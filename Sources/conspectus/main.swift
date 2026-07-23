import Cocoa
import ConspectusCore

// conspectus — a split window: a TUI file manager (yazi by default) running in an
// embedded terminal on the left, a live macOS Quick Look preview on the right.
//
// The file manager drives the preview by writing the hovered absolute path to a
// FIFO whose location is handed to it via the QLPEEK_FIFO env var. yazi does
// this through the bundled conspectus.yazi plugin. Any other TUI can drive it
// too by writing a path to $QLPEEK_FIFO on selection.
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
// Code layout: this file is the bootstrap (CLI parsing, globals, app start).
// Pure helpers live in the ConspectusCore library target (unit-tested);
// Appearance.swift holds theming/rendering; Panel*.swift is the AppKit shell.

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

/// Event diagnosis, off by default: CONSPECTUS_EVENT_LOG=<path> appends one
/// timestamped line per instrumented event (scrolls reaching the Quick Look
/// view, preview requests). Used to tell "events never arrive" (routing bug)
/// from "events arrive but the remote QL extension is dead" (rebuild needed).
/// Side effects: appends to the log file when the env var is set.
let eventLogPath = ProcessInfo.processInfo.environment["CONSPECTUS_EVENT_LOG"]
func logEvent(_ msg: String) {
    guard let path = eventLogPath else { return }
    let line = "\(Date()) \(msg)\n"
    if let fh = FileHandle(forWritingAtPath: path) {
        defer { try? fh.close() }
        fh.seekToEndOfFile()
        fh.write(Data(line.utf8))
    } else if !FileManager.default.createFile(atPath: path, contents: Data(line.utf8)) {
        warn("conspectus: cannot write CONSPECTUS_EVENT_LOG at \(path)")
    }
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

// One FIFO per instance: a shared path let any new launch (second window,
// test run) unlink the running instance's FIFO and permanently wedge its
// reader in a blocking open() on the orphaned inode — previews then never
// updated again. Stale FIFOs of dead instances are removed at startup.
let fifoPath = (cacheDir as NSString).appendingPathComponent("target-\(getpid())")

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

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = Panel()
app.delegate = delegate
app.run()
