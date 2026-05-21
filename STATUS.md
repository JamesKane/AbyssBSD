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

- `b772b49` Gate D refinement: the IPC ring, serialization, wire request/reply
- `e2d76de` Phase 4: abyss-transport — the envelope over the transport
- `23b2bec` ci: install a DejaVu font for the Linux test step
- `454d518` Bump STATUS: Phase 4 FreeBSD remainder, increment 1 (abyss-transport)
- `ea2b569` Phase 4: abyss-transport — the SOCK_SEQPACKET transport
- `a0f13b0` ci: add a FreeBSD job that runs the test suite in a VM
- `1b5dcf3` ci: install freetype and harfbuzz on the runner
- `e8712f9` Bump STATUS: the FreeBSD VM builds the workspace green
- `82c1469` tools/vm: add `provision` — reproducible VM package set
- `de9be9d` abyss-cap: make the concurrency harness test deterministic

## Site

`site/` is the project's static web presentation — seven pages: a landing
page, the vision and principles, the architecture, the component map, the
interface contracts, the ecosystem stance, and the five-milestone roadmap,
plus shared styling (`style.css`). It tracks `DESIGN.md` and is updated as
the design moves — last refreshed alongside the window-management,
screen-capture, and capability-coverage design work (`9fb7995`). It is a
presentation layer, deliberately outside the Cargo workspace.

## In flight

**Phase 4's FreeBSD remainder — the transport built, the IPC-ring
design settled.** `crates/abyss-transport` is the inter-process transport
(`broker-and-transport.md` §2): a `SOCK_SEQPACKET` socket pair with
`SCM_RIGHTS` fd-passing over a C cmsg shim (`Channel`), and the envelope
framing on top (`MessageChannel`) — one datagram carries one encoded
envelope plus its handles' descriptors. Built and tested in the FreeBSD
VM (`tools/vm/vm.sh build`); `cargo xtask ci` green on macOS and FreeBSD.
Working tree clean.

A design pass then resolved where increment 3 was under-specified —
how `Cap` reconciles its in-process and IPC backends. The Gate D doc
gains §2.5–§2.7: `Interface::Message: Wire`; the IPC ring frame (a
correlation id outside the envelope); and wire request/reply via a
`Responder`, superseding the embedded-`Sender` `call`.

The dev loop is settled: edit on macOS, `vm.sh build` runs the full
`cargo xtask ci` in the FreeBSD guest.

## Next

**The rest of Phase 4's FreeBSD remainder**, per
`docs/design/broker-and-transport.md`:

- the **IPC ring backend** — `Cap`/looper over a `SOCK_SEQPACKET`
  connection, the ring frame, correlation, the `Responder`, and the
  `kqueue` event source (§2.3, §2.5–§2.7) — the next increment;
- the broker's jailed `pdfork` spawn, the bootstrap bundle, and the
  `cap_enter` startup shim (§5.3–§5.4), over the `sys/*` bindings;
- supervision and `PeerRestarted` re-wiring (§5.5);
- `Cap: Wire` — a capability delegated inside a message (§3.2, §3.4);

with the `sys/*` shims fleshed out and every FFI signature verified
against the FreeBSD headers as the broker exercises them.

The `freebsd-src` submodule (`ROADMAP.md` §6) is populated for that work.
This reaches the bulk of **M1**.
