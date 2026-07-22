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
