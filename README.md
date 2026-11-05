# conspectus

**The best of both worlds, glued by a minimal Swift wrapper:** [yazi's](https://yazi-rs.github.io/)
fast, fully customizable keyboard navigation — your config, your keybindings,
your plugins — combined with **macOS-native previews**: text and source
highlighted in-process, markdown typeset as a document, images and PDFs in
native views, and Quick Look for the long tail (video, .ai, .psd, Office, …).

Terminal file managers navigate better than Finder ever will; a native pane
previews better than any terminal ever will. conspectus refuses to choose: a
split window with yazi in an embedded terminal on the left and a live preview
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
The line is **permanence**, not pixels: conspectus may *show* a mark — the
word a content search hit, in yellow on its page (`@PDFPAGE`, see Coupling
below) — as long as it is gone with the next hover and nothing is written
anywhere. Deliberately not built here: reading position, saved highlights,
in-document search — every piece of document state that has to be kept slows
down the loop this app is for.

## How it works

Code layout: `Sources/ConspectusCore` holds the pure, unit-tested helpers
(start-dir resolution, palettes, icon mapping, listing order);
`Sources/conspectus` is the AppKit shell around them. Conventions live in
`CLAUDE.md`, solved gotchas in `NOTES.md`.

- Left pane: [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) hosting a
  login shell that `exec`s the file manager.
- Right pane: a universal preview that swaps by hovered item type —
  - **File** → one of four covers over an always-alive `QLPreviewView`: text /
    source / notes in a native `NSTextView` (markdown rendered or `bat`-
    highlighted), raster images in an `NSImageView`, PDFs in PDFKit, and
    everything else through Quick Look (same generators as Finder). See
    "Status / limits" for each.
  - **Folder** → a rendered contents listing in **yazi's current sort order**
    (the `,` keys — `, t`, `, m`, `, s` … — reach the pane; the plugin sends
    the tab's sort preference with every hover), Nerd Font glyphs, Catppuccin
    colors, size and modification date as a dimmed column — `today 14:32` /
    `y-day 09:10`, `16.10. 14:32` this year, `15.01. 2024` before (day field
    as wide as `16.10.`, so the columns sit close).
    Names longer than 40 characters are cut with `…` like yazi cuts them
    (`lenz09-soziologie-der-zweierbeziehu….pdf` — the extension stays), so
    the column never wraps; the full name is the row's tooltip.
    Quick Look on a folder only shows its icon +
    metadata, so we render the look-ahead ourselves. **Clicking a row marks
    it in yazi** (`reveal`: yazi cds to the listed folder and puts the cursor
    on the row — which fires a hover and previews it, the same way keyboard
    navigation does); **double-clicking acts**: a folder is entered, a file
    opens like `Enter`. Mimics yazi's own third column. Inside a CVS
    checkout the rows carry **CVS status signs** in front of the icons, the
    same as yazi's (next bullet).
- **CVS status signs, like git.yazi's**: in a CVS checkout (a directory with
  `CVS/Entries`) yazi's file list and the folder listing show the letters
  `cvs -n update` prints — `M` modified, `A` added, `R` removed, `C`
  conflict, `?` unknown; clean and ignored files get a blank cell. The
  bundled `plugins/cvs.yazi` is a yazi fetcher (runs asynchronously as yazi
  enters a directory, spawns nothing outside a checkout) that calls
  `conspectus --cvs-status <dir>` — the binary the launcher hands over as
  `CONSPECTUS_BIN` — so yazi and the pane share one implementation
  (`ConspectusCore/CVS.swift`). **Offline**: read from `CVS/Entries` (+
  `Entries.Log`), mtimes, conflict markers and the cvsignore lists (built-in,
  `~/.cvsignore`, `$CVSIGNORE`, the directory's `.cvsignore`), never from the
  server — so it cannot show "needs update", nor honor the server's
  `CVSROOT/cvsignore`. Directories get no roll-up of their contents' state.
- **`U` — newer on the server**, the one sign that needs the server, and
  the one that answers "am I looking at the current version?". Entering a
  checkout folder makes the fetcher run `conspectus --cvs-remote <dir>` as
  a second phase, after the local signs are on screen: one `cvs -n -q
  update -l` in that folder (`-l`: no subfolders), ~0.25 s over a kept-alive
  ssh connection (`ControlMaster` in `~/.ssh/config`; ~0.7 s when it has to
  connect), 20 s timeout. The answer is cached per folder under
  `~/.cache/conspectus/cvs-remote/` for **`CONSPECTUS_CVS_REMOTE`** seconds
  (default 300; `off` never asks the server, the signs stay local), a
  failed check for 60 s. The first failed check of a yazi session shows a
  notification ("server check failed — no U signs"), later ones stay
  silent. Limits: `U` is as old as the cache says; a file you modified
  locally that is also newer on the server shows `M`, as in `cvs -n
  update`; the folder listing in the pane shows `U` only for folders
  already entered (a hover never costs a server round trip); `CVS Update…`
  drops the folder's cache so the next fetch asks again.
- **The CVS line above a previewed file** — for every preview kind inside
  a checkout, a strip reads `paper.tex  1.4 — current (checked today
  10:32)`: the direct answer to "am I looking at the current version?".
  Verdicts, local state first (as `cvs -n update` ranks them): `newer on
  the server (checked …)`, `modified locally, not committed · server has
  nothing newer (…)`, `added, not committed`, `conflict markers in the
  file`, `not in CVS`; and when the server has not answered, it says so —
  `server not checked yet` (the fetcher's result lands within a second;
  if it never comes, e.g. for a file reached through the pane's listing,
  the preview runs the dry run itself after 0.8 s), `server check failed
  (…)`, `server not asked (CONSPECTUS_CVS_REMOTE=off)`. Never "current"
  without a good check. Outside a checkout the strip is gone and the
  preview has the whole pane.
- **The git line, same strip** — inside a git repository the line reads
  `admin-passwords.kdbx  efc8c72 30.09. 2025 — current (fetched today
  16:01)`: name, last commit touching the file, and the verdict. Local
  state from git itself (`status --porcelain`, mapped onto the same
  vocabulary: untracked = `not in git`, `ignored by git`, `added`, `deleted`,
  `modified locally, not committed`, `merge conflict`); the server part from
  one `git fetch` per **repository** (not per folder), cached under
  `~/.cache/conspectus/git-remote/` for **`CONSPECTUS_GIT_REMOTE`** seconds
  (default 300; `off` never fetches), a failed one for 60 s. The fetch runs
  with no way to wait for a human (`GIT_TERMINAL_PROMPT=0`, ssh in
  BatchMode): a remote that needs a prompt fails fast and the line says
  `fetch failed (…)`. The answer is **per file**: `newer on origin/master —
  3 commits behind` only when the incoming commits touch this file
  (`git diff --name-only HEAD...@{u}`); otherwise `current (fetched …) ·
  origin/master is 3 commits ahead, not this file`, plus `· 2 commits to
  push` when you are ahead. `no upstream branch` is a failed check. A CVS
  checkout inside a git repository is answered as CVS. `conspectus
  --git-remote <repo>` prints the cached or fresh check from a shell. No
  sign column for git in yazi or the listing: git.yazi already shows the
  local letters, and "newer upstream" is answered in the line.
- **VCS Update… (`⌥⌘U`, Go menu; also in the context menu: "CVS Update…"
  next to "Open in lazycvs", "Git Update…" next to "Open in lazygit" in a
  git repository)** — the
  server half the signs leave out. In a CVS checkout the terminal panel runs
  `cvs -n -q update -d` in the folder yazi is in (recursive, as cvs is),
  streaming one line per file that differs — `U`/`P` newer on the server,
  `M` `A` `R` `C` `?` local. Then it asks `Update now? [y/N]`; only `y` runs
  `cvs -q update -d -P`. cvs exits 1 already when a file would conflict, so
  that gets a note, not a stop; an aborted cvs (server unreachable) stops
  before the question. In a git repository the panel runs `git fetch`
  (here a credential prompt can be answered), lists uncommitted local
  changes, then the incoming commits with their files (`git log --stat
  HEAD..origin/master`) and asks `Pull now (git pull --ff-only)? [y/N]` —
  never a merge from a panel: a diverged branch is reported and nothing
  moves; up to date (with the commits-to-push count) closes without a
  question. Any key closes the panel. Outside a checkout or repository the
  key beeps.
- Because the right pane previews files *and* folders, yazi runs at 2 columns
  (its own 3rd preview column is hidden via the overlay `yazi.toml`). You
  navigate in the middle column and enter directories to descend.
- **Finder's mouse contract inside the yazi pane too**: a left click marks
  (moves the cursor — stock yazi), a double-click enters a folder or opens a
  file like `Enter`. yazi has no double-click; the bundled plugin wraps
  `Entity:click` and counts two clicks on the same row within the macOS
  double-click interval (System Settings → Mouse, handed over as
  `CONSPECTUS_DOUBLE_CLICK`). Right-click keeps its stock reveal. One quirk:
  the app delivers a right-click to yazi as a left click (cursor onto the row
  before the menu), so left-then-right on the same row within the interval
  counts as a double-click.
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
  the app swaps the preview in place. For yazi the bundled
  `plugins/conspectus.yazi` does this, writing the FIFO straight from Lua.

Any other TUI can drive the preview by writing an absolute path to
`$QLPEEK_FIFO` when its cursor moves. A writer that knows a PDF **page** —
a content search through ripgrep-all, which prints `Page 3: …` for every
PDF hit — writes `@PDFPAGE:<page>:<path>` instead, and the native PDF
preview opens on that page rather than page 1; with a tab and the searched
word appended (`@PDFPAGE:3:/a.pdf<TAB>rosen`) every occurrence on that page
is marked in yellow. The mark is display-only — PDFKit's
`highlightedSelections`, gone with the next hover, never written to the
document; a highlight that should *stay* is perlege's job (`E p`). Yazi's
`S` picker sends this in its `M-a` mode, see the dotfiles `keybindings.md`. The `qlpeek send` script does exactly
that when the variable is set, so a tool running in the terminal panel
with `qlpeek send <file>` as its opener lands in the preview pane: lazycvs
with `alt_open = "qlpeek send $FILE"` shows an old revision of a PDF or an
image there on `Ctrl-o` in its History tab.

## Requirements & works best with

**Required:** macOS 13+, [yazi](https://yazi-rs.github.io/) (the bundled
plugin is injected automatically — a machine with no yazi config works),
Swift toolchain to build.

**Optional, but the preview shines with them:**

- **[`bat`](https://github.com/sharkdp/bat)** (`brew install bat`) for syntax
  highlighting in the native text preview; without it source shows as plain
  themed monospace. `BAT_THEME` overrides the Catppuccin theme the app picks.
- **Quick Look extensions** only matter for the long tail that still goes
  through Quick Look (text, markdown, images and PDFs are rendered natively).
- **A Nerd Font** (e.g. `brew install --cask font-jetbrains-mono-nerd-font`)
  for yazi's file icons and the folder listing glyphs — otherwise you get
  tofu boxes.
- **Catppuccin yazi flavors** (`ya pkg add yazi-rs/flavors:catppuccin-mocha`
  and `…:catppuccin-latte`) so yazi follows the light/dark theme with the
  panel; without them your own yazi theme is kept.
- **[macFUSE](https://macfuse.github.io/) + sshfs** for [`conspectus ssh`](#remote-machines-conspectus-ssh) (browsing a remote machine).

## Build & run

```sh
./build.sh             # swift build -c release (first run fetches SwiftTerm + swift-markdown)
swift test             # unit tests for the pure helpers (ConspectusCore)
conspectus             # yazi + Quick Look preview, starting at $HOME
conspectus ~/work      # start at a given directory (tilde/relative resolved)
conspectus ~/work/paper.pdf   # a FILE: start in its dir, cursor on the file
conspectus split       # two yazi panes side by side (dual-pane copy)
conspectus split ~/work
conspectus triple      # two yazi panes + Quick Look preview (3 panes)
conspectus ide         # yazi | nvim | preview — a small IDE (see below)
conspectus ssh <host>:projects  # a remote machine over sshfs, also TRAMP paths (see below)
./install-app.sh       # assemble /Applications/Conspectus.app (Finder/Dock icon)
```

Start dir is `$HOME` unless a `[path]` is given. A `[path]` that is a *file*
starts in the file's directory with the cursor on it, so the Quick Look pane
previews it immediately — this is what indago's `M-o` ("open in conspectus")
uses. The TUI is yazi; override with the `CONSPECTUS_CMD` env var (e.g.
`CONSPECTUS_CMD=lf conspectus`).

**Privacy permissions (Downloads, Desktop, Documents, …):** macOS asks per
folder the first time the app touches it and stores the answer against the
binary's code signature. A SwiftPM build is ad-hoc signed, i.e. signed with
the hash of that very build — so every `./build.sh` is a new app to macOS and
the whole round of dialogs comes back. Name a stable signing identity and
`build.sh` signs the binary with it after each build (any identity from
`security find-identity -v -p codesigning`, a free *Apple Development* one
is enough):

```sh
export CONSPECTUS_SIGN_IDENTITY="Apple Development: you@example.com (TEAMID)"
./build.sh
```

The grants then survive rebuilds (the first launch after switching to the
signed binary asks once more). To skip the per-folder dialogs altogether, add
the binary once under System Settings ▸ Privacy & Security ▸ **Full Disk
Access** (the `+` button; `⌘⇧G` in the file picker takes a path like
`~/projects/conspectus/.build/release/conspectus`). The `Conspectus.app`
bundle needs nothing of its own: its launcher execs this same binary.

**yazi columns:** preview modes run yazi at 2 columns by default (its own
preview column hidden — the Quick Look pane is the preview).
`CONSPECTUS_COLUMNS=3 conspectus` keeps your full 3-column config instead:
yazi's look-ahead column *plus* the Quick Look pane. Split mode always uses
your full config.

## Remote machines (`conspectus ssh`)

```sh
conspectus ssh <host>                # start in the remote home directory
conspectus ssh <host>:projects/x     # relative to the remote home
conspectus ssh <host>:/var/log       # absolute
conspectus ssh --sudo <host>:/etc    # read as root, read-only

# the same in Emacs TRAMP spelling (quote it: | is a shell pipe)
conspectus '/ssh:<host>:~/projects/x'
conspectus '/ssh:leguin|sudo:root@leguin:/home/textimg/ComfyUI/output/'
conspectus '/ssh:<host>|sudo:www-data@<host>:/var/www'   # as another user
```

The launcher mounts the remote `/` with sshfs under **`CONSPECTUS_SSH_MOUNTS`**`/<host>` (default `~/mnt/ssh`, e.g. `~/mnt/ssh/leguin-sudo/home/textimg/ComfyUI/output`), so yazi, every preview, the pickers and the openers work on plain local paths. **Is conspectus already running** (e.g. you type it into its own ⌘J terminal), the remote directory opens as a **new tab in that window**, like `con <dir>`, and the mount stays until you `umount ~/mnt/ssh/<host>` (sshfs's output goes to `~/.cache/conspectus/sshfs-<host>.log`). Otherwise it starts a window of its own there. sshfs runs your own `ssh`, so `~/.ssh/config` applies (host aliases, keys, `ControlMaster`); a password or passphrase prompt shows in the launching terminal. Quitting that own window unmounts again — unless the mount is still in use (a second session on the same host, a shell cd'd into it), then it stays and the launcher prints the `umount` to run later. A second `conspectus ssh` to the same host reuses the mount and leaves the unmounting to the session that made it. The usual network-mount rules apply: the fzf pickers search two levels deep, and a stalled server can hang a preview — `CONSPECTUS_PREVIEW_SKIP_DIRS` / ⌘⇧P (see [Status / limits](#status--limits)) turn previews off there. Files are never copied; sshfs is mounted with `noappledouble`, so no `._*` files land on the server either.

The TRAMP subset understood: `/ssh:[user@]host:path` and one sudo hop on the same host, `/ssh:[user@]host|sudo:[user@]host:path` (sudo user defaults to root). Other methods, more hops and `host#port` stop with a message — a port goes into `~/.ssh/config`.

**sudo** (`--sudo` or `|sudo:` in the path) reads files only that user may read, as a separate **read-only** mount (`~/mnt/ssh/<host>-sudo`, `…-sudo-<user>` for a non-root user), so a slip in yazi cannot delete or overwrite as root. Like TRAMP, it asks the sudo password in the launching terminal, once per session — and only if sudo on the server wants one. The password goes to the server as the first line of the sftp stream and reaches sudo through a throwaway askpass helper in the remote home (`~/.conspectus-askpass.*`, removed when sudo ends; a torn connection can leave one behind — it holds no secret, only `exec printenv CONSPECTUS_PW`); the password never appears on a command line. On this Mac it sits in the environment of the sshfs process for the session (needed to reconnect), readable by your own user only. The password is checked before anything is mounted; a wrong one is asked again, three tries like sudo.

## Network mounts on demand (automount)

A network mount you only need now and then (CephFS, SMB, sshfs) need not stay mounted — and one that stayed often survives sleep or a network change only on paper: it still sits in the mount table, but every access fails with `Device not configured` or hangs. List such mounts in **`CONSPECTUS_AUTOMOUNT`** (default `~/.config/conspectus/automount`), one per line, the mount point first and then the command that mounts it:

```
# <mount point>  <command>
~/mnt/ceph/storage  ceph-mount
```

Whenever a tab enters a mount point or anything below it — `cd`, a click, `con <dir>`, a tab restored at start, or a start path such as `conspectus ~/mnt/ceph/storage/corpora` — the launcher checks it: mounted and its top folder lists within 5 seconds → nothing happens. Otherwise it runs the command in a login zsh (so `~/bin` is on `PATH` even when the app came from the Dock), a notification says it is mounting and whether that worked, and yazi shows the folder as soon as the mount answers again. The command must bring the mount back from every state — missing, failing at once, or hanging (ceph_macos's `ceph-mount` does since its commit ff12f24); one still running after 120 seconds is stopped. A mount point is checked at most once every 30 seconds per pane, and two panes never run its command at the same time; the command's output goes to `~/.cache/conspectus/automount-<mount point>.log`. Nothing is ever unmounted: a mount stays until you unmount it, and a dead one is repaired the next time you enter it. The file is read when conspectus starts, so restart it after editing; the mount point is the first word (no spaces), and `#` starts a comment, in the command too.

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
focusable pane exists). The mouse can also *navigate*: a double-click on a
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
that take files), **Alfred Actions…** (Alfred's Universal Actions panel for
the file, via its AppleScript `action` command; only shown with Alfred
installed — for a file also **Alfred Actions for “folder”…**, the panel for
the folder it lies in, so folder-only actions such as a "Create new file
here" workflow are reachable from a file too), **Open in lazycvs** (only inside a CVS checkout, i.e. next to a
`CVS/Root` marker: the terminal panel opens at half the window height running
`lcvs <item>` in that directory — the dotfiles shim around lazycvs, which lands
on the clicked item; while it runs, **lazycvs follows yazi**: every directory
you enter is sent over a per-instance FIFO (`lcvs -follow`), and lazycvs makes
it its root, in place — the lazycvs tree always starts where yazi stands, up or
down, and the scans of the root left behind are cancelled; a dialog or search
open in lazycvs defers the switch until you are done, a directory outside any
checkout leaves it where it is (`~/cvsrepo` itself is a checkout of the whole
repository, so stopping there scans everything);
quitting lazycvs closes the panel, an lcvs error stays visible above a shell
(an lcvs build without `-follow` fails here too: `lcvs build`); an open panel
is replaced; from the keyboard: yazi's
`E C` in the dotfiles keymap, via the bundled plugin's `lazycvs` mode, which beeps outside a checkout), **Open in lazygit**
(its git twin, in a git repository: the same panel runs `lazygit -p <root>
-f <item>` — filter mode, so the log, reflog and stash show only what touched
the clicked file or folder; the repository root itself opens the plain view.
No follow channel: lazygit has no mode for a root that moves with yazi.
Quitting lazygit closes the panel, an error stays visible above a shell), **Copy Path** / **Copy
Name**, **Copy** / **Cut** / **Paste** (Paste only while yazi's yank buffer
holds something; its title names the count and the target folder — next to
it **Show Clipboard (N)** lists the buffer in the preview, clickable like ⌘L's
selection list; also **⇧⌘L**, below), **New
File…** / **New Folder…**, and **Rename…** / **Move to Trash**. All file
operations run *inside yazi*, so there is one task system, one confirmation
and one yank buffer (`p` in either pane pastes what the menu copied; Copy also puts the files
on the macOS pasteboard, so ⌘V in Finder pastes them too — Cut stays in yazi,
since Finder has no cut on the pasteboard):
rename and trash act on the clicked item (`--hovered`, never on a selection
you left elsewhere); copy / cut are yazi's `yank` — the clicked item, or the
whole selection if you right-clicked a selected file, and refused with a
notice if other files are selected; paste and new file / folder (yazi's
`create`, prompting for the name) act in the folder containing the clicked
item. In a yazi pane the right-click first moves yazi's
cursor onto the row, like a left click, then opens the menu for the file yazi
reports as hovered. Not offered (yet): Tags, Compress, Duplicate, Make Alias.

The same file operations sit in the menu bar's **File** menu, Finder-style
(Open, Reveal in Finder, Get Info, Alfred Actions… and …for Enclosing Folder,
New File… / New Folder…, Copy / Cut / Paste Items, Copy Path / Name, Rename…,
Move to Trash), acting on the item under yazi's cursor in the pane you used
last. They deliberately have no shortcuts — yazi's own keys (`y` `x` `p` `a`
`r` `d`) are the keyboard path, and ⌘C / ⌘X / ⌘V stay Edit's. The **Help**
menu's search field (⇧⌘/) finds any menu item by typing, these included.

**Selecting text:** click into the preview to focus it, then drag to select
and **⌘C** to copy — in the PDF view and in the text/markdown preview alike
(**⌘A** selects all). ⌘C / ⌘V also copy/paste in the terminal panes.

**⌘C copies the file** in a yazi pane, Finder-style: with no terminal text
selected, the file under the cursor goes onto the pasteboard as a file URL
(plus its path as text), so ⌘V in Finder pastes the file and a text field gets
the path. yazi is then asked for its *marked* selection and a non-empty answer
replaces the pasteboard a few milliseconds later (yazi has no selection event,
so it is pulled). The hovered file is written first so that **Alfred's
selection hotkey**, which simulates ⌘C in apps it cannot read, always finds a
file — for the marked set in Alfred, use yazi's `E a` (dotfiles keymap: Alfred
Actions for the selection or the hovered item, works in a bare terminal yazi
too). Terminal text selected by dragging still copies as text.

## Bottom terminal (⌘J)

**⌘J** toggles a terminal panel below the panes: a fresh interactive login
zsh started **in the directory yazi is currently visiting** (derived from
the hover events; in split mode that's the active pane) — for quick
`git`/`cvs`/one-off commands next to the file manager. Deliberately no live
cd-follow: closing (⌘J, **⌘W**, or `exit`) kills the shell, reopening starts
a new one at yazi's current location. The panel's shells (⌘J, lazycvs, VCS
Update…) run with **`TERM_PROGRAM=conspectus`**, so a zshrc can give them the
slim startup it gives VS Code's and Zed's terminals (the dotfiles do: no
fzf-tab, no p10k, no syntax highlighting — a quick command, not a session). ⌘W only ever closes the panel — with
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
replaces it. **⇧⌘L** (View → Show Yazi Clipboard in Preview) shows the
same list for yazi's yank buffer — everything `y` / `x` or the context menu's
Copy / Cut put there, not just the first name the shortcut bar names; it
reads the app's `@YANK:` mirror, no round trip.

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
  preview column could not render images inside conspectus — which is why
  preview modes hide that column (`CONSPECTUS_COLUMNS=2`, the default) and the
  right pane does both jobs: file previews *and* the directory look-ahead
  listing. `CONSPECTUS_COLUMNS=3` keeps yazi's column alongside if you want
  its text previews too.
- The launcher builds an overlay config under `~/.cache/conspectus/yazi-config`
  and points `YAZI_CONFIG_HOME` at it: your live config is symlinked in, the
  **bundled `plugins/conspectus.yazi`** is injected, and `init.lua` is
  generated to load your own init first. That plugin is the yazi-side half of
  conspectus: it pushes hovers into the FIFO, follows the app's `panesync-*`
  messages (row clicks, back/forward, the theme restart), keeps the tab session,
  decides `l` / `o` / `Enter` from the *hovered* entry, and turns two clicks
  on a row into Finder's double-click (enter / open). Your
  normal yazi is untouched — and a machine with **no yazi config at all**
  works too (yazi defaults + the bundled plugin). `theme.toml` switches to the
  catppuccin flavors only if they are installed; otherwise your own theme (or
  yazi's default) is kept.
- Font: JetBrainsMono Nerd Font Mono by default; override with `CONSPECTUS_FONT` /
  `CONSPECTUS_FONT_SIZE`. Line height 1.136 × the font's natural height
  (`terminalLineSpacing`), the same value as wezterm's `line_height` — 1.5 ×
  the size for JetBrains Mono.
- Split ratio: the preview keeps **a third** of the width, the terminal panes
  share the remaining two thirds — at every pane count, so toggling ⌘D/⌘E does
  not resize the preview behind your back. `CONSPECTUS_SPLIT` is the terminals'
  combined share as a fraction (default `0.667`; `0.5` gives the preview half,
  `0.75` favours yazi); clamped to 0.25…0.75. The divider is still draggable,
  and the ratio scales when you resize the window.
- Mouse back / forward: the side buttons (4 and 5) walk the **directory
  history** of the pane under the pointer — together with double-click-to-enter that
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
  per preview request, note delivery, context menu and scroll event reaching
  the Quick Look view — for debugging a preview that stops reacting. The file
  is appended to, never truncated; delete it yourself.
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
  `bat` isn't installed. The encoding is detected (UTF-8, UTF-16 with BOM,
  Windows-1252, Latin-1), so legacy Latin-1 files show their umlauts.
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
- App-level shortcuts are the window chrome only (⌘D/E/I/J/K/L/N/P/R/W, the
  Go menu, ⌥-arrows); every file-manager key is yazi's own, from your keymap.

## License

[MIT](LICENSE)
