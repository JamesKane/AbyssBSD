# STATUS

Rolling change context for AbyssBSD. Kept short by design — see
[`docs/ROADMAP.md`](docs/ROADMAP.md) §7. Older history is `git log`; the
plan is the roadmap.

## Epic

**Phase 3 — rendering & toolkit core. Increment 1 of 3: `abyss-render`
(geometry).** `crates/abyss-render` built per `docs/design/toolkit.md` §3 —
the NanoVG-style `Canvas`, the `RenderBackend` seam, and a CPU backend: a
software anti-aliased rasterizer (analytic-X, 4×-supersampled-Y), with
paths/curves, solid and gradient paints, rectangular clipping, and
source-over compositing. `#![forbid(unsafe_code)]`, zero external deps. 12
tests green — crisp integer fills, anti-aliased fractional edges,
triangles, rounded rects, gradients, clipping, both winding rules. 58
workspace-wide; `cargo xtask ci` passes.

Phase 3 is large — split into increments: **(1) `abyss-render` geometry
[done]**, (2) text — the font-stack FFI and glyph atlas, (3)
`abyss-toolkit` — the arena, layout, and widgets.

## Recent commits

*(≤10 most recent, newest first)*

- `551084a` Gate C: the toolkit design doc
- `1cc1cca` Gate E: the window-management design doc
- `366263c` Phase 2: the looper & service framework — abyss-looper & abyss-cap
- `198b5f3` Gate B: the looper & service framework design doc
- `3636807` Phase 1: the message primitive — abyss-msg & abyss-msg-derive
- `80510c3` Gate A: the wire-format design doc
- `b90c53b` Phase 0: Cargo workspace & CI harness
- `c1d3fe5` site: add the Ecosystem statement page
- `a0784fe` Pin the FreeBSD base source (ROADMAP §6 resolved)
- `139c785` Update STATUS after merge to main

## In flight

The Phase 3 increment-1 commit is pending. Working tree otherwise clean.

## Next

**Phase 3, increment 2 — text.** Add the font-stack FFI
(freetype/harfbuzz/fontconfig) and a glyph atlas to `abyss-render`, so the
`Canvas` gains a `text` API (`docs/design/toolkit.md` §3.3). This is the
point where `bindgen` and the font libraries are added to
`docs/dependency-allowlist.md`. Then increment 3: `crates/abyss-toolkit` —
the arena/`ViewId`, retained tree, two-pass layout, widget set, theming,
and damage (toolkit doc §4–§10).

The window-management gate (E) remains designed ahead of its Phase 5; the
tiling layout engine is pure geometry and can be built standalone whenever
convenient.

## Notes

- Work happens on `main` directly; feature branches only for a planned
  breaking refactor.
- A Forgejo remote is to be set up later — not yet configured.
