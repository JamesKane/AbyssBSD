# STATUS

Rolling change context for AbyssBSD. Kept short by design — see
[`docs/ROADMAP.md`](docs/ROADMAP.md) §7. Older history is `git log`; the
plan is the roadmap.

## Epic

**Phases 0–3 complete — the host-buildable layer is done.** Seven crates —
the message primitive (`abyss-msg`, `abyss-msg-derive`), the looper &
service framework (`abyss-looper`, `abyss-cap`), the 2D renderer
(`abyss-render`), the font stack (`abyss-font`), and the toolkit
(`abyss-toolkit`) — 78 tests, `cargo xtask ci` green, zero runtime
dependencies, all building and testing on macOS with no FreeBSD.

Since Phase 3: two registers added — `docs/acceleration.md` (SIMD/GPU
hot-path candidates, with the multi-arch / RVV constraints) and
`docs/TECH-DEBT.md` (corrections owed) — and the project is licensed
**BSD 2-Clause**, with an SPDX header on every source file.

## Recent commits

*(≤10 most recent, newest first)*

- `6d868e8` docs: record the multi-arch SIMD constraint in the acceleration register
- `0acf55e` Apply the BSD 2-Clause license
- `370c1b2` docs: add the acceleration register and the tech-debt list
- `fd0bddb` Phase 3 (3/3): abyss-toolkit — the Interface Kit
- `306abfd` abyss-font: per-Font freetype library — fix a data race
- `f931937` Phase 3 (2/3): text — abyss-font and Canvas::text
- `0ce5c78` Expand scripting/automation design, grow the backlog, browser spec
- `f073994` Phase 3 (1/3): abyss-render — the 2D geometry renderer
- `551084a` Gate C: the toolkit design doc
- `1cc1cca` Gate E: the window-management design doc

## Site

`site/` is the project's static web presentation — seven pages: a landing
page, the vision and principles, the architecture, the component map, the
interface contracts, the ecosystem stance, and the five-milestone roadmap,
plus shared styling (`style.css`). It tracks `DESIGN.md` and is updated as
the design moves — last refreshed alongside the window-management,
screen-capture, and capability-coverage design work (`9fb7995`). It is a
presentation layer, deliberately outside the Cargo workspace.

## In flight

Nothing — working tree clean.

## Next

The next phase is the **first FreeBSD work**, so it is gated:

1. **Gate D** — `docs/design/broker-and-transport.md`: the manifest
   schema, the spawn/bundle protocol, `SOCK_SEQPACKET` framing, the
   object-rights → `cap_rights_t` mapping (`ROADMAP.md` §5).
2. **Phase 4** — `crates/abyss-broker` and the `sys/*` FFI crates, on an
   amd64 FreeBSD 15.0 VM (`ROADMAP.md` §4). Here the in-tree `freebsd-src`
   submodule is first populated (`ROADMAP.md` §6).
