# STATUS

Rolling change context for AbyssBSD. Kept short by design — see
[`docs/ROADMAP.md`](docs/ROADMAP.md) §7. Older history is `git log`; the
plan is the roadmap.

## Epic

**Phase 3 — rendering & toolkit core. Increment 2 of 3: text.**
`crates/abyss-font` binds the freetype + harfbuzz **ports** through a small
C shim (`c/font_shim.c`) — chosen over `bindgen` so freetype's struct
layouts stay in C. `build.rs` compiles the shim by invoking the system
toolchain (`cc`, `ar`) directly, so `abyss-font` has **zero
dependencies**; the FFI `unsafe` is confined there. `abyss-render` gained
text: a `RenderBackend::blit_coverage` mask op, a per-font `GlyphCache`,
and `Canvas::text` — and stays `#![forbid(unsafe_code)]`. 10 new tests
(6 font, 4 text) against real Monaco; 68 workspace-wide; `cargo xtask ci`
passes.

Phase 3 increments: **(1) `abyss-render` geometry [done]**, **(2) text
[done]**, (3) `abyss-toolkit` — the arena, layout, and widgets.

## Recent commits

*(≤10 most recent, newest first)*

- `f073994` Phase 3 (1/3): abyss-render — the 2D geometry renderer
- `551084a` Gate C: the toolkit design doc
- `1cc1cca` Gate E: the window-management design doc
- `366263c` Phase 2: the looper & service framework — abyss-looper & abyss-cap
- `198b5f3` Gate B: the looper & service framework design doc
- `3636807` Phase 1: the message primitive — abyss-msg & abyss-msg-derive
- `80510c3` Gate A: the wire-format design doc
- `b90c53b` Phase 0: Cargo workspace & CI harness
- `c1d3fe5` site: add the Ecosystem statement page
- `a0784fe` Pin the FreeBSD base source (ROADMAP §6 resolved)

## In flight

The Phase 3 increment-2 commit is pending. Working tree otherwise clean
(the parallel-process `docs/DESIGN.md` / `docs/BACKLOG.md` edits are far-
future / hole-filling and left to that process).

## Next

**Phase 3, increment 3 — `crates/abyss-toolkit`.** The arena and
generational `ViewId`, the retained view tree, the two-pass box layout,
the curated widget set, input routing and UI events, theming, and damage
tracking (`docs/design/toolkit.md` §4–§10). Host-testable on macOS. This
completes Phase 3.

The window-management gate (E) remains designed ahead of its Phase 5; the
tiling layout engine is pure geometry and can be built standalone whenever
convenient.

## Notes

- Work happens on `main` directly; feature branches only for a planned
  breaking refactor.
- A Forgejo remote is to be set up later — not yet configured.
