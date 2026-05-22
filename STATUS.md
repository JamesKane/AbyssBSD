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
  on FreeBSD, the `spawn` and `supervisor` modules — component spawn and
  restart-on-death (§5.3, §5.5); see In flight. No `unsafe`.
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

- `0a52e92` Phase 4: design — typed request and reply (§2.10)
- `b337cd8` Bump STATUS: Phase 4 — the Cap IPC backend, send dispatch
- `1ed3820` Phase 4: abyss-cap — the Cap IPC backend, send dispatch
- `1963a6d` Bump STATUS: Phase 4 — Cap holds a Backend
- `e8bddbe` Phase 4: abyss-cap — Cap holds a Backend
- `90341b7` Bump STATUS: Phase 4 — Interface::ID, the §2.9 contract layer complete
- `1b31a68` Phase 4: abyss-cap — Interface::ID, the interface side of §2.9
- `21369f0` Bump STATUS: Phase 4 — the Method trait and derive
- `b610b8d` Phase 4: abyss-msg — the Method trait and #[derive(Method)]
- `2004c3e` Bump STATUS: Phase 4 — the interface contract design pass

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
  request with its reply by id; `send` carries a one-way Command or Event;
  `serve` routes replies to callers and inbound messages to an `Inbox`;
  `accept` lifts a request off it with a `Responder`. **The IPC ring is
  complete.**

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
exit (`EVFILT_PROCDESC` / `NOTE_EXIT`); the broker's **`Supervisor`** is
built on that signal — it watches its components' process descriptors
and, when one exits, spawns it again, reclaiming its jail first. Verified
in the VM: a supervised component that exits is respawned as a fresh
process. And `Cap: Wire` is under way — `abyss-cap`'s **`CapBody`** is the §3.2
handle-table body a capability serializes to (the `cap_rights` mask and
the object-rights set that ride beside an fd), and `abyss-msg`'s handle
table now **carries those fds**: `HandleSink` / `HandleStore` pair each
handle's metadata with the descriptor it rides `SCM_RIGHTS` on, and
`Envelope::from_message` / `into_message` carry the fds across. Two design
passes have pinned what the IPC backend lands in: §2.8 — the `Cap`
two-backend crate structure (`abyss-cap` over `abyss-transport`, `Cap:
Wire` gated to FreeBSD); §2.9 — the interface contract `Cap::send`/`call`
dispatch through, its shape checked against the Wayland / FIDL / Cap'n
Proto / Binder corpus. That contract layer is built:
`abyss-msg`'s **`Method`** trait and **`#[derive(Method)]`** give a
message its routing identity — the method ordinal (by declaration order)
and the kind — and `abyss-cap`'s **`Interface::ID`** gives the interface
its id; together they name an envelope `Header`. `Connection::send`
carries a one-way Command or Event, the IPC counterpart of `call`. And
the **`Cap` rework** is under way — `Cap<I, R>` holds a `Backend`, both
variants now in: `Local` (the in-process ring) and `Ipc` (an
`abyss-transport` `Connection`). `Cap::send` dispatches over either;
sent over IPC, a message is framed with its interface and method identity
and crosses a real `SOCK_SEQPACKET` ring. A further design pass (§2.10)
pinned the typed request/reply shape `Cap::call` reshapes to — precise
per-request, each request its own type carrying its reply type, the
gRPC / FIDL shape. `cargo xtask ci` green on macOS and FreeBSD; tree clean.

## Next

**The rest of Phase 4's FreeBSD remainder**, per
`docs/design/broker-and-transport.md`:

- the **typed request layer** — the `Request` trait (`type Reply`), the
  derive emitting it and `From<request> for I::Message` per Request
  variant, and `Cap::call<Q>` reshaped per §2.10 — the next increment;
- **`Cap: Wire`** — a `Cap` itself delivered inside a message (§3.4);
- the broker **wiring an authority graph** — spawning a manifest set and
  connecting the components with rings (§5.2);
- supervision's **`PeerRestarted`** — re-wiring the peers of a restarted
  component, once components are wired (§5.5).

The `freebsd-src` submodule (`ROADMAP.md` §6) is populated for that work.
This reaches the bulk of **M1**.
