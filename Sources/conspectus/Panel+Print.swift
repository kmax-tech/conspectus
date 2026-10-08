import Cocoa
import Quartz
import ConspectusCore

// Printing the previewed file (File ▸ Print…, ⌥⌘P). The preview already owns a
// native in-process renderer per type; printing reuses exactly those, so what
// leaves the printer is what the pane shows — a PDF page-for-page, an image
// fitted to the page, source paginated, a markdown note typeset.
//
// Two deliberate departures from the screen:
//   - the LIGHT palette, always. The dark theme is a screen theme; light-on-dark
//     prints an unreadable, toner-eating page.
//   - no `bat` syntax colors for source. They are palette colors chosen for a
//     backlit pane, and several of them are near-invisible on paper.

extension Panel {
    /// Print the file the preview is showing, through the real macOS print
    /// panel (printer, copies, page range, duplex, "Save as PDF" — the user
    /// asked for the dialog, so nothing is ever sent to a printer unprompted).
    ///
    /// The subject is `lastPath` — the hovered file, or the pinned one while the
    /// preview is pinned (⌘P). It is tracked even with the preview pane closed
    /// (⌘E), so printing works in `split` mode too. Folders, and types with no
    /// native renderer, refuse loudly instead of printing something wrong.
    ///
    /// ⌥⌘P, not ⌘P: ⌘P pins the preview and ⌘⇧P is the per-folder preview
    /// switch — both older than this. ⌥⌘P puts print next to ⌥⌘R (reveal in
    /// Finder), the other "act on the previewed file" command.
    /// Side effects: runs a print operation as a sheet on the window.
    @objc func printPreviewFile() {
        guard let path = lastPath else {
            refusePrint("Nothing is previewed yet — hover a file first.")
            return
        }
        let name = (path as NSString).lastPathComponent
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else {
            refusePrint("\(name) is gone from disk.")
            return
        }
        guard !isDir.boolValue else {
            refusePrint("\(name) is a folder — only files print.")
            return
        }
        guard let op = printOperation(for: path) else {
            refusePrint("""
                No printable rendering for \(name).

                conspectus prints what it renders itself: PDFs, images, and \
                text/source/markdown. Open the file in an app that knows the \
                format and print it from there.
                """)
            return
        }
        logEvent("print \(path)")
        op.jobTitle = name              // the printer queue shows the file, not "Untitled"
        op.showsPrintPanel = true
        op.showsProgressPanel = true
        op.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }

    /// The print operation for `path`, one branch per native renderer — nil for
    /// a type conspectus cannot render itself (the caller refuses).
    private func printOperation(for path: String) -> NSPrintOperation? {
        if path.lowercased().hasSuffix(".pdf"), let doc = PDFDocument(url: URL(fileURLWithPath: path)) {
            // A PDF carries its own page geometry: no margins of ours on top,
            // just scale a page down if it exceeds the printer's imageable area.
            return doc.printOperation(for: printInfo(margin: 0),
                                      scalingMode: .pageScaleDownToFit, autoRotate: true)
        }
        if isImagePreviewable(path), let image = NSImage(contentsOfFile: path) {
            return imagePrintOperation(image)
        }
        if isTextPreviewable(path), let text = readForPrint(path) {
            return textPrintOperation(printableText(text, for: path))
        }
        return nil
    }

    /// A fresh `NSPrintInfo` for one job: a copy, so the shared default (and
    /// with it every later job) never inherits our margins and pagination.
    private func printInfo(margin: CGFloat = 54) -> NSPrintInfo {
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.leftMargin = margin; info.rightMargin = margin
        info.topMargin = margin; info.bottomMargin = margin      // 54pt = 0.75in
        info.horizontalPagination = .fit                          // never spill sideways
        info.verticalPagination = .automatic                      // paginate down the file
        info.isHorizontallyCentered = true
        info.isVerticallyCentered = false                         // text starts at the top margin
        return info
    }

    /// The printable area of a page: paper minus our margins.
    private func contentSize(_ info: NSPrintInfo) -> NSSize {
        NSSize(width: info.paperSize.width - info.leftMargin - info.rightMargin,
               height: info.paperSize.height - info.topMargin - info.bottomMargin)
    }

    /// One page, image fitted into it proportionally (letterboxed, never
    /// cropped or blown past its own resolution's page).
    private func imagePrintOperation(_ image: NSImage) -> NSPrintOperation {
        let info = printInfo()
        let view = NSImageView(frame: NSRect(origin: .zero, size: contentSize(info)))
        view.imageScaling = .scaleProportionallyUpOrDown
        view.imageAlignment = .alignCenter
        view.image = image
        return NSPrintOperation(view: view, printInfo: info)
    }

    /// Paginated text: an off-screen `NSTextView` laid out to the page width,
    /// which is what makes AppKit break the content across pages. Off-screen on
    /// purpose — printing must not disturb the preview's own text view (its
    /// content, scroll position, or measure cap).
    private func textPrintOperation(_ content: NSAttributedString) -> NSPrintOperation {
        let info = printInfo()
        let size = contentSize(info)
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: size.width, height: size.height))
        view.minSize = NSSize(width: size.width, height: 0)
        view.maxSize = NSSize(width: size.width, height: .greatestFiniteMagnitude)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.textContainer?.containerSize = NSSize(width: size.width, height: .greatestFiniteMagnitude)
        view.textContainer?.widthTracksTextView = true
        view.textStorage?.setAttributedString(content)
        view.sizeToFit()     // lay the text out, so pagination knows its height
        return NSPrintOperation(view: view, printInfo: info)
    }

    /// What a text file looks like on paper: a markdown note in the preview's
    /// own typesetting when the preview is in render mode (serif, headings,
    /// tables — the reason the render exists), everything else as plain black
    /// monospace. Rendering with `latte` regardless of the system appearance is
    /// the light-palette rule above.
    private func printableText(_ text: String, for path: String) -> NSAttributedString {
        if markdownRender, isMarkdownFile(path) {
            return MarkdownRenderer(palette: latte).render(text)
        }
        return NSAttributedString(string: text, attributes: [
            .font: terminalFont(size: 10),      // ~78 columns at 0.75in margins
            .foregroundColor: NSColor.black,
        ])
    }

    /// Read a text file for printing. Deliberately lenient, exactly like the
    /// text preview: UTF-8, then Latin-1, so a legacy-encoded file still prints
    /// instead of refusing.
    private func readForPrint(_ path: String) -> String? {
        (try? String(contentsOfFile: path, encoding: .utf8))
            ?? (try? String(contentsOfFile: path, encoding: .isoLatin1))
    }

    /// Refuse to print, visibly: a sheet says why. A `warn()` alone would be
    /// invisible for a command the user just typed.
    /// Side effects: beeps, opens a sheet on the window.
    private func refusePrint(_ reason: String) {
        warn("conspectus: cannot print — \(reason)")
        NSSound.beep()
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Cannot print"
        alert.informativeText = reason
        alert.beginSheetModal(for: window, completionHandler: nil)
    }
}
