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
//   conspectus ide [path]      # yazi | nvim | preview — `open` sends files to the one nvim
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

/// How markdown files preview: "render" (native swift-markdown → themed
/// document, the default) or "source" (bat → highlighted markdown source).
/// Toggle at runtime with `M`. Invalid values fail loud → default.
let markdownRenderDefault: Bool = {
    let raw = ProcessInfo.processInfo.environment["CONSPECTUS_MD_MODE"] ?? "render"
    switch raw {
    case "render": return true
    case "source": return false
    default:
        warn("conspectus: CONSPECTUS_MD_MODE must be render|source (got '\(raw)') — using render")
        return true
    }
}()

/// Live preview refresh (CONSPECTUS_WATCH): "on" (default) watches the
/// currently-previewed file and re-renders when it changes on disk — so
/// editing a note in nvim (left) updates the preview (right) on save. "off"
/// disables the watcher.
let watchEnabled: Bool = {
    let raw = (ProcessInfo.processInfo.environment["CONSPECTUS_WATCH"] ?? "on").lowercased()
    return !(raw == "off" || raw == "0" || raw == "false" || raw == "no")
}()

/// FIFO control message asking conspectus to move keyboard focus into the
/// preview pane — written by yazi's `l`/→-on-a-file binding so h/l pane
/// navigation flows from yazi into the preview. Not a path (those are
/// absolute), so it can never collide with a hovered file.
let focusPreviewSentinel = "@FOCUS_PREVIEW"

/// FIFO control message asking conspectus to toggle markdown render↔source —
/// written by yazi's `M` binding so the toggle works from any yazi pane
/// (browsing), not only when the preview itself is focused.
let toggleMarkdownSentinel = "@TOGGLE_MD"

/// FIFO control message asking conspectus to pin/unpin the preview to the
/// current file. Also reachable as ⌘P (app chrome). Pinned, hover events are
/// ignored so the preview stays on the file you are editing (e.g. in Neovide)
/// even when the other yazi pane is navigated. A yazi binding can write this;
/// like the others it is not a path, so it never collides with a hovered file.
let togglePinSentinel = "@TOGGLE_PIN"

/// Quick Look fallback toggle (CONSPECTUS_QUICKLOOK): "on" (default) previews
/// the long tail — video, audio, office, fonts, anything not text/image/PDF —
/// through Quick Look. "off" disables it entirely; those files show a short
/// "no native preview" note instead.
///
/// WHY this exists: Quick Look is the one preview path conspectus does NOT own
/// — it renders out-of-process in a private, undocumented system extension, and
/// every preview crash/wedge in the project's history traces to that (the
/// `_teardownScrollers` KVO abort, the WebKit scroller-style crash, the churn
/// wedge). Text, images, and PDFs are already native/in-process; Quick Look now
/// only serves the long tail. A user who never previews those and wants ZERO
/// Quick Look surface (no remote extension ever spawned, no crash class at all)
/// can turn it off and trade long-tail previews for maximum stability. It stays
/// ON by default because the fallback is still useful and the shield guards it.
let quickLookEnabled: Bool = {
    let raw = (ProcessInfo.processInfo.environment["CONSPECTUS_QUICKLOOK"] ?? "on").lowercased()
    switch raw {
    case "on", "1", "true", "yes": return true
    case "off", "0", "false", "no": return false
    default:
        warn("conspectus: CONSPECTUS_QUICKLOOK must be on|off (got '\(raw)') — using on")
        return true
    }
}()

/// PDF preview mode (CONSPECTUS_PDF_MODE): "page" (default) previews PDFs in
/// the native PDFKit view, page-wise — "perlege light", same keys as perlege
/// when the pane is focused; "continuous" starts that view in continuous
/// scrolling instead; "ql" routes PDFs through Quick Look like any other file
/// (escape hatch). Invalid values fail loud and use the default.
let pdfPreviewMode: String = {
    let raw = ProcessInfo.processInfo.environment["CONSPECTUS_PDF_MODE"] ?? "page"
    guard ["page", "continuous", "ql"].contains(raw) else {
        warn("conspectus: CONSPECTUS_PDF_MODE must be page|continuous|ql (got '\(raw)') — using page")
        return "page"
    }
    return raw
}()

/// Preview size cap: files larger than CONSPECTUS_PREVIEW_MAX_MB (default 50)
/// are not previewed — a several-hundred-MB JSON would wedge Quick Look and
/// spike memory. The pane shows a short "too large" note instead. 0 = no cap.
/// Invalid values fail loud and use the default.
let previewMaxBytes: Int = {
    let raw = ProcessInfo.processInfo.environment["CONSPECTUS_PREVIEW_MAX_MB"] ?? "50"
    guard let mb = Int(raw), mb >= 0 else {
        warn("conspectus: CONSPECTUS_PREVIEW_MAX_MB must be a non-negative integer (got '\(raw)') — using 50")
        return 50 * 1_048_576
    }
    return mb * 1_048_576
}()

/// Split ratio (CONSPECTUS_SPLIT): the terminal pane's share of the window
/// width at startup, as a fraction — the rest goes to the preview. Default
/// 0.5 (equal): the preview is the app's whole point and documents/PDFs need
/// width to read comfortably, so it gets at least half. Lower it (e.g. 0.45)
/// to favour the preview further, raise it to favour yazi. Clamped to
/// 0.25…0.75 so neither pane collapses. The ratio then scales with window
/// resizes; the divider is still draggable. Invalid values fail loud.
let terminalSplitFraction: CGFloat = {
    let raw = ProcessInfo.processInfo.environment["CONSPECTUS_SPLIT"] ?? "0.5"
    guard let f = Double(raw) else {
        warn("conspectus: CONSPECTUS_SPLIT must be a fraction like 0.5 (got '\(raw)') — using 0.5")
        return 0.5
    }
    return CGFloat(min(0.75, max(0.25, f)))
}()

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

// nvim RPC socket for `ide` mode: the middle nvim runs `--listen` on it, and
// each yazi pane gets the path as $CONSPECTUS_NVIM so its `open` sends files
// into that one instance (nvim --server … --remote) instead of spawning a new
// editor. Per-pid like the FIFO, so concurrent instances never collide.
let nvimSocketPath = (cacheDir as NSString).appendingPathComponent("nvim-\(getpid()).sock")

let cliArgs    = Array(CommandLine.arguments.dropFirst())
let splitMode  = cliArgs.first == "split" || cliArgs.first == "-s"
let tripleMode = cliArgs.first == "triple" || cliArgs.first == "-3"
let ideMode    = cliArgs.first == "ide"
let rest       = (splitMode || tripleMode || ideMode) ? Array(cliArgs.dropFirst()) : cliArgs
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
