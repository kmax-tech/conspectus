import Cocoa
import ConspectusCore

// The CVS line above a previewed file: "paper.tex  1.4 — current (checked
// today 10:32)" — the direct answer to "am I looking at the current
// version?", for every preview kind (text, image, PDF, Quick Look). Shown
// only for files inside a CVS checkout; outside, the covers get the whole
// pane back. The local part comes from `readCVSStatuses` (10 ms, off
// main), the server part from the per-directory cache the yazi fetcher
// fills on entering a folder — and, when that has not happened (a file
// reached through the pane's listing, a race with the fetcher), from one
// in-process `cvs -n -q update -l` after a short grace period.

let cvsBarHeight: CGFloat = 22

extension Panel {
    /// Build the strip (hidden until a checkout file previews). Side effects:
    /// creates `cvsBar`/`cvsBarText`.
    func buildCVSBar() {
        cvsBar = NSView(frame: NSRect(x: 0, y: rightContainer.bounds.height - cvsBarHeight,
                                      width: rightContainer.bounds.width, height: cvsBarHeight))
        cvsBar.autoresizingMask = [.width, .minYMargin]
        cvsBar.wantsLayer = true
        cvsBar.isHidden = true
        cvsBarText = NSTextField(labelWithString: "")
        cvsBarText.font = terminalFont(size: 11)
        cvsBarText.lineBreakMode = .byTruncatingMiddle
        cvsBarText.frame = NSRect(x: 10, y: 0, width: cvsBar.bounds.width - 20, height: cvsBarHeight)
        cvsBarText.autoresizingMask = [.width]
        cvsBar.addSubview(cvsBarText)
        styleCVSBar()
    }

    /// Palette follow (light↔dark): opaque background, else the covered QL
    /// view bleeds through — same rule as the PDF bar.
    func styleCVSBar() {
        guard let cvsBar = cvsBar else { return }
        cvsBar.layer?.backgroundColor = nsColor(activePalette().bg).cgColor
    }

    /// Show or hide the strip and give the covers the pane minus the strip
    /// (or the whole pane). The covers keep their autoresizing masks, so a
    /// window resize preserves the top margin set here. Side effects: frames
    /// of every cover and the QL view.
    func setCVSBarVisible(_ visible: Bool) {
        guard cvsBar.isHidden == visible else { return }
        cvsBar.isHidden = !visible
        var area = rightContainer.bounds
        if visible { area.size.height -= cvsBarHeight }
        for v in [preview, pdfPane, textPane, imageView, folderScroll] as [NSView?] {
            v?.frame = area
        }
    }

    /// Fill the line for `path` and show the strip; hide it for a file
    /// outside any checkout. Runs the directory read off main; a newer hover
    /// (`gen`) drops the result. When the server part is missing or stale,
    /// `scheduleCVSRemoteCheck` fetches it and this re-runs.
    /// Side effects: see `setCVSBarVisible`; may spawn cvs via the schedule.
    func updateCVSBar(for path: String, generation gen: Int) {
        let dir = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self, self.isCurrentListing(gen) else { return }
            guard let state = readCVSStatuses(in: dir) else {
                DispatchQueue.main.async { if self.isCurrentListing(gen) { self.setCVSBarVisible(false) } }
                return
            }
            for line in state.malformed { warn("conspectus: \(dir)/CVS/Entries: unparseable line: \(line)") }
            let now = Date()
            var remote = readCVSRemoteCache(for: dir, cacheDir: cvsRemoteCacheDir)
            if let r = remote, let ttl = cvsRemoteTTL, !r.isFresh(now: now, ttl: ttl, errorTTL: cvsRemoteErrorTTL) {
                remote = nil   // stale: say "not checked yet" and ask again below
            }
            var local = state.statuses[name] ?? .clean
            if local == .clean, remote?.needsUpdate.contains(name) == true { local = .needsUpdate }
            let file = CVSFileState(name: name, revision: state.entries.entries[name]?.revision,
                                    local: local, remote: remote, remoteEnabled: cvsRemoteTTL != nil)
            let line = cvsFileLine(file, now: now)
            DispatchQueue.main.async {
                guard self.isCurrentListing(gen), self.previewAttached else { return }
                self.renderCVSBar(line)
                self.setCVSBarVisible(true)
                if remote == nil, cvsRemoteTTL != nil { self.scheduleCVSRemoteCheck(dir: dir, path: path, generation: gen) }
            }
        }
    }

    /// Head in the foreground color, verdict in the sign's color.
    private func renderCVSBar(_ line: CVSFileLine) {
        let pal = activePalette()
        let font = terminalFont(size: 11)
        let out = NSMutableAttributedString(string: line.head + "  — ", attributes: [
            .font: font, .foregroundColor: nsColor(pal.fg)])
        let color = line.status == .clean ? nsColor(pal.fg).withAlphaComponent(listingDimAlpha)
                                          : cvsSignColor(line.status, pal)
        out.append(NSAttributedString(string: line.verdict, attributes: [.font: font, .foregroundColor: color]))
        cvsBarText.attributedStringValue = out
    }

    /// The server part is missing for `dir`: wait a moment (the yazi fetcher
    /// usually lands within ~0.3 s of entering a folder, and its result is
    /// what we want to reuse), re-read the cache, and only if it is still
    /// missing run the dry run here — once per directory at a time, written
    /// to the same cache the fetcher uses. Either way the line re-renders if
    /// the hover is still current. Side effects: may spawn cvs, writes the
    /// cache, `cvsRemoteInFlight`.
    func scheduleCVSRemoteCheck(dir: String, path: String, generation gen: Int) {
        guard !cvsRemoteInFlight.contains(dir) else { return }
        cvsRemoteInFlight.insert(dir)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self = self else { return }
            DispatchQueue.global(qos: .utility).async {
                let now = Date()
                let cached = readCVSRemoteCache(for: dir, cacheDir: cvsRemoteCacheDir)
                if cached == nil || !(cached!.isFresh(now: now, ttl: cvsRemoteTTL ?? 0, errorTTL: cvsRemoteErrorTTL)) {
                    let result = runCVSDryRun(in: dir)
                    do {
                        try writeCVSRemoteCache(result, for: dir, cacheDir: cvsRemoteCacheDir)
                    } catch {
                        warn("conspectus: cannot write \(cvsRemoteCacheDir): \(error.localizedDescription)")
                    }
                }
                DispatchQueue.main.async {
                    self.cvsRemoteInFlight.remove(dir)
                    // Re-render whatever file is hovered now, if still in this
                    // directory — the cache answers for the whole directory.
                    if self.isCurrentListing(gen), self.previewAttached {
                        self.updateCVSBar(for: path, generation: gen)
                    }
                }
            }
        }
    }
}
