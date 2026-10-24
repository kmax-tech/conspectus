import Cocoa
import ConspectusCore

// The VCS line above a previewed file: "paper.tex  1.4 — current (checked
// today 10:32)" in a CVS checkout, "admin.kdbx  efc8c72 30.09. 2025 —
// current (fetched today 16:01)" in a git repository — the direct answer
// to "am I looking at the current version?", for every preview kind (text,
// image, PDF, Quick Look). Shown only for files inside a checkout or
// repository; elsewhere the covers get the whole pane back. CVS: the local
// part comes from `readCVSStatuses` (10 ms, off main), the server part from
// the per-directory cache the yazi fetcher fills — or, when that has not
// happened, from one in-process `cvs -n -q update -l` after a grace period.
// git: the local part from three short git calls, the server part from one
// `git fetch` per repository, cached by repository root. A directory that
// is both (a CVS checkout inside a git repo) is answered as CVS.

let vcsBarHeight: CGFloat = 22

extension Panel {
    /// Build the strip (hidden until a versioned file previews). Side
    /// effects: creates `vcsBar`/`vcsBarText`.
    func buildVCSBar() {
        vcsBar = NSView(frame: NSRect(x: 0, y: rightContainer.bounds.height - vcsBarHeight,
                                      width: rightContainer.bounds.width, height: vcsBarHeight))
        vcsBar.autoresizingMask = [.width, .minYMargin]
        vcsBar.wantsLayer = true
        vcsBar.isHidden = true
        vcsBarText = NSTextField(labelWithString: "")
        vcsBarText.font = terminalFont(size: 11)
        vcsBarText.lineBreakMode = .byTruncatingMiddle
        vcsBarText.frame = NSRect(x: 10, y: 0, width: vcsBar.bounds.width - 20, height: vcsBarHeight)
        vcsBarText.autoresizingMask = [.width]
        vcsBar.addSubview(vcsBarText)
        styleVCSBar()
    }

    /// Palette follow (light↔dark): opaque background, else the covered QL
    /// view bleeds through — same rule as the PDF bar.
    func styleVCSBar() {
        guard let vcsBar = vcsBar else { return }
        vcsBar.layer?.backgroundColor = nsColor(activePalette().bg).cgColor
    }

    /// Show or hide the strip and give the covers the pane minus the strip
    /// (or the whole pane). The covers keep their autoresizing masks, so a
    /// window resize preserves the top margin set here. Side effects: frames
    /// of every cover and the QL view.
    func setVCSBarVisible(_ visible: Bool) {
        guard vcsBar.isHidden == visible else { return }
        vcsBar.isHidden = !visible
        var area = rightContainer.bounds
        if visible { area.size.height -= vcsBarHeight }
        for v in [preview, pdfPane, textPane, imageView, folderScroll] as [NSView?] {
            v?.frame = area
        }
    }

    /// Fill the line for `path` and show the strip; hide it for a file
    /// outside any checkout or repository. Runs the working-copy reads off
    /// main; a newer hover (`gen`) drops the result. When the server part is
    /// missing or stale, the check is scheduled and this re-runs.
    /// Side effects: see `setVCSBarVisible`; may spawn cvs or git via the schedule.
    func updateVCSBar(for path: String, generation gen: Int) {
        let dir = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self, self.isCurrentListing(gen) else { return }
            let answer: (line: VCSFileLine, remoteMissing: Bool, remoteKey: String?)?
            if let state = readCVSStatuses(in: dir) {
                answer = self.cvsLine(dir: dir, name: name, state: state)
            } else if let root = gitWorkingDir(for: dir) {
                answer = self.gitLine(root: root, dir: dir, name: name)
            } else {
                answer = nil
            }
            DispatchQueue.main.async {
                guard self.isCurrentListing(gen), self.previewAttached else { return }
                guard let a = answer else { self.setVCSBarVisible(false); return }
                self.renderVCSBar(a.line)
                self.setVCSBarVisible(true)
                if a.remoteMissing, let key = a.remoteKey {
                    self.scheduleRemoteCheck(key: key, path: path, generation: gen)
                }
            }
        }
    }

    /// The CVS line: local state from `state`, server part from the
    /// directory cache (stale → "not checked yet" and ask again). Off main.
    private func cvsLine(dir: String, name: String, state: CVSDirectoryState)
        -> (line: VCSFileLine, remoteMissing: Bool, remoteKey: String?) {
        for line in state.malformed { warn("conspectus: \(dir)/CVS/Entries: unparseable line: \(line)") }
        let now = Date()
        var remote = readCVSRemoteCache(for: dir, cacheDir: cvsRemoteCacheDir)
        if let r = remote, let ttl = cvsRemoteTTL, !r.isFresh(now: now, ttl: ttl, errorTTL: cvsRemoteErrorTTL) {
            remote = nil
        }
        var local = state.statuses[name] ?? .clean
        if local == .clean, remote?.needsUpdate.contains(name) == true { local = .needsUpdate }
        let file = CVSFileState(name: name, revision: state.entries.entries[name]?.revision,
                                local: local, remote: remote, remoteEnabled: cvsRemoteTTL != nil)
        return (cvsFileLine(file, now: now), remote == nil && cvsRemoteTTL != nil, dir)
    }

    /// The git line: local state from git itself, server part from the
    /// repository cache (stale → "not checked yet" and fetch again). nil
    /// when git cannot run (warned by `readGitFileLocal`). Off main.
    private func gitLine(root: String, dir: String, name: String)
        -> (line: VCSFileLine, remoteMissing: Bool, remoteKey: String?)? {
        guard let local = readGitFileLocal(dir: dir, name: name) else { return nil }
        let now = Date()
        var remote = readGitRemoteCache(for: root, cacheDir: gitRemoteCacheDir)
        if let r = remote, let ttl = gitRemoteTTL, !r.isFresh(now: now, ttl: ttl, errorTTL: cvsRemoteErrorTTL) {
            remote = nil
        }
        let file = GitFileState(name: name, repoPath: local.repoPath, commit: local.commit, local: local.local,
                                remote: remote, remoteEnabled: gitRemoteTTL != nil)
        return (gitFileLine(file, now: now), remote == nil && gitRemoteTTL != nil, root)
    }

    /// Head in the foreground color, verdict in the sign's color.
    private func renderVCSBar(_ line: VCSFileLine) {
        let pal = activePalette()
        let font = terminalFont(size: 11)
        let out = NSMutableAttributedString(string: line.head + "  — ", attributes: [
            .font: font, .foregroundColor: nsColor(pal.fg)])
        let color = line.status == .clean ? nsColor(pal.fg).withAlphaComponent(listingDimAlpha)
                                          : cvsSignColor(line.status, pal)
        out.append(NSAttributedString(string: line.verdict, attributes: [.font: font, .foregroundColor: color]))
        vcsBarText.attributedStringValue = out
    }

    /// The server part is missing for `key` (a CVS directory or a git
    /// repository root): wait a moment — for CVS the yazi fetcher usually
    /// lands within ~0.3 s of entering a folder, and its result is what we
    /// want to reuse — re-read the cache, and only if it is still missing
    /// run the check here, once per key at a time, written to the same cache
    /// the fetcher uses. Either way the line re-renders if the hover is still
    /// current. Side effects: may spawn cvs or git, writes the cache,
    /// `remoteInFlight`.
    func scheduleRemoteCheck(key: String, path: String, generation gen: Int) {
        guard !remoteInFlight.contains(key) else { return }
        remoteInFlight.insert(key)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self = self else { return }
            DispatchQueue.global(qos: .utility).async {
                self.refreshRemoteCache(key: key)
                DispatchQueue.main.async {
                    self.remoteInFlight.remove(key)
                    // Re-render whatever file is hovered now, if still in this
                    // directory — the cache answers for the whole directory.
                    if self.isCurrentListing(gen), self.previewAttached {
                        self.updateVCSBar(for: path, generation: gen)
                    }
                }
            }
        }
    }

    /// Run the server check for `key` unless the cache turned fresh in the
    /// meantime: CVS when `key` is a checkout directory, git otherwise. Off
    /// main. Side effects: spawns cvs or git, writes the cache.
    private func refreshRemoteCache(key: String) {
        let now = Date()
        if cvsWorkingDir(for: key) == key {
            if let c = readCVSRemoteCache(for: key, cacheDir: cvsRemoteCacheDir),
               c.isFresh(now: now, ttl: cvsRemoteTTL ?? 0, errorTTL: cvsRemoteErrorTTL) { return }
            do {
                try writeCVSRemoteCache(runCVSDryRun(in: key), for: key, cacheDir: cvsRemoteCacheDir)
            } catch {
                warn("conspectus: cannot write \(cvsRemoteCacheDir): \(error.localizedDescription)")
            }
        } else {
            if let c = readGitRemoteCache(for: key, cacheDir: gitRemoteCacheDir),
               c.isFresh(now: now, ttl: gitRemoteTTL ?? 0, errorTTL: cvsRemoteErrorTTL) { return }
            do {
                try writeGitRemoteCache(runGitRemoteCheck(in: key), for: key, cacheDir: gitRemoteCacheDir)
            } catch {
                warn("conspectus: cannot write \(gitRemoteCacheDir): \(error.localizedDescription)")
            }
        }
    }
}
