# qlpanel

A split window: a **TUI file manager** (yazi by default) running in an embedded
terminal on the left, a live **macOS Quick Look preview** on the right. Your own
fast, native, dual-pane-ish file manager — the terminal keeps your yazi config
and keybindings, the preview gets full Quick Look fidelity (.ai, .psd, PDF,
video, …).

This is the "integrated window" sibling of [`qlpeek`](../qlpeek), which docks a
Quick Look panel next to your existing terminal instead of embedding one.

## How it works

- Left pane: [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) hosting a
  login shell that `exec`s the file manager.
- Right pane: `QLPreviewView` — the embeddable Quick Look view, same generators
  as Finder.
- Coupling: the app creates a FIFO and hands its path to the shell via
  `QLPEEK_FIFO`. The file manager writes the hovered path there on selection;
  the app swaps the preview in place. For yazi this is the `qlpeek send` plugin
  (honours `QLPEEK_FIFO`) and follow mode auto-enables inside qlpanel.

Any other TUI can drive the preview by writing an absolute path to
`$QLPEEK_FIFO` when its cursor moves.

## Build & run

```sh
./build.sh          # swift build -c release (first run fetches SwiftTerm)
qlpanel             # default: yazi
qlpanel lf          # or any TUI file manager (preview needs its own hook)
```

## Status / limits

- SwiftTerm is not kitty: no kitty graphics protocol, so yazi's *own* image
  preview column won't render images inside qlpanel — but that's what the Quick
  Look pane is for. yazi's 3rd column is kept anyway, because it also does
  **directory look-ahead** (contents of the hovered folder), which Quick Look
  does not replace. Quick Look is additive: full fidelity for files on the
  right, yazi's column for look-ahead + text/simple previews.
- The launcher builds an overlay config under `~/.cache/qlpanel/yazi-config`
  (everything symlinked from the live config; only `theme.toml` is generated, to
  follow the system appearance) and points `YAZI_CONFIG_HOME` at it. Your normal
  yazi is untouched.
- Font: JetBrainsMono Nerd Font Mono by default; override with `QLPANEL_FONT` /
  `QLPANEL_FONT_SIZE`.
- Theme: follows the macOS system appearance — Catppuccin Latte in light mode,
  Mocha in dark, re-themed live on toggle. The terminal palette is set by
  qlpanel; yazi picks the matching flavor by querying our background (OSC 11)
  via the overlay `theme.toml` (`dark = catppuccin-mocha`, `light =
  catppuccin-latte`). Needs both flavors installed
  (`ya pkg add yazi-rs/flavors:catppuccin-mocha`).
- Only yazi ships a preview hook so far (`qlpeek.yazi` plugin in the dotfiles
  repo). lf/nnn/xplr work as terminals; wire their selection hook to
  `$QLPEEK_FIFO` to get the live preview.
- Prototype: no app-level shortcuts yet beyond the window chrome; file-manager
  keys are yazi's own.
