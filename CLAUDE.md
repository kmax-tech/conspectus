# CLAUDE.md — conspectus

macOS AppKit app in Swift (SwiftPM). These conventions are the project-adapted
version of the general (Python-oriented) code standards — same spirit, tuned
for a small native GUI prototype. If a request conflicts with a rule here,
flag the conflict instead of silently violating it.

The thread through every rule: **nothing important should be implicit.**

## Structure

- `Sources/ConspectusCore/` — unit-testable logic without AppKit state or
  SwiftTerm: start-dir resolution, palettes/hex parsing, icon mapping,
  listing order, the keymap parser, ANSI parsing, note lookup, typography,
  tips. Mostly pure; the few functions that read the filesystem
  (`loadFolder`, `resolveNote`, `cvsWorkingDir`, `isDirectory`) say so in
  their doc comment and return data, never mutate app state.
- `Sources/conspectus/` — the AppKit shell: `main.swift` (bootstrap, env
  vars, FIFO sentinels), `Appearance.swift` (theming/rendering),
  `MarkdownRender.swift` (swift-markdown AST → attributed string),
  `Icon.swift`, and `Panel.swift` (state + lifecycle) with themed extensions
  (`Panel+Layout`, `Panel+Focus`, `Panel+Preview`, `Panel+PDFBar`,
  `Panel+Notes`, `Panel+Print`, `Panel+Terminal`, `Panel+History`,
  `Panel+ContextMenu`, `Panel+CheatSheet`). UI, processes, FIFO — the
  side-effect edge of the system. Top-level code stays in `main.swift` (Swift
  requires it); stored properties stay in `Panel.swift`.
- `Sources/ConspectusShield/` — one ObjC function: the @try/@catch swizzle
  around Quick Look's scroller teardown (Swift cannot catch ObjC exceptions).
- `Tests/ConspectusCoreTests/` — XCTest suite for the core, mirroring its files.
- `bin/conspectus` — launcher script (builds the yazi overlay config and
  injects the bundled plugin).
- `plugins/conspectus.yazi/` — bundled yazi glue (hover → FIFO, panesync-cd
  follower); makes the repo self-contained, no external plugin or binary.

New pure logic goes into `ConspectusCore`; AppKit/process glue stays in the
executable. That boundary is what keeps the important parts testable.

## Rules (adapted)

1. **Documentation over type hints.** Swift's compiler enforces types; what it
   can't enforce is intent. Every non-trivial function gets a comment or `///`
   doc comment saying *what* and *why* (not line-by-line how). Functions with
   side effects state them explicitly (`Side effects:` line).
2. **One function does one thing.** If a body grows distinct `// now do X`
   blocks, split it into named functions and let the original orchestrate
   (see `applicationDidFinishLaunching`).
3. **Side effects live at the edges.** Pure logic in `ConspectusCore`; I/O,
   AppKit state, and process handling in the executable. Don't mutate state
   from a core function.
4. **Named structures across boundaries.** More than ~2 values crossing a
   function boundary → a small struct (`StartDir`, `FileIcon`, `DirEntry`),
   not a tuple.
5. **NOTES.md records solved hard problems** — problem, solution, gotcha, a
   few lines each. Only genuinely tricky things, not a changelog.
6. **Assumptions are visible.** Configurable behavior is an env var or named
   constant, documented in the README (`CONSPECTUS_CMD`, `CONSPECTUS_FONT`, …).
   Significant ambiguous choices get asked about; small ones get stated.
7. **Fail loud.** No silent `try?` unless absence/failure is genuinely the
   normal case — and then a comment says so ("deliberate"). Startup failures
   `die()` with a message; degraded-but-usable situations `warn()` to stderr
   once; hardcoded constants (palettes) validate at init and crash on typos.
   Never coerce bad input into a default silently.
8. **Tests for important logic only.** The pure helpers in `ConspectusCore`
   (path resolution, parsing, ordering, mappings) are tested — normal, edge,
   and error cases. UI/AppKit/process code is not unit-tested. A small change
   to an existing function does not need a new dedicated test; changed
   behavior must update the affected existing tests. Run `swift test`.
9. **README stays in sync.** Read it before changing behavior; update it when
   a change makes it inaccurate.
10. **No linter.** Deliberately none (SwiftLint etc. not wanted). The bar is:
    `swift build` compiles without warnings, and `swift test` passes.
11. **Reuse before writing.** Check `ConspectusCore` for an existing helper
    (`isDirectory`, `nsColor`, …) before adding a new one; promote repeated
    logic there instead of duplicating it.
12. **Dependencies are a decision.** Ask before adding a package; record it in
    `Package.swift`. Currently two: SwiftTerm (the terminal) and Apple's
    swift-markdown (the markdown AST, approved 2026-07-25) — keep it at that
    unless there's a strong reason.

## Build & verify

```sh
./build.sh     # release build (what bin/conspectus runs)
swift build    # debug build — must be warning-free
swift test     # ConspectusCore unit tests — must pass
```
