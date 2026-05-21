# Acceleration register

Hot-path regions that may benefit from **SIMD** or **GPU** acceleration —
recorded as the project is built, so each can later be pulled into a
benchmark and measured (scalar vs accelerated) before any fast path is
committed.

This is the §3.5 review lens applied to performance: build the concrete
**scalar** thing first, measure, and accelerate only what measurement
proves hot (`DESIGN.md` §3.6). The register exists so "measure" has a
worklist; it is maintained as the project grows.

---

## Discipline

Three rules govern every acceleration path.

### 1. The scalar path is the floor; SIMD is an opt-in lane

RISC-V Vector (RVV) silicon only began shipping in the last few years. The
32-bit-degradability goal (`DESIGN.md` §3.6 — RV32, constrained and older
hardware) and the zero-GPU CPU-render floor (§7.1, §9) all must run with
**no vector unit at all**. Every SIMD path therefore *keeps* a complete
scalar fallback, selected at build or run time. **No region becomes
SIMD-only**, and no region becomes GPU-only — the GPU is an accelerated
backend behind a seam, never a requirement (§7.1).

### 2. Data-Oriented Design layout

Hot data is laid out as flat, contiguous arrays of primitives, so a SIMD
path loads lanes without gather or shuffle. Hot structs are `#[repr(C)]`
for a predictable, stated layout; explicit `#[repr(align(N))]` is added
where a benchmark shows aligned wide loads matter — not speculatively.

So far the hot buffers are already DOD-friendly and should stay so: the
`Pixmap`'s `Vec<Color>` (a flat 4-byte-per-pixel array) and the
rasterizer's `Vec<f32>` coverage accumulator. New hot structs are laid out
this way from the start — that is the cheap part; retrofitting is not.

### 3. Benchmark before adopting

A candidate is pulled into a benchmark — the scalar path against the SIMD
or GPU path — and the fast path is committed only if it wins on the
reference machine (`DESIGN.md` §5, §3.6). A SIMD path that does not beat
autovectorized scalar is deleted.

---

## Architecture targets

AbyssBSD distributes for **three architectures** — `x86_64`, `aarch64`
(ARM64), and `riscv64` (RV64). A SIMD fast lane is not written once; it is
written against three very different baselines, and rule 1 (a complete
scalar fallback, always) is what makes that tractable.

| Arch | Baseline SIMD | Guaranteed in the baseline ISA? | `core::arch` intrinsics |
|---|---|---|---|
| `x86_64` | SSE2 | yes — SSE2 is part of `x86_64` | stable; AVX2 needs runtime detection |
| `aarch64` | NEON | yes — NEON is mandatory in ARMv8 | stable |
| `riscv64` | **none** | **no — RVV is not in RV64GC** | **RVV intrinsics still unstable** |

RISC-V is the constraining case. The Vector extension (RVV) is **not part
of the RV64GC baseline**: a large share of the RV64 install base has no
vector unit at all, and the ones that do expose a *scalable*-vector ISA
that does not map onto a fixed-width hand-written kernel. This is the
concrete reason the scalar path is the floor — on RV64 it is frequently
the *only* path — and the reason a per-arch `core::arch` strategy cannot
cover all three targets today (the RISC-V vector intrinsics are not yet
stable). It also means within-arch fragmentation must be handled at
selection time: AVX2-vs-SSE2 on x86-64, and RVV-present-vs-absent on RV64.

The portability of `std::simd` — one kernel lowering to SSE2 / NEON / RVV —
is therefore worth the most *here*, of all the places it could matter; see
below for why it is still not adopted.

---

## `std::simd` maturity

Portable SIMD (`core::simd` / `std::simd`) is **nightly-only** — gated
behind `#![feature(portable_simd)]`, and **not stabilized as of early
2026**. AbyssBSD is pinned to **stable** Rust (`DESIGN.md` §3.1), so
`std::simd` is **not available today**.

The stable options until it stabilizes:

- **Autovectorization** — let LLVM vectorize simple scalar loops. Free, no
  `unsafe`; but unreliable across compiler versions and shapes. A bonus,
  never the plan.
- **`core::arch` intrinsics** — per-architecture, `unsafe`, kept behind a
  seam. The x86-64 and aarch64 intrinsics are stable; the RISC-V Vector
  intrinsics are themselves still being stabilized — a further reason
  rule 1 holds.

**Policy.** Scalar now. Revisit `std::simd` when it stabilizes — it then
becomes the preferred way to write a fast lane (one portable path instead
of per-arch intrinsics, and far less `unsafe`). Until then, a
measurement-proven hot region may take a `core::arch` fast lane in a
contained module, always behind the scalar fallback (rule 1). Tracked in
`TECH-DEBT.md` as a watch item.

---

## Candidates

Recorded as encountered. **None is accelerated yet** — all are scalar,
correct, and within budget so far (§3.5).

| Region | Where | Why it is hot | Candidate | Fallback |
|---|---|---|---|---|
| Path fill — coverage accumulation & span filling | `abyss-render` `cpu.rs::fill` | per-scanline inner loops over every covered pixel | SIMD over coverage lanes | scalar (current) |
| Pixel compositing — source-over | `abyss-render` `color.rs::over`, in the fill & blit loops | runs once per painted pixel | SIMD 4–8 px/iter; or the **GLES backend** — the render-backend seam (`DESIGN.md` §7.1, Gate G) is the headline acceleration | CPU scalar |
| Glyph blit — mask × color composite | `abyss-render` `cpu.rs::blit_coverage` | per pixel of every glyph, every frame with text | SIMD over the coverage mask | scalar (current) |
| Gradient evaluation | `abyss-render` `paint.rs::eval` | per pixel of a gradient fill | SIMD over pixel lanes | scalar (current) |

**On the horizon** (not yet built): the compositor's screen composite
(Phase 5) is the largest acceleration target — and the design already
answers it, with GPU compositing and managed direct scanout (`DESIGN.md`
§7.4, §7.1). The render-backend seam means the GPU path is an
architecture choice, not a retrofit.
