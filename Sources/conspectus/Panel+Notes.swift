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
        // guard an OLD note could land last and hijack the window. The GC of
        // older auto-notes rides INSIDE the same delivery transaction
        // (sweepStale), so no interleaving can leave one behind.
        openInEditor(note, focus: false, sweepStale: true,
                     while: { [weak self] in self?.lastEditorNotePush == note })
    }

    /// Vimscript single-quoted string literal for `s`.
    private func vimQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "''") + "'"
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
        openInEditor(target, focus: !alreadyShown, sweepStale: true)   // pinned, so the sweep spares it
    }

    /// Open `path` as a buffer in the ide editor's nvim — VERIFIED and atomic:
    /// one `--remote-expr` `:drop`s the file, garbage-collects stale
    /// auto-followed note buffers in the SAME transaction (`sweepStale` — no
    /// separate client call that overlapping chains could race against), and
    /// answers with the buffer nvim actually shows afterwards. Only a matching
    /// answer counts as delivered; anything else (E-errors, swap prompt, dead
    /// server) is logged to the event log and retried — the pane may have been
    /// added just now (nvim booting, socket not listening, `nvimPath`
    /// resolving). Gives up loud after ~12s.
    /// Side effects: spawns nvim client processes off-thread; `focus: true`
    /// moves the keyboard to the editor on success; `while` (checked on main
    /// before every attempt) aborts the chain silently when it returns false —
    /// how a superseded auto-push dies.
    func openInEditor(_ path: String, focus: Bool, attempt: Int = 0, sweepStale: Bool = false,
                      while stillWanted: (() -> Bool)? = nil) {
        guard let editor = editorTerm else { return }   // pane closed while retrying
        if stillWanted?() == false { return }           // superseded — a newer push owns the editor
        guard let nvim = nvimPath else {                // resolution still in flight
            retryOpenInEditor(path, focus: focus, attempt: attempt,
                              sweepStale: sweepStale, while: stillWanted)
            return
        }
        // Stale = every auto-pushed note except this one and the pinned ones,
        // deleted only if unmodified AND hidden — never discards work. Exact
        // name comparison (index over getbufinfo names), NOT bufnr(): bufnr
        // falls back to partial matching and could hit an unrelated buffer.
        let stale = sweepStale
            ? autoNoteBuffers.subtracting(pinnedNoteBuffers).subtracting([path]).sorted()
            : []
        let staleList = "[" + stale.map(vimQuote).joined(separator: ",") + "]"
        let sweep = stale.isEmpty ? "''"
            : "execute(join(map(filter(getbufinfo(), "
              + "{_, b -> index(\(staleList), b.name) >= 0 && b.changed == 0 && empty(b.windows)}), "
              + "{_, b -> 'silent! bdelete ' . b.bufnr}), '|'))"
        let expr = "[execute('drop ' . fnameescape(\(vimQuote(path)))), \(sweep), expand('%:p')][2]"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let (status, answer, errOut) = runNvimExpr(nvim, expr)
            let delivered = status == 0 && answer == path
            DispatchQueue.main.async {
                guard let self = self else { return }
                if delivered {
                    logEvent("openInEditor delivered \(path)"
                             + (stale.isEmpty ? "" : " (sweep over \(stale.count) stale)"))
                    if focus, self.editorTerm === editor { self.window.makeFirstResponder(editor) }
                    if !stale.isEmpty { self.reportSweepSurvivors(stale, nvim: nvim) }
                } else {
                    if !errOut.isEmpty || !answer.isEmpty {
                        logEvent("openInEditor attempt \(attempt) failed for \(path): "
                                 + "answer='\(answer)' err='\(errOut)'")
                    }
                    self.retryOpenInEditor(path, focus: focus, attempt: attempt,
                                           sweepStale: sweepStale, while: stillWanted)
                }
            }
        }
    }

    /// Diagnostics only: after a sweep, ask nvim which of the stale note
    /// buffers are STILL there and why (changed? visible?) and event-log the
    /// answer — a buffer that "won't close" now explains itself (e.g. a plugin
    /// marking buffers modified on load) instead of leaving us guessing.
    /// Nothing is deleted or retried here. Side effects: one nvim client
    /// off-thread.
    private func reportSweepSurvivors(_ stale: [String], nvim: String) {
        let list = "[" + stale.map(vimQuote).joined(separator: ",") + "]"
        // b.listed: a bdelete'd buffer lingers unlisted in getbufinfo() —
        // without the filter every successfully swept note would false-alarm.
        let expr = "join(map(filter(getbufinfo(), {_, b -> b.listed && index(\(list), b.name) >= 0}), "
                 + "{_, b -> fnamemodify(b.name, ':t') . '[changed=' . b.changed"
                 + " . ' visible=' . len(b.windows) . ']'}), '  ')"
        DispatchQueue.global(qos: .utility).async {
            let (status, answer, _) = runNvimExpr(nvim, expr)
            if status == 0, !answer.isEmpty { logEvent("note buffers kept: \(answer)") }
        }
    }

    private func retryOpenInEditor(_ path: String, focus: Bool, attempt: Int,
                                   sweepStale: Bool, while stillWanted: (() -> Bool)?) {
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
            self?.openInEditor(path, focus: focus, attempt: attempt + 1,
                               sweepStale: sweepStale, while: stillWanted)
        }
    }
}

/// Run `nvim --server <ide socket> --remote-expr <expr>` synchronously and
/// return (exit status, stdout, stderr), both trimmed. Blocking — call
/// off the main thread.
private func runNvimExpr(_ nvim: String, _ expr: String) -> (Int32, String, String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: nvim)
    p.arguments = ["--server", nvimSocketPath, "--remote-expr", expr]
    let outPipe = Pipe(); let errPipe = Pipe()
    p.standardOutput = outPipe; p.standardError = errPipe
    do {
        try p.run()
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let out = (String(data: outData, encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let err = (String(data: errData, encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (p.terminationStatus, out, err)
    } catch {
        return (-1, "", error.localizedDescription)
    }
}
