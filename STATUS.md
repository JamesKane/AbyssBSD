# STATUS

Rolling change context for AbyssBSD. Kept short by design — see
[`docs/ROADMAP.md`](docs/ROADMAP.md) §7. Older history is `git log`; the
plan is the roadmap.

## Epic

**Phase 4 — the broker, host slice.** Phase 4 is the first FreeBSD work,
the boundary the roadmap was ordered around. Its FreeBSD-independent
parts are built and tested on the macOS dev bed; the FreeBSD environment
for the rest now exists (`tools/vm`, see In flight).

- `crates/abyss-broker` — the broker. Its host slice: the `manifest`
  parser — the component-manifest schema and its fixed-schema declarative
  text format, a first-party parser with no vendored config crate
  (`broker-and-transport.md` §4) — and the `graph` module, the static
  authority graph computed and validated from a manifest set (§5.2). And,
  on FreeBSD, the `spawn` module — component spawn (§5.3); see In flight.
  No `unsafe`.
- `sys/freebsd-{capsicum,jail,procdesc}-sys` — the FreeBSD FFI crates (§6),
  all three now built out and VM-verified. Capsicum and procdesc carry C
  shims (Capsicum's rights API is C macros; procdesc's `pdfork`-then-`exec`
  must run in C); jail is a direct `extern` block. Each is gated on
  `target_os = "freebsd"` and compiles to an empty library on macOS.

The workspace is nine `crates/` + three `sys/` + `xtask`, `cargo xtask
ci` green. Gate D (`docs/design/broker-and-transport.md`) specifies the
FreeBSD remainder.

## Recent commits

*(≤10 most recent, newest first)*

- `69a02d7` Phase 4: abyss-transport — kqueue process-descriptor exit monitoring
- `210e7f6` Bump STATUS: Phase 4 — the cap_enter startup shim
- `a0f5ade` Phase 4: abyss-bootstrap — the cap_enter startup shim
- `c83943d` Bump STATUS: Phase 4 — the broker component spawn module
- `9c85f9e` Phase 4: abyss-broker — the FreeBSD component spawn module
- `d325451` Bump STATUS: Phase 4 — the bootstrap fd in the spawn
- `baf68eb` Phase 4: freebsd-procdesc-sys — the bootstrap fd in the spawn
- `8bb3a9b` Bump STATUS: Phase 4 — the jail around the spawn
- `4e86395` Phase 4: the jail around the spawn — verified jail-sys, jailed spawn
- `ff7dd78` Bump STATUS: Phase 4 — the pdfork-based spawn

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
  *task*, not the looper thread, when the socket would block;
- `Connection` — the request/reply protocol (§2.7): `call` correlates a
  request with its reply by id; `serve` routes replies to callers and
  inbound messages to an `Inbox`; `accept` lifts a request off it with a
  `Responder` to answer it. **The IPC ring is complete.**

A design pass first settled where this was under-specified — the Gate D
doc gained §2.5–§2.7 (`Interface::Message: Wire`; the IPC ring frame; the
`Responder`) — and `abyss-looper` gained the **`EventSource` seam** so a
non-thread-park backend can drive the looper (looper-framework §3.3).
Verified end to end in the FreeBSD VM: a looper `call`s and gets a
correlated reply, and an `accept`ed request is answered through its
`Responder`.

The broker's jailed-spawn foundation is also down: **`freebsd-procdesc-sys`**
is reworked from blind scaffold to a real, VM-verified `spawn` — `pdfork`
then `execve`, done in a C shim so no Rust runs in the forked child, with
a `Child` holding the process descriptor that `wait`s on the exit and
`kill`s the child (§5.3, §5.5); and **`freebsd-jail-sys`** is verified, the
spawned child `jail_attach`ing before the exec so a component lands
confined; and the spawn hands the child a bootstrap socket at fd 3.
**`abyss-broker`'s `spawn` module** composes all of it: `spawn_component`
creates the component's jail, opens the bootstrap channel, `pdfork`s the
program into the jail holding that channel as fd 3, and sends the
bootstrap bundle over it.

And the spawn-and-bootstrap loop is closed. **`abyss-bootstrap`** is the
component-side startup shim: `enter` adopts the bootstrap socket at fd 3,
receives the bundle, and `cap_enter`s — verifying `freebsd-capsicum-sys`.
The `component-probe` binary is the first AbyssBSD component; an
end-to-end VM test spawns it through the broker and sees it report back
from inside capability mode, having received exactly the bundle the
broker sent. And the kqueue substrate now watches process descriptors for
exit (`EVFILT_PROCDESC` / `NOTE_EXIT`) — the signal the broker's
supervision is built on. `cargo xtask ci` green on macOS and FreeBSD;
tree clean.

## Next

**The rest of Phase 4's FreeBSD remainder**, per
`docs/design/broker-and-transport.md`:

- the broker's **supervision loop** — on the `EVFILT_PROCDESC` exit
  signal now in place: restarting a failed component and the
  `PeerRestarted` re-wiring of the components that talked to it (§5.5) —
  the next increment;
- `Cap: Wire` — a capability delegated inside a message (§3.2, §3.4);
- the broker built from a manifest set: spawning a whole graph, not one
  component at a time (§5).

The `freebsd-src` submodule (`ROADMAP.md` §6) is populated for that work.
This reaches the bulk of **M1**.
