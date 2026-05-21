# STATUS

Rolling change context for AbyssBSD. Kept short by design — see
[`docs/ROADMAP.md`](docs/ROADMAP.md) §7. Older history is `git log`; the
plan is the roadmap.

## Epic

**Gate B — the looper & service framework.**
`docs/design/looper-framework.md` written: the looper and its cooperative
executor (run loop, per-handler serialization, wakers), the typed ring API
and transport seam, the request/reply call, the `abyss-cap` capability
layer (`Cap<I, R>`, phantom rights, `Cap: Wire`), and supervision. Phase 2
is now fully specified.

## Recent commits

*(≤10 most recent, newest first)*

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

The Gate B doc commit is pending. Parallel-process changes are also
uncommitted and untouched by me — `docs/DESIGN.md`, `docs/BACKLOG.md`,
`site/ecosystem.html`, `site/index.html`.

## Next

**Phase 2** — build `crates/abyss-looper` and `crates/abyss-cap` per
`docs/design/looper-framework.md` §11: the in-process ring, the looper and
executor, handlers, the call, `Cap<I, R>` with phantom rights, and the
host multi-looper test harness. Still host-testable on macOS — the
inter-process backend and the broker are Gate D.

## Notes

- Work happens on `main` directly; feature branches only for a planned
  breaking refactor.
- A Forgejo remote is to be set up later — not yet configured.
