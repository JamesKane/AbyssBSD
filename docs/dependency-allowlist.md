# Dependency allowlist

`DESIGN.md` §3.2: the AbyssBSD layer takes no dependency without a
deliberate, recorded decision. **This file is that record.** A crate that
appears in a `Cargo.toml` and is not listed here is a mistake.

Tiers, by how much trust each placement demands:

- **runtime** — linked into a shipping AbyssBSD binary. Highest bar.
- **build** — runs only at build time (proc macros, codegen, `bindgen`).
  Never in a shipped binary.
- **dev** — used only by tests and benches. Never shipped.

## Allowed

| Crate | Version | Tier | Why |
|---|---|---|---|
| `proc-macro2` | 1 | build | Token plumbing for the `abyss-msg-derive` proc macro. |
| `quote` | 1 | build | Code generation for `#[derive(Wire)]`. |
| `syn` | 2 | build | Parsing derive input for `#[derive(Wire)]`. |
| `unicode-ident` | 1 | build | Transitive — Unicode identifier tables, pulled by `proc-macro2`. |

`proc-macro2` + `quote` + `syn` are the irreducible cost of having a derive
macro at all — and `DESIGN.md` §6.3 mandates derived typed views. They are
build-time only, never linked into a shipped binary — the same category as
`bindgen` (`ROADMAP.md` §2, pre-approved for Phase 4). One ecosystem-standard
trio, one maintainer, MIT/Apache-2.0. Their only transitive dependency is
`unicode-ident`; it rides in as part of that cost and is listed above so the
table matches `Cargo.lock` exactly. Four crates, all build-tier.

## Deliberately not used

- **A property-testing crate** (`proptest`, `quickcheck`). Phase 1's
  property and decoder-robustness tests use a hand-rolled seeded generator
  — ~40 lines, zero dependencies (`crates/abyss-msg/tests/common/`).
  Revisit only if hand-rolled generators become a real maintenance cost.
- **A coverage-guided fuzzer** (`cargo-fuzz` / libfuzzer). It needs a
  nightly toolchain; AbyssBSD is pinned to stable (`DESIGN.md` §3.1).
  Deterministic randomized no-panic tests run under stable in `cargo test`
  instead.
- **`trybuild`**, for derive compile-fail tests — deferred. The derive's
  accepted forms are covered by round-trip tests; its rejected forms emit
  `compile_error!` with a clear message, checked by reading.

## Pending

- `bindgen` (build tier) — FreeBSD header import, Phase 4. Noted by
  `ROADMAP.md` §2; added here when Phase 4 introduces the `sys/*` crates.
