# STATUS

Rolling change context for AbyssBSD. Kept short by design — see
[`docs/ROADMAP.md`](docs/ROADMAP.md) §7. Older history is `git log`; the
plan is the roadmap.

## Epic

**Phase 1 — the message primitive.** `crates/abyss-msg` (value codec,
envelope, the `Wire` trait — zero deps, `#![forbid(unsafe_code)]`) and
`crates/abyss-msg-derive` (`#[derive(Wire)]`) built per
`docs/design/wire-format.md`. 31 tests green — round-trip, golden vectors,
randomized decoder robustness, derive coverage. First external deps
(`syn`/`quote`/`proc-macro2`, build-tier) recorded in
`docs/dependency-allowlist.md`.

## Recent commits

*(≤10 most recent, newest first)*

- `80510c3` Gate A: the wire-format design doc
- `b90c53b` Phase 0: Cargo workspace & CI harness
- `c1d3fe5` site: add the Ecosystem statement page
- `a0784fe` Pin the FreeBSD base source (ROADMAP §6 resolved)
- `139c785` Update STATUS after merge to main
- `322d8ad` Add STATUS.md rolling change context
- `16c387b` Bootstrap project: docs cleanup, reorg, roadmap, toolchain, site
- `fc2596c` Initial Rust-fallback variant of the AbyssBSD design

## In flight

Nothing — working tree clean; the Phase 1 commit is pending.

## Next

1. **Gate B** — `docs/design/looper-framework.md`: the looper & service
   framework design (executor internals, ring API, `RingCap` &
   supervision, the `Wire`-trait integration). The §6.10 "chief
   structural piece" — design before Phase 2 builds it.
2. **Phase 2** — `crates/abyss-looper` and `crates/abyss-cap`, on the
   in-process ring (still host-testable).

## Notes

- Work happens on `main` directly; feature branches only for a planned
  breaking refactor.
- A Forgejo remote is to be set up later — not yet configured.
