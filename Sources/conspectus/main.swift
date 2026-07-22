import Cocoa
import ConspectusCore
import Quartz
import SwiftTerm

// conspectus — a split window: a TUI file manager (yazi by default) running in an
// embedded terminal on the left, a live macOS Quick Look preview on the right.
//
// The file manager drives the preview by writing the hovered absolute path to a
// FIFO whose location is handed to it via the QLPEEK_FIFO env var. yazi does
// this through the `qlpeek send` plugin (which honours QLPEEK_FIFO). Any other
// TUI can drive it too by writing a path to $QLPEEK_FIFO on selection.
//
// Usage:
//   conspectus [path]          # yazi + Quick Look preview; start dir = path or $HOME
//   conspectus split [path]    # two yazi panes side by side (dual-pane copy)
// The TUI is yazi by default; override with the CONSPECTUS_CMD env var.
//
// Pure helpers (start-dir resolution, palettes, icon mapping, sort order) live
// in the ConspectusCore library target so they are unit-testable; this file is
// the AppKit shell around them.

/// Write a warning line to stderr. Side effects: writes to stderr.
func warn(_ msg: String) {
    FileHandle.standardError.write(Data((msg + "\n").utf8))
}

/// Report a fatal startup error and exit. Side effects: writes to stderr,
/// terminates the process with exit code 1.
func die(_ msg: String) -> Never {
    warn(msg)
    exit(1)
}

// Headless icon dump: `conspectus --icon <path>` renders the app icon to a PNG
// and exits (install-app.sh turns it into an .icns). Handled before anything
// else so the <path> argument is never mistaken for a start directory. Single
// source of truth for the icon is Icon.swift.
if let i = CommandLine.arguments.firstIndex(of: "--icon"), i + 1 < CommandLine.arguments.count {
    let out = CommandLine.arguments[i + 1]
    let img = conspectusIcon()
    guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        die("conspectus: could not render the icon to PNG")
    }
    do {
        try png.write(to: URL(fileURLWithPath: out))
    } catch {
        die("conspectus: cannot write icon to \(out): \(error.localizedDescription)")
    }
    exit(0)
}

let cacheDir = (NSHomeDirectory() as NSString).appendingPathComponent(".cache/conspectus")
let fifoPath = (cacheDir as NSString).appendingPathComponent("target")

// Last cwd: yazi writes it here on exit (--cwd-file); a bare `conspectus`
// resumes there, falling back to $HOME.
let lastCwdPath = (cacheDir as NSString).appendingPathComponent("last-cwd")

let cliArgs   = Array(CommandLine.arguments.dropFirst())
let splitMode = cliArgs.first == "split" || cliArgs.first == "-s"
let rest      = splitMode ? Array(cliArgs.dropFirst()) : cliArgs
let start     = resolveStart(rest.first(where: { !$0.hasPrefix("-") }), lastCwdFile: lastCwdPath)
let startPath = start.path
let command   = ProcessInfo.processInfo.environment["CONSPECTUS_CMD"] ?? "yazi"

// An explicit [path] that isn't a directory falls back to $HOME — say so
// instead of silently starting somewhere the user didn't ask for.
if let w = start.warning { warn(w) }

// Follow the macOS system appearance: Catppuccin Latte in light mode, Mocha in
// dark. yazi picks its matching flavor by querying our background via OSC 11
// (SwiftTerm answers), so the whole panel stays one coherent theme.
func systemIsDark() -> Bool {
    UserDefaults.standard.string(forKey: "AppleInterfaceStyle")?.lowercased() == "dark"
}

func activePalette() -> Palette { systemIsDark() ? mocha : latte }

/// SwiftTerm color from a palette hex string (validated by Palette's init;
/// see nsColor in ConspectusCore for why try! is the honest choice here).
func stColor(_ hex: String) -> SwiftTerm.Color {
    let v = try! parseHexColor(hex)
    func chan(_ shift: UInt32) -> UInt16 { UInt16((v >> shift) & 0xff) * 257 }
    return SwiftTerm.Color(red: chan(16), green: chan(8), blue: chan(0))
}

func applyTheme(_ t: LocalProcessTerminalView) {
    let p = activePalette()
    t.installColors(p.ansi.map(stColor))
    t.nativeBackgroundColor = nsColor(p.bg)
    t.nativeForegroundColor = nsColor(p.fg)
    t.caretColor            = nsColor(p.cursor)
}

// A Nerd Font so yazi's icon glyphs render. Override with CONSPECTUS_FONT /
// CONSPECTUS_FONT_SIZE; falls back through installed Nerd Fonts, then plain mono.
func terminalFont() -> NSFont {
    let env = ProcessInfo.processInfo.environment
    let size = Double(env["CONSPECTUS_FONT_SIZE"] ?? "") ?? 14
    var names = ["JetBrainsMono Nerd Font Mono", "JetBrainsMono Nerd Font",
                 "Hack Nerd Font Mono", "MesloLGS NF"]
    if let override = env["CONSPECTUS_FONT"], !override.isEmpty { names.insert(override, at: 0) }
    for n in names {
        if let f = NSFont(name: n, size: size) { return f }
    }
    return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
}

// Directory look-ahead for the right pane: Quick Look only shows a folder's
// icon + metadata, so for directories we render the contents ourselves —
// folders first, natural sort, Nerd Font glyphs, Catppuccin colors per type.
func folderListing(_ dir: String) -> NSAttributedString {
    let pal = activePalette()
    let fg = nsColor(pal.fg), blue = nsColor(pal.ansi[4])
    let font = terminalFont()
    let names: [String]
    do {
        names = try FileManager.default.contentsOfDirectory(atPath: dir).filter { !$0.hasPrefix(".") }
    } catch {
        // The folder can vanish (or lose permission) between hover and render —
        // show the failure in the pane instead of a silently empty listing.
        return NSAttributedString(string: "  (unreadable: \(error.localizedDescription))",
                                  attributes: [.font: font, .foregroundColor: fg])
    }
    let entries = sortEntries(names.map {
        DirEntry(name: $0, isDir: isDirectory((dir as NSString).appendingPathComponent($0)))
    })
    if entries.isEmpty {
        return NSAttributedString(string: "  (empty)", attributes: [.font: font, .foregroundColor: fg])
    }
    let out = NSMutableAttributedString()
    for e in entries {
        let icon = e.isDir ? FileIcon(glyph: "\u{f07b}", color: blue)   // nf-fa-folder for dirs
                           : fileIcon(e.name, pal)
        out.append(NSAttributedString(string: icon.glyph + "  " + e.name + (e.isDir ? "/" : "") + "\n",
                                      attributes: [.font: font, .foregroundColor: icon.color]))
    }
    return out
}

final class Panel: NSObject, NSApplicationDelegate, LocalProcessTerminalViewDelegate, NSSplitViewDelegate {
    var window: NSWindow!
    var split: NSSplitView!
    var rightContainer: NSView!
    var splitButton: NSButton!
    var term: LocalProcessTerminalView!
    var term2: LocalProcessTerminalView?
    var preview: QLPreviewView!
    var folderScroll: NSScrollView!
    var folderText: NSTextView!
    var lastPath: String?
    var lastWasDir = false

    func makeTerm() -> LocalProcessTerminalView {
        let t = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 700, height: 900))
        t.font = terminalFont()           // Nerd Font before startProcess so cols/rows are sized right
        applyTheme(t)                     // Catppuccin, following system light/dark
        t.processDelegate = self
        return t
    }

    // Login shell so PATH/config load, then exec the file manager. YAZI_ID/LEVEL
    // stripped so each pane is a fresh, separate yazi instance (they discover
    // each other via the DDS for cross-instance yank/paste).
    func launch(_ t: LocalProcessTerminalView, extraEnv: [String: String], rememberCwd: Bool = false) {
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"; env["COLORTERM"] = "truecolor"
        env["YAZI_ID"] = nil; env["YAZI_LEVEL"] = nil
        for (k, v) in extraEnv { env[k] = v }
        // Left/yazi pane records its cwd on exit so the next bare launch resumes there.
        let cwdFlag = (rememberCwd && command == "yazi") ? " --cwd-file \"\(lastCwdPath)\"" : ""
        t.startProcess(executable: "/bin/zsh",
                       args: ["-l", "-c", "cd \"\(startPath)\" && exec \(command)\(cwdFlag)"],
                       environment: env.map { "\($0.key)=\($0.value)" })
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        createFifo()
        term = makeTerm()
        observeAppearanceChanges()
        buildRightPane()
        buildSplitView()
        buildWindow()
        addTitlebarSplitButton()

        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(term)     // keystrokes go to the TUI
        buildMenu()                         // ⌘D split, ⌘⌥←/→ focus, ⌘Q/⌘H
        NSApp.applicationIconImage = conspectusIcon()   // Dock / Cmd-Tab icon
        NSApp.activate(ignoringOtherApps: true)

        // CONSPECTUS_PEER is a flag, not an id: it arms the `=` cd-sync (keymap
        // broadcasts via `ya pub-to 0`, the panesync plugin follows). yazi
        // auto-generates its own DDS ids, so no fixed ids are set here.
        launch(term, extraEnv: ["QLPEEK_FIFO": fifoPath, "CONSPECTUS_PEER": "L"], rememberCwd: true)
        startFifoReader()

        if splitMode { addSecondPane() }   // launched with `split`: start dual-pane
    }

    /// Create the FIFO the left TUI writes hovered paths to (Quick Look
    /// coupling). Without it the preview can never update, so failure is
    /// fatal and reported, not swallowed.
    /// Side effects: creates the cache directory, replaces the FIFO on disk.
    func createFifo() {
        do {
            try FileManager.default.createDirectory(atPath: cacheDir, withIntermediateDirectories: true)
        } catch {
            die("conspectus: cannot create cache directory \(cacheDir): \(error.localizedDescription)")
        }
        unlink(fifoPath)
        guard mkfifo(fifoPath, 0o600) == 0 else {
            die("conspectus: mkfifo(\(fifoPath)) failed: \(String(cString: strerror(errno)))")
        }
    }

    /// Re-theme live when the user toggles the macOS appearance.
    func observeAppearanceChanges() {
        DistributedNotificationCenter.default.addObserver(
            forName: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil, queue: .main) { [weak self] _ in
            guard let self = self else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                applyTheme(self.term)
                if let t2 = self.term2 { applyTheme(t2) }
                self.styleFolder()
                if let p = self.lastPath { self.update(p) }
            }
        }
    }

    /// Build the right pane: Quick Look preview (files) stacked with a
    /// directory listing (folders); `update` toggles which one is visible.
    func buildRightPane() {
        rightContainer = NSView(frame: NSRect(x: 0, y: 0, width: 620, height: 900))
        preview = QLPreviewView(frame: rightContainer.bounds, style: .normal) ?? QLPreviewView()
        preview.autoresizingMask = [.width, .height]
        folderScroll = NSScrollView(frame: rightContainer.bounds)
        folderScroll.hasVerticalScroller = true
        folderScroll.autoresizingMask = [.width, .height]
        folderText = NSTextView(frame: rightContainer.bounds)
        folderText.isEditable = false
        folderText.isVerticallyResizable = true
        folderText.isHorizontallyResizable = false
        folderText.autoresizingMask = [.width]
        folderText.textContainerInset = NSSize(width: 10, height: 10)
        folderText.textContainer?.widthTracksTextView = true
        folderScroll.documentView = folderText
        folderScroll.isHidden = true
        styleFolder()
        rightContainer.addSubview(preview)
        rightContainer.addSubview(folderScroll)
    }

    /// Build the split view holding terminal (left) and preview (right).
    func buildSplitView() {
        split = NSSplitView(frame: NSRect(x: 0, y: 0, width: 1340, height: 900))
        split.isVertical = true            // vertical divider -> panes side by side
        split.dividerStyle = .thin
        split.delegate = self              // keep proportions on resize, min widths
        split.addSubview(term)
        split.addSubview(rightContainer)
        split.setPosition(760, ofDividerAt: 0)
    }

    /// Build the main window; remembers size/position across launches
    /// (including the split layout width).
    func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1340, height: 900),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable],
                          backing: .buffered, defer: false)
        window.title = "conspectus"
        window.contentView = split
        if !window.setFrameUsingName("ConspectusMain") { window.center() }
        window.setFrameAutosaveName("ConspectusMain")
    }

    /// Titlebar toggle: swap the right pane between Quick Look preview and a
    /// second yazi (dual-pane copy). A click never fights yazi for the keyboard.
    func addTitlebarSplitButton() {
        let btn = NSButton(title: " Split ", target: self, action: #selector(toggleSecondPane))
        btn.setButtonType(.pushOnPushOff)
        btn.bezelStyle = .rounded
        if let img = NSImage(systemSymbolName: "rectangle.split.2x1", accessibilityDescription: "Split") {
            btn.image = img; btn.imagePosition = .imageLeading
        }
        btn.sizeToFit()
        splitButton = btn
        let acc = NSTitlebarAccessoryViewController()
        acc.layoutAttribute = .right
        acc.view = btn
        window.addTitlebarAccessoryViewController(acc)
    }

    // Minimal main menu so the app is keyboard-centric: menu key equivalents are
    // handled before the terminal view sees the keys (SwiftTerm has no
    // performKeyEquivalent), so nothing is intercepted inside yazi itself.
    //   ⌘D  toggle split pane (kitty muscle memory)
    //   ⌘⌥← / ⌘⌥→  focus left / right pane (Alt+arrow habit + Cmd)
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
        let left = NSMenuItem(title: "Focus Left Pane", action: #selector(focusLeftPane),
                              keyEquivalent: String(UnicodeScalar(NSLeftArrowFunctionKey)!))
        left.keyEquivalentModifierMask = [.command, .option]; left.target = self
        viewMenu.addItem(left)
        let right = NSMenuItem(title: "Focus Right Pane", action: #selector(focusRightPane),
                               keyEquivalent: String(UnicodeScalar(NSRightArrowFunctionKey)!))
        right.keyEquivalentModifierMask = [.command, .option]; right.target = self
        viewMenu.addItem(right)
        viewItem.submenu = viewMenu

        NSApp.mainMenu = main
    }

    @objc func focusLeftPane()  { window.makeFirstResponder(term) }
    @objc func focusRightPane() { if let t2 = term2 { window.makeFirstResponder(t2) } }

    @objc func toggleSecondPane() { term2 == nil ? addSecondPane() : removeSecondPane() }

    func addSecondPane() {
        guard term2 == nil else { return }
        let t2 = makeTerm()
        term2 = t2
        split.replaceSubview(rightContainer, with: t2)
        split.setPosition(split.frame.width * 0.5, ofDividerAt: 0)
        launch(t2, extraEnv: ["CONSPECTUS_PEER": "R"])
        window.makeFirstResponder(t2)
        splitButton?.state = .on
        window.title = "conspectus — split"
    }

    func removeSecondPane() {
        guard let t2 = term2 else { return }
        term2 = nil
        if t2.superview != nil {
            split.replaceSubview(t2, with: rightContainer)
            split.setPosition(split.frame.width * 0.56, ofDividerAt: 0)
        }
        t2.terminate()
        // rightContainer just re-entered the window, but its QLPreviewView
        // auto-closed when it left — reusing it would trip QuickLook's
        // assertion (SIGABRT). Rebuild it and restore the last hovered item.
        rebuildPreview()
        lastWasDir = false
        if let p = lastPath { update(p) }
        window.makeFirstResponder(term)
        splitButton?.state = .off
        window.title = "conspectus"
    }

    /// Replace the `QLPreviewView` with a fresh instance, keeping frame and
    /// visibility. A `QLPreviewView` closes itself (its remote Quick Look
    /// extension goes away) when it leaves the window hierarchy or spends time
    /// hidden; setting `previewItem` on a closed view aborts the app with a
    /// QuickLook assertion — rebuilding is the only safe way back.
    func rebuildPreview() {
        let fresh = QLPreviewView(frame: preview.frame, style: .normal) ?? QLPreviewView()
        fresh.autoresizingMask = [.width, .height]
        fresh.isHidden = preview.isHidden
        rightContainer.replaceSubview(preview, with: fresh)
        preview = fresh
    }

    func startFifoReader() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var warnedOpenFailure = false
            while true {
                guard let f = fopen(fifoPath, "r") else {
                    // fopen on a FIFO blocks until a writer appears, so failure
                    // means the FIFO itself is gone/broken. Deliberate policy:
                    // warn once (not every 100ms) and keep retrying — the
                    // preview degrades, the app stays usable.
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
        DispatchQueue.main.async {
            // Split mode: the right pane is a second terminal; rightContainer is
            // out of the window and its QLPreviewView has auto-closed. Touching
            // it would abort the app (QuickLook assertion), so skip the view
            // work — lastPath keeps tracking, and removeSecondPane restores the
            // preview from it when the split is toggled off.
            if self.term2 != nil { return }
            if dir {
                // Folder: render its contents ourselves (Quick Look would only
                // show the folder icon + metadata).
                self.folderText.textStorage?.setAttributedString(folderListing(path))
                self.folderText.scroll(NSPoint.zero)
                self.preview.isHidden = true
                self.folderScroll.isHidden = false
            } else {
                self.folderScroll.isHidden = true
                if self.lastWasDir {
                    // dir -> file: a QLPreviewView that spent time hidden can come
                    // back permanently blank (its remote QL extension goes away).
                    // Rebuild the view from scratch — file -> file keeps the fast
                    // in-place swap.
                    self.rebuildPreview()
                }
                self.preview.isHidden = false
                self.preview.previewItem = URL(fileURLWithPath: path) as QLPreviewItem
                self.preview.refreshPreviewItem()
            }
            self.lastWasDir = dir
        }
    }

    // MARK: NSSplitViewDelegate — window resize must not collapse a pane.
    // Keep the panes' ratio and enforce a 300pt minimum on both sides (also
    // caps divider dragging via the constrain methods).
    let minPane: CGFloat = 300

    func splitView(_ sv: NSSplitView, resizeSubviewsWithOldSize oldSize: NSSize) {
        guard sv.subviews.count == 2 else { sv.adjustSubviews(); return }
        let total = sv.frame.width - sv.dividerThickness
        let oldTotal = oldSize.width - sv.dividerThickness
        let ratio = oldTotal > 0 ? sv.subviews[0].frame.width / oldTotal : 0.56
        let leftW = max(minPane, min(total - minPane, total * ratio))
        sv.subviews[0].frame = NSRect(x: 0, y: 0, width: leftW, height: sv.frame.height)
        sv.subviews[1].frame = NSRect(x: leftW + sv.dividerThickness, y: 0,
                                      width: total - leftW, height: sv.frame.height)
    }
    func splitView(_ sv: NSSplitView, constrainMinCoordinate p: CGFloat, ofSubviewAt i: Int) -> CGFloat {
        max(p, minPane)
    }
    func splitView(_ sv: NSSplitView, constrainMaxCoordinate p: CGFloat, ofSubviewAt i: Int) -> CGFloat {
        min(p, sv.frame.width - minPane)
    }

    // MARK: LocalProcessTerminalViewDelegate
    func processTerminated(source: TerminalView, exitCode: Int32?) {
        DispatchQueue.main.async {
            if source === self.term {
                unlink(fifoPath); NSApp.terminate(nil)   // left pane quit -> close app
            } else {
                self.removeSecondPane()                  // second pane's yazi quit -> collapse
            }
        }
    }
    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = Panel()
app.delegate = delegate
app.run()
