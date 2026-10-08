import Cocoa
import SwiftTerm
import ConspectusCore

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

    /// ⌘R — theme reload: ask every yazi pane (DDS broadcast) to quit so it
    /// can be relaunched with the CURRENT theme. yazi picks its Catppuccin
    /// flavor only at startup (OSC 11), so a live light↔dark switch leaves a
    /// running yazi in the old flavor — this is the graceful nudge. The
    /// bundled plugin refuses while file tasks run (quitting would abort
    /// them) and says so in yazi; then nothing restarts and the arm window
    /// below just expires. Side effects: broadcasts over the DDS, arms the
    /// restart window.
    @objc func reloadYaziPanes() {
        yaziRestartArmedUntil = Date().addingTimeInterval(4)   // idle quits arrive well within this
        sendToYazi("-", action: "restart")                     // body unused by the subscriber
        logEvent("yazi theme reload requested")
    }

    /// Replace a quit yazi with a fresh instance in the SAME pane (the armed
    /// theme-reload path). cwd restore: the left pane's yazi wrote its cwd on
    /// quit (--cwd-file), the second pane has no such file — both fall back
    /// to the last hovered dir. Side effects: swaps the terminal view in the
    /// pane container, spawns a new yazi, moves focus into it.
    func relaunchYaziPane(left: Bool) {
        guard let pane = left ? termPane : term2Pane else { return }
        let fresh = makeTerm()
        (left ? term : term2)?.removeFromSuperview()
        fresh.frame = pane.bounds.insetBy(dx: termPadding, dy: termPadding)
        fresh.autoresizingMask = [.width, .height]
        pane.addSubview(fresh)
        if left { term = fresh } else { term2 = fresh }
        let dir = left
            ? resolveStart(nil, lastCwdFile: lastCwdPath, home: currentYaziDir()).path
            : currentYaziDir()
        launch(fresh, extraEnv: ["QLPEEK_FIFO": fifoPath,
                                 "CONSPECTUS_PEER": left ? "L" : "R",
                                 "CONSPECTUS_NVIM": nvimSocketPath,
                                 "CONSPECTUS_TABS_FILE": left ? tabsFileL : tabsFileR,
                                 // a ⌘R relaunch ALWAYS restores — the plugin
                                 // snapshotted the tabs right before quitting
                                 "CONSPECTUS_TABS_RESTORE": "1"],
               rememberCwd: left, startIn: dir)
        window.makeFirstResponder(fresh)
        // A fresh yazi starts with an empty yank buffer — drop the bar's copy
        // of the old one. If the session plugin restores the buffer, its yank
        // event refills the bar; stale is the one state this must never show.
        yankChanged("copy:")
        logEvent("yazi pane relaunched (\(left ? "L" : "R")) in \(dir)")
    }

    // MARK: LocalProcessTerminalViewDelegate
    func processTerminated(source: TerminalView, exitCode: Int32?) {
        DispatchQueue.main.async {
            let restarting = Date() < self.yaziRestartArmedUntil
            if source === self.term {
                if restarting { self.relaunchYaziPane(left: true); return }
                unlink(fifoPath); unlink(nvimSocketPath)   // clean up both channels
                NSApp.terminate(nil)                       // left pane quit -> close app
            } else if source === self.term2 {
                if restarting { self.relaunchYaziPane(left: false); return }
                self.removeSecondPane()                  // second pane's yazi quit -> collapse
            } else if source === self.editorTerm {
                self.removeEditorPane()                  // nvim quit (:qa) -> collapse the editor (⌘I re-adds)
            } else if source === self.bottomTerm {
                self.closeBottomTerminal()               // `exit` in the shell -> collapse panel
            }
        }
    }
    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
}
