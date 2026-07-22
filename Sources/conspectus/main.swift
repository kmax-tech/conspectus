import Cocoa
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

let cacheDir = (NSHomeDirectory() as NSString).appendingPathComponent(".cache/conspectus")
let fifoPath = (cacheDir as NSString).appendingPathComponent("target")

// Start directory: an explicit [path] arg (tilde/relative resolved), else $HOME.
// So Finder/launchd (which hand over "/") and a bare `conspectus` both open home.
func resolveStart(_ raw: String?) -> String {
    guard let raw = raw, !raw.isEmpty else { return NSHomeDirectory() }
    var p = (raw as NSString).expandingTildeInPath
    if !p.hasPrefix("/") {
        p = (FileManager.default.currentDirectoryPath as NSString).appendingPathComponent(p)
    }
    p = (p as NSString).standardizingPath
    var isDir: ObjCBool = false
    if FileManager.default.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue { return p }
    return NSHomeDirectory()
}

let cliArgs   = Array(CommandLine.arguments.dropFirst())
let splitMode = cliArgs.first == "split" || cliArgs.first == "-s"
let rest      = splitMode ? Array(cliArgs.dropFirst()) : cliArgs
let startPath = resolveStart(rest.first(where: { !$0.hasPrefix("-") }))
let command   = ProcessInfo.processInfo.environment["CONSPECTUS_CMD"] ?? "yazi"

// Follow the macOS system appearance: Catppuccin Latte in light mode, Mocha in
// dark. yazi picks its matching flavor by querying our background via OSC 11
// (SwiftTerm answers), so the whole panel stays one coherent theme.
func hexByte(_ v: UInt32, _ shift: UInt32) -> UInt16 { UInt16((v >> shift) & 0xff) * 257 }
func stColor(_ hex: String) -> SwiftTerm.Color {
    let v = UInt32(hex, radix: 16) ?? 0
    return SwiftTerm.Color(red: hexByte(v, 16), green: hexByte(v, 8), blue: hexByte(v, 0))
}
func nsColor(_ hex: String) -> NSColor {
    let v = UInt32(hex, radix: 16) ?? 0
    return NSColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255,
                   green: CGFloat((v >> 8) & 0xff) / 255,
                   blue: CGFloat(v & 0xff) / 255, alpha: 1)
}

struct Palette { let ansi: [String]; let bg: String; let fg: String; let cursor: String }

// 0-7 normal, 8-15 bright.
let mocha = Palette(
    ansi: ["45475A", "F38BA8", "A6E3A1", "F9E2AF", "89B4FA", "F5C2E7", "94E2D5", "BAC2DE",
           "585B70", "F38BA8", "A6E3A1", "F9E2AF", "89B4FA", "F5C2E7", "94E2D5", "A6ADC8"],
    bg: "1E1E2E", fg: "CDD6F4", cursor: "F5E0DC")
let latte = Palette(
    ansi: ["5C5F77", "D20F39", "40A02B", "DF8E1D", "1E66F5", "EA76CB", "179299", "ACB0BE",
           "6C6F85", "D20F39", "40A02B", "DF8E1D", "1E66F5", "EA76CB", "179299", "BCC0CC"],
    bg: "EFF1F5", fg: "4C4F69", cursor: "DC8A78")

func systemIsDark() -> Bool {
    UserDefaults.standard.string(forKey: "AppleInterfaceStyle")?.lowercased() == "dark"
}
func applyTheme(_ t: LocalProcessTerminalView) {
    let p = systemIsDark() ? mocha : latte
    t.installColors(p.ansi.map(stColor))
    t.nativeBackgroundColor = nsColor(p.bg)
    t.nativeForegroundColor = nsColor(p.fg)
    t.caretColor            = nsColor(p.cursor)
}
func activePalette() -> Palette { systemIsDark() ? mocha : latte }

func isDir(_ path: String) -> Bool {
    var d: ObjCBool = false
    return FileManager.default.fileExists(atPath: path, isDirectory: &d) && d.boolValue
}

// Curated extension -> (Nerd Font glyph, Catppuccin color). Uses the reliable
// Font Awesome file-type glyphs (f1c1-f1c9), so no tofu; colors approximate
// yazi's per-type scheme rather than mirroring its exact icon set.
func fileIcon(_ name: String, _ pal: Palette) -> (String, NSColor) {
    func c(_ i: Int) -> NSColor { nsColor(pal.ansi[i]) }   // 1 red 2 green 3 yellow 4 blue 5 pink 6 cyan
    let fg = nsColor(pal.fg)
    switch (name as NSString).pathExtension.lowercased() {
    case "jpg", "jpeg", "png", "gif", "webp", "bmp", "svg", "tiff", "tif", "heic", "ico", "avif":
        return ("\u{f1c5}", c(5))   // image
    case "pdf":
        return ("\u{f1c1}", c(1))   // pdf
    case "zip", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar", "zst":
        return ("\u{f1c6}", c(3))   // archive
    case "mp3", "wav", "flac", "m4a", "aac", "ogg":
        return ("\u{f1c7}", c(2))   // audio
    case "mp4", "mov", "mkv", "avi", "webm", "m4v":
        return ("\u{f1c8}", c(5))   // video
    case "md", "markdown", "rst", "txt", "text", "log", "org":
        return ("\u{f15c}", fg)     // text
    case "py", "js", "ts", "tsx", "jsx", "lua", "c", "cpp", "h", "hpp", "go", "rs",
         "swift", "sh", "bash", "zsh", "fish", "rb", "java", "json", "jsonl", "json5",
         "yaml", "yml", "toml", "html", "css", "scss", "tex", "vim", "el":
        return ("\u{f1c9}", c(2))   // code
    default:
        return ("\u{f15b}", fg)     // generic file
    }
}

// Directory look-ahead for the right pane: Quick Look only shows a folder's
// icon + metadata, so for directories we render the contents ourselves —
// folders first, natural sort, Nerd Font glyphs, Catppuccin colors per type.
func folderListing(_ dir: String) -> NSAttributedString {
    let pal = activePalette()
    let fg = nsColor(pal.fg), blue = nsColor(pal.ansi[4])
    let font = terminalFont()
    let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [])
        .filter { !$0.hasPrefix(".") }
    let sorted = names.sorted { a, b in
        let ad = isDir((dir as NSString).appendingPathComponent(a))
        let bd = isDir((dir as NSString).appendingPathComponent(b))
        if ad != bd { return ad }
        return a.localizedStandardCompare(b) == .orderedAscending
    }
    if sorted.isEmpty {
        return NSAttributedString(string: "  (empty)", attributes: [.font: font, .foregroundColor: fg])
    }
    let out = NSMutableAttributedString()
    for name in sorted {
        let d = isDir((dir as NSString).appendingPathComponent(name))
        let (glyph, color) = d ? ("\u{f07b}", blue) : fileIcon(name, pal)   // nf-fa-folder for dirs
        out.append(NSAttributedString(string: glyph + "  " + name + (d ? "/" : "") + "\n",
                                      attributes: [.font: font, .foregroundColor: color]))
    }
    return out
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
    func launch(_ t: LocalProcessTerminalView, extraEnv: [String: String]) {
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"; env["COLORTERM"] = "truecolor"
        env["YAZI_ID"] = nil; env["YAZI_LEVEL"] = nil
        for (k, v) in extraEnv { env[k] = v }
        t.startProcess(executable: "/bin/zsh",
                       args: ["-l", "-c", "cd \"\(startPath)\" && exec \(command)"],
                       environment: env.map { "\($0.key)=\($0.value)" })
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        // FIFO the left TUI writes hovered paths to (Quick Look coupling).
        try? FileManager.default.createDirectory(atPath: cacheDir, withIntermediateDirectories: true)
        unlink(fifoPath); mkfifo(fifoPath, 0o600)

        term = makeTerm()

        // Re-theme live when the user toggles macOS appearance.
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

        // Right pane: Quick Look preview (files) or a directory listing (folders).
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

        split = NSSplitView(frame: NSRect(x: 0, y: 0, width: 1340, height: 900))
        split.isVertical = true            // vertical divider -> panes side by side
        split.dividerStyle = .thin
        split.delegate = self              // keep proportions on resize, min widths
        split.addSubview(term)
        split.addSubview(rightContainer)
        split.setPosition(760, ofDividerAt: 0)

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1340, height: 900),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable],
                          backing: .buffered, defer: false)
        window.title = "conspectus"
        window.contentView = split
        window.center()

        // Titlebar toggle: swap the right pane between Quick Look preview and a
        // second yazi (dual-pane copy). A click never fights yazi for the keyboard.
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

        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(term)     // keystrokes go to the TUI
        buildMenu()                         // ⌘D split, ⌘⌥←/→ focus, ⌘Q/⌘H
        NSApp.applicationIconImage = conspectusIcon()   // Dock / Cmd-Tab icon
        NSApp.activate(ignoringOtherApps: true)

        // CONSPECTUS_PEER is a flag, not an id: it arms the `=` cd-sync (keymap
        // broadcasts via `ya pub-to 0`, the panesync plugin follows). yazi
        // auto-generates its own DDS ids, so no fixed ids are set here.
        launch(term, extraEnv: ["QLPEEK_FIFO": fifoPath, "CONSPECTUS_PEER": "L"])
        startFifoReader()

        if splitMode { addSecondPane() }   // launched with `split`: start dual-pane
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
        window.makeFirstResponder(term)
        splitButton?.state = .off
        window.title = "conspectus"
    }

    func startFifoReader() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            while true {
                guard let f = fopen(fifoPath, "r") else { usleep(100_000); continue }
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
        guard FileManager.default.fileExists(atPath: path, isDirectory: &d) else { return }
        let dir = d.boolValue
        lastPath = path
        DispatchQueue.main.async {
            if dir {
                // Folder: render its contents ourselves (Quick Look would only
                // show the folder icon + metadata).
                self.folderText.textStorage?.setAttributedString(folderListing(path))
                self.folderText.scroll(NSPoint.zero)
                self.preview.isHidden = true
                self.folderScroll.isHidden = false
            } else {
                // File: unhide the preview BEFORE setting its item — QLPreviewView
                // does not render an item assigned while it is hidden.
                self.folderScroll.isHidden = true
                self.preview.isHidden = false
                self.preview.previewItem = URL(fileURLWithPath: path) as QLPreviewItem
                self.preview.refreshPreviewItem()
            }
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

// Headless icon dump: `conspectus --icon <path>` renders the app icon to a PNG
// and exits (install-app.sh turns it into an .icns). Single source of truth for
// the icon is Icon.swift.
if let i = CommandLine.arguments.firstIndex(of: "--icon"), i + 1 < CommandLine.arguments.count {
    let img = conspectusIcon()
    if let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
       let png = rep.representation(using: .png, properties: [:]) {
        try? png.write(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
    }
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = Panel()
app.delegate = delegate
app.run()
