# STATUS

Rolling change context for AbyssBSD. Kept short by design — see
[`docs/ROADMAP.md`](docs/ROADMAP.md) §7. Older history is `git log`; the
plan is the roadmap.

## Epic

**Gate C — the toolkit design.** `docs/design/toolkit.md` written,
elaborating `DESIGN.md` §7.3 and §8: the 2D renderer and its CPU/GLES
backend seam, the view arena and generational `ViewId`, the retained view
tree, the two-pass box layout, the curated widget set, the no-callbacks
event model, theming, and damage tracking. Phase 3 (`abyss-render`,
`abyss-toolkit`) is now fully specified — and host-testable on macOS (CPU
rendering into a memory buffer, golden images).

## Recent commits

*(≤10 most recent, newest first)*

- `1cc1cca` Gate E: the window-management design doc
- `366263c` Phase 2: the looper & service framework — abyss-looper & abyss-cap
- `198b5f3` Gate B: the looper & service framework design doc
- `3636807` Phase 1: the message primitive — abyss-msg & abyss-msg-derive
- `80510c3` Gate A: the wire-format design doc
- `b90c53b` Phase 0: Cargo workspace & CI harness
- `c1d3fe5` site: add the Ecosystem statement page
- `a0784fe` Pin the FreeBSD base source (ROADMAP §6 resolved)
- `139c785` Update STATUS after merge to main
- `322d8ad` Add STATUS.md rolling change context

## In flight

The Gate C doc commit is pending. Working tree otherwise clean.

## Next

**Phase 3** — build `crates/abyss-render` (the `Canvas`, the
`RenderBackend` seam, the CPU backend, the font-stack FFI) and
`crates/abyss-toolkit` (the arena/`ViewId`, the retained tree, layout, the
widget set, theming, damage) per `docs/design/toolkit.md` §12. Fully
host-testable on macOS. A Phase-3 opening task: add `bindgen` and the font
libraries to `docs/dependency-allowlist.md` (§3.3 of the toolkit doc).

The window-management gate (E) remains designed ahead of its Phase 5; the
tiling layout engine is pure geometry and can be built standalone whenever
convenient.

## Notes

- Work happens on `main` directly; feature branches only for a planned
  breaking refactor.
- A Forgejo remote is to be set up later — not yet configured.
