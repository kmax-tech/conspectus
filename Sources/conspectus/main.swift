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

/// Read an on/off env var: on|1|true|yes, off|0|false|no (case-insensitive).
/// Unset → `def`; anything else fails loud and uses `def`. The one grammar
/// for every boolean switch below. Side effects: stderr on a bad value.
func boolEnv(_ name: String, default def: Bool) -> Bool {
    guard let raw = ProcessInfo.processInfo.environment[name]?.lowercased() else { return def }
    switch raw {
    case "on", "1", "true", "yes": return true
    case "off", "0", "false", "no": return false
    default:
        warn("conspectus: \(name) must be on|off (got '\(raw)') — using \(def ? "on" : "off")")
        return def
    }
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
let watchEnabled = boolEnv("CONSPECTUS_WATCH", default: true)

/// Mouse side buttons (CONSPECTUS_MOUSE_HISTORY, default on): buttons 4 and 5
/// — "back"/"forward" on most mice — step through the hovered yazi pane's
/// directory history, so a folder tree can be browsed with the mouse alone
/// (click a folder row to descend, side button to come back). yazi itself
/// cannot see these buttons (crossterm reports left/middle/right only), so the
/// app translates them into yazi's `back`/`forward` over the DDS. "off" leaves
/// the buttons to whatever the mouse driver does with them; the Go menu
/// (⌘[ / ⌘]) stays either way.
let mouseHistoryEnabled = boolEnv("CONSPECTUS_MOUSE_HISTORY", default: true)

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

/// FIFO control message asking conspectus to bring its window to the front —
/// written by the bundled plugin after it handles a `conspectus-open` DDS
/// message (the shell's `con <dir>`), so opening a directory from the terminal
/// also surfaces the window. Not a path, so it never collides with a hover.
let activateSentinel = "@ACTIVATE"

/// FIFO message prefix for yazi's yank buffer — written by the bundled plugin
/// on every `yank` DDS event as `@YANK:<copy|cut>:<path>\t<path>…` (empty list
/// = buffer cleared). The shortcut bar mirrors it, so WHAT is copied stays
/// visible after navigating away. Prefixed, so it never collides with a hover.
let yankPrefix = "@YANK:"

/// FIFO message prefix for yazi's SORT preference — written by the bundled
/// plugin right before every hover path as `@SORT:<by>:<reverse>:<dir_first>`
/// (ConspectusCore.parseListingSort), so the folder listing orders a folder
/// the way yazi's columns do. Before-every-hover rather than on-change: yazi
/// publishes no sort event, but it re-hovers after every `sort`, so the pair
/// always arrives together. Prefixed, so it never collides with a hover.
let sortPrefix = "@SORT:"

/// FIFO message prefix for yazi's SELECTION (Space/v marks) — the plugin's
/// answer to the app's `panesync-selected` DDS request (⌘L), as
/// `@SELECTED:<path>\t<path>…` (empty = nothing selected). Request/answer, not
/// an event stream: yazi publishes no event for selection changes, so the
/// selection can only be pulled on demand, never mirrored live like the yank
/// buffer. Prefixed, so it never collides with a hover.
let selectedPrefix = "@SELECTED:"

/// FIFO message prefix for a REFUSED theme restart — the plugin's answer to a
/// `panesync-restart` it would not honour, as `@RESTART_REFUSED:<peer>:<reason>`
/// (reason `tasks`, `selection`, or `error`; see ConspectusCore/Retheme.swift).
/// Lets the shortcut bar say what the pending re-theme waits for. Prefixed, so
/// it never collides with a hover.
let restartRefusedPrefix = "@RESTART_REFUSED:"

/// FIFO message prefix the ide editor's nvim writes on BufEnter — followed by
/// the active file's absolute path (`@EDITOR_FILE:/abs/path`). conspectus
/// previews it only while the editor pane is focused, so the preview follows
/// the editor. Prefixed (not a bare path) so it's distinct from a yazi hover.
let editorFilePrefix = "@EDITOR_FILE:"

/// FIFO message prefix for yazi's `E C` (dotfiles keymap → bundled plugin,
/// mode `lazycvs`) — `@LAZYCVS:<path>`
/// with the hovered (or first selected) item: the same action as the context
/// menu's "Open in lazycvs", so the key opens the terminal panel instead of
/// running lazycvs inside the yazi pane. Prefixed, so it never collides with
/// a hover.
let lazycvsPrefix = "@LAZYCVS:"

/// FIFO message prefix for a hover WITH a PDF page — `@PDFPAGE:<page>:<path>`
/// (ConspectusCore.parsePDFPageMessage), written by a content search that
/// knows the page of its hit: yazi's `S` picker in its ripgrep-all mode
/// (M-a), whose focus bind sends this instead of the bare path for a PDF hit.
/// Handled as the same hover a bare path would be, plus the PDF preview opens
/// on that page instead of page 1. Prefixed, so it never collides with a hover.
let pdfPagePrefix = "@PDFPAGE:"

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
let quickLookEnabled = boolEnv("CONSPECTUS_QUICKLOOK", default: true)

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

/// Central note libraries (CONSPECTUS_NOTES_DIRS): comma-separated dirs
/// searched flat for `<stem>.md` when a previewed PDF has no local note
/// (sibling / subdirs / symlink target — perlege's lookup, see
/// ConspectusCore/NoteResolver.swift). Default: ~/work/library/notes.
/// A set-but-empty value fails loud and uses the default.
let notesDirs: [String] = {
    let raw = ProcessInfo.processInfo.environment["CONSPECTUS_NOTES_DIRS"]
    let dirs = parseNotesDirs(raw)
    if raw != nil, dirs.isEmpty {
        warn("conspectus: CONSPECTUS_NOTES_DIRS is set but contains no directories — using \(defaultNotesDir)")
        return parseNotesDirs(nil)
    }
    return dirs
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

/// Per-location preview off-switch (CONSPECTUS_PREVIEW_SKIP_DIRS): comma-
/// separated directories under which hovering shows a short note and the
/// preview touches the filesystem NOT AT ALL — no existence check, no size
/// stat, no read, no mtime watch. For network mounts (CephFS behind SMB/NFS,
/// sshfs) where a single blocking filesystem call on a stalled server can
/// beachball the app. Default: unset — preview everywhere. A set-but-empty
/// value fails loud (and previews stay on).
let previewSkipDirs: [String] = {
    guard let raw = ProcessInfo.processInfo.environment["CONSPECTUS_PREVIEW_SKIP_DIRS"] else { return [] }
    let dirs = parseDirList(raw)
    if dirs.isEmpty {
        warn("conspectus: CONSPECTUS_PREVIEW_SKIP_DIRS is set but contains no directories — previews stay on")
    }
    return dirs
}()

/// Split ratio (CONSPECTUS_SPLIT): the terminal panes' *combined* share of the
/// window width, as a fraction — the preview keeps the rest. Applies at every
/// pane count, not just at startup: the preview holds its share when panes are
/// added or removed (⌘D, ⌘E), and the terminal panes divide what is left among
/// themselves. Default 0.667, i.e. a third for the preview: enough for a
/// readable document column while yazi keeps room for long filenames. Lower it
/// (e.g. 0.5 for equal panes) to favour the preview, raise it to favour yazi.
/// Clamped to 0.25…0.75 so neither side collapses. The ratio then scales with
/// window resizes; dividers stay draggable. Invalid values fail loud.
let terminalSplitFraction: CGFloat = {
    let raw = ProcessInfo.processInfo.environment["CONSPECTUS_SPLIT"] ?? "0.667"
    guard let f = Double(raw) else {
        warn("conspectus: CONSPECTUS_SPLIT must be a fraction like 0.667 (got '\(raw)') — using 0.667")
        return 0.667
    }
    return CGFloat(min(0.75, max(0.25, f)))
}()

/// The preview pane's share of the window width — the complement of the
/// terminal share, named because the layout distributes from the preview side
/// (reserve the preview's width first, split the rest among the terminals).
let previewSplitFraction: CGFloat = 1 - terminalSplitFraction

/// Body size of the rendered markdown view (CONSPECTUS_MD_FONT_SIZE, default
/// 16). Headings and every vertical rhythm in MarkdownRender.swift scale off
/// it, so the layout holds at any size. Invalid values fail loud.
let mdFontSize: CGFloat = {
    let raw = ProcessInfo.processInfo.environment["CONSPECTUS_MD_FONT_SIZE"] ?? "16"
    guard let s = Double(raw), s >= 6, s <= 48 else {
        warn("conspectus: CONSPECTUS_MD_FONT_SIZE must be a size between 6 and 48 (got '\(raw)') — using 16")
        return 16
    }
    return CGFloat(s)
}()

/// Measure cap for rendered markdown (CONSPECTUS_MD_MEASURE): the maximum line
/// length in characters, default 68 — the classic 60–75 range where the eye
/// finds the next line without effort. A wide preview pane otherwise sets
/// 150-character lines, which reads far worse than any font choice can repair.
/// The text column is centred and the surplus becomes margin; 0 disables the
/// cap. Only the *rendered* view is capped, never source/`bat` output, where
/// the line length is the file's own. Invalid values fail loud.
let mdMeasureChars: CGFloat = {
    let raw = ProcessInfo.processInfo.environment["CONSPECTUS_MD_MEASURE"] ?? "68"
    guard let n = Double(raw), n == 0 || (n >= 30 && n <= 200) else {
        warn("conspectus: CONSPECTUS_MD_MEASURE must be 0 or 30…200 characters (got '\(raw)') — using 68")
        return 68
    }
    return CGFloat(n)
}()

/// The measure cap in points. A serif face averages ≈ 0.5 em per character, so
/// characters × half the body size is the width that holds them.
let mdMeasurePoints: CGFloat = mdMeasureChars * mdFontSize * 0.5

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

// Headless CVS status: `conspectus --cvs-status <dir>` prints one
// `<status>\t<name>` line per entry that is not clean (status = a
// CVSFileStatus raw value) and exits; nothing for a clean directory or one
// outside any checkout. The bundled cvs.yazi fetcher reads this, so yazi's
// signs and the pane's folder listing come from the same ConspectusCore code.
if let i = CommandLine.arguments.firstIndex(of: "--cvs-status") {
    guard i + 1 < CommandLine.arguments.count else { die("conspectus: --cvs-status needs a directory") }
    let dir = CommandLine.arguments[i + 1]
    if let read = readCVSStatuses(in: dir) {
        for line in read.malformed { warn("conspectus: \(dir)/CVS/Entries: unparseable line: \(line)") }
        let out = read.statuses.filter { $0.value != .clean }.sorted { $0.key < $1.key }
            .map { "\($0.value.rawValue)\t\($0.key)\n" }.joined()
        FileHandle.standardOutput.write(Data(out.utf8))
    }
    exit(0)
}

let cacheDir = (NSHomeDirectory() as NSString).appendingPathComponent(".cache/conspectus")

/// Server check of a checkout directory for the `U` signs: how long a result
/// is reused before the server is asked again (CONSPECTUS_CVS_REMOTE,
/// seconds, default 300; `off` never asks the server — the signs then stay
/// local). The dry run takes ~0.25 s over a kept-alive ssh connection, so a
/// short TTL is affordable; the TTL is what keeps a folder you hop in and
/// out of from being asked every time. A failed check is reused for
/// `cvsRemoteErrorTTL` only.
let cvsRemoteTTL: TimeInterval? = remoteTTL(env: "CONSPECTUS_CVS_REMOTE")
let cvsRemoteErrorTTL: TimeInterval = 60
/// Longest wait for one `cvs -n -q update -l`: a server that does not
/// answer (VPN down, ssh asking for a password nobody can type) must not
/// block yazi's fetcher thread for good. Generous, because the first call
/// of a session also opens the ssh connection.
let cvsRemoteTimeout: TimeInterval = 20
let cvsRemoteCacheDir = (cacheDir as NSString).appendingPathComponent("cvs-remote")

/// The git twin: how long one `git fetch` of a repository answers the line
/// above its files (CONSPECTUS_GIT_REMOTE, seconds, default 300; `off`
/// never fetches). One fetch per repository, not per folder — the cache is
/// keyed by the repository root.
let gitRemoteTTL: TimeInterval? = remoteTTL(env: "CONSPECTUS_GIT_REMOTE")
let gitRemoteTimeout: TimeInterval = 20
let gitRemoteCacheDir = (cacheDir as NSString).appendingPathComponent("git-remote")
/// git with no way to wait for a human: no credential prompt
/// (GIT_TERMINAL_PROMPT), no ssh passphrase prompt (BatchMode) — a
/// repository that needs one fails fast and the line says so. Defined up
/// here with the other constants: main.swift initializes globals in order,
/// and the `--git-remote` block below runs before anything after it.
let gitBatchEnvironment = ["GIT_TERMINAL_PROMPT": "0", "GIT_SSH_COMMAND": "ssh -oBatchMode=yes"]

/// A server-check TTL from the environment: seconds, `off` for nil (never
/// ask), default 300; a bad value warns once and falls back to 300.
func remoteTTL(env name: String) -> TimeInterval? {
    let raw = ProcessInfo.processInfo.environment[name] ?? "300"
    if raw.lowercased() == "off" { return nil }
    guard let secs = Int(raw), secs >= 0 else {
        warn("conspectus: \(name) must be a non-negative integer (seconds) or off (got '\(raw)') — using 300")
        return 300
    }
    return TimeInterval(secs)
}

/// Headless server check: `conspectus --cvs-remote <dir>` prints the
/// directory's `CVSRemoteResult` (see its `serialized` format) — from the
/// cache while fresh, else from a fresh `cvs -n -q update -l` run in `dir`,
/// which is then cached. The bundled cvs.yazi fetcher calls this after the
/// local `--cvs-status`. Prints nothing (exit 0) with CONSPECTUS_CVS_REMOTE
/// off; a failed run is still a result (`error\t…`), exit 0 — the caller
/// shows it, the exit code is for a broken call, not a broken server.
if let i = CommandLine.arguments.firstIndex(of: "--cvs-remote") {
    guard i + 1 < CommandLine.arguments.count else { die("conspectus: --cvs-remote needs a directory") }
    let dir = CommandLine.arguments[i + 1]
    guard let ttl = cvsRemoteTTL else { exit(0) }
    let result: CVSRemoteResult
    if let cached = readCVSRemoteCache(for: dir, cacheDir: cvsRemoteCacheDir),
       cached.isFresh(now: Date(), ttl: ttl, errorTTL: cvsRemoteErrorTTL) {
        result = cached
    } else {
        result = runCVSDryRun(in: dir)
        do {
            try writeCVSRemoteCache(result, for: dir, cacheDir: cvsRemoteCacheDir)
        } catch {
            warn("conspectus: cannot write \(cvsRemoteCacheDir): \(error.localizedDescription)")
        }
    }
    FileHandle.standardOutput.write(Data(result.serialized().utf8))
    exit(0)
}

/// Headless git twin: `conspectus --git-remote <repo-root>` prints the
/// repository's `GitRemoteResult` (see its `serialized` format) — from the
/// cache while fresh, else from a fresh `git fetch` + diff against the
/// upstream, which is then cached. Nothing (exit 0) with
/// CONSPECTUS_GIT_REMOTE off; a failed check is still a result (`error\t…`).
/// No yazi fetcher calls this (git.yazi shows the local signs); it exists
/// for scripts and for checking the preview's line from a shell.
if let i = CommandLine.arguments.firstIndex(of: "--git-remote") {
    guard i + 1 < CommandLine.arguments.count else { die("conspectus: --git-remote needs a repository directory") }
    let root = CommandLine.arguments[i + 1]
    guard let ttl = gitRemoteTTL else { exit(0) }
    let result: GitRemoteResult
    if let cached = readGitRemoteCache(for: root, cacheDir: gitRemoteCacheDir),
       cached.isFresh(now: Date(), ttl: ttl, errorTTL: cvsRemoteErrorTTL) {
        result = cached
    } else {
        result = runGitRemoteCheck(in: root)
        do {
            try writeGitRemoteCache(result, for: root, cacheDir: gitRemoteCacheDir)
        } catch {
            warn("conspectus: cannot write \(gitRemoteCacheDir): \(error.localizedDescription)")
        }
    }
    FileHandle.standardOutput.write(Data(result.serialized().utf8))
    exit(0)
}

/// What one finished command left behind.
struct CommandResult {
    let status: Int32
    let stdout: String
    /// Trimmed.
    let stderr: String
}

/// Why `runCommand` could not deliver a result: the process never started,
/// or it did not finish within the timeout (and was terminated).
enum CommandFailure: Error, CustomStringConvertible {
    case cannotRun(String)
    case timedOut(TimeInterval)

    var description: String {
        switch self {
        case .cannotRun(let why): return "cannot run: \(why)"
        case .timedOut(let secs): return "no answer within \(Int(secs)) s"
        }
    }
}

/// Run `args` (via PATH: `/usr/bin/env`, so Homebrew tools are found from
/// the login shell yazi runs in) in `dir`, with stdin closed — never a
/// password prompt that waits — and `extraEnvironment` on top of ours.
/// Both pipes are drained while waiting, so a chatty command cannot stall
/// on a full pipe. A non-zero exit is a result, not an error; the caller
/// reads `status`. Side effects: spawns the process; terminates it on
/// timeout.
func runCommand(_ args: [String], in dir: String, timeout: TimeInterval,
                extraEnvironment: [String: String] = [:]) throws -> CommandResult {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    p.arguments = args
    p.currentDirectoryURL = URL(fileURLWithPath: dir, isDirectory: true)
    if !extraEnvironment.isEmpty {
        p.environment = ProcessInfo.processInfo.environment.merging(extraEnvironment) { $1 }
    }
    let out = Pipe(), err = Pipe()
    p.standardOutput = out; p.standardError = err
    p.standardInput = FileHandle.nullDevice
    do { try p.run() } catch { throw CommandFailure.cannotRun(error.localizedDescription) }
    let done = DispatchGroup()
    done.enter()
    DispatchQueue.global().async { p.waitUntilExit(); done.leave() }
    var stdoutData = Data(), stderrData = Data()
    let readers = DispatchGroup()
    readers.enter(); DispatchQueue.global().async { stdoutData = out.fileHandleForReading.readDataToEndOfFile(); readers.leave() }
    readers.enter(); DispatchQueue.global().async { stderrData = err.fileHandleForReading.readDataToEndOfFile(); readers.leave() }
    if done.wait(timeout: .now() + timeout) == .timedOut {
        p.terminate()
        throw CommandFailure.timedOut(timeout)
    }
    readers.wait()
    return CommandResult(status: p.terminationStatus,
                         stdout: String(decoding: stdoutData, as: UTF8.self),
                         stderr: String(decoding: stderrData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
}

/// The last line of a command's stderr, or a generic exit note — the one
/// line a verdict has room for.
func lastLine(of r: CommandResult, tool: String) -> String {
    r.stderr.split(separator: "\n").last.map(String.init) ?? "\(tool) exit \(r.status)"
}

/// Run `cvs -n -q update -l` in `dir` and parse the `U`/`P` lines. Any
/// failure — no cvs, timeout, `[update aborted]`, non-zero exit without
/// output — becomes the result's `error`, never an exception: the fetcher
/// shows it. Exit 1 with output is cvs's "something would conflict", not a
/// failure. Side effects: spawns cvs, which talks to the CVS server.
func runCVSDryRun(in dir: String) -> CVSRemoteResult {
    let started = Date()
    let r: CommandResult
    do {
        r = try runCommand(["cvs", "-n", "-q", "update", "-l"], in: dir, timeout: cvsRemoteTimeout)
    } catch {
        return CVSRemoteResult(checked: started, needsUpdate: [], error: "cvs: \(error)")
    }
    if r.stderr.contains("aborted]") || (r.status != 0 && r.stdout.isEmpty) {
        return CVSRemoteResult(checked: started, needsUpdate: [], error: lastLine(of: r, tool: "cvs"))
    }
    return CVSRemoteResult(checked: started, needsUpdate: parseCVSDryRun(r.stdout))
}

/// Server check of a git repository at `root`: `git fetch`, then the
/// ahead/behind counts against the upstream branch and the files it has
/// newer content for (`git diff --name-only HEAD...@{u}`). Every failure —
/// no upstream, fetch refused, timeout — is the result's `error`, never an
/// exception. Side effects: spawns git, which talks to the remote.
func runGitRemoteCheck(in root: String) -> GitRemoteResult {
    let started = Date()
    func fail(_ why: String) -> GitRemoteResult {
        GitRemoteResult(checked: started, upstream: nil, ahead: 0, behind: 0, changed: [], error: why)
    }
    do {
        let up = try runCommand(["git", "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"], in: root, timeout: 5)
        guard up.status == 0 else { return fail("no upstream branch") }
        let upstream = up.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let fetch = try runCommand(["git", "fetch", "--quiet"], in: root, timeout: gitRemoteTimeout,
                                   extraEnvironment: gitBatchEnvironment)
        guard fetch.status == 0 else { return fail(lastLine(of: fetch, tool: "git fetch")) }
        let counts = try runCommand(["git", "rev-list", "--left-right", "--count", "HEAD...@{u}"], in: root, timeout: 5)
        guard counts.status == 0, let ab = parseGitAheadBehind(counts.stdout) else {
            return fail(lastLine(of: counts, tool: "git rev-list"))
        }
        let diff = try runCommand(["git", "diff", "--name-only", "HEAD...@{u}"], in: root, timeout: 10)
        guard diff.status == 0 else { return fail(lastLine(of: diff, tool: "git diff")) }
        let changed = Set(diff.stdout.split(separator: "\n").map(String.init))
        return GitRemoteResult(checked: started, upstream: upstream, ahead: ab.ahead, behind: ab.behind, changed: changed)
    } catch {
        return fail("git: \(error)")
    }
}

/// What the working copy says about one file in a git repository: its
/// repo-relative path, porcelain status and last commit — the local half of
/// `GitFileState`. nil (with a warning) when git itself cannot run; a
/// non-zero status is answered as "unknown", the honest default. Side
/// effects: spawns git three times (short, local).
func readGitFileLocal(dir: String, name: String) -> (repoPath: String, local: CVSFileStatus, commit: GitCommitStamp?)? {
    do {
        let prefix = try runCommand(["git", "rev-parse", "--show-prefix"], in: dir, timeout: 5)
        guard prefix.status == 0 else { warn("conspectus: git rev-parse in \(dir): \(lastLine(of: prefix, tool: "git"))"); return nil }
        let repoPath = prefix.stdout.trimmingCharacters(in: .whitespacesAndNewlines) + name
        let status = try runCommand(["git", "status", "--porcelain=v1", "--ignored", "--", name], in: dir, timeout: 10)
        let local = status.status == 0 ? parseGitPorcelainStatus(status.stdout) : .unknown
        let log = try runCommand(["git", "log", "-1", "--format=%h%x09%ct", "--", name], in: dir, timeout: 10)
        return (repoPath, local, log.status == 0 ? GitCommitStamp.parse(log.stdout) : nil)
    } catch {
        warn("conspectus: git in \(dir): \(error)")
        return nil
    }
}

// One FIFO per instance: a shared path let any new launch (second window,
// test run) unlink the running instance's FIFO and permanently wedge its
// reader in a blocking open() on the orphaned inode — previews then never
// updated again. Stale FIFOs of dead instances are removed at startup.
let fifoPath = (cacheDir as NSString).appendingPathComponent("target-\(getpid())")

// Follow channel for lazycvs in the terminal panel (`lcvs -follow <fifo>`):
// while lazycvs runs there, every directory yazi enters is written into it
// and lazycvs moves its selection along. Per-pid like the FIFO above; exists
// only while that panel is open.
let lazycvsFollowPath = (cacheDir as NSString).appendingPathComponent("lazycvs-follow-\(getpid())")

// Last cwd: yazi writes it here on exit (--cwd-file); a bare `conspectus`
// resumes there, falling back to $HOME.
let lastCwdPath = (cacheDir as NSString).appendingPathComponent("last-cwd")

// nvim RPC socket for `ide` mode: the middle nvim runs `--listen` on it, and
// each yazi pane gets the path as $CONSPECTUS_NVIM so its `open` sends files
// into that one instance (nvim --server … --remote) instead of spawning a new
// editor. Per-pid like the FIFO, so concurrent instances never collide.
let nvimSocketPath = (cacheDir as NSString).appendingPathComponent("nvim-\(getpid()).sock")

// Tab-session state, one file per yazi pane side — deliberately SHARED across
// app runs (that is the point: tabs survive a restart), not per-pid. The
// bundled plugin snapshots every cd into it and restores at startup when
// CONSPECTUS_TABS_RESTORE is "1" (concurrent instances would overwrite each
// other's snapshots — last quit wins, acceptable for a single-user tool).
let tabsFileL = (cacheDir as NSString).appendingPathComponent("tabs-L")
let tabsFileR = (cacheDir as NSString).appendingPathComponent("tabs-R")

let cliArgs    = Array(CommandLine.arguments.dropFirst())
let splitMode  = cliArgs.first == "split" || cliArgs.first == "-s"
let tripleMode = cliArgs.first == "triple" || cliArgs.first == "-3"
let ideMode    = cliArgs.first == "ide"
let rest       = (splitMode || tripleMode || ideMode) ? Array(cliArgs.dropFirst()) : cliArgs
let start     = resolveStart(rest.first(where: { !$0.hasPrefix("-") }), lastCwdFile: lastCwdPath)
let startPath = start.path
// A FILE argument (e.g. from indago's "open in conspectus"): start in its
// parent and hand the file to yazi as the entry, so the cursor lands on it
// and the Quick Look pane previews it immediately.
let startRevealFile = start.revealFile
let command   = ProcessInfo.processInfo.environment["CONSPECTUS_CMD"] ?? "yazi"

// An explicit [path] that doesn't exist falls back to $HOME — say so
// instead of silently starting somewhere the user didn't ask for.
if let w = start.warning { warn(w) }

// Reopen the saved tabs only on a bare start — an explicit [path] means
// "begin HERE, clean". ⌘R relaunches always restore (see relaunchYaziPane).
let tabsRestoreDefault = rest.first(where: { !$0.hasPrefix("-") }) == nil

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = Panel()
app.delegate = delegate
app.run()
