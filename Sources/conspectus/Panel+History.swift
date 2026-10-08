import Cocoa
import ConspectusCore

// The Go menu's moves: browser-style back / forward for the yazi panes (the
// mouse's side buttons and ⌘[ / ⌘]), enclosing folder, and Reveal in Finder.
// The history moves end up in yazi's own commands (`back` / `forward`, what
// H / L run) via the DDS — never as a synthetic keystroke, which would type
// into an open filter or search prompt.
//
// Why the app and not the keymap: yazi reads mouse input through crossterm,
// which only knows left / middle / right — the side buttons never reach it.
// AppKit does see them (`otherMouseDown`, button 3 = back, 4 = forward), so
// conspectus is the only layer that can offer them.

extension Panel {
    /// Watch for the mouse's side buttons and turn them into history moves.
    /// The pane under the pointer is the one that moves; a click outside both
    /// yazi panes (preview, editor, terminal panel) drives the pane that was
    /// last active, so back/forward also works while reading a preview.
    /// Swallows the event: nothing else in conspectus uses these buttons, and
    /// leaving it in the queue would send a stray mouse report to SwiftTerm.
    /// Side effects: installs a local otherMouseDown monitor.
    func startMouseHistoryMonitor() {
        guard mouseHistoryEnabled else { return }
        NSEvent.addLocalMonitorForEvents(matching: .otherMouseDown) { [weak self] event in
            guard let self = self else { return event }
            switch event.buttonNumber {
            case 3: self.goHistory("back", at: event.locationInWindow)
            case 4: self.goHistory("forward", at: event.locationInWindow)
            default: return event
            }
            return nil
        }
    }

    /// Menu action: back (⌘[).
    @objc func historyBack() { goHistory("back", at: nil) }

    /// Menu action: forward (⌘]).
    @objc func historyForward() { goHistory("forward", at: nil) }

    /// Menu action: enclosing folder (⌘↑ — Finder's key for the same move).
    /// Runs yazi's `leave`, so it is one level up, not one step back in the
    /// history. Menu + shortcut is the mouse-reachable half of going up; the
    /// clickable path bar in each pane's header is the other.
    @objc func goUp() { goHistory("up", at: nil) }

    /// Menu action: reveal the hovered item in Finder (⌥⌘R — VS Code's key for
    /// the same move; the GUI half of the cross-tool contract, whose keyboard
    /// half is yazi's `E f` and nvim's / Emacs's `x f`). Works from any pane,
    /// including nvim and the preview, where the yazi binding cannot be typed.
    ///
    /// A folder OPENS in Finder (its contents — what "in Finder" means for a
    /// directory), anything else is REVEALED in its parent and selected, the
    /// same split the `E f` binding makes. Falls back to the pane's current
    /// directory before the first hover.
    ///
    /// Side effects: activates Finder.
    @objc func revealInFinder() {
        let path = lastPath ?? currentYaziDir()
        guard FileManager.default.fileExists(atPath: path) else {
            warn("reveal: no such path \(path)")   // deleted under the cursor
            return
        }
        let url = URL(fileURLWithPath: path)
        if isDirectory(path) {
            NSWorkspace.shared.open(url)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    /// Menu action: previous / next yazi tab (⌘⇧[ / ⌘⇧] — the cross-tool tab
    /// idiom of kitty and WezTerm, dotfiles `keybindings.md`).
    @objc func tabPrevious() { goTab("prev") }
    @objc func tabNext() { goTab("next") }

    /// Menu action: switch to tab 1…9 (⌘1…⌘9, as in both terminals). The tag
    /// carries the tab number; yazi counts from 0, the plugin converts.
    @objc func tabByNumber(_ sender: NSMenuItem) { goTab(String(sender.tag)) }

    /// Drive one pane's tabs over the DDS. Like `goHistory`, this sends a
    /// command and never a synthetic keystroke: `[` typed into an open filter
    /// prompt would land in the query instead of switching tabs.
    ///
    /// The tabs themselves stay yazi's (`t` creates, `1…9` switch inside a
    /// focused pane) — these menu keys exist for the moments a yazi pane does
    /// NOT have the keyboard: from nvim, the preview, or the terminal panel,
    /// yazi's own keys never arrive.
    func goTab(_ move: String) {
        publishToYazi("panesync-tab", body: "\(move) \(paneUnder(nil))")
    }

    /// Move one step through the history of one pane. `point` is a window
    /// coordinate to pick the pane from (a mouse click); nil means "the active
    /// pane" — the menu has no pointer.
    func goHistory(_ direction: String, at point: NSPoint?) {
        publishToYazi("panesync-history", body: "\(direction) \(paneUnder(point))")
    }

    /// Which yazi pane a window point belongs to, as the peer letter the
    /// plugin filters on. Falls back to the last active yazi pane, so clicks
    /// in the preview or menu commands still address the pane you were just
    /// navigating.
    func paneUnder(_ point: NSPoint?) -> String {
        if let point = point, let hit = window?.contentView?.hitTest(point) {
            if let t2 = term2, hit === t2 || hit.isDescendant(of: t2) { return "R" }
            if let t1 = term, hit === t1 || hit.isDescendant(of: t1) { return "L" }
        }
        return (lastTopTerm != nil && lastTopTerm === term2) ? "R" : "L"
    }
}
