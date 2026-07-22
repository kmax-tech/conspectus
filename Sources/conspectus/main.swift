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
//   conspectus triple [path]   # two yazi panes + preview following the active one
// The TUI is yazi by default; override with the CONSPECTUS_CMD env var.
//
// In triple mode both yazi instances write to the same FIFO; only the pane
// being navigated emits hover events, so the preview follows the active
// instance without any focus tracking.
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

let cliArgs    = Array(CommandLine.arguments.dropFirst())
let splitMode  = cliArgs.first == "split" || cliArgs.first == "-s"
let tripleMode = cliArgs.first == "triple" || cliArgs.first == "-3"
let rest       = (splitMode || tripleMode) ? Array(cliArgs.dropFirst()) : cliArgs
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
// `size` overrides the configured size (used by the smaller shortcut bar).
func terminalFont(size overrideSize: Double? = nil) -> NSFont {
    let env = ProcessInfo.processInfo.environment
    let size = overrideSize ?? (Double(env["CONSPECTUS_FONT_SIZE"] ?? "") ?? 14)
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
// Loading (ConspectusCore.loadFolder: bulk isDirectory keys, sort, cap)
// happens off the main thread; only a screenful is rendered anyway, and
// "… and N more" makes the cut visible.
let folderListingCap = 500

/// Render loaded folder contents in the current theme. Does no I/O — safe to
/// build off the main thread; TextKit layout happens when the result is
/// applied to the text view on main.
func renderListing(_ contents: FolderContents) -> NSAttributedString {
    let pal = activePalette()
    let fg = nsColor(pal.fg), blue = nsColor(pal.ansi[4])
    let font = terminalFont()
    if let err = contents.error {
        // Folder vanished or lost permission mid-hover — show it in the pane
        // instead of a silently empty listing.
        return NSAttributedString(string: "  (unreadable: \(err))",
                                  attributes: [.font: font, .foregroundColor: fg])
    }
    if contents.entries.isEmpty {
        return NSAttributedString(string: "  (empty)", attributes: [.font: font, .foregroundColor: fg])
    }
    let out = NSMutableAttributedString()
    for e in contents.entries {
        let icon = e.isDir ? FileIcon(glyph: "\u{f07b}", color: blue)   // nf-fa-folder for dirs
                           : fileIcon(e.name, pal)
        out.append(NSAttributedString(string: icon.glyph + "  " + e.name + (e.isDir ? "/" : "") + "\n",
                                      attributes: [.font: font, .foregroundColor: icon.color]))
    }
    if contents.omitted > 0 {
        out.append(NSAttributedString(string: "\n  … and \(contents.omitted) more entries\n",
                                      attributes: [.font: font,
                                                   .foregroundColor: fg.withAlphaComponent(0.6)]))
    }
    return out
}

/// QLPreviewView that never takes keyboard focus — the keyboard belongs to
/// the terminal panes (the app's keyboard-centric contract); the preview is
/// mouse-only. Prevents "keys dead after app switch" states where the
/// preview ends up first responder and silently swallows hjkl/arrows.
final class NoFocusPreviewView: QLPreviewView {
    override var acceptsFirstResponder: Bool { false }
}

final class Panel: NSObject, NSApplicationDelegate, LocalProcessTerminalViewDelegate, NSSplitViewDelegate {
    var window: NSWindow!
    var split: NSSplitView!
    var rightContainer: NSView!
    var splitButton: NSButton!
    var previewButton: NSButton!
    var term: LocalProcessTerminalView!
    var term2: LocalProcessTerminalView?
    var preview: QLPreviewView!
    var folderScroll: NSScrollView!
    var folderText: NSTextView!
    var outerSplit: NSSplitView!
    var bottomTerm: LocalProcessTerminalView?
    var hintBar: NSView!
    var hintText: NSTextField!
    var cheatPanel: NSPanel?
    var cheatText: NSTextView?
    var lastPath: String?
    var lastWasDir = false
    weak var lastFocusedTerm: LocalProcessTerminalView?

    // Folder listings load off the main thread; this generation counter is
    // the cancellation: every hover (file or folder) bumps it, and an
    // in-flight load checks it after the disk I/O (skipping the string build
    // for stale results) and again before applying — navigating on drops
    // outdated work instead of rendering it out of order.
    private var listingGen = 0
    private let listingGenLock = NSLock()

    /// Invalidate all in-flight folder loads and return the new generation.
    func bumpListingGeneration() -> Int {
        listingGenLock.lock(); defer { listingGenLock.unlock() }
        listingGen += 1
        return listingGen
    }

    /// True while `gen` is still the newest hover.
    func isCurrentListing(_ gen: Int) -> Bool {
        listingGenLock.lock(); defer { listingGenLock.unlock() }
        return gen == listingGen
    }

    // Bottom shortcut bar: training wheels until the muscle memory sits.
    // Toggled with ⌘/ ; visibility persists across launches (UserDefaults).
    let hintBarHeight: CGFloat = 26
    let showHintsKey = "ConspectusShowHints"
    // The most-used yazi keys (defaults) plus conspectus's own shortcuts.
    // y→p means: y (yank), then p (paste) — across panes in split mode too.
    // cc/cf are yazi's copy-to-clipboard submenu (path / filename).
    let shortcutHints: [(key: String, label: String)] = [
        ("y→p", "copy"), ("x→p", "move"), ("d", "trash"), ("r", "rename"),
        ("a", "new"), ("cc", "path"), ("cf", "name"), ("␣", "select"),
        ("/", "find"),
        ("⌘D", "split"), ("⌘E", "preview"), ("⌘J", "terminal"), ("⌘K", "all keys"), ("⌘/", "bar"),
    ]

    // Full cheat sheet (⌘K): yazi's default mgr keymap, grouped, plus the
    // conspectus keys. The user's own keymap.toml is parsed on every open
    // (ConspectusCore.parseYaziKeymap) and shown as its own group on top;
    // parse problems appear in the panel footer instead of being swallowed.
    let cheatSheetGroups: [(title: String, entries: [(String, String)])] = [
        ("Navigate", [("h / ←", "parent directory"), ("l / →", "enter / open"),
                      ("j / k", "down / up"), ("g g", "to top"), ("G", "to bottom"),
                      ("H / L", "history back / forward"), ("z", "jump (zoxide)"), ("Z", "jump (fzf)")]),
        ("Select", [("Space", "toggle + move down"), ("v", "visual mode"),
                    ("Esc", "clear selection"), ("Ctrl a", "select all")]),
        ("Files", [("o / Enter", "open"), ("O", "open with …"),
                   ("y", "yank (copy)"), ("x", "cut"), ("p", "paste"), ("P", "paste (overwrite)"),
                   ("Y / X", "cancel yank"), ("d", "trash"), ("D", "delete permanently"),
                   ("a", "create (dir: end with /)"), ("r", "rename"), (".", "toggle hidden")]),
        ("Clipboard", [("c c", "copy full path"), ("c d", "copy dirname"),
                       ("c f", "copy filename"), ("c n", "copy name w/o extension")]),
        ("Find", [("/", "find"), ("n / N", "next / previous match"), ("f", "filter"),
                  ("s", "search files (fd)"), ("S", "search content (rg)")]),
        ("Tabs", [("t", "new tab"), ("1…9", "switch tab"), ("[ / ]", "previous / next tab")]),
        ("Misc", [("w", "task manager"), (",", "sort menu"), ("~", "yazi help"), ("q", "quit")]),
        ("conspectus", [("⌘D", "toggle split pane"), ("⌘E", "toggle preview pane"),
                        ("⌘J", "terminal panel (opens in yazi's dir)"),
                        ("⌘/", "toggle shortcut bar"), ("⌘K", "this cheat sheet"),
                        ("⌘⌥← →", "focus left / right pane"), ("=", "sync cd to other pane")]),
    ]

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
        UserDefaults.standard.register(defaults: [showHintsKey: true])   // bar starts visible
        createFifo()
        term = makeTerm()
        observeAppearanceChanges()
        buildRightPane()
        buildSplitView()
        buildOuterSplit()
        buildHintBar()
        buildWindow()
        addTitlebarButtons()

        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(term)     // keystrokes go to the TUI
        buildMenu()                         // ⌘D split, ⌘E preview, ⌘J terminal, ⌘/ bar, ⌘⌥←/→ focus
        NSApp.applicationIconImage = conspectusIcon()   // Dock / Cmd-Tab icon
        NSApp.activate(ignoringOtherApps: true)

        // CONSPECTUS_PEER is a flag, not an id: it arms the `=` cd-sync (keymap
        // broadcasts via `ya pub-to 0`, the panesync plugin follows). yazi
        // auto-generates its own DDS ids, so no fixed ids are set here.
        launch(term, extraEnv: ["QLPEEK_FIFO": fifoPath, "CONSPECTUS_PEER": "L"], rememberCwd: true)
        startFifoReader()

        // Pane layout is two independent toggles: the second yazi pane (⌘D)
        // and the preview pane (⌘E, always rightmost). `split` starts 2-pane
        // without preview, `triple` starts with both.
        if splitMode { detachPreview() }
        if splitMode || tripleMode { addSecondPane() }

        startMainThreadWatchdog()
    }

    /// Main-thread watchdog: a utility thread pings the main thread every 2s;
    /// if a ping goes unanswered for 2s the UI is frozen. The stall is then
    /// logged to stderr and `/usr/bin/sample` captures our own call stacks to
    /// ~/.cache/conspectus/freeze-<timestamp>.txt, so the cause of a beachball
    /// is diagnosable after the fact. Throttled to one sample per 30s.
    /// Side effects: writes sample reports into the cache directory.
    func startMainThreadWatchdog() {
        DispatchQueue.global(qos: .utility).async {
            var lastSample = Date.distantPast
            while true {
                let sem = DispatchSemaphore(value: 0)
                DispatchQueue.main.async { sem.signal() }
                if sem.wait(timeout: .now() + 2.0) == .timedOut {
                    if Date().timeIntervalSince(lastSample) > 30 {
                        lastSample = Date()
                        let out = (cacheDir as NSString)
                            .appendingPathComponent("freeze-\(Int(Date().timeIntervalSince1970)).txt")
                        warn("conspectus: main thread stalled >2s — sampling to \(out)")
                        let p = Process()
                        p.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
                        p.arguments = ["\(getpid())", "3", "-file", out]
                        // Deliberate try?: diagnostics must never crash the app;
                        // a failed sample still leaves the stall warning above.
                        try? p.run()
                        p.waitUntilExit()
                    }
                    sem.wait()   // consume the late signal once main recovers
                }
                usleep(2_000_000)
            }
        }
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
                if let bt = self.bottomTerm { applyTheme(bt) }
                self.styleFolder()
                self.styleHintBar()
                self.styleCheatSheet()
                if let p = self.lastPath { self.update(p) }
            }
        }
    }

    /// Build the right pane: Quick Look preview (files) stacked with a
    /// directory listing (folders); `update` toggles which one is visible.
    func buildRightPane() {
        rightContainer = NSView(frame: NSRect(x: 0, y: 0, width: 620, height: 900))
        preview = NoFocusPreviewView(frame: rightContainer.bounds, style: .normal) ?? NoFocusPreviewView()
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

    /// Build the outer vertical stack: the pane split on top, optionally the
    /// bottom terminal (⌘J) below it.
    func buildOuterSplit() {
        outerSplit = NSSplitView(frame: NSRect(x: 0, y: 0, width: 1340, height: 900))
        outerSplit.isVertical = false      // horizontal divider -> stacked panes
        outerSplit.dividerStyle = .thin
        outerSplit.delegate = self
        outerSplit.addSubview(split)
    }

    // MARK: bottom terminal (⌘J) — a plain zsh in the dir yazi is visiting.
    // Deliberately no live cd-follow (typing `cd` into a running interactive
    // shell could clobber the user's input): closing (⌘J or `exit`) kills the
    // shell, reopening starts a fresh one in the current yazi dir.
    let termPanelHeight: CGFloat = 240
    let minTermHeight: CGFloat = 120

    @objc func toggleBottomTerminal() { bottomTerm == nil ? openBottomTerminal() : closeBottomTerminal() }

    /// The directory currently visited in the active yazi pane, derived from
    /// the last hovered path — hover events always come from the listing of
    /// the directory containing them. Falls back to the start dir before the
    /// first hover.
    func currentYaziDir() -> String {
        guard let p = lastPath else { return startPath }
        return (p as NSString).deletingLastPathComponent
    }

    /// Open the bottom terminal: a fresh interactive login zsh in the current
    /// yazi dir. A failed cd prints its error into the terminal itself and
    /// the shell still starts (visible, not swallowed).
    func openBottomTerminal() {
        guard bottomTerm == nil else { return }
        let t = makeTerm()
        bottomTerm = t
        outerSplit.addSubview(t)
        layoutOuterPanes(terminalHeight: termPanelHeight)   // frames BEFORE startProcess so cols/rows fit
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"; env["COLORTERM"] = "truecolor"
        t.startProcess(executable: "/bin/zsh",
                       args: ["-l", "-c", "cd \"\(currentYaziDir())\"; exec zsh -i"],
                       environment: env.map { "\($0.key)=\($0.value)" })
        window.makeFirstResponder(t)
    }

    /// Close the bottom terminal and kill its shell (a fresh one is started
    /// per open — that is how the panel "follows" yazi's dir).
    func closeBottomTerminal() {
        guard let t = bottomTerm else { return }
        bottomTerm = nil
        if t.superview != nil { t.removeFromSuperview() }
        t.terminate()
        layoutOuterPanes()
        window.makeFirstResponder(term)
    }

    /// Lay the outer stack out explicitly: the pane area fills the space, the
    /// bottom terminal (if open) gets `terminalHeight` (or keeps its current
    /// height), clamped to the minimums. NSSplitView's setPosition/delegate
    /// layout proved unreliable for programmatic add/remove (the added view
    /// ended up 0pt high), so the frames are set directly.
    func layoutOuterPanes(terminalHeight: CGFloat? = nil) {
        let w = outerSplit.frame.width
        let h = outerSplit.frame.height
        guard let t = bottomTerm, t.superview === outerSplit else {
            split.frame = NSRect(x: 0, y: 0, width: w, height: h)
            return
        }
        let want = terminalHeight ?? t.frame.height
        let termH = min(max(minTermHeight, want),
                        max(minTermHeight, h - minPane - outerSplit.dividerThickness))
        let mainH = h - termH - outerSplit.dividerThickness
        split.frame = NSRect(x: 0, y: 0, width: w, height: mainH)
        t.frame = NSRect(x: 0, y: mainH + outerSplit.dividerThickness, width: w, height: termH)
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

    /// Toggle the floating cheat-sheet panel (full grouped key list — the
    /// native, scrollable version of yazi's `~` help).
    @objc func toggleCheatSheet() {
        if let p = cheatPanel, p.isVisible { p.orderOut(nil); return }
        if cheatPanel == nil { buildCheatSheet() }
        styleCheatSheet()
        cheatPanel?.makeKeyAndOrderFront(nil)
    }

    /// Build the floating panel holding the cheat sheet; frame persists
    /// across launches.
    func buildCheatSheet() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 660),
                            styleMask: [.titled, .closable, .resizable, .utilityWindow],
                            backing: .buffered, defer: false)
        panel.title = "Shortcuts"
        panel.isFloatingPanel = true
        let scroll = NSScrollView(frame: panel.contentView!.bounds)
        scroll.hasVerticalScroller = true
        scroll.autoresizingMask = [.width, .height]
        let tv = NSTextView(frame: scroll.bounds)
        tv.isEditable = false
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainerInset = NSSize(width: 12, height: 12)
        tv.textContainer?.widthTracksTextView = true
        scroll.documentView = tv
        panel.contentView = scroll
        if !panel.setFrameUsingName("ConspectusCheatSheet") { panel.center() }
        panel.setFrameAutosaveName("ConspectusCheatSheet")
        cheatPanel = panel
        cheatText = tv
    }

    /// Read the user's yazi keymap for the cheat sheet. Returns the bindings
    /// plus a status line for the panel footer — a missing file is normal
    /// (defaults only), a parse failure is reported there, never swallowed.
    func loadUserKeymap() -> (bindings: [KeymapBinding], status: String) {
        let configHome = ProcessInfo.processInfo.environment["YAZI_CONFIG_HOME"]
            ?? (NSHomeDirectory() as NSString).appendingPathComponent(".config/yazi")
        let path = (configHome as NSString).appendingPathComponent("keymap.toml")
        guard FileManager.default.fileExists(atPath: path) else {
            return ([], "no keymap.toml found — yazi defaults only")
        }
        do {
            let toml = try String(contentsOfFile: path, encoding: .utf8)
            let bindings: [KeymapBinding]
            do {
                bindings = try parseYaziKeymap(toml)
            } catch KeymapParseError.missingSection {
                bindings = try parseYaziKeymap(toml, section: "manager")   // pre-25.x name
            }
            return (bindings, "yazi defaults + \(bindings.count) bindings from your keymap.toml")
        } catch {
            return ([], "keymap.toml not parsed (\(error)) — yazi defaults only")
        }
    }

    /// (Re-)render the cheat sheet in the active palette; called on open and
    /// whenever the system appearance changes. Re-reads keymap.toml each time
    /// so config edits show up on the next ⌘K.
    func styleCheatSheet() {
        guard let tv = cheatText else { return }
        let pal = activePalette()
        tv.drawsBackground = true
        tv.backgroundColor = nsColor(pal.bg)
        tv.enclosingScrollView?.drawsBackground = true
        tv.enclosingScrollView?.backgroundColor = nsColor(pal.bg)
        let font = terminalFont(size: 12)
        let headColor = nsColor(pal.ansi[4])   // blue group headers
        let keyColor = nsColor(pal.ansi[3])    // yellow keys
        let fg = nsColor(pal.fg)
        let user = loadUserKeymap()
        var groups = cheatSheetGroups
        if !user.bindings.isEmpty {
            groups.insert(("Your keymap.toml",
                           user.bindings.map { ($0.keys.joined(separator: " "), $0.desc) }), at: 0)
        }
        let s = NSMutableAttributedString()
        for (gi, group) in groups.enumerated() {
            if gi > 0 { s.append(NSAttributedString(string: "\n", attributes: [.font: font])) }
            s.append(NSAttributedString(string: group.title + "\n",
                                        attributes: [.font: font, .foregroundColor: headColor]))
            for (key, desc) in group.entries {
                let padded = key.count < 12
                    ? key + String(repeating: " ", count: 12 - key.count)
                    : key + "  "
                s.append(NSAttributedString(string: "  " + padded,
                                            attributes: [.font: font, .foregroundColor: keyColor]))
                s.append(NSAttributedString(string: desc + "\n",
                                            attributes: [.font: font, .foregroundColor: fg]))
            }
        }
        s.append(NSAttributedString(
            string: "\n" + user.status,
            attributes: [.font: terminalFont(size: 10), .foregroundColor: fg.withAlphaComponent(0.6)]))
        tv.textStorage?.setAttributedString(s)
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
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 1340, height: 900))
        outerSplit.autoresizingMask = [.width, .height]
        content.addSubview(hintBar)
        content.addSubview(outerSplit)
        window.contentView = content
        applyHintBarVisibility()
        if !window.setFrameUsingName("ConspectusMain") { window.center() }
        window.setFrameAutosaveName("ConspectusMain")
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
        let previewToggle = NSMenuItem(title: "Toggle Preview Pane", action: #selector(togglePreviewPane), keyEquivalent: "e")
        previewToggle.target = self
        viewMenu.addItem(previewToggle)
        let termToggle = NSMenuItem(title: "Toggle Terminal Panel", action: #selector(toggleBottomTerminal), keyEquivalent: "j")
        termToggle.target = self
        viewMenu.addItem(termToggle)
        let hints = NSMenuItem(title: "Toggle Shortcut Bar", action: #selector(toggleHintBar), keyEquivalent: "/")
        hints.target = self
        viewMenu.addItem(hints)
        let cheat = NSMenuItem(title: "Keyboard Cheat Sheet", action: #selector(toggleCheatSheet), keyEquivalent: "k")
        cheat.target = self
        viewMenu.addItem(cheat)
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

    @objc func toggleSecondPane()  { term2 == nil ? addSecondPane() : removeSecondPane() }
    @objc func togglePreviewPane() { rightContainer.superview == nil ? attachPreview() : detachPreview() }

    /// True while the preview pane is part of the window. Source of truth is
    /// the view hierarchy itself, so the flag can never drift from reality.
    var previewAttached: Bool { rightContainer.superview != nil }

    func addSecondPane() {
        guard term2 == nil else { return }
        let t2 = makeTerm()
        term2 = t2
        // Keep the preview rightmost: the second terminal goes between the
        // left terminal and the preview container.
        if previewAttached {
            split.addSubview(t2, positioned: .above, relativeTo: term)
        } else {
            split.addSubview(t2)
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
        if t2.superview != nil { t2.removeFromSuperview() }
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
        lastWasDir = false
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
    }

    /// Replace the `QLPreviewView` with a fresh instance, keeping frame and
    /// visibility. A `QLPreviewView` closes itself (its remote Quick Look
    /// extension goes away) when it leaves the window hierarchy or spends time
    /// hidden; setting `previewItem` on a closed view aborts the app with a
    /// QuickLook assertion — rebuilding is the only safe way back.
    func rebuildPreview() {
        let fresh = NoFocusPreviewView(frame: preview.frame, style: .normal) ?? NoFocusPreviewView()
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

    /// Swap the right pane to the folder listing and load it off the main
    /// thread (mirrors Quick Look, which is asynchronous by design). The
    /// previous listing stays visible until the new one lands — Finder-style,
    /// no white flash, no main-thread hitch.
    func showFolder(_ path: String, generation gen: Int) {
        preview.isHidden = true
        folderScroll.isHidden = false
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let contents = loadFolder(path, cap: folderListingCap)
            // Navigated on already? Skip the attributed-string build entirely.
            guard self.isCurrentListing(gen) else { return }
            let listing = renderListing(contents)
            DispatchQueue.main.async {
                // Re-check: a newer hover may have won while we rendered.
                guard self.isCurrentListing(gen) else { return }
                self.folderText.textStorage?.setAttributedString(listing)
                self.folderText.scroll(NSPoint.zero)
            }
        }
    }

    // MARK: NSSplitViewDelegate — window resize must not collapse a pane.
    // Keep the panes' ratios and enforce a 300pt minimum per pane (also caps
    // divider dragging via the constrain methods). Works for 1–3 panes.
    let minPane: CGFloat = 300

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

    // MARK: NSApplicationDelegate — focus resilience across app switches.
    // Launching an editor out of yazi (E c → VS Code, …) and coming back must
    // never leave the keyboard pointing nowhere: remember which terminal had
    // focus when we deactivate, and restore it if reactivation hands the
    // first-responder role to anything that is not a terminal.
    func applicationDidResignActive(_ n: Notification) {
        if let t = window?.firstResponder as? LocalProcessTerminalView { lastFocusedTerm = t }
    }

    func applicationDidBecomeActive(_ n: Notification) {
        guard let window = window else { return }
        if !(window.firstResponder is LocalProcessTerminalView) {
            window.makeFirstResponder(lastFocusedTerm ?? term)
        }
    }

    // MARK: LocalProcessTerminalViewDelegate
    func processTerminated(source: TerminalView, exitCode: Int32?) {
        DispatchQueue.main.async {
            if source === self.term {
                unlink(fifoPath); NSApp.terminate(nil)   // left pane quit -> close app
            } else if source === self.term2 {
                self.removeSecondPane()                  // second pane's yazi quit -> collapse
            } else if source === self.bottomTerm {
                self.closeBottomTerminal()               // `exit` in the shell -> collapse panel
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
