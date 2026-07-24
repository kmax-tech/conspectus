import Cocoa
import Quartz
import ConspectusCore

// The perlege-style control strip above the PDF preview: page stepper with
// live "n / total", zoom group with live percentage, fit, single↔continuous
// toggle, and a recolor toggle (dark rendering via CoreImage layer filters —
// the preview version of perlege's `r`). Buttons mirror what the keys do when
// the pane is focused (J/K, +/-, f, s), so mouse-only use needs no keyboard.

let pdfBarHeight: CGFloat = 28

extension Panel {
    /// Build the PDF pane: toolbar on top, the PDFKit view below. The PANE is
    /// what covers the Quick Look view; both children are ours, so
    /// hiding/showing is safe (the QL hide rules apply only to the QL view).
    func buildPDFPane() {
        pdfPane = NSView(frame: rightContainer.bounds)
        pdfPane.autoresizingMask = [.width, .height]

        pdfBar = NSView(frame: NSRect(x: 0, y: pdfPane.bounds.height - pdfBarHeight,
                                      width: pdfPane.bounds.width, height: pdfBarHeight))
        pdfBar.autoresizingMask = [.width, .minYMargin]
        pdfBar.wantsLayer = true

        pdfView = IntentFocusPDFView(frame: NSRect(x: 0, y: 0, width: pdfPane.bounds.width,
                                                   height: pdfPane.bounds.height - pdfBarHeight))
        pdfView.autoresizingMask = [.width, .height]
        pdfView.autoScales = true
        pdfView.displayMode = pdfPreviewMode == "continuous" ? .singlePageContinuous : .singlePage

        pdfPane.addSubview(pdfView)
        pdfPane.addSubview(pdfBar)
        pdfPane.isHidden = true

        buildPDFBarControls()
        stylePDFBar()   // opaque background NOW — else the covered QL view bleeds through the bar

        // Live labels: PDFKit posts on page flips and zoom changes.
        NotificationCenter.default.addObserver(forName: .PDFViewPageChanged, object: pdfView,
                                               queue: .main) { [weak self] _ in self?.updatePDFBar() }
        NotificationCenter.default.addObserver(forName: .PDFViewScaleChanged, object: pdfView,
                                               queue: .main) { [weak self] _ in self?.updatePDFBar() }
    }

    private func barButton(_ symbol: String, _ tip: String, _ action: Selector) -> NSButton {
        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
            ?? NSImage(named: NSImage.actionTemplateName)!
        let b = NSButton(image: img, target: self, action: action)
        b.isBordered = false
        b.toolTip = tip
        b.setButtonType(.momentaryChange)
        return b
    }

    private func barLabel() -> NSTextField {
        let l = NSTextField(labelWithString: "")
        l.font = terminalFont(size: 11)
        l.alignment = .center
        return l
    }

    private func buildPDFBarControls() {
        pdfPageLabel = barLabel()
        pdfZoomLabel = barLabel()
        let controls: [NSView] = [
            barButton("chevron.left", "Vorherige Seite (K)", #selector(pdfPrevPage)),
            pdfPageLabel,
            barButton("chevron.right", "Nächste Seite (J)", #selector(pdfNextPage)),
            barButton("minus.magnifyingglass", "Zoom − (-)", #selector(pdfZoomOut)),
            pdfZoomLabel,
            barButton("plus.magnifyingglass", "Zoom + (+)", #selector(pdfZoomIn)),
            barButton("arrow.up.left.and.arrow.down.right", "Einpassen (f)", #selector(pdfZoomFit)),
            barButton("doc.plaintext", "Single ↔ Continuous (s)", #selector(pdfToggleMode)),
            barButton("sun.max", "Recolor hell ↔ dunkel", #selector(pdfToggleRecolor)),
        ]
        let stack = NSStackView(views: controls)
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
        stack.frame = pdfBar.bounds
        stack.autoresizingMask = [.width, .height]
        pdfBar.addSubview(stack)
    }

    // MARK: bar actions — same paths the keys take, so behavior can't diverge.
    @objc func pdfPrevPage()   { pdfView.goToPreviousPage(nil) }
    @objc func pdfNextPage()   { pdfView.goToNextPage(nil) }
    @objc func pdfZoomIn()     { pdfView.zoomIn(nil) }
    @objc func pdfZoomOut()    { pdfView.zoomOut(nil) }
    @objc func pdfZoomFit()    { pdfView.autoScales = true; updatePDFBar() }
    @objc func pdfToggleMode() { pdfView.toggleDisplayMode() }

    /// Dark rendering for the PDF only (perlege's `r`, preview edition):
    /// invert + hue-rotate as layer filters keeps colors roughly right while
    /// white paper turns dark. Pure view-level — the file is untouched.
    @objc func pdfToggleRecolor() {
        pdfRecolored.toggle()
        // CIFilters on a layer are IGNORED on macOS unless the view opts in
        // with layerUsesCoreImageFilters — that was the missing piece.
        pdfView.wantsLayer = true
        pdfView.layerUsesCoreImageFilters = true
        if pdfRecolored,
           let invert = CIFilter(name: "CIColorInvert"),
           let hue = CIFilter(name: "CIHueAdjust") {
            hue.setValue(Double.pi, forKey: kCIInputAngleKey)   // 180° back → colours stay ~right, paper goes dark
            pdfView.layer?.filters = [invert, hue]
        } else {
            pdfView.layer?.filters = nil
        }
    }

    /// Refresh "n / total" and the zoom percentage.
    func updatePDFBar() {
        guard let doc = pdfView.document else {
            pdfPageLabel.stringValue = "– / –"
            pdfZoomLabel.stringValue = ""
            return
        }
        let current = doc.index(for: pdfView.currentPage ?? doc.page(at: 0)!) + 1
        pdfPageLabel.stringValue = "\(current) / \(doc.pageCount)"
        pdfZoomLabel.stringValue = "\(Int((pdfView.scaleFactor * 100).rounded())) %"
    }

    /// Palette-follow for the bar (called from styleFolder on theme changes).
    func stylePDFBar() {
        guard let pdfBar = pdfBar else { return }
        let pal = activePalette()
        pdfBar.layer?.backgroundColor = nsColor(pal.bg).cgColor
        pdfView.backgroundColor = nsColor(pal.bg)
        for case let label as NSTextField in (pdfBar.subviews.first?.subviews ?? []) {
            label.textColor = nsColor(pal.fg)
        }
        for case let button as NSButton in (pdfBar.subviews.first?.subviews ?? []) {
            button.contentTintColor = nsColor(pal.fg)
        }
    }
}
