# STATUS

Rolling change context for AbyssBSD. Kept short by design — see
[`docs/ROADMAP.md`](docs/ROADMAP.md) §7. Older history is `git log`; the
plan is the roadmap.

## Epic

**Window-management design gate** (done early, at the user's request).
`docs/design/window-management.md` written, elaborating `DESIGN.md` §7.7:
the window-management core, the layout-policy seam, the tiling layout
engine (pure geometry — host-testable), the floating policy, key-chords,
and the two coexisting experiences. Tiling is the first face (M1–M2); the
floating GNOME-2 desktop follows at M3. Added to `ROADMAP.md` §5 as
**Gate E**; the gate table re-lettered (display → F, render-backends → G,
schemas/login → H, install-update → I).

## Recent commits

*(≤10 most recent, newest first)*

- `366263c` Phase 2: the looper & service framework — abyss-looper & abyss-cap
- `198b5f3` Gate B: the looper & service framework design doc
- `3636807` Phase 1: the message primitive — abyss-msg & abyss-msg-derive
- `80510c3` Gate A: the wire-format design doc
- `b90c53b` Phase 0: Cargo workspace & CI harness
- `c1d3fe5` site: add the Ecosystem statement page
- `a0784fe` Pin the FreeBSD base source (ROADMAP §6 resolved)
- `139c785` Update STATUS after merge to main
- `322d8ad` Add STATUS.md rolling change context
- `16c387b` Bootstrap project: docs cleanup, reorg, roadmap, toolchain, site

## In flight

The window-management gate commit is pending. Working tree otherwise clean
— the parallel-process DESIGN.md / BACKLOG.md / site changes landed in
`9fb7995` and `a09fc9f`.

## Next

Implementation order resumes with **Gate C** — `docs/design/toolkit.md`
(the Interface Kit widget set, the layout algorithm, the arena/`ViewId`
API, the §7.3 drawing-API seam) — then **Phase 3**, the renderer and
toolkit core. The window-management gate (E) was designed ahead of its
Phase 5; the tiling layout engine can be built as a standalone, host-
tested crate whenever convenient, since it is pure geometry.

## Notes

- Work happens on `main` directly; feature branches only for a planned
  breaking refactor.
- A Forgejo remote is to be set up later — not yet configured.
