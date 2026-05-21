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

- `b0d5670` Phase 4: abyss-transport — the async IPC channel
- `bc3a12d` Bump STATUS: Phase 4 — the looper event-source seam
- `8466c49` Phase 4: abyss-looper — the event-source seam
- `5429aa8` Bump STATUS: Phase 4 — the framed connection
- `47a3d6b` Phase 4: abyss-transport — the framed connection
- `49655d8` Bump STATUS: Phase 4 — the kqueue reactor
- `812d46c` Phase 4: abyss-transport — the kqueue reactor
- `1bcb4eb` Bump STATUS: IPC ring design pass (broker-and-transport.md §2.5-2.7)
- `b772b49` Gate D refinement: the IPC ring, serialization, wire request/reply
- `e2d76de` Phase 4: abyss-transport — the envelope over the transport

## Site

`site/` is the project's static web presentation — seven pages: a landing
page, the vision and principles, the architecture, the component map, the
interface contracts, the ecosystem stance, and the five-milestone roadmap,
plus shared styling (`style.css`). It tracks `DESIGN.md` and is updated as
the design moves — last refreshed alongside the window-management,
screen-capture, and capability-coverage design work (`9fb7995`). It is a
presentation layer, deliberately outside the Cargo workspace.

## In flight

**Phase 4's FreeBSD remainder is in progress** — `crates/abyss-transport`
is the FreeBSD IPC and event substrate (`broker-and-transport.md` §2):

- `Channel` — a `SOCK_SEQPACKET` socket pair with `SCM_RIGHTS` fd-passing
  over a C cmsg shim;
- `MessageChannel` — a bare envelope per datagram (the bootstrap bundle);
- `RingFrame` / `FramedChannel` — the IPC ring's wire (§2.6): an 8-byte
  ring frame, with the correlation id, ahead of each envelope;
- `Reactor` / `ReactorSource` — the `kqueue` readiness reactor (§2.3),
  presented as an `abyss-looper` `EventSource`: a looper built on it is
  driven by the `kqueue` where the in-process backend used thread-park;
- `AsyncChannel` — a `FramedChannel` whose `recv`/`send` suspend the
  *task*, not the looper thread, when the socket would block.

A design pass first settled where this was under-specified — the Gate D
doc gained §2.5–§2.7 (`Interface::Message: Wire`; the IPC ring frame; the
`Responder`) — and `abyss-looper` gained the **`EventSource` seam** so a
non-thread-park backend can drive the looper (looper-framework §3.3). A
looper task now async-`recv`s a framed request and async-sends a reply,
verified end to end in the FreeBSD VM. `cargo xtask ci` green on macOS
and FreeBSD; working tree clean.

## Next

**The rest of Phase 4's FreeBSD remainder**, per
`docs/design/broker-and-transport.md`:

- the **request/reply layer** — the `Connection`: a correlation table,
  the demux receive loop, and the `Responder` (§2.7), over `AsyncChannel`
  — the next increment;
- the broker's jailed `pdfork` spawn, the bootstrap bundle, and the
  `cap_enter` startup shim (§5.3–§5.4), over the `sys/*` bindings;
- supervision and `PeerRestarted` re-wiring (§5.5);
- `Cap: Wire` — a capability delegated inside a message (§3.2, §3.4);

with the `sys/*` shims fleshed out and every FFI signature verified
against the FreeBSD headers as the broker exercises them.

The `freebsd-src` submodule (`ROADMAP.md` §6) is populated for that work.
This reaches the bulk of **M1**.
