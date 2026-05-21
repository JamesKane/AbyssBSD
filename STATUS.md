# STATUS

Rolling change context for AbyssBSD. Kept short by design — see
[`docs/ROADMAP.md`](docs/ROADMAP.md) §7. Older history is `git log`; the
plan is the roadmap.

## Epic

**Phase 3 — rendering & toolkit core: COMPLETE.** Increment 3,
`crates/abyss-toolkit`, finishes Phase 3 (`docs/design/toolkit.md`
§4–§10): the view arena with generational `ViewId`s, the retained view
tree, the two-pass box layout, a representative widget set (`Linear`,
`Label`, `Button`), input routing → `UiEvent`s, the `Theme`, and damage
tracking. `#![forbid(unsafe_code)]`. 10 tests — generational handles,
column layout, click → `Clicked`, damage, typed widget access, a button
visibly changing on press. 78 workspace-wide; `cargo xtask ci` passes.

CI caught a real bug — a data race in the font shim's shared freetype
library — fixed (`306abfd`) with a per-`Font` library.

The remaining `docs/design/toolkit.md` §7 widgets are mechanical
population on the same `Widget` interface, done as the M3 desktop and M4
apps need them.

## Recent commits

*(≤10 most recent, newest first)*

- `306abfd` abyss-font: per-Font freetype library — fix a data race
- `f931937` Phase 3 (2/3): text — abyss-font and Canvas::text
- `f073994` Phase 3 (1/3): abyss-render — the 2D geometry renderer
- `551084a` Gate C: the toolkit design doc
- `1cc1cca` Gate E: the window-management design doc
- `366263c` Phase 2: the looper & service framework — abyss-looper & abyss-cap
- `198b5f3` Gate B: the looper & service framework design doc
- `3636807` Phase 1: the message primitive — abyss-msg & abyss-msg-derive
- `80510c3` Gate A: the wire-format design doc
- `b90c53b` Phase 0: Cargo workspace & CI harness

## In flight

The Phase 3 increment-3 commit is pending. Working tree otherwise clean.

## Next

Phases 0–3 are done — the host-buildable layer is complete (message
primitive, looper/service framework, renderer, font stack, toolkit; 78
tests). The next phase is the **first FreeBSD work**, so it is gated:

1. **Gate D** — `docs/design/broker-and-transport.md`: the manifest
   schema, the spawn/bundle protocol, `SOCK_SEQPACKET` framing, the
   object-rights → `cap_rights_t` mapping (`ROADMAP.md` §5).
2. **Phase 4** — `crates/abyss-broker` and `sys/*`, on an amd64 FreeBSD
   15.0 VM (`ROADMAP.md` §4). This is where the in-tree `freebsd-src`
   submodule is first populated (ROADMAP §6).

The window-management gate (E) remains designed ahead of its Phase 5; the
tiling layout engine is pure geometry and can be built standalone whenever
convenient.

## Notes

- Work happens on `main` directly; feature branches only for a planned
  breaking refactor.
- A Forgejo remote is to be set up later — not yet configured.
