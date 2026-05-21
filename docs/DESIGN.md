# AbyssBSD — Design

> An opinionated desktop operating system built on the
> **FreeBSD base**: a BeOS-influenced architecture and a GNOME-2-style
> graphical desktop layered on top of FreeBSD's kernel, libc, drivers,
> toolchain, and ports.
>
> Status: design captured from the initial brainstorm. Nothing built yet.

---

## 1. Vision

AbyssBSD is an **opinionated desktop OS on the FreeBSD base**. FreeBSD is kept
whole — kernel, libc, device drivers, the LLVM/Clang toolchain,
base utilities, `rc`, ports/pkg — and AbyssBSD adds, on top, a coherent
graphical desktop with a genuinely new architecture:

- one **unified, typed message primitive** that carries UI events,
  inter-thread traffic, and IPC alike (the BeOS idea);
- an **object-capability security model** woven through that bus, backed by
  FreeBSD's native Capsicum and jails;
- a **from-scratch, Wayland-free compositor**;
- a **Kit-structured, retained-mode toolkit**;
- a desktop that *looks* like GNOME 2 and *feels* like BeOS — snappy,
  message-driven, never stalling;
- a **coherent architecture** in which every component does one thing and
  is replaceable behind an enforced message-interface boundary (§3.4) —
  coherent like macOS, but swappable.

AbyssBSD is shipped as a curated FreeBSD-based desktop OS — the same form as
helloSystem or GhostBSD, but with a new architecture above the base rather
than a conventional desktop environment.

### The experience

BeOS-like — the *feel*, not the chrome. The visual surface is deliberately
conventional (GNOME 2), so the novelty is in the architecture, not the look.

---

## 2. AbyssBSD vs. the FreeBSD base

AbyssBSD is a **layer**, not a from-scratch OS. The boundary:

**FreeBSD provides** — kernel (Capsicum, jails, process descriptors,
`drm-kmod` for KMS, the `vt` console); the base libc; device drivers; the
Clang/LLVM toolchain; base CLI utilities; `init`/`rc`; the shell;
the ports tree and `pkg`.

**AbyssBSD provides** — the message bus; the capability broker; the
compositor/display server; the Kit toolkit; the desktop shell; the core
apps; and the curation that makes it one coherent product.

**The boundary is fixed.** AbyssBSD is a *desktop layer*. It runs on
FreeBSD's `rc`; the capability broker is started as an `rc` service and is
**permanently desktop-scoped** — it owns the desktop's components and
authority and grows no further. `rc` remains the system init: it supervises
the FreeBSD base and the broker itself. The broker will not subsume `rc` —
that would fork FreeBSD's init and inflate the security TCB (§10.6), the
service-scope counterpart of the D-Bus refusal (§10.1). The seam is one
handoff: `rc` starts and supervises the broker (§11.9).

AbyssBSD **does not fork the FreeBSD base.** It tracks it upstream. This is what
makes the project an order of magnitude smaller than a new-userland OS:
FreeBSD does the unglamorous 90%, and does it well.

---

## 3. Design principles

### 3.1 The implementation language

The AbyssBSD layer — bus, broker, compositor, toolkit, shell, apps — is
written in **Rust**. The FreeBSD base below is C, well-maintained upstream
and not AbyssBSD's to audit line by line (though it is honestly in the TCB,
§10.6).

**Why Rust.** AbyssBSD needs a *shipping, mature* systems language that
meets a set of hard requirements with no compiler-maturity risk — and Rust
is the one that does. What AbyssBSD needs from the language, and how Rust
provides it: memory safety without a GC (ownership + borrow checking); move
semantics; data-race-free concurrency, compiler-checked (`Send`/`Sync` —
§6.7); C FFI and header import (`extern "C"` plus `bindgen` at build time,
§11.2); generics; compile-time codegen (`derive` and procedural macros,
§6.3); and `async`/`.await` (native — §6.9). Rust supplies every one today,
in a stable toolchain — there is no language-design backlog and no compiler
to wait on.

**What Rust leaves to AbyssBSD.** Two things the architecture leans on are
not language surface in Rust, and so become first-party AbyssBSD code:

- **The looper/service framework (§6.10).** Rust has `async`/`.await` but
  no actor or service model, so AbyssBSD writes the looper, message rings,
  and supervised wiring itself, as a first-party crate. Well-trodden ground
  — a supervised unit with a thread, an executor, and typed message queues
  is the actor pattern — but code AbyssBSD owns and audits. It is the chief
  structural piece the project builds for itself.
- **Capability rights as typestate (§10.5).** Capability rights are
  expressed as compile-time typestate via phantom type parameters — sound,
  slightly verbose. The enforcement that actually matters — the kernel and
  the exporting service — does not depend on it.

Neither is a blocker; both are ordinary Rust.

### 3.2 Zero vendored dependencies — scoped to the AbyssBSD layer

The discipline is precise: it governs the AbyssBSD layer.

- **The AbyssBSD-layer code** leans on the Rust standard library and a
  curated set of *first-party* crates, plus an explicit, version-controlled
  allowlist for any external crate or build-time tool (`bindgen` is on it,
  §11.2). Adding to the allowlist is a deliberate decision. No dependency is
  taken for "a few methods" or to import a bloated abstraction layer — and
  the async runtime is notably *not* a third-party crate: the looper is
  AbyssBSD's own executor (§6.9, §6.10).
- **FreeBSD ports** the AbyssBSD layer leans on are kept to a deliberately
  small, recorded set — the font stack, `libinput`, `seatd`, Mesa (§11.2).
  Depending on a new port is a decision too.

Discipline here = dependency discipline + port discipline.

### 3.3 Opinionated

Strong, curated defaults and a coherent vision over endless
configurability. The opinion is: GNOME 2 surface, BeOS architecture,
capability security, no legacy desktop cruft.

### 3.4 One thing well, replaceable at the seam

Every component does one thing. Components interact *only* through typed
messages over the capability bus (§6, §10) — never through shared
internals, never through ambient authority (§10.1). The boundary is
therefore real, not nominal: a component is defined by the message
interface it exports, and anything exporting that interface is a valid
replacement.

This is the deliberate answer to the freedesktop desktop. That world is not
short of small components — it is short of a *coherent design* and of
*enforced* boundaries: dozens of independently-governed projects, duplicate
solutions to one problem that can never be removed, interfaces that in
practice assume specific peers so "replaceable" is fiction. macOS and
Windows win on coherence — at the price of a monolith in which nothing can
be swapped.

AbyssBSD takes both: the coherence of one opinionated design (§3.3), and
genuine replaceability — because the bus and object-capabilities (the same
mechanism already carrying IPC and security) enforce the seam
*structurally*. A component cannot reach around its interface; it has no
authority to. Small components alone are not the point — small components,
under one vision, behind enforced interfaces, with nothing duplicated, are.

Consequences:

- **No duplication.** No two components share a responsibility — the
  dependency discipline (§3.2) extended to AbyssBSD's own parts.
- **The interface is the artifact.** A component's exported message
  interface is specified as a first-class thing: the unit of design, and
  the unit of replacement.
- **Replaceable, not endlessly configurable.** AbyssBSD ships one curated
  whole (§3.3). Clean seams make a part swappable without the system
  rotting; they are not an invitation to a thousand configurations.

### 3.5 The review lens

Every component and interface is held against one yardstick — the shared
sensibility of Carmack, Ousterhout, Muratori, and Blow. They differ on
detail; the core they share is the test:

- **Hold the whole thing in your head.** A component too large to
  understand is, by that fact, a defect.
- **Earn every abstraction.** A *deep* module — a small interface over real
  substance — is good; a shallow one, and speculative generality, are not.
  Build concrete; factor when the duplication is real, not before.
- **Refuse incremental complexity.** It arrives one locally-justified
  addition at a time — that is how systemd happened. Say no to the
  increments.
- **Dependencies are liabilities**, each one weighed (§3.2).
- **No hidden control flow, no opaque state, no magic** — what the system
  does is plainly inspectable.
- **Measure; do not guess.**

§3.4 and §3.2 are this lens applied structurally; this section names the
taste behind them.

### 3.6 Performance & memory budgets

A 12-core, 5 GHz, RTX-5060-class machine should never feel slower than a
1995 desktop did. That it routinely does is not a hardware problem — it is
**accreted latency**: compositors that buffer extra frames, toolkits that
re-lay-out the world on every change, garbage-collector pauses, async hops,
framework upon framework. The hardware got a thousand times faster and the
software spent all of it.

AbyssBSD's architecture is built to remove those causes — one native toolkit,
message-passing, no GC anywhere (Rust), direct scanout (§7.4),
control-plane components kept out of the data path. The budgets here *hold
it to that*: performance is a designed, measured, **enforced** constraint —
not a hope.

**Latency — bounded by the refresh rate, and nothing else.**

- **Input-to-photon.** The software AbyssBSD controls — input service, bus,
  compositor — adds **at most one refresh interval** of latency. A response
  to input lands at the next vsync; past that the desktop is
  refresh-rate-bound, because waiting for vsync is the only wait left.
- **Frame budget.** The compositor finishes every frame within the refresh
  interval, with headroom — **zero dropped frames** under desktop load. An
  idle desktop composites nothing (damage-tracked partial compositing).
- This is §6.8's "the UI thread never blocks," made quantitative.

**Memory — framebuffers plus a bounded constant.**

- The idle desktop — every resident component and the bus, no apps — is
  budgeted at the display's **triple-buffer cost plus a bounded constant**
  for code and data: on the order of **256 MB at 4K**, dominated
  by the framebuffers, and scaling *down* at lower resolution. (A current
  GNOME/KDE desktop idles at 1–2 GB.)
- Every component declares a **memory budget in its manifest** (§11.9).
- Budgets start conservative and are **tightened by measurement** (§3.5) —
  never inflated to fit.

**Idle CPU — zero.** Components are event-driven; a looper wakes only on a
message (§6). An idle AbyssBSD desktop does no work and burns no measurable
CPU. No polling loops, anywhere.

**The budgets are walls, not targets.** Memory is enforced by the broker
via jail resource limits — a component *cannot* exceed its manifest budget;
the kernel stops it. Input-to-photon is measured continuously by a harness
built from the compositor's present-feedback timestamps (§7.4), on the
reference machine (§5), and **gates CI** on the p99 against budget (a margin
absorbs normal machine and thermal variance). Exceeding either budget is a
build or runtime failure; a legitimate increase is a deliberate, reviewed
manifest change, so every gram of growth is visible and intentional. Soft
tracking is how the industry drifted into the mess this section exists to
prevent.

**Non-binding goal — 32-bit degradability.** Distinct from the budgets above,
which are walls: AbyssBSD's own code is kept **32-bit-clean** — no
gratuitous assumption of 64-bit pointers, a 64-bit address space, or a
64-bit `usize`. The aim is that the system could *degrade* to run as a
32-bit OS — concretely on **PPC32** (were FreeBSD's 32-bit PowerPC paths
restored) or **RV32** (were a FreeBSD RV32 port to exist). It is explicitly
**non-binding**: the substrate is not AbyssBSD's to provide — FreeBSD's
32-bit PowerPC support is being deprecated, there is no FreeBSD RV32 port,
and a 32-bit FreeBSD Rust target would need standing up — so it cannot be a wall.
It earns its place as a **forcing function**: code that genuinely fits a
32-bit machine — a 4 GB address space, modest RAM, usually the CPU render
backend (§7.1) — has *proven* it carries no bloat. The section's thesis
taken to its end, and a door kept open to constrained and older hardware,
and to small RISC-V.

---

## 4. Architecture stack

```
  ┌─ AbyssBSD layer (zero vendored deps) ───────────────┐
  │  Desktop shell (panel, app menu, window list)    │  GNOME 2 look
  │  Apps   ·   Toolkit (Kits, retained-mode)        │
  │  ─────────── minimal graphical floor ─────────   │
  │  Compositor / display server  (CPU + GLES)       │
  │  Message bus  ·  capability broker  ·  services  │
  └──────────────────────────────────────────────────┘
  ┌─ FreeBSD base (kept whole, tracked upstream) ────┐
  │  rc / init   ·   base utilities   ·   shell      │
  │  ports / pkg   ·   Clang/LLVM toolchain          │
  │  base libc                                       │
  │  kernel:  Capsicum · jails · drm-kmod · vt       │
  └──────────────────────────────────────────────────┘
```

---

## 5. The FreeBSD base

- **Kept whole, tracked upstream, not forked.** AbyssBSD is a derivative in
  the helloSystem/GhostBSD sense — a curated build of FreeBSD plus the
  AbyssBSD layer.
- **Native capability substrate.** Capsicum (`cap_enter` capability mode +
  `cap_rights_limit` per-fd rights), jails, and process descriptors are the
  kernel mechanisms the security model (§10) is built on — kernel-enforced,
  maintained, upstream. This is the reason the project chose FreeBSD.
- **Graphics.** DRM/KMS comes from `drm-kmod` (FreeBSD's port of the Linux
  DRM drivers via `linuxkpi`); the userland-facing DRM uAPI is the standard
  DRM ioctl interface, so the compositor (§7) targets it directly.
- **Toolchain.** Clang/LLVM is FreeBSD's system compiler. The AbyssBSD layer
  is built by **`rustc`** — the Rust toolchain, itself a FreeBSD port and
  LLVM-based (§3.1). The FreeBSD base self-hosts inherently, and the Rust
  toolchain is mature and shipping, so there is no compiler-maturity risk
  to carry (§3.1).
- **Console.** FreeBSD's `vt` console is kept as the low-level safety valve
  for early-boot messages and panic output, since the AbyssBSD desktop has no
  text mode (§9). It is a base facility, not a userland login.
- **Hardware scope.** AbyssBSD adds *no hardware enablement of its own* —
  supported hardware is exactly what FreeBSD's drivers and `drm-kmod`
  provide. `drm-kmod` lags Linux, so the usable GPU set trails. AbyssBSD is
  VM-first early on; the bare-metal development and test reference is a
  desktop with an **AMD RX 6750 XT (RDNA2)** — first-class `amdgpu` support
  under Mesa (OpenGL now, Vulkan when the deferred backend lands), well
  covered by recent `drm-kmod`.

---

## 6. Core paradigm — the unified message primitive

AbyssBSD adopts BeOS's defining idea: **one message primitive** carries
everything — UI events, inter-thread traffic, IPC, the display protocol
(§7.2), and capabilities (§10). It *is* the IPC bus; there is no separate
D-Bus-style mechanism.

### 6.1 One type, three transports

A **looper** is a thread with a message queue; **handlers** are the objects
it dispatches messages to — the BeOS `BLooper`/`BHandler` model (each window
is a looper, §8). The primitive is used three ways, and only the third
involves a wire format at all:

- **In-process** — a message is a value moved by ownership through a
  looper's queue. No serialization.
- **Inter-thread** — the same: a value moved between looper threads.
- **Inter-process** — the message is serialized into an *envelope* (§6.2);
  the wire format exists *only* here. This is what "pointer-passed
  in-process, serialized across" means concretely.

The looper, its handlers, and these three uses are provided by a
first-party **looper/service framework** (§6.10) — a crate AbyssBSD writes
and owns.

### 6.2 The envelope

The cross-process representation is a universal envelope:

```
  ┌──────────────────────────────────────────────┐
  │ header:  interface id · method/type id       │
  │          flags · payload len · handle count  │
  ├──────────────────────────────────────────────┤
  │ payload: the serialized message body (§6.3)   │
  ├──────────────────────────────────────────────┤
  │ handles: [ {kind, value, cap_rights} ] …      │
  └──────────────────────────────────────────────┘
```

Handles are file descriptors (passed via `SCM_RIGHTS`) or bus tokens, each
carrying its Capsicum rights mask (§10.2). **Large data never travels
inline** — it is shared as a memory handle (a `memfd`/shm capability) in the
handle array; dmabuf buffer sharing is exactly this case. Envelopes nest:
the bus can wrap one inside another for routing.

### 6.3 Payload — self-describing, with typed views

The payload is **BMessage-like**: a self-describing structure of named,
typed fields. This is deliberate — it is what makes applications
**scriptable** (§6.6): a script can build and inspect messages with no
compile-time knowledge of them.

AbyssBSD's own code is not written against an untyped dict, though. Rust
`derive` and procedural macros generate **typed views** over the dict:

- OS code (compositor, toolkit, services) programs against typed structs —
  compile-time field checking, and `Cap<Interface>` send APIs that accept
  only that interface's messages (§6.5).
- Scripts work the self-describing dict directly.
- A received message is always validated on receipt (`from_dict` is
  fallible) — mandatory once scripts can send arbitrary messages, so it is
  no extra cost.
- Hot paths (input events, frame callbacks on the display fast-path) may use
  a compact typed encoding rather than the tagged dict form.

### 6.4 Transport & wire format

- **Wire format** — owned structs with a copying serializer; tagged and
  self-describing, so scripts and generic tools can parse without a schema.
  Not zero-copy: construction ergonomics win over marshalling cost.
- **General IPC** — `SOCK_SEQPACKET` Unix sockets: message boundaries
  preserved, ordered, reliable, native fd-passing via `SCM_RIGHTS`, kernel
  flow control.
- **Display fast-path** — a shared-memory ring with a `kqueue` doorbell, for
  high-frequency compositor traffic. Both transports are built for M1.

### 6.5 Addressing, capabilities & replies

There is no namespace of destinations. **You send to a capability you
hold** — `cap.send(msg)`; the bus routes a cross-process send by the token
inside the capability. Addressing and authority (§10) are the same thing.

- Capabilities are statically typed by interface: a `Cap<Display>` only
  accepts display-protocol messages.
- **Replies** ride the same mechanism — a request carries a *reply-to*
  capability, and the reply is a message sent back to it.

### 6.6 Scripting

Scriptability is a *protocol*, not merely the payload format. Following
BeOS: every handler answers a standard suite — **introspect**, **get** /
**set property**, **invoke**. An external tool can thus discover and drive
any app it holds a capability to.

Scripting authority *is* capability authority: a scripting capability
carries Capsicum-style rights (§10), so an inspect-only cap, a
set-properties cap, and a full-invoke cap are genuinely different grants.
The language scripts are written in is a later concern.

This same introspection surface is the natural substrate for accessibility
tooling — a screen reader is, structurally, a scripting client. But a
dedicated accessibility stack is a **scoped-out non-goal**: the team is too
small to carry it. AbyssBSD provides the substrate, not the stack.

### 6.7 Why Rust fits this

Per-window-thread + message-passing is safe by construction only in a
language with **compiler-checked concurrency** — a guarantee about which
values may cross a thread. Rust has it as a settled, shipping feature: the
`Send` and `Sync` marker traits, auto-derived and compiler-enforced, make a
value unsafe to move or share between threads a *compile error*, not a
runtime bug; the borrow checker does the rest. BeOS fought C++ for thread
safety; Rust gives it by construction.

### 6.8 Responsiveness as a contract

"The UI thread never blocks" is an enforced rule, not an aspiration. The
per-window-thread model and message-passing make non-blocking the default;
with client-side rendering (§7), a hung app simply stops updating its
buffer — the compositor stays live regardless. (How the looper enforces
this — as an async executor — is §6.9.)

### 6.9 The looper as an async executor

A looper (§6.1) is a thread, a message queue, **and a cooperative async
executor**. A handler may be `async`, and may `.await`.

A request/reply **call** — send a request, receive its reply (the
interfaces carry a reply-to capability, `interfaces/README.md`) — is a
`Future<Reply>`. Awaiting it **suspends the handler, never the looper's
thread**: while the handler is suspended the looper goes on dispatching
other messages and running other handlers, and when the reply arrives it
resolves the `Future` and the handler resumes — its code having read
straight through, as though the call were blocking, with no hand-written
state machine.

This makes §6.8's contract — *the UI thread never blocks* — **mechanically
true**: `.await` can only suspend a handler; it has no way to block the
thread. The alternative — classic callback dispatch, where a reply is just
another message correlated by hand — is rejected: it turns every multi-step
interaction into a hand-rolled state machine, the exact boilerplate this
model removes.

**Per-handler serialization holds.** While one invocation of a handler is
suspended on an `.await`, the looper runs *other* handlers — it does not
start another message for that *same* handler. Each handler still sees its
messages one at a time, in order; async adds concurrency *between* handlers,
never re-entrancy *within* one. BeOS's `BHandler` invariant is kept, with
async added beneath it.

Each window is its own looper on its own thread (§8), so one window
awaiting never stalls another. The model rests on Rust's native
`async`/`.await` and `Future` — stable language features. The looper *is*
the executor that drives them; Rust exposes `Pin` and `Waker` as the
machinery, which the looper/service framework (§6.10) encapsulates so
handler code never sees them. No language feature here is pending — the
substrate exists today.

### 6.10 The looper & service framework

§6.1's looper and §6.9's async executor are a **first-party AbyssBSD
framework** — a crate the project writes, owns, and audits. Rust has
`async`/`.await` but no actor or service model, so AbyssBSD builds one. It
is well-trodden ground — a supervised unit with a thread, an executor, and
typed message queues is the actor pattern — but it is AbyssBSD code, and it
is the chief structural piece the project builds for itself (§3.1).

The framework provides:

- **Loopers** — a thread, a typed message queue, and the §6.9 cooperative
  executor. Each window and each component is a looper.
- **Handlers** — a handler runs to completion and is **not re-entered
  across `.await`** (§6.9's per-handler serialization); the framework
  enforces this invariant.
- **Rings** — typed point-to-point message queues. An endpoint is a
  `RingCap`, move-only — exactly one sender, one receiver; a dead peer
  surfaces to a handler as a typed `RingClosed` error.
- **Transport** — an in-process ring is a queue in one address space; the
  inter-process bus is the same ring API over `SOCK_SEQPACKET`/shm with
  `SCM_RIGHTS` fd-passing, the §6.2 envelope as its wire format. Component
  code is written once against the ring API, transport-agnostic.

A message type crossing the inter-process bus must be serializable — no
borrows, no raw pointers; a derived `Wire` trait marks the admissible
types, and capability handles are `Wire` (the transport marshals embedded
fds out-of-band via `SCM_RIGHTS` — the §6.2 payload/handle split).

**The broker realizes §11.9 on this framework.** It is the sole authority
to create components and connections — no ambient spawn. Bringing up a
component set (§11.15) it pre-creates every ring and spawns each component
looper, moving the endpoints into each child's bundle: the broker's
eager, pre-wired, statically-auditable authority graph (§11.9). Each spawn yields a
supervision handle the broker holds for the session; a dead peer surfaces
as a `RingClosed` error, and restart policy stays in the broker manifest.

AbyssBSD thus writes this framework *and* the components on it. The
framework is bounded and conventional — but it is real code in the core,
and §3.6's budgets cover it.

---

## 7. Display & input

### 7.1 Compositor / display server

Written from scratch, it plays the role BeOS's `app_server` played:
the single display server, speaking the native message primitive.

- Talks to **DRM/KMS directly** via the DRM ioctl uAPI (provided by
  `drm-kmod`, §5) — no `libdrm`.
- **Render-backend seam.** A render-backend abstraction. v1 builds two
  backends; a third is planned:
  - a **CPU / dumb-buffer** backend — needs zero GPU stack;
  - a **GLES** backend (OpenGL ES 3.x via EGL) — the accelerated path;
  - a **Vulkan** backend — deferred post-v1, behind the same seam (§13).
- GPU-accelerated by default: the GLES backend via Mesa is the M2 target. It
  covers all hardware Mesa accelerates — far wider than Vulkan, which is the
  reason GLES was chosen — and degrades to Mesa's `llvmpipe` software GL
  where there is no driver. AbyssBSD's own CPU backend is the zero-Mesa floor:
  the system boots and renders in a VM with no GPU stack at all.

### 7.2 Display protocol — native, not Wayland

Because there is *one* unified message primitive, the display protocol is
**not** a separate Wayland wire format. The compositor speaks the native
message primitive directly (BeOS `app_server` style). Apps render their own
buffers and share them as dmabuf handles carried in messages. Its concrete
design is §7.4.

Wayland compatibility, if ever built, is an **optional later compat layer**
for running third-party Wayland apps — never the native path.

### 7.3 2D rendering

A NanoVG-style 2D scene renderer (glyph atlas, path tessellation, rounded
rects, gradients, clip stacks, damage tracking). The CPU/GLES backend seam
is exposed **up at the toolkit's drawing API** — the minimal-UI terminal and
the recovery floor (§9) must draw before, and independently of, Mesa.

### 7.4 The display protocol

The display protocol is the compositor's exported interface (§11.1). It
rides the message bus (§6), is native rather than Wayland (§7.2), and is
designed around two first-class cases: ordinary composited windows, and
full-screen games that scan out directly.

- **Connection & outputs.** On connect (the client holds a `Cap<Display>`,
  §6.5) a version handshake runs. The compositor advertises each output —
  resolution, refresh, scale, the scanout-capable format/modifier set, and
  the VRR range — and reports hotplug.
- **Surfaces & roles.** A client creates a *surface* and gives it a *role*
  — top-level, popup, or fullscreen — which fixes how the compositor treats
  it.
- **Buffers.** A client renders into a buffer and attaches it. Buffers are
  dmabuf handles (§6.2) tagged with explicit format + modifier. The protocol
  is **API-agnostic**: GLES, Vulkan, and CPU-rendered buffers are identical
  to it. Pixel data is never inline — always a handle.
- **Commit & frames.** Surface state is double-buffered: the client stages
  buffer, damage, and sync points, then *commits* atomically. The compositor
  returns *frame callbacks* (when to draw next) and *present feedback* (when
  a frame reached the display, with timing) so clients — games especially —
  can pace themselves.
- **Explicit synchronization.** Each buffer carries an *acquire* timeline-
  semaphore point (ready when it signals) and is given a *release* point
  (reusable when it signals); the semaphore handles travel in messages.
  Implicit dmabuf fencing is not used — explicit sync is the only model,
  because Vulkan requires it and it is the correct one.
- **Window management & decorations.** The compositor does WM (§11.1) and
  draws every window's title bar and frame — decorations are
  **server-side**. The protocol carries it: the compositor sends *configure*
  events (size, state, focus, output, scale); the client sets its title and
  may request state changes (minimize, maximize, fullscreen)
  programmatically. Title-bar and border drags, and the min/max/close
  buttons, are handled compositor-side with no client round-trip — so window
  manipulation is frame-perfect (§3.6).
- **Input.** The compositor routes input to the focused surface (§11.1);
  pointer/keyboard/touch events arrive on the surface's connection. Direct
  scanout (below) changes only the *output* path — input is unchanged.
- **Clipboard & drag-and-drop.** Inter-client data transfer is
  compositor-mediated and **authorized by user action** — a copy, a paste,
  a drag, a drop. The compositor holds the current selection; a client reads
  it only when the user pastes into it, and drag data reaches a surface only
  on the drop. No client snoops the clipboard ambiently — unlike X11, where
  any client may read any selection at any time. The user's gesture *is* the
  capability (§10).
- **Screen capture.** Reading pixels a client did not draw — for a
  screenshot, a screen recorder, or screen sharing in a call — is a
  capability, never an ambient power. The compositor already holds every
  surface and output buffer, so it exports *capture* behind a capability
  scoped to a single surface, a single output, or the whole desktop, and
  bounded to a one-shot frame or a continuous stream; a live stream is
  surfaced in the status-indicator area (§11.10) for as long as it runs, so
  capture is never silent. The grant is authorized the way the clipboard is —
  by a user action, the gesture *is* the capability (§10) — and, as a
  service-object capability, it is revocable (§10.5): the user ends the share
  and the capturer's next frame fails with `Revoked`. No client reads the
  screen ambiently — unlike X11, where any client may read any pixel at any
  time.

**Full-screen pass-through — managed direct scanout.** When a surface holds
the fullscreen role on an output:

- The compositor tests eligibility — opaque, covers the output exactly,
  buffer format/modifier scannable by the display.
- If eligible, it **page-flips the client's buffer directly to KMS** — no
  composition pass, no copy — and sends a *scanout-active* event so the
  client can size its swapchain to the output and pick a scanout-capable
  format. Near-exclusive-fullscreen performance.
- The compositor **keeps KMS ownership.** The instant an overlay is needed
  — notification, alt-tab, lock screen — it sends *scanout-inactive* and
  resumes compositing, seamlessly; the client need not react.
- A fullscreen surface may opt into **immediate (tearing) present** for
  lowest input latency, and the compositor drives **VRR** within the
  output's range. Both are per-surface and opt-in.

A game does nothing special for this: it uses an ordinary Vulkan swapchain.
AbyssBSD supplies the Vulkan WSI and the EGL/GLES platform backend in its Mesa
port (§11.2) that target this protocol; "going fullscreen" plus the
compositor's eligibility test is all direct scanout needs. Direct scanout
bypasses the compositor's own renderer entirely, so it is independent of the
GLES-vs-Vulkan backend choice (§7.1) — and client Vulkan ships in v1 even
though the compositor's own Vulkan backend does not.

### 7.5 The input interface

The input service (§11.1) turns hardware input devices into one normalized
event stream. Its interface is **internal and one-directional** — input
service → compositor; clients receive input via the display protocol
(§7.4), never this interface directly.

- **Exports** — *device lifecycle* (a keyboard / pointer / touch / tablet
  device appeared, changed, or left, with its kind and axes) and the
  *normalized event stream* — keyboard, pointer (relative and absolute,
  buttons, scroll), touch, gestures, tablet — each event device-tagged and
  timestamped. It also exposes a coarse *activity signal* — distinct from
  the event stream — so the power service can detect idle (§11.8) without
  subscribing to raw input.
- **Normalization** is `libinput`'s work: debounce, pointer acceleration,
  tap-to-click, palm rejection, natural scroll, gesture synthesis. The input
  service applies device configuration and emits clean events.
- **Keyboard interpretation lives here.** The input service owns the xkb
  keymap (layout read from settings). Each key event carries **both** the
  raw keycode — the physical key, layout-independent, which games need
  (WASD by position regardless of layout) — and the cooked interpretation
  (keysym, modifier state, text). Keymap logic sits in the one component
  whose job is interpreting input hardware; no per-client keymap is needed.
  (Complex text input — IME / CJK composition — is a separate concern beyond
  keymap, with its own later design.)
- **Consumes** — the device monitor (input-device hotplug), `seatd` (the
  capability to open each device), and the **settings service** (§11.5) for
  per-device configuration: acceleration profile, tap-to-click, natural
  scroll, key-repeat rate, keyboard layout.

### 7.6 Multi-monitor behavior

§7.4 advertises every output at the protocol level; this is the desktop
*behavior* across them. The compositor is the authority — it owns the
output coordinate space, window placement, and per-output scanout (§11.1's
WM role); the shell renders furniture per output by consuming §7.4's output
advertisements (§11.10).

**One coordinate space, independent frame clocks.** The outputs form a
single continuous coordinate space — a window may be placed anywhere and may
straddle a seam — but each output is composited and page-flipped on **its
own refresh clock**. A 60 Hz and a 144 Hz monitor each run at their native
rate; the compositor never locks the desktop to the slowest. §3.6's "limited
by the refresh rate" is a *per-output* budget — the only honest reading when
the rates differ. A straddling window is paced by, and renders at the scale
of, the output it predominantly occupies; the compositor resamples it for
any other output it overlaps — briefly soft there, a mid-drag transient.

**Mixed scale.** Each output advertises its scale (§7.4); a window renders
at the scale of the output it is on and re-lays-out (§8) on a `configure`
that changes it as the window moves between outputs. Per-output scale,
output arrangement, primary designation, and mode (resolution/refresh) are
persisted configuration (§11.5), applied by the compositor; absent it the
defaults are native mode, DPI-derived scale, the KMS-reported primary, and
outputs placed left-to-right.

**Window placement.** A new window opens on the **active output** — the one
with the focused window, else the pointer's. A window restored from saved
state returns to its output if that output still exists. **Maximize and
fullscreen are per-output**: maximize fills the output the window is on;
fullscreen — including managed direct scanout (§7.4) — takes a single output
and leaves the others compositing, so a game may scan out on one monitor
while the desktop runs on another. There is no span-across-all mode; a
window crossing monitors is the user sizing it so.

**Hotplug.** On connect, an output joins the coordinate space — its
remembered position if known, else placed to the right — and gains its
furniture. On disconnect, its windows **migrate** to a surviving output (the
primary), re-placed, never lost; configuration for a known output is
retained for its return.

**Per-output furniture, singular surfaces.** Each output is self-sufficient:
the shell draws its panels and desktop surface on every output, and the
window list on each panel is scoped to that output's windows (§11.10). Some
surfaces are deliberately *not* replicated — notification popups appear on
the active output only, not flashed across every monitor; and the session
lock and greeter cover **all** outputs (an output left showing the session
would be a lock bypass, §11.11/§11.15), with the prompt on the primary.

### 7.7 Window management — tiling and floating

Window management is the compositor's (§7.4, §11.1): it owns placement, focus,
and stacking. *How* it places windows is a **layout policy** — a bounded module
behind a defined internal seam — and AbyssBSD ships two, first-class, from
early on:

- **Tiling** — Sway/i3-grade. Windows fill the output without overlap, split
  into horizontal and vertical containers; navigating, splitting, resizing, and
  moving windows between containers and **workspaces** is keyboard-driven
  through configurable key-chords. This is the power-programmer-first
  experience — and the first to exist: it needs only the compositor and a
  keyboard, no toolkit and no pointer-driven furniture, so it is usable from
  the minimal-UI stage (§9) the moment the compositor manages more than one
  window.
- **Floating** — conventional overlapping windows, pointer-placed. This is the
  placement the GNOME-2 desktop shell (§11.10) presents, and the **shipped
  default** (§3.3): most users get the GNOME-2 desktop; tiling is the
  first-class alternative they may select.

Both are policies over **one shared set of primitives** — the output coordinate
space (§7.6), workspaces, surface roles (§7.4), focus, and the `configure`
protocol. The GNOME-2 desktop is not a second mechanism: it is the floating
policy plus the shell's furniture. The tiling WM is therefore not throwaway
early scaffolding — it is the first consumer of the permanent window-management
core that the desktop then reuses (§3.5: build the concrete thing, reuse it
when the reuse is real).

The policies coexist within a session — a surface may be tiled or floating, and
dialogs and popups (§7.4 roles) float regardless; which policy is the *default*
and which furniture is shown is what makes the "tiling experience" and the
"desktop experience" distinct. Because decorations are server-side (§7.4) the
frame follows the policy with no client involvement: full title bars when
floating, thin borders and container/tab headers when tiling.

**Key-chords.** Bindings are configuration (§11.5), not compiled in. The input
service interprets the keymap and emits keysym + modifiers (§7.5); the
compositor matches each event against the binding table and, on a match,
performs the window-management action — otherwise the event passes to the
focused surface. Chord *sequences* and *modes* — a prefix that re-scopes the
keys that follow, i3's "mode" — are supported. This is the same chord-matching
the compositor uses for global shortcuts (§13); a WM binding is the case where
the matched action is internal.

**The bar.** The tiling experience's bar — workspaces, the focused-window
title, the status indicators — is the desktop shell (§11.10) in a minimal
configuration; the GNOME-2 panels are that same component, fuller. One
furniture component, scaled to the experience.

**Restraint.** The tiling experience is held to the same lens as everything
else (§3.3, §3.5): Sway/i3 in spirit — fast, legible, keyboard-first, a small
and well-specified feature set — and deliberately **not** Hyprland-style
maximalism. Animation is not the product, and the configuration surface is
curated, not infinite. "Power-user-first" describes the input model — it is not
an invitation to a thousand knobs.

---

## 8. Toolkit

- **Retained-mode**, organized as **Kits** (the BeOS structure):
  - *Interface Kit* — widgets, layout, theming, the view hierarchy.
  - *Application Kit* — app lifecycle, the looper/handler model, messaging.
  - *Storage Kit* — files, XDG-resolved locations (§11.4); typed
    attributes and live queries are post-v1 (§11.16).
  - *Media Kit* — later.
- **Per-window threads** — each window is a looper.
- The toolkit themes the **widgets** — the controls within a window's
  content — to the **GNOME 2 appearance**. Window decorations (title bars,
  frames) are drawn by the compositor, server-side (§7.4); the panel,
  application menu, and window list are the shell's (§11.10). The three draw
  from **one shared theme** so the desktop is visually coherent. The BeOS
  influence is the architecture underneath, not the chrome.

**Icons.** The visual target is a single coherent icon set in the spirit of
Red Hat's *Bluecurve* — the clean, restrained, unified iconography of the
GNOME 2 era. **Haiku's icon set** is a strong concrete candidate: a similar
aesthetic, and — as the BeOS recreation — spiritually of a piece with
AbyssBSD's BeOS lineage. Haiku is MIT-licensed, which would be compatible;
the icon artwork's license is to be confirmed before adoption. Failing
that, an asset to commission or assemble in the same spirit. (The standing
objection to the GNOME 2 era's software is its daemons and abstraction
layers, §10 — never its artwork.)

**View ownership — an arena of views, addressed by handle.** A window's
view hierarchy is *not* a tree of pointers or reference-counted nodes. One
**arena per window** owns every view; the parent/child structure and every
cross-reference — input focus, an event's target, layout relations, an
app's handle to a widget it created — is a **`ViewId`**, a generational
handle (a `struct ViewId(u32)` newtype — index + generation, the standard
slotmap pattern). Resolving one is an
arena lookup that generation-checks: a `ViewId` outliving its view resolves
to `none` — safe and observable, never a dangling pointer, never a leak.
The tree is single-ownership (the arena owns); tree-walks take transient
borrows that do not outlive the walk; nothing holds a long-lived reference,
so there are no ownership cycles and no `Rc`/`Arc`. Retained-mode means only the
dirty `ViewId` set is re-laid-out and repainted — the desktop stays limited
by the refresh rate, not by busywork (§3.6). The `ViewId` is also the
internal handle behind a scripting specifier path (§6.6).

**Uniform Rust — no GC.** The whole system — broker, compositor, toolkit,
services, shell — and apps alike are ordinary Rust: explicit allocation,
deterministic destruction (`Drop`), no GC anywhere in the resident set,
fully budgetable (§3.6). `Rc`/`Arc` reference-counting is an explicit,
local opt-in, never a default. The arena+`ViewId` model above is the right
ownership model for the view tree regardless: cache-friendly,
refcount-free, with safe generational handles, and one toolkit crate the
shell and every app link alike. The discipline that the resident desktop
holds no `Rc`/`Arc` cycles and stays inside §3.6's budgets is a code-review
rule.

The view tree stores **no callbacks**, by the same design choice §6.9
makes: a widget interaction is routed to a `ViewId` and emitted as a
*message* to the app's looper (§6.9, §6.10), not a stored closure. The per-window arena is
that window looper's private, share-nothing state (§6.10); cross-window
widget references are structurally impossible, which is correct.

---

## 9. Desktop experience

- **No text mode.** Boot lands directly in the AbyssBSD graphical session.
  There is no AbyssBSD text-mode login. (FreeBSD's `vt` console still exists
  beneath, §5, as a safety valve only.)
- **First boot = minimal framebuffer UI.** `rc` → broker → compositor (CPU
  backend) → one terminal window. Early bringup auto-logs straight in; the
  graphical greeter and the login/session lifecycle are §11.15.
- **The minimal framebuffer UI is the permanent recovery floor.** It is
  simultaneously the bringup environment and the rescue environment. It
  uses the CPU render backend so it always comes up.
- **The terminal emulator is load-bearing from M1** — a real VT (full
  escape-sequence handling, hosts an editor, runs a build, survives resize).

---

## 10. Security model

AbyssBSD uses an **object-capability (ocap)** model. It is not a subsystem
bolted on beside the message bus — it *is* the bus.

### 10.1 Principle

- **No ambient authority.** A process is born holding nothing. It cannot
  name or reach any resource it was not explicitly given.
- **Authority is an unforgeable handle.** To hold a reference to an object
  *is* the permission to use it.
- **Authority travels only in messages.** A message can carry handles; the
  recipient implicitly gains the authority those handles confer. Because the
  unified message primitive already carries handles (§6), the security model
  and the IPC model are the same mechanism.
- **Attenuate and delegate, never amplify.** A holder may pass on a handle,
  or a weaker derivation of it, but can never manufacture more authority
  than it was given.

This is the structural reason AbyssBSD rejects D-Bus: D-Bus is a
names-and-methods bus with no notion of authority, so security has to be
bolted alongside it (polkit, portal services, Flatpak). A capability bus
needs none of them.

### 10.2 Capability representation

One "handle" type in the message primitive, with two backings, transparent
to the holder:

- **Kernel resources** (devices, memory, files, sockets) — a file
  descriptor, passed between processes by `SCM_RIGHTS`, **with a Capsicum
  rights mask** (`cap_rights_t`) limiting it.
- **Userland service objects** — a bus routing token naming an object
  exported by another process, carrying its own rights set.

Because FreeBSD's Capsicum enforces per-fd rights *in the kernel*, both
backings are genuinely enforced — there is no "advisory mask on a raw fd"
gap. This is the concrete payoff of choosing FreeBSD over Linux.

### 10.3 Enforcement — native Capsicum + jails

| Concern | Mechanism |
|---|---|
| No opening resources by name | Capsicum **capability mode** (`cap_enter`) — irreversible, kernel-enforced; the only way to get a resource is to be handed a handle |
| Per-handle rights | Capsicum `cap_rights_limit` — fine-grained, kernel-enforced fd rights |
| Isolation container | **jails** |
| Process handle | process descriptors (`pdfork`) |
| Handle transport | `SCM_RIGHTS` for fd-backed capabilities; bus tokens for service objects |

This is the model Capsicum was built for — AbyssBSD uses it natively rather
than approximating it.

### 10.4 The broker

A **broker** is the sole minter of authority. It is the only component that
opens devices and creates jails; it hands each child its initial capability
set at spawn time. A child cannot open those resources itself — capability
mode forbids it.

- **Rooted.** The broker is started early by `rc` and bootstraps the first
  capabilities for the AbyssBSD session.
- **Recursive delegation.** Any capability holder can sub-broker for its own
  children, carving sandboxes out of its own authority. The compositor, for
  example, is *handed* the GPU device and forbidden from opening anything
  else (which is also where `seatd` fits, §11.1).
- **Modeled on Casper.** FreeBSD's `libcasper` is precisely this pattern — a
  service performing privileged operations for sandboxed processes, itself
  sandboxed, split into small single-purpose sub-services. AbyssBSD's broker
  follows that decomposition and may interoperate with Casper services.

### 10.5 Capability mechanics

§10.1–§10.4 give the model; this is how it is concretely realized.

**Two rights layers, one law.** A capability's rights live in one of two
vocabularies. An fd-backed capability (§10.2) carries a **`cap_rights_t`**
mask — the fixed Capsicum right set, kernel-enforced. A service-object
capability carries **object rights** — the per-interface named set
(`Cap<Settings>` read/write, a `RingCap`'s send/recv, scripting's
introspect/get/set/invoke), enforced by the exporting service. A manifest
(below) requests a capability in object-rights terms; the broker translates
an fd-backed request to a `cap_rights_t` mask by a fixed per-device-class
mapping and applies it with `cap_rights_limit` before passing the fd. Both
layers obey the *same* monotonic law — `cap_rights_limit` only restricts,
the rights phantom-type narrows only to a subset, §10.1 forbids
amplification: `narrow` is a fresh `cap_rights_limit` on an fd-cap and a
fresh lesser token on a service-object cap. The kernel enforces
non-amplification for fd-caps for free.

The honest caveat: rights modeled as phantom type parameters keep a
component honest *with itself*, intra-process — a `narrow` that would widen
fails to compile — but they do **not** secure a process boundary, since one
process cannot trust another's compiler. Inter-process, security rests on `cap_rights_t` (kernel) and the
exporting service's *runtime* check. A service-object token's rights are
recorded by the **issuer** and never asserted by the holder — that is what
makes them unforgeable.

**The manifest.** Each component ships a small, declarative, legible
manifest (§3.5 — never an opaque blob). It declares: *identity* (name,
exported interface, version); the *capabilities needed* — each a kind (peer
connection, device, Casper service, settings subtree) and its object
rights, the list being the component's whole authority and the static
authority graph (§11.9); *jail parameters* (filesystem visibility,
network — usually none — and the principal to run as); the *resource budget*
(memory §3.6, fd/CPU caps, applied as jail/`rctl` limits); and the *restart
policy*. One format, two trust profiles: a **system-component** manifest
ships with the OS and is curation-vetted — the grant is the manifest
verbatim; an **app** manifest lives in the `.app` bundle (§11.14) — the
grant is the manifest **∩ the user's approval**.

**Broker bootstrap.** `rc` execs the broker as root. The broker is the one
component that **never enters capability mode** — it must keep creating
jails and opening devices for delegated spawns at runtime — so it is the
permanently-unsandboxed root of authority, and therefore the smallest and
most-audited thing in the TCB. It reads the system manifests (a malformed
*system* manifest is a boot fault → the §9 recovery floor), computes the
static authority graph, opens the initial device capabilities, then creates
the jails and spawns the system layer (§11.15). Each child enters
capability mode itself, in a tiny trusted startup shim, *after* receiving
its bundle. The jail is the hard boundary; `cap_enter` is defense-in-depth
on an already-empty bundle.

**Casper, composed.** A Capsicum-sandboxed component cannot resolve DNS,
read `passwd`, or call `sysctl` — those open resources by name. FreeBSD's
Casper provides exactly these as sandboxed services, and Casper is the
*base*, not a vendored dependency. A component declares the Casper services
it needs in its manifest; the broker sets up each `cap_channel_t` — itself
an fd — into the bundle. The division is clean: the broker does spawn,
jail, and capability-granting; Casper provides the privileged-by-name
operations. The broker is *modeled on* Casper and composes *with* it; it is
not built on it.

**Revocation.** Revocability is a per-capability design choice, by backing.
A **service-object capability is revocable** — the bus token is already an
indirection the exporting service resolves, so the issuer invalidates it
and the next use fails with a typed `Revoked` error (the sibling of
`RingClosed`, and of a stale `ViewId` resolving to `none`). This is the
object-capability *membrane* pattern, and it costs nothing extra here. An
**fd-backed capability is not individually revocable** — one process cannot
close another's fd; it is revoked instead by *resource lifecycle* (an
unplugged device — the kernel fails the fd, the device monitor observes it)
or by *holder restart* (the broker holds a `pdfork` descriptor;
restart-with-fresh-bundle drops everything, and `PeerRestarted` re-wires
peers — supervision is coarse revocation). The rule follows: a capability
that must be revocable per-holder is exported as a *mediated service
object*; a stable infrastructure capability is passed as a *raw fd* for
speed. The compositor's GPU fd is raw — never individually revoked, and a
dead compositor ends the session anyway. A microphone capability the user
granted an app is mediated — §11.14 lets the user revoke it later, and that
revocation must bite.

### 10.6 Honest scope

The FreeBSD base — kernel and base system — is large and sits in the trusted
computing base regardless. This is **not** seL4-grade verified isolation,
and AbyssBSD does not claim it. What the model buys is a **desktop layer in
which no application holds ambient authority** — a strict, real improvement
over every conventional desktop, and now with *kernel-enforced* capabilities
rather than a best-effort approximation.

---

## 11. Components & packaging

### 11.1 The component map

AbyssBSD decomposes into the components below — and the discipline of §3.4 is
that this list is closed and curated, not open-ended. Each is one process,
jailed (§10), reached only over a bus connection carrying a capability;
none shares memory or authority with another except by explicit handle
(§6.2, §10.1). Granularity is **by responsibility**: a component is cut at
one coherent responsibility, which may span several mechanisms — not at
every mechanism. Replacing a component means supplying a process that
exports the same interface. Each interface's *shape* is given in this
document; its concrete typed message schema (§6.3) is a separate
per-interface design document under `interfaces/`.

The bus itself is not a component — it is a protocol and a library (§6).
Components connect point-to-point; the broker hands out the connection
capabilities. There is no central bus daemon: a router that saw all traffic
would enlarge the TCB for nothing.

**Foundation**

- **Broker** — the root of authority and the session root: spawns every
  component, creates its jail, mints and delegates capabilities, wires bus
  connections, owns the session (incl. `$XDG_RUNTIME_DIR`, §11.4). Started
  by `rc` (§2). *Holds:* the initial kernel and device capabilities. §10.4.

**Display & input**

- **Compositor** — owns the display (GPU/KMS), composites client surfaces,
  manages windows (placement, focus, stacking, decoration), and routes
  input to the focused surface. *Exports:* the display protocol (§7.4).
  *Holds:* the GPU device; the input-event stream.
- **Input service** — turns hardware input devices into one normalized
  event stream (libinput). *Exports:* the input-event interface (consumed
  by the compositor). *Holds:* input-device capabilities, `seatd`-mediated.

**Login & session**

- **Authenticator** — the single trusted front-end to system
  authentication (FreeBSD PAM): owns the credential conversation and the
  user-database access, and on a verified greeter-context login asks the
  broker to establish the session. Privileged, deliberately tiny, audited —
  the one credential-handling component (§11.15).
- **Greeter** — the pre-session login UI: a user picker, the auth
  conversation, a power menu. An *unprivileged* display client (a `@strict`
  toolkit app, §8) running as a dedicated `_greeter` principal; it renders,
  it does not verify (§11.15).

**System services** — one responsibility each

- **Settings service** — the typed settings store. *Exports:* get / set /
  subscribe.
- **Notification service** — accepts, queues, and dispatches
  notifications. *Exports:* post / update / withdraw; the shell subscribes
  and renders (§11.6).
- **Device monitor** — hardware presence (hotplug, fed by `devd`) and
  removable-volume mounting. *Exports:* device events; volume mount/unmount
  (§11.7).
- **Power & lifecycle service** — suspend/resume, battery, idle detection,
  lock policy, shutdown coordination. *Exports:* lifecycle events and
  control.
- **Networking** — desktop network management (join Wi-Fi, status,
  profiles); a control-plane orchestrator over the FreeBSD base, not in the
  packet path. *Exports:* connect / list / status (§11.12).
- **Audio** — desktop audio control: per-app and master volume, device
  selection; control-plane only — the kernel mixes. *Exports:* volume /
  device control and events (§11.13).

**Data** *(post-v1)*

- **Index/query service** — indexes files and answers live queries: the
  BFS-like typed-attribute data model (§11.16). *Exports:* query / subscribe.

**Shell & apps**

- **Session lock** — draws the unlock surface and authenticates the user;
  a deliberately tiny, auditable component — the trusted unlock path.
  *Exports:* the auth result to the power service (§11.11).
- **Desktop shell** — the in-session furniture: panels, application menu,
  window list, desktop surface, the status-indicator area. A consumer;
  like any app it exports only the scripting interface (§6.6).
- **Apps** — terminal, file manager, settings UI, text editor (§12). The
  leaves: they consume interfaces and expose only scripting; nothing in the
  system depends on an app.

**System layer and session layer.** The map divides by lifecycle. The
*system layer* — broker, compositor, input service, authenticator, greeter
— is spawned once at boot and persists across logins; the compositor and
input service sit here deliberately, so one instance serves the greeter and
then every session as ordinary display clients. The *session layer* — the
desktop shell, the session lock, the per-user services, and the user's apps
— is spawned per login as the authenticated user and torn
down at logout. The boot's two spawn phases are §11.15.

**Not a component.** The toolkit (the Kits, §8) is a *library* linked into
every UI process, not a process behind an interface. "Component" means a
process with a message interface; shared code is a library. Keeping that
distinction prevents the error of making everything a service.

### 11.2 Ports the AbyssBSD layer depends on

A deliberately small, recorded set, each for a genuinely hard, narrow
problem — all from FreeBSD ports:

| Port | Reason |
|---|---|
| Font stack | freetype / harfbuzz / fontconfig, from ports — the established C stack. A pure-Rust font stack exists in the ecosystem, but §3.2's discipline weighs a proven port over a young dependency tree. |
| `libinput` | Hardware-quirk-heavy input handling (palm rejection, tap heuristics). |
| `seatd` | Seat / session device brokering. |
| Mesa | The GPU stack — unreimplementable; provides OpenGL/GLES, Vulkan (RADV / ANV), and `llvmpipe` software GL. Client-side Vulkan (games, §7.4) ships in v1; only the compositor's *own* Vulkan render backend is post-v1 (§7.1). |

### 11.3 Packaging & distribution

AbyssBSD rides FreeBSD's **ports + `pkg`** — they are how the curators
*build* the AbyssBSD layer on top of the base. The product ships as a
**curated, installable FreeBSD-based image** with the AbyssBSD desktop
preinstalled. `pkg` is a build-time tool, not the on-machine update path:
the install and system-update lifecycle is §11.17.

### 11.4 Filesystem conventions

System-level layout is FreeBSD's `hier(7)`, unchanged — part of keeping the
base whole (§5).

Per-user files follow the **XDG Base Directory Specification**: configuration
in `$XDG_CONFIG_HOME` (`~/.config`), data in `$XDG_DATA_HOME`
(`~/.local/share`), state in `$XDG_STATE_HOME` (`~/.local/state`), cache in
`$XDG_CACHE_HOME` (`~/.cache`), and per-session runtime files in
`$XDG_RUNTIME_DIR`. No dotfile sprawl in `$HOME`.

This is consistent with rejecting the rest of freedesktop (§10): the
objection is to bloated daemons and abstraction layers — D-Bus, polkit,
portals — not to sane conventions. The Base Directory Specification is a
*convention*, not a dependency: no code, no daemon, nothing to vendor.

- **The Storage Kit exposes only XDG-resolved locations.** An AbyssBSD app is
  handed its config / data / state / cache directory; writing a stray
  dotfile into `$HOME` is not the path of least resistance. Opinionated by
  design.
- **System defaults adapt to `hier(7)`.** `XDG_DATA_DIRS` resolves to
  `/usr/local/share:/usr/share` and `XDG_CONFIG_DIRS` to a FreeBSD-
  appropriate `/usr/local/etc/xdg`, matching FreeBSD's `/usr/local` prefix.
- **`$XDG_RUNTIME_DIR` is the broker's job.** There is no `logind` to
  create it; the AbyssBSD session (the broker, §10.4) creates and owns it at
  login. The unified message bus's per-session socket lives there.

### 11.5 The settings interface

The settings service (§11.1) is the single typed configuration store — one
coherent thing in place of the gsettings/dconf-plus-registry sprawl. Unlike
the input interface it is **widely consumed**: the input service,
compositor, shell, power service, and apps all read it.

- **Exports** — `get`, `set`, and `subscribe`. `subscribe` is the
  load-bearing operation: settings is an *observed* store, not a passive
  file. A subscriber is sent a message whenever a watched key or subtree
  changes — this is how the input service picks up a layout change, the
  compositor a display setting, the shell its configuration.
- **Schemas are declarative and shipped.** Each component ships a schema
  file — its keys, their types, defaults, metadata — that the settings
  service loads at install/start. The whole settings surface is therefore
  knowable statically and auditable; a key's default exists before its
  owning component has ever run; every `set` is type-checked against the
  schema.
- **System and per-user layers.** A `get` resolves user → system → schema
  default. Per-user settings persist under `$XDG_CONFIG_HOME` (§11.4).
- **Access is capability-scoped (§10).** A component's `Cap<Settings>` is
  *narrowed* — to a subtree and to read or read-write. A component writes
  its own subtree and reads others'; settings access control *is* the
  capability model, not a separate ACL.
- **Storage** — the self-describing typed dict (§6.3) is already the right
  on-disk shape for a typed key tree; settings reuse it rather than
  inventing a format.

### 11.6 The notification interface

The notification service (§11.1) owns notification *policy and lifecycle*;
the desktop shell only renders. It is always-on — apps post even when the
shell is not showing (a fullscreen game, the recovery floor) — which is why
it is a component distinct from the shell.

- **Exports to posters.** Any app or service holding a post-scoped
  `Cap<Notifications>` (handed out by the broker) may `post` a notification
  — title, body, app identity, icon, urgency, action buttons, timeout, and
  an optional replace-id to update one in place — and `update` or `withdraw`
  it.
- **Exports to the shell.** `subscribe` to the active set (the shell renders
  the popups and the notification center) and query session history; the
  shell reports user interactions back — dismissed, action-invoked, expired.
- **Actions ride capabilities.** Each action button carries a reply-to
  capability (§6.5); when the user clicks it the service invokes that
  capability and the poster is called back directly — no name routing.
- **Policy.** Urgency levels (a critical notification bypasses
  do-not-disturb), do-not-disturb, per-app rate-limiting and grouping.
  Do-not-disturb and per-app policy are configuration, so the notification
  service `subscribe`s to the settings service (§11.5).

### 11.7 The device monitor interface

The device monitor (§11.1) reports hardware presence and manages removable
volumes. It is fed by FreeBSD's `devd`.

- **Exports — presence.** `subscribe` to device events: arrival, change,
  and removal, each carrying the device class (input, removable storage,
  audio, network, …), the device's identity, and what a consumer needs to
  use it. The input service consumes input-device arrivals (§7.5); the
  shell consumes removable-media events.
- **Exports — volumes.** For removable storage the device monitor mounts
  and unmounts the volume — a privileged operation it performs with a
  brokered mount capability — and exposes the mounted subtree, to which the
  broker can then grant access (e.g. to the file manager). Whether a volume
  mounts automatically or on user action is a setting (§11.5).
- **Not display hotplug.** A monitor being connected is *connector*
  hotplug; the compositor learns that from KMS directly (§7.1). The device
  monitor does not also report it — that duplication is what §3.4 forbids.

### 11.8 The power & lifecycle interface

The power & lifecycle service (§11.1) owns the machine's and session's
lifecycle — suspend/resume, battery and power source, idle and lock policy,
and shutdown coordination.

- **Exports — events** (`subscribe`). Suspend / resume; battery and
  power-source state; low- and critical-battery; idle / active transitions;
  *lock now* / *unlocked*; *about to shut down / reboot*. The shell renders
  the battery indicator from these; the session lock presents the unlock surface on *lock now* (§11.11); the compositor
  releases the display across suspend and confines input to the lock
  surface while locked.
- **Exports — control** (capability-gated commands). Request suspend,
  hibernate, shutdown, reboot, or lock. Session logout is the broker's (it
  is the session root, §11.1); the power service requests it.
- **Inhibitors are capability handles.** A component that must block
  suspend, idle, or lock — a video player, a fullscreen game, a long
  download — holds an *inhibitor capability*; the inhibit lasts exactly as
  long as the handle is held, and lifts automatically if the holder exits
  or crashes — no stale inhibitors. The same handle as a *delay* inhibitor
  buys a bounded window to finish work before suspend.
- **Consumes.** ACPI state — battery, AC, lid, thermal — from the kernel
  via sysctl and `devd` ACPI-notify events. (`devd` is a kernel facility;
  the device monitor reads its device-presence events, the power service
  its ACPI events — different event classes, one responsibility each,
  §3.4.) A coarse activity signal from the input service (§7.5) for idle
  detection; power policy — idle/lock/blank timeouts, lid-close and
  low-battery actions — from the settings service (§11.5). Critical alerts
  (low battery) it posts through the notification service (§11.6).

### 11.9 The broker interface

The broker (§11.1) is the root of authority and the session root. It is
unusual among components: its "interface" is less a request/reply API than
a *spawn-and-grant* surface. Started by `rc` (§2), it spawns and supervises
the AbyssBSD component set; `rc` remains the system init and supervises the
FreeBSD base — and the broker itself.

- **Manifests in.** The broker is configured by a declarative, shipped
  manifest per component — identity, the capabilities it needs (which peers
  it connects to, which devices and resources, its settings subtree), jail
  parameters, its memory budget (§3.6), restart policy. The whole authority graph is therefore static
  and auditable before anything runs. The manifest format is kept
  deliberately small (§3.5).
- **Spawn & bundle.** The broker spawns each component into a jail (§10)
  and hands it its **bundle** — the pre-wired connection endpoints to its
  peers, its device and resource capabilities, its scoped `Cap<Settings>`.
  A component is born holding exactly its manifest's grant and no ambient
  authority (§10.1).
- **Activation is eager and pre-wired.** The broker spawns components in
  eager, pre-wired phases — the system layer at boot, the session layer at
  login (§11.15): each phase's set comes up in dependency order with every
  bus connection pre-created and both ends handed out. No component ever
  races a peer being "not up yet" — that class of error is gone by
  construction — and there is no lazy-activation machinery to carry. Apps
  spawn on demand.
- **Supervision.** The broker holds a process descriptor (`pdfork`, §10.3)
  for each component; on crash it restarts per the manifest's policy —
  fresh jail, fresh bundle, peers re-wired. This is s6-grade supervision and
  nothing more.
- **Delegated spawn.** A component may ask the broker to spawn a child —
  chiefly the shell launching apps. The child's **birth bundle is granted by
  the broker** as root of authority (§10.4), per the child's manifest — for
  an app, intersected with what the user approved (§11.14) — and is *not*
  bounded by the caller, which is only the launcher. Capabilities a
  component instead *delegates from its own holdings*, over the bus, are
  attenuated and bounded by what it holds (§10.1).
- **Inspection.** The broker can report the live picture — components
  running, the connection and capability graph — plainly and legibly, never
  as an opaque blob (§3.5).
- **Consumes.** `rc` (which starts it); the kernel (jails, process
  descriptors, the initial device capabilities); the component manifests.
  It owns the session, including `$XDG_RUNTIME_DIR` (§11.4).

**The boundary with `rc`.** The broker is a *leaf* of `rc`'s
supervision tree and the *root* of the desktop's — an s6-style bounded
supervision subtree nested under the base, not a replacement for it. It is
**permanently desktop-scoped**: by deliberate decision it does not grow to
subsume `rc`'s system-init role (§2). Subsuming `rc` would fork FreeBSD's
init and inflate the security TCB (§10.6) — the service-scope counterpart of
the D-Bus refusal (§10.1). The broker is machine-boot-scoped: it establishes
and spans every login session of a boot (§11.15), and `rc` supervises the
broker itself. Whether the broker is internally one process or several
privilege-separated sub-services (the Casper decomposition, §10.4) is an
implementation matter — it does not move this outward boundary.

**Scope.** The broker brokers authority and lifecycle — nothing else.
Notifications, settings, devices, and power are separate components (§11.1)
specifically so the broker cannot absorb them; that separation is the
structural defense against the systemd fate (§3.4, §3.5).

### 11.10 The desktop shell

The desktop shell (§11.1) is the in-session furniture. It is a *consumer* —
its substance is what it presents and what it consumes — and, like any app,
it exports only the scripting interface (§6.6). Nothing in the system
depends on the shell.

**Presents.** GNOME-2-style panels (a top and a bottom panel by default),
the application menu (categorized, with a search box), the window list, the
desktop surface, and a curated status-indicator area. Menus are per-window
(GNOME 2 and BeOS both) — not a global menu bar. On a multi-monitor desktop
this furniture is drawn per output — each monitor self-sufficient — with the
window list scoped to its own output (§7.6). The same component scales to the
*experience* (§7.7): in a minimal configuration it is the **bar** of the tiling
experience — workspaces, focused-window title, status indicators — and the
GNOME-2 panels are that same furniture, fuller.

**The window list** is the *anti-taskbar*, held to six disciplines — the
Windows taskbar (survey verdict: burn) being the cautionary tale of what a
window list becomes without them:

1. One button per **window** — never grouped; reaching a window is one
   click.
2. The button shows the window's title, and nothing else.
3. **Launching is not here** — the application menu launches (a separate
   responsibility, §3.4). No pinned apps.
4. **No tray.** The status-indicator area is a *curated, fixed set* — clock,
   battery, network, volume — each fed by its owning component; apps cannot
   dump icons into it.
5. No search box, no widgets, no "recommended," no ads — not ever.
6. The model is stable; it does not churn across versions.

**Consumes.** The display protocol (§7.4) through a **shell-scoped
capability** — more rights than an app's: window-list introspection,
focus/activate, and panel strut reservation (the §10 rights model
distinguishing the shell from an app). Settings (§11.5) for its
configuration; notifications (§11.6), of which it renders the popups and the
notification center; power (§11.8) for the battery indicator; the device
monitor (§11.7) for a removable-media affordance. It launches apps through
the broker's delegated spawn (§11.9).

The shell is native and light — furniture must never be the bottleneck
(§6.8) — and it is **not** in the lock path: the unlock surface is a
separate component (§11.11). (The network and volume indicators are fed by
§11.12 and §11.13.)

### 11.11 The session lock

The session lock (§11.1) draws the unlock surface and authenticates the
user. It is deliberately tiny: the trusted computing base of the unlock
path is this component and the authenticator (§11.15), nothing else. A bug in the large desktop shell
cannot become a lock bypass, because the shell is not in the unlock path at
all — a small thing you can fully audit (§3.5), and a class of error
defined out of existence.

- **Activated by** the power & lifecycle service: on a *lock now* event
  (§11.8) the session lock presents its unlock surface; the compositor
  confines input to it and shows only it.
- **Authenticates** by running the credential conversation through the
  **authenticator** (§11.15) — the single trusted PAM front-end. The lock
  collects input and renders prompts; it does not itself touch PAM or the
  user database.
- **Exports** one thing: on successful authentication it reports to the
  power & lifecycle service, which owns lock *state* and emits *unlocked*
  (§11.8); the compositor then releases the input confinement.
- It draws as an ordinary display client (§7.4) and is spawned and
  supervised by the broker like any component (§11.9).

*Authenticate to unlock the session* is a genuinely distinct responsibility
from "draw the panel" (§3.4); separating it is the clean by-responsibility
cut and the security-correct one at once.

### 11.12 The networking interface

The networking component (§11.1) is desktop network management. The TCP/IP
stack, DHCP, and Wi-Fi authentication are the FreeBSD base (§2); this
component **orchestrates** that machinery and surfaces it to the desktop —
it is control-plane only and never carries a packet.

- **Exports** — `list` available networks (Wi-Fi scans, wired links);
  `connect` / `disconnect`; `status`; and a `subscribe` for connection
  events (link up/down, address acquired, signal). The shell renders the
  network indicator (§11.10) from this.
- **Orchestrates, does not reimplement.** It drives the FreeBSD base —
  `dhclient` for DHCP, `wpa_supplicant` for Wi-Fi authentication,
  `ifconfig` for link setup — managing and configuring those programs. It
  never reimplements DHCP or Wi-Fi cryptography: that is security-critical
  code the base already provides, and rewriting it would be indefensible
  (§3.5).
- **Connection profiles** — remembered networks, auto-join — are its own
  persistent state.
- **Consumes** — the FreeBSD base's network programs; the device monitor
  (§11.7) for interface hotplug; the settings service (§11.5).
- **Scope.** Desktop connectivity management, nothing more. The firewall
  (`pf`) and VPN tunnels are not its job; folding them in would be the
  scope creep §3.5 forbids.

### 11.13 The audio interface

The audio component (§11.1) is desktop audio *control*. The decisive fact:
the FreeBSD kernel already mixes — `vchans` give per-device mixing,
resampling, and per-channel volume in the kernel. AbyssBSD needs no sound
server in the data path.

- **Control-plane only.** Apps open the kernel audio device directly,
  through a capability the broker grants — scoped to playback, capture, or
  both — and the kernel mixes their streams. The audio component **never
  touches a sample**; a game talks straight to the kernel, so lowest
  latency is the default and costs nothing.
- **Exports** — per-app and master volume (applied to the kernel mixer's
  channels); default-device selection; and a `subscribe` for audio events
  (device added/removed, default changed). The shell renders the volume
  indicator (§11.10) from this.
- **Device re-routing.** Moving a playing stream to a newly-attached device
  — headphones plugged in — means the app re-opens on the new device.
  Because AbyssBSD has a single toolkit, this is handled **once** in the Media
  Kit (§8): it catches the default-device-changed event and re-opens
  transparently; apps write no code for it.
- **Capture is separately gated.** Recording is a distinct capability — an
  app granted playback cannot record. Microphone access is capability-gated
  like any other authority (§10).
- **Consumes** — the device monitor (§11.7) for audio-device hotplug; the
  settings service (§11.5); the kernel audio device, whose mixer it
  configures.

### 11.14 The app model

An AbyssBSD app is a **bundle** — a directory presented as one object, in
the macOS `.app` tradition, but deduplicated as §3.4 requires. (System
*components* ship as ports/pkg, §11.3, as part of the curated OS; *apps*
are the user-installed leaves — two packaging models, for two lifecycles,
deliberately.)

**The bundle** holds an **app manifest**, the executable, resources, and —
for transport — the libraries the app needs. The manifest declares
identity, the **capabilities the app requests** (§10 — network, devices,
file scopes, audio, …), and its **library dependencies by content hash**.
It is the app's counterpart of the component manifest (§11.9).

**Libraries are content-addressed.** Each library is stored once,
system-wide, in a content-addressed store keyed by the hash of its
contents; a bundle *references* its libraries by hash rather than carrying
private copies. This is §3.4's "no duplication" achieved *by construction*
— the store cannot hold a duplicate — and the store is a flat, inspectable,
hash-keyed directory (§3.5). Content-addressing also removes version
conflict: two apps needing different builds reference different hashes,
both present, each shared with whoever wants that exact build. No dependency
solver, no DLL hell.

**Dedup serves the memory budget.** Because every app references the
*identical* library file, the kernel maps its text once and shares it
across all of them — N apps, one resident copy, not N. Library dedup is a
§3.6 mechanism, not merely a disk one.

**Self-contained for transport, deduplicated once resident.** A shipped
bundle carries its libraries — a complete, movable artifact. On
installation those libraries merge into the store; ones already present
(used by other apps, or the system) are dropped as duplicates, only new
ones added. "If they already exist on the filesystem" is the normal case.

**Lifecycle.** *Install* — place the bundle; its libraries are ensured in
the store, deduplicated on the way in; no package database. *Uninstall* —
remove the bundle; store libraries no longer referenced by any bundle are
garbage-collected. *Run* — the shell launches the app via the broker's
delegated spawn (§11.9), jailed, granted the capability set its manifest
declares; its jail sees only the libraries it references.

**Capabilities are requested, not assumed.** A manifest *requests*
capabilities; the broker grants them. A curated AbyssBSD app ships a
manifest vetted by curation; a third-party app's requests beyond a safe
default are surfaced for the user to approve. An app never holds authority
its manifest did not ask for and the user did not grant — apps are the
leaves of the system (§11.1), exposing only the scripting interface (§6.6).

### 11.15 The login & session lifecycle

Boot reaches a desktop in two spawn phases, and authentication is split
across three components so that no single one is both privileged and
complex.

**Three roles.** The **broker** (§11.9) establishes sessions — it spawns
the per-user component set as the authenticated user, and is the only thing
that can. The **authenticator** is the single trusted front-end to system
authentication (FreeBSD PAM): it owns the credential conversation and the
user-database access, kept small and audited because it is the one
privileged credential-handling component. The **greeter** is the
pre-session login UI — a user picker, the auth conversation, a power menu —
an *unprivileged* display client (a toolkit app, §8) running as a
dedicated `_greeter` principal. The greeter renders; it does not verify.
Folding PAM or session-spawn into the greeter would put a themeable,
comparatively complex UI in the TCB with root; folding PAM into the broker
would grow the broker against the §3.4 discipline. Three roles, each one
job.

**Two spawn phases.** At boot `rc` starts the broker, which spawns the
**system layer** — compositor, input service, authenticator, greeter
(§11.1). The greeter draws on the compositor, which confines input to it
exactly as it does for the session lock (§11.11). On a verified login the
broker spawns the **session layer** — the desktop shell and the per-user
services and apps — as the authenticated user; this is the broker's
eager, pre-wired spawn (§11.9), here the *session* phase specifically.
The compositor and input service persist across the transition; the
greeter's window gives way to the shell's. Logout cancels the session
layer's looper supervision handles (§6.10) and re-presents the greeter; the
system layer never tears down.

**The trust flow.** The greeter UI holds exactly one capability: submit a
credential attempt to the authenticator. It cannot name a principal to the
broker, create a session, or read the user database — a greeter compromise
yields a jailed, unprivileged process that can only ask "is this right?"
Only the authenticator may ask the broker to establish a session, and it
passes the principal *it verified* — the greeter's chosen username reaches
the broker only after verification. The greeter UI does see the plaintext
credential, since it owns the text field as any login UI must; being
unprivileged and jailed, that buys an attacker nothing.

**A conversation, not a prompt.** PAM is multi-step — a password, then
perhaps a second factor, then perhaps a forced password change. The
authenticator↔UI interface is therefore a **prompt/response conversation**:
the authenticator emits typed prompts, the UI renders them and returns
responses. The greeter — and the session lock — are generic
auth-conversation renderers, so second factors and password-change-at-login
need no new interface.

**The session lock shares this.** The session lock (§11.11) is the same
shape — a confined UI running the authenticator's conversation — differing
only in consequence: it resumes an existing session rather than
establishing one. Both route credentials through the one authenticator, so
the trusted credential path is a single audited component, not two. The
greeter and the lock stay separate components — different principals,
different lifecycles — but share the mechanism.

**Auto-login** is a supported system configuration the broker reads: when
set, the broker skips the greeter and establishes the configured user's
session directly. It governs cold-boot-to-session only — an established
session is still lock-protected (§11.11); auto-login is not "no lock."
AbyssBSD supports multiple local accounts but **one active session at a
time**: switching users is logout-then-login. Fast user switching
(concurrent sessions) and multi-seat are out of scope.

**Failure.** The broker supervises the system layer; persistent failure of
the greeter or authenticator drops to the §9 minimal-framebuffer recovery
floor, from which the system is repairable. Any greeter→recovery-shell
escape hatch is gated by *root* authentication through the authenticator —
an unauthenticated one would be a root bypass. The greeter milestone
follows the toolkit (§8, §12).

### 11.16 The data model — typed attributes & live queries

The BeOS legacy AbyssBSD keeps: a file is not only its bytes but a set of
**typed attributes**, and the filesystem can be **queried** like a database,
with results that stay **live**. This is the post-v1 data model; the §11.1
**index/query service** is its component, and the Storage Kit (§8) is its
toolkit-side API.

**Not a filesystem.** BeOS's BFS maintained the indexes in the filesystem
itself. AbyssBSD does not — writing or forking a filesystem is the
from-scratch-OS scope §2 rejects. Files live on an ordinary
FreeBSD filesystem, unchanged; a focused userland service indexes them. This
is the Spotlight architecture, not the BFS or WinFS one.

**Attributes live in the file; the index is soft state.** A typed attribute
is stored as a POSIX **extended attribute** on the file (the `user`
namespace). The file is the source of truth. The index/query service's
database is a *derived, rebuildable accelerator* — pure soft state: delete
it, corrupt it, skew its version, and it is rebuilt by walking the tree and
re-reading extattrs, with no data loss. Attributes are typed in the §6.3
typed-value vocabulary, and because §6.3 values are self-describing, the
§6.3 encoding *is* the on-disk attribute format — one type system and one
serialization across messages, settings, scripting, and attributes.

**Substrate — extended attributes, not ZFS specifically.** The model rests
on POSIX extended attributes, which **both UFS and ZFS provide**; it does
not require ZFS. ZFS is *recommended* — its `xattr=sa` storage is efficient
where UFS extattr is clumsy and size-limited, and its snapshots make
reconciliation cheap (below) — but the dependency is on the extattr
capability, not the product (§3.4).

**Liveness — exact for kit writes, convergent for the rest.** A file written
through the **Storage Kit** is indexed exactly and live: the kit is the
write path and notifies the index. A file changed *outside* the kit — a
`tar` extract, a `git` checkout, another OS on a shared disk — is caught by
**reconciliation**: `kqueue` on directories of interest, a periodic scan, or
on ZFS a snapshot `zfs diff`. Foreign changes are therefore *eventually
consistent*, not instant. The model is BFS-grade for kit-managed files —
which is where a desktop's files overwhelmingly come from — and honest about
the rest.

**Live queries are the subscription pattern.** A live query is a query whose
reply-to capability the index/query service *retains*
(`interfaces/README.md`): the reply is the current result set, and
thereafter the service streams `Added` / `Removed` / `Changed` events as the
set evolves. No new mechanism — the live query falls out of the bus
subscription model. Query capabilities are **scoped**, like a `Cap<Settings>`
subtree (§11.5): an app queries its own data subtree; a whole-disk search is
a broader grant — otherwise a query would leak the existence of files the
querying app cannot see.

**The payoff.** This is what makes the BeOS lineage structural rather than
cosmetic: an app can be a thin shell over files-with-attributes plus a saved
live query, and the file manager can present a saved query *as a folder* —
"files as a database," delivered as a userland service over honest files.

### 11.17 Install & system updates

Install and system update are **one lifecycle** — both produce or replace
the curated system, and both run on **ZFS boot environments** (`bectl`,
FreeBSD-native; the project already recommends ZFS, §11.16).

**The system is one curated artifact.** A FreeBSD base release and the
AbyssBSD layer (§11.3) are curated, tested, and versioned *together* as one
"AbyssBSD release." `pkg` and ports are **build-time** tools the curators
use to assemble the layer; they are *not* the on-machine update path. A user
never runs `pkg upgrade` or `freebsd-update` to move the system — base
security fixes ship as AbyssBSD point releases. This is what §2's "one
coherent product" requires: the user never runs an untested combination.

**An update is a new boot environment.** Applying a release creates a fresh
ZFS boot environment, populates it with the new curated system, marks it
active, and reboots into it — **atomic**: the running system is never
half-updated. Efficient delivery is a ZFS incremental `send`/`recv` delta,
but the transport is a detail; the model is the atomic boot environment.

**Rollback is booting the prior environment.** The previous boot environment
is left intact and bootable from the loader — a bad update is one reboot
from undone, by a non-technical user. Further, a freshly-activated
environment is **on probation** at first boot: if it does not reach a
healthy desktop (the greeter comes up, §11.15), the system **auto-reverts**
to the last-known-good environment. A bad update cannot brick the machine —
the old environment is always intact.

**Apps update separately.** GUI apps are §11.14 bundles, updated per app,
never part of the system image — system and apps run on independent tracks.

**The installer is a graphical application.** §9 admits no text mode, so a
curses installer (FreeBSD's `bsdinstall`) is structurally inadmissible — it
would be the product's one text-mode surface. The install image instead
boots a **live AbyssBSD environment** — the same compositor (CPU backend,
§9) and toolkit the installed system uses — and runs the installer as an app
in it. It is **opinionated** (§3.3): a short guided flow with sane defaults
— disk and ZFS-pool selection, locale/keyboard/timezone, the first user
account, encryption as one question — not a configuration sprawl. It lays
the system down as a ZFS pool with boot environments from the first install,
so atomic update exists from day one: install *is* "create boot environment
#1." The same live image doubles as a graphical rescue environment (§9's
recovery floor, on removable media).

**The split — privileged mechanism, unprivileged UI.** As with the greeter
(§11.15): a small, privileged **update service** performs the
boot-environment work (fetch, populate, activate); an *unprivileged* desktop
UI — a settings panel — surfaces "an update is available," progress, and
"restart to apply," and authorizes the work through a narrow capability. The
privileged surface stays small and auditable (§10.5).

---

## 12. Milestones

There is no self-host milestone — FreeBSD provides a self-hosting system.

| # | Goal | Done when |
|---|---|---|
| **M1** | Minimal framebuffer UI | On a stock FreeBSD system, an AbyssBSD `rc` service starts broker → compositor (CPU backend) + one terminal window. The message primitive, bus, and broker exist. This is the recovery floor forever after. |
| **M2** | GPU path | GLES 3.x backend, Mesa, dmabuf buffer sharing; the compositor goes accelerated. |
| **M3** | Toolkit + desktop | Retained-mode Kits; the GNOME-2 shell — panel, app menu, window list. |
| **M4** | Core apps | File manager, settings, text editor. (The terminal already exists from M1.) |
| **M5** | Distribution & hardening | A curated installable image/installer; performance and daily-driver work; broadening curated hardware support. |

The message primitive, the bus, and the capability broker are foundational —
built across M1 — because the compositor depends on them. The compositor's
window-management core and its tiling layout policy (§7.7) come up with the
compositor across M1–M2 — the keyboard-driven tiling experience is the system's
first face; the floating GNOME-2 desktop and its furniture follow at M3.
Capsicum and jail confinement is applied per service as each is brought up
through M1–M5.

---

## 13. Open threads

- **Vulkan backend (post-v1).** A second accelerated backend behind the
  existing render-backend seam, added once the GLES path is solid (§7.1).

- **Display & input capability coverage.** Routing input only to the focused
  surface and forbidding ambient observation (§7.4, §7.5) is the right default
  — and the same instinct that made Wayland's security model sound. But a model
  with only two answers — *deliver-to-focused-client* or *forbid* — loses every
  legitimate workflow that falls between them, and that loss, re-litigated one
  protocol extension at a time, is the substance of the long-standing grievance
  against Wayland. AbyssBSD holds the answer Wayland lacked: the capability is a
  third answer — a bounded, revocable, user-authorized *yes* (§10.5) — but only
  where each such workflow is actually given one. Screen capture is now in the
  protocol shape (§7.4). Still to design: **global shortcuts** — a holder
  registers a binding with the compositor and receives its event whether or not
  it is focused (media keys, push-to-talk) — and **clipboard history**, kept by
  the compositor, which already holds the selection, and exported behind a
  capability, rather than the ambient read §7.4 rightly forbids. Two scope calls
  are pending, to be settled *explicitly* — the way the accessibility stack was
  (§6.6), never by silent omission: **remote display** (the bus transport is
  local fd/shm/dmabuf, §6.4; network transparency would need a re-encoding proxy
  and is likely a non-goal) and **HDR / color management** (buffers carry format
  and modifier but no color space, §7.4; likely a later addition). The
  discipline: every power a legacy desktop granted ambiently, AbyssBSD either
  mints as an explicit capability or scopes out on purpose.

