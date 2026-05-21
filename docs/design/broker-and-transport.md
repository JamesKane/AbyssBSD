# The broker & the transport

> Design elaboration for **Gate D** (`../ROADMAP.md` §5). It makes
> `../DESIGN.md` §6.2/§6.4, §10, and §11.9 implementable: the inter-process
> ring transport, how capabilities cross a process boundary, the component
> manifest, the broker, and the FreeBSD FFI. It also resolves the items
> Gates A and B deferred here — the IPC ring backend, the handle-table
> body layout, and `Cap: Wire`.
>
> The foundation for **Phase 4** — `crates/abyss-broker`, the `sys/*` FFI
> crates, and the IPC transport. **Phase 4 is the first FreeBSD work**:
> everything here is FreeBSD-specific and built and tested on the amd64
> FreeBSD 15.0 VM (`ROADMAP.md` §2, §4).
>
> Status: draft.

---

## 1. Scope & principles

Phases 0–3 built the AbyssBSD layer on the host with no operating-system
authority at all. Phase 4 is where the layer meets the FreeBSD kernel:
real processes, real isolation, real capabilities.

Principles, each load-bearing:

- **No ambient authority** (§10.1). A component is born holding exactly
  its bundle and can name nothing else. After `cap_enter` this is
  kernel-enforced, not a convention.
- **No central bus daemon** (§11.1). Components connect point-to-point;
  the broker hands out the connections. A router that saw all traffic
  would enlarge the TCB for nothing.
- **The broker is the smallest, most-audited thing in the TCB** (§10.4,
  §10.5). It is the one component that never enters capability mode, so it
  stays small and **dependency-free** — a vendored parser or framework in
  the broker is unthinkable.
- **Capabilities are kernel-enforced.** Gate B's phantom rights were
  intra-process hygiene (looper-framework §7.2); this gate is the real
  thing — Capsicum `cap_rights_t` on every fd.
- **Eager, pre-wired activation** (§11.9). The broker pre-creates every
  connection, *then* spawns; no component can race a peer being "not up
  yet" — that error class is gone by construction.

---

## 2. The transport — the inter-process ring

Gate B's ring API (`abyss-looper`) had one backend, in-process. This is
the second: a ring whose two endpoints are in different processes.

### 2.1 One socket per ring

A cross-process ring **is a `SOCK_SEQPACKET` Unix-domain socket**. The
broker creates it with `socketpair(2)` and places one end in each process's
bundle (§5.3). There is no multiplexing and no router — **one socket per
connection** (§11.1).

`SOCK_SEQPACKET` is DESIGN §6.4's choice, and the reasons are exact: it
preserves message boundaries (one envelope is one datagram), it is ordered
and reliable, it does kernel flow control, and it carries file descriptors.

### 2.2 The envelope is the wire frame

One `sendmsg(2)` carries one envelope (`DESIGN.md` §6.2, wire-format §3):

- the envelope's **header + payload + handle-table bytes** go in the
  datagram body;
- the envelope's **handle fds** go in the **`SCM_RIGHTS`** ancillary data
  of the *same* `sendmsg`.

The handle-table entries (wire-format §3.4) and the `SCM_RIGHTS` fds
correlate **by order**: the k-th fd-bearing handle entry is the k-th
received fd. `recvmsg(2)` reverses it. This is Gate B's deferred IPC ring
backend and wire-format §3.4's deferred fd marshaling, made concrete.

### 2.3 The looper's event source — `kqueue`

The Phase-2 in-process looper parked on the thread (looper-framework §12).
The FreeBSD looper waits on a **`kqueue`** — and everything registers on
that one queue:

- **`EVFILT_READ`** on each IPC socket — a ring became readable, so wake
  the receiving task;
- **`EVFILT_USER`** — cross-thread and in-process wakeups (the Phase-2
  parker's job, now a kqueue event);
- **`EVFILT_PROCDESC`** — a supervised child exited (§5.5); only the
  broker uses this.

Backpressure is unchanged from Gate B §3.1: a full socket send buffer is
the bounded ring's "full" — the `send` future registers for `EVFILT_WRITE`
and resumes when the socket is writable, suspending the *handler*, never
the looper thread. Phase 4 extends `abyss-looper` with this kqueue event
loop; the in-process backend stays for host tests.

### 2.4 Large data never travels inline

A datagram is bounded (`SO_SNDBUF` — a few KB). Large data is **never**
sent inline (§6.2): it is shared as a **memory capability** — a `memfd` or
shm fd in the handle table, mapped by the receiver. dmabuf buffer sharing
(the display path) is exactly this case. Envelopes stay small.

### 2.5 The ring across two backends

Gate B framed the ring as a *transport seam* — one ring API, a pluggable
backend. There are two:

- **in-process** — an MPSC ring of typed Rust messages, no serialization
  (looper-framework §3). It is the Phase-2 host-test backend, and it
  serves intra-process use.
- **IPC** — a `SOCK_SEQPACKET` connection (§2.1) carrying serialized
  envelopes.

For the IPC backend to carry an interface's messages they must serialize,
so — **resolved here — `Interface::Message: Wire`**: every interface's
message type implements `Wire` (`#[derive(Wire)]`, wire-format §6). An
interface is a cross-component *contract*; being serializable is intrinsic
to it, not a tax. (The request/reply *reply* value rides a raw ring of an
arbitrary `Rep` type, not an `Interface`, and is unaffected — see §2.7.)

`Cap<I, R>` and the receiving end are backend-agnostic; the backend is
fixed when the ring is constructed. `cap_channel` builds an in-process
pair (host tests); the broker, wiring the authority graph (§5.2), builds
IPC pairs over `socketpair`. `Cap::send` and `Cap::call` dispatch on the
backend the `Cap` holds.

### 2.6 The IPC ring frame

This refines §2.2. On the IPC backend the datagram body is a small fixed
**ring frame** followed by the envelope. The ring frame is the IPC ring's
own protocol layer; the envelope (wire-format §3) is **unchanged**, so
`abyss-msg` and the Gate A wire format are untouched.

The ring frame is 8 bytes:

- `frame_kind: u8` — `0` a message, `1` a reply;
- 3 bytes reserved, zero;
- `correlation: u32` — the request/reply correlation id (§2.7).

A **message** frame carries an envelope inbound to a handler — a Request,
Command, or Event, by the envelope's own `MessageKind`. A Request's
`correlation` is a fresh id; a Command's or Event's is `0`. A **reply**
frame carries the answer to a Request: its `correlation` echoes the
request's, and its envelope payload is the reply value.

The correlation id lives in the ring frame, not the envelope, on purpose:
request/reply correlation is an IPC concern the in-process backend has no
need of, and keeping it out of the envelope leaves the wire format and
`abyss-msg` alone. `MessageChannel` (the increment-2 type) sends a *bare*
envelope with no ring frame — exactly right for the one-shot **bootstrap
bundle** (§5.3); the IPC ring frames over the raw `Channel`.

### 2.7 Request and reply over the wire

In-process, the looper framework's `call` embeds a live reply `Sender` in
the request message. That cannot cross a process — an in-process queue
handle is meaningless to another. Over IPC, request and reply correlate
by the ring frame's `correlation` id (§2.6), and the reply rides back over
the same bidirectional `SOCK_SEQPACKET` connection.

An IPC ring connection owns a monotonic per-connection correlation
counter, a **pending-call table** (`correlation → a waiting caller`), and
the connection's receive loop. `Cap::call` over IPC takes the next id,
sends a message frame (envelope kind Request) carrying it, registers a
slot, and awaits it. The receive loop reads each datagram: a reply frame
is matched by `correlation` and fulfills its waiting caller; a message
frame is delivered to the looper for the handler.

The reply path is **framework-mediated, not embedded**. A request
delivered to a handler is accompanied by a **`Responder`** — a
backend-agnostic reply handle the framework supplies; it is *not* a field
the interface author writes into the message. The handler answers with
`responder.send(value)`, and the framework routes it: in-process over a
reply ring, over IPC as a reply frame echoing the correlation id. This
**supersedes the looper framework's embedded-`Sender` `call`** — the
embedded `Sender` becomes an in-process implementation detail of the
`Responder`, never part of an interface's message shape. `Cap::call` and
`Handler` are then uniform across both backends: the caller `await`s a
typed reply, the handler answers a `Responder`, and neither names a
backend.

### 2.8 The two backends in the crate graph

§2.5 fixed the model; this fixes how it lands in code — the question
Gate B left open.

`Cap<I, R>` holds a **backend**, and `send`/`call` match on it:

- `Local` — the Gate B in-process ring, a `Sender<I::Message>`. It is on
  every host; it is what the macOS development bed and the host tests run.
- `Ipc` — an `abyss-transport` IPC ring over a `SOCK_SEQPACKET`
  connection. It is `cfg(target_os = "freebsd")`: those sockets are a
  FreeBSD facility.

So **`abyss-cap` depends on `abyss-transport`** (and `abyss-msg`) — the
capability layer sits above the transport, the natural direction, and no
cycle. `abyss-transport` already builds on every host (its IPC parts gate
on FreeBSD), so `abyss-cap` still builds on the development bed.

**`Interface::Message: Wire` is an IPC-construction requirement, not a
trait supertrait.** The `Interface` trait keeps `type Message: Send +
'static`. The `Wire` bound is demanded where an *IPC* ring is built — the
broker wiring the authority graph (§5.2) — not of every `Interface`. An
interface used only in-process is unaffected, and `#[derive(Wire)]` stays
something an interface opts into, not a tax the trait levies on every
message on every host.

`Cap: Wire` (§3.4) is therefore itself `cfg(target_os = "freebsd")`:
serializing a capability *is* the IPC act of passing an fd across a
process boundary. An in-process `Cap` never serializes — it moves as a
value (looper-framework §7) — so the absence of a `Wire` impl off FreeBSD
costs nothing.

---

## 3. Capabilities across a process boundary

### 3.1 Every capability is an fd

DESIGN §10.2 sketched two capability backings — a kernel fd, and a "bus
routing token" naming a service object. **In the no-router architecture
(§11.1, Gate B) the second does not materialize**: there is no daemon to
resolve a token, so a service-connection capability *is* a ring *is* a
`SOCK_SEQPACKET` socket fd.

So capabilities are **uniform — every one is a file descriptor**: a
service-ring capability is a socket fd; a kernel-resource capability (a
device, a `memfd`) is that resource's fd. One mechanism, and Capsicum
governs all of it. This is cleaner than the two-backing sketch, and it is
the realized model — recorded here as the resolution.

### 3.2 The handle-table body layout

Wire-format §3.4 left the handle-table entry's `body` opaque, to be
defined here. A handle entry is `kind: u8`, `body_len: u32`, `body`:

- **`kind` = 1, an fd capability.** Every capability (§3.1). The `body`:
  - `cap_rights: 16 bytes` — the FreeBSD `cap_rights_t` mask the fd
    carries (§3.3). A fixed 16 bytes — FreeBSD's current `cap_rights_t` is
    two `u64`s; the field is fixed-width and version-checked on decode.
  - `object_rights: u32` — for a service-ring capability, the per-interface
    object-rights set (§3.3); zero for a kernel-resource fd.
- `kind` = 2 is **reserved** — it was the bus-token backing, which §3.1
  retired.

The fd itself is **not** in the body — it rides `SCM_RIGHTS` (§2.2). The
body is the metadata that travels in the datagram alongside it.

### 3.3 Two rights layers, and the mapping

DESIGN §10.5's two rights layers, made concrete:

1. **`cap_rights_t`** — kernel-enforced, on *every* fd. The broker applies
   it with `cap_rights_limit(2)` before the fd is ever handed over.
2. **Object rights** — per-interface, enforced by the **exporting service**
   at runtime (a `Cap<Settings>`'s read vs read-write, scoped to a
   subtree; a service checks each request against the rights recorded for
   that connection).

A manifest (§4) requests a capability in **object-rights** terms. The
broker translates an fd request to a `cap_rights_t` mask by this **fixed
mapping** and applies it before passing the fd:

| Capability kind / class | `cap_rights_t` mask |
|---|---|
| service ring (a socket) | `CAP_SEND` `CAP_RECV` `CAP_EVENT` `CAP_FSTAT` |
| GPU device | `CAP_MMAP_RW` `CAP_IOCTL` `CAP_EVENT` `CAP_FSTAT` |
| input device | `CAP_READ` `CAP_EVENT` `CAP_IOCTL` `CAP_FSTAT` |
| memory handle (`memfd`/shm) | `CAP_MMAP_RW` `CAP_FSTAT` (`CAP_MMAP_R` if read-only) |
| Casper channel | `CAP_SEND` `CAP_RECV` `CAP_EVENT` |

Both layers obey one **monotonic law** (§10.1): `cap_rights_limit` only
ever restricts, and `narrow` (abyss-cap) only ever shrinks the
object-rights set. Authority is attenuated, never amplified.

### 3.4 `Cap: Wire`

Gate B (looper-framework §12) deferred the `Wire` impl for `Cap` to here.

- **`to_wire`** — `Cap<I, R>` pushes a `RawHandle` whose `body` is §3.2's
  layout (the `cap_rights_t` for its socket, its object rights) into the
  `HandleSink`, and returns `Value::Handle(idx)`. The transport, on
  `sendmsg`, pulls the fd from the cap and places it in `SCM_RIGHTS`.
- **`from_wire`** — `Cap<I, R>` takes its `RawHandle` from the
  `HandleStore`, which the transport populated from the received
  `SCM_RIGHTS` fds paired with the body metadata.

This is the last connection between `abyss-cap`, `abyss-msg`'s
`HandleSink`/`HandleStore`/`RawHandle`, and the transport. Authority
travelling in a message (§10.1) is now a real fd crossing a real socket.

---

## 4. The manifest

### 4.1 The schema

Every component ships a **manifest** — its whole authority, declared. It
states:

- **identity** — `name`, the exported `interface`, `version`;
- **capabilities** — a list; each request is a `kind`
  (`peer` · `device` · `memory` · `casper` · `settings`), a *target* (the
  peer interface, the device class, the settings subtree), and the
  **object rights** asked for;
- **jail** — filesystem visibility, network (usually `none`), the
  principal to run as;
- **budget** — the memory ceiling (§3.6), fd and CPU caps;
- **restart** — the policy: `always` · `on-failure` · `never`.

The **static authority graph** (§11.9) is the union of every component's
manifest — knowable, and auditable, before anything runs.

### 4.2 The format

The manifest is a **small, fixed-schema declarative text format**, parsed
by a **first-party parser in the broker** — not a general configuration
language, and not a vendored parser. The broker is the most-audited thing
in the TCB (§10.5, §3.2); a hand-written parser over a fixed, tiny schema
is auditable, and a vendored TOML-plus-`serde` dependency tree is not. An
example:

```
# compositor.manifest
name      = compositor
interface = display
version   = 1

[capability]
kind   = device
class  = gpu
rights = mmap, ioctl

[capability]
kind      = peer
interface = input
rights    = recv

[jail]
root    = /
network = none
user    = _compositor

[budget]
memory = 96M
fds    = 64

[restart]
policy = always
```

`#` comments, `key = value`, `[section]` headers, repeatable
`[capability]` blocks. The parser is a fixed recursive walk over known
keys — no grammar, no escaping subtleties — and it is fully tested,
because a malformed *system* manifest is a boot fault (§5.1).

### 4.3 Two trust profiles

One format, two trust levels (§10.5):

- A **system-component** manifest ships with the curated OS and is
  curation-vetted — the grant is the manifest **verbatim**.
- An **app** manifest lives in the `.app` bundle (§11.14) — the grant is
  the manifest **∩ the user's approval**. Capabilities beyond a safe
  default are surfaced for the user to approve; the broker grants only the
  intersection.

---

## 5. The broker

`crates/abyss-broker` — the root of authority and the session root.

### 5.1 Boot

`rc` execs `abyss-broker` as **root** (§11.9). The broker is the one
component that **never enters capability mode** — it must keep creating
jails and opening devices for the life of the session — so it is the
permanently-unsandboxed root of the TCB, and therefore kept smallest and
most audited. It reads the system manifests; a malformed *system* manifest
is a **boot fault** and drops to the §9 recovery floor.

### 5.2 The authority graph and pre-wiring

From the manifests the broker computes the **static authority graph** —
every component, every connection, every device grant — before spawning
anything. Activation is **eager and pre-wired**: for a spawn phase the
broker pre-creates *every* ring (a `socketpair` per connection), *then*
spawns each component with both ends already assigned. Boot has two
phases — the **system layer** at boot, the **session layer** at login
(§11.15); each phase's set is pre-wired as a whole.

### 5.3 Spawn & the bootstrap bundle

The broker `pdfork(2)`s a child — a **process descriptor**, not a bare
pid (§10.3) — creates its jail (`jail_set` / `jail_attach`), and `exec`s
the component binary inside it.

The child is execed holding **one fd: the bootstrap socket**, at a known
number. On it the broker sends **one envelope — the bundle**: the handle
table carries every capability the component was granted (each an fd via
`SCM_RIGHTS` — its ring endpoints, its device fds, its scoped settings
capability), and the payload names them (which fd is which peer or
device). The bundle *is* an envelope — the §6.2 mechanism, reused for
bootstrap.

### 5.4 The startup shim — `cap_enter`

The child runs a tiny, trusted **startup shim** (§10.5): it receives the
bootstrap envelope, decodes the bundle, then calls **`cap_enter(2)`** —
irreversibly entering Capsicum capability mode — and only *then* hands the
component its rings and runs it.

After `cap_enter` the component **cannot open anything by name**; it holds
exactly its bundle. The jail is the hard boundary; `cap_enter` is
defense-in-depth on an already-empty bundle (§10.5).

### 5.5 Supervision, restart, and `PeerRestarted`

The broker holds each child's `pdfork` **process descriptor** and registers
it on its `kqueue` (`EVFILT_PROCDESC`, §2.3). A child's exit — clean or a
crash — is an *event*, not a `SIGCHLD` race.

On a crash the broker restarts per the manifest's policy: a fresh jail,
fresh `socketpair` rings, a fresh bundle. The dead component's old sockets
are gone — each surviving peer's ring yields `RingClosed` (Gate B §3.2).
The broker then **re-wires**: over each peer's control connection to the
broker it sends a **`PeerRestarted`** message carrying the *fresh* ring
endpoint (a new fd via `SCM_RIGHTS`); the peer's looper swaps the dead
ring for it. This is the s6-grade supervision of §11.9.

### 5.6 Delegated spawn

A component — chiefly the shell, launching an app — may ask the broker to
spawn a child. The child's **birth bundle is the broker's grant**, per the
*child's* manifest (for an app, ∩ user approval, §4.3) — it is **not**
bounded by the launcher (§11.9). The shell need not itself hold
microphone, network, or file authority to launch apps that use them.

Capabilities a component instead **delegates from its own holdings** —
passing a `Cap` it already holds into a message (§3.4) — *are* bounded by
what it holds: recursive attenuation, never amplification (§10.1).

### 5.7 Casper, composed

A Capsicum-sandboxed component cannot resolve DNS, read `passwd`, or call
`sysctl` — those open resources by name. FreeBSD's **Casper**
(`libcasper`) provides exactly these as sandboxed services. A component
declares the Casper services it needs (`kind = casper`); the broker sets
up each `cap_channel_t` — itself an fd — into the bundle. The broker is
*modeled on* Casper and *composes with* it; it is not built on it (§10.4).

---

## 6. The FreeBSD FFI — the `sys/*` crates

The kernel surface is bound through **C shims** — the approach `abyss-font`
validated (`docs/dependency-allowlist.md`). Here it is not merely
preferable but **required**: FreeBSD's Capsicum rights API
(`cap_rights_init`, `cap_rights_set`, …) and the socket control-message
API (`CMSG_FIRSTHDR`, `CMSG_DATA`, `CMSG_SPACE`, …) are **C macros**, not
callable functions — only a C shim can expose them to Rust. Each `sys/*`
crate is a tiny C shim plus flat Rust FFI: no `bindgen`, no `libclang`,
each compiled by the system toolchain (the `abyss-font` `build.rs`
pattern).

The crates:

- **`sys/freebsd-capsicum-sys`** — `cap_enter`, the `cap_rights_t`
  builders, `cap_rights_limit`, `cap_ioctls_limit`.
- **`sys/freebsd-jail-sys`** — `jail_set`, `jail_attach`, `jail_remove`.
- **`sys/freebsd-procdesc-sys`** — `pdfork`, `pdwait`, `pdkill`, and the
  `kqueue` glue for process-descriptor exit.

The `SCM_RIGHTS` / `cmsg` shim lives with the transport — it is
transport-specific. Each `sys/*` crate confines its `unsafe`, is the one
audited FFI boundary, and the broker and transport build safe APIs over
it. The `freebsd-src` submodule (`ROADMAP.md` §6) is **populated now** —
Phase 4 builds the shims against its headers.

---

## 7. What Phase 4 builds

This document is complete enough to build Phase 4 with no further design.

**Extended:** `abyss-looper` gains the FreeBSD `kqueue` event loop and the
`SOCK_SEQPACKET` ring backend (§2); `abyss-cap` gains the `Wire` impl
(§3.4). `abyss-msg`'s envelope is the wire frame, unchanged.

**New:** `crates/abyss-broker` — manifest parsing (§4), jailed spawn and
the bootstrap bundle (§5.3), the startup shim (§5.4), `pdfork` supervision
and re-wiring (§5.5). `sys/freebsd-capsicum-sys`,
`sys/freebsd-jail-sys`, `sys/freebsd-procdesc-sys` (§6).

**Test plan** — on the amd64 FreeBSD 15.0 VM (`ROADMAP.md` §2):

- a `socketpair` ring round-trips an envelope, including an fd passed by
  `SCM_RIGHTS`;
- a jailed child spawns, receives its bundle, calls `cap_enter`, and then
  *cannot* open a file by name;
- the broker brings a two-component graph up eager-and-pre-wired, with no
  peer-not-ready race;
- a killed child is restarted and its peer re-wired (`PeerRestarted`).

This is the bulk of **M1** — `rc` → broker → a jailed component set — and
sets up Phase 5's compositor.

---

## 8. Deferred

- **The shm display fast-path** (§6.4) — the compositor's high-frequency
  ring. Designed with the display protocol (Phase 5); the general
  `SOCK_SEQPACKET` bus here is the everyday transport.
- **The authenticator and greeter** (§11.15) — the broker's *session-layer*
  spawn phase is shaped here; the auth components themselves are Phase 7.
- **Envelope nesting for routing** (wire-format §9) — there is no router
  (§3.1), so nothing needs it; the thread is closed.
- **`drm-sys`** — the DRM/KMS FFI is Phase 5, with the compositor.
