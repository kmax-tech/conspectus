# NOTES

Solved hard problems — the *why* the code can't show. Keep entries short:
problem, solution, gotcha.

## 2026-07-22 — QLPreviewView comes back blank after being hidden

**Problem:** Hovering a folder hides the `QLPreviewView`; on returning to a
file it could stay permanently blank. Its remote Quick Look extension dies
while the view is hidden, and `refreshPreviewItem()` doesn't revive it.

**Solution:** On every dir→file transition, rebuild the `QLPreviewView` from
scratch and swap it into the container; file→file keeps the fast in-place swap
(`Panel.update`).

**Notes:** Don't "optimize" the rebuild away — the blank state is not
reproducible on every machine/OS version, but it is real.

## 2026-07-22 — SIGABRT in split mode: QLPreviewView auto-closes off-window

**Problem:** With the second yazi pane open, hovering a *file* in the left
pane crashed the app (`_QLRaiseAssert` → SIGABRT in
`-[QLPreviewView setPreviewItem:]`). `addSecondPane` removes rightContainer
from the window; a `QLPreviewView` that leaves the window hierarchy closes
itself (its remote Quick Look extension is torn down), and setting
`previewItem` on a closed view is a QuickLook assertion failure. The left
yazi keeps writing hovered paths to the FIFO the whole time.

**Solution:** `update()` skips all view work while `term2 != nil` (there is
no preview pane in split mode; `lastPath` keeps tracking). `removeSecondPane()`
rebuilds the `QLPreviewView` via `rebuildPreview()` (shared with the
dir→file blank-fix path) and replays `lastPath` so the preview resumes.

**Notes:** Never reuse a `QLPreviewView` after it was hidden for long or
detached from the window — always rebuild. Folder hovers never crashed
(they go to the self-rendered listing), which is why it only hit "sometimes".

## 2026-07-22 — Triple mode: preview follows the active pane via one FIFO

**Problem:** Three panes (two yazi + preview) need the preview to follow
whichever yazi is being used — but tracking keyboard focus and switching
preview sources is fiddly and racy.

**Solution:** No focus tracking at all. Both yazi instances get the same
`QLPEEK_FIFO`; only the pane actually being navigated emits hover events, so
the last writer *is* the active pane. Layout became two independent toggles
(second pane ⌘D, preview ⌘E, preview always rightmost) instead of hardwired
modes; `split`/`triple` are just start presets.

**Notes:** Turning the second pane off while the preview is hidden re-attaches
the preview — a lone terminal pane is never left standing. The split-view
delegate (ratio-keeping resize, 300pt min) is generalized to n panes.

## 2026-07-22 — Cheat sheet parses keymap.toml with a TOML-subset scanner

**Problem:** The ⌘K cheat sheet should show the user's *real* yazi bindings,
but a full TOML dependency is overkill (and needs sign-off per the
conventions), while naive line/regex parsing breaks on the config's
triple-quoted multiline `run` strings, which contain brackets, braces, and
quotes.

**Solution:** `ConspectusCore/Keymap.swift` — a small character-level scanner
for exactly the keymap subset: `[mgr]` inline-table arrays and
`[[mgr.prepend_keymap]]` blocks, all four TOML string forms, comments,
`on`/`desc`/`run` extraction (`desc` falls back to a compacted `run`).
Everything outside the subset throws a typed `KeymapParseError`; the app
shows parse failures in the panel footer instead of swallowing them.

**Notes:** It is deliberately NOT a general TOML parser — if yazi's config
format grows beyond this subset, extend the scanner (tests in
`KeymapTests.swift` include a fixture mirroring the real config). Legacy
configs use `[manager]` instead of `[mgr]`; `loadUserKeymap` retries with
that name on `missingSection`.

## 2026-07-22 — Bottom terminal: fresh shell per open instead of cd-follow

**Problem:** A ⌘J terminal panel should open in the dir yazi is visiting.
Following yazi's cwd *live* would mean typing `cd` into a running
interactive shell — which can clobber whatever the user has half-typed, and
there is no reliable way to detect an empty prompt from outside.

**Solution:** No live follow. Each ⌘J open spawns a fresh login zsh in the
current yazi dir; close (⌘J or `exit`) kills the shell. The cwd comes from
the existing hover FIFO: every hovered path's parent *is* the directory
being listed, so `dirname(lastPath)` tracks the active pane for free (same
trick as the preview in triple mode).

**Notes:** A failed `cd` (dir vanished) prints its error into the terminal
and the shell still starts — visible, not swallowed. If persistent sessions
are ever wanted, hide instead of terminate, but then the reopen-relocates
semantics is lost.

Gotcha: NSSplitView's `setPosition`/delegate layout silently gave a
programmatically added subview **0pt height** (shell ran, prompt invisible —
a white panel in light mode). `layoutOuterPanes()` therefore sets the outer
frames explicitly on open/close/resize; never rely on `setPosition` for
runtime add/remove in the outer split.

## 2026-07-22 — Folder look-ahead at scale: bulk keys + cap; further options

**Problem:** Hovering a huge directory (tens of thousands of entries) statted
every entry individually and built a megabyte `NSAttributedString` on the
main thread — UI hitch and a transient memory spike.

**Solution:** Enumerate with
`contentsOfDirectory(at:includingPropertiesForKeys: [.isDirectoryKey])` — the
isDir bit arrives in one `getattrlistbulk` kernel pass instead of a stat per
entry. Sort *all* entries (cheap once isDir is free, keeps dirs-first correct
in huge folders), then cap only the rendering at `folderListingCap` (500)
with a visible "… and N more entries" line.

**Notes:** Loading now also runs **off the main thread with cancellation**:
every hover bumps a lock-guarded generation counter, and an in-flight load
checks it after the disk I/O (skips the string build) and again before
applying — navigating on drops stale work instead of racing it out of
order. The previous listing stays visible until the new one lands
(Finder-style, no white flash). Options if the cap ever hurts (kept for the
future): (1) virtualized `NSTableView` with a lazy data source — only
visible rows materialize, scrollable through 100k entries at constant
memory (how Finder does it; would replace the capped `NSTextView`);
(2) per-directory cache keyed on path + mtime for instant re-hovers.

## 2026-07-22 — Keyboard focus: by intent only, visible, restored

**Problem:** After switching to an editor launched out of yazi (E c →
VS Code) and back, hjkl/arrows went dead while mouse-wheel scrolling kept
working — the QLPreviewView had silently become first responder (scroll
events need no key focus, key events do). Yet a *deliberately* focused
preview is useful: Quick Look natively takes arrows/PgUp/Space.

**Solution:** Three pieces. (1) `IntentFocusPreviewView.allowFocus` — the
preview refuses first-responder status except during the explicit ⌘⌥→
command; KVO on `window.firstResponder` revokes the permission when focus
moves away. (2) `applicationDidBecomeActive` restores the last-focused
terminal if reactivation left focus on a non-terminal. (3) A subtle gray
border (fg at 25% alpha) marks the focused pane, shown only when more than
one focusable pane exists.

**Notes:** The KVO observation is the single source of truth for border
updates — mouse clicks change first responder without any of our code
running, so per-call-site updates would miss them. `updateTitle()` also
repaints borders because attach/detach changes the target set without a
first-responder change.

## 2026-07-22 — FIFO per instance; reader opens O_RDWR (wedged-open bug)

**Problem:** All instances shared `~/.cache/conspectus/target`. Any new
launch (second window, headless test run) unlinked and recreated it — and a
running instance whose reader was blocked in `fopen("r")` (which waits for a
writer) stayed blocked on the orphaned inode *forever*: previews silently
stopped updating for keyboard and mouse alike, with no error anywhere.

**Solution:** The FIFO is `target-<pid>` — one per instance, handed to that
instance's yazi children via QLPEEK_FIFO; startup removes FIFOs of dead
pids (and the legacy shared `target`). The reader now opens with `O_RDWR`:
opening a FIFO read-write never blocks waiting for a writer and never sees
EOF between writers, so the wedged-open state cannot occur at all.

**Notes:** If previews ever stop updating again, check `ls
~/.cache/conspectus/` and the reader thread first — this failure mode is
silent by nature. Multiple conspectus windows are now safe to run at once.

## 2026-07-22 — Quick Look wedges under churn; debounce the requests

**Problem:** Racing through hundreds of PDFs (held-down key) set
`previewItem` for every intermediate file. The Quick Look service
eventually wedged: the view stuck on a permanent loading spinner and never
recovered on its own.

**Solution:** Debounce the QL request — the pane switches immediately, but
`previewItem` is only set once the hover has settled for ~120ms (reusing
the listing generation counter as the cancellation token). Scrolling
through a directory now issues zero QL requests until the user stops.
`lastWasDir` became `previewDirty`: the dir→file rebuild happens at
request time inside the debounce, not per hover event.

**Notes:** Manual recovery for a wedged preview (should it still happen):
⌘E twice — detach + attach rebuilds the QLPreviewView from scratch.

## 2026-07-22 — Dual-pane yazi: DDS ids and cd-sync

**Problem:** Fixed `YAZI_ID`s per pane broke yazi's DDS discovery; panes
either didn't see each other's yanks or cd-sync looped.

**Solution:** Strip `YAZI_ID`/`YAZI_LEVEL` from the child env so each pane is
a fresh instance with an auto-generated id. `CONSPECTUS_PEER` is only a flag
(arms the `=` cd-sync keymap, broadcast via `ya pub-to 0`), not an id.

**Notes:** Cross-pane copy (`y`/`p`) relies on DDS auto-discovery; anything
that fixes ids will silently break it.

## 2026-07-22 — Theme following without configuring yazi directly

**Problem:** The terminal palette (Catppuccin Latte/Mocha) must follow the
macOS appearance, and yazi should match — without touching the user's yazi
config.

**Solution:** conspectus sets the SwiftTerm palette; yazi queries the terminal
background via OSC 11 (SwiftTerm answers) and picks its flavor through the
overlay `theme.toml` (`dark = catppuccin-mocha`, `light = catppuccin-latte`)
that `bin/conspectus` generates under `~/.cache/conspectus/yazi-config`.

**Notes:** Needs both flavors installed (`ya pkg add
yazi-rs/flavors:catppuccin-mocha` / `…-latte`). On appearance toggle the app
re-themes live and re-renders the folder listing.

## 2026-07-22 — Testability split: ConspectusCore

**Problem:** All logic lived in the executable target; SwiftPM can't import an
executable into a test target, so nothing was unit-testable.

**Solution:** Pure helpers (start-dir resolution, hex/palette parsing, icon
mapping, listing order) moved to the `ConspectusCore` library target;
`Tests/ConspectusCoreTests` covers them. The executable keeps the AppKit shell.

**Notes:** New pure logic belongs in the core, not in `main.swift` — otherwise
it's untestable again. Fallbacks are returned as data (`StartDir.warning`),
not printed, so the logic stays pure and the app decides how to surface them.
