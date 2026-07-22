# conspectus

A split window: a **TUI file manager** (yazi by default) running in an embedded
terminal on the left, a live **macOS Quick Look preview** on the right. Your own
fast, native, dual-pane-ish file manager — the terminal keeps your yazi config
and keybindings, the preview gets full Quick Look fidelity (.ai, .psd, PDF,
video, …).

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
    metadata, so we render the look-ahead ourselves.
- Because the right pane previews files *and* folders, yazi runs at 2 columns
  (its own 3rd preview column is hidden via the overlay `yazi.toml`). You
  navigate in the middle column and enter directories to descend.
- Coupling: the app creates a FIFO and hands its path to the shell via
  `QLPEEK_FIFO`. The file manager writes the hovered path there on selection;
  the app swaps the preview in place. For yazi this is the `qlpeek send` plugin
  (honours `QLPEEK_FIFO`) and follow mode auto-enables inside conspectus.

Any other TUI can drive the preview by writing an absolute path to
`$QLPEEK_FIFO` when its cursor moves.

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

**⌘⌥← / ⌘⌥→** cycle the keyboard horizontally: left terminal ⇄ second
terminal ⇄ preview. A focused pane shows a subtle gray border (only when
more than one focusable pane exists). The preview is **focus-by-intent**: a
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
  (everything symlinked from the live config; only `theme.toml` is generated, to
  follow the system appearance) and points `YAZI_CONFIG_HOME` at it. Your normal
  yazi is untouched.
- Font: JetBrainsMono Nerd Font Mono by default; override with `CONSPECTUS_FONT` /
  `CONSPECTUS_FONT_SIZE`.
- Theme: follows the macOS system appearance — Catppuccin Latte in light mode,
  Mocha in dark, re-themed live on toggle. The terminal palette is set by
  conspectus; yazi picks the matching flavor by querying our background (OSC 11)
  via the overlay `theme.toml` (`dark = catppuccin-mocha`, `light =
  catppuccin-latte`). Needs both flavors installed
  (`ya pkg add yazi-rs/flavors:catppuccin-mocha`).
- Only yazi ships a preview hook so far (`qlpeek.yazi` plugin in the dotfiles
  repo). lf/nnn/xplr work as terminals; wire their selection hook to
  `$QLPEEK_FIFO` to get the live preview.
- Prototype: no app-level shortcuts yet beyond the window chrome; file-manager
  keys are yazi's own.
