# The looper & service framework

> Design elaboration for **Gate B** (`../ROADMAP.md` §5). It makes
> `../DESIGN.md` §6.1 and §6.8–§6.10 implementable: the looper and its
> cooperative executor, the handler model, the typed ring, the
> request/reply call, and the capability layer. The foundation for
> **Phase 2** — the `abyss-looper` and `abyss-cap` crates.
>
> Status: draft.

---

## 1. Scope & principles

DESIGN §6.10 names this framework "the chief structural piece the project
builds for itself" — Rust gives `async`/`.await` but no actor or service
model, so AbyssBSD writes one. Every component and every window is a looper;
they talk only over rings. This document fixes that framework.

Principles, each load-bearing:

- **The UI thread never blocks — mechanically** (§6.8, §6.9). `.await`
  suspends a *handler*, never the looper's thread. It is not a discipline
  to remember; the executor makes blocking the thread impossible.
- **Per-handler serialization** (§6.9). A handler processes its messages
  one at a time, in order, even across `.await`. Concurrency lives
  *between* handlers, never *within* one. The framework enforces this — it
  is not the handler's job to be careful.
- **Idle is zero CPU** (§3.6). A looper wakes only on a message. No polling
  loop, anywhere.
- **One ring API, transport-agnostic** (§6.10). Component code is written
  once; whether a ring is in-process or a cross-process socket is the
  broker's choice, invisible above.
- **Hold it in your head** (§3.5). One run loop, one invariant, three
  types. The executor is small enough to read in a sitting.

What is **here**: the looper, the executor, handlers, rings, the call, and
the capability *types* (`abyss-cap`). What is **deferred** (§10): the
inter-process ring backend, the broker, manifests, restart policy, and
kernel-enforced rights — all Gate D. Phase 2 builds and tests this whole
framework on the **in-process ring backend**, on the host, with no FreeBSD.

---

## 2. The model at a glance

```
   ┌─ Looper ── one OS thread ───────────────────────────────┐
   │                                                         │
   │   inbound rings        handlers          the executor   │
   │   ──────────────       ────────          ────────────   │
   │   ═══ RingRx ═══▶  ┌─ Handler A ─┐   run loop: drain     │
   │   ═══ RingRx ═══▶  │  async fn   │   rings, poll tasks,  │
   │                    └─────────────┘   park when idle      │
   │   ═══ RingRx ═══▶  ┌─ Handler B ─┐                       │
   │                    └─────────────┘   ≤ 1 in-flight task  │
   │                                       per handler        │
   └─────────────────────────────────────────────────────────┘
              │ cap.send(msg)            ▲ reply
              ▼                          │
       ╴╴╴ another looper ╴╴╴ (same process, or across the bus) ╴╴╴
```

- A **looper** is one OS thread: a set of inbound rings, a set of handlers,
  and a cooperative async executor that drives them. A component is a
  looper; a window is a looper (§8).
- A **handler** is an object with one `async fn handle`. It owns mutable
  state and processes one interface's messages, one at a time.
- A **ring** is a typed, bounded, ordered, point-to-point queue with two
  move-only endpoints — a sender and a receiver.

A handler never calls `recv`: the looper drains the rings and invokes
`handle`. Handler code only *sends* (through capabilities) and *calls*
(request/reply, §6). Receiving is the framework's job.

---

## 3. Rings

A ring carries messages of one type `M` between exactly one sender and one
receiver (§6.10 — "exactly one sender, one receiver"). Its endpoints:

- `RingTx<M>` — the send end. Move-only.
- `RingRx<M>` — the receive end. Move-only, owned by a looper.

`M: Send + 'static`. A ring the broker *might* route across a process
boundary additionally requires `M: Wire` (`abyss-msg`) — and in practice it
always might, so component message types are `Wire`. A purely
looper-internal ring needs only `Send`.

A ring is **bounded** (a capacity fixed at creation) and **FIFO** —
messages arrive in send order (`interfaces/README.md`: events on one
connection are ordered). Boundedness is deliberate: an unbounded queue is
an unbudgeted memory leak waiting for a slow consumer (§3.6).

### 3.1 Sending, and backpressure

```rust
impl<M> RingTx<M> {
    async fn send(&self, msg: M) -> Result<(), RingClosed>;
    fn try_send(&self, msg: M) -> Result<(), TrySendError>;
}
```

`send` is **async**. On a ring with free space it completes on the first
poll — no suspension, no cost. On a *full* ring it suspends the **calling
handler** (never the looper's thread) until the consumer drains space.
That is backpressure done right: a slow consumer stalls one producing
handler, while that handler's looper keeps serving its others. It is §6.9's
suspension model applied to flow control — the same mechanism, no new one.

`try_send` is the non-blocking escape hatch for a sender that would rather
drop than wait (`TrySendError` is `Full` or `Closed`).

### 3.2 RingClosed

When one endpoint is dropped — the peer looper exited, or simply let its
capability fall — the survivor's next `send` (or the looper's next drain of
a `RingRx`) yields **`RingClosed`**. This is the framework's dead-peer
signal (§6.10). A handler treats it as an ordinary value: a subscription
whose sink closed is over; a call whose peer vanished failed. No
exceptions, no unwinding.

### 3.3 The transport seam

`RingTx`/`RingRx` are one API over two backends:

- **In-process** (Phase 2) — an `Arc`-shared bounded queue with a wakeup
  for the receiver and one for a backpressured sender. `M` moves by
  ownership; nothing is serialized. This is the whole Phase-2 backend, and
  it is fully host-testable.
- **Inter-process** (Phase 4, Gate D) — the same API over
  `SOCK_SEQPACKET` / shared memory, with the §6.2 envelope as the wire
  format and `SCM_RIGHTS` for fds. Requires `M: Wire`.

The broker picks the backend when it wires a ring; component code never
knows which it got (§6.10). A lock-free in-process queue is a deferred
optimization — measure first (§3.5); the `Arc` + queue is correct and
simple now.

---

## 4. The looper & its executor

A looper is a thread, a message queue, **and a cooperative async executor**
(§6.9). The executor *is* the looper — there is no separate runtime.

### 4.1 The run loop

```
loop {
    // (a) poll every task whose waker has fired
    while let Some(h) = runnable.pop() {
        match poll(handler[h].task) {
            Ready   => { handler[h].task = None;
                         if let Some(m) = handler[h].queue.pop_front() {
                             start(h, m);          // begin the next message
                         } }
            Pending => { }                         // still parked on a ring
        }
    }
    // (b) dispatch newly-arrived inbound messages
    for (h, msg) in drained_inbound_rings() {
        if handler[h].task.is_none() { start(h, msg); }
        else                         { handler[h].queue.push_back(msg); }
    }
    // (c) nothing runnable, nothing waiting — sleep until a ring stirs
    if quiescent() { park(); }
}
```

`start(h, m)` builds the future `handler[h].handle(m, ctx)`, stores it as
handler `h`'s in-flight task, and polls it once. Step (c) is where §3.6's
"idle is zero CPU" is honored: `park()` blocks the thread until a ring —
inbound or a reply ring — stirs it. There is no spin.

### 4.2 Per-handler serialization

Each handler holds **at most one in-flight task**. A message arriving for a
handler that already has a task — even one merely *suspended* on `.await` —
goes to that handler's `queue`, not into a second task. When the task
finishes, the next queued message starts.

This is §6.9's invariant, and the executor enforces it by construction:
step (b) simply never calls `start` for a busy handler. A handler therefore
sees its messages strictly one at a time, in order. Async adds concurrency
*between* handlers; it never re-enters one. This is also what makes
`async fn handle(&mut self, …)` sound — the `&mut self` borrow held across
an `.await` can never alias a second invocation, because there is no second
invocation.

### 4.3 Wakers

When a task `.await`s a reply (§6), the framework registers the task's
**`Waker`** with the reply ring. When the reply lands — sent by another
looper, on another thread — the ring calls `wake()`: the task is marked
`runnable` and the looper thread is unparked. The looper re-polls it on its
next step (a).

Wakers are built with `std::task::Wake` (safe, stable) — an `Arc` carrying
the looper's id and the task's id. `wake()` is thread-safe: a reply
crossing from another looper's thread is the normal case. `Pin` and
`Waker` live entirely inside the executor; **handler code never names
them** (§6.9) — a handler is plain `async fn`.

> Storing a handler beside its in-flight future is self-referential (the
> future borrows the handler). This is the one spot where the framework's
> own machinery concentrates; the executor core encapsulates it, and
> Phase 2 settles the mechanism (a contained, audited `unsafe`, or an
> `Rc<RefCell>` slot) with the bias toward whatever stays auditable. It is
> exactly the "framework encapsulates the machinery" of §6.9.

---

## 5. Handlers

```rust
pub trait Handler: Send + 'static {
    type Message: Send + 'static;

    /// Process one message. May `.await`. While suspended, this handler
    /// receives no further message (§4.2).
    async fn handle(&mut self, msg: Self::Message, ctx: &Ctx);
}
```

`async fn` in traits is stable (Rust 1.75+; the pin is 1.95). It is not
`dyn`-compatible — so the looper never stores `dyn Handler`. Instead:

```rust
impl Looper {
    fn attach<H: Handler>(&mut self, handler: H, inbox: RingRx<H::Message>) -> HandlerId;
    fn feed<H: Handler>(&mut self, id: HandlerId, inbox: RingRx<H::Message>);
}
```

`attach` is generic — monomorphized with `H` and `M` known. **Type erasure
happens here**, at attach time: the framework builds the erased glue that
the run loop drives, boxing each per-message future. The run loop itself
names no handler type. A handler may be fed by *several* inbound rings
(`feed`) — one service, many clients, the looper merging their messages in
arrival order.

The per-message `Box` is a known, small cost; pooling it is a deferred
optimization (§3.5 — measure first).

**A panic is a defect, not a failure mode.** The framework does not catch a
handler panic: a panic means the component is buggy, so it dies and the
broker restarts it with a fresh bundle (§8). Catching it would mask the
defect — against `interfaces/README.md` ("a `panic!` is for defects") and
§3.5. Interface failures are *values* (§6), never panics.

---

## 6. The request/reply call

A **call** is request → reply. `interfaces/README.md`: a request carries a
fresh reply-to capability; the reply is the one message sent back to it;
the capability *is* the correlation — no request-ids.

```rust
impl Ctx {
    async fn call<R: Request>(&self, cap: &Cap<R::Interface>, request: R)
        -> Result<R::Reply, CallError>;
}
```

The framework's `call`:

1. mints a fresh **one-shot reply ring** (capacity 1) on this looper;
2. installs the reply ring's send endpoint as the request's reply-to
   capability;
3. `cap.send(request).await` — sends the request;
4. awaits the one message on the reply ring.

Step 4 is the suspension point: it parks the *handler*, never the thread
(§6.9). While parked, the looper serves its other handlers; when the reply
lands, the waker (§4.3) resumes this one. The handler's code reads
straight down — `let reply = ctx.call(&peer, req).await?;` — with no
hand-written state machine. The callback alternative, where a reply is just
another message correlated by hand, is rejected (§6.9): it is the exact
boilerplate this model removes.

`CallError` is `Closed` — the peer dropped the ring before replying — or
`Failed(Error)`, the interface's own `{ code, detail }` error value
(`interfaces/README.md` — errors are values). A handler `?`s it like any
`Result`.

---

## 7. Capabilities — `abyss-cap`

`abyss-cap` is the typed, rights-bearing face of a ring endpoint.
DESIGN's `RingCap` (§6.10) is realized here as `Cap<I, R>` (the send end)
and `Inbox<I>` (the receive end).

### 7.1 `Cap<I, R>`

```rust
pub struct Cap<I: Interface, R: Rights> { /* a RingTx, plus phantom I, R */ }
```

`Cap<I, R>` is the send endpoint of a ring, typed by the interface `I` it
speaks (§6.5 — a `Cap<Display>` accepts only display messages) and
parameterized by the rights `R` the holder was granted. It is **move-only**
— one sender per ring (§6.10). Sharing a service among many clients is many
rings, not a cloned cap; that is the statically-auditable authority graph
(§11.9). Delegation (§10.1) is moving a cap into a message, or the broker
minting another ring.

`Inbox<I>` is the matching receive endpoint, fed to a service handler via
`Looper::feed`.

### 7.2 Rights as phantom typestate

`R` carries the held object-rights subset as a compile-time phantom (§10.5).
`narrow` produces a weaker capability:

```rust
impl<I: Interface, R: Rights> Cap<I, R> {
    fn narrow<R2>(self) -> Cap<I, R2> where R2: SubsetOf<R>;
}
```

The `R2: SubsetOf<R>` bound makes the monotonic law of §10.1 a *compile
error* to break: `narrow` only ever restricts; widening does not type-check.
The concrete encoding — each interface's rights as marker types, the
`SubsetOf` relation — is an `abyss-cap` implementation detail; this document
fixes only the contract.

**The honest caveat** (§10.5, repeated because it matters). Phantom rights
are **intra-process compile-time hygiene only** — they keep a component
honest *with itself*. They do **not** secure a process boundary: one process
cannot trust another's compiler. Real enforcement is the kernel
(`cap_rights_t`) and the exporting service's *runtime* check — Phase 4,
Gate D. `abyss-cap`'s rights are a lint, and the doc says so plainly.

### 7.3 Capabilities are `Wire`

Authority travels in messages (§10.1), so `Cap<I, R>` implements `Wire`
(`abyss-msg`): `to_wire` pushes a `RawHandle` into the `HandleSink` and
returns a `Value::Handle`; `from_wire` moves the handle out of the
`HandleStore`. This *is* the §6.2 / wire-format §3.4 payload/handle split.

In-process (Phase 2) the `RawHandle` body is a process-local ring token,
moved directly — host-testable today. Cross-process marshaling — the fd via
`SCM_RIGHTS`, the `cap_rights_t` mask — is Gate D. The seam is exactly the
one the wire-format doc reserved: `abyss-msg` frames the handle, `abyss-cap`
gives it meaning.

---

## 8. Supervision & failure

The framework provides the *mechanism*; the broker (Gate D) sets *policy*
(§3.4).

- **Supervision handle.** Spawning a looper yields its parent — the broker
  — a handle that reports the looper's exit: clean, or a panic. The broker
  holds it for the session.
- **`RingClosed`** (§3.2) surfaces a dead peer to every live handler still
  holding a ring to it.
- **Restart** is the broker's: on a crash it rebuilds the looper with a
  fresh bundle and re-wires its peers (§11.9). `PeerRestarted` — the signal
  a survivor sees when its peer was replaced — is built on swapping in a
  fresh ring; its policy is Gate D.

The framework restarts nothing on its own. A looper that exits is observed;
what happens next is the broker's manifest, not the framework's opinion.

---

## 9. Concurrency & safety

- **One looper, one thread.** A handler's state is owned by that thread,
  never shared — no locks in handler code, ever.
- **Rings are the only cross-thread seam.** A message moving between
  loopers moves between threads, so `M: Send`; the compiler enforces it
  (§6.7). The ring's internal synchronization is the one audited place
  threads meet.
- **Deadlock is possible and named.** Bounded rings plus a cycle — handler
  A awaiting `send` to B, B awaiting `send` to A, both rings full — can
  wedge. It is not papered over. Mitigations: the authority graph is
  overwhelmingly an acyclic client→service shape; reply rings have
  capacity 1 and are written once, so they cannot fill; and a wedged
  looper stops draining and is observable to the broker. No magic (§3.5) —
  a real hazard, stated, with its bounds.

---

## 10. Deferred — Gate D and beyond

Named so nothing is silently lost:

- **The inter-process ring backend** — `SOCK_SEQPACKET`/shm, the §6.2
  envelope, `SCM_RIGHTS` fd-passing. Gate D.
- **The broker** — spawn, jails, manifests, capability minting, restart
  policy, `PeerRestarted` re-wiring. Gate D (`interfaces/broker.md`).
- **Kernel-enforced rights** — `cap_rights_t`, the object-rights → Capsicum
  mapping, the exporting service's runtime check. Phase 4.
- **Interface-schema codegen** — generating each interface's message enum,
  its `Interface` marker, and its `Request`/`Reply` associations from
  `interfaces/`. Until then, Phase 2's tests hand-write interface types.
- **Timers / clocks** — a looper waking on time, not only on a message.
  Added when a component needs it.

---

## 11. What Phase 2 builds

This document is complete enough to implement Phase 2 with no further
design. Two crates, host-built and host-tested (`ROADMAP.md` §4):

**`crates/abyss-looper`** — `RingTx`/`RingRx` and the in-process backend
(§3); the `Looper`, its executor and run loop (§4); the `Handler` trait and
`attach`/`feed` (§5); `Ctx` and `call` (§6); the supervision handle and
`RingClosed` (§8).

**`crates/abyss-cap`** — `Cap<I, R>`, `Inbox<I>`, the `Interface` and
`Rights` markers, `narrow` with the `SubsetOf` bound (§7); the `Wire` impl
for capabilities (§7.3). Depends on `abyss-looper` and `abyss-msg`.

**Test plan** — an in-process, multi-looper harness on the host:

- **Call/reply** — a request crosses loopers and its reply returns; the
  caller's handler reads straight through.
- **Per-handler serialization** — a handler that `.await`s mid-message
  still sees its next messages in order and is never re-entered; *other*
  handlers on the looper make progress meanwhile.
- **Backpressure** — a full ring suspends the sending handler, not the
  looper thread; the looper keeps serving.
- **`RingClosed`** — dropping one endpoint surfaces the typed error at the
  other.
- **`narrow`** — narrowing compiles; widening does not (a compile-fail
  check).
- **Idle is zero CPU** — a looper with no traffic parks and consumes no
  measurable CPU.

`cargo xtask ci` runs all of it on every change.

---

## 12. As built — Phase 2 refinements

§§1–11 are the design. Building `abyss-looper` and `abyss-cap` refined
several mechanisms. Every *contract* above holds — per-handler
serialization, concurrency between handlers, the thread never blocks, idle
is zero CPU, move-only capabilities, narrow-only rights — but these details
changed, and this section is authoritative where it differs.

- **The executor is serve loops, not a dispatch table.** §4.1 sketched a
  looper dispatching messages into per-handler queues. The build is simpler
  and equivalent: `attach` spawns one task per handler — a `serve` loop
  that `recv`s the handler's inbox and `.await`s `handle`. Per-handler
  serialization is then just the loop being sequential, and the
  "per-handler queue" is the inbox ring's own buffer. The executor only
  polls tasks and parks. This also dissolves the §4.3 self-reference
  worry: the serve loop *owns* the handler, so `handle`'s `&mut self` is an
  ordinary local borrow inside one task future. Both crates are
  `#![forbid(unsafe_code)]`.

- **Rings are MPSC.** §3's "exactly one sender, one receiver" became an
  MPSC ring: `channel` yields a clonable `Sender` and one `Receiver`. A
  capability stays move-only regardless — `Cap<I, R>` wraps a sender and is
  deliberately not `Clone`. Many clients of one service are many `Cap`s
  minted onto that service's one ring: the move-only, per-connection
  authority discipline of §7.1, realized over an MPSC ring.

- **`call` is a method on `Cap`.** Not `ctx.call(&cap, request)` but
  `cap.call(|reply| Request { …, reply }).await` — the closure is handed a
  fresh reply `Sender` to embed. `call` needs no looper context, so it
  belongs on the capability (§6.5 — act on a capability you hold).

- **The receive endpoint is `Receiver<I::Message>`.** No distinct `Inbox<I>`
  newtype was built; it would wrap `Receiver` and add nothing (§3.5).
  `cap_channel()` yields `(Cap<I, R>, Receiver<I::Message>)`.

- **`block_on` was added.** It drives a future to completion on a
  non-looper thread (`main`, tests) — the bridge for any thread that is
  not itself a looper.

- **`Cap: Wire` is deferred to Gate D.** §7.3 placed it in Phase 2, but
  in-process a capability moves as an ordinary Rust value — there is
  nothing to serialize. The `Wire` impl has a job only when a capability
  crosses a process, which is the Gate D transport. `abyss-cap` therefore
  depends only on `abyss-looper`, not `abyss-msg`, for now.

- **`Send` bounds.** A looper moves to its thread once, so its tasks — and
  thus `Handler` and the `handle` future — must be `Send` (§6.7, §9). The
  `Handler` trait carries the bound.

- **`Ctx` is empty.** Reserved as §5 and §10 said; Phase 2 puts nothing in
  it. It is passed by reference so the `Handler` signature is stable as it
  grows.
