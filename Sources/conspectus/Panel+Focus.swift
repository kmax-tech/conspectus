import Cocoa
import Quartz
import SwiftTerm
import ConspectusCore

// Keyboard focus: cycling with ⌥-arrows, focus-by-intent for the preview,
// the subtle focus border, and restoration after app switches.

/// QLPreviewView with focus-by-intent: it refuses first-responder status
/// unless `allowFocus` is set — so *unintended* focus changes (app switches,
/// stray events) can never silently steal the keyboard from the terminals.
/// Focus is granted deliberately: by ⌥→ or by a click in the pane (the
/// Panel's click monitor sets allowFocus + makes it first responder). A
/// focused Quick Look natively takes arrows, PgUp/PgDn, and Space. The
/// permission is revoked as soon as focus moves elsewhere.
final class IntentFocusPreviewView: QLPreviewView {
    var allowFocus = false
    /// Return to yazi — set by the Panel; `h`/← invoke it. Best-effort for the
    /// QL view: Quick Look's remote content may consume keys first, in which
    /// case ⌥←/⌥[ still returns. (The PDF view handles h/← reliably.)
    var onFocusLeft: (() -> Void)?
    override var acceptsFirstResponder: Bool { allowFocus }

    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == "h" || event.keyCode == 123 {
            onFocusLeft?()
        } else {
            super.keyDown(with: event)
        }
    }

    private var lastNudge = Date.distantPast

    // Fourth QLPreviewView state trap (see NOTES): after a pointer excursion
    // the remote extension can stop processing wheel events for the
    // still-displayed document; a first-responder change re-arms it
    // (user-verified). Wheel events normally TERMINATE inside the remote
    // subview and never bubble up here — one arriving is itself the proof
    // that the remote dropped them. So the focus nudge runs lazily, exactly
    // then. The throttle (0.25s) only guards against a dance per wheel TICK
    // if the bubbling assumption is ever wrong — it must stay well below
    // human retry time, or a dead preview feels dead for that long. The
    // earlier eager nudge-on-every-mouse-entry was REVERTED: its
    // resign/become churn on the terminal view could wedge SwiftTerm's
    // repainting (frozen yazi pane while navigation kept working underneath).
    //
    // `prev !== self` also means: a DELIBERATELY focused preview (⌥→) never
    // enters this branch, so the unconditional `allowFocus = false` below
    // cannot revoke an intentional focus — focusPreview() re-grants it anyway.
    override func scrollWheel(with event: NSEvent) {
        if Date().timeIntervalSince(lastNudge) > 0.25,
           let win = window, let prev = win.firstResponder, prev !== self {
            lastNudge = Date()
            logEvent("scroll-nudge: re-arming QL remote (restoring \(type(of: prev)))")
            allowFocus = true
            if win.makeFirstResponder(self) {
                win.makeFirstResponder(prev)
            }
            allowFocus = false
        }
        super.scrollWheel(with: event)
    }
}

/// Transparent overlay that only draws the focus border and never intercepts
/// clicks. Needed for the preview pane: Quick Look's content is composited
/// from a remote process, so a border on the container layer can end up
/// underneath it — this view sits above everything in the pane.
final class PassthroughBorderView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Native PDF preview — "perlege light". PDFs bypass the fragile Quick Look
/// machinery entirely and render in PDFKit, page-wise by default (mouse wheel
/// flips pages). Same focus-by-intent contract as the Quick Look view: wheel
/// works unfocused; focus is granted deliberately by ⌥→ or a click in the
/// pane. Focused, it answers to perlege's bindings (shared/keymap.json is the
/// reference): J/]/space next page, K/[ previous, +/- zoom, f fit, s toggles
/// single ↔ continuous.
final class IntentFocusPDFView: PDFView {
    var allowFocus = false
    /// Return to the yazi pane — set by the Panel; `h`/← invoke it so h/l
    /// pane navigation is symmetric (yazi `l`→preview, preview `h`→yazi).
    var onFocusLeft: (() -> Void)?
    /// `n` — open (or create) the PDF's companion note in the ide editor;
    /// set by the Panel, same action as the toolbar's note button.
    var onOpenNote: (() -> Void)?
    override var acceptsFirstResponder: Bool { allowFocus }

    // PDFView redirects first-responder status to an internal document view,
    // so keyDown on the PDFView itself may never fire. Claim it back on
    // becomeFirstResponder so our key handler below is the one that runs.
    override func becomeFirstResponder() -> Bool {
        _ = super.becomeFirstResponder()
        return true
    }

    // A deliberate click IS intent: it grants focus (the click monitor in the
    // Panel does this), so let PDFKit handle the click normally for selection
    // and link activation.
    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
    }

    /// Mirror of perlege's displayMode toggle (`s`), minus the twoUp modes —
    /// the preview pane is too narrow for spreads.
    func toggleDisplayMode() {
        displayMode = displayMode == .singlePage ? .singlePageContinuous : .singlePage
        autoScales = true
    }

    override func keyDown(with event: NSEvent) {
        switch event.charactersIgnoringModifiers {
        case "j", "J", "]", " ": goToNextPage(nil)
        case "k", "K", "[":      goToPreviousPage(nil)
        case "+", "=":           zoomIn(nil)
        case "-":                zoomOut(nil)
        case "f":                autoScales = true
        case "s":                toggleDisplayMode()
        case "n":                onOpenNote?()                // companion note → editor
        case "h":                onFocusLeft?()               // back to yazi (h/l nav)
        default:
            if event.keyCode == 123 { onFocusLeft?() }        // ← also returns
            else { super.keyDown(with: event) }               // arrows, PgUp/PgDn native
        }
    }
}

/// Native text preview — the first step of moving off Quick Look. Text/source/
/// config/notes render here (in-process NSTextView) instead of through Quick
/// Look and the third-party sbarex QL plugins, so the common and crash-prone
/// (markdown → QLMarkdown → WebKit) cases leave the fragile remote path. Same
/// focus-by-intent contract as the other previews: wheel scrolls unfocused,
/// focus is granted by ⌥→ or a click / l-on-file; then j/k scroll a line,
/// arrows/PgUp/PgDn scroll natively, h/← return to yazi.
final class IntentFocusTextView: NSTextView {
    var allowFocus = false
    var onFocusLeft: (() -> Void)?
    /// `M` — toggle markdown between rendered and source. Uppercase to match
    /// yazi's `M` binding (lowercase `m` is yazi's linemode menu).
    var onToggleMarkdown: (() -> Void)?
    override var acceptsFirstResponder: Bool { allowFocus }

    /// Maximum measure (line length) in points for the text column, 0 = none.
    /// Set for rendered markdown, cleared for source: prose past ~75 characters
    /// per line loses the reader between lines, while a source listing must keep
    /// the file's own line breaks. Side effect: changing it re-lays out the text.
    var maxMeasure: CGFloat = 0 {
        didSet { if maxMeasure != oldValue { applyMeasureCap() } }
    }
    /// Padding when the text is narrower than the pane (the uncapped default).
    private let minInset: CGFloat = 12

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        applyMeasureCap()
    }

    /// Centre the text column by growing the horizontal inset: the container
    /// tracks the view width, so the surplus over `maxMeasure` becomes margin
    /// on both sides. No-op (beyond the base padding) when uncapped.
    private func applyMeasureCap() {
        let wanted = maxMeasure > 0 ? max(minInset, (bounds.width - maxMeasure) / 2) : minInset
        guard abs(textContainerInset.width - wanted) > 0.5 else { return }
        textContainerInset = NSSize(width: wanted, height: textContainerInset.height)
    }

    override func keyDown(with event: NSEvent) {
        switch event.charactersIgnoringModifiers {
        case "j": scrollLineDown(nil)
        case "k": scrollLineUp(nil)
        case "M": onToggleMarkdown?()
        case "h": onFocusLeft?()
        default:
            if event.keyCode == 123 { onFocusLeft?() }   // ← returns to yazi
            else { super.keyDown(with: event) }
        }
    }
}

/// Native image preview — raster images render here (in-process NSImageView,
/// fit-to-pane) instead of Quick Look. Focus-by-intent like the other previews
/// so the border and h/l navigation stay consistent; there is nothing to
/// scroll or page, so it only handles h/← (return to yazi).
final class IntentFocusImageView: NSImageView {
    var allowFocus = false
    var onFocusLeft: (() -> Void)?
    override var acceptsFirstResponder: Bool { allowFocus }

    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == "h" || event.keyCode == 123 {
            onFocusLeft?()
        } else {
            super.keyDown(with: event)
        }
    }
}

/// The folder-listing text view: display + clickable rows only. It must never
/// take the keyboard — a click on a row would otherwise make it first
/// responder and silently swallow all yazi keystrokes (same trap the preview
/// had; link clicks and wheel scrolling work without key focus).
final class NonFocusableTextView: NSTextView {
    override var acceptsFirstResponder: Bool { false }
}

extension Panel {
    // ⌥←/→ cycle horizontally: left terminal ⇄ second terminal ⇄ preview.
    // The preview is a real focus target (focus-by-intent) — a focused Quick
    // Look scrolls with arrows/PgUp/PgDn and pages PDFs with Space.
    @objc func focusLeftPane() {
        if window.firstResponder === editorTerm { editorSplitNavOrHandoff("left"); return }
        if previewHasFocus(window.firstResponder) {
            window.makeFirstResponder(middleTerm ?? term)
        } else {
            window.makeFirstResponder(term)
        }
    }

    @objc func focusRightPane() {
        if window.firstResponder === editorTerm { editorSplitNavOrHandoff("right"); return }
        if window.firstResponder === term, let mid = middleTerm {
            window.makeFirstResponder(mid)
            return
        }
        if previewAttached {
            focusPreview()
        } else if let mid = middleTerm {
            window.makeFirstResponder(mid)
        }
    }

    // ⌥↓ / ⌥↑ — vertical focus between the pane area and the terminal panel.
    @objc func focusDown() {
        if window.firstResponder === editorTerm { editorSplitNavOrHandoff("down"); return }
        if let bt = bottomTerm { window.makeFirstResponder(bt) }
    }

    @objc func focusUp() {
        if window.firstResponder === editorTerm { editorSplitNavOrHandoff("up"); return }
        window.makeFirstResponder(lastTopTerm ?? term)
    }

    /// ⌥-arrow inside the ide editor: ask the editor's nvim to move within its
    /// OWN splits first (RPC to its --listen server via `v:lua.conspectus_move`);
    /// only if nvim is already at that edge ("edge", or the helper/nvim is
    /// absent) hand off to the neighbouring conspectus pane. This is the
    /// smart-splits handoff, with conspectus driving so it never depends on how
    /// the terminal encodes ⌥-arrows. Without the (opt-in) nvim helper the RPC
    /// simply fails and it degrades to a plain pane move — the old behaviour.
    /// Side effects: spawns the nvim client off-thread; moves focus on main.
    func editorSplitNavOrHandoff(_ dir: String) {
        guard let nvim = nvimPath else { moveEditorNeighbour(dir); return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: nvim)
            p.arguments = ["--server", nvimSocketPath, "--remote-expr", "v:lua.conspectus_move('\(dir)')"]
            let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
            var moved = false
            do {
                try p.run()
                let d = out.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                moved = (String(data: d, encoding: .utf8) ?? "").contains("moved")
            } catch { moved = false }
            if !moved { DispatchQueue.main.async { self?.moveEditorNeighbour(dir) } }
        }
    }

    /// Move focus out of the editor to the conspectus pane in `dir`. The editor
    /// sits in the middle (yazi | nvim | preview): left → yazi, right → preview,
    /// down → terminal panel; nothing sits above it.
    func moveEditorNeighbour(_ dir: String) {
        switch dir {
        case "left":  window.makeFirstResponder(term)
        case "right": if previewAttached { focusPreview() } else { window.makeFirstResponder(term) }
        case "down":  if let bt = bottomTerm { window.makeFirstResponder(bt) }
        default:      break   // "up": no pane above the editor
        }
    }

    /// Hand the keyboard to the preview deliberately (clicks cannot). Goes to
    /// whichever preview is currently showing: the PDF view (perlege keys) or
    /// the Quick Look view (arrows/Space natively).
    func focusPreview() {
        guard previewAttached else { return }
        // Whichever cover is showing gets the keyboard: native text, native
        // PDF, else the Quick Look view.
        if let tp = textPane, !tp.isHidden {
            textView.allowFocus = true
            let ok = window.makeFirstResponder(textView)
            logEvent("focusPreview -> textView ok=\(ok) fr=\(type(of: window.firstResponder))")
        } else if let iv = imageView, !iv.isHidden {
            imageView.allowFocus = true
            let ok = window.makeFirstResponder(imageView)
            logEvent("focusPreview -> imageView ok=\(ok) fr=\(type(of: window.firstResponder))")
        } else if let pane = pdfPane, !pane.isHidden {
            pdfView.allowFocus = true
            let ok = window.makeFirstResponder(pdfView)
            logEvent("focusPreview -> pdfView ok=\(ok) fr=\(type(of: window.firstResponder))")
        } else {
            preview.allowFocus = true
            let ok = window.makeFirstResponder(preview)
            logEvent("focusPreview -> QL ok=\(ok) fr=\(type(of: window.firstResponder))")
        }
        updateFocusBorders()   // belt-and-suspenders: paint immediately, not only on the KVO tick
    }

    /// True if the keyboard currently sits in the preview pane. Quick Look
    /// hands first-responder duty to a private internal subview, so an
    /// identity check against `preview` alone misses — test for descendants
    /// of the pane instead.
    func previewHasFocus(_ fr: NSResponder?) -> Bool {
        if fr === preview { return true }
        if let v = fr as? NSView { return v.isDescendant(of: rightContainer) }
        return false
    }

    /// Click-to-focus: a deliberate click in the preview pane focuses it and
    /// shows the focus border, exactly like clicking a terminal pane does via
    /// SwiftTerm. This does NOT reopen the silent-focus-steal bug the
    /// focus-by-intent contract guards against — that was about *unintended*
    /// focus loss (app reactivation, stray events); a click is intent. The
    /// monitor grants focus but returns the event, so buttons in the PDF
    /// toolbar and text selection still work. Terminal panes already focus on
    /// click (SwiftTerm), so we only handle clicks that land in the preview.
    /// Side effects: installs a local leftMouseDown monitor.
    func startPreviewClickMonitor() {
        NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self = self, self.previewAttached,
                  let hit = self.window?.contentView?.hitTest(event.locationInWindow),
                  hit.isDescendant(of: self.rightContainer),
                  !self.previewHasFocus(self.window?.firstResponder) else { return event }
            self.focusPreview()
            return event   // don't swallow — the click still selects / clicks buttons
        }
    }

    /// React to any first-responder change (KVO): revoke the preview's
    /// focus-by-intent permission once focus moves elsewhere, and repaint the
    /// focus borders. KVO covers all paths — menu commands, mouse clicks into
    /// a pane, and the app-switch restore.
    func focusDidChange() {
        if !previewHasFocus(window?.firstResponder) {
            preview?.allowFocus = false
            pdfView?.allowFocus = false
            textView?.allowFocus = false
            imageView?.allowFocus = false
        }
        if let fr = window?.firstResponder as? LocalProcessTerminalView, fr !== bottomTerm {
            lastTopTerm = fr
        }
        // Focusing the editor pane: show whatever file nvim currently has open,
        // so the preview follows the editor (not yazi's hover) while you edit.
        if window?.firstResponder === editorTerm { previewEditorCurrentFile() }
        updateFocusBorders()
    }

    /// Ask the editor's nvim (over its RPC socket) which file is open and
    /// preview it — the focus-in trigger for "preview follows the editor". The
    /// in-nvim buffer-switch trigger is the `@EDITOR_FILE:` push (see the FIFO
    /// reader). No-op without nvim, or on an empty/no-name buffer. Side effects:
    /// spawns the nvim client off-thread; updates the preview on main.
    func previewEditorCurrentFile() {
        guard let nvim = nvimPath else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: nvim)
            p.arguments = ["--server", nvimSocketPath, "--remote-expr", "expand('%:p')"]
            let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
            var path = ""
            do {
                try p.run()
                let d = out.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                path = (String(data: d, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            } catch { return }
            guard !path.isEmpty else { return }   // empty buffer: leave the preview as-is
            DispatchQueue.main.async {
                guard let self = self,
                      self.window.firstResponder === self.editorTerm else { return }  // still editing
                // Editing the previewed PDF's own note: keep (or restore) the
                // PDF on the right — mirroring the note the editor already
                // shows would be pointless, and this is what stops the
                // note-follow and editor-follow features fighting each other.
                if let a = self.activeNote, path == a.note { self.update(a.pdf); return }
                self.update(path)
            }
        }
    }

    /// A file became active in the editor's nvim (BufEnter push over the FIFO).
    /// Honour it only while the editor is focused — otherwise yazi's hover owns
    /// the preview. Goes through `update`, so pin and the mtime watch still apply.
    func editorFileHover(_ path: String) {
        guard window.firstResponder === editorTerm else { return }
        // Switching (back) to the previewed PDF's note keeps the PDF on the
        // right — same guard as in previewEditorCurrentFile. Note that the
        // auto-follow push itself echoes here too (nvim's BufEnter fires on
        // --remote), but dies at the focus guard above: yazi is focused then.
        if let a = activeNote, path == a.note { update(a.pdf); return }
        update(path)
    }

    /// Subtle gray border on the focused pane — shown only while more than
    /// one focusable target exists (a lone pane stays clean). The preview's
    /// border is drawn by its dedicated overlay (see PassthroughBorderView).
    func updateFocusBorders() {
        guard let window = window else { return }
        let fr = window.firstResponder
        var targets: [(NSView, Bool)] = [(termPane, fr === term)]
        if let t2 = term2, let pane = term2Pane { targets.append((pane, fr === t2)) }
        if let et = editorTerm, let pane = editorPane { targets.append((pane, fr === et)) }
        if previewAttached { targets.append((previewFocusRing, previewHasFocus(fr))) }
        if let bt = bottomTerm, let pane = bottomPane { targets.append((pane, fr === bt)) }
        let show = targets.count > 1
        let color = nsColor(activePalette().fg).withAlphaComponent(0.25).cgColor
        let pinColor = NSColor.systemYellow.withAlphaComponent(0.9).cgColor
        for (view, focused) in targets {
            view.wantsLayer = true
            // A pinned preview always wears a distinct (yellow) border — it
            // overrides the subtle focus gray so the pinned state reads at a
            // glance, focused or not.
            if view === previewFocusRing && previewPinned {
                view.layer?.borderWidth = 2
                view.layer?.borderColor = pinColor
            } else {
                view.layer?.borderWidth = (show && focused) ? 2 : 0
                view.layer?.borderColor = color
            }
        }
    }

    /// Bring the window to the front — the `@ACTIVATE` FIFO sentinel, written
    /// by the bundled plugin after the shell routed a directory in via the
    /// `conspectus-open` DDS message (zsh `con <dir>`). In-process activation,
    /// so no Automation/accessibility permission is needed on the shell side.
    /// Side effects: activates the app and raises/deminiaturizes the window.
    func activateFromShell() {
        NSApp.activate(ignoringOtherApps: true)
        window?.deminiaturize(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: NSApplicationDelegate — focus resilience across app switches.
    // Launching an editor out of yazi (E c → VS Code, …) and coming back must
    // never leave the keyboard pointing nowhere: remember which terminal had
    // focus when we deactivate, and restore it if reactivation hands the
    // first-responder role to anything that is not a terminal.
    func applicationDidResignActive(_ n: Notification) {
        if let t = window?.firstResponder as? LocalProcessTerminalView { lastFocusedTerm = t }
    }

    func applicationDidBecomeActive(_ n: Notification) {
        guard let window = window else { return }
        if !(window.firstResponder is LocalProcessTerminalView) {
            window.makeFirstResponder(lastFocusedTerm ?? term)
        }
    }
}
