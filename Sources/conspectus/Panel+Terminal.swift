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
    /// `lcvs [-follow <fifo>] <path>` in `dir` (lcvs walks up to the CVS/Root
    /// marker and lands on the item). With the follow channel up, every
    /// directory yazi enters afterwards is sent to lazycvs
    /// (`followInLazycvs`). Quitting lazycvs normally closes the panel; if
    /// lcvs fails (not on PATH, not built, too old for -follow) its error
    /// stays visible above a shell in `dir`. An already open panel is
    /// replaced — the panel is a fresh shell per open by design. Side
    /// effects: kills a running panel shell, creates the follow FIFO, spawns
    /// lcvs.
    func openLazycvs(in dir: String, at path: String) {
        closeBottomTerminal()
        let follow = openLazycvsFollow() ? ["-follow", lazycvsFollowPath] : []
        lazycvsFollowedDir = isDirectory(path) ? path : (path as NSString).deletingLastPathComponent
        startBottomTerminal(script: "cd \"$1\" && shift && \(lazycvsCommand) \"$@\" && exit; exec zsh -i",
                            args: [dir] + follow + [path],
                            height: outerSplit.frame.height * lazycvsPanelShare)
    }

    /// Context menu → Open in lazygit: the terminal panel opens running
    /// `lazygit -p <root> [-f <item>]` in `root` — filter mode on the clicked
    /// file or folder (`lazygitArguments`), the plain repository view for the
    /// root itself. The git twin of `openLazycvs` without the follow channel:
    /// lazygit has no mode for a root that moves with yazi. Quitting lazygit
    /// closes the panel; if it fails (not installed, not a repository) its
    /// error stays visible above a shell in `root`. An open panel is
    /// replaced. Side effects: kills a running panel shell, spawns lazygit.
    func openLazygit(in root: String, at path: String) {
        closeBottomTerminal()
        startBottomTerminal(script: "cd \"$1\" && shift && \(lazygitCommand) \"$@\" && exit; exec zsh -i",
                            args: [root] + lazygitArguments(root: root, item: path),
                            height: outerSplit.frame.height * lazycvsPanelShare)
    }

    /// Create the lazycvs follow FIFO and hold its write end. Non-blocking:
    /// the open must not wait for lazycvs, and a write must never stall the
    /// main thread if lazycvs stops reading. Returns false (lazycvs then runs
    /// without following) after warning once on stderr. Side effects: FIFO
    /// on disk, `lazycvsFollowFD`.
    func openLazycvsFollow() -> Bool {
        unlink(lazycvsFollowPath)
        guard mkfifo(lazycvsFollowPath, 0o600) == 0 else {
            warn("conspectus: mkfifo(\(lazycvsFollowPath)) failed: \(String(cString: strerror(errno))) — lazycvs will not follow yazi")
            return false
        }
        let fd = open(lazycvsFollowPath, O_RDWR | O_NONBLOCK)
        guard fd >= 0 else {
            warn("conspectus: open(\(lazycvsFollowPath)) failed: \(String(cString: strerror(errno))) — lazycvs will not follow yazi")
            unlink(lazycvsFollowPath)
            return false
        }
        lazycvsFollowFD = fd
        return true
    }

    /// Close and remove the follow FIFO (panel closed, lazycvs gone).
    /// Side effects: closes the fd, unlinks the FIFO.
    func closeLazycvsFollow() {
        guard lazycvsFollowFD >= 0 else { return }
        close(lazycvsFollowFD)
        lazycvsFollowFD = -1
        lazycvsFollowedDir = nil
        unlink(lazycvsFollowPath)
    }

    /// A yazi hover while lazycvs follows: send the hovered item's directory
    /// — the dir yazi is in, as in `currentYaziDir` — when it changed.
    /// lazycvs makes every followed checkout directory its root and
    /// ignores directories outside any checkout. A full pipe
    /// (lazycvs not reading, e.g. it exited into the fallback shell) drops
    /// the line: deliberate, the next directory change is what matters.
    /// Side effects: writes to the follow FIFO, stderr on a real failure.
    func followInLazycvs(hover path: String) {
        guard lazycvsFollowFD >= 0, path.hasPrefix("/") else { return }
        let dir = (path as NSString).deletingLastPathComponent
        guard dir != lazycvsFollowedDir else { return }
        lazycvsFollowedDir = dir
        let line = Array((dir + "\n").utf8)
        if write(lazycvsFollowFD, line, line.count) < 0 && errno != EAGAIN {
            warn("conspectus: lazycvs follow write failed: \(String(cString: strerror(errno))) — follow stopped")
            closeLazycvsFollow()
        }
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

    /// VCS Update… (⌥⌘U on the dir yazi is in, or the context menu on an
    /// item's checkout or repository dir): the terminal panel runs
    /// `cvsUpdateScript` in a CVS checkout — dry run first, the real update
    /// only after a `y` — or `gitUpdateScript` in a git repository — fetch
    /// and the incoming log first, `git pull --ff-only` only after a `y`. A
    /// directory that is both is answered as CVS, like the line. An open
    /// panel is replaced, like for lazycvs. Outside both: beep + stderr,
    /// nothing runs. Side effects: kills a running panel shell, drops the
    /// cached server check (the run supersedes it, and an update changes
    /// exactly what it recorded), spawns zsh with cvs or git.
    func openVCSUpdate(in dir: String) {
        let script: String, key: String, cache: String
        if cvsWorkingDir(for: dir) != nil {
            (script, key, cache) = (cvsUpdateScript, dir, cvsRemoteCacheDir)
        } else if let root = gitWorkingDir(for: dir) {
            (script, key, cache) = (gitUpdateScript, root, gitRemoteCacheDir)
        } else {
            NSSound.beep()
            warn("conspectus: VCS Update — \(dir) is neither a CVS checkout (no CVS/Root) nor in a git repository")
            return
        }
        closeBottomTerminal()
        // Deliberate try?: no cache file yet is the normal case.
        try? FileManager.default.removeItem(atPath: remoteCachePath(for: key, cacheDir: cache))
        startBottomTerminal(script: script, args: [key],
                            height: outerSplit.frame.height * lazycvsPanelShare)
    }

    /// ⌥⌘U — VCS Update… for the directory the active yazi pane is in.
    @objc func vcsUpdateHere() { openVCSUpdate(in: currentYaziDir()) }

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
        // The panel is an editor-style terminal: opened for one quick command,
        // closed again. TERM_PROGRAM names us (not the terminal conspectus was
        // launched from), so the dotfiles' zshrc gives it the same lightweight
        // shell as VS Code's and Zed's panels (no fzf-tab, no p10k, no
        // highlighting) — see the "editor terminal lightweight mode" block
        // in ~/.zshrc.
        env["TERM_PROGRAM"] = "conspectus"
        t.startProcess(executable: "/bin/zsh",
                       args: ["-l", "-c", script, "zsh"] + args,
                       environment: env.map { "\($0.key)=\($0.value)" })
        window.makeFirstResponder(t)
    }

    /// Close the bottom terminal and kill its shell (a fresh one is started
    /// per open — that is how the panel "follows" yazi's dir).
    func closeBottomTerminal() {
        guard let t = bottomTerm else { return }
        closeLazycvsFollow()
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
                unlink(fifoPath); unlink(nvimSocketPath); unlink(lazycvsFollowPath)   // clean up all channels
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

/// The panel script behind CVS Update… ($1 = the directory). Recursive from
/// there, as cvs is by default. Step one is the dry run `cvs -n -q update -d`
/// — one line per file that differs locally or on the server (`U`/`P` =
/// newer on the server, `M`, `A`, `R`, `C`, `?`), streamed while it runs;
/// step two, only after `y`, the real `cvs -q update -d -P` (flags as
/// lazycvs uses them: new dirs come along, empty ones are pruned). cvs exits
/// 1 already when a file would conflict, so a non-zero status alone only
/// gets a visible note; an aborted cvs (`[update aborted]`: server
/// unreachable, no login) stops before the question. Any key closes the
/// panel at the end.
private let cvsUpdateScript = """
    cd "$1" || { read -k1 "?(any key closes)"; exit 1 }
    close() { echo; read -k1 "?(any key closes)"; exit $1 }
    print -P "%B$ cvs -n -q update -d%b   in ${PWD/#$HOME/~}"
    log=$(mktemp -t conspectus-cvs) || close 1
    cvs -n -q update -d 2>&1 | tee "$log"; s=${pipestatus[1]}
    if grep -q 'update aborted]' "$log"; then print "\ncvs failed (exit $s) — nothing updated"; rm -f "$log"; close $s; fi
    (( s != 0 )) && print "\n(cvs exit $s: conflicts or warnings above)"
    if [[ ! -s $log ]]; then print "Up to date: no local or server changes."; rm -f "$log"; close 0; fi
    rm -f "$log"
    echo
    if read -q "?Update now (cvs -q update -d -P)? [y/N] "; then
        echo; print -P "%B$ cvs -q update -d -P%b"
        cvs -q update -d -P; s=$?
        (( s != 0 )) && print "\n(cvs exit $s: conflicts or errors above)"
        close $s
    fi
    close 0
    """

/// The panel script behind VCS Update… in a git repository ($1 = the
/// repository root). Step one: `git fetch` (a human may answer a prompt
/// here, unlike the line's batch fetch), then the local changes, the
/// ahead/behind counts against the upstream branch and the incoming
/// commits with their files (`git log --stat HEAD..@{u}`); step two, only
/// after `y`, `git pull --ff-only` — never a merge commit from a panel: if
/// the branch has diverged, git says so and nothing moves. No upstream or a
/// failed fetch stops before the question. Any key closes the panel.
private let gitUpdateScript = """
    cd "$1" || { read -k1 "?(any key closes)"; exit 1 }
    close() { echo; read -k1 "?(any key closes)"; exit $1 }
    print -P "%B$ git fetch%b   in ${PWD/#$HOME/~}"
    if ! up=$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>&1); then
        print "no upstream branch: $up"; close 1
    fi
    git fetch 2>&1 || { print "\ngit fetch failed — nothing updated"; close 1 }
    counts=$(git rev-list --left-right --count 'HEAD...@{u}') || close 1
    ahead=${counts%%[[:space:]]*}; behind=${counts##*[[:space:]]}
    changes=$(git status --short)
    [[ -n $changes ]] && { print "\nLocal changes, not committed:"; print -r -- "$changes" }
    if (( behind == 0 )); then
        if (( ahead > 0 )); then print "\nUp to date with $up; $ahead commit(s) to push."
        else print "\nUp to date with $up."; fi
        close 0
    fi
    echo
    print -P "%B$ git log --stat HEAD..$up%b   ($behind commit(s) behind)"
    git --no-pager log --stat --format='%h %ad %an  %s' --date=short "HEAD..$up"
    echo
    if read -q "?Pull now (git pull --ff-only)? [y/N] "; then
        echo; print -P "%B$ git pull --ff-only%b"
        git pull --ff-only; s=$?
        (( s != 0 )) && print "\n(git exit $s: local commits or changes in the way — see above)"
        close $s
    fi
    close 0
    """
