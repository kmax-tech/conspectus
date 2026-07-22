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
