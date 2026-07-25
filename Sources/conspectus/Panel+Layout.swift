import Cocoa
import ConspectusCore
import SwiftTerm

// Window, menu, and pane construction; the two split-view layers and their
// layout. Pane layout is two independent toggles: the second yazi pane (⌘D)
// and the preview pane (⌘E, always rightmost); the bottom terminal (⌘J)
// hangs below both in the outer split.

extension Panel {
    /// Build the right pane: Quick Look preview (files) stacked with a
    /// directory listing (folders); `update` toggles which one is visible.
    func buildRightPane() {
        rightContainer = NSView(frame: NSRect(x: 0, y: 0, width: 620, height: 900))
        preview = IntentFocusPreviewView(frame: rightContainer.bounds, style: .normal) ?? IntentFocusPreviewView()
        preview.autoresizingMask = [.width, .height]
        preview.onFocusLeft = { [weak self] in self?.focusLeftPane() }
        folderScroll = NSScrollView(frame: rightContainer.bounds)
        folderScroll.hasVerticalScroller = true
        folderScroll.autoresizingMask = [.width, .height]
        folderText = NonFocusableTextView(frame: rightContainer.bounds)
        folderText.isEditable = false
        folderText.isVerticallyResizable = true
        folderText.isHorizontallyResizable = false
        folderText.autoresizingMask = [.width]
        folderText.textContainerInset = NSSize(width: 10, height: 10)
        folderText.textContainer?.widthTracksTextView = true
        // Folder rows are clickable links (navigate yazi there); keep their
        // own colors — only the cursor signals clickability.
        folderText.linkTextAttributes = [.cursor: NSCursor.pointingHand]
        folderText.delegate = self
        folderScroll.documentView = folderText
        folderScroll.isHidden = true
        styleFolder()
        rightContainer.addSubview(preview)
        // The PDF pane (toolbar + PDFKit view) sits ABOVE the always-alive
        // Quick Look view (cover pattern) and BELOW the folder listing; it is
        // entirely our own, so hiding/showing it is safe — the QL hide/unhide
        // rules don't apply.
        buildPDFPane()
        rightContainer.addSubview(pdfPane)
        buildTextPreview()
        rightContainer.addSubview(textPane)
        buildImagePreview()
        rightContainer.addSubview(imageView)
        rightContainer.addSubview(folderScroll)
        previewFocusRing = PassthroughBorderView(frame: rightContainer.bounds)
        previewFocusRing.autoresizingMask = [.width, .height]
        rightContainer.addSubview(previewFocusRing)   // last -> stays on top
    }

    /// Native text preview: a pane holding an optional markdown toolbar (a
    /// rendered↔source segmented toggle, shown only for markdown) plus an
    /// NSTextView in a scroll view. The pane covers the QL view like the folder
    /// listing. Ours, in-process — safe to hide/show.
    func buildTextPreview() {
        textPane = NSView(frame: rightContainer.bounds)
        textPane.autoresizingMask = [.width, .height]

        textBar = NSView(frame: NSRect(x: 0, y: textPane.bounds.height - pdfBarHeight,
                                       width: textPane.bounds.width, height: pdfBarHeight))
        textBar.autoresizingMask = [.width, .minYMargin]
        textBar.wantsLayer = true
        // rendered (eye) ↔ source (code) toggle — like the Claude viewer.
        mdSegment = NSSegmentedControl(labels: [], trackingMode: .selectOne, target: self,
                                       action: #selector(mdSegmentChanged))
        mdSegment.segmentCount = 2
        mdSegment.setImage(NSImage(systemSymbolName: "eye", accessibilityDescription: "Rendered"), forSegment: 0)
        mdSegment.setImage(NSImage(systemSymbolName: "chevron.left.forwardslash.chevron.right", accessibilityDescription: "Source"), forSegment: 1)
        mdSegment.setToolTip("Rendered", forSegment: 0)
        mdSegment.setToolTip("Source", forSegment: 1)
        mdSegment.selectedSegment = markdownRender ? 0 : 1
        mdSegment.translatesAutoresizingMaskIntoConstraints = false
        textBar.addSubview(mdSegment)
        NSLayoutConstraint.activate([
            mdSegment.trailingAnchor.constraint(equalTo: textBar.trailingAnchor, constant: -10),
            mdSegment.centerYAnchor.constraint(equalTo: textBar.centerYAnchor),
        ])

        textScroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: textPane.bounds.width,
                                                height: textPane.bounds.height - pdfBarHeight))
        textScroll.hasVerticalScroller = true
        textScroll.autoresizingMask = [.width, .height]
        textView = IntentFocusTextView(frame: textScroll.bounds)
        textView.isEditable = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.textContainer?.widthTracksTextView = true
        textView.onFocusLeft = { [weak self] in self?.focusLeftPane() }
        textView.onToggleMarkdown = { [weak self] in self?.toggleMarkdownMode() }
        textScroll.documentView = textView

        textPane.addSubview(textScroll)
        textPane.addSubview(textBar)
        textPane.isHidden = true
    }

    /// The segmented toggle changed — apply the chosen markdown mode.
    @objc func mdSegmentChanged() {
        setMarkdownRender(mdSegment.selectedSegment == 0)
    }

    /// Native image preview: an NSImageView covering the QL view, scaled to fit
    /// with the theme background as letterbox.
    func buildImagePreview() {
        imageView = IntentFocusImageView(frame: rightContainer.bounds)
        imageView.autoresizingMask = [.width, .height]
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        imageView.wantsLayer = true
        imageView.onFocusLeft = { [weak self] in self?.focusLeftPane() }
        imageView.isHidden = true
    }

    /// Wrap a terminal in a padded container: `termPadding` between the pane
    /// edge and the text, padding painted in the theme background. The split
    /// views hold these containers; the terminal autoresizes inside.
    func makeTermPane(_ t: LocalProcessTerminalView) -> NSView {
        let pane = NSView(frame: t.frame)
        pane.wantsLayer = true
        pane.layer?.backgroundColor = nsColor(activePalette().bg).cgColor
        t.frame = pane.bounds.insetBy(dx: termPadding, dy: termPadding)
        t.autoresizingMask = [.width, .height]
        pane.addSubview(t)
        return pane
    }

    /// Repaint the pane padding in the active palette (theme changes).
    func styleTermPanes() {
        let bg = nsColor(activePalette().bg).cgColor
        for pane in [termPane, term2Pane, bottomPane] {
            pane?.layer?.backgroundColor = bg
        }
    }

    /// Build the split view holding terminal (left) and preview (right).
    func buildSplitView() {
        split = NSSplitView(frame: NSRect(x: 0, y: 0, width: 1340, height: 900))
        split.isVertical = true            // vertical divider -> panes side by side
        split.dividerStyle = .thin
        split.delegate = self              // keep proportions on resize, min widths
        termPane = makeTermPane(term)
        split.addSubview(termPane)
        split.addSubview(rightContainer)
        split.setPosition(760, ofDividerAt: 0)
    }

    /// Build the outer vertical stack: the pane split on top, optionally the
    /// bottom terminal (⌘J) below it.
    func buildOuterSplit() {
        outerSplit = NSSplitView(frame: NSRect(x: 0, y: 0, width: 1340, height: 900))
        outerSplit.isVertical = false      // horizontal divider -> stacked panes
        outerSplit.dividerStyle = .thin
        outerSplit.delegate = self
        outerSplit.addSubview(split)
    }

    /// Lay the outer stack out explicitly: the pane area fills the space, the
    /// bottom terminal (if open) gets `terminalHeight` (or keeps its current
    /// height), clamped to the minimums. NSSplitView's setPosition/delegate
    /// layout proved unreliable for programmatic add/remove (the added view
    /// ended up 0pt high), so the frames are set directly.
    func layoutOuterPanes(terminalHeight: CGFloat? = nil) {
        let w = outerSplit.frame.width
        let h = outerSplit.frame.height
        guard let pane = bottomPane, pane.superview === outerSplit else {
            split.frame = NSRect(x: 0, y: 0, width: w, height: h)
            return
        }
        let want = terminalHeight ?? pane.frame.height
        let termH = min(max(minTermHeight, want),
                        max(minTermHeight, h - minPane - outerSplit.dividerThickness))
        let mainH = h - termH - outerSplit.dividerThickness
        split.frame = NSRect(x: 0, y: 0, width: w, height: mainH)
        pane.frame = NSRect(x: 0, y: mainH + outerSplit.dividerThickness, width: w, height: termH)
    }

    /// Build the shortcut bar: one line of key/label pairs in the theme
    /// colors, centered, truncating on narrow windows.
    func buildHintBar() {
        hintBar = NSView(frame: NSRect(x: 0, y: 0, width: 1340, height: hintBarHeight))
        hintBar.autoresizingMask = [.width]
        hintText = NSTextField(labelWithString: "")
        hintText.isBordered = false
        hintText.drawsBackground = false
        hintText.lineBreakMode = .byTruncatingTail
        hintText.alignment = .center
        hintBar.addSubview(hintText)
        styleHintBar()
    }

    /// (Re-)render the shortcut bar in the active palette; called on build
    /// and whenever the system appearance changes.
    func styleHintBar() {
        guard let hintBar = hintBar, let hintText = hintText else { return }
        let pal = activePalette()
        hintBar.wantsLayer = true
        hintBar.layer?.backgroundColor = nsColor(pal.bg).cgColor
        let font = terminalFont(size: 11)
        let keyColor = nsColor(pal.ansi[3])                          // yellow accent
        let labelColor = nsColor(pal.fg).withAlphaComponent(0.8)
        let s = NSMutableAttributedString()
        for (i, hint) in shortcutHints.enumerated() {
            if i > 0 { s.append(NSAttributedString(string: "   ", attributes: [.font: font])) }
            s.append(NSAttributedString(string: hint.key + " ",
                                        attributes: [.font: font, .foregroundColor: keyColor]))
            s.append(NSAttributedString(string: hint.label,
                                        attributes: [.font: font, .foregroundColor: labelColor]))
        }
        hintText.attributedStringValue = s
        hintText.sizeToFit()
        hintText.frame = NSRect(x: 8, y: (hintBarHeight - hintText.frame.height) / 2,
                                width: hintBar.bounds.width - 16, height: hintText.frame.height)
        hintText.autoresizingMask = [.width]
    }

    /// Show/hide the shortcut bar per the persisted preference and lay the
    /// split view out above it.
    func applyHintBarVisibility() {
        guard let content = window?.contentView else { return }
        let visible = UserDefaults.standard.bool(forKey: showHintsKey)
        hintBar.isHidden = !visible
        let barH = visible ? hintBarHeight : 0
        hintBar.frame = NSRect(x: 0, y: 0, width: content.bounds.width, height: hintBarHeight)
        outerSplit.frame = NSRect(x: 0, y: barH, width: content.bounds.width,
                                  height: content.bounds.height - barH)
        layoutOuterPanes()
    }

    /// Toggle the shortcut bar. Side effects: persists the choice in
    /// UserDefaults so it survives relaunches.
    @objc func toggleHintBar() {
        let d = UserDefaults.standard
        d.set(!d.bool(forKey: showHintsKey), forKey: showHintsKey)
        applyHintBarVisibility()
    }

    /// Build the main window: split view above the shortcut bar; remembers
    /// size/position across launches (including the split layout width).
    func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1340, height: 900),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable],
                          backing: .buffered, defer: false)
        window.title = "conspectus"
        // AppKit's legacy default releases a closed window even though `self.window`
        // still points at it — the next access (e.g. applicationDidResignActive
        // touching firstResponder) is then a use-after-free crash. Keep ownership
        // with ARC; closing quits the app via
        // applicationShouldTerminateAfterLastWindowClosed.
        window.isReleasedWhenClosed = false
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 1340, height: 900))
        outerSplit.autoresizingMask = [.width, .height]
        content.addSubview(hintBar)
        content.addSubview(outerSplit)
        window.contentView = content
        applyHintBarVisibility()
        if !window.setFrameUsingName("ConspectusMain") { window.center() }
        window.setFrameAutosaveName("ConspectusMain")
        focusObservation = window.observe(\.firstResponder) { [weak self] _, _ in
            self?.focusDidChange()
        }
    }

    /// Titlebar toggles for the two panes (second yazi, Quick Look preview) —
    /// clicks never fight yazi for the keyboard. Their on/off state mirrors
    /// the actual layout.
    func addTitlebarButtons() {
        splitButton = makeToggleButton(title: " Split ", symbol: "rectangle.split.2x1",
                                       action: #selector(toggleSecondPane))
        previewButton = makeToggleButton(title: " Preview ", symbol: "eye",
                                         action: #selector(togglePreviewPane))
        previewButton.state = previewAttached ? .on : .off
        let stack = NSStackView(views: [previewButton, splitButton])
        stack.orientation = .horizontal
        stack.spacing = 6
        let acc = NSTitlebarAccessoryViewController()
        acc.layoutAttribute = .right
        acc.view = stack
        window.addTitlebarAccessoryViewController(acc)
    }

    func makeToggleButton(title: String, symbol: String, action: Selector) -> NSButton {
        let btn = NSButton(title: title, target: self, action: action)
        btn.setButtonType(.pushOnPushOff)
        btn.bezelStyle = .rounded
        if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: title) {
            btn.image = img; btn.imagePosition = .imageLeading
        }
        btn.sizeToFit()
        return btn
    }

    // Minimal main menu so the app is keyboard-centric: menu key equivalents are
    // handled before the terminal view sees the keys (SwiftTerm has no
    // performKeyEquivalent), so nothing is intercepted inside yazi itself.
    //   ⌘D  toggle split pane (kitty muscle memory)
    //   ⌘E  toggle preview pane
    //   ⌘J  toggle bottom terminal (VS Code muscle memory)
    //   ⌘/  toggle shortcut bar
    //   ⌥←/→/↑/↓  pane focus (kitty/WezTerm/smart-splits habit; ⌘⌥ = alias)
    func buildMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "Hide Conspectus", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(NSMenuItem(title: "Quit Conspectus", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appItem.submenu = appMenu

        let viewItem = NSMenuItem(); main.addItem(viewItem)
        let viewMenu = NSMenu(title: "View")
        let toggle = NSMenuItem(title: "Toggle Split Pane", action: #selector(toggleSecondPane), keyEquivalent: "d")
        toggle.target = self
        viewMenu.addItem(toggle)
        let previewToggle = NSMenuItem(title: "Toggle Preview Pane", action: #selector(togglePreviewPane), keyEquivalent: "e")
        previewToggle.target = self
        viewMenu.addItem(previewToggle)
        let termToggle = NSMenuItem(title: "Toggle Terminal Panel", action: #selector(toggleBottomTerminal), keyEquivalent: "j")
        termToggle.target = self
        viewMenu.addItem(termToggle)
        // ⌘W = "close tab" muscle memory: closes the terminal panel when it is
        // open and deliberately does nothing otherwise — it must never take
        // the whole window down.
        let closeTerm = NSMenuItem(title: "Close Terminal Panel", action: #selector(closeTerminalPanel), keyEquivalent: "w")
        closeTerm.target = self
        viewMenu.addItem(closeTerm)
        let hints = NSMenuItem(title: "Toggle Shortcut Bar", action: #selector(toggleHintBar), keyEquivalent: "/")
        hints.target = self
        viewMenu.addItem(hints)
        let cheat = NSMenuItem(title: "Keyboard Cheat Sheet", action: #selector(toggleCheatSheet), keyEquivalent: "k")
        cheat.target = self
        viewMenu.addItem(cheat)
        // Pane focus follows the kitty/WezTerm/smart-splits convention from
        // the dotfiles (keybindings.md): plain ⌥-arrows move focus between
        // panes; ⌘⌥ stays as a silent alias for the old chord. Trade-off,
        // same as in kitty: ⌥←/→ no longer reach the shell as word jumps —
        // M-b/M-f and C-a/C-e still do.
        addFocusItem(viewMenu, "Focus Left Pane", NSLeftArrowFunctionKey, #selector(focusLeftPane))
        addFocusItem(viewMenu, "Focus Right Pane", NSRightArrowFunctionKey, #selector(focusRightPane))
        addFocusItem(viewMenu, "Focus Terminal Panel", NSDownArrowFunctionKey, #selector(focusDown))
        addFocusItem(viewMenu, "Focus Pane Above", NSUpArrowFunctionKey, #selector(focusUp))
        // HHKB-friendly alternates for horizontal focus: ⌥[ / ⌥] — no arrow
        // keys needed. Same actions as ⌥←/→; both stay live.
        addFocusKeyItem(viewMenu, "Focus Left Pane (⌥[)", "[", #selector(focusLeftPane))
        addFocusKeyItem(viewMenu, "Focus Right Pane (⌥])", "]", #selector(focusRightPane))
        viewItem.submenu = viewMenu

        NSApp.mainMenu = main
    }

    /// Add a focus menu item bound to ⌥+arrow, plus a ⌘⌥ alternate (shown
    /// only while ⌘ is held) so the old chord keeps working.
    func addFocusItem(_ menu: NSMenu, _ title: String, _ arrow: Int, _ action: Selector) {
        let key = String(UnicodeScalar(arrow)!)
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = [.option]; item.target = self
        menu.addItem(item)
        let alias = NSMenuItem(title: title, action: action, keyEquivalent: key)
        alias.keyEquivalentModifierMask = [.command, .option]; alias.target = self
        alias.isAlternate = true
        menu.addItem(alias)
    }

    /// Add a focus menu item bound to ⌥+<char> (for the ⌥[ / ⌥] alternates).
    func addFocusKeyItem(_ menu: NSMenu, _ title: String, _ key: String, _ action: Selector) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = [.option]; item.target = self
        menu.addItem(item)
    }

    @objc func toggleSecondPane()  { term2 == nil ? addSecondPane() : removeSecondPane() }
    @objc func togglePreviewPane() { rightContainer.superview == nil ? attachPreview() : detachPreview() }

    func addSecondPane() {
        guard term2 == nil else { return }
        let t2 = makeTerm()
        term2 = t2
        let pane = makeTermPane(t2)
        term2Pane = pane
        // Keep the preview rightmost: the second terminal goes between the
        // left terminal and the preview container.
        if previewAttached {
            split.addSubview(pane, positioned: .above, relativeTo: termPane)
        } else {
            split.addSubview(pane)
        }
        evenOutPanes()
        // Same FIFO as the left pane: only the pane being navigated emits
        // hover events, so the preview follows the active instance for free.
        launch(t2, extraEnv: ["QLPEEK_FIFO": fifoPath, "CONSPECTUS_PEER": "R"])
        window.makeFirstResponder(t2)
        splitButton?.state = .on
        updateTitle()
    }

    func removeSecondPane() {
        guard let t2 = term2 else { return }
        term2 = nil
        term2Pane?.removeFromSuperview()
        term2Pane = nil
        t2.terminate()
        if previewAttached {
            evenOutPanes()      // preview never left the window — no rebuild needed
        } else {
            attachPreview()     // a lone terminal defeats the app's purpose
        }
        window.makeFirstResponder(term)
        splitButton?.state = .off
        updateTitle()
    }

    /// Remove the preview pane. The QLPreviewView auto-closes as soon as it
    /// leaves the window (its remote Quick Look extension is torn down), which
    /// is why `update` must never touch it while detached and `attachPreview`
    /// must rebuild it.
    func detachPreview() {
        guard previewAttached else { return }
        stopWatchingPreviewFile()   // nothing visible to keep fresh
        rightContainer.removeFromSuperview()
        evenOutPanes()
        previewButton?.state = .off
        updateTitle()
    }

    /// Re-attach the preview as the rightmost pane, rebuild the auto-closed
    /// QLPreviewView, and restore the last hovered item.
    func attachPreview() {
        guard !previewAttached else { return }
        split.addSubview(rightContainer)
        rebuildPreview()
        evenOutPanes()
        if let p = lastPath { update(p) }
        previewButton?.state = .on
        updateTitle()
    }

    /// Distribute the pane widths evenly after a pane was added or removed.
    func evenOutPanes() {
        let n = split.subviews.count
        guard n > 1 else { return }
        for i in 0..<(n - 1) {
            split.setPosition(split.frame.width * CGFloat(i + 1) / CGFloat(n), ofDividerAt: i)
        }
    }

    func updateTitle() {
        switch (term2 != nil, previewAttached) {
        case (true, true):  window.title = "conspectus — triple"
        case (true, false): window.title = "conspectus — split"
        default:            window.title = "conspectus"
        }
        updateFocusBorders()   // pane set changed — the indicator set changes with it
    }

    // MARK: NSSplitViewDelegate — window resize must not collapse a pane.
    // Keep the panes' ratios and enforce a minPane minimum per pane (also caps
    // divider dragging via the constrain methods). Works for 1–3 panes.
    func splitView(_ sv: NSSplitView, resizeSubviewsWithOldSize oldSize: NSSize) {
        if sv === outerSplit { layoutOuterPanes(); return }
        let n = sv.subviews.count
        guard n > 1 else { sv.adjustSubviews(); return }
        let total = sv.frame.width - CGFloat(n - 1) * sv.dividerThickness
        let oldTotal = oldSize.width - CGFloat(n - 1) * sv.dividerThickness
        // Scale each pane by the old ratio, clamp to the minimum, and put any
        // rounding/clamping slack into the last pane.
        var widths: [CGFloat]
        if oldTotal > 0 {
            widths = sv.subviews.map { max(minPane, total * ($0.frame.width / oldTotal)) }
        } else {
            widths = Array(repeating: total / CGFloat(n), count: n)
        }
        widths[n - 1] += total - widths.reduce(0, +)
        var x: CGFloat = 0
        for (i, v) in sv.subviews.enumerated() {
            v.frame = NSRect(x: x, y: 0, width: widths[i], height: sv.frame.height)
            x += widths[i] + sv.dividerThickness
        }
    }

    func splitView(_ sv: NSSplitView, constrainMinCoordinate p: CGFloat, ofSubviewAt i: Int) -> CGFloat {
        if sv === outerSplit { return max(p, minPane) }   // pane area keeps ≥ minPane height
        // Left of divider i sit panes 0…i and i dividers.
        return max(p, CGFloat(i + 1) * minPane + CGFloat(i) * sv.dividerThickness)
    }

    func splitView(_ sv: NSSplitView, constrainMaxCoordinate p: CGFloat, ofSubviewAt i: Int) -> CGFloat {
        if sv === outerSplit { return min(p, sv.frame.height - minTermHeight - sv.dividerThickness) }
        // Right of divider i sit panes i+1…n-1, each needing minPane + divider.
        let n = CGFloat(sv.subviews.count)
        return min(p, sv.frame.width - (n - 1 - CGFloat(i)) * (minPane + sv.dividerThickness))
    }
}
