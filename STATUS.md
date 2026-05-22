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

The workspace is thirteen `crates/` + three `sys/` + `xtask`, `cargo
xtask ci` green. Gate D (`docs/design/broker-and-transport.md`) specifies
the FreeBSD remainder.

## Recent commits

*(≤10 most recent, newest first)*

- `e13ce72` Phase 4: abyss-broker — wire an authority graph into a spawned session (§5.2)
- `c693146` Bump STATUS: Phase 4 — the bootstrap-bundle schema
- `bc490e9` Phase 4: abyss-bundle — the bootstrap-bundle schema (§5.8)
- `88680e0` Phase 4: design — the bootstrap-bundle schema (§5.8)
- `7ba1632` Bump STATUS: Phase 4 — Cap: Wire; align §3.5 with the built bind signature
- `031f5a6` Phase 4: abyss-cap — Cap: Wire, and binding a received capability (§3.4–§3.5)
- `22c60ed` Bump STATUS: Phase 4 — a Spawner for a running looper
- `c8fdb0e` Phase 4: abyss-looper — a Spawner for a running looper
- `5df312f` Phase 4: design — Cap: Wire in code, and binding (§3.5)
- `abc68e9` Bump STATUS: Phase 4 — Cap::call reshaped to the typed request

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
gRPC / FIDL shape — and that layer's trait and derive are built:
`abyss-msg`'s **`Request`** (`type Reply`) and **`#[derive(Request)]`**,
which links each request payload to its message enum and to its reply
type. The `Cap::call` reshape (§2.7, §2.10) is **done**. `abyss-looper` gained
the in-process reply path — the **`Responder`** handle, and `Delivery` /
`Ctx` / `Looper::attach_service` carrying a request's responder to its
handler — and `Cap::call` is reshaped onto it: `call<Q>` hands the caller
exactly the request's `Q::Reply`, framework-mediated over either backend,
no embedded `Sender`. The multi-looper harness passes on the reshaped
path. A design pass (§3.5) pinned `Cap: Wire`'s mechanics, and **`Cap: Wire` is
now built**. `abyss-looper` first gained a **`Spawner`** — a cloneable,
`Send` handle that adds tasks to a running looper (looper-framework §10),
drained and installed at the start of every run turn. Then `abyss-cap`'s
**`impl Wire for Cap`**: `to_wire` duplicates the cap's ring socket onto
`SCM_RIGHTS` beside its `CapBody`; `from_wire` yields an *unbound* `Cap` —
a received fd, no live ring; and **`Cap::bind`** lifts that into a live
`Connection` on the looper's reactor and spawns its `serve` loop through
the `Spawner` — the single `IpcUnbound → Ipc` edge. The transport gained
the supporting API: `AsFd` for `Connection` / `AsyncChannel`,
`FramedChannel::from_fd`, and a non-blocking `Connection::try_send` that
wires `Cap::try_send`'s IPC arm. Verified in the VM: a `Cap` round-trips
through `to_wire` / `from_wire` across a socket, binds onto a looper, and
`call`s over the bound ring with the reply routed by the spawned `serve`
loop.

The broker now **wires an authority graph into a spawned session** (§5.2).
A design pass pinned the **bootstrap-bundle schema** (§5.8) — the payload
format §5.3 left open — and the new **`abyss-bundle`** crate *is* that
schema: `Bundle`, a `Wire`-round-tripping list of capability `Grant`s,
each an `interface`, a `Role` (client / server), a `CapBody`, and a
ring-endpoint descriptor; the contract the broker and every startup shim
share. On it, `abyss-broker`'s new **`session`** module turns a `Graph`
into a running set: `Session::wire` pre-creates a `SOCK_SEQPACKET` ring
per connection and assembles each component's `Bundle` (requester ↦
client end, provider ↦ server end), `Session::spawn` brings each
component into being holding it. Verified in the VM: a three-component
graph is wired and spawned, and each component decodes its bundle and
finds exactly the grants its connections imply. The minted capabilities
carry zero rights for now — the §3.3 rights mapping is deferred
(`TECH-DEBT.md`). This increment is `cargo xtask ci`-green on macOS and
FreeBSD.

## Next

**The rest of Phase 4's FreeBSD remainder**, per
`docs/design/broker-and-transport.md`:

- the **startup shim decoding the bundle** — `abyss-bootstrap` turning
  each `Grant` into the capability its `Role` calls for, the client grants
  becoming bound `Cap`s (§5.4, §3.5) — the next increment;
- supervision's **`PeerRestarted`** — re-wiring the peers of a restarted
  component (§5.5);
- the §3.3 **rights mapping** — minting each grant's `CapBody` from the
  manifest rather than zero (`TECH-DEBT.md`).

The `freebsd-src` submodule (`ROADMAP.md` §6) is populated for that work.
This reaches the bulk of **M1**.
