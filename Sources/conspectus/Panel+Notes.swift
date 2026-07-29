import Cocoa
import ConspectusCore

// PDF companion notes (perlege's note lookup, integrated): hovering a PDF
// resolves its `<stem>.md` (ConspectusCore.resolveNote) and — with the ide
// editor pane open — opens the EXISTING note in the middle nvim automatically,
// so cycling through PDFs in yazi keeps PDF (right) and note (middle) in sync.
// The toolbar button / `n` opens the note deliberately, creating a sibling
// note if none exists (never in the central library).

extension Panel {
    /// Resolve the previewed PDF's note off the main thread; on main — if this
    /// is still the newest hover — publish it: `activeNote`, the toolbar icon,
    /// and the ide auto-follow. Side effects: filesystem walk off-thread,
    /// state + UI updates and a possible nvim push on main.
    func resolveNoteAsync(for path: String, generation gen: Int) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let note = resolveNote(for: path, notesDirs: notesDirs)
            guard self.isCurrentListing(gen) else { return }
            DispatchQueue.main.async {
                guard self.isCurrentListing(gen) else { return }
                self.activeNote = note.map { (pdf: path, note: $0) }
                self.updateNoteButton()
                self.pushNoteToEditor()
                if let n = note { logEvent("note resolved \(path) -> \(n)") }
            }
        }
    }

    /// Mirror `activeNote` in the PDF toolbar: existing note → plain note
    /// icon, none → badge-plus (clicking creates one next to the PDF).
    func updateNoteButton() {
        guard let b = noteButton else { return }
        let tip = activeNote != nil
            ? "Note im Editor öffnen (n)"
            : "Note anlegen (n) — <name>.md neben dem PDF"
        b.image = NSImage(systemSymbolName: activeNote != nil ? "note.text" : "note.text.badge.plus",
                          accessibilityDescription: tip) ?? b.image
        b.toolTip = tip
    }

    /// ide auto-follow: open the previewed PDF's EXISTING note in the middle
    /// nvim — only while the editor pane is open, never creating anything,
    /// deduped so re-hovering the same PDF doesn't spam nvim. The editor keeps
    /// (or rather never gets) the keyboard; yazi stays in charge. Once the new
    /// note is in, the PREVIOUS auto-followed note buffer is garbage-collected
    /// (unmodified + hidden only) — cycling through a paper library must not
    /// pile up a buffer per PDF. Notes opened explicitly (`n`/toolbar) and
    /// anything with unsaved changes are never touched.
    func pushNoteToEditor() {
        guard editorTerm != nil, let note = activeNote?.note, note != lastEditorNotePush else { return }
        lastEditorNotePush = note
        autoNoteBuffers.insert(note)
        // `while`: a stale auto-push dies as soon as a newer note took over —
        // during nvim's boot several retry chains overlap, and without the
        // guard an OLD note could land last and hijack the window.
        openInEditor(note, focus: false,
                     while: { [weak self] in self?.lastEditorNotePush == note },
                     then: { [weak self] in self?.sweepAutoNoteBuffers() })
    }

    /// Close every auto-followed note buffer except the current one — pinned,
    /// modified, and visible buffers survive (cleanupNoteBuffer's guards). A
    /// sweep over ALL auto-pushed notes, not just the previous one, so a push
    /// that landed out of order (nvim boot race) is collected on the next
    /// cycle instead of sticking forever.
    func sweepAutoNoteBuffers() {
        for path in autoNoteBuffers
        where path != lastEditorNotePush && !pinnedNoteBuffers.contains(path) {
            cleanupNoteBuffer(path)
        }
    }

    /// Delete the nvim buffer for `path` iff it is unmodified and not visible
    /// in any window — the auto-follow buffer GC. Best-effort by design: a
    /// failed delete only leaves a clean buffer in the list (deliberate, no
    /// retry/warn). Side effects: spawns an nvim client off-thread.
    func cleanupNoteBuffer(_ path: String) {
        guard editorTerm != nil, let nvim = nvimPath else { return }
        let q = path.replacingOccurrences(of: "'", with: "''")   // vimscript '…' escaping
        // Exact name comparison (==#), not bufnr('<path>') — bufnr falls back
        // to PARTIAL name matching and could delete an unrelated buffer.
        let expr = "execute(join(map(filter(getbufinfo(), "
                 + "{_, b -> b.name ==# '\(q)' && b.changed == 0 && empty(b.windows)}), "
                 + "{_, b -> 'silent! bdelete ' . b.bufnr}), '|'))"
        DispatchQueue.global(qos: .utility).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: nvim)
            p.arguments = ["--server", nvimSocketPath, "--remote-expr", expr]
            p.standardOutput = Pipe(); p.standardError = Pipe()
            try? p.run()   // deliberate: GC is cosmetic, failure is harmless
            p.waitUntilExit()
            logEvent("note buffer GC \(path) (exit \(p.terminationStatus))")
        }
    }

    /// Toolbar button / `n` on the focused PDF pane / ⌘N from anywhere: open
    /// the note in the ide editor — the resolved one, or (none found) a fresh
    /// `<stem>.md` next to the PDF; nvim materializes it on the first save.
    /// Adds the editor pane if it isn't open (the note needs somewhere to go)
    /// and focuses it. Deliberate open = PIN: the buffer leaves the GC's
    /// reach, so `n` while cycling collects notes in the buffer list.
    @objc func openPDFNote() {
        guard let pdf = pdfView.document?.documentURL?.path else { NSSound.beep(); return }
        let target = activeNote?.note ?? defaultNotePath(for: pdf)
        pinnedNoteBuffers.insert(target)
        logEvent("note pinned \(target)")
        // Auto-follow already has this note on screen → a pure pin: keep the
        // keyboard where it is (collecting notes must not break the cycling).
        // A note not yet in nvim (fresh create, fresh pane, or no editor
        // follow) is opened to be written in → focus moves to the editor.
        // Decided BEFORE addEditorPane: its own auto-push sets
        // lastEditorNotePush to this very note, which would mask the fresh open.
        let alreadyShown = editorTerm != nil && target == lastEditorNotePush
        if editorTerm == nil { addEditorPane() }
        openInEditor(target, focus: !alreadyShown)
    }

    /// Open `path` as a buffer in the ide editor's nvim (`--remote` = drop).
    /// Retries: the pane may have been added just now — nvim still starting,
    /// its socket not yet listening, `nvimPath` still resolving. Gives up loud
    /// after ~12s. Side effects: spawns nvim client processes off-thread;
    /// `focus: true` moves the keyboard to the editor on success; `then` runs
    /// on main after a successful open (used by the buffer GC); `while`
    /// (checked on main before every attempt) aborts the chain silently when
    /// it returns false — how a superseded auto-push dies.
    func openInEditor(_ path: String, focus: Bool, attempt: Int = 0,
                      while stillWanted: (() -> Bool)? = nil, then: (() -> Void)? = nil) {
        guard let editor = editorTerm else { return }   // pane closed while retrying
        if stillWanted?() == false { return }           // superseded — a newer push owns the editor
        guard let nvim = nvimPath else {                // resolution still in flight
            retryOpenInEditor(path, focus: focus, attempt: attempt, while: stillWanted, then: then)
            return
        }
        // Delivery is VERIFIED, not fire-and-forget: the expr `:drop`s the file
        // and answers with the buffer nvim actually shows afterwards — only a
        // matching answer counts as delivered. Errors (E37, swap prompts, a
        // dead server) surface in stderr and go to the event log instead of
        // being swallowed; that is what made failures diagnosable.
        let esc = path.replacingOccurrences(of: "'", with: "''")
        let expr = "[execute('drop ' . fnameescape('\(esc)')), expand('%:p')][1]"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: nvim)
            p.arguments = ["--server", nvimSocketPath, "--remote-expr", expr]
            let outPipe = Pipe(); let errPipe = Pipe()
            p.standardOutput = outPipe; p.standardError = errPipe
            var answer = ""; var errOut = ""
            do {
                try p.run()
                let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                answer = (String(data: outData, encoding: .utf8) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                errOut = (String(data: errData, encoding: .utf8) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            } catch { errOut = error.localizedDescription }
            let delivered = p.terminationStatus == 0 && answer == path
            DispatchQueue.main.async {
                guard let self = self else { return }
                if delivered {
                    logEvent("openInEditor delivered \(path)")
                    if focus, self.editorTerm === editor { self.window.makeFirstResponder(editor) }
                    then?()
                } else {
                    if !errOut.isEmpty || !answer.isEmpty {
                        logEvent("openInEditor attempt \(attempt) failed for \(path): "
                                 + "answer='\(answer)' err='\(errOut)'")
                    }
                    self.retryOpenInEditor(path, focus: focus, attempt: attempt, while: stillWanted, then: then)
                }
            }
        }
    }

    private func retryOpenInEditor(_ path: String, focus: Bool, attempt: Int,
                                   while stillWanted: (() -> Bool)?, then: (() -> Void)?) {
        // Generous: a FRESH pane pays a login shell (oh-my-zsh …) + nvim
        // startup before the socket listens — 3s proved too short in the
        // field. Retries stop on the first success; only a truly dead nvim
        // burns the full budget, then fails loud.
        let maxAttempts = 40   // × 0.3s ≈ 12s
        guard attempt + 1 < maxAttempts else {
            warn("conspectus: cannot open \(path) in the editor — nvim's RPC server did not respond")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.openInEditor(path, focus: focus, attempt: attempt + 1, while: stillWanted, then: then)
        }
    }
}
