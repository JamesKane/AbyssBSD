# STATUS

Rolling change context for AbyssBSD. Kept short by design — see
[`docs/ROADMAP.md`](docs/ROADMAP.md) §7. Older history is `git log`; the
plan is the roadmap.

## Epic

**Project bootstrap.** Design docs cleaned up, roadmap and toolchain pin
established, project website added. No code yet — Gate A then Phase 0 next.

## Recent commits

*(≤10 most recent, newest first)*

- `16c387b` Bootstrap project: docs cleanup, reorg, roadmap, toolchain, site
- `fc2596c` Initial Rust-fallback variant of the AbyssBSD design

## In flight

- Work so far sits on the **`bootstrap`** branch, not merged to `main`.

## Next

1. Bring `bootstrap` onto `main` (fast-forward merge).
2. Resolve ROADMAP §6 — where the pinned FreeBSD 15.0 source lives
   (recommendation: in-tree submodule). Not needed until Phase 4.
3. **Gate A** — write `docs/design/wire-format.md` (before Phase 1).
4. **Phase 0** — scaffold the Cargo workspace and the macOS CI lane.
