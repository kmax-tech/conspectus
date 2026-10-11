# conspectus

**The best of both worlds, glued by a minimal Swift wrapper:** [yazi's](https://yazi-rs.github.io/)
fast, fully customizable keyboard navigation — your config, your keybindings,
your plugins — combined with **macOS-native previews** in full Quick Look
fidelity (PDF, video, .ai, .psd, rendered Markdown and highlighted code via QL
extensions, …).

Terminal file managers navigate better than Finder ever will; Finder previews
better than any terminal ever will. conspectus refuses to choose: a split
window with yazi in an embedded terminal on the left and a live Quick Look
pane on the right, driven by whatever you hover. The Swift wrapper stays
deliberately minimal — it owns the window, the preview, and the glue, and
leaves everything about *navigation* to yazi.

This is the "integrated window" sibling of [`qlpeek`](../qlpeek), which docks a
Quick Look panel next to your existing terminal instead of embedding one.

## conspectus and perlege

Reading in an IDE means a second *tab*, and a tab is a workspace slot competing
with your code — it gets overlaid the moment you open anything else, and PDFs
never fit it at all. Both conspectus and [perlege](../pdf-highlighter) exist to
give a document a fixed place instead of a slot. They split by **where what you
read stays**:

- **conspectus keeps nothing in the document, everything in the note.** Cycle
  files in yazi, each one previews instantly, and in [IDE mode](#ide-mode-conspectus-ide)
  nvim sits between the two: PDF right, its note in the middle, ⌘N pins the
  keepers. Because there is no document state to maintain, a file you discard
  costs nothing — that is what makes the loop fast.
- **perlege keeps things in the document**: highlights, reading position and the
  SyncTeX mapping, anchored to the content hash so they survive renames, copies
  and library symlinks.

Rule of thumb: as long as the result of your reading lands in the *note*, stay
here; the moment it should stay in the *document* — highlight it, find it again,
keep the position — hand it over with **`E p`**. Both resolve a PDF's companion
note the same way, so they always agree on which `<stem>.md` belongs to it.
Deliberately not built here: reading position, highlights, in-document search —
every piece of document state slows down the loop this app is for.

## How it works

Code layout: `Sources/ConspectusCore` holds the pure, unit-tested helpers
(start-dir resolution, palettes, icon mapping, listing order);
`Sources/conspectus` is the AppKit shell around them. Conventions live in
`CLAUDE.md`, solved gotchas in `NOTES.md`.

- Left pane: [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) hosting a
  login shell that `exec`s the file manager.
- Right pane: a universal preview that swaps by hovered item type —
  - **File** → `QLPreviewView` (embeddable Quick Look, same generators as Finder).
  - **Folder** → a rendered contents listing (folders first, natural sort, Nerd
    Font glyphs, Catppuccin colors). Quick Look on a folder only shows its icon +
    metadata, so we render the look-ahead ourselves. **Clicking a row hands
    the path to yazi**: a folder is entered (`cd`), a file is revealed (the
    cursor moves onto it) — which fires a hover and previews it, the same way
    keyboard navigation does. Mimics yazi's own third column.
- Because the right pane previews files *and* folders, yazi runs at 2 columns
  (its own 3rd preview column is hidden via the overlay `yazi.toml`). You
  navigate in the middle column and enter directories to descend.
- **Clicking works the same way inside the yazi pane**: a left click on a
  folder row enters it, exactly like `Enter`. Stock yazi only moves the cursor
  there; the bundled plugin wraps yazi's `Entity:click` to add the `enter`
  (right-click keeps its stock "reveal + open"). The flip side: a click meant
  only to focus a pane also descends when it lands on a folder row.
- **Going up is the path bar**: the cwd in a pane's header is a breadcrumb —
  click any segment to `cd` to that level, several levels in one click. The
  columns themselves only ever descend (the left column holds the *parent's*
  entries, so clicking there enters a sibling), which is why the mouse needs
  the header. `⌘↑` (Go → Enclosing Folder) is the keyboard twin for one level.
- **Out to Finder**: `⌥⌘R` (Go → Reveal in Finder) acts on the hovered item —
  a folder opens, a file is revealed in its parent and selected. It is a menu
  shortcut, so it works from every pane, including nvim and the preview, where
  yazi's own binding cannot be typed. ⌥⌘R is VS Code's key for the same
  command; in a bare terminal yazi the keyboard twin is `E f` (dotfiles
  `keybindings.md`).
- Coupling: the app creates a FIFO (one per instance,
  `~/.cache/conspectus/target-<pid>`) and hands its path to the shell via
  `QLPEEK_FIFO`. The file manager writes the hovered path there on selection;
  the app swaps the preview in place. For yazi this is the `qlpeek send` plugin
  (honours `QLPEEK_FIFO`) and follow mode auto-enables inside conspectus.

Any other TUI can drive the preview by writing an absolute path to
`$QLPEEK_FIFO` when its cursor moves.

## Requirements & works best with

**Required:** macOS 13+, [yazi](https://yazi-rs.github.io/) (the bundled
plugin is injected automatically — a machine with no yazi config works),
Swift toolchain to build.

**Optional, but the preview shines with them:**

- **Quick Look extensions** — conspectus shows whatever Quick Look can
  render, so extensions upgrade it directly:
  [QLMarkdown](https://github.com/sbarex/QLMarkdown) (rendered Markdown) and
  [Syntax Highlight](https://github.com/sbarex/SourceCodeSyntaxHighlight)
  (highlighted source code): `brew install --cask qlmarkdown syntax-highlight`.
  Without them, code and Markdown fall back to plain text.
- **A Nerd Font** (e.g. `brew install --cask font-jetbrains-mono-nerd-font`)
  for yazi's file icons and the folder listing glyphs — otherwise you get
  tofu boxes.
- **Catppuccin yazi flavors** (`ya pkg add yazi-rs/flavors:catppuccin-mocha`
  and `…:catppuccin-latte`) so yazi follows the light/dark theme with the
  panel; without them your own yazi theme is kept.

## Build & run

```sh
./build.sh             # swift build -c release (first run fetches SwiftTerm)
swift test             # unit tests for the pure helpers (ConspectusCore)
conspectus             # yazi + Quick Look preview, starting at $HOME
conspectus ~/work      # start at a given directory (tilde/relative resolved)
conspectus ~/work/paper.pdf   # a FILE: start in its dir, cursor on the file
conspectus split       # two yazi panes side by side (dual-pane copy)
conspectus split ~/work
conspectus triple      # two yazi panes + Quick Look preview (3 panes)
conspectus ide         # yazi | nvim | preview — a small IDE (see below)
./install-app.sh       # assemble /Applications/Conspectus.app (Finder/Dock icon)
```

Start dir is `$HOME` unless a `[path]` is given. A `[path]` that is a *file*
starts in the file's directory with the cursor on it, so the Quick Look pane
previews it immediately — this is what indago's `M-o` ("open in conspectus")
uses. The TUI is yazi; override with the `CONSPECTUS_CMD` env var (e.g.
`CONSPECTUS_CMD=lf conspectus`).

**yazi columns:** preview modes run yazi at 2 columns by default (its own
preview column hidden — the Quick Look pane is the preview).
`CONSPECTUS_COLUMNS=3 conspectus` keeps your full 3-column config instead:
yazi's look-ahead column *plus* the Quick Look pane. Split mode always uses
your full config.

## Dual-pane split

Two **yazi panes** instead of terminal + preview — an orthodox (Norton/Total
Commander) layout. Each pane is a separate yazi instance; they share yanked files
via yazi's DDS, so **`y` in one pane, `p` in the other copies between them**.
Focus a pane by clicking it.

The layout is two independent toggles — the second yazi pane (**⌘D** or the
titlebar **`Split` button**) and the preview pane (**⌘E**, always rightmost):

| second pane | preview | layout |
|---|---|---|
| off | on | yazi + preview (default) |
| on | off | two yazi panes (`conspectus split`) |
| on | on | two yazi panes + preview (`conspectus triple`) |

Toggling the second pane off with the preview hidden brings the preview back
(a lone terminal defeats the app's purpose).

## IDE mode (`conspectus ide`)

Three columns — **yazi | nvim | preview** — turn conspectus into a small IDE:
pick files on the left, edit in the middle, watch them render on the right.

Start it with `conspectus ide`, or toggle the editor pane on/off at any time
with **⌘I** (from a plain `conspectus` — no restart needed to try it). Quitting
nvim (`:qa`) collapses the pane; ⌘I brings it back.

The middle pane runs **one** nvim as an RPC server (`nvim --listen <socket>`).
Each yazi pane is handed that socket as `$CONSPECTUS_NVIM`, so **`o` / `Enter`
on a file sends it to that nvim** (`nvim --server … --remote`) as a buffer
instead of launching a new editor. Binary files (PDF, images) are not sent
there but go to yazi's normal opener. Select several files and they all pile up in
the same nvim; in a split you can drive it from either yazi pane — there is only
ever one editor. (`l` / `→` still peeks at a file in the preview; `o` / `Enter`
edits it.) The mechanism mirrors the preview FIFO: conspectus owns the channel
and hands its address to yazi.

**The preview follows the editor** while the nvim pane is focused: focusing it
(or switching buffers inside nvim) shows the file nvim currently has open, and
saving re-renders it live (mtime poll — survives even a `latexmk` rebuild). Move
focus back to yazi and the preview follows yazi's hover again. (conspectus asks
nvim over its RPC socket on focus-in, and nvim pushes its active file on
`BufEnter` via the same opt-in helper — see the dotfiles
`plugins/smart-splits.lua`.) **⌘P** still pins a file explicitly, overriding the
follow. Quitting nvim (`:qa`) collapses the editor pane; **⌘I** re-adds it. Needs
`nvim` (0.7+ for `--remote`) on the login-shell PATH.

**PDF notes (perlege's lookup, integrated):** when a PDF previews, conspectus
resolves its companion note `<stem>.md` — first next to the PDF, then in
subfolders below it (3 levels deep, hidden dirs skipped), then at the symlink
target's real location, finally flat in the central notes dirs
(`CONSPECTUS_NOTES_DIRS`, comma-separated, default `~/work/library/notes` —
the same order perlege uses, so both tools always find the same note). With
the editor pane open, an **existing note opens in nvim automatically** as you
cycle through PDFs: PDF right, note in the middle, no keystroke needed — and
while you edit the note, the preview deliberately keeps showing the PDF
instead of following the editor. So the buffer list doesn't grow by one per
hovered PDF, the previously auto-followed note buffer is **closed again**
once the next one opens — but only if it is unmodified, not visible in a
window, and not pinned; unsaved changes always keep their buffer. A
deliberate open — 📝 toolbar button, `n` on the focused PDF pane, or **⌘N**
from anywhere — **pins** the note's buffer, so collecting notes is just
cycling + ⌘N on every keeper: each pinned note stays in the buffer list
while the rest clean up after themselves. On an already-pinned note the
same button/key **unpins** (a toggle, like ⌘P on the preview) — so the
click that bootstraps the first note doesn't pin it forever. The pin lives **in nvim** as
`b:conspectus_pinned` (single source of truth): `:ConspectusPin` /
`:ConspectusUnpin` toggle it from inside nvim (`:bd` also releases it), the
PDF bar shows a pin icon for the hovered PDF's note, and a bufferline can
render pinned notes with a ★ via the buffer variable (see the dotfiles
`plugins/bufferline.lua` for the three-line `name_formatter`). (⌘N on an
auto-followed note keeps the keyboard where it is; opening/creating a note
not yet in nvim focuses the editor.) The 📝 **toolbar button** (or **`n`** with
the PDF pane focused) opens the note explicitly, creating it as `<stem>.md`
**next to the PDF** if none exists (never in the central library; the file
materializes on nvim's first save) — the editor pane is added automatically
if it isn't open.

**Split handoff (smart-splits):** ⌥←/→/↑/↓ inside the editor move between
**nvim's own splits** first; only at nvim's edge do they hand off to the
neighbouring conspectus pane (yazi / preview / terminal) — one set of keys for
both, like smart-splits across WezTerm/kitty. conspectus drives it over nvim's
RPC socket (it asks nvim to move and only steps in on "edge"), so it never
depends on how the terminal encodes ⌥-arrows. This needs a tiny opt-in helper
in your nvim config — a global `conspectus_move(dir)` that calls
`smart-splits` and reports `moved`/`edge` (see the dotfiles
`plugins/smart-splits.lua`). Without it, ⌥-arrows just move panes as usual.

### Focus

**⌥← / ⌥→** (or **⌥[ / ⌥]**, HHKB-friendly — no arrow keys) cycle the
keyboard horizontally (left terminal ⇄ second terminal ⇄ preview), **⌥↑ /
⌥↓** vertically between the pane area and the terminal panel — the same
plain-Alt-arrow convention as kitty, WezTerm, and smart-splits in the
dotfiles (`keybindings.md`); ⌘⌥-arrows remain as silent aliases. Trade-off
(same as kitty): ⌥-arrows no longer reach the shell as word jumps —
`M-b`/`M-f` and `C-a`/`C-e` still do. **Clicking** a pane focuses it too.
A focused pane shows a subtle gray border (only when more than one
focusable pane exists). The mouse can also *navigate*: a left click on a
folder row enters that folder, and the **side buttons** (or **⌘[ / ⌘]** in the
Go menu) step back and forward through that pane's directory history — enough
to browse a tree without touching the keyboard. **⌘⌃→ / ⌘⌃←** widen / narrow the focused pane
(WezTerm-style keyboard resize, 60 pt/step; the divider stays draggable and
no pane can collapse below its minimum). The preview is **focus-by-intent**: a
focused Quick Look scrolls with the arrow keys / PgUp / PgDn and pages PDFs
(or plays videos) with Space — but clicks and app switches can never move
the keyboard into it, so hjkl in yazi always keep working; coming back from
an editor launched out of yazi restores focus to the last terminal.

**Right-click** opens Finder's file menu for the item under the mouse — in a
yazi pane (the row you clicked), on a row of the folder listing, or on the
preview (the previewed file): **Open** (a folder is entered in yazi, a file
opens in its default app), **Open With** (LaunchServices' list, the same one
Finder shows, default app first, plus Other…), **Reveal in Finder** / **Open in
Finder**, **Get Info** (Finder's info window, via Apple Events — macOS asks
once for Automation permission), **Share**, **Services** (incl. Quick Actions
that take files), **Copy Path** / **Copy Name**, and **Rename…** / **Move to
Trash**. The last two run *inside yazi* (`rename` / `remove --hovered` on the
clicked item, never on a selection you left elsewhere), so there is one task
system and one confirmation. In a yazi pane the right-click first moves yazi's
cursor onto the row, like a left click, then opens the menu for the file yazi
reports as hovered. Not offered (yet): Tags, Compress, Duplicate, Make Alias.

**Selecting text:** click into the preview to focus it, then drag to select
and **⌘C** to copy — in the PDF view and in the text/markdown preview alike
(**⌘A** selects all). ⌘C / ⌘V also copy/paste in the terminal panes.

## Bottom terminal (⌘J)

**⌘J** toggles a terminal panel below the panes: a fresh interactive login
zsh started **in the directory yazi is currently visiting** (derived from
the hover events; in split mode that's the active pane) — for quick
`git`/`cvs`/one-off commands next to the file manager. Deliberately no live
cd-follow: closing (⌘J, **⌘W**, or `exit`) kills the shell, reopening starts
a new one at yazi's current location. ⌘W only ever closes the panel — with
the panel closed it does nothing (the "close tab" habit stays safe). The divider is draggable (min 120pt panel,
min 300pt pane area).

## Shortcut bar

A slim status bar at the bottom shows the most-used shortcuts until the muscle
memory sits — yazi's defaults plus conspectus's own keys, led by the tip of the
day:

    💡 , s folder sizes   ·   y→p copy   x→p move   d trash   r rename   a new
    cc path   cf name   ␣ select   / find   w tasks   ⌘L selected   ⌘D split

`y→p` = yank then paste (copies across panes in split mode); `cc`/`cf`/`cn`
copy the full path / filename / name without extension to the clipboard;
`w` opens yazi's task manager (background copies, deletions, size sums — and
why a yazi re-theme may wait). Toggle the bar with **⌘/** (or View → Toggle
Shortcut Bar) — the choice persists across launches.

**Yank mirror.** While yazi's yank buffer is non-empty, the bar's front slot
shows it instead of the tip — `⧉ 1 copied · main.lua — p paste · Y cancel` —
green for copied, red for cut, matching yazi's own count badge. Yazi shows
which files are yanked only inside their source directory; the bar keeps the
answer visible wherever you navigate. The bundled plugin announces every
change over the preview FIFO (`@YANK:` message); clearing the buffer (`Y`/`X`,
or pasting after a cut) brings the tip back.

**Selection list (⌘L).** Yazi's *selection* (Space / `v` marks, the yellow
badge) has no such live mirror — yazi publishes no event for it, so it can
only be pulled on demand: **⌘L** (View → Show Yazi Selection in Preview) asks
the focused pane's plugin over the DDS (`panesync-selected`) and shows the
answer in the preview pane as a clickable list in the folder-listing style —
icon and name per row, the parent directory dimmed behind it, since a
selection spans directories. Clicking a row reveals that file in yazi (a
directory row cds there). The list is a peek, not a mode: the next hover
replaces it.

**Tip of the day** rotates through a curated pool of yazi and conspectus keys
(`ConspectusCore/Tips.swift`), one per calendar day, deterministic — the same
day always shows the same tip, and it flips at local midnight. It sits first in
the bar because the bar truncates at the tail on narrow windows. A session left
running past midnight keeps the old tip until the bar is re-rendered (⌘R, an
appearance switch, or a relaunch); the ⌘K panel re-reads it on every open.

**⌘K** opens the full cheat sheet — the day's tip in full at the top (the
sentence the bar has no room for), then a native, scrollable panel with yazi's
complete default keymap, grouped (navigate / select / files / clipboard /
find / tabs / sort & inspect) plus the conspectus keys — the readable version of yazi's `~`
help. Your own `keymap.toml` (`$YAZI_CONFIG_HOME`, else `~/.config/yazi`) is
parsed on every open and shown as its own group on top, so config edits
appear on the next ⌘K; parse problems are reported in the panel footer. Your
bindings win: a default line for a key you rebound drops out instead of
contradicting your group (a line listing alternatives, `o / Enter`, goes only
when you rebound all of them). The parser covers the keymap subset of TOML
(inline-table arrays and `[[mgr.prepend_keymap]]` blocks) — no TOML
dependency.

A **filter field** sits on top of the sheet: type and the list shrinks to the
matching lines, matches highlighted, the footer counting them (`3 of 240
shortcuts match "indago"`). It matches keys and descriptions alike, ignoring
case and accents; continuation lines stay with the entry they explain, and a
matching group title (`clipboard`) keeps its whole block. The tip of the day
steps aside while a filter is active. **Esc** clears the filter and hands the
keyboard back to yazi with the sheet still open; ⌘K closes it. The field is
the only part of the panel that takes the keyboard — clicking the list or
scrolling leaves yazi in charge (`becomesKeyOnlyIfNeeded`).

### Triple mode: preview follows the active pane

In triple mode both yazi instances write hovered paths to the **same FIFO**.
Only the pane you are navigating emits hover events, so the preview follows
the active instance automatically — no focus tracking involved. Note that
`conspectus split` starts each pane with its full 3-column config, while
`conspectus triple` applies the 2-column preview overlay to both panes.

## Status / limits

- SwiftTerm is not kitty: no kitty graphics protocol, so yazi's *own* image
  preview column won't render images inside conspectus — but that's what the Quick
  Look pane is for. yazi's 3rd column is kept anyway, because it also does
  **directory look-ahead** (contents of the hovered folder), which Quick Look
  does not replace. Quick Look is additive: full fidelity for files on the
  right, yazi's column for look-ahead + text/simple previews.
- The launcher builds an overlay config under `~/.cache/conspectus/yazi-config`
  and points `YAZI_CONFIG_HOME` at it: your live config is symlinked in, the
  **bundled `plugins/conspectus.yazi`** is injected, and `init.lua` is
  generated to load your own init first. That plugin is the yazi-side half of
  conspectus: it pushes hovers into the FIFO, follows the app's `panesync-*`
  messages (row clicks, back/forward, the theme restart), keeps the tab session,
  decides `l` / `o` / `Enter` from the *hovered* entry, and makes a left click
  on a folder row enter it. Your
  normal yazi is untouched — and a machine with **no yazi config at all**
  works too (yazi defaults + the bundled plugin). `theme.toml` switches to the
  catppuccin flavors only if they are installed; otherwise your own theme (or
  yazi's default) is kept.
- Font: JetBrainsMono Nerd Font Mono by default; override with `CONSPECTUS_FONT` /
  `CONSPECTUS_FONT_SIZE`.
- Split ratio: the preview keeps **a third** of the width, the terminal panes
  share the remaining two thirds — at every pane count, so toggling ⌘D/⌘E does
  not resize the preview behind your back. `CONSPECTUS_SPLIT` is the terminals'
  combined share as a fraction (default `0.667`; `0.5` gives the preview half,
  `0.75` favours yazi); clamped to 0.25…0.75. The divider is still draggable,
  and the ratio scales when you resize the window.
- Mouse back / forward: the side buttons (4 and 5) walk the **directory
  history** of the pane under the pointer — together with click-to-enter that
  makes the mouse alone enough to browse a tree. yazi cannot see those buttons
  itself (crossterm reports left/middle/right only), so conspectus translates
  them into yazi's own `back`/`forward` over the DDS. The same two commands sit
  in the **Go menu as ⌘[ / ⌘]** — the keyboard twins, and the fallback for mice
  whose driver already turns the side buttons into those chords.
  `CONSPECTUS_MOUSE_HISTORY=off` leaves the buttons to the driver; the menu
  keys stay either way.
- Live refresh: the previewed file's mtime is polled (~0.7 s) while a file
  preview is showing, so editing a note in `nvim` (left pane, `E t`) and saving
  updates the preview (right) on the fly. Polling (not an fd watch) on purpose:
  it survives a rebuild that deletes/recreates/moves the file — e.g. `latexmk`
  producing a PDF — where the file briefly vanishes and an inode-bound watch
  would be lost. Gated to an active file preview, so it stops when browsing
  dirs / idle. `CONSPECTUS_WATCH=off` disables it.
- Pin the preview (**⌘P**): holds the current file in the preview and ignores
  hover events, so it stays on the file you are editing while the yazi pane(s)
  navigate elsewhere — pin it, open it in Neovide/nvim, and watch it re-render
  on every save (esp. useful in `triple` mode, where the preview otherwise
  follows whichever yazi pane you last moved in). A yellow border marks the
  pinned state; ⌘P again unpins. Only a file can be pinned (not a directory).
- Print the previewed file (**⌥⌘P**, File ▸ Print Previewed File…): opens the
  normal macOS print dialog (printer, copies, page range, duplex, *Save as
  PDF*) for whatever the preview is showing — the hovered file, or the pinned
  one. It prints conspectus' *own* renderings, so what comes out matches the
  pane: a **PDF** page-for-page (PDFKit, scaled down to fit if the page is
  larger than the paper), an **image** fitted to one page, **text/source**
  paginated as plain monospace, and a **markdown note** typeset exactly like
  the rendered view when that mode is on (`M` / the eye toggle) — source when
  it is off. Always in the light palette on white paper, regardless of the
  system appearance, and without `bat`'s screen colors: a dark-theme page is
  unreadable in print. Types with no native rendering (video, archives,
  Office files) refuse with a sheet instead of printing something wrong —
  print those from an app that knows the format. Works with the preview pane
  closed (⌘E) too, since the hovered path is tracked either way. ⌥⌘P and not
  ⌘P because ⌘P pins the preview and ⌘⇧P is the per-folder preview switch.
- Event diagnosis (off by default): `CONSPECTUS_EVENT_LOG=<path>` appends a line
  per preview request and per scroll event reaching the Quick Look view — for
  debugging a preview that stops reacting.
- Preview size cap: files above `CONSPECTUS_PREVIEW_MAX_MB` (default 50) show a
  short "too large" note instead of previewing — a several-hundred-MB JSON
  would otherwise wedge Quick Look and spike memory. `0` disables the cap.
- Preview off per location: under the directories in
  `CONSPECTUS_PREVIEW_SKIP_DIRS` (comma-separated, e.g.
  `CONSPECTUS_PREVIEW_SKIP_DIRS=/Volumes/ceph`) **files are not previewed** —
  no size stat, no read, no mtime watch; a short note shows instead, with
  zero I/O on the hover path. For network mounts (CephFS behind SMB/NFS,
  sshfs), where a single blocking filesystem call on a stalled server would
  beachball the app. **Folder listings stay on** (capped at 500 entries, like
  everywhere): a lone "is it a dir?" probe runs on its own serial queue, so a
  hung mount blocks only that probe while the note stays and the app keeps
  running. Matching is by path prefix on component boundaries
  (`/Volumes/ceph` covers `/Volumes/ceph/x`, not `/Volumes/cephalon`); yazi
  itself still browses the mount normally.
  **⌘⇧P toggles this live** for the folder currently browsed (and thereby its
  whole subtree): previews off where they hang, or back on inside a skipped
  mount — removing whichever entry covered the folder, session-only (the env
  var stays the persistent seed). Turning previews back on on a truly hung
  mount blocks exactly like before the skip — that's the explicit ask.
- Text/source/notes/config (`.md`, `.tex`, `.py`, `.json`, …) preview in a
  **native in-process `NSTextView`** — off Quick Look and the third-party
  sbarex QL plugins entirely, which takes the common and most crash-prone
  case (markdown → WebKit) off the fragile remote path. **Syntax-highlighted
  via `bat`** (its ANSI parsed to an attributed string, Catppuccin theme
  matching the app's light/dark palette); falls back to plain monospace if
  `bat` isn't installed.
- Markdown previews **rendered** by default — a native document view
  (swift-markdown → themed `NSAttributedString`: proportional serif, sized
  headings, inline-code chips, real tables via `NSTextTable`, lists,
  blockquotes, links) — or as highlighted **source** (`bat`). A toolbar
  **eye / `</>` toggle** flips it (like the Claude viewer); so does **`M`**
  from any yazi pane or the focused preview. `CONSPECTUS_MD_MODE=render|source`
  sets the default. All in-process, no WebKit.
- The rendered view is typeset, not just styled: the **measure is capped**
  (`CONSPECTUS_MD_MEASURE`, default 68 characters, `0` = off) and the column
  centred, prose **hyphenates in the document's own language** (detected per
  file, so German notes don't break by English patterns) with proportional
  line height, and plain text gets **real typography** — „…“ / “…” by
  language, – and — for dashes, … for ellipses. Code spans, links and source
  view stay verbatim. Tables honour the column alignment (`|---:|`) and set
  figures in tabular (fixed-width) digits. Everything scales off
  `CONSPECTUS_MD_FONT_SIZE` (default 16), including the spacing.
- Images (`.png`, `.jpg`, `.gif`, `.heic`, …) preview in a native
  `NSImageView`, fit-to-pane, letterboxed in the theme background.
- Only the long tail (video, audio, office, fonts, …) still uses Quick Look —
  text, images, and PDFs are all native, in-process, off the fragile path.
  `CONSPECTUS_QUICKLOOK=off` disables even that: the long tail shows a "no
  native preview" note and Quick Look's out-of-process extension is never
  spawned at all — maximum stability, no long-tail previews. On by default.
- PDFs preview in a native PDFKit view ("perlege light"), **page-wise** by
  default — the mouse wheel flips pages. Focus the pane (⌥→) and perlege's
  keys work: `J`/`]`/Space next page, `K`/`[` previous, `+`/`-` zoom, `f` fit,
  `s` toggles single ↔ continuous. `CONSPECTUS_PDF_MODE=continuous` starts in
  continuous scrolling; `CONSPECTUS_PDF_MODE=ql` routes PDFs through Quick
  Look again (escape hatch). All other file types keep using Quick Look.
- Theme: follows the macOS system appearance — Catppuccin Latte in light mode,
  Mocha in dark, re-themed live on toggle. The terminal palette is set by
  conspectus; yazi picks the matching flavor by querying our background (OSC 11)
  via the overlay `theme.toml` (`dark = catppuccin-mocha`, `light =
  catppuccin-latte`). Needs both flavors installed
  (`ya pkg add yazi-rs/flavors:catppuccin-mocha`). yazi queries the
  background **only at startup**, so a light↔dark switch cannot re-colour a
  running yazi — conspectus therefore **relaunches the yazi pane(s) in
  place** on every appearance switch (cwd and tabs preserved, preview/nvim
  untouched); **⌘R** forces the same relaunch by hand. Graceful by design:
  the relaunch waits until a pane is idle — the bundled plugin refuses while
  file tasks (copy/move) run or files are selected (a relaunch would lose the
  selection; the yank buffer survives via the session plugin), the shortcut
  bar says what it is waiting for (`🎨 yazi re-theme waits for file tasks`),
  and the app re-asks every 5 s. After 15 min of a busy pane it stops and
  leaves a ⌘R note in the bar. The first refusal is also shown in yazi.
- Tab session: the yazi **tabs survive** ⌘R *and* a full app restart — the
  bundled plugin snapshots every tab's dir plus the active tab on each `cd`
  (`~/.cache/conspectus/tabs-L|R`, per pane side) and reopens them on the
  next bare start. Starting with an explicit `[path]` deliberately does NOT
  restore (begin *here*, clean); the snapshot keeps being written, so the
  tabs come back on the next bare start.
- Tab keys: **⌘⇧[ / ⌘⇧]** cycle the active pane's tabs and **⌘1…⌘9** jump to
  one — the same chords kitty and WezTerm use for their tabs (dotfiles
  `keybindings.md`). They exist for the moments a yazi pane does *not* hold
  the keyboard: from nvim, the preview, or the terminal panel, yazi's own
  `[` / `]` / `1…9` never arrive. Like back/forward, they travel as DDS
  commands, so an open filter prompt receives no stray keystroke. Creating
  and closing tabs stays yazi's (`t`, `close`) — and ⌘W stays the safe
  "close terminal panel".
- Open-from-shell: a running instance can be told to show a directory —
  `ya pub-to 0 conspectus-open --str /abs/dir` switches the left yazi pane to
  the tab already at that dir, else opens a new tab there (browser-tab
  semantics), and brings the window to the front. Meant to be wrapped in a
  tiny shell function, e.g. in zsh:

  ```zsh
  con() {
    if pgrep -qx conspectus; then
      ya pub-to 0 conspectus-open --str "${${1:-$PWD}:a}"
    else
      conspectus "$@" >/dev/null 2>&1 &!
    fi
  }
  ```
- The preview hook for yazi ships **inside this repo**
  (`plugins/conspectus.yazi`) — no external plugin or binary needed. lf/nnn/
  xplr work as terminals; wire their selection hook to `$QLPEEK_FIFO` to get
  the live preview.
- Prototype: no app-level shortcuts yet beyond the window chrome; file-manager
  keys are yazi's own.

## License

[MIT](LICENSE)
