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
        startBottomTerminal(script: "cd \"$1\"; exec zsh -i", args: [currentYaziDir()],
                            height: termPanelHeight)
    }

    /// Context menu → Open in lazycvs: the terminal panel opens running
    /// `lcvs <path>` in `dir` (lcvs walks up to the CVS/Root marker and lands
    /// on the item). Quitting lazycvs normally closes the panel; if lcvs
    /// fails (not on PATH, not built) its error stays visible above a shell
    /// in `dir`. An already open panel is replaced — the panel is a fresh
    /// shell per open by design. Side effects: kills a running panel shell,
    /// spawns lcvs.
    func openLazycvs(in dir: String, at path: String) {
        closeBottomTerminal()
        startBottomTerminal(script: "cd \"$1\" && \(lazycvsCommand) \"$2\" && exit; exec zsh -i",
                            args: [dir, path], height: outerSplit.frame.height * lazycvsPanelShare)
    }

    /// yazi's `E C` (FIFO `@LAZYCVS:<path>`): open lazycvs for the item if it
    /// sits in a CVS checkout; otherwise beep and say why (the context menu
    /// hides the item instead, a key cannot). Side effects: see
    /// `openLazycvs`; beep + stderr when not a checkout.
    func lazycvsRequested(_ path: String) {
        guard let dir = cvsWorkingDir(for: path) else {
            NSSound.beep()
            warn("conspectus: E C — \(path) is not in a CVS checkout (no CVS/Root)")
            return
        }
        openLazycvs(in: dir, at: path)
    }

    /// Start the panel's login zsh with `script`; `args` arrive as $1, $2, …
    /// (positional, so paths are never spliced into shell source). Side
    /// effects: adds the panel, relayouts, spawns the process, takes focus.
    func startBottomTerminal(script: String, args: [String], height: CGFloat) {
        guard bottomTerm == nil else { return }
        let t = makeTerm()
        bottomTerm = t
        let pane = makeTermPane(t)
        bottomPane = pane
        outerSplit.addSubview(pane)
        layoutOuterPanes(terminalHeight: height)   // frames BEFORE startProcess so cols/rows fit
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"; env["COLORTERM"] = "truecolor"
        t.startProcess(executable: "/bin/zsh",
                       args: ["-l", "-c", script, "zsh"] + args,
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

    /// ⌘R — theme reload on demand; the appearance observer calls the same
    /// path automatically.
    @objc func reloadYaziPanes() { requestYaziRetheme() }

    /// Theme reload: relaunch each yazi pane with the CURRENT theme. yazi
    /// picks its Catppuccin flavor only at startup (OSC 11), so a light↔dark
    /// switch leaves a running yazi in the old flavor. The relaunch waits for
    /// the pane to be idle: the bundled plugin refuses while file tasks run or
    /// a selection exists (and reports why over the FIFO); the app re-asks
    /// every few seconds until the deadline, then stops and leaves a ⌘R note
    /// in the shortcut bar. Preview and nvim are untouched. Side effects:
    /// resets the pending set and deadline, sends the first attempt.
    func requestYaziRetheme() {
        yaziRethemePending = ["L"]
        if term2 != nil { yaziRethemePending.insert("R") }
        yaziRethemeDeadline = Date().addingTimeInterval(yaziRethemeTimeout)
        yaziRethemeRefusals = [:]
        yaziRethemeNote = nil
        logEvent("yazi theme reload requested for \(yaziRethemePending.sorted())")
        attemptYaziRetheme(firstAttempt: true)
    }

    /// One attempt: arm the restart window, ask the pending pane(s) over the
    /// DDS (body "<L|R|*> <ask|quiet>" — the plugin ignores a target that is
    /// not its own, so a pane that already relaunched is not bounced again),
    /// and schedule the next attempt. A pane that quits is relaunched by
    /// `processTerminated`, which clears it from the pending set; one that
    /// refuses answers `@RESTART_REFUSED` (`yaziRethemeRefused`). Past the
    /// deadline the app stops asking and says so. Side effects: DDS publish,
    /// retry timer, shortcut bar re-render, stderr warning on give-up.
    func attemptYaziRetheme(firstAttempt: Bool) {
        yaziRethemeRetry?.cancel()
        yaziRethemeRetry = nil
        if term2 == nil { yaziRethemePending.remove("R") }   // split closed meanwhile
        guard !yaziRethemePending.isEmpty else { styleHintBar(); return }
        if Date() >= yaziRethemeDeadline {
            yaziRethemeNote = "theme changed — ⌘R re-themes yazi when you are ready"
            warn("conspectus: yazi theme reload gave up after \(Int(yaziRethemeTimeout / 60)) min "
                 + "(pane(s) \(yaziRethemePending.sorted()) stayed busy) — press ⌘R when idle")
            yaziRethemePending = []
            styleHintBar()
            return
        }
        yaziRestartArmedUntil = Date().addingTimeInterval(4)   // idle quits arrive well within this
        let target = yaziRethemePending.count == 2 ? "*" : yaziRethemePending.first!
        publishToYazi("panesync-restart", body: "\(target) \(firstAttempt ? "ask" : "quiet")")
        let retry = DispatchWorkItem { [weak self] in self?.attemptYaziRetheme(firstAttempt: false) }
        yaziRethemeRetry = retry
        DispatchQueue.main.asyncAfter(deadline: .now() + yaziRethemeRetryInterval, execute: retry)
        styleHintBar()
    }

    /// FIFO handler for `@RESTART_REFUSED:<peer>:<reason>` — the plugin would
    /// not quit. `tasks`/`selection` are transient: remember the reason for
    /// the bar, the scheduled retry does the rest. `error` (the plugin cannot
    /// read yazi's state) is final for that pane: stop asking, say so. An
    /// answer from a pane that is not pending is a protocol slip — warned,
    /// not acted on. Side effects: pending set, bar re-render, stderr.
    func yaziRethemeRefused(_ body: String) {
        let parts = body.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, yaziRethemePending.contains(parts[0]) else {
            warn("conspectus: unexpected @RESTART_REFUSED '\(body)' — ignored")
            return
        }
        let (peer, reason) = (parts[0], parts[1])
        if reason == rethemeRefusalError {
            yaziRethemePending.remove(peer)
            yaziRethemeNote = "theme reload failed — plugin could not read yazi's state; ⌘R to retry"
            warn("conspectus: yazi pane \(peer) refused the theme reload: cannot read task/selection state")
        } else {
            yaziRethemeRefusals[peer] = reason
        }
        logEvent("yazi theme reload refused by \(peer): \(reason)")
        styleHintBar()
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
        // This pane is re-themed; the last one to go ends the retries.
        yaziRethemePending.remove(left ? "L" : "R")
        yaziRethemeRefusals[left ? "L" : "R"] = nil
        if yaziRethemePending.isEmpty {
            yaziRethemeRetry?.cancel()
            yaziRethemeRetry = nil
            yaziRethemeNote = nil
        }
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
