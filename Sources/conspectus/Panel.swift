import Cocoa
import Quartz
import SwiftTerm
import ConspectusShield

// Panel — the application delegate and owner of the whole window. This file
// holds the stored state and the app lifecycle (startup, FIFO management,
// appearance observer, watchdog); the behavior lives in themed extensions:
//   Panel+Layout.swift    window/menu/pane construction and split layout
//   Panel+Focus.swift     focus cycling, focus-by-intent preview, borders
//   Panel+Preview.swift   Quick Look + folder listing pipeline
//   Panel+Terminal.swift  bottom terminal panel, process lifecycle
//   Panel+CheatSheet.swift  shortcut bar content and the ⌘K panel

final class Panel: NSObject, NSApplicationDelegate, LocalProcessTerminalViewDelegate, NSSplitViewDelegate,
                   NSTextViewDelegate {
    var window: NSWindow!
    var split: NSSplitView!
    var rightContainer: NSView!
    var splitButton: NSButton!
    var previewButton: NSButton!
    var term: LocalProcessTerminalView!
    var term2: LocalProcessTerminalView?
    // Padded containers around the terminals: light padding between pane
    // edge and text (the preview pane brings its own). The split views hold
    // these panes; the terminal views live inset inside them.
    var termPane: NSView!
    var term2Pane: NSView?
    var bottomPane: NSView?
    let termPadding: CGFloat = 8
    var preview: IntentFocusPreviewView!
    var pdfView: IntentFocusPDFView!
    /// PDF preview chrome: pane = toolbar + pdfView (the unit that covers the
    /// QL view), bar = the perlege-style control strip, labels live-update.
    var pdfPane: NSView!
    var pdfBar: NSView!
    var pdfPageLabel: NSTextField!
    var pdfZoomLabel: NSTextField!
    var pdfRecolored = false
    var previewFocusRing: PassthroughBorderView!
    var focusObservation: NSKeyValueObservation?
    var folderScroll: NSScrollView!
    var folderText: NSTextView!
    var outerSplit: NSSplitView!
    var bottomTerm: LocalProcessTerminalView?
    var hintBar: NSView!
    var hintText: NSTextField!
    var cheatPanel: NSPanel?
    var cheatText: NSTextView?
    var lastPath: String?
    /// Time of the last wheel event anywhere in the app (stamped by a local
    /// event monitor) — gates the terminal repaint insurance. Main thread only.
    var lastWheelActivity = Date.distantPast
    /// Absolute path of the `ya` CLI, resolved once at startup by
    /// `resolveYaPath()` — click-to-navigate spawns it directly instead of
    /// paying a login-shell startup (~150ms+) on every click. Main thread only.
    var yaPath: String?
    weak var lastFocusedTerm: LocalProcessTerminalView?
    weak var lastTopTerm: LocalProcessTerminalView?   // ⌥↑ returns here from the terminal panel

    /// Minimum pane extent (width in the horizontal split, height of the pane
    /// area in the outer split) — window resizes and divider drags must not
    /// collapse a pane.
    let minPane: CGFloat = 300
    /// Bottom terminal panel: initial and minimum height.
    let termPanelHeight: CGFloat = 240
    let minTermHeight: CGFloat = 120

    /// True while the preview pane is part of the window. Source of truth is
    /// the view hierarchy itself, so the flag can never drift from reality.
    var previewAttached: Bool { rightContainer.superview != nil }

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
        // Remove the AppleShowScrollBars=Always pin earlier builds persisted:
        // it was meant to suppress the QL scroller-style-switch crash, did
        // provably NOT (second identical crash with the pin active), and as
        // an app-wide default it forced legacy scrollbars onto every scroll
        // view — a UI regression that would otherwise survive in the plist
        // forever. The working protection is the shield below.
        UserDefaults.standard.removeObject(forKey: "AppleShowScrollBars")
        // Fail-loud, not fail-silent: without the shield the crash class is
        // simply back (e.g. after a macOS update renames the private method).
        if conspectus_installQLTeardownShield() {
            logEvent("QL teardown shield installed")
        } else {
            warn("conspectus: QL teardown shield NOT installed (private API changed) — "
                 + "style-switch crashes during wheel scrolling are possible again")
        }
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
        buildMenu()                         // ⌘D split, ⌘E preview, ⌘J terminal, ⌘/ bar, ⌥-arrows focus
        NSApp.applicationIconImage = conspectusIcon()   // Dock / Cmd-Tab icon
        NSApp.activate(ignoringOtherApps: true)

        // CONSPECTUS_PEER is a flag, not an id: it arms the `=` cd-sync (keymap
        // broadcasts via `ya pub-to 0`, the panesync plugin follows). yazi
        // auto-generates its own DDS ids, so no fixed ids are set here.
        launch(term, extraEnv: ["QLPEEK_FIFO": fifoPath, "CONSPECTUS_PEER": "L"], rememberCwd: true)
        startFifoReader()
        resolveYaPath()                     // once, so clicks don't pay a login shell

        // Pane layout is two independent toggles: the second yazi pane (⌘D)
        // and the preview pane (⌘E, always rightmost). `split` starts 2-pane
        // without preview, `triple` starts with both.
        if splitMode { detachPreview() }
        if splitMode || tripleMode { addSecondPane() }

        startMainThreadWatchdog()
        startTerminalRepaintInsurance()
        startPreviewClickMonitor()
    }

    /// SwiftTerm (1.15.0) can wedge its display-update pipeline under fast
    /// wheel-event floods: the terminal buffer keeps advancing (navigation
    /// works, hover events flow) but the view stops painting until something
    /// forces a redraw. Root cause is SwiftTerm-internal and unfixed upstream;
    /// until then this insurance repaints the terminal views — but GATED on
    /// recent wheel activity (a local event monitor stamps it): the wedge only
    /// ever appears during/after wheel floods, and an idle app must not burn
    /// battery repainting nothing (App Nap stays effective; the no-op timer
    /// tick with tolerance is negligible). Scheduled in .common modes so it
    /// keeps firing during scroll gestures (event-tracking run-loop mode),
    /// which is exactly when the wedge happens.
    /// Side effects: installs a local scrollWheel event monitor, schedules a
    /// repeating main-runloop timer.
    func startTerminalRepaintInsurance() {
        let repaintInterval: TimeInterval = 1.0   // worst-case visible staleness
        let activityWindow: TimeInterval = 3.0    // repaint only this long after the last wheel tick
        NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            self?.lastWheelActivity = Date()
            return event
        }
        let timer = Timer(timeInterval: repaintInterval, repeats: true) { [weak self] _ in
            guard let self = self,
                  Date().timeIntervalSince(self.lastWheelActivity) < activityWindow else { return }
            for t in [self.term, self.term2, self.bottomTerm] { t?.needsDisplay = true }
        }
        timer.tolerance = 0.3   // let the system coalesce wakeups
        RunLoop.main.add(timer, forMode: .common)
    }

    /// Single-window app: closing the window (red button) quits, exactly like
    /// ⌘Q or quitting yazi — the app must never linger window-less (that state
    /// crashed in applicationDidResignActive on the released window).
    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }

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
                    // A stall nobody can see is not a freeze: in sleep/DarkWake
                    // maintenance windows the App-Napped main thread misses
                    // pings while this utility thread runs (observed as 5:56am
                    // reports with empty sample call graphs). Only report when
                    // someone was plausibly at the machine.
                    let anyInput = CGEventType(rawValue: ~0) ?? .null
                    let idle = CGEventSource.secondsSinceLastEventType(
                        .combinedSessionState, eventType: anyInput)
                    if idle < 60, Date().timeIntervalSince(lastSample) > 30 {
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
        cleanupStaleFifos()
        unlink(fifoPath)
        guard mkfifo(fifoPath, 0o600) == 0 else {
            die("conspectus: mkfifo(\(fifoPath)) failed: \(String(cString: strerror(errno)))")
        }
    }

    /// Remove FIFOs left behind by dead instances: `target-<pid>` whose
    /// process is gone, plus the legacy shared `target`. Deliberate try? on
    /// the listing — the directory was created a moment ago, and a failed
    /// cleanup only leaves harmless stale pipes behind.
    func cleanupStaleFifos() {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: cacheDir)) ?? []
        for f in files where f.hasPrefix("target") {
            let alive = Int32(f.dropFirst("target-".count)).map { kill($0, 0) == 0 } ?? false
            if !alive { unlink((cacheDir as NSString).appendingPathComponent(f)) }
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
                self.styleTermPanes()
                self.updateFocusBorders()
                if let p = self.lastPath { self.update(p) }
            }
        }
    }
}
