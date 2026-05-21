# STATUS

Rolling change context for AbyssBSD. Kept short by design — see
[`docs/ROADMAP.md`](docs/ROADMAP.md) §7. Older history is `git log`; the
plan is the roadmap.

## Epic

**Gate D — the broker & transport design.**
`docs/design/broker-and-transport.md` written, elaborating `DESIGN.md`
§6.2/§6.4, §10, §11.9: the `SOCK_SEQPACKET` IPC ring transport (the
envelope as wire frame, `SCM_RIGHTS` for fds, a `kqueue` event loop), how
capabilities cross a process boundary (every capability is an fd; the
handle-table body layout; the object-rights → `cap_rights_t` mapping),
the component manifest, the broker (jailed `pdfork` spawn, the bootstrap
bundle, `cap_enter`, supervision and re-wiring), and the `sys/*` C-shim
FFI. It also resolves the IPC-backend and `Cap: Wire` items deferred from
Gates A and B. Phase 4 — the first FreeBSD work — is now fully specified.

Phases 0–3 (the host-buildable layer — 7 crates, 78 tests) remain done;
the project is BSD-2-Clause licensed.

## Recent commits

*(≤10 most recent, newest first)*

- `d8e3ef7` Bump STATUS: Phases 0-3 done, registers, license, site
- `6d868e8` docs: record the multi-arch SIMD constraint in the acceleration register
- `0acf55e` Apply the BSD 2-Clause license
- `370c1b2` docs: add the acceleration register and the tech-debt list
- `fd0bddb` Phase 3 (3/3): abyss-toolkit — the Interface Kit
- `306abfd` abyss-font: per-Font freetype library — fix a data race
- `f931937` Phase 3 (2/3): text — abyss-font and Canvas::text
- `0ce5c78` Expand scripting/automation design, grow the backlog, browser spec
- `f073994` Phase 3 (1/3): abyss-render — the 2D geometry renderer
- `551084a` Gate C: the toolkit design doc

## Site

`site/` is the project's static web presentation — seven pages: a landing
page, the vision and principles, the architecture, the component map, the
interface contracts, the ecosystem stance, and the five-milestone roadmap,
plus shared styling (`style.css`). It tracks `DESIGN.md` and is updated as
the design moves — last refreshed alongside the window-management,
screen-capture, and capability-coverage design work (`9fb7995`). It is a
presentation layer, deliberately outside the Cargo workspace.

## In flight

The Gate D doc commit is pending. Working tree otherwise clean.

## Next

**Phase 4 — the first FreeBSD work** (`ROADMAP.md` §4), per
`docs/design/broker-and-transport.md` §7:

- extend `abyss-looper` with the `kqueue` event loop and the
  `SOCK_SEQPACKET` ring backend; add `Cap: Wire` to `abyss-cap`;
- build `crates/abyss-broker` and `sys/freebsd-{capsicum,jail,procdesc}-sys`;
- on an **amd64 FreeBSD 15.0 VM** — the first FreeBSD environment.

Phase 4 first populates the in-tree `freebsd-src` submodule
(`git submodule update --init --filter=tree:0`, `ROADMAP.md` §6) for the
`sys/*` C-shim headers. It reaches the bulk of **M1**.
