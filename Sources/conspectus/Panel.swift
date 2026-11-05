import Cocoa
import Quartz
import SwiftTerm
import ConspectusCore
import ConspectusShield

// Panel — the application delegate and owner of the whole window. This file
// holds the stored state and the app lifecycle (startup, FIFO management,
// appearance observer, watchdog); the behavior lives in themed extensions:
//   Panel+Layout.swift       window/menu/pane construction and split layout
//   Panel+Focus.swift        focus cycling, focus-by-intent preview, borders
//   Panel+Preview.swift      FIFO reader, preview routing (text/image/PDF/QL), folder listing
//   Panel+PDFBar.swift       the control strip above the PDF preview
//   Panel+Notes.swift        PDF companion notes, ide auto-follow, nvim RPC
//   Panel+Print.swift        ⌥⌘P — print what the preview renders
//   Panel+Terminal.swift     bottom terminal panel, lazycvs, yazi re-theme, process lifecycle
//   Panel+VCSBar.swift       the VCS line above a previewed file (CVS revision / git commit, current?)
//   Panel+History.swift      Go menu: back/forward, enclosing folder, reveal, tabs
//   Panel+ContextMenu.swift  right-click file menu, ⌘C copies the file, Services
//   Panel+CheatSheet.swift   shortcut bar content and the ⌘K panel

final class Panel: NSObject, NSApplicationDelegate, LocalProcessTerminalViewDelegate, NSSplitViewDelegate,
                   NSTextViewDelegate, NSSearchFieldDelegate {
    var window: NSWindow!
    var split: NSSplitView!
    var rightContainer: NSView!
    var splitButton: NSButton!
    var previewButton: NSButton!
    /// ⌘P menu item; its checkmark mirrors `previewPinned`.
    weak var pinMenuItem: NSMenuItem?
    var term: LocalProcessTerminalView!
    var term2: LocalProcessTerminalView?
    /// ide mode: the middle pane runs nvim as an RPC server (`--listen`), so
    /// yazi's `open` sends files here instead of spawning a new editor. nil
    /// outside ide mode. `editorPane` is its themed container.
    var editorTerm: LocalProcessTerminalView?
    var editorPane: NSView?
    /// The single middle terminal, whichever role it plays: a second yazi
    /// (split/triple) or the nvim editor (ide). They never coexist, so focus
    /// cycling and borders can treat "the middle pane" uniformly.
    var middleTerm: LocalProcessTerminalView? { term2 ?? editorTerm }
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
    /// The companion note of the currently previewed PDF (perlege's lookup):
    /// set async by `resolveNoteAsync` when a PDF previews, cleared when the
    /// preview moves to anything else. Drives the note toolbar button and the
    /// ide auto-follow (hover a PDF → its note opens in nvim), and is the echo
    /// guard: nvim re-announcing this note must not steal the preview off the
    /// PDF. Main thread only.
    var activeNote: (pdf: String, note: String)?
    /// Note the ide editor was last asked to open — dedup so re-hovers of the
    /// same PDF don't spam nvim with --remote calls. Main thread only.
    var lastEditorNotePush: String?
    /// Whether the active note's buffer is pinned (b:conspectus_pinned in
    /// nvim — THE source of truth, so :ConspectusUnpin works there without a
    /// second state to drift). This mirror only drives the toolbar icon;
    /// refreshed on every PDF hover, set optimistically on ⌘N. Main thread only.
    var activeNotePinned = false
    /// Every note the auto-follow ever pushed — the GC sweeps THIS set (minus
    /// current/pinned), not just the immediately previous note: while a fresh
    /// nvim boots, delivery retries race and a push can land out of order,
    /// which would otherwise leave the first note stuck in the buffer list
    /// forever. Paths only, tiny; stale entries are no-ops. Main thread only.
    var autoNoteBuffers: Set<String> = []
    /// Toolbar button in the PDF bar: opens the note (or a fresh sibling note)
    /// in the ide editor; its icon mirrors whether a note exists.
    var noteButton: NSButton!
    /// The VCS line above a previewed file (`Panel+VCSBar`): strip + label,
    /// shown only for files inside a CVS checkout or a git repository.
    /// `remoteInFlight` holds the keys (CVS directory, git repository root)
    /// the preview itself is asking the server about, so one hover storm
    /// never spawns a second cvs or git for the same one. Main thread only.
    var vcsBar: NSView!
    var vcsBarText: NSTextField!
    var remoteInFlight: Set<String> = []
    var previewFocusRing: PassthroughBorderView!
    var focusObservation: NSKeyValueObservation?
    var folderScroll: NSScrollView!
    var folderText: NSTextView!
    /// Native text preview (source/notes/config), covering the QL view like the
    /// folder listing does — separate view so its focus/scroll semantics don't
    /// collide with the clickable folder rows.
    /// textPane = optional markdown toolbar (textBar) + textScroll. The PANE is
    /// the cover over the QL view; the bar shows only for markdown files.
    var textPane: NSView!
    var textBar: NSView!
    var mdSegment: NSSegmentedControl!
    var textScroll: NSScrollView!
    var textView: IntentFocusTextView!
    /// Native image preview, another cover over the QL view. Fit-to-pane,
    /// letterboxed in the theme background.
    var imageView: IntentFocusImageView!
    var outerSplit: NSSplitView!
    var bottomTerm: LocalProcessTerminalView?
    var hintBar: NSView!
    var hintText: NSTextField!
    var cheatPanel: NSPanel?
    var cheatText: NSTextView?
    /// Filter field on top of the cheat sheet; its content is the filter state
    /// (no second copy to drift). The only control in the panel that takes the
    /// keyboard — see `buildCheatSheet`.
    var cheatSearch: NSSearchField?
    var lastPath: String?
    /// Session-live copy of CONSPECTUS_PREVIEW_SKIP_DIRS — ⌘⇧P toggles the
    /// folder being browsed (and thereby its whole subtree) in and out at
    /// runtime; the env var stays the persistent seed. Guarded by
    /// `skipDirsLock`: the FIFO reader thread consults the list on every hover
    /// (before any filesystem call), the main thread mutates it on toggle.
    /// Access via the `skipDirs` snapshot in Panel+Preview.
    var skipDirsStore: [String] = previewSkipDirs
    let skipDirsLock = NSLock()
    /// Serial queue for the one filesystem call a skipped location still gets:
    /// the "is it a directory?" probe (folder listings stay useful on a slow
    /// mount). Serial ON PURPOSE — on a hung mount the probe blocks, and this
    /// queue confines that to a single thread while hovers keep queueing
    /// cheaply; stale generations die on return. Never probe on the FIFO
    /// reader thread or on main.
    let skipProbeQueue = DispatchQueue(label: "conspectus.skip-probe", qos: .utility)
    /// Preview pinned to `lastPath`: hover events are ignored (update() drops a
    /// different path) so the preview stays on the file being edited while the
    /// yazi pane(s) navigate elsewhere. Toggled by ⌘P / the @TOGGLE_PIN sentinel.
    var previewPinned = false
    /// Path currently shown in the native text preview — dedup for showTextPreview.
    var lastTextPath: String?
    /// mtime of the file behind `pdfView.document` at load time — the PDF dedup
    /// key together with the document URL. The document survives hovers onto
    /// other files (only its pane hides), so URL alone would hand back a
    /// stale document after a rebuild happened while another file was shown.
    var pdfLoadedMtime: Date?
    /// Page a `@PDFPAGE:` hover asked for, waiting for its PDF to render.
    /// Set by the FIFO reader, consumed by the PDF branch of
    /// `requestFilePreview` (which goes there instead of page 1), dropped by
    /// `update` when a hover onto a DIFFERENT path arrives first. Survives
    /// the preview debounce and a bare hover onto the same file in either
    /// order — yazi's `reveal` after a pick re-hovers the file, and that
    /// must not undo the page.
    var pendingPDFPage: PDFPageHover?
    /// Live-refresh: poll the previewed file's mtime while a file preview is
    /// showing, so an edit (nvim on the left) or a rebuild (latexmk → PDF)
    /// refreshes the preview. Polling, not an fd watcher, ON PURPOSE: latexmk
    /// deletes/recreates/moves the PDF, and an fd watch loses the file the
    /// moment it briefly vanishes; `stat` on the path doesn't care about inodes
    /// (this is the lesson from perlege). Gated to an active file preview, so
    /// it stops when browsing dirs / idle (App Nap stays intact).
    var previewWatchTimer: Timer?
    var lastPreviewMtime: Date?
    /// Absolute path of `bat`, resolved once at startup; nil until resolved or
    /// if missing (then the text preview stays plain monospace). Main thread only.
    var batPath: String?
    /// Markdown preview: true = rendered (native swift-markdown → themed
    /// NSAttributedString), false = source (bat). Starts from CONSPECTUS_MD_MODE;
    /// `M` toggles it live. Main thread only.
    lazy var markdownRender: Bool = markdownRenderDefault
    /// Time of the last wheel event anywhere in the app (stamped by a local
    /// event monitor) — gates the terminal repaint insurance. Main thread only.
    var lastWheelActivity = Date.distantPast
    /// Absolute path of the `ya` CLI, resolved once at startup by
    /// `resolveOnLoginPath` — click-to-navigate spawns it directly instead of
    /// paying a login-shell startup (~150ms+) on every click. Main thread only.
    var yaPath: String?
    /// Absolute path of `nvim`, resolved once when the editor pane first opens.
    /// Used to drive the ide editor's RPC server directly (⌥-arrow split
    /// handoff) without paying a login shell per keystroke. Main thread only.
    var nvimPath: String?
    weak var lastFocusedTerm: LocalProcessTerminalView?
    weak var lastTopTerm: LocalProcessTerminalView?   // ⌥↑ returns here from the terminal panel
    /// While `Date()` is before this, a yazi pane quitting is a REQUESTED
    /// theme-reload restart — relaunch it in place instead of the normal
    /// quit handling (left pane: close app). A short window per attempt, so a
    /// restart refused by the plugin simply expires and a later manual `q`
    /// quits normally. Main thread only.
    var yaziRestartArmedUntil = Date.distantPast
    /// Panes still owed a theme restart ("L"/"R"). Set by
    /// `requestYaziRetheme` (appearance switch, ⌘R); a peer leaves the set
    /// when its pane relaunches. The plugin refuses while a pane is in use,
    /// so `attemptYaziRetheme` re-asks every `yaziRethemeRetryInterval` until
    /// `yaziRethemeDeadline`, then gives up and leaves ⌘R to the user.
    /// Main thread only.
    var yaziRethemePending: Set<String> = []
    var yaziRethemeDeadline = Date.distantPast
    var yaziRethemeRetry: DispatchWorkItem?
    /// Reason word of each pending pane's last refusal (`@RESTART_REFUSED`) —
    /// what the shortcut bar says it is waiting for. Main thread only.
    var yaziRethemeRefusals: [String: String] = [:]
    /// Right-click in a yazi pane waiting for the clicked row's hover (see
    /// Panel+ContextMenu). Main thread only.
    var pendingContextMenu: PendingContextMenu?
    /// Write end of `lazycvsFollowPath` while lazycvs runs in the terminal
    /// panel (-1 = no follow), and the directory last sent, so only real
    /// directory changes reach lazycvs. Main thread only.
    var lazycvsFollowFD: Int32 = -1
    var lazycvsFollowedDir: String?
    /// The file the open context menu is about — what the Services menu's
    /// `validRequestor` / `writeSelection` hand to a service. Main thread only.
    var contextMenuPath: String?
    /// One-shot taker of the next `@SELECTED` answer (⌘C wants the marked
    /// files on the pasteboard); nil means the answer is ⌘L's list.
    /// Main thread only.
    var selectionConsumer: (([String]) -> Void)?
    /// The one Services submenu AppKit fills (registered as NSApp.servicesMenu),
    /// re-parented into every context menu.
    let servicesMenu = NSMenu(title: "Services")
    /// Standing shortcut-bar note after the app stopped asking (deadline
    /// passed, or the plugin could not read yazi's state): the re-theme is
    /// now the user's ⌘R. nil = none. Cleared by the next relaunch.
    /// Main thread only.
    var yaziRethemeNote: String?
    /// Yazi's yank buffer as last announced over the FIFO (`@YANK:`); nil when
    /// empty. Shown in the shortcut bar in place of the tip of the day.
    /// Cleared on pane relaunch — a fresh yazi starts with an empty buffer,
    /// and if the session plugin restores one, its event refills this.
    /// Main thread only.
    var yankState: YankState?
    /// When the context menu's Copy was clicked; the next copy-mode `@YANK:`
    /// within `menuCopyPasteboardWait` also goes onto the macOS pasteboard
    /// (see `contextYank`). nil = no menu copy pending. Main thread only.
    var menuCopyPending: Date?
    /// Yazi's sort preference as last announced over the FIFO (`@SORT:`), the
    /// order the folder listing uses. Set on the main thread by `sortChanged`,
    /// read on the main thread by `showFolder` before it hands off to the
    /// loader queue. Main thread only.
    var listingSort = ListingSort.default
    /// Terminal rows above yazi's file list (header, tab bar) as last
    /// announced over the FIFO (`@LIST_TOP:`); the folder listing's first row
    /// goes on that row of the preview pane (`alignListingRows`). Set on the
    /// main thread by `listTopChanged`. Main thread only.
    var yaziListTop = 1
    /// The folder-listing row a single click just revealed, kept for the
    /// double-click that may follow: the first click already re-renders the
    /// pane (yazi hovers the row — the listing changes, or a file preview
    /// replaces it), so the second click cannot be resolved against what is
    /// under the mouse; it acts on this remembered row (`listingDoubleClick`).
    /// nil when no click is pending. Main thread only.
    var listingClick: ListingClick?

    /// Minimum pane extent (width in the horizontal split, height of the pane
    /// area in the outer split) — window resizes and divider drags must not
    /// collapse a pane.
    let minPane: CGFloat = 300
    /// How far ⌘⌃←/→ move a divider per keystroke (points).
    let paneResizeStep: CGFloat = 60
    /// Theme reload of the yazi panes: how often the app re-asks a busy pane,
    /// and how long before it stops and leaves ⌘R to the user. The automatic
    /// switch (sunrise/sunset) usually meets an idle pane; a selection or a
    /// long copy is what the retries wait out.
    let yaziRethemeRetryInterval: TimeInterval = 5
    let yaziRethemeTimeout: TimeInterval = 15 * 60
    /// Bottom terminal panel: initial and minimum height.
    let termPanelHeight: CGFloat = 240
    let minTermHeight: CGFloat = 120
    /// Context menu → Open in lazycvs: the command run in the terminal panel
    /// (the dotfiles shim around the lazycvs checkout, found on the login
    /// shell's PATH) and the window share the panel opens with — a full TUI
    /// is cramped in the plain-shell height.
    let lazycvsCommand = "lcvs"
    let lazycvsPanelShare: CGFloat = 0.5
    /// Context menu → Open in lazygit: the git twin. The Homebrew binary on
    /// the login shell's PATH; it shares lazycvs's panel height.
    let lazygitCommand = "lazygit"

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
        t.lineSpacing = terminalLineSpacing  // same reason: it sets the cell height
        applyTheme(t)                     // Catppuccin, following system light/dark
        t.processDelegate = self
        return t
    }

    // Login shell so PATH/config load, then exec the file manager. YAZI_ID/LEVEL
    // stripped so each pane is a fresh, separate yazi instance (they discover
    // each other via the DDS for cross-instance yank/paste). `startIn`
    // overrides the app start dir (theme-reload restarts resume where the
    // pane was, not where the app began). `reveal` hands a file to yazi as
    // its entry argument (cursor on the file, preview follows) — only the
    // initial left pane passes it, and only when the CLI arg was a file.
    func launch(_ t: LocalProcessTerminalView, extraEnv: [String: String],
                rememberCwd: Bool = false, run: String? = nil, startIn: String? = nil,
                reveal: String? = nil) {
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"; env["COLORTERM"] = "truecolor"
        env["YAZI_ID"] = nil; env["YAZI_LEVEL"] = nil
        // The macOS double-click interval (System Settings → Mouse), so the
        // bundled plugin's double-click on yazi rows agrees with the rest of
        // the desktop — yazi itself has no double-click.
        env["CONSPECTUS_DOUBLE_CLICK"] = String(NSEvent.doubleClickInterval)
        for (k, v) in extraEnv { env[k] = v }
        // `run` overrides the global command (e.g. the ide editor pane runs nvim).
        let cmd = run ?? command
        // Left/yazi pane records its cwd on exit so the next bare launch resumes there.
        let cwdFlag = (rememberCwd && cmd == "yazi") ? " --cwd-file \"\(lastCwdPath)\"" : ""
        let revealArg = (reveal != nil && cmd == "yazi") ? " \"\(reveal!)\"" : ""
        t.startProcess(executable: "/bin/zsh",
                       args: ["-l", "-c", "cd \"\(startIn ?? startPath)\" && exec \(cmd)\(cwdFlag)\(revealArg)"],
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
        // CONSPECTUS_NVIM is exported in every mode — the socket only exists
        // while the editor pane runs, and yazi's `open` guards on it existing,
        // so ⌘I can add the editor at runtime and routing follows automatically.
        launch(term, extraEnv: ["QLPEEK_FIFO": fifoPath, "CONSPECTUS_PEER": "L",
                                "CONSPECTUS_NVIM": nvimSocketPath,
                                "CONSPECTUS_TABS_FILE": tabsFileL,
                                "CONSPECTUS_TABS_RESTORE": tabsRestoreDefault ? "1" : "0"],
               rememberCwd: true, reveal: startRevealFile)
        startFifoReader()
        // Resolve external CLIs once (no per-use login shell): `ya` for clicks,
        // `bat` for text-preview syntax highlighting.
        resolveOnLoginPath("ya", missingWarning:
            "conspectus: `ya` not found on the login-shell PATH — click-to-navigate "
            + "falls back to a slow shell per click") { [weak self] in self?.yaPath = $0 }
        resolveOnLoginPath("bat", missingWarning:
            "conspectus: `bat` not found — text preview falls back to plain monospace "
            + "(no syntax highlighting)") { [weak self] in self?.batPath = $0 }

        // Pane layout is two independent toggles: the second yazi pane (⌘D)
        // and the preview pane (⌘E, always rightmost). `split` starts 2-pane
        // without preview, `triple` starts with both.
        if splitMode { detachPreview() }
        if splitMode || tripleMode { addSecondPane() }
        if ideMode { addEditorPane() }   // yazi | nvim | preview

        startMainThreadWatchdog()
        startTerminalRepaintInsurance()
        startPreviewClickMonitor()
        startMouseHistoryMonitor()
        startContextMenuMonitor()
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
            for t in [self.term, self.term2, self.editorTerm, self.bottomTerm] { t?.needsDisplay = true }
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

    /// Remove FIFOs left behind by dead instances: `target-<pid>` and
    /// `lazycvs-follow-<pid>` whose process is gone, plus the legacy shared
    /// `target`. Deliberate try? on the listing — the directory was created a
    /// moment ago, and a failed cleanup only leaves harmless stale pipes behind.
    func cleanupStaleFifos() {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: cacheDir)) ?? []
        for f in files {
            guard let prefix = ["target-", "lazycvs-follow-", "target"].first(where: { f.hasPrefix($0) }) else { continue }
            let alive = Int32(f.dropFirst(prefix.count)).map { kill($0, 0) == 0 } ?? false
            if !alive { unlink((cacheDir as NSString).appendingPathComponent(f)) }
        }
    }

    /// Re-theme live when the macOS appearance changes: the app's own chrome
    /// at once, the yazi panes by an in-place relaunch as soon as each is idle
    /// (`requestYaziRetheme`) — yazi fixes its flavor at startup, so nothing
    /// short of a relaunch re-colours it.
    func observeAppearanceChanges() {
        DistributedNotificationCenter.default.addObserver(
            forName: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil, queue: .main) { [weak self] _ in
            guard let self = self else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                for t in [self.term, self.term2, self.editorTerm, self.bottomTerm] {
                    if let t = t { applyTheme(t) }
                }
                self.styleFolder()
                self.styleHintBar()
                self.styleCheatSheet()
                self.styleTermPanes()
                self.updateFocusBorders()
                // Same path, new palette: bypass the text/pdf dedups, or the
                // markdown keeps its old-palette colours on the new background.
                self.refreshCurrentPreview()
                self.requestYaziRetheme()
            }
        }
    }
}
