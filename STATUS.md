# STATUS

Rolling change context for AbyssBSD. Kept short by design — see
[`docs/ROADMAP.md`](docs/ROADMAP.md) §7. Older history is `git log`; the
plan is the roadmap.

## Epic

**Project bootstrap.** Design docs cleaned up, roadmap and toolchain pin
established, project website added. No code yet — Gate A then Phase 0 next.

## Recent commits

*(≤10 most recent, newest first)*

- `139c785` Update STATUS after merge to main
- `322d8ad` Add STATUS.md rolling change context
- `16c387b` Bootstrap project: docs cleanup, reorg, roadmap, toolchain, site
- `fc2596c` Initial Rust-fallback variant of the AbyssBSD design

## In flight

Nothing — working tree clean.

## Next

1. **Gate A** — write `docs/design/wire-format.md` (before Phase 1).
2. **Phase 0** — scaffold the Cargo workspace and the macOS CI lane.

ROADMAP §6 is resolved: the FreeBSD 15.0 source is an in-tree submodule at
`third_party/freebsd-src`, pinned to `releng/15.0` (15.0-RELEASE-p9),
populated on demand at Phase 4.

## Notes

- Work happens on `main` directly; feature branches only for a planned
  breaking refactor.
- A Forgejo remote is to be set up later — not yet configured.
