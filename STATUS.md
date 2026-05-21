# STATUS

Rolling change context for AbyssBSD. Kept short by design — see
[`docs/ROADMAP.md`](docs/ROADMAP.md) §7. Older history is `git log`; the
plan is the roadmap.

## Epic

**Gate A — the wire format.** `docs/design/wire-format.md` written: the
nine-kind value vocabulary, the envelope byte layout, untrusted-input
decoding rules, and the `#[derive(Wire)]` contract. Phase 1 is now fully
specified and ready to build.

## Recent commits

*(≤10 most recent, newest first)*

- `b90c53b` Phase 0: Cargo workspace & CI harness
- `c1d3fe5` site: add the Ecosystem statement page
- `a0784fe` Pin the FreeBSD base source (ROADMAP §6 resolved)
- `139c785` Update STATUS after merge to main
- `322d8ad` Add STATUS.md rolling change context
- `16c387b` Bootstrap project: docs cleanup, reorg, roadmap, toolchain, site
- `fc2596c` Initial Rust-fallback variant of the AbyssBSD design

## In flight

Nothing — working tree clean; the Gate A doc commit is pending.

## Next

1. **Phase 1** — build `crates/abyss-msg` and `crates/abyss-msg-derive`
   per `docs/design/wire-format.md` §10: the `Value` codec, the envelope,
   the `Wire` trait, `#[derive(Wire)]`, and the full host test suite
   (round-trip, property, decoder fuzz, golden vectors, trybuild).
2. These are the first `crates/` members — CI begins exercising real code.

## Notes

- Work happens on `main` directly; feature branches only for a planned
  breaking refactor.
- A Forgejo remote is to be set up later — not yet configured.
