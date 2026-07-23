import Cocoa
import Quartz
import ConspectusCore

// The preview pipeline: FIFO reader -> update() -> Quick Look (debounced) or
// the async folder listing; plus click-to-cd on folder rows.

extension Panel {
    /// Replace the `QLPreviewView` with a fresh instance, keeping frame and
    /// visibility. A `QLPreviewView` closes itself (its remote Quick Look
    /// extension goes away) when it leaves the window hierarchy or spends time
    /// hidden; setting `previewItem` on a closed view aborts the app with a
    /// QuickLook assertion — rebuilding is the only safe way back.
    func rebuildPreview() {
        let fresh = IntentFocusPreviewView(frame: preview.frame, style: .normal) ?? IntentFocusPreviewView()
        fresh.autoresizingMask = [.width, .height]
        fresh.isHidden = preview.isHidden
        rightContainer.replaceSubview(preview, with: fresh)
        preview = fresh
    }

    func startFifoReader() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var warnedOpenFailure = false
            while true {
                // O_RDWR: opening a FIFO read-write never blocks waiting for a
                // writer and never sees EOF between writers — the reader can't
                // wedge in open() if the FIFO is unlinked underneath it.
                let fd = open(fifoPath, O_RDWR)
                guard fd >= 0, let f = fdopen(fd, "r") else {
                    if fd >= 0 { close(fd) }
                    // FIFO gone/broken. Deliberate policy: warn once (not every
                    // 100ms) and keep retrying — the preview degrades, the app
                    // stays usable.
                    if !warnedOpenFailure {
                        warnedOpenFailure = true
                        warn("conspectus: cannot open FIFO \(fifoPath) "
                             + "(\(String(cString: strerror(errno)))) — preview updates suspended, retrying")
                    }
                    usleep(100_000); continue
                }
                warnedOpenFailure = false
                var buf: UnsafeMutablePointer<CChar>? = nil
                var cap = 0
                while getline(&buf, &cap, f) > 0 {
                    guard let b = buf else { continue }
                    let s = String(cString: b).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !s.isEmpty { self?.update(s) }
                }
                free(buf); buf = nil; cap = 0
                fclose(f)
            }
        }
    }

    // MARK: NSTextViewDelegate — click a folder row in the listing.
    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        guard let url = link as? URL else { return false }
        navigateYazi(to: url.path)
        return true
    }

    /// Ask the yazi pane(s) to cd — the same `panesync-cd` DDS broadcast the
    /// `=` key uses; the panesync plugin (guarded by CONSPECTUS_PEER) follows.
    /// Works from outside yazi without a YAZI_ID (verified). In triple mode
    /// both panes follow — the `=` semantics. yazi then publishes new hover
    /// events, so the preview updates to the entered directory by itself.
    /// Side effects: spawns `ya` via a login shell.
    func navigateYazi(to dir: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", "ya pub-to 0 panesync-cd --str \"$CONSPECTUS_CLICK_DIR\""]
        var env = ProcessInfo.processInfo.environment
        env["CONSPECTUS_CLICK_DIR"] = dir
        p.environment = env
        p.terminationHandler = { proc in
            if proc.terminationStatus != 0 {
                warn("conspectus: ya pub-to failed (exit \(proc.terminationStatus)) — "
                     + "click-to-cd needs yazi's panesync plugin")
            }
        }
        do {
            try p.run()
        } catch {
            warn("conspectus: cannot spawn ya for click-to-cd: \(error.localizedDescription)")
        }
    }

    func styleFolder() {
        guard let folderScroll = folderScroll, let folderText = folderText else { return }
        let pal = activePalette()
        folderScroll.drawsBackground = true
        folderScroll.backgroundColor = nsColor(pal.bg)
        folderText.drawsBackground = true
        folderText.backgroundColor = nsColor(pal.bg)
    }

    func update(_ path: String) {
        var d: ObjCBool = false
        // The hovered path can already be gone (fast navigation, deletion in
        // another pane). Deliberate policy: keep showing the previous preview
        // rather than flashing an error for a transient race.
        guard FileManager.default.fileExists(atPath: path, isDirectory: &d) else { return }
        let dir = d.boolValue
        lastPath = path
        let gen = bumpListingGeneration()   // any hover cancels in-flight folder loads
        DispatchQueue.main.async {
            // Preview detached: rightContainer is out of the window and its
            // QLPreviewView has auto-closed. Touching it would abort the app
            // (QuickLook assertion), so skip the view work — lastPath keeps
            // tracking, and attachPreview restores the preview from it.
            if !self.previewAttached { return }
            if dir {
                self.showFolder(path, generation: gen)
            } else {
                // DEBOUNCE the Quick Look request: racing through hundreds of
                // files must not hammer the QL service with every intermediate
                // item — that can wedge the remote extension into a permanent
                // spinner. Only the hover the user settles on (~120ms) is
                // requested; until then the current pane content stays.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                    guard self.isCurrentListing(gen), self.previewAttached else { return }
                    self.preview.previewItem = URL(fileURLWithPath: path) as QLPreviewItem
                    self.preview.refreshPreviewItem()
                    self.folderScroll.isHidden = true   // uncover the preview
                }
            }
        }
    }

    /// Swap the right pane to the folder listing and load it off the main
    /// thread (mirrors Quick Look, which is asynchronous by design). The
    /// previous listing stays visible until the new one lands — Finder-style,
    /// no white flash, no main-thread hitch.
    ///
    /// The QLPreviewView is COVERED by the opaque listing, never hidden:
    /// hiding it triggers QL's _teardownScrollers, which can crash in KVO
    /// removeObserver when its internal bindings are torn (seen in the wild),
    /// and a hidden view also auto-closes its remote extension (the blank-
    /// preview class of bugs). Covering sidesteps all of it.
    func showFolder(_ path: String, generation gen: Int) {
        folderScroll.isHidden = false   // opaque — covers the always-alive preview
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let contents = loadFolder(path, cap: folderListingCap)
            // Navigated on already? Skip the attributed-string build entirely.
            guard self.isCurrentListing(gen) else { return }
            let listing = renderListing(contents, in: path)
            DispatchQueue.main.async {
                // Re-check: a newer hover may have won while we rendered.
                guard self.isCurrentListing(gen) else { return }
                self.folderText.textStorage?.setAttributedString(listing)
                self.folderText.scroll(NSPoint.zero)
            }
        }
    }
}
