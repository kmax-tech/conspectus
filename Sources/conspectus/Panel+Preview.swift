import Cocoa
import Quartz
import SwiftTerm
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
        fresh.onFocusLeft = { [weak self] in self?.focusLeftPane() }
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
                    // Control messages, not paths: yazi bindings ask to focus the
                    // preview (l-on-a-file) or toggle markdown render↔source (M).
                    // Real hover paths are absolute (start with "/"), so the
                    // "@"-prefixed sentinels can never collide with one.
                    if s == focusPreviewSentinel {
                        DispatchQueue.main.async { self?.focusPreview() }
                    } else if s == toggleMarkdownSentinel {
                        DispatchQueue.main.async { self?.toggleMarkdownMode() }
                    } else if s == togglePinSentinel {
                        DispatchQueue.main.async { self?.togglePreviewPin() }
                    } else if s == activateSentinel {
                        DispatchQueue.main.async { self?.activateFromShell() }
                    } else if s.hasPrefix(selectedPrefix) {
                        let body = String(s.dropFirst(selectedPrefix.count))
                        DispatchQueue.main.async { self?.selectedArrived(parseSelectedPaths(body)) }
                    } else if s.hasPrefix(sortPrefix) {
                        let body = String(s.dropFirst(sortPrefix.count))
                        DispatchQueue.main.async { self?.sortChanged(body) }
                    } else if s.hasPrefix(yankPrefix) {
                        let body = String(s.dropFirst(yankPrefix.count))
                        DispatchQueue.main.async { self?.yankChanged(body) }
                    } else if s.hasPrefix(restartRefusedPrefix) {
                        let body = String(s.dropFirst(restartRefusedPrefix.count))
                        DispatchQueue.main.async { self?.yaziRethemeRefused(body) }
                    } else if s.hasPrefix(lazycvsPrefix) {
                        let path = String(s.dropFirst(lazycvsPrefix.count))
                        DispatchQueue.main.async { self?.lazycvsRequested(path) }
                    } else if s.hasPrefix(editorFilePrefix) {
                        let path = String(s.dropFirst(editorFilePrefix.count))
                        DispatchQueue.main.async { self?.editorFileHover(path) }
                    } else if !s.isEmpty {
                        DispatchQueue.main.async {
                            self?.hoverArrived(s)                            // a pending right-click menu
                            self?.followInLazycvs(hover: s)                  // lazycvs in the terminal panel
                        }
                        self?.update(s)
                    }
                }
                free(buf); buf = nil; cap = 0
                fclose(f)
            }
        }
    }

    /// FIFO handler (main thread): yazi announced its sort preference
    /// (`@SORT:` body) — the hover that follows it renders the listing in that
    /// order. A malformed body keeps the previous order and warns, never
    /// silently falls back.
    func sortChanged(_ body: String) {
        guard let sort = parseListingSort(body) else {
            warn("conspectus: malformed @SORT FIFO message '\(body)' — keeping the previous order")
            return
        }
        listingSort = sort
    }

    // MARK: NSTextViewDelegate — click a row in the folder listing.
    // Finder semantics, the same as in the yazi pane: a single click MARKS
    // the row — `reveal` in yazi (cd to the listed folder, cursor onto the
    // row), which fires a hover and previews it; a double-click ACTS — enters
    // a folder, opens a file like Enter (`listingDoubleClick`). The single
    // click is not held back to wait for a possible double: the double acts
    // on the remembered row, so the first click costs no latency.
    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        guard let url = link as? URL else { return false }
        listingClick = ListingClick(path: url.path, isDir: url.hasDirectoryPath, at: Date())
        sendToYazi(url.path, action: "reveal")
        return true
    }

    /// Second click of a double-click in the preview area (from the
    /// leftMouseDown monitor): acts on the row the first click revealed —
    /// `cd` into a folder, `panesync-act open` for a file (yazi's opener with
    /// the plugin's IDE routing, i.e. what Enter does in the pane). Only a
    /// click within the system double-click interval of a listing click
    /// counts; anything else is left alone. Returns true when it consumed the
    /// click. Side effects: DDS publish; clears `listingClick`.
    func listingDoubleClick(_ event: NSEvent) -> Bool {
        guard event.clickCount == 2, let c = listingClick else { return false }
        listingClick = nil
        guard Date().timeIntervalSince(c.at) <= NSEvent.doubleClickInterval,
              let hit = window?.contentView?.hitTest(event.locationInWindow),
              hit.isDescendant(of: rightContainer) else { return false }
        if c.isDir {
            sendToYazi(c.path, action: "cd")
        } else {
            publishToYazi("panesync-act", body: "\(paneUnder(nil)) open \(c.path)")
        }
        return true
    }

    /// Resolve a CLI on the login-shell PATH once, off the main thread (the app
    /// inherits no useful PATH from Spotlight/Hammerspoon). `then` runs on the
    /// main thread with the resolved absolute path; a missing tool warns once
    /// with `missingWarning`. Used for `ya` (clicks) and `bat` (highlighting).
    /// Side effects: spawns a login shell; calls `then` on main.
    func resolveOnLoginPath(_ cmd: String, missingWarning: String, then: @escaping (String) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/zsh")
            p.arguments = ["-lc", "command -v \(cmd)"]
            let out = Pipe()
            p.standardOutput = out
            do {
                try p.run()
                let data = out.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                let found = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if p.terminationStatus == 0, !found.isEmpty {
                    DispatchQueue.main.async { then(found) }
                } else {
                    warn(missingWarning)
                }
            } catch {
                warn("conspectus: cannot resolve `\(cmd)`: \(error.localizedDescription)")
            }
        }
    }

    /// Broadcast a path to the yazi pane(s) over the DDS — `cd` enters a
    /// directory, `reveal` moves the cursor onto a file (the bundled
    /// conspectus.yazi plugin, guarded by CONSPECTUS_PEER, subscribes to
    /// `panesync-<action>`). Works from outside yazi without a YAZI_ID. yazi
    /// then emits a hover event, so the preview updates by itself — same path
    /// as any keyboard navigation. In triple mode both panes follow.
    /// Side effects: see `publishToYazi`.
    func sendToYazi(_ path: String, action: String) {
        publishToYazi("panesync-\(action)", body: path)
    }

    /// Publish one DDS message to the yazi pane(s) — the single channel the app
    /// uses to drive yazi from AppKit (`panesync-cd` / `-reveal` for row
    /// clicks, `panesync-history` for back/forward, `panesync-restart` for the
    /// theme reload).
    /// Side effects: spawns `ya` (directly via the cached `yaPath`; through a
    /// login shell only if resolution hasn't landed or failed).
    func publishToYazi(_ message: String, body: String) {
        let p = Process()
        if let ya = yaPath {
            p.executableURL = URL(fileURLWithPath: ya)
            p.arguments = ["pub-to", "0", message, "--str", body]
        } else {
            // `ya` not resolved (yet) — pay the slow login shell rather than
            // drop the click.
            p.executableURL = URL(fileURLWithPath: "/bin/zsh")
            p.arguments = ["-lc", "ya pub-to 0 \(message) --str \"$CONSPECTUS_CLICK_PATH\""]
            var env = ProcessInfo.processInfo.environment
            env["CONSPECTUS_CLICK_PATH"] = body
            p.environment = env
        }
        p.terminationHandler = { proc in
            if proc.terminationStatus != 0 {
                warn("conspectus: ya pub-to \(message) failed (exit \(proc.terminationStatus)) — "
                     + "driving yazi from the app needs the bundled conspectus.yazi plugin")
            }
        }
        do {
            try p.run()
        } catch {
            warn("conspectus: cannot spawn ya for \(message): \(error.localizedDescription)")
        }
    }

    func styleFolder() {
        guard let folderScroll = folderScroll, let folderText = folderText else { return }
        let pal = activePalette()
        folderScroll.drawsBackground = true
        folderScroll.backgroundColor = nsColor(pal.bg)
        folderText.drawsBackground = true
        folderText.backgroundColor = nsColor(pal.bg)
        if let textScroll = textScroll, let textView = textView {
            textScroll.drawsBackground = true
            textScroll.backgroundColor = nsColor(pal.bg)
            textView.drawsBackground = true
            textView.backgroundColor = nsColor(pal.bg)
            textPane?.wantsLayer = true
            textPane?.layer?.backgroundColor = nsColor(pal.bg).cgColor
            textBar?.layer?.backgroundColor = nsColor(pal.bg).cgColor
        }
        imageView?.layer?.backgroundColor = nsColor(pal.bg).cgColor   // letterbox
        stylePDFBar()   // bar + pdf letterbox follow the palette too
        styleVCSBar()
    }

    func update(_ path: String) {
        // Pinned: ignore a hover onto a different file — the preview stays on the
        // pinned one. Same-path re-renders (attach, palette change) still pass,
        // and the mtime watch keeps refreshing the pinned file on save/rebuild.
        if previewPinned, let p = lastPath, path != p { return }
        // Location off-switch (CONSPECTUS_PREVIEW_SKIP_DIRS / ⌘⇧P): under
        // these dirs no filesystem call may run here (FIFO reader thread —
        // even the fileExists below can block for minutes on a stalled
        // network mount and would freeze every further preview update) or on
        // the main thread. The note shows immediately with zero I/O; the only
        // filesystem touch is the dir probe below, confined to its own queue.
        if pathIsUnder(path, anyOf: skipDirs) {
            lastPath = path
            let gen = bumpListingGeneration()
            DispatchQueue.main.async {
                guard self.isCurrentListing(gen), self.previewAttached else { return }
                self.stopWatchingPreviewFile()
                self.lastTextPath = nil
                logEvent("preview skipped (skip dir): \(path)")
                self.showPreviewMessage("""
                    \((path as NSString).lastPathComponent)

                    File preview is off here (network location) —
                    folders still show. Press ⌘⇧P to show file contents
                    in this folder (CONSPECTUS_PREVIEW_SKIP_DIRS).
                    """)
            }
            // Folders stay useful on a skipped mount — a listing is one capped
            // readdir, loaded off-main anyway. Probe "is it a dir?" on the
            // dedicated serial queue; a directory upgrades the note to the
            // listing, a file keeps it, and on a hung mount the probe just
            // never comes back while the note stays and the app keeps running.
            skipProbeQueue.async { [weak self] in
                guard let self = self, self.isCurrentListing(gen), isDirectory(path) else { return }
                DispatchQueue.main.async {
                    guard self.isCurrentListing(gen), self.previewAttached else { return }
                    self.showFolder(path, generation: gen)
                }
            }
            return
        }
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
                    self.requestFilePreview(path, generation: gen)
                }
            }
        }
    }

    /// mtime of `path`, or nil if it can't be stat'd (e.g. momentarily gone
    /// mid-rebuild). Pure path→mtime; no inode identity involved — which is the
    /// whole point of polling over an fd watch.
    func fileMtime(_ path: String) -> Date? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let m = attrs[.modificationDate] as? Date else { return nil }
        return m
    }

    /// Watch `path` for on-disk changes and refresh the preview when its mtime
    /// moves. Polling, not an fd watcher, ON PURPOSE: an editor saves by writing
    /// a temp and renaming over the original, and latexmk goes further — it
    /// deletes/recreates/moves the PDF several times per build, so the file is
    /// briefly *absent*. An fd watch points at one inode; the moment latexmk's
    /// new file replaces it, the fd is stale, and if the re-`open()` lands in
    /// the gap where nothing is there, the watch is lost for good (this is what
    /// bit perlege). `stat` on the path doesn't care about inodes — file gone
    /// this tick, back the next, mtime moved, we refresh. Gated to an active
    /// file preview so it stops on dir/idle. Side effects: starts a repeating
    /// main-thread timer; replaces any previous one. The 120ms debounce in
    /// `update` coalesces an editor's write bursts.
    func watchPreviewFile(_ path: String) {
        stopWatchingPreviewFile()
        guard watchEnabled else { return }
        lastPreviewMtime = fileMtime(path)
        let t = Timer(timeInterval: 0.7, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            // Only compare when the file is actually there; a nil (mid-rebuild
            // gap) is not a change — we wait for it to come back with a new mtime.
            guard let now = self.fileMtime(path) else { return }
            if now != self.lastPreviewMtime {
                self.lastPreviewMtime = now
                logEvent("preview file changed \(path)")
                self.refreshCurrentPreview()
            }
        }
        t.tolerance = 0.2   // let the scheduler coalesce; this is not latency-critical
        RunLoop.main.add(t, forMode: .common)
        previewWatchTimer = t
    }

    func stopWatchingPreviewFile() {
        previewWatchTimer?.invalidate()
        previewWatchTimer = nil
        lastPreviewMtime = nil
    }

    /// Re-render the currently-previewed file, bypassing the per-type dedups so
    /// a same-path change actually shows. Goes through `update` so the debounce
    /// and generation cancellation still apply.
    func refreshCurrentPreview() {
        guard previewAttached, let path = lastPath else { return }
        lastTextPath = nil                                             // text/markdown dedup
        pdfLoadedMtime = nil                                           // pdf dedup (url + mtime)
        update(path)
    }

    /// Hide every cover over the always-alive QL view. Each show-path calls
    /// this, then reveals exactly its own cover — so only one is ever visible,
    /// and the QL view shows when all are hidden.
    func hideAllCovers() {
        folderScroll?.isHidden = true
        pdfPane?.isHidden = true
        textPane?.isHidden = true
        imageView?.isHidden = true
    }

    /// Route a settled file hover to the right preview. Priority, all covering
    /// the always-alive QL view: text/source/notes → native NSTextView (off
    /// the fragile Quick Look path); raster images → native NSImageView; PDFs →
    /// native PDFKit view; everything else → Quick Look (fallback for the long
    /// tail). Exactly one cover shows.
    func requestFilePreview(_ path: String, generation gen: Int) {
        watchPreviewFile(path)   // live-refresh this file if it's edited on disk
        updateVCSBar(for: path, generation: gen)   // "is this the current version?" above the file
        // A different file replaces the previewed PDF → its note is no longer
        // the active one (the PDF branch below re-resolves for a new PDF).
        if activeNote != nil, activeNote?.pdf != path {
            activeNote = nil
            updateNoteButton()
        }
        // Size cap: don't hand any renderer a file big enough to wedge it
        // (hundreds of MB of JSON, a giant log) — show a note instead.
        if previewMaxBytes > 0,
           let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size]) as? Int,
           size > previewMaxBytes {
            logEvent("preview skipped (too large): \(path) \(size / 1_048_576)MB")
            showPreviewMessage("""
                \((path as NSString).lastPathComponent)

                \(size / 1_048_576) MB — too large to preview
                (limit \(previewMaxBytes / 1_048_576) MB; set CONSPECTUS_PREVIEW_MAX_MB)
                """)
            return
        }
        if isTextPreviewable(path) {
            showTextPreview(path, generation: gen)
            return
        }
        if isImagePreviewable(path) {
            showImagePreview(path, generation: gen)
            return
        }
        if pdfPreviewMode != "ql", path.lowercased().hasSuffix(".pdf") {
            let url = URL(fileURLWithPath: path)
            // Dedup keyed on URL + mtime (mirrors the QL check). The document
            // outlives hovers onto other files, so a rebuild that happened
            // while the .md next to it was shown must not hand back the old
            // pages when the hover returns.
            let mtime = fileMtime(path)
            if pdfView.document?.documentURL != url || pdfLoadedMtime != mtime {
                logEvent("requestPDFPreview \(path)")
                pdfView.document = PDFDocument(url: url)
                pdfLoadedMtime = mtime
                // New document: start at page 1 (PDFKit otherwise keeps the
                // previous scroll offset in continuous mode / on reload).
                if let first = pdfView.document?.page(at: 0) { pdfView.go(to: first) }
            }
            updatePDFBar()
            resolveNoteAsync(for: path, generation: gen)   // companion note → toolbar + ide follow
            hideAllCovers()
            pdfPane.isHidden = false
            return
        }
        hideAllCovers()
        guard quickLookEnabled else {
            // Quick Look turned off (CONSPECTUS_QUICKLOOK=off): no remote
            // extension is ever touched — the long tail just shows a note.
            showPreviewMessage("""
                \((path as NSString).lastPathComponent)

                No native preview for this type.
                Quick Look is off (CONSPECTUS_QUICKLOOK=on to enable).
                """)
            return
        }
        requestQLPreview(path)
    }

    /// Render a raster image in the native NSImageView, loaded off the main
    /// thread. Covering the QL view; already size-capped by requestFilePreview.
    func showImagePreview(_ path: String, generation gen: Int) {
        logEvent("showImagePreview \(path)")
        hideAllCovers()
        imageView.layer?.backgroundColor = nsColor(activePalette().bg).cgColor
        imageView.isHidden = false
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let img = NSImage(contentsOfFile: path)
            guard self.isCurrentListing(gen) else { return }
            DispatchQueue.main.async {
                guard self.isCurrentListing(gen), !self.imageView.isHidden else { return }
                self.imageView.image = img
            }
        }
    }

    /// Render a text/source file in the native NSTextView, loaded off the main
    /// thread (mirrors showFolder). Syntax-highlighted via `bat` (parsed from
    /// ANSI, themed to the palette); plain themed monospace if `bat` isn't
    /// resolved yet or is missing. Covering the QL view; already size-capped by
    /// requestFilePreview. Dedup: if the view already shows this path, skip.
    func showTextPreview(_ path: String, generation gen: Int) {
        if !textPane.isHidden, lastTextPath == path { return }
        logEvent("showTextPreview \(path)")
        hideAllCovers()
        textPane.isHidden = false   // cover the always-alive QL view
        lastTextPath = path
        let font = terminalFont(size: 13)
        let pal = activePalette()          // snapshot on main
        let fg = nsColor(pal.fg)
        let bat = batPath
        let theme = batTheme()
        // Markdown in render mode → native document render (swift-markdown →
        // themed NSAttributedString: serif, tables, code chips). Else → bat
        // (highlighted source, ANSI). Everything else → bat too.
        let isMd = isMarkdownFile(path)
        // Toolbar (rendered↔source toggle) only for markdown; give the scroll
        // view the freed strip back for other files.
        textBar.isHidden = !isMd
        mdSegment.selectedSegment = markdownRender ? 0 : 1
        textScroll.frame = isMd
            ? NSRect(x: 0, y: 0, width: textPane.bounds.width, height: textPane.bounds.height - pdfBarHeight)
            : textPane.bounds
        let renderMd = markdownRender && isMd
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let attr: NSAttributedString
            if renderMd, let text = readTextLeniently(path) {
                logEvent("textPreview via markdown-render \(path)")
                attr = MarkdownRenderer(palette: pal).render(text)
            } else if let bat = bat, let text = readTextLeniently(path),
                      let ansi = self.runBat(bat, theme: theme, path: path, text: text) {
                logEvent("textPreview via bat (source) \(path)")
                attr = renderANSI(parseANSI(ansi), font: font, defaultFg: fg)
            } else {
                // Fallback: raw text, themed monospace; an unreadable file
                // says so instead of showing nothing.
                let text = readTextLeniently(path) ?? "(cannot read file)"
                attr = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: fg])
            }
            guard self.isCurrentListing(gen) else { return }
            DispatchQueue.main.async {
                guard self.isCurrentListing(gen), !self.textPane.isHidden else { return }
                // Cap the measure for rendered prose only — source keeps the
                // file's own line breaks and must not be squeezed.
                self.textView.maxMeasure = renderMd ? mdMeasurePoints : 0
                self.textView.textStorage?.setAttributedString(attr)
                self.textView.scroll(NSPoint.zero)
            }
        }
    }

    /// Toggle the markdown mode (native render ↔ source via bat) — a global
    /// setting, so `M` flips it consistently from any pane. If a markdown file
    /// is on screen, re-render it so the change is visible immediately.
    /// Triggered by yazi's `M` (via the FIFO sentinel) or `M` in the focused
    /// text preview. Main thread only.
    func toggleMarkdownMode() { setMarkdownRender(!markdownRender) }

    /// Pin/unpin the preview to the current file. Pinned, hover events are
    /// ignored (see `update`), so the preview holds the file you are editing
    /// while a yazi pane navigates elsewhere — pin it, open it in Neovide/nvim,
    /// and watch it re-render on every save. Only a real file can be pinned; a
    /// directory or empty preview beeps and stays unpinned. Triggered by ⌘P or
    /// the @TOGGLE_PIN FIFO sentinel. Side effects: sets `previewPinned`, redraws
    /// the pin border, syncs the menu item. Main thread only.
    @objc func togglePreviewPin() {
        if previewPinned {
            previewPinned = false
            logEvent("preview unpinned")
        } else {
            var isDir: ObjCBool = false
            guard let p = lastPath,
                  FileManager.default.fileExists(atPath: p, isDirectory: &isDir),
                  !isDir.boolValue else {
                warn("conspectus: nothing to pin — hover a file first")
                NSSound.beep()
                return
            }
            previewPinned = true
            logEvent("preview pinned \(p)")
        }
        pinMenuItem?.state = previewPinned ? .on : .off
        updateFocusBorders()   // the pin border lives on the preview focus ring
    }

    /// Thread-safe snapshot of the live preview skip list (see `skipDirsStore`
    /// in Panel.swift) — the only way the list is read.
    var skipDirs: [String] {
        skipDirsLock.lock(); defer { skipDirsLock.unlock() }
        return skipDirsStore
    }

    /// Toggle the preview skip list for the folder currently browsed — the
    /// parent of the last hovered entry, which is the yazi cwd whether a file
    /// or a subfolder is hovered. An entry always covers its whole subtree.
    /// Covered → the covering entries are removed (previews come back); not
    /// covered → the folder is added (previews off below it). Session-only;
    /// CONSPECTUS_PREVIEW_SKIP_DIRS is the persistent seed. Re-enabling on a
    /// truly hung mount will block exactly like before the skip — that is the
    /// user's explicit call. Triggered by ⌘⇧P. Side effects: mutates
    /// `skipDirsStore` (under the lock), re-renders the current preview.
    @objc func togglePreviewSkipHere() {
        guard let hovered = lastPath else {
            warn("conspectus: nothing hovered yet — no folder to toggle")
            NSSound.beep()
            return
        }
        let dir = (hovered as NSString).deletingLastPathComponent
        let toggled = toggleSkipDir(dir, in: skipDirs)
        skipDirsLock.lock()
        skipDirsStore = toggled.dirs
        skipDirsLock.unlock()
        logEvent("preview skip \(toggled.nowSkipped ? "ON" : "off") for \(dir)")
        refreshCurrentPreview()
    }

    /// Set the markdown mode (true = rendered, false = source), sync the toolbar
    /// segment, and re-render the current file if it's markdown. Shared by `M`,
    /// the FIFO sentinel, and the segmented control.
    func setMarkdownRender(_ on: Bool) {
        markdownRender = on
        mdSegment?.selectedSegment = on ? 0 : 1
        logEvent("markdown mode -> \(on ? "render" : "source")")
        guard let path = lastTextPath, !textPane.isHidden else { return }
        guard isMarkdownFile(path) else { return }
        lastTextPath = nil                                  // defeat the dedup
        showTextPreview(path, generation: bumpListingGeneration())
    }

    /// Run `bat` on already-decoded `text` and return its ANSI-coloured output,
    /// or nil on failure (caller falls back to plain text). The text goes in on
    /// stdin as UTF-8 — bat reads files as strict UTF-8 and turns Latin-1
    /// umlauts into `�` — and `--file-name` keeps syntax detection by `path`.
    /// `--style=plain` = no line numbers/decorations; `--wrap=never` lets the
    /// NSTextView do the wrapping. Off the main thread.
    private func runBat(_ bat: String, theme: String, path: String, text: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bat)
        p.arguments = ["--color=always", "--style=plain", "--paging=never",
                       "--wrap=never", "--theme=\(theme)", "--file-name=\(path)", "-"]
        let inp = Pipe()
        let out = Pipe()
        p.standardInput = inp
        p.standardOutput = out
        p.standardError = Pipe()   // swallow bat's stderr
        do {
            try p.run()
            // Feed stdin from a second thread: a large file would fill both
            // pipe buffers and deadlock if we wrote it all before reading.
            // F_SETNOSIGPIPE: if bat dies early, the write fails with EPIPE
            // instead of SIGPIPE killing the whole app.
            let writer = inp.fileHandleForWriting
            _ = fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1)
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try writer.write(contentsOf: Data(text.utf8))
                    try writer.close()
                } catch {
                    // bat's own exit status decides the fallback; just note it.
                    logEvent("runBat stdin write failed for \(path): \(error)")
                }
            }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            guard p.terminationStatus == 0 else { return nil }
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
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

    /// Show a short centered note in the preview pane (reusing the folder
    /// listing's text view as the opaque cover over the Quick Look view) —
    /// for the "too large to preview" case. The next normal hover replaces or
    /// uncovers it via the usual paths.
    func showPreviewMessage(_ message: String) {
        let pal = activePalette()
        let para = NSMutableParagraphStyle(); para.alignment = .center
        let attr = NSAttributedString(string: "\n\n" + message, attributes: [
            .font: terminalFont(size: 13),
            .foregroundColor: nsColor(pal.fg).withAlphaComponent(0.7),
            .paragraphStyle: para,
        ])
        folderText.textStorage?.setAttributedString(attr)
        folderText.scroll(NSPoint.zero)
        hideAllCovers()
        setVCSBarVisible(false)
        folderScroll.isHidden = false   // cover the always-alive Quick Look view
    }

    /// ⌘L — ask yazi for its current selection. The selection lives inside
    /// yazi and has no change event, so it can only be PULLED: this publishes
    /// a `panesync-selected` DDS request naming the pane whose selection is
    /// wanted (the focused one; anything that is not the right pane's yazi
    /// asks the left). The plugin answers over the FIFO (`@SELECTED:`), which
    /// lands in `showSelectedList`. Side effects: spawns `ya pub-to`.
    @objc func requestSelectedList() {
        publishToYazi("panesync-selected",
                      body: peerLetter(of: window.firstResponder as? LocalProcessTerminalView))
    }

    /// Show yazi's selection as a clickable list in the folder-listing pane
    /// (the `@SELECTED:` answer to ⌘L). Same cover discipline as showFolder
    /// (cover the Quick Look view, never hide it), same off-main rendering
    /// (the renderer stats every path), same generation guard (a hover racing
    /// in afterwards wins — the list is a peek, not a mode).
    /// `heading` / `emptyNote` name the list (default: the selection);
    /// Show Yazi Clipboard (⇧⌘L) passes the yank buffer's.
    /// Side effects: swaps the visible preview cover.
    func showSelectedList(_ paths: [String], heading: String? = nil,
                          emptyNote: String = "nothing selected — Space or v marks files in yazi") {
        let heading = heading ?? "\(paths.count) selected"
        logEvent("showSelectedList (\(heading))")
        stopWatchingPreviewFile()   // no single file to watch, like a folder
        hideAllCovers()
        lastTextPath = nil
        folderScroll.isHidden = false
        let gen = bumpListingGeneration()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let listing = renderSelectedListing(paths, heading: heading, emptyNote: emptyNote)
            DispatchQueue.main.async {
                guard self.isCurrentListing(gen) else { return }
                self.folderText.textStorage?.setAttributedString(listing)
                self.folderText.scroll(NSPoint.zero)
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
        logEvent("showFolder \(path)")
        stopWatchingPreviewFile()   // a directory has no single file to watch
        hideAllCovers()
        setVCSBarVisible(false)     // the line is per file; the listing has its sign column
        lastTextPath = nil
        folderScroll.isHidden = false   // opaque — covers the always-alive preview
        let sort = listingSort   // read on main; the loader queue gets a copy
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let contents = loadFolder(path, cap: folderListingCap, sort: sort)
            // Navigated on already? Skip the attributed-string build entirely.
            guard self.isCurrentListing(gen) else { return }
            // nil outside a CVS checkout — the listing then has no sign column.
            let cvs = readCVSStatuses(in: path)
            for line in cvs?.malformed ?? [] { warn("conspectus: \(path)/CVS/Entries: unparseable line: \(line)") }
            // Server side from the cache only (the yazi fetcher fills it when a
            // folder is entered) — a hover must never cost a server round trip.
            var statuses = cvs?.statuses
            if statuses != nil, let ttl = cvsRemoteTTL,
               let remote = readCVSRemoteCache(for: path, cacheDir: cvsRemoteCacheDir),
               remote.isFresh(now: Date(), ttl: ttl, errorTTL: cvsRemoteErrorTTL) {
                for name in remote.needsUpdate { statuses?[name] = .needsUpdate }
            }
            let listing = renderListing(contents, in: path, cvs: statuses)
            DispatchQueue.main.async {
                // Re-check: a newer hover may have won while we rendered.
                guard self.isCurrentListing(gen) else { return }
                self.folderText.textStorage?.setAttributedString(listing)
                self.folderText.scroll(NSPoint.zero)
            }
        }
    }
}

/// Read a text file for display or print, guessing its encoding
/// (`decodeText`: UTF-16 BOM → UTF-8 → Windows-1252 → Latin-1), so legacy
/// Latin-1 files show their umlauts instead of mojibake. nil only when the
/// file can't be read (gone, no permission) — deliberate `try?`: the caller
/// says so visibly. Side effects: reads the file.
func readTextLeniently(_ path: String) -> String? {
    guard let data = FileManager.default.contents(atPath: path) else { return nil }
    return decodeText(data)
}

/// A folder-listing row a single click revealed, remembered for the
/// double-click that may follow (see `Panel.listingClick`).
struct ListingClick {
    let path: String
    let isDir: Bool
    let at: Date
}
