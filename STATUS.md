# STATUS

Rolling change context for AbyssBSD. Kept short by design — see
[`docs/ROADMAP.md`](docs/ROADMAP.md) §7. Older history is `git log`; the
plan is the roadmap.

## Epic

**Phase 2 — the looper & service framework.** `crates/abyss-looper` (the
MPSC ring, the cooperative executor, `Handler`/`attach`, `block_on`) and
`crates/abyss-cap` (`Cap<I, R>`, phantom-typed rights, `narrow`, `call`)
built per `docs/design/looper-framework.md`. Both
`#![forbid(unsafe_code)]`, zero external deps. 15 tests green — ring
basics, cross-thread backpressure, call/reply, per-handler serialization,
concurrency between handlers, narrow (incl. a compile-fail doctest for
widening). 46 tests workspace-wide; `cargo xtask ci` passes. Build
refinements recorded in the framework doc §12.

## Recent commits

*(≤10 most recent, newest first)*

- `198b5f3` Gate B: the looper & service framework design doc
- `3636807` Phase 1: the message primitive — abyss-msg & abyss-msg-derive
- `80510c3` Gate A: the wire-format design doc
- `b90c53b` Phase 0: Cargo workspace & CI harness
- `c1d3fe5` site: add the Ecosystem statement page
- `a0784fe` Pin the FreeBSD base source (ROADMAP §6 resolved)
- `139c785` Update STATUS after merge to main
- `322d8ad` Add STATUS.md rolling change context
- `16c387b` Bootstrap project: docs cleanup, reorg, roadmap, toolchain, site
- `fc2596c` Initial Rust-fallback variant of the AbyssBSD design

## In flight

The Phase 2 commit is pending. Parallel-process changes remain uncommitted
and untouched by me — `docs/DESIGN.md`, `docs/BACKLOG.md`, and several
`site/` files.

## Next

**Gate C** — `docs/design/toolkit.md`: the toolkit architecture (the
Interface Kit widget set, the layout algorithm, the arena/`ViewId` API,
the §7.3 drawing-API seam). Design before Phase 3 builds the renderer and
toolkit core. Phase 3 is still host-testable on macOS.

## Notes

- Work happens on `main` directly; feature branches only for a planned
  breaking refactor.
- A Forgejo remote is to be set up later — not yet configured.
