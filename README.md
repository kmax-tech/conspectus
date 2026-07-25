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
conspectus split       # two yazi panes side by side (dual-pane copy)
conspectus split ~/work
conspectus triple      # two yazi panes + Quick Look preview (3 panes)
./install-app.sh       # assemble /Applications/Conspectus.app (Finder/Dock icon)
```

Start dir is `$HOME` unless a `[path]` is given. The TUI is yazi; override with
the `CONSPECTUS_CMD` env var (e.g. `CONSPECTUS_CMD=lf conspectus`).

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

### Focus

**⌥← / ⌥→** (or **⌥[ / ⌥]**, HHKB-friendly — no arrow keys) cycle the
keyboard horizontally (left terminal ⇄ second terminal ⇄ preview), **⌥↑ /
⌥↓** vertically between the pane area and the terminal panel — the same
plain-Alt-arrow convention as kitty, WezTerm, and smart-splits in the
dotfiles (`keybindings.md`); ⌘⌥-arrows remain as silent aliases. Trade-off
(same as kitty): ⌥-arrows no longer reach the shell as word jumps —
`M-b`/`M-f` and `C-a`/`C-e` still do. **Clicking** a pane focuses it too.
A focused pane shows a subtle gray border (only when more than one
focusable pane exists). The preview is **focus-by-intent**: a
focused Quick Look scrolls with the arrow keys / PgUp / PgDn and pages PDFs
(or plays videos) with Space — but clicks and app switches can never move
the keyboard into it, so hjkl in yazi always keep working; coming back from
an editor launched out of yazi restores focus to the last terminal.

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
memory sits — yazi's defaults plus conspectus's own keys:

    y→p copy   x→p move   d trash   r rename   a new   cc path   cf name
    ␣ select   / find   ⌘D split   ⌘E preview   ⌘J terminal   ⌘K all keys   ⌘/ bar

`y→p` = yank then paste (copies across panes in split mode); `cc`/`cf`/`cn`
copy the full path / filename / name without extension to the clipboard.
Toggle the bar with **⌘/** (or View → Toggle Shortcut Bar) — the choice
persists across launches.

**⌘K** opens the full cheat sheet: a native, scrollable panel with yazi's
complete default keymap, grouped (navigate / select / files / clipboard /
find / tabs) plus the conspectus keys — the readable version of yazi's `~`
help. Your own `keymap.toml` (`$YAZI_CONFIG_HOME`, else `~/.config/yazi`) is
parsed on every open and shown as its own group on top, so config edits
appear on the next ⌘K; parse problems are reported in the panel footer. The
parser covers the keymap subset of TOML (inline-table arrays and
`[[mgr.prepend_keymap]]` blocks) — no TOML dependency.

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
  **bundled `plugins/conspectus.yazi`** (hover → FIFO, panesync-cd follower) is
  injected, and `init.lua` is generated to load your own init first. Your
  normal yazi is untouched — and a machine with **no yazi config at all**
  works too (yazi defaults + the bundled plugin). `theme.toml` switches to the
  catppuccin flavors only if they are installed; otherwise your own theme (or
  yazi's default) is kept.
- Font: JetBrainsMono Nerd Font Mono by default; override with `CONSPECTUS_FONT` /
  `CONSPECTUS_FONT_SIZE`.
- Live refresh: the previewed file's mtime is polled (~0.7 s) while a file
  preview is showing, so editing a note in `nvim` (left pane, `E t`) and saving
  updates the preview (right) on the fly. Polling (not an fd watch) on purpose:
  it survives a rebuild that deletes/recreates/moves the file — e.g. `latexmk`
  producing a PDF — where the file briefly vanishes and an inode-bound watch
  would be lost. Gated to an active file preview, so it stops when browsing
  dirs / idle. `CONSPECTUS_WATCH=off` disables it.
- Event diagnosis (off by default): `CONSPECTUS_EVENT_LOG=<path>` appends a line
  per preview request and per scroll event reaching the Quick Look view — for
  debugging a preview that stops reacting.
- Preview size cap: files above `CONSPECTUS_PREVIEW_MAX_MB` (default 50) show a
  short "too large" note instead of previewing — a several-hundred-MB JSON
  would otherwise wedge Quick Look and spike memory. `0` disables the cap.
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
  (`ya pkg add yazi-rs/flavors:catppuccin-mocha`).
- The preview hook for yazi ships **inside this repo**
  (`plugins/conspectus.yazi`) — no external plugin or binary needed. lf/nnn/
  xplr work as terminals; wire their selection hook to `$QLPEEK_FIFO` to get
  the live preview.
- Prototype: no app-level shortcuts yet beyond the window chrome; file-manager
  keys are yazi's own.

## License

[MIT](LICENSE)
