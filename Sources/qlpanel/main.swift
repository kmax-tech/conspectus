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
        term.processDelegate = self

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
