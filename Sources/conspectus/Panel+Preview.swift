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

    // MARK: NSTextViewDelegate — click a row in the folder listing.
    // Both cases just hand the path to yazi and let the normal hover pipeline
    // do the rest: a folder is entered (cd), a file is revealed (cursor moves
    // onto it) — which fires a hover and previews it. Symmetric, no special
    // preview handling here.
    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        guard let url = link as? URL else { return false }
        sendToYazi(url.path, action: url.hasDirectoryPath ? "cd" : "reveal")
        return true
    }

    /// Find the `ya` CLI once through a login shell (the app inherits no
    /// useful PATH when launched from Spotlight/Hammerspoon) and cache it in
    /// `yaPath`, so every click can spawn `ya` directly — the ~150ms+ shell
    /// startup is paid once here instead of on each click.
    /// Side effects: spawns a login shell, sets `yaPath`, warns if `ya` is missing.
    func resolveYaPath() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/zsh")
            p.arguments = ["-lc", "command -v ya"]
            let out = Pipe()
            p.standardOutput = out
            do {
                try p.run()
                let data = out.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                let found = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if p.terminationStatus == 0, !found.isEmpty {
                    DispatchQueue.main.async { self?.yaPath = found }
                } else {
                    warn("conspectus: `ya` not found on the login-shell PATH — "
                         + "click-to-navigate will fall back to a slow shell per click")
                }
            } catch {
                warn("conspectus: cannot resolve `ya`: \(error.localizedDescription)")
            }
        }
    }

    /// Broadcast a path to the yazi pane(s) over the DDS — `cd` enters a
    /// directory, `reveal` moves the cursor onto a file (the bundled
    /// conspectus.yazi plugin, guarded by CONSPECTUS_PEER, subscribes to
    /// `panesync-<action>`). Works from outside yazi without a YAZI_ID. yazi
    /// then emits a hover event, so the preview updates by itself — same path
    /// as any keyboard navigation. In triple mode both panes follow.
    /// Side effects: spawns `ya` (directly via the cached `yaPath`; through a
    /// login shell only if resolution hasn't landed or failed).
    func sendToYazi(_ path: String, action: String) {
        let p = Process()
        if let ya = yaPath {
            p.executableURL = URL(fileURLWithPath: ya)
            p.arguments = ["pub-to", "0", "panesync-\(action)", "--str", path]
        } else {
            // `ya` not resolved (yet) — pay the slow login shell rather than
            // drop the click.
            p.executableURL = URL(fileURLWithPath: "/bin/zsh")
            p.arguments = ["-lc", "ya pub-to 0 panesync-\(action) --str \"$CONSPECTUS_CLICK_PATH\""]
            var env = ProcessInfo.processInfo.environment
            env["CONSPECTUS_CLICK_PATH"] = path
            p.environment = env
        }
        p.terminationHandler = { proc in
            if proc.terminationStatus != 0 {
                warn("conspectus: ya pub-to failed (exit \(proc.terminationStatus)) — "
                     + "click-to-navigate needs the bundled conspectus.yazi plugin")
            }
        }
        do {
            try p.run()
        } catch {
            warn("conspectus: cannot spawn ya for click-to-navigate: \(error.localizedDescription)")
        }
    }

    func styleFolder() {
        guard let folderScroll = folderScroll, let folderText = folderText else { return }
        let pal = activePalette()
        folderScroll.drawsBackground = true
        folderScroll.backgroundColor = nsColor(pal.bg)
        folderText.drawsBackground = true
        folderText.backgroundColor = nsColor(pal.bg)
        pdfView?.backgroundColor = nsColor(pal.bg)   // letterbox around pages
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
                // requested; until then the current pane content stays. This
                // deliberately starves during machine-speed event streams (fzf
                // focus flips while rg is still streaming): nothing meaningful
                // is on screen long enough to preview, and a mid-churn
                // "max-latency" render was tried and REVERTED — even ~2
                // requests/s of fresh PDFs wedged QL and stalled the main
                // thread (see NOTES).
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                    guard self.isCurrentListing(gen), self.previewAttached else { return }
                    self.requestFilePreview(path)
                }
            }
        }
    }

    /// Route a settled file hover to the right preview: PDFs go to the native
    /// PDFKit view ("perlege light" — page-wise, perlege keys, none of the
    /// Quick Look fragility), everything else to Quick Look. The PDF view is
    /// ours, so hiding it is safe; the QL view below stays alive and covered.
    func requestFilePreview(_ path: String) {
        if pdfPreviewMode != "ql", path.lowercased().hasSuffix(".pdf") {
            let url = URL(fileURLWithPath: path)
            if pdfView.document?.documentURL != url {   // dedup, mirrors the QL check
                logEvent("requestPDFPreview \(path)")
                pdfView.document = PDFDocument(url: url)
            }
            pdfView.isHidden = false
            folderScroll.isHidden = true
            return
        }
        pdfView.isHidden = true
        requestQLPreview(path)
    }

    /// Point Quick Look at `path` and uncover the preview. Main thread only.
    /// Duplicate hover writes are dropped: two plugins can feed the FIFO
    /// (bundled + dotfiles qlpeek), and the event log proved the second write
    /// often lands outside the debounce window — re-requesting the item the
    /// uncovered preview already shows would only double the QL churn.
    func requestQLPreview(_ path: String) {
        if folderScroll.isHidden, preview.previewItem?.previewItemURL?.path == path {
            logEvent("requestQLPreview dedup \(path)")
            return
        }
        logEvent("requestQLPreview \(path)")
        preview.previewItem = URL(fileURLWithPath: path) as QLPreviewItem
        preview.refreshPreviewItem()
        folderScroll.isHidden = true   // uncover the preview
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
        logEvent("showFolder \(path)")
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
