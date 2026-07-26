import Cocoa
import SwiftTerm

// Bottom terminal panel (⌘J) — a plain zsh in the dir yazi is visiting.
// Deliberately no live cd-follow (typing `cd` into a running interactive
// shell could clobber the user's input): closing (⌘J, ⌘W, or `exit`) kills
// the shell, reopening starts a fresh one in the current yazi dir. Also home
// of the terminal-process lifecycle delegate.

extension Panel {
    @objc func toggleBottomTerminal() { bottomTerm == nil ? openBottomTerminal() : closeBottomTerminal() }

    /// ⌘W: close the terminal panel if open; a no-op otherwise (never closes
    /// the window — the "close tab" habit must stay safe).
    @objc func closeTerminalPanel() { closeBottomTerminal() }

    /// The directory currently visited in the active yazi pane, derived from
    /// the last hovered path — hover events always come from the listing of
    /// the directory containing them. Falls back to the start dir before the
    /// first hover.
    func currentYaziDir() -> String {
        guard let p = lastPath else { return startPath }
        return (p as NSString).deletingLastPathComponent
    }

    /// Open the bottom terminal: a fresh interactive login zsh in the current
    /// yazi dir. A failed cd prints its error into the terminal itself and
    /// the shell still starts (visible, not swallowed).
    func openBottomTerminal() {
        guard bottomTerm == nil else { return }
        let t = makeTerm()
        bottomTerm = t
        let pane = makeTermPane(t)
        bottomPane = pane
        outerSplit.addSubview(pane)
        layoutOuterPanes(terminalHeight: termPanelHeight)   // frames BEFORE startProcess so cols/rows fit
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"; env["COLORTERM"] = "truecolor"
        t.startProcess(executable: "/bin/zsh",
                       args: ["-l", "-c", "cd \"\(currentYaziDir())\"; exec zsh -i"],
                       environment: env.map { "\($0.key)=\($0.value)" })
        window.makeFirstResponder(t)
    }

    /// Close the bottom terminal and kill its shell (a fresh one is started
    /// per open — that is how the panel "follows" yazi's dir).
    func closeBottomTerminal() {
        guard let t = bottomTerm else { return }
        bottomTerm = nil
        bottomPane?.removeFromSuperview()
        bottomPane = nil
        t.terminate()
        layoutOuterPanes()
        window.makeFirstResponder(term)
    }

    // MARK: LocalProcessTerminalViewDelegate
    func processTerminated(source: TerminalView, exitCode: Int32?) {
        DispatchQueue.main.async {
            if source === self.term {
                unlink(fifoPath); unlink(nvimSocketPath)   // clean up both channels
                NSApp.terminate(nil)                       // left pane quit -> close app
            } else if source === self.term2 {
                self.removeSecondPane()                  // second pane's yazi quit -> collapse
            } else if source === self.editorTerm {
                self.respawnEditor()                     // the editor is a fixture of ide mode -> bring it back
            } else if source === self.bottomTerm {
                self.closeBottomTerminal()               // `exit` in the shell -> collapse panel
            }
        }
    }
    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
}
