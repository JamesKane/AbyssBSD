# STATUS

Rolling change context for AbyssBSD. Kept short by design — see
[`docs/ROADMAP.md`](docs/ROADMAP.md) §7. Older history is `git log`; the
plan is the roadmap.

## Epic

**Phase 4 — the broker, host slice.** Phase 4 is the first FreeBSD work,
the boundary the roadmap was ordered around. Its FreeBSD-independent
parts are built and tested on the macOS dev bed; the rest waits on a
FreeBSD environment (see Next).

- `crates/abyss-broker` — the broker's FreeBSD-independent core. The
  `manifest` parser: the component-manifest schema and its fixed-schema
  declarative text format, a first-party parser with no vendored config
  crate (`broker-and-transport.md` §4). The `graph` module: the static
  authority graph — components, and the connections between them —
  computed and validated from a manifest set (§5.2). 23 tests, no `unsafe`.
- `sys/freebsd-{capsicum,jail,procdesc}-sys` — the FreeBSD FFI crates,
  scaffolded (§6). Capsicum carries a C shim (its rights API is C macros);
  jail and procdesc are direct `extern` blocks. Each is gated on
  `target_os = "freebsd"` and compiles to an empty library on macOS.

The workspace is now eight `crates/` + three `sys/` + `xtask`; 101 tests,
`cargo xtask ci` green. Gate D (`docs/design/broker-and-transport.md`)
specifies the FreeBSD remainder.

## Recent commits

*(≤10 most recent, newest first)*

- `1f21b09` Phase 4 (3/3): the sys/* FreeBSD FFI crate scaffolding
- `b7e82c7` Phase 4 (2/3): abyss-broker — the authority graph
- `ee362c1` Phase 4 (1/3): abyss-broker — the manifest parser
- `6a17d3a` Gate D: the broker & transport design doc
- `d8e3ef7` Bump STATUS: Phases 0-3 done, registers, license, site
- `6d868e8` docs: record the multi-arch SIMD constraint in the acceleration register
- `0acf55e` Apply the BSD 2-Clause license
- `370c1b2` docs: add the acceleration register and the tech-debt list
- `fd0bddb` Phase 3 (3/3): abyss-toolkit — the Interface Kit
- `306abfd` abyss-font: per-Font freetype library — fix a data race

## Site

`site/` is the project's static web presentation — seven pages: a landing
page, the vision and principles, the architecture, the component map, the
interface contracts, the ecosystem stance, and the five-milestone roadmap,
plus shared styling (`style.css`). It tracks `DESIGN.md` and is updated as
the design moves — last refreshed alongside the window-management,
screen-capture, and capability-coverage design work (`9fb7995`). It is a
presentation layer, deliberately outside the Cargo workspace.

## In flight

Nothing — working tree clean. The Phase 4 host slice is committed; the
FreeBSD remainder is blocked on a FreeBSD environment (see Next).

## Next

**The FreeBSD remainder of Phase 4** — everything that needs a FreeBSD
kernel, per `docs/design/broker-and-transport.md` §7. It requires a
FreeBSD environment, which the macOS dev bed cannot provide (no
`SOCK_SEQPACKET`, Capsicum, jails, or `pdfork`) and which is not yet
provisioned:

- the `SOCK_SEQPACKET` ring transport with `SCM_RIGHTS` fd-passing, and
  the `kqueue` event loop in `abyss-looper` (§2);
- `Cap: Wire` in `abyss-cap` (§3.4);
- the broker's jailed `pdfork` spawn, the bootstrap bundle, the
  `cap_enter` startup shim, and supervision (§5.3–§5.7) — wiring the
  manifest parser and authority graph to the `sys/*` bindings;
- verifying the `sys/*` shims and FFI signatures against the FreeBSD
  headers.

The path: provision a FreeBSD 15.0 VM under QEMU, or build on a FreeBSD
box. The `freebsd-src` submodule (`ROADMAP.md` §6) is populated then.
This reaches the bulk of **M1**.
