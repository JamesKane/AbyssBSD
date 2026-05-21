# STATUS

Rolling change context for AbyssBSD. Kept short by design — see
[`docs/ROADMAP.md`](docs/ROADMAP.md) §7. Older history is `git log`; the
plan is the roadmap.

## Epic

**Phase 4 — the broker, host slice.** Phase 4 is the first FreeBSD work,
the boundary the roadmap was ordered around. Its FreeBSD-independent
parts are built and tested on the macOS dev bed; the FreeBSD environment
for the rest now exists (`tools/vm`, see In flight).

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

- `82c1469` tools/vm: add `provision` — reproducible VM package set
- `de9be9d` abyss-cap: make the concurrency harness test deterministic
- `3412381` Build the workspace in the FreeBSD VM: source sync, MSRV
- `505977a` Bump STATUS: the FreeBSD development VM is up
- `402271e` Add tools/vm: the FreeBSD development VM
- `56664e8` ci: add the GitHub Actions pipeline and README status badge
- `e3893ba` site: link the site to the GitHub source
- `c6eb968` docs: prepare README for a public push
- `1850903` site: add the Governance page and nav entry
- `cedb430` governance: add the RFC and adoption process

## Site

`site/` is the project's static web presentation — seven pages: a landing
page, the vision and principles, the architecture, the component map, the
interface contracts, the ecosystem stance, and the five-milestone roadmap,
plus shared styling (`style.css`). It tracks `DESIGN.md` and is updated as
the design moves — last refreshed alongside the window-management,
screen-capture, and capability-coverage design work (`9fb7995`). It is a
presentation layer, deliberately outside the Cargo workspace.

## In flight

Working tree clean. **The FreeBSD VM builds the workspace green.**
`tools/vm` runs a FreeBSD 15.0-RELEASE-p9 aarch64 guest (QEMU + HVF,
native speed); `./tools/vm/vm.sh build` syncs the working tree and runs
the full `cargo xtask ci` in the guest, which passes — fmt, clippy,
build, every test — for the whole workspace, the `sys/*` FFI crates now
compiled against real FreeBSD kernel headers (the Capsicum C shim, the
`jail` and `procdesc` `extern` blocks). The dev loop for the FreeBSD
remainder of Phase 4 is in place: edit on macOS, `vm.sh build` on FreeBSD.

## Next

**The FreeBSD remainder of Phase 4** — the code that needs a FreeBSD
kernel, per `docs/design/broker-and-transport.md` §7, now that the VM
builds and tests the workspace:

- the `SOCK_SEQPACKET` ring transport with `SCM_RIGHTS` fd-passing, and
  the `kqueue` event loop in `abyss-looper` (§2);
- `Cap: Wire` in `abyss-cap` (§3.4);
- the broker's jailed `pdfork` spawn, the bootstrap bundle, the
  `cap_enter` startup shim, and supervision (§5.3–§5.7) — wiring the
  manifest parser and authority graph to the `sys/*` bindings;
- fleshing out the `sys/*` shims and verifying every FFI signature
  against the FreeBSD headers as the broker exercises them.

The `freebsd-src` submodule (`ROADMAP.md` §6) is populated for that work.
This reaches the bulk of **M1**.
