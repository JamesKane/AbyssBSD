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

**Not a crate dependency — the `sys/*` FreeBSD FFI.** The Phase 4 `sys/*`
crates bind FreeBSD kernel facilities. `freebsd-capsicum-sys` carries a C
shim (`c/capsicum_shim.c`), because Capsicum's `cap_rights_*` API is built
from C macros that cannot be called over Rust's FFI; `freebsd-jail-sys`
and `freebsd-procdesc-sys` are direct `extern` blocks over ordinary libc
functions. This resolves the binding question `ROADMAP.md` §2 raised
against `bindgen`: the C-shim approach the font stack validated is used —
no `bindgen`, no `libclang`, no C struct layouts transcribed into Rust.
No `sys/*` crate has a crate dependency, build or otherwise.

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
- **An ecosystem logging crate** (`log`, `tracing`, `env_logger`). Logging
  is the first-party `abyss-log` crate — five levels, five macros, one
  line format, zero dependencies (`crates/abyss-log`). `tracing` pulls a
  broad dependency tree; `log` is only a facade and still needs a separate
  backend. A small first-party crate gives the project the consistency it
  needs without spending the dependency budget (`DESIGN.md` §3.2).
