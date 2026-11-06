# Engineering notes

These notes explain implementation decisions and failures that are easy to repeat. They are for contributors investigating *why* the code works this way; dated entries describe the problem and solution at that time, and later entries may supersede them.

For using the app, start with the [README](README.md), the [IDE and PDF notes walkthrough](docs/ide-notes.md), or the [handbook](docs/handbook.md). Open work and checks still awaiting real-world use belong in [TODO.md](TODO.md); contributor rules live in [CLAUDE.md](CLAUDE.md).

## Names used in these notes

These entries sometimes refer to the author's other tools: **perlege** is a separate PDF reader with saved highlights and reading positions; **qlpeek** puts a Quick Look preview beside an existing terminal; **lazycvs** and **lazygit** are terminal interfaces to CVS and Git. **Dotfiles** means personal shell, yazi and Neovim configuration outside this repository; **smart-splits** is a Neovim plugin for navigating editor splits and terminal panes. References to WezTerm and kitty concern terminal emulators used as comparisons. These tools explain the origin of some decisions; they are optional integrations rather than prerequisites for Conspectus's basic browsing and note workflow.

**CephFS** is a network filesystem, **ceph-fuse** its mounting client, and `ceph-mount` / `ceph-remount` are external scripts from the author's Ceph setup. **TRAMP** is Emacs's syntax for remote paths, which Conspectus also accepts without requiring Emacs. **FIFO** is a local named pipe for messages, **DDS** is yazi's messaging between instances, and **RPC** is the command channel to Neovim. The [handbook](docs/handbook.md#how-it-works) distinguishes bundled behaviour from personal bindings and optional integrations.

## Find a design decision

The entries remain in their existing order so references from code and older notes stay useful. Use this subject index to jump to a problem. New entries should state the problem, solution and gotchas; this file is not a change log.

### IDE and companion notes

- [2026-07-29 — PDF note auto-follow vs. "preview follows the editor"](#2026-07-29--pdf-note-auto-follow-vs-preview-follows-the-editor)
- [2026-07-26 — IDE mode: send files to one nvim instead of spawning editors](#2026-07-26--ide-mode-send-files-to-one-nvim-instead-of-spawning-editors)

### Preview rendering and Quick Look

- [2026-11-06 — The UTF-8 BOM test passed locally and failed in CI: Foundation differs between macOS versions](#2026-11-06--the-utf-8-bom-test-passed-locally-and-failed-in-ci-foundation-differs-between-macos-versions)
- [2026-10-14 — Latin-1 files: decode ourselves, feed bat via stdin](#2026-10-14--latin-1-files-decode-ourselves-feed-bat-via-stdin)
- [2026-07-27 — `l` jumped to the preview instead of entering a folder](#2026-07-27--l-jumped-to-the-preview-instead-of-entering-a-folder)
- [2026-07-22 — QLPreviewView comes back blank after being hidden](#2026-07-22--qlpreviewview-comes-back-blank-after-being-hidden)
- [2026-07-22 — SIGABRT in split mode: QLPreviewView auto-closes off-window](#2026-07-22--sigabrt-in-split-mode-qlpreviewview-auto-closes-off-window)
- [2026-07-22 — Triple mode: preview follows the active pane via one FIFO](#2026-07-22--triple-mode-preview-follows-the-active-pane-via-one-fifo)
- [2026-07-22 — Folder look-ahead at scale: bulk keys + cap; further options](#2026-07-22--folder-look-ahead-at-scale-bulk-keys--cap-further-options)
- [2026-07-23 — Third QLPreviewView trap: hiding it can crash in KVO teardown](#2026-07-23--third-qlpreviewview-trap-hiding-it-can-crash-in-kvo-teardown)
- [2026-07-25 — Live preview refresh (edit in nvim, see it on save)](#2026-07-25--live-preview-refresh-edit-in-nvim-see-it-on-save)
- [2026-07-25 — Markdown: native document render (swift-markdown) + toolbar toggle](#2026-07-25--markdown-native-document-render-swift-markdown--toolbar-toggle)
- [2026-07-25 — Hardening step 1: native text preview off Quick Look](#2026-07-25--hardening-step-1-native-text-preview-off-quick-look)
- [2026-07-24 — Fourth QLPreviewView trap: wheel events die after mouse re-entry](#2026-07-24--fourth-qlpreviewview-trap-wheel-events-die-after-mouse-re-entry)
- [2026-07-22 — Quick Look wedges under churn; debounce the requests](#2026-07-22--quick-look-wedges-under-churn-debounce-the-requests)
- [2026-08-10 — Typesetting the markdown preview (TextKit, not CSS)](#2026-08-10--typesetting-the-markdown-preview-textkit-not-css)

### Network mounts and remote access

- [2026-08-28 — Network mounts (CephFS via SMB): the preview must not touch them](#2026-08-28--network-mounts-cephfs-via-smb-the-preview-must-not-touch-them)
- [2026-11-04 — sshfs under macFUSE 5 never returns](#2026-11-04--sshfs-under-macfuse-5-never-returns)
- [2026-11-04 — sudo over sshfs with a password (TRAMP's `|sudo:`)](#2026-11-04--sudo-over-sshfs-with-a-password-tramps-sudo)
- [2026-11-04 — Starting conspectus from its own ⌘J terminal broke yazi's config](#2026-11-04--starting-conspectus-from-its-own-j-terminal-broke-yazis-config)
- [2026-11-04 — A dead network mount still counts as mounted](#2026-11-04--a-dead-network-mount-still-counts-as-mounted)
- [2026-11-05 — `mount` waits two minutes on a hung FUSE mount; the launcher asks the app instead](#2026-11-05--mount-waits-two-minutes-on-a-hung-fuse-mount-the-launcher-asks-the-app-instead)

### Navigation, terminal, themes and core structure

- [2026-10-20 — A blocking yazi shell must not trigger a pane resize](#2026-10-20--a-blocking-yazi-shell-must-not-trigger-a-pane-resize)
- [2026-10-18 — CVS status without the server: compare strings, read markers](#2026-10-18--cvs-status-without-the-server-compare-strings-read-markers)
- [2026-10-11 — Right-click menu in a terminal pane: ask yazi which row that was](#2026-10-11--right-click-menu-in-a-terminal-pane-ask-yazi-which-row-that-was)
- [2026-10-11 — Automatic yazi re-theme: wait for idle, address panes by peer](#2026-10-11--automatic-yazi-re-theme-wait-for-idle-address-panes-by-peer)
- [2026-07-30 — Tab session: yazi 26 ignores tab_create's positional path](#2026-07-30--tab-session-yazi-26-ignores-tab_creates-positional-path)
- [2026-07-27 — Washed-out colours after a dark↔light switch (stale appearance)](#2026-07-27--washed-out-colours-after-a-darklight-switch-stale-appearance)
- [2026-07-22 — Cheat sheet parses keymap.toml with a TOML-subset scanner](#2026-07-22--cheat-sheet-parses-keymaptoml-with-a-toml-subset-scanner)
- [2026-07-22 — Bottom terminal: fresh shell per open instead of cd-follow](#2026-07-22--bottom-terminal-fresh-shell-per-open-instead-of-cd-follow)
- [2026-07-22 — Keyboard focus: by intent only, visible, restored](#2026-07-22--keyboard-focus-by-intent-only-visible-restored)
- [2026-07-22 — FIFO per instance; reader opens O_RDWR (wedged-open bug)](#2026-07-22--fifo-per-instance-reader-opens-o_rdwr-wedged-open-bug)
- [2026-07-24 — SwiftTerm display wedge under wheel floods; repaint insurance](#2026-07-24--swiftterm-display-wedge-under-wheel-floods-repaint-insurance)
- [2026-07-23 — Click-to-navigate felt sluggish: a login shell per click](#2026-07-23--click-to-navigate-felt-sluggish-a-login-shell-per-click)
- [2026-07-22 — Self-contained: bundled conspectus.yazi, no qlpeek CLI](#2026-07-22--self-contained-bundled-conspectusyazi-no-qlpeek-cli)
- [2026-07-22 — Dual-pane yazi: DDS ids and cd-sync](#2026-07-22--dual-pane-yazi-dds-ids-and-cd-sync)
- [2026-07-22 — Theme following without configuring yazi directly](#2026-07-22--theme-following-without-configuring-yazi-directly)
- [2026-07-22 — Testability split: ConspectusCore](#2026-07-22--testability-split-conspectuscore)
- [2026-08-17 — Hover, not selection: `o`/`Enter` and click-to-enter in the plugin](#2026-08-17--hover-not-selection-oenter-and-click-to-enter-in-the-plugin)
- [2026-10-24 — A symlink to a folder lists as empty (ENOTDIR)](#2026-10-24--a-symlink-to-a-folder-lists-as-empty-enotdir)
- [2026-10-24 — main.swift globals initialize in order: a CLI block must not use a `let` below it](#2026-10-24--mainswift-globals-initialize-in-order-a-cli-block-must-not-use-a-let-below-it)

## 2026-10-20 — A blocking yazi shell must not trigger a pane resize

**Problem:** `E C` (lazycvs) quit the whole app; the context menu's "Open in lazycvs" was fine, and the FIFO handler was innocent (a hand-written `@LAZYCVS:` line opened the panel). No crash report: the app exited with status 0.

**Solution:** The keymap ran `shell … --block`, which hands the terminal to its child; when the child exits yazi re-probes the terminal (DA1 query) before redrawing. The FIFO message made the app open the terminal panel, i.e. resize the yazi pane, right inside that probe — its `read` returned EINTR, yazi treated it as fatal and quit (yazi.log: `Terminal failed to respond to DA1 … Interrupted system call`), and the left pane quitting is the app's exit signal. Now the keymap's outer shell never blocks: inside the app it emits `plugin conspectus lazycvs` (the plugin writes the FIFO from Lua, hovered item), in a bare terminal it emits a *second*, blocking shell for `lcvs`.

**Gotcha:** The same holds for any future `--block` binding whose side effect reaches the app: the app must not relayout the yazi pane while yazi is resuming. Reproduce with real keystrokes (osascript) — `ya emit-to` could not address the pane (yazi's DDS ids are not pids), and a plain FIFO write skips the block/resume window entirely.

## 2026-10-18 — CVS status without the server: compare strings, read markers

**Problem:** Per-file CVS signs on every directory yazi enters; `cvs -n update` asks the server (seconds, network), so it cannot run per directory.

**Solution:** Everything except "needs update" is in the working copy. `CVS/Entries` holds each file's checkout mtime as an asctime string in UTC; CVS calls a file modified when `asctime(gmtime(mtime))` differs from that string — a string compare, so `cvsTimestamp` builds exactly that string (`strftime "%a %b %e …"`, the day space-padded: `Mon Mar  4`) instead of parsing dates. Revision `0` = added, `-…` = removed, not in Entries = unknown unless a cvsignore pattern (fnmatch) matches.

**Gotcha:** After a conflicted merge the timestamp reads `Result of merge+<asctime>`, and an *edited* file is still `C` as long as it holds `<<<<<<< ` / `=======` / `>>>>>>> ` lines — cvs scans the content. Checked against `cvs -n -q update` on a throwaway local repository. The built-in ignore list is taken from the installed binary (`strings $(which cvs)`): Homebrew's 1.12 adds `._*`.

## 2026-10-14 — Latin-1 files: decode ourselves, feed bat via stdin

**Problem:** Text previews of legacy files (CVS repo: Latin-1 TeX) showed `�` for every umlaut, although `readTextLeniently` already had a Latin-1 fallback. That fallback only ran without bat — bat reads files as strict UTF-8 and replaces each invalid byte with U+FFFD, so its output decoded fine and the fallback never fired.

**Solution:** `ConspectusCore.decodeText` guesses the encoding (UTF-16 with BOM → UTF-8 → Windows-1252 → Latin-1), and `runBat` gets the decoded text on stdin as UTF-8 with `--file-name=<path>`, so syntax detection still works.

**Gotcha:** Writing bat's stdin needs its own thread (both pipe buffers full → deadlock), and the write fd gets `F_SETNOSIGPIPE` — otherwise a bat that exits early kills the app with SIGPIPE.

## 2026-10-11 — Right-click menu in a terminal pane: ask yazi which row that was

**Problem:** A Finder-style context menu needs the file under the mouse. In the preview pane the app knows it (listing rows carry their path). In a yazi pane it does not — the pane is a grid of characters yazi drew; only yazi knows which file sits on which row. And SwiftTerm forwards left clicks only, so a right-click never even reaches yazi.

**Solution:** A local `rightMouseDown` monitor (same pattern as the side buttons) swallows the click, synthesizes a left mouse down/up into the terminal view (yazi moves its cursor onto the row and emits a hover), arms a `PendingContextMenu`, and the next FIFO hover opens the menu for exactly that path. A 300 ms fallback covers the silent case: the clicked row was already hovered, so no hover event comes, and the menu opens for the last hover.

**Gotcha:** File operations from the menu must not run on "whatever yazi hovers right now". yazi's `rename`/`remove` act on the SELECTION when one exists — `--hovered` fixes that — and after a `reveal` into another directory the hover is not yet the target. The plugin therefore runs the command immediately only if the hovered url already equals the path; otherwise it stores a `pending_act`, reveals, and the hover handler runs it only when the hover IS that path — any other hover cancels it. Trashing a neighbour because a reveal landed one row off is the failure this guards against.

## 2026-10-11 — Automatic yazi re-theme: wait for idle, address panes by peer

**Problem:** After a light↔dark switch the app re-themed itself live but the yazi panes stayed in the old flavor until a manual ⌘R (yazi reads OSC 11 only at startup). Making ⌘R automatic naively would bounce a pane mid-copy or throw away a selection — the reason it had been manual.

**Solution:** The appearance observer calls the same `requestYaziRetheme` as ⌘R. The plugin decides idleness (no running tasks, normal mode, nothing selected) and answers a refusal over the FIFO (`@RESTART_REFUSED:<peer>:
<tasks|selection|error>`); the app re-asks every 5 s until a 15-min deadline
and shows the reason in the shortcut bar. The yank buffer needs no guard: the session plugin (`sync_yanked`) persists it through the DDS, so a relaunched yazi gets it back.

**Gotcha:** The restart message must address panes individually (body `"<L|R|*> <ask|quiet>"`). With a plain broadcast, an idle pane restarts on the first attempt and is then bounced AGAIN on every retry meant for its busy sibling. `processTerminated` relaunches a pane only inside a 4-s arm window per attempt, so a manual `q` between retries still quits normally. The mode check fails loud: missing `is_select`/`is_unset` fields are `error` (stop, tell the user), never "not in use" — a silent pass there would restart a pane in visual mode after the next yazi API drift.

## 2026-07-30 — Tab session: yazi 26 ignores tab_create's positional path

**Problem:** Restoring saved tabs via `emit("tab_create", { dir })` silently created every tab in the ACTIVE tab's dir — the path argument is ignored in yazi 26.5.6 (it works in keymap strings, not via the Lua emit table).

**Solution:** create-then-cd: `tab_create { current = true }` followed by `cd { dir }` — commands apply in emit order, and the cd always hits the just-created (now active) tab. Restore = cd tab 1, then create+cd per saved tab, then `tab_switch` (0-based) to the saved active index.

**Gotcha:** a "restore worked" test is only conclusive if the state file CHANGES: the post-restore re-snapshot (cd events fire during restore, incl. per tab_create) can be byte-identical to the crafted input. Verify against real state — e.g. ⌘R's pre-quit snapshot, which reads `cx.tabs` directly.

## 2026-07-29 — PDF note auto-follow vs. "preview follows the editor"

**Problem:** ide notes mode (hover a PDF → its `<stem>.md` opens in nvim) feeds the feature that goes the *other* way: nvim announces every buffer switch (`@EDITOR_FILE:` on BufEnter / the focus-in RPC query), and the preview follows it. Naively combined they fight — the auto-follow push triggers a BufEnter, nvim announces the note, and the preview would swap the PDF for its own note's markdown (or, mid-cycle, yank the preview off whatever yazi hovers next, because the echo arrives ~100–300 ms late).

**Solution:** two guards, both existing-state-based, no new channel. (1) The late echo dies at the focus guard that was already there: editor announcements are only honoured while the editor pane is focused, and during yazi-driven cycling it never is. (2) While the editor IS focused and announces exactly `activeNote.note`, show `activeNote.pdf` instead — editing a note keeps its PDF on the right (also covers `:b`-switching back to the note).

**Gotcha:** guard (2) must compare against the *resolved* note path, not `defaultNotePath` — the note may live in `notes/` or the central library, and a path-prefix or stem comparison would misfire on same-named files elsewhere.

## 2026-07-27 — `l` jumped to the preview instead of entering a folder

**Problem:** With files selected (for copy/cut), pressing `l` on a *folder* focused the preview pane instead of entering the folder.

**Solution:** The `l`/`<Right>` keymap decided dir-vs-file with a shell `[ -d "$1" ]`, but in yazi `"$1"` (like `"$@"`) is the first **selected** file, or the hovered one only when nothing is selected. So a pending selection made `[ -d ]` test a *file* → the binding fell through to `@FOCUS_PREVIEW`. Moved the decision into the bundled plugin (`ya emit plugin conspectus`), which reads `cx.active.current.hovered.cha.is_dir` — the item under the cursor, never the selection. Same root cause as the earlier "Enter opens the selected PDF, not the hovered file": navigation/preview must key off the HOVERED item.

**Gotcha:** the plugin lives only in conspectus's overlay, so the keymap guards `ya emit plugin conspectus` behind `[ -n "$QLPEEK_FIFO" ]` — a plain terminal yazi (no plugin) keeps the simple shell path.

## 2026-07-27 — Washed-out colours after a dark↔light switch (stale appearance)

**Problem:** Toggling macOS dark↔light while conspectus ran left the panel low-contrast — e.g. yazi's directories in Mocha's pale blue (`#89b4fa`) on Latte's light background — and it stayed wrong until the app was relaunched.

**Solution:** `systemIsDark()` read `UserDefaults AppleInterfaceStyle`, which is frequently still stale when `AppleInterfaceThemeChangedNotification` fires. So on a switch `applyTheme` installed the OLD palette and set the terminal's `nativeBackgroundColor` to the old appearance. yazi picks its Latte/Mocha flavor from that background (it queries it over OSC 11), so it latched onto the wrong flavor — truecolor, so the wrong blue was baked in — and since nothing corrected the background afterwards it persisted until relaunch. Fix: read the live `NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])`, which is current at notification time.

**Gotcha:** the directory colour is truecolor from the flavor (`*/ = #1e66f5`), not an ANSI index, so it's driven by *which flavor yazi chose*, i.e. by the background we advertise — not by the ANSI palette we install. The whole theme's coherence hangs on advertising the correct bg. The remaining half — yazi re-queries OSC 11 only at startup, so a LIVE switch leaves a running yazi in the old flavor — is solved by ⌘R (2026-07-30): a DDS `panesync-restart` asks each yazi to quit-if-idle (the plugin refuses while file tasks run — quitting would abort copies), and an armed window in `processTerminated` turns that quit into an in-place relaunch (cwd from --cwd-file / last hover) instead of the normal left-pane-quit-closes-app path. First shipped as a manual ⌘R only ("only the user knows whether NOW is a good moment"); since 2026-10-11 the appearance switch triggers it automatically and the plugin's idle check is the judge of "a good moment" — see that entry.

## 2026-07-26 — IDE mode: send files to one nvim instead of spawning editors

**Problem:** `conspectus ide` is yazi | nvim | preview. Opening a file from yazi must land in the *existing* middle nvim (as a buffer), not launch a new editor each time — and from either yazi pane in a split.

**Solution:** The middle pane runs `nvim --listen <socket>` (nvim's RPC server). conspectus owns the socket path (`nvimSocketPath`, per-pid like the FIFO) and hands it to every yazi pane as `$CONSPECTUS_NVIM`. yazi's `o`/`Enter` binding then does `nvim --server $CONSPECTUS_NVIM --remote "$@"` — the client call adds the file(s) as buffers and returns immediately (no new UI). This is the exact channel-ownership pattern of the preview FIFO: conspectus owns the channel, exports its address, yazi writes into it.

The editor toggles at runtime too (**⌘I**), not just via `conspectus ide`.

**Preview follows the editor:** while the nvim pane is focused the preview shows nvim's active file, not yazi's hover. Two triggers, both reusing `update` (so pin + the mtime watch still apply): focus-in RPC-queries `expand('%:p')` (`previewEditorCurrentFile`); an in-nvim buffer switch pushes `@EDITOR_FILE:<path>` to the FIFO on `BufEnter` (`editorFileHover`). Both are gated on `firstResponder === editorTerm`, so leaving the editor hands the preview back to yazi. The push needs the editor nvim to know the FIFO — hence `CONSPECTUS_FIFO` in its launch env, and the opt-in autocmd in dotfiles `smart-splits.lua`. Safe because conspectus holds the FIFO open O_RDWR for its whole life, so nvim's `io.open(fifo,"a")` never blocks (and the editor can't outlive conspectus — it's a child).

**Split handoff (⌥-arrows):** inside the editor, ⌥-arrows should navigate nvim's OWN splits first and only hand off to the neighbouring conspectus pane at nvim's edge (smart-splits, as across WezTerm/kitty). conspectus **drives** this over the RPC socket rather than forwarding ⌥-arrows through the terminal: on ⌥-arrow with the editor focused, `editorSplitNavOrHandoff` spawns `nvim --server <sock> --remote-expr v:lua.conspectus_move('left')`, which moves within nvim and returns `"moved"` or `"edge"`; on anything but `"moved"` conspectus moves the pane. Chosen over key-forwarding because that would depend on SwiftTerm's ⌥-key encoding (whether ⌥← becomes a proper `<M-Left>` meta sequence) — brittle. It also degrades safely: no nvim helper / nvim missing → the RPC fails → plain pane move (the old behaviour), so the Swift side ships independently of the opt-in dotfiles helper (`plugins/smart-splits.lua` defines `_G.conspectus_move`).

**Gotchas:** (1) `launch` grew a `run:` override because the editor pane runs nvim, not the global `command` (yazi). (2) The second-yazi slot (split/triple) and the editor slot (ide) are the same middle position and never coexist, so `middleTerm = term2 ?? editorTerm` unifies focus cycling / borders instead of special-casing. (3) `$CONSPECTUS_NVIM` is exported to yazi in EVERY mode, not only ide — you can't inject env into an already-running yazi, so ⌘I could never enable routing after launch otherwise. The socket only exists while the editor runs, and the yazi binding guards on `[ -S "$CONSPECTUS_NVIM" ]`, so routing follows the pane automatically: editor up → send to nvim, editor down → normal opener. (4) Symmetric lifecycle with the second yazi: quitting nvim (`:qa`) collapses the pane (unlinking the socket) rather than respawning — ⌘I re-adds it. Respawn-on-exit was rejected: it makes the editor un-quittable.

## 2026-07-22 — QLPreviewView comes back blank after being hidden

> Superseded 2026-07-23 (third trap, below): the view is never hidden any more, the covers sit on top of it, and the rebuild survives only in `attachPreview`. Kept for the symptom.

**Problem:** Hovering a folder hides the `QLPreviewView`; on returning to a file it could stay permanently blank. Its remote Quick Look extension dies while the view is hidden, and `refreshPreviewItem()` doesn't revive it.

**Solution:** On every dir→file transition, rebuild the `QLPreviewView` from scratch and swap it into the container; file→file keeps the fast in-place swap (`Panel.update`).

**Notes:** Don't "optimize" the rebuild away — the blank state is not reproducible on every machine/OS version, but it is real.

## 2026-07-22 — SIGABRT in split mode: QLPreviewView auto-closes off-window

**Problem:** With the second yazi pane open, hovering a *file* in the left pane crashed the app (`_QLRaiseAssert` → SIGABRT in `-[QLPreviewView setPreviewItem:]`). `addSecondPane` removes rightContainer from the window; a `QLPreviewView` that leaves the window hierarchy closes itself (its remote Quick Look extension is torn down), and setting `previewItem` on a closed view is a QuickLook assertion failure. The left yazi keeps writing hovered paths to the FIFO the whole time.

**Solution:** `update()` skips all view work while the preview is detached (today `previewAttached`, derived from the view hierarchy; `lastPath` keeps tracking). `removeSecondPane()` rebuilds the `QLPreviewView` via `rebuildPreview()` (shared with the dir→file blank-fix path) and replays `lastPath` so the preview resumes.

**Notes:** Never reuse a `QLPreviewView` after it was hidden for long or detached from the window — always rebuild. Folder hovers never crashed (they go to the self-rendered listing), which is why it only hit "sometimes".

## 2026-07-22 — Triple mode: preview follows the active pane via one FIFO

**Problem:** Three panes (two yazi + preview) need the preview to follow whichever yazi is being used — but tracking keyboard focus and switching preview sources is fiddly and racy.

**Solution:** No focus tracking at all. Both yazi instances get the same `QLPEEK_FIFO`; only the pane actually being navigated emits hover events, so the last writer *is* the active pane. Layout became two independent toggles (second pane ⌘D, preview ⌘E, preview always rightmost) instead of hardwired modes; `split`/`triple` are just start presets.

**Notes:** Turning the second pane off while the preview is hidden re-attaches the preview — a lone terminal pane is never left standing. The split-view delegate (ratio-keeping resize, 300pt min) is generalized to n panes.

## 2026-07-22 — Cheat sheet parses keymap.toml with a TOML-subset scanner

**Problem:** The ⌘K cheat sheet should show the user's *real* yazi bindings, but a full TOML dependency is overkill (and needs sign-off per the conventions), while naive line/regex parsing breaks on the config's triple-quoted multiline `run` strings, which contain brackets, braces, and quotes.

**Solution:** `ConspectusCore/Keymap.swift` — a small character-level scanner for exactly the keymap subset: `[mgr]` inline-table arrays and `[[mgr.prepend_keymap]]` blocks, all four TOML string forms, comments, `on`/`desc`/`run` extraction (`desc` falls back to a compacted `run`). Everything outside the subset throws a typed `KeymapParseError`; the app shows parse failures in the panel footer instead of swallowing them.

**Notes:** It is deliberately NOT a general TOML parser — if yazi's config format grows beyond this subset, extend the scanner (tests in `KeymapTests.swift` include a fixture mirroring the real config). Legacy configs use `[manager]` instead of `[mgr]`; `loadUserKeymap` retries with that name on `missingSection`.

## 2026-07-22 — Bottom terminal: fresh shell per open instead of cd-follow

**Problem:** A ⌘J terminal panel should open in the dir yazi is visiting. Following yazi's cwd *live* would mean typing `cd` into a running interactive shell — which can clobber whatever the user has half-typed, and there is no reliable way to detect an empty prompt from outside.

**Solution:** No live follow. Each ⌘J open spawns a fresh login zsh in the current yazi dir; close (⌘J or `exit`) kills the shell. The cwd comes from the existing hover FIFO: every hovered path's parent *is* the directory being listed, so `dirname(lastPath)` tracks the active pane for free (same trick as the preview in triple mode).

**Notes:** A failed `cd` (dir vanished) prints its error into the terminal and the shell still starts — visible, not swallowed. If persistent sessions are ever wanted, hide instead of terminate, but then the reopen-relocates semantics is lost.

Gotcha: NSSplitView's `setPosition`/delegate layout silently gave a programmatically added subview **0pt height** (shell ran, prompt invisible — a white panel in light mode). `layoutOuterPanes()` therefore sets the outer frames explicitly on open/close/resize; never rely on `setPosition` for runtime add/remove in the outer split.

## 2026-07-22 — Folder look-ahead at scale: bulk keys + cap; further options

**Problem:** Hovering a huge directory (tens of thousands of entries) statted every entry individually and built a megabyte `NSAttributedString` on the main thread — UI hitch and a transient memory spike.

**Solution:** Enumerate with `contentsOfDirectory(at:includingPropertiesForKeys: [.isDirectoryKey])` — the isDir bit arrives in one `getattrlistbulk` kernel pass instead of a stat per entry. Sort *all* entries (cheap once isDir is free, keeps dirs-first correct in huge folders), then cap only the rendering at `folderListingCap` (500) with a visible "… and N more entries" line.

**Notes:** Loading now also runs **off the main thread with cancellation**: every hover bumps a lock-guarded generation counter, and an in-flight load checks it after the disk I/O (skips the string build) and again before applying — navigating on drops stale work instead of racing it out of order. The previous listing stays visible until the new one lands (Finder-style, no white flash). Options if the cap ever hurts (kept for the future): (1) virtualized `NSTableView` with a lazy data source — only visible rows materialize, scrollable through 100k entries at constant memory (how Finder does it; would replace the capped `NSTextView`); (2) per-directory cache keyed on path + mtime for instant re-hovers.

## 2026-07-22 — Keyboard focus: by intent only, visible, restored

**Problem:** After switching to an editor launched out of yazi (E c → VS Code) and back, hjkl/arrows went dead while mouse-wheel scrolling kept working — the QLPreviewView had silently become first responder (scroll events need no key focus, key events do). Yet a *deliberately* focused preview is useful: Quick Look natively takes arrows/PgUp/Space.

**Solution:** Three pieces. (1) `IntentFocusPreviewView.allowFocus` — the preview refuses first-responder status except during the explicit ⌘⌥→ command; KVO on `window.firstResponder` revokes the permission when focus moves away. (2) `applicationDidBecomeActive` restores the last-focused terminal if reactivation left focus on a non-terminal. (3) A subtle gray border (fg at 25% alpha) marks the focused pane, shown only when more than one focusable pane exists.

**Notes:** The KVO observation is the single source of truth for border updates — mouse clicks change first responder without any of our code running, so per-call-site updates would miss them. `updateTitle()` also repaints borders because attach/detach changes the target set without a first-responder change.

2026-07-24: two more silent keyboard thieves of the same family — a click on a folder-listing row focused its NSTextView, and the ⌘K cheat panel took key-window status; both left yazi deaf with the app looking healthy. Rule: anything display-only (listing, reference panels) must refuse first responder / key status (`NonFocusableTextView`) — links, scrolling, and close buttons all work without the keyboard.

2026-08-24: the cheat sheet grew a filter field, which needs the keyboard. Refusing key status wholesale would have made that impossible; typing keys away from yazi unconditionally would bring the old bug back. `NSPanel`'s `becomesKeyOnlyIfNeeded` (utility windows only) splits it exactly right: the panel goes key when a click lands on a control that needs text input, and stays out of the way for clicks on the list or the scroller. The keyboard is handed back explicitly — Esc in the field and closing the sheet both call `window.makeKeyAndOrderFront`, so yazi is never left deaf.

## 2026-07-22 — FIFO per instance; reader opens O_RDWR (wedged-open bug)

**Problem:** All instances shared `~/.cache/conspectus/target`. Any new launch (second window, headless test run) unlinked and recreated it — and a running instance whose reader was blocked in `fopen("r")` (which waits for a writer) stayed blocked on the orphaned inode *forever*: previews silently stopped updating for keyboard and mouse alike, with no error anywhere.

**Solution:** The FIFO is `target-<pid>` — one per instance, handed to that instance's yazi children via QLPEEK_FIFO; startup removes FIFOs of dead pids (and the legacy shared `target`). The reader now opens with `O_RDWR`: opening a FIFO read-write never blocks waiting for a writer and never sees EOF between writers, so the wedged-open state cannot occur at all.

**Notes:** If previews ever stop updating again, check `ls ~/.cache/conspectus/` and the reader thread first — this failure mode is silent by nature. Multiple conspectus windows are now safe to run at once.

## 2026-07-23 — Third QLPreviewView trap: hiding it can crash in KVO teardown

**Problem:** `preview.isHidden = true` (on folder hover) crashed with SIGABRT: hiding the view runs QL's `_updateControls → _teardownScrollers → unbind → removeObserver:forKeyPath:`, and when its internal bindings are already torn (after heavy PDF churn) that KVO removal throws an uncaught exception. Swift cannot catch ObjC exceptions, so the app dies.

**Solution:** Never hide (or un-hide) the QLPreviewView again. The opaque folder listing is a sibling ABOVE it and simply **covers** it; file hovers uncover it. Bonus: the whole hidden-state bug family disappears — no auto-close while hidden, no blank-view rebuild on dir→file (previewDirty removed), less QL churn overall. The rebuild survives only where the view actually leaves the window: attachPreview (⌘E) — which doubles as the manual recovery for a wedged preview.

**Notes:** QLPreviewView state rules learned so far: (1) leaves window → auto-closes, must rebuild; (2) request churn → debounce; (3) hide/unhide → never do it, cover instead; (4) pointer exit/re-entry → remote may stop processing wheel events, re-arm with a lazy focus nudge (next entry); (5) the same `_teardownScrollers` KVO crash also fires when macOS switches the recommended scroller style mid WebKit layer commit (fast wheel scrolling a Web2/markdown preview). Pinning `AppleShowScrollBars=Always` did NOT stop it (second identical crash with the pin verifiably active) and was itself a bug — an app-wide persistent default forcing legacy scrollbars everywhere; startup now REMOVES that stale key. The working protection is the ConspectusShield target: an ObjC swizzle wrapping `-[QLScrollController _teardownScrollers]` in @try/@catch (Swift cannot catch ObjC exceptions). Fails loud at startup if the private method disappears in a macOS update; success is visible in the event log.

## 2026-07-25 — Live preview refresh (edit in nvim, see it on save)

**Problem:** The preview only updated on hover. Editing a note in nvim (left pane) and saving didn't refresh the preview (right).

**Solution:** Poll the previewed file's mtime (`watchPreviewFile`, armed in requestFilePreview, cancelled in showFolder/detach). On a change it calls `refreshCurrentPreview`, which busts the per-type dedups (text via lastTextPath=nil, PDF via pdfLoadedMtime=nil) and re-runs `update` (so the 120ms debounce + generation cancellation still apply).

**Gotcha — the watch only covers the file being shown (2026-10-25):** the PDF document is kept across hovers onto other files (only its pane hides), and the dedup in requestFilePreview compared the URL alone. Hover the PDF, hover its .md, rebuild, hover the PDF again → the old document came back (130 pages shown, 129 on disk). The dedup is now keyed on URL + mtime (`pdfLoadedMtime`).

**Gotcha — why polling, not an fd watch (this is the perlege lesson):** the first version used a `DispatchSourceFileSystemObject` on an `O_EVTONLY` fd, re-arming on `.rename`/`.delete` to follow editors' atomic saves. That handles nvim (write-temp-then-rename, one clean swap) but NOT a build tool. `latexmk` deletes/recreates/moves the PDF several times per run, so the file is briefly *absent*; an fd is bound to one inode, and if the re-`open()` lands in the gap where nothing is there, the watch is lost for good — exactly the failure that plagued perlege. `stat` on the path has no inode identity: file gone this tick → we skip (nil ≠ change), back next tick with a new mtime → refresh. A 0.7s repeating Timer (tolerance 0.2), gated to an active file preview so it stops on dir/idle (App Nap stays intact — a foreground app viewing a file isn't the idle case the gating protects). `CONSPECTUS_WATCH=off` disables it. Live-verified: in-place write, append, and atomic rename-save all refresh; no loop (re-arm records the fresh mtime, so it doesn't self-fire).

## 2026-07-25 — Markdown: native document render (swift-markdown) + toolbar toggle

**Problem:** The rendered markdown mode used glow → ANSI → NSTextView, which looks like a *terminal* (monospace, ANSI colours), not a *document* (the Claude-viewer target: proportional serif, real tables, code chips). glow can't cross that gap.

**Solution:** A real document renderer. Added the swift-markdown SPM dependency (Apple; the second dependency after SwiftTerm — a deliberate, user-approved decision). `MarkdownRender.swift` walks the AST into a themed `NSAttributedString`: serif body/headings (via `.serif` font design), sized headings, bold/italic, inline-code chips (mono + subtle bg), fenced code blocks, lists, blockquotes, thematic rules, links, and **real tables via NSTextTable/NSTextTableBlock**. Themed to the palette. glow removed.

A toolbar on the text preview (shown only for markdown) carries a segmented **eye / `</>`** toggle (rendered↔source), like the Claude artifact viewer; `M` (any pane, via the @TOGGLE_MD FIFO sentinel) and the focused preview do the same, all routed through `setMarkdownRender`.

**Notes:** The render runs off-thread (fast for notes; size-capped). NSTextTable didn't crash on real tables (live-verified). Source mode still uses bat. Everything in-process, no WebKit — markdown never touches Quick Look / the sbarex QLMarkdown plugin now, whichever mode.

## 2026-07-25 — Hardening step 1: native text preview off Quick Look

**Problem:** Every QLPreviewView crash/wedge traces to Quick Look being out-of-process (remote extension + private internals). The most hovered files are text/source/notes, and markdown specifically routed through the third-party QLMarkdown plugin → HTML → Apple's Web2/WebKit display plugin — the exact `_teardownScrollers` abort path. So the common case sat on the most fragile path.

**Solution:** Type-dispatched preview. `ConspectusCore.isTextPreviewable` (pure, tested) classifies by extension/basename; text files render in a native in-process `IntentFocusTextView` (`showTextPreview`), covering the QL view like the folder listing, loaded off-thread with the same generation cancellation. PDFs → PDFKit (already). Everything else → Quick Look (fallback for the long tail). Verified live via the FIFO: .md/.tex/.json → showTextPreview, .pdf → PDFKit, .png → QL.

**Notes:** Step 2 (done same day): syntax highlighting via `bat`. `ConspectusCore.parseANSI` (pure, tested) turns `bat --color=always` output into styled `AnsiRun`s; `renderANSI` (executable) maps them to an attributed string (truecolor fg, bold/italic via font traits). `bat` is resolved once at startup via the shared `resolveOnLoginPath` (with `ya`); theme follows the palette (Catppuccin Latte/Mocha, or `$BAT_THEME`). Missing `bat` → plain monospace fallback. We ignore ANSI background so text always sits on the themed pane bg. Direction lives in the memory `project-hardening-native-previews`.

**Step 3 (done same day): images → native NSImageView.** `isImagePreviewable` (pure, tested) classifies raster extensions; `showImagePreview` loads NSImage off-thread and fits it to the pane, letterboxed in the theme bg. The four covers over the QL view (folder listing, text, image, PDF) are now managed by one `hideAllCovers()` helper — each show-path hides all then reveals its own, so exactly one shows and QL appears only when all are hidden. Result: text, images, and PDFs are all native/in-process; Quick Look (with its shield + ⌘E rebuild) now guards only the long tail (video/audio/office/fonts). The most-hovered and most crash-prone cases are off the fragile out-of-process path entirely. `CONSPECTUS_QUICKLOOK=off` disables the fallback outright (long tail shows a note; the remote extension is never spawned) for users who want zero QL surface — on by default.

## 2026-07-24 — SwiftTerm display wedge under wheel floods; repaint insurance

**Problem:** Fast mouse-wheel scrolling over the yazi pane could freeze the terminal *display*: the buffer keeps advancing (navigation works, hover events keep flowing — "navigation hat geklappt, aber die Ansicht nicht"), the app's main thread is provably idle, but SwiftTerm stops painting until something forces a redraw (a click revives it). First misattributed to the eager focus nudge — the freeze reproduced with the nudge removed.

**Solution:** Band-aid until the root cause is found in SwiftTerm (1.15.0, latest release): a 1s repeating timer in `.common` run-loop modes (so it fires during scroll gestures) sets `needsDisplay` on all terminal views — GATED on wheel activity in the last 3s (local scrollWheel event monitor stamps it), so an idle app repaints nothing and App Nap stays effective. `drawRect` renders from the current buffer, so worst-case staleness is ~1s regardless of what wedged internally.

**Notes:** If SwiftTerm ships a display-pipeline fix, drop the insurance. The `.common` mode matters: a default-mode timer pauses during event-tracking — exactly when the wedge happens.

## 2026-07-24 — Fourth QLPreviewView trap: wheel events die after mouse re-entry

> Amended the same day: the eager nudge on every `mouseEntered` was REVERTED — its resign/become churn could wedge SwiftTerm's repainting (next entry). The nudge now runs lazily in `scrollWheel`, only when a wheel event bubbles up to the view at all (which is itself the proof the remote dropped it); see the comment in `Panel+Focus.swift`.

**Problem:** Scroll the PDF preview (works), move the pointer to another pane — no click — and back: the same document is still displayed but no longer scrolls. User-discovered recovery: focusing the preview (⌘⌥→) revives it. The remote QL extension apparently stops processing forwarded wheel events once the pointer leaves, and only a first-responder change re-arms its event routing.

**Solution:** `IntentFocusPreviewView` owns a tracking area; every `mouseEntered` performs the same nudge invisibly — make the view first responder and hand the keyboard straight back to the previous responder in the same runloop turn. The focus-by-intent contract holds (no keystroke can land in the preview in between; `allowFocus` is reset immediately).

**Notes:** Diagnosed with CONSPECTUS_EVENT_LOG (scroll arrival vs. preview requests) plus the user's "focusing fixes it" observation — the nudge is that observation, automated. The launcher defaulted the event log on for the diagnosis; that block was removed 2026-10-13 (the log is opt-in again).

## 2026-07-23 — Click-to-navigate felt sluggish: a login shell per click

**Problem:** Every folder/file click in the preview listing spawned `zsh -lc "ya pub-to …"` — the login shell exists only because the app inherits no useful PATH (Spotlight/Hammerspoon launch) and must find `ya`. Measured: the shell costs ~130ms+ warm (worse cold / with a heavy zprofile), the actual `ya pub-to` broadcast ~10ms. Nothing was broken, so the ~10x overhead was silent — clicks just felt laggy.

**Solution:** Resolve `ya` once at startup (`resolveYaPath`, background login shell), cache the path, spawn `ya` directly per click with real argv (which also removed the env-var quoting detour). Shell fallback stays only for "not resolved yet / ya missing", with a warning.

**Notes:** General rule: the no-PATH problem makes `zsh -lc` tempting for any CLI call — fine for one-off/startup work (`launch()` legitimately uses a login shell for the terminal panes), never per user action. Resolve the binary once instead.

## 2026-07-22 — Quick Look wedges under churn; debounce the requests

**Problem:** Racing through hundreds of PDFs (held-down key) set `previewItem` for every intermediate file. The Quick Look service eventually wedged: the view stuck on a permanent loading spinner and never recovered on its own.

**Solution:** Debounce the QL request — the pane switches immediately, but `previewItem` is only set once the hover has settled for ~120ms (reusing the listing generation counter as the cancellation token). Scrolling through a directory now issues zero QL requests until the user stops. `lastWasDir` became `previewDirty`: the dir→file rebuild happens at request time inside the debounce, not per hover event.

**Notes:** Manual recovery for a wedged preview (should it still happen): ⌘E twice — detach + attach rebuilds the QLPreviewView from scratch.

2026-07-23 amendment — max-latency escape tried and REVERTED: the fzf `focus`→FIFO coupling (yazi `s`/`S`) fires on every top-item change while rg streams, so the debounce never settles and the preview looked frozen. First fix attempt: render anyway when the last QL request is >0.5s old. Result: main-thread stalls (watchdog reports) and a wedged PDF preview — even ~2 fresh-document requests/s is enough to back up the QL service, and `previewItem`/`refreshPreviewItem` XPC then blocks the main thread. The *actual* bug behind the frozen preview was yazi's `%s` substitution corrupting the FIFO writes (see dotfiles keymap GOTCHA); with that fixed, pure debounce is correct by design: machine-speed streams show nothing worth previewing, human dwell ≥120ms renders. Do not resurrect the escape.

## 2026-07-22 — Self-contained: bundled conspectus.yazi, no qlpeek CLI

**Problem:** The preview coupling depended on the user's dotfiles (qlpeek + panesync plugins) and the external `qlpeek` binary — a stranger cloning the repo got an app with a dead preview.

**Solution:** `plugins/conspectus.yazi` in the repo does both jobs (hover → FIFO, panesync-cd follower) and writes the FIFO **directly from Lua** — no external binary. This is safe because the app opens its FIFO O_RDWR and holds it for its lifetime, so the plugin's open-for-append never blocks. The launcher injects the plugin into the overlay config (now built in ALL modes, split included), generates init.lua (user's init first), and only sets the catppuccin theme if the flavors are installed.

**Notes:** Users with the dotfiles qlpeek plugin get double FIFO writes per hover (their plugin + bundled one). 2026-07-24: the event log disproved the old "harmless, the debounce coalesces them" claim — the second write often lands outside the 120ms window and doubled every QL request. `requestQLPreview` now drops requests for the item the uncovered preview already shows. The `[[ -e $entry ]]` guards matter: with an empty config dir, bash leaves the glob literal and a symlink named `*` lands in the overlay.

## 2026-07-22 — Dual-pane yazi: DDS ids and cd-sync

**Problem:** Fixed `YAZI_ID`s per pane broke yazi's DDS discovery; panes either didn't see each other's yanks or cd-sync looped.

**Solution:** Strip `YAZI_ID`/`YAZI_LEVEL` from the child env so each pane is a fresh instance with an auto-generated id. `CONSPECTUS_PEER` is only a flag (arms the `=` cd-sync keymap, broadcast via `ya pub-to 0`), not an id.

**Notes:** Cross-pane copy (`y`/`p`) relies on DDS auto-discovery; anything that fixes ids will silently break it. Discovery alone is NOT enough, though (2026-08-25): yank state only crosses instances with the built-in `session` plugin armed — `bin/conspectus` writes `require("session"):setup { sync_yanked = true }` into the overlay `init.lua`. Without it, `p` works across tabs (same instance) but silently does nothing in the other pane. Bonus finding: `ya pub-to 0 panesync-cd --str <dir>` also works from OUTSIDE yazi, without any YAZI_ID — conspectus uses this for click-to-cd on folder rows in the preview listing.

## 2026-07-22 — Theme following without configuring yazi directly

**Problem:** The terminal palette (Catppuccin Latte/Mocha) must follow the macOS appearance, and yazi should match — without touching the user's yazi config.

**Solution:** conspectus sets the SwiftTerm palette; yazi queries the terminal background via OSC 11 (SwiftTerm answers) and picks its flavor through the overlay `theme.toml` (`dark = catppuccin-mocha`, `light = catppuccin-latte`) that `bin/conspectus` generates under `~/.cache/conspectus/yazi-config`.

**Notes:** Needs both flavors installed (`ya pkg add yazi-rs/flavors:catppuccin-mocha` / `…-latte`). On appearance toggle the app re-themes live and re-renders the folder listing.

## 2026-07-22 — Testability split: ConspectusCore

**Problem:** All logic lived in the executable target; SwiftPM can't import an executable into a test target, so nothing was unit-testable.

**Solution:** Pure helpers (start-dir resolution, hex/palette parsing, icon mapping, listing order) moved to the `ConspectusCore` library target; `Tests/ConspectusCoreTests` covers them. The executable keeps the AppKit shell.

**Notes:** New pure logic belongs in the core, not in `main.swift` — otherwise it's untestable again. Fallbacks are returned as data (`StartDir.warning`), not printed, so the logic stays pure and the app decides how to surface them.

## 2026-08-10 — Typesetting the markdown preview (TextKit, not CSS)

**Problem:** The rendered markdown view was *styled* (serif, sizes, colors) but not *typeset*: fixed 2pt line spacing that tightened as the font grew, a thematic break made of 60 `─` characters that wrapped onto a second line in a narrow pane, blockquotes dimmed to 55% alpha (poor contrast for long quotes), straight quotes/`--`/`...` as typed, table column alignments ignored, and an unbounded measure — in a wide pane the lines ran past 150 characters.

**Solution:** All vertical measures became multiples of `base` (`CONSPECTUS_MD_FONT_SIZE`), with `lineHeightMultiple` instead of `lineSpacing`. Hyphenation is on with `.languageIdentifier` set from `NLLanguageRecognizer.dominantLanguage` per file — without it macOS hyphenates German notes by English patterns. The measure is capped in `IntentFocusTextView.maxMeasure`: the container tracks the view width, so growing `textContainerInset.width` centres the column and turns the surplus into margin (rendered markdown only — source keeps the file's own lines). Smart punctuation lives in `ConspectusCore/Typography.swift` and is applied *only* in the `Markdown.Text` case of the AST walk, so code spans and link destinations can't be mangled — the usual failure of regex-based approaches.

**Gotcha:** TextKit has no "border on a paragraph" attribute. Both the rule and the blockquote bar are `NSTextTableBlock`s with a single edge drawn — `.minY` for the rule (carrier line in a 1pt font, so only the border shows), `.minX` plus left padding for the quote bar. Measured offscreen with `NSLayoutManager`: the rule row lays out 1.0pt high, the quoted text indents to x=15 and keeps its line height. Blockquote also *amends* the inner paragraph styles (enumerate, copy, add `textBlocks`) instead of replacing them — replacing flattens the spacing and hyphenation of the quoted blocks.

**Deliberately not done:** justified text (at a ~68-character measure it opens rivers; ragged right is correct for a column), and hanging punctuation / widow
+ orphan control — TextKit has no equivalent, and the preview scrolls continuously, so there are no pages to break.

## 2026-08-17 — Hover, not selection: `o`/`Enter` and click-to-enter in the plugin

> **Superseded in part (2026-10-16):** click-to-enter was replaced by Finder's contract — a click marks, a double-click enters/opens. yazi has no double-click; the plugin counts two clicks on the same row within `CONSPECTUS_DOUBLE_CLICK` (the macOS interval, exported by the app), see `install_double_click` in `plugins/conspectus.yazi/main.lua`. The listing in the preview pane acts on the *remembered* first click, because yazi's reveal re-renders the pane before the second click lands. The wrapping technique and the hover-not-selection point below still hold.

**Problem:** Two navigation keys asked the shell `[ -d "$1" ]` whether to enter a directory. But yazi's `shell` passes the SELECTED files, falling back to the hovered one only when nothing is selected — so with a pending copy/cut, `Enter` on a folder opened the selection instead of descending. `l`/`→` had been fixed in the bundled plugin (which reads `cx.active.current.hovered`); `o`/`<Enter>` still had the bug. Separately, a mouse click on a folder row only moved the cursor there: yazi's preset `Entity:click` emits `reveal`, nothing else.

**Solution:** One plugin entry, two modes — no argument = the `l`/`→` behavior (enter a dir, else focus the preview), `open` = the `o`/`<Enter>` behavior (enter a dir, else push the file into the IDE nvim or the opener). Both ask the hovered item. Click-to-enter *wraps* the preset component rather than replacing it:

```lua
local base = Entity.click
Entity.click = function(self, event, up)
	base(self, event, up)                     -- keeps reveal + right-click open
	if not up and not event.is_middle and not event.is_right
	   and self._file and self._file.cha.is_dir then
		ya.emit("enter", {})                  -- acts on what reveal just hovered
	end
end
```

**Gotcha 1:** `ya emit plugin conspectus -- open` does NOT reach the plugin. `ya emit` already takes the action's arguments as a list, and the `--` gets eaten — `job.args[1]` arrives as `""`. Verified in a pty harness against a probe plugin: `-- open`, `-- -- open`, `"-- open"` and `--args=open` all fail, plain `ya emit plugin conspectus open` works. The keymap's *own* form (`run = "plugin conspectus -- open"`, no `ya emit`) does need the `--`.

**Gotcha 2:** the preset components are globals (`Entity`, `Current`, `Parent`) that exist by the time `init.lua` runs, so a plugin's `setup()` can wrap them — but a version that renames or moves `Entity:click` would silently disable the feature, so the wrapper checks and `ya.notify`s instead of failing quietly.

**Testing:** a pty harness (python `pty.fork` + `TIOCSWINSZ`) runs the real plugin against a scratch tree and asserts on the hover FIFO. Two details make or break it: the FIFO reader must open with `O_RDWR` (a read-only open hits EOF the moment yazi closes its write end, exactly what the app avoids by holding it open), and the pty needs a window size or yazi renders no rows and every key lands in an empty list. Mouse clicks are just SGR sequences: `\e[<0;COL;ROWM` press, `…m` release.

**Follow-up (same day) — mouse back/forward:** the side buttons cannot be bound in yazi at all: it reads mouse input through crossterm, whose `MouseButton` is left/middle/right only, so buttons 4/5 never become an event a keymap could see. AppKit does deliver them (`otherMouseDown`, `buttonNumber` 3 and 4), so the translation belongs in the app: a local monitor publishes `panesync-history` with `"<direction> <peer>"` and the plugin runs yazi's `back`/`forward`. Addressing the peer matters — a broadcast would move *both* panes in split mode, and the pane the pointer sits over is the one meant. The same actions are in the Go menu (⌘[ / ⌘]), which doubles as the fallback for mice whose driver converts the side buttons into those chords before macOS sees them. Publishing a *command* rather than typing `H`/`L` into the pane is deliberate: a synthetic keystroke would be swallowed by an open filter prompt.

**Follow-up — going up with the mouse (2026-08-20):** the column layout can only descend. The left column shows the *parent's* entries, so a click there enters a sibling directory (measured: `reveal` + `enter` in one tick lands in the clicked dir), and no click anywhere in the panes leaves the current level. The fix is the path bar every GUI file manager has: the bundled plugin wraps yazi's no-op `Header:click` and cds to the clicked segment of the cwd. Two things make the mapping non-obvious: the header renders `ya.readable_path`, so `~` stands for two real segments, and it truncates with `rtl = true`, so the *left* end is what disappears. Both are handled by counting segments **from the right** — the shown text is always a tail of the real path — and by refusing a click on a half-eaten first segment instead of guessing. `_right_width` is not available at click time (reflow builds a fresh Header, only `redraw` sets it), so the width budget is recomputed from `children_redraw(RIGHT)`. Keyboard twin: ⌘↑ (Go → Enclosing Folder) publishes `panesync-history` with direction `up`, which runs yazi's `leave` — the app never tracks a pane's cwd, so it cannot compute the parent itself.

## 2026-08-28 — Network mounts (CephFS via SMB): the preview must not touch them

**Problem:** browsing the Ceph mount (`/Volumes/storage`, SMB) beachballed the app. The preview pipeline makes synchronous filesystem calls in places that must never block: the size-cap stat and `PDFDocument(url:)` run on the main thread, the mtime watch polls `stat` on a main-thread timer every 0.7s, and `update()` runs `fileExists` on the FIFO reader thread — one stalled SMB call wedges the UI or silences every further hover. Separately, the fzf pickers in the dotfiles keymap (`s`/`S`, later also `Z`/`⌥C`) run an unbounded `fd`/`rg` walk over the cwd; on SMB every directory listing is a network round-trip, so the walk itself looks like a freeze — no preview involved.

**Solution, app side:** `CONSPECTUS_PREVIEW_SKIP_DIRS` (comma-separated dirs, prefix match on component boundaries — `ConspectusCore/DirList.swift`) plus ⌘⇧P as a session-live toggle for the folder being browsed. Under a skipped dir a *file* hover shows a static note with **zero I/O on the hover path**; a *directory* still gets the capped listing: the only filesystem touch is an "is it a dir?" probe on a dedicated **serial** queue, so a hung mount blocks that one thread at most while the note is already up and stale generations die on return. The live list is read by the FIFO thread and written by the main thread → guarded by an `NSLock` (`skipDirsStore`/`skipDirs`).

**Solution, keymap side:** all recursive pickers detect a network mount by `df -P .` device (`/dev/*`, `map*`, `devfs*` = local, anything else — SMB is `//user@host/share`, NFS `host:/path` — = network) and then cap `fd`/`rg` at `--max-depth 2`, announcing it in the fzf header. Unknown filesystems are capped too: a visible cap beats an invisible freeze. Go deeper by cd'ing deeper — the cap counts from the cwd.

**Gotchas:** ⌘⇧P re-enabling previews on a *hung* mount blocks exactly like before the skip — deliberate, it is the user's explicit call. And a truly dead mount is unfixable client-side: even `df`/`stat` hang then; only `umount -f` helps. The skip list protects the app, not the mount.

## 2026-10-24 — A symlink to a folder lists as empty (ENOTDIR)

**Problem:** `conspectus --cvs-status ~/work/areas/passwords/cvs-webis-organization` (a symlink into `~/cvsrepo`) printed nothing — no signs in yazi — while the real path printed `modified …`. `CVS/Entries` was read fine through the link; only the directory enumeration came back empty, hidden behind a `try? … ?? []`.

**Solution:** `FileManager.contentsOfDirectory(at:)` fails with POSIX 20 ("Not a directory") when the URL is a symlink built with `isDirectory: true`. `directoryURL(_:)` in `ConspectusCore/Listing.swift` resolves the link first; `loadFolder` and `readCVSStatuses` both go through it.

**Gotcha:** the `try?` with the "directory vanished" comment was honest about the race it meant but also swallowed this. A negative result ("no signs") is a claim — test it once against a file you know is modified.

## 2026-10-24 — main.swift globals initialize in order: a CLI block must not use a `let` below it

**Problem:** `conspectus --git-remote <repo>` crashed with SIGSEGV in `Dictionary.isEmpty` inside `runGitRemoteCheck`, while the no-upstream path (which returns before the fetch) worked. The function read `gitBatchEnvironment`, a top-level `let` in main.swift.

**Solution:** main.swift is a script: top-level `let`s are initialized in textual order as the file executes, and the `--git-remote` block `exit(0)`s before the lines below it ever run. A global function called from such a block may only touch globals defined *above* the block. The constant moved up next to `gitRemoteTTL`; the comment there says why.

**Gotcha:** the compiler does not warn — a global in main.swift is `static`-like storage read through an unchecked pointer, so the symptom is a null dereference at a random-looking place, not an error message. The `--cvs-remote` block only worked because its constants happen to sit above it. Rule of thumb: constants for headless CLI blocks go into the constants section at the top; functions can live anywhere.

## 2026-11-04 — sshfs under macFUSE 5 never returns

**Problem:** `sshfs host:/ mnt` (sshfs 2.x, macFUSE 5.3) mounts fine but then prints `fuse: daemonize requested after mount started; continuing in foreground` and blocks — a launcher that runs it and then starts the app hangs before the app ever opens.

**Solution:** `conspectus ssh` runs `sshfs -f … &` and polls `mount` until the mount point is listed, aborting if the sshfs process dies first. Unmounting on quit (`umount`) ends sshfs by itself.

**Gotchas:** tested without a network by pointing sshfs's `ssh` at a fake one on `PATH` that execs `/usr/libexec/sftp-server` for the `-s sftp` subsystem call — the whole mount path, locally. macFUSE prints one `MFChannelSendMessage … Socket is not connected` line at unmount; noise, not an error.

## 2026-11-04 — sudo over sshfs with a password (TRAMP's `|sudo:`)

**Problem:** sftp has no terminal, so sudo cannot ask for a password; `sudo -S` would read it from stdin, which is the sftp stream itself.

**Solution:** sshfs's `ssh_command` is the launcher again (`CONSPECTUS_SUDO_TRANSPORT`): it drops sshfs's `-s sftp`, runs a remote `sh -c` instead, and feeds the password as the first line ahead of the stream. The remote shell `read`s that one line (byte-wise from a pipe, so no sftp bytes are lost), writes an askpass helper (`exec printenv CONSPECTUS_PW`) and runs `sudo -A -u <user> -- sftp-server`, which then owns the rest of stdin. A probe first asks `LC_ALL=C sudo -n … -h` whether a password is needed at all; NOPASSWD still gets an (empty) line.

**Gotchas:** sshfs hands ssh one socket for stdin *and* stdout, and OpenSSH sets O_NONBLOCK on its stdin/stdout — a flag on the shared file description, so a `cat` reading the same socket dies with `cat: stdin: Resource temporarily unavailable` (first real run on leguin; a fake ssh without that behaviour had passed). So ssh gets fifos on both sides and two plain relays touch the socket: feeder (password line, then socket → ssh) and drain (ssh → socket). The feeder holds the socket open — when sudo refuses, ssh ends but sshfs never sees EOF and hangs — so it is killed once ssh is gone. A background job's stdin is `/dev/null` in a non-interactive bash: the feeder needs an explicit `<&3` (dup of the socket). The test fake ssh (python) now sets O_NONBLOCK like the real one; a 2.5 MB file read through the sudo mount is byte-identical.

## 2026-11-04 — Starting conspectus from its own ⌘J terminal broke yazi's config

**Problem:** `conspectus …` typed into the ⌘J terminal opened a window that closed at once. The terminal inherits the app's environment, where `YAZI_CONFIG_HOME` is the launcher's overlay (`~/.cache/conspectus/yazi-config`) — so the launcher took the overlay as the user's config, `rm -rf`'d it, and generated an `init.lua` that `dofile`s itself; yazi died at start. The running window's overlay was left broken too (any yazi restart would have hit it).

**Solution:** the launcher exports the real source as `CONSPECTUS_YAZI_SRC` and never accepts the overlay as source (fallback `~/.config/yazi` for instances started before the fix). `conspectus ssh` with a running instance now opens the mount as a tab in it (`ya pub-to 0 conspectus-open`) instead of a second window.

**Gotcha (same day):** a mount attempt that fails (sudo refusing a wrong password inside the sftp transport) leaves macFUSE's `mount_macfuse` helper alive — sometimes it only starts after sshfs has died — and the next mount on that mount point hangs for good. So the password is tried first over plain ssh (`sudo_verify`: `sftp-server -h` through the same askpass path), and after any failed mount `mount_cleanup` kills that mount point's helpers for two seconds. The test harness had a fake `pgrep` that answered every call, which hid exactly this cleanup; it now fakes only `pgrep -qx conspectus`.

## 2026-11-04 — A dead network mount still counts as mounted

**Problem:** after sleep or a network change, ceph-fuse's mount stayed in the mount table while every access failed with `Device not configured` (macFUSE's channel to the daemon gone, `MFChannelSendMessage … Socket is not connected` in its log) — or, with the cluster session dead, hung. `ceph-mount` saw the mount-table entry and said "already mounted"; `ceph-remount` killed the pid file's daemon with TERM, which a stuck one ignored, so a second ceph-fuse ran beside it.

**Solution:** "mounted" means the mount point is in the table *and* `ls` of its root finishes within a few seconds, polled with `kill -0` (no GNU `timeout` on a stock Mac). Unmounting stops every daemon whose command line names the mount point, escalating to KILL. conspectus's automount (`bin/conspectus`, `automount_ensure`) runs the same probe on every entry into a listed mount point and calls the mount command only when it fails.

**Gotchas:** a dead FUSE mount for tests is one `kill -9` away: sshfs over the fake ssh (see the sshfs entry above), killed, gives exactly the ENXIO symptom; `kill -STOP` on the fake ssh gives the hang. yazi re-lists a cwd whose mount came back by itself, and fires `cd` at start for its first directory, so the plugin needs no reload trick and no extra start hook. Under `set -e`, `x="$(for p in $pids; do kill -0 "$p" && echo "$p"; done)"` aborts the script when the *last* pid is gone (the loop's status is the failed `&&`) — use `if … then echo; fi` in the loop.

## 2026-11-05 — `mount` waits two minutes on a hung FUSE mount; the launcher asks the app instead

**Problem:** `conspectus ssh-mount` (the automount command for an sshfs host) took 2:03 to repair a hung sshfs (`kill -STOP` on the daemon), longer than automount's 120 s budget for the whole command. A trace put the time before the probe: in `is_mounted`, which was `mount | grep`. The `mount` command lists with MNT_WAIT — it statfs's every mount, and macFUSE answers for a daemon that does not after a two-minute timeout. `umount -f` alone on such a mount waits the same two minutes (`umount: pthread_cond_timeout failed; continuing with unmount`).

**Solution:** `is_mounted` asks the app: `conspectus --mount-table` prints `getfsstat(MNT_NOWAIT)` (ConspectusCore's `readMountTable`, the kernel's cached view) — instant, never touches a server. For the repair, ssh-mount sends its sshfs SIGKILL before `umount -f`; with the daemon dead the unmount takes milliseconds. Hung repair now 9 s (one 5 s probe plus the mount), killed-daemon repair 3 s.

**Gotchas:** `df`, `stat -f` and `mount` all block the same way; only MNT_NOWAIT is safe, and bash has no way to ask for it — hence the app's flag. A SIGKILLed but SIGSTOPped daemon dies at once (the kernel handles KILL on a stopped process); no polling needed before the unmount. Killing a backgrounded probe `ls` prints `Terminated: 15 ls …` from bash unless the job is `wait`ed with stderr closed.

## 2026-11-06 — The UTF-8 BOM test passed locally and failed in CI: Foundation differs between macOS versions

**Problem:** The first GitHub Actions run (macos-15, Swift 6.1.2) failed exactly one of 210 tests: `testDecodeDropsUTF8BOM` got `"\u{FEFF}ok"` instead of `"ok"`. Locally (macOS 26, Swift 6.3) the test had always passed. `decodeText` documented that the UTF-8 BOM is dropped but relied on `String(data:encoding:.utf8)` to do it — and only the newer Foundation strips it.

**Solution:** `decodeText` drops the three BOM bytes itself before the UTF-8 decode (`Sources/ConspectusCore/TextPreview.swift`). Behaviour no longer depends on which Foundation runs.

**Gotchas:** A test that passes locally proves the local toolchain, not the code — that is what the CI runner on an older image is for. When a doc comment promises something, the code under it must do it, not a library whose behaviour changed between OS releases.
