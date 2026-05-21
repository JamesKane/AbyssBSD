# STATUS

Rolling change context for AbyssBSD. Kept short by design — see
[`docs/ROADMAP.md`](docs/ROADMAP.md) §7. Older history is `git log`; the
plan is the roadmap.

## Epic

**Phase 0 — workspace & CI harness.** Cargo workspace and the
`cargo xtask ci` lane (fmt, clippy, build, test) stood up and verified
green on the pinned Rust 1.95.0. No `crates/` yet — Gate A then Phase 1
next.

## Recent commits

*(≤10 most recent, newest first)*

- `c1d3fe5` site: add the Ecosystem statement page
- `a0784fe` Pin the FreeBSD base source (ROADMAP §6 resolved)
- `139c785` Update STATUS after merge to main
- `322d8ad` Add STATUS.md rolling change context
- `16c387b` Bootstrap project: docs cleanup, reorg, roadmap, toolchain, site
- `fc2596c` Initial Rust-fallback variant of the AbyssBSD design

## In flight

Nothing — working tree clean; the Phase 0 workspace commit is pending.

## Next

1. **Gate A** — write `docs/design/wire-format.md`: the envelope byte
   layout, the typed-value vocabulary, the derive-macro contract.
2. **Phase 1** — `abyss-msg` + `abyss-msg-derive`, the message primitive.
   First `crates/` members; CI starts exercising real code.

## Notes

- Work happens on `main` directly; feature branches only for a planned
  breaking refactor.
- A Forgejo remote is to be set up later — not yet configured.
