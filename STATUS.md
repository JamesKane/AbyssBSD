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
  on FreeBSD, the `spawn` and `session` modules — component spawn, and the
  session runtime that wires, spawns, and supervises a manifest set (§5.3,
  §5.5); see In flight. No `unsafe`.
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

- `442ba6c` Phase 4: abyss-transport — AsyncMessageChannel, the async control channel
- `ba39aac` Bump STATUS: Phase 4 — Session/Supervisor unified (§5.5)
- `edea028` Phase 4: §5.5 — Session and Supervisor unified into one runtime
- `101bca6` Phase 4: abyss-cap — the durable capability (§5.5)
- `6314afb` Bump STATUS: Phase 4 — the PeerRestarted control message (§5.5)
- `e381452` Phase 4: abyss-bundle — the PeerRestarted control message (§5.5)
- `3f2a4d8` Bump STATUS: Phase 4 — PeerRestarted designed (§5.5)
- `31f9b17` Phase 4: design — PeerRestarted, re-wiring a restarted component (§5.5)
- `a9b7d26` Bump STATUS: Phase 4 — the object-rights layer enforced end to end
- `04eed42` Phase 4: abyss-bootstrap — the probe serves through bind_service (§3.6)

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
exit (`EVFILT_PROCDESC` / `NOTE_EXIT`); the broker's **process
supervision** is built on that signal — it watches its components'
process descriptors and, when one exits, spawns it again, reclaiming its
jail first. Verified in the VM: a supervised component that exits is
respawned as a fresh process. And `Cap: Wire` is under way — `abyss-cap`'s **`CapBody`** is the §3.2
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
carry zero rights for now (`TECH-DEBT.md`) — but the model they will be
minted from is no longer open: a first-principles design pass, grounded in
Capsicum / seL4 / Cap'n Proto / Fuchsia / Wayland, **pinned the
object-rights model in §3.3**. A service ring is a multiplexor, so object
rights are a bitmask over an interface's method ordinals (the unit
`#[derive(Method)]` already assigns), service-enforced — the kernel
`cap_rights_t` mask's counterpart one layer up. §3.3 rewritten end to end;
the kernel-layer table corrected (the service-ring mask gains `CAP_FCNTL`).

Three correctness defects in **`abyss-looper`** were then found and fixed,
each with a regression test: a **lost wakeup** in the ring — a send
cancelled while pending stranded its waker ahead of a live sender's, so a
freed slot woke no one; a **responder leak** — `attach_service` held an
unanswered request's responder past the handler, leaving its caller to
hang; and **unbounded task-arena growth** — a completed task's slot was
never reclaimed, now a generational slotmap that frees and reuses slots.

And the **startup shim brings the bundle to life** (§5.4).
`abyss-bootstrap`'s `enter` decodes the received envelope into a `Bundle`;
`Startup` claims each grant — a `client` grant as an unbound `Cap<I, R>`
(`abyss-cap::unbound_ipc_cap`), a `server` grant as the service end of its
ring. A component then builds its looper, binds a claimed `Cap` to it
(§3.5), and uses it. **Two components now converse over a broker-wired
ring**: the end-to-end test wires a three-component session and spawns it,
and the `compositor` probe `call`s a request over the ring to the `input`
probe, which serves it and replies — a request and its reply crossing a
`SOCK_SEQPACKET` ring between two jailed, capability-mode components the
broker spawned and wired. This reaches the bulk of **M1**.

The first of §3.3's two rights layers is now enforced: `Session::wire`
builds the fixed service-ring `cap_rights_t` mask (`CAP_SEND`, `CAP_RECV`,
`CAP_EVENT`, `CAP_FCNTL`, `CAP_FSTAT`), `cap_rights_limit`s each ring
descriptor to it, and records it in the grant's `CapBody`;
`freebsd-capsicum-sys` gained `CAP_FCNTL`. The conversation still runs end
to end over the now-restricted rings — proof the mask covers what the
transport exercises.

The **§3.3 object-rights layer is built and enforced end to end**, and
with it §3.6, the IPC service framework. A message enum's command and
request variants are tagged `#[rights(name)]`, and `#[derive(Method)]`
collects the tags into `Method::RIGHTS_CLASSES`. The broker's `catalogue`
module resolves a manifest's `rights` tokens to an `object_rights` mask,
and `Session::wire` mints it into both grants. `abyss-transport`'s ring
frame gained an **`Error`** kind; `abyss-cap` gained **`bind_service`**,
the server counterpart of `Cap::bind` — it binds a `Role::Server` grant,
runs an accept loop that **checks each inbound `method_id` against the
object-rights mask before a `Service` handler sees the message**, and
refuses what is out of rights; `Cap::call` yields a `CallError`. A wired
test grants a component no rights on a peer, and its `call` is refused —
the broker's mint, the framework's check, the `Error` frame, and
`CallError::RightsDenied` at the caller, across two jailed,
capability-mode components.

A design pass (§5.5) has pinned **`PeerRestarted`** — the broker re-wiring
a restarted component's peers: the bootstrap channel kept as a *control
connection*, a `PeerRestarted` message carrying one fresh `Grant`, the
`Session` and `Supervisor` unified into one broker runtime, and the
component-side **durable capability** the framework repoints at the fresh
ring so a `call` after a restart travels it transparently. Building it has
begun: `abyss-bundle` gained the **`PeerRestarted`** control message — one
fresh `Grant` — and `abyss-cap` gained the **durable capability**:
`DurableCap` carries the `Cap` in use, and a paired `Repointer` swaps it
for a fresh ring, so a `call` after a restart travels the new ring. And
**`Session` and `Supervisor` are now one runtime**: `supervisor.rs` is
gone, its restart-on-exit logic folded into the `session` module.
`Session::launch` wires, spawns, and registers every component's process
descriptor on a kqueue reactor; `Session::step` supervises — and on a
component exit it *re-wires*, creating a fresh ring per connection the
dead component touched, respawning it into a fresh bundle, and sending
each surviving peer a `PeerRestarted` over that peer's control channel.
Verified in the VM: a component that exits is re-wired and restarted, its
live peer untouched. The component side has begun: `abyss-transport`
gained **`AsyncMessageChannel`**, the bare-envelope async sibling of
`AsyncChannel` — a component wraps its bootstrap channel in one to await
`PeerRestarted` without blocking its looper thread. What remains is the
control loop itself — decoding a received `PeerRestarted` and driving the
`Repointer` — and a full multi-process restart test. `cargo xtask ci`
green on macOS and FreeBSD; tree clean.

## Next

**The rest of Phase 4's FreeBSD remainder**, per
`docs/design/broker-and-transport.md`:

- **building §5.5 `PeerRestarted`** — the control message, the durable
  capability, the unified session runtime with re-wire-on-restart, and
  `AsyncMessageChannel` (the async control channel) are in; what remains
  is the component-side control loop that decodes a `PeerRestarted` and
  drives the `Repointer`, and a full multi-process restart test — the
  next increment;
- the `Cap<I, R>` typestate connected to the runtime object-rights mask
  (`narrow`, the `bind`-time check) — the client-side compile-time safety
  net beside the now-enforced service-side check (§3.3).

The `freebsd-src` submodule (`ROADMAP.md` §6) is populated for that work.
