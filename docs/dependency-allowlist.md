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
macro at all — and `DESIGN.md` §6.3 mandates derived typed views. One
ecosystem-standard trio, one maintainer, MIT/Apache-2.0; their only
transitive dependency is `unicode-ident`. Every crate here is **build-tier**
— none is linked into a shipped AbyssBSD binary. The table matches
`Cargo.lock` exactly.

**Not a crate dependency — the font stack.** `abyss-font` binds the
freetype and harfbuzz **ports** (`DESIGN.md` §11.2) through a C shim
(`crates/abyss-font/c/font_shim.c`). Its `build.rs` compiles the shim by
invoking the system toolchain directly — `cc` (clang on macOS and the
BSDs) and `ar` — and locates the libraries with `pkg-config`. The
toolchain and `pkg-config` are part of the build environment, not vendored
crates, so nothing is added to this table. `abyss-font` itself has no
dependencies, build or otherwise.

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

- **FreeBSD FFI binding** for the `sys/*` crates (Phase 4). `ROADMAP.md` §2
  noted `bindgen`; the font stack instead validated the **C-shim** approach
  — a small shim compiled by the system toolchain, no build crate, no
  `libclang`, no C struct layouts in Rust. Phase 4 chooses between the two
  when the `sys/*` crates land — whichever is recorded here then.
