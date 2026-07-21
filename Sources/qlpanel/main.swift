import Cocoa
import Quartz
import SwiftTerm

// qlpanel — a split window: a TUI file manager (yazi by default) running in an
// embedded terminal on the left, a live macOS Quick Look preview on the right.
//
// The file manager drives the preview by writing the hovered absolute path to a
// FIFO whose location is handed to it via the QLPEEK_FIFO env var. yazi does
// this through the `qlpeek send` plugin (which honours QLPEEK_FIFO). Any other
// TUI can drive it too by writing a path to $QLPEEK_FIFO on selection.
//
// Usage:  qlpanel [command]     # default command: yazi

let cacheDir = (NSHomeDirectory() as NSString).appendingPathComponent(".cache/qlpanel")
let fifoPath = (cacheDir as NSString).appendingPathComponent("target")
let command  = CommandLine.arguments.dropFirst().first ?? "yazi"

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

// A Nerd Font so yazi's icon glyphs render. Override with QLPANEL_FONT /
// QLPANEL_FONT_SIZE; falls back through installed Nerd Fonts, then plain mono.
func terminalFont() -> NSFont {
    let env = ProcessInfo.processInfo.environment
    let size = Double(env["QLPANEL_FONT_SIZE"] ?? "") ?? 14
    var names = ["JetBrainsMono Nerd Font Mono", "JetBrainsMono Nerd Font",
                 "Hack Nerd Font Mono", "MesloLGS NF"]
    if let override = env["QLPANEL_FONT"], !override.isEmpty { names.insert(override, at: 0) }
    for n in names {
        if let f = NSFont(name: n, size: size) { return f }
    }
    return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
}

final class Panel: NSObject, NSApplicationDelegate, LocalProcessTerminalViewDelegate {
    var window: NSWindow!
    var term: LocalProcessTerminalView!
    var preview: QLPreviewView!

    func applicationDidFinishLaunching(_ n: Notification) {
        // FIFO the embedded TUI writes hovered paths to.
        try? FileManager.default.createDirectory(atPath: cacheDir, withIntermediateDirectories: true)
        unlink(fifoPath)
        mkfifo(fifoPath, 0o600)

        // Left: embedded terminal running the file manager.
        term = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 720, height: 900))
        term.font = terminalFont()        // Nerd Font before startProcess so cols/rows are sized right
        applyTheme(term)                  // Catppuccin, following system light/dark
        term.processDelegate = self

        // Re-theme live when the user toggles macOS appearance.
        DistributedNotificationCenter.default.addObserver(
            forName: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil, queue: .main) { [weak self] _ in
            guard let t = self?.term else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { applyTheme(t) }
        }

        // Right: Quick Look preview.
        preview = QLPreviewView(frame: NSRect(x: 0, y: 0, width: 620, height: 900),
                                style: .normal) ?? QLPreviewView()

        let split = NSSplitView(frame: NSRect(x: 0, y: 0, width: 1340, height: 900))
        split.isVertical = true            // vertical divider -> panes side by side
        split.dividerStyle = .thin
        split.addSubview(term)
        split.addSubview(preview)
        split.setPosition(760, ofDividerAt: 0)

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1340, height: 900),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable],
                          backing: .buffered, defer: false)
        window.title = "qlpanel — \(command)"
        window.contentView = split
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(term)     // keystrokes go to the TUI
        NSApp.activate(ignoringOtherApps: true)

        // Environment for the embedded shell: inherit ours, then point the
        // preview hook at our FIFO and set a sane TERM.
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["QLPEEK_FIFO"] = fifoPath
        let envArray = env.map { "\($0.key)=\($0.value)" }

        // Login shell so PATH/config load, then exec the file manager.
        term.startProcess(executable: "/bin/zsh",
                          args: ["-l", "-c", "exec \(command)"],
                          environment: envArray)

        startFifoReader()
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

    func update(_ path: String) {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        DispatchQueue.main.async { self.preview.previewItem = url as QLPreviewItem }
    }

    // MARK: LocalProcessTerminalViewDelegate
    func processTerminated(source: TerminalView, exitCode: Int32?) {
        unlink(fifoPath)
        NSApp.terminate(nil)
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
