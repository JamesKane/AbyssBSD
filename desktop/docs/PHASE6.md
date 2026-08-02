# Phase 6 — `undertow`: the compositor, in Swift (scope)

The last of the big rewrites, and the one that unblocks everything a Wayland
*client* fundamentally cannot do. Read [PLAN.md](PLAN.md) for the locked
decisions, the sibling's [DESKTOP.md](../../AbyssBSD/abyss/docs/DESKTOP.md) for
the architecture canon this phase implements, and [HANDOFF.md](HANDOFF.md) for
the interop traps.

Last updated: 2026-08-02. **Scoped, not started.** Three risks were spiked
first, on both platforms, before any of it was written down as a plan (§4) —
because the phase's shape depends on their answers.

---

## 1. What this phase is

**The performance contract, made real in Swift.** DESKTOP.md opens with C1–C5
and says why:

> Phase 1 is deliberately the performance contract and its meter — because on
> this project, *that* is the feature.

So the promise is not "we wrote a compositor". It is:

> The screen stays at refresh rate, and **a single misbehaving program cannot
> make it stutter** — proved by an in-process flight recorder and headless
> benches that fail the build on a regression.

Everything else in this phase exists to make that true and to measure it.

**We own the scene, the scheduler and the present path. wlroots owns the
plumbing** — DRM/KMS, GBM, libinput, and the protocol grind (DESKTOP.md §2).
That division is canon and this phase does not relitigate it: writing a
compositor from scratch is a multi-year detour that would not improve the parts
we actually own.

**Explicitly NOT in Phase 6:**

- **No GPU, no DRM/KMS, no real vblank.** The build VM is Bochs std-VGA with no
  `/dev/dri`, and the sibling is blocked at exactly this line (its STATUS.md §4:
  *"the one real blocker: GPU"*). Phase 6 is **software rendering (pixman) on
  wlroots' headless and nested backends**, which is where C1–C3 are provable
  anyway. Hardware cursor, direct scanout, atomic page-flip, VRR and
  explicit-sync belong to **Phase 4** (Mac Pro bring-up), on metal.
- **No real-time priority.** The sibling needed an `allow.rtprio` jail param —
  a *kernel* divergence — to grant the present thread bounded RT. That is a
  Phase-4 concern; headless benches measure the loop body's cost, which is what
  C1 actually constrains.
- **No jails.** Same reasoning as Phase 7's carve-out: FreeBSD systems work that
  belongs with the hardware story.
- **Not the toolkit.** `Aqua` already exists and already renders the desktop.
  This phase changes *what it runs on*, not what it looks like.

---

## 2. What we already have vs. what's new

More of this is done than the phase's size suggests, because Phases 1–3 built
the client half and the substrate:

| Need | Have | New in Phase 6 |
|---|---|---|
| Wayland protocol glue | `CWayland` + the `aw_*` shim (§2.1), 5 protocols vendored | the **server** half — `wayland-scanner server-header` |
| C-interop discipline | four phases of it; §2.1–§2.3 are the rules | `CWlroots` — the listener trampoline (§4.1) |
| A control plane | `CurrentIPC`, SCM_RIGHTS (P3.5) | the compositor hosts a service |
| A session supervisor | `anchor` (P3.6) | it starts `undertow` instead of sway |
| Config | `PoolConfig` (P2.3) | output/workspace layout persisted |
| A shell to run | the whole Aqua desktop (Phase 2) | it runs on **our** compositor |
| Real clients to test with | `AquaDemo`, the Finder, the Dock… | adversarial clients (C2) |
| A test harness | `abyss/tests`, 35 live modes | the C1–C5 gating benches |
| Screenshots | `wlr-screencopy` **client** (P7.5) | the **server** half (PHASE7 §6.6's debt) |

---

## 3. Component map (sibling → ours)

`tide` is ~5.9k lines of Rust (plus ~2k of tests and a 4.9k-line bindgen dump).
Ours should land smaller, because Swift imports wlroots directly (§4.1) and
because `CurrentIPC`/`PoolConfig`/`Anchor` already exist.

| Job | Sibling | Ours |
|---|---|---|
| The compositor | `tide` | **`undertow`** (`de/undertow`, `de/undertowbin`) |
| wlroots binding | `wlsys` (bindgen, 4946 lines) | **`CWlroots`** — **29 lines of C**; Swift imports the rest (§4.1) |
| Frame scheduler | `metronome.rs` (489) | `Metronome.swift` |
| Flight recorder | `recorder.rs` (227), `hud.rs` (195) | `FlightRecorder.swift` |
| Scene (SoA) | `scene.rs` (214), `damage.rs` (180) | `Scene.swift`, `Damage.swift` |
| Reactor | `reactor.rs` (167), `kq.rs` (214) | `Reactor.swift` — poll/kqueue, the `Display.run()` discipline (§2.14) |
| wlroots output bridge | `wlout.rs` (2335) | `Backend.swift` |
| Input | `evdev.rs` (908) | `Seat.swift` — via wlroots' libinput, not raw evdev |
| Lock-free publish | `triple.rs` (157), `spsc.rs` (123) | `TripleBuffer.swift` |

---

## 4. The spikes — three risks, retired before planning

PLAN.md risk 4 ("Swift ARC vs. the latency contract") was the reason to spike
before scoping: if the answers had gone the other way, this would be a different
phase. All three were run **on Linux and in the FreeBSD guest**.

### 4.1 Can Swift bind wlroots at all? — **Yes, and better than the sibling can.**

The sibling needed **bindgen** (`wlsys`, 4946 generated lines, with the standing
"regenerate in the VM, pull the file back before the next sync" hazard in its
STATUS.md §2). **Swift's C importer reads wlroots' headers directly** — no
bindgen, no generated file to keep in sync. `wl_display_create`,
`wlr_headless_backend_create` and friends are callable, and struct layouts import
correctly.

Two things do need C, both already familiar:

- **`xdg-shell-protocol.h` must be generated with `wayland-scanner
  server-header`.** We have only ever generated the *client* header. This is the
  one-line reason a naïve `import CWlroots` fails, and it costs a `gen_server`
  line in `generate-protocols.sh`.
- **wlroots' entire event model is `wl_listener` + `wl_container_of`, and both
  are macros** — the §2.1 trap at scale. `wl_signal_add` is a `static inline`
  too. The fix is one C trampoline, and it is the single most important 15 lines
  of the phase:

```c
typedef void (*tw_notify_fn)(void *ctx, void *data);
struct tw_listener { struct wl_listener l; tw_notify_fn fn; void *ctx; };

static void tw_trampoline(struct wl_listener *listener, void *data) {
    struct tw_listener *tl = wl_container_of(listener, tl, l);
    tl->fn(tl->ctx, data);          /* -> a Swift @convention(c) function */
}
```

Verified end to end on **both platforms**: a headless backend's `new_output`
signal fires into a Swift closure carrying an `Unmanaged` context, naming
`HEADLESS-1` and `HEADLESS-2`. That is the mechanism every other wlroots event
will use, so the phase's core FFI question is answered before it is asked.

### 4.2 Can the present path be allocation-free in plain Swift? — **Yes. Measured.**

PLAN.md risk 4 named three possible mitigations: *"Embedded Swift,
preallocation, and a C shim for the present path if measurement demands it"*.
Measurement does not demand them.

A structure-of-arrays scene over `UnsafeMutableBufferPointer`, composited by a
loop body with no `Array`/`String`/class in reach, run under an allocation
interposer:

```
undertow bench-alloc — 5000 frames, 512 surfaces
  probe             live (positive control saw its own allocations)
  allocations       0
undertow bench-metronome — 240Hz, 600 frames, 512 surfaces
  composite cost    p50 14.92 us   p99 37.44 us   p99.9 56.57 us
```

**Zero allocations, and roughly fifty times of headroom on p99 against the 2 ms
C1 budget.**

> **Corrected at P6.1.** The first version of this measurement was taken with a
> probe that wrapped only `malloc`/`calloc`/`realloc` and **had no positive
> control**. Swift's runtime allocates through **`posix_memalign`**, so that
> probe was blind to nearly every allocation a Swift program makes and would
> have reported a comfortable zero no matter what the loop did. The number above
> is from the real `bench-alloc`, which refuses to report anything until a
> deliberate allocation proves the probe can see one. The conclusion did not
> change; the evidence for it was much weaker than it was stated to be, and
> stating it that way was the mistake (HANDOFF §2.37).
So: plain Swift, with the discipline made a *rule* and the flight recorder
catching violations as latency spikes — which is exactly what DESKTOP.md §11
prescribes for Rust, and for the same reason ("achievable but not automatic").

**Embedded Swift is the wrong tool and would not have worked anyway.** It is a
whole-module (`-wmo`) language *subset* for bare metal; you cannot scope it to
one thread of a process that links wlroots and Foundation. Recording that here so
nobody spends a week rediscovering it — PLAN.md's risk-4 wording invites the
attempt.

The residual risk is real but ordinary: **a spike is not the loop.** The real
present path also touches wlroots calls and the triple buffer, and ARC can hide
in an innocuous-looking capture. Hence P6.1's in-tree allocation counter, which
runs as a *test*, not as a one-off.

### 4.3 Does the guest have what it needs? — **Yes, already.**

`wlroots019` and `seatd` have been in the VM seed since Phase 3 (they were put
there so the shell could run as a *client* under sway). The guest carries
wlroots **0.19 and 0.20**; Fedora ships 0.19 only, so **we pin 0.19** and the
dev box is the constraint, as usual. Better than that: both platforms are on
**0.19.3 exactly**, so the substrate matches the way every other dependency in
this project does. `abyss/vm/check.sh` now asserts `wayland-server` and
`wlroots-0.19` alongside the rest, so seed drift is caught before a build is.

---

## 5. Ordered passes

**P6.1 — The metronome and its meter, against nothing at all. ✅ done.**
The contract before the pixels, and before wlroots: pure Swift, no compositor,
no display. `Metronome` (EWMA vblank prediction, an adaptive latch margin, the
§3.1 late-latch loop), `FlightRecorder` (a ring of POD records with a release
publish), the `Output`/`FrameSink` protocols, and a synthetic display and scene
to drive them. `undertow` is its own bench harness, as `tide` is:

```
undertow bench-metronome — 240Hz, 600 frames, 512 surfaces (after 75 warmup)
  wall clock        2499 ms  (nominal 2499 ms)
  period estimate   4166.66 us  (nominal 4166.66 us, 671 samples)
  latch margin      949.84 us
  composite cost    p50 14.11 us   p99 32.98 us   p99.9 55.43 us
  missed flips      0 of 600  (0 per mille)
```

**The metronome is generic over its display and scene, never existential.**
`Metronome<O: Output, S: FrameSink>` keeps the loop body's calls statically
dispatched and inlinable — DESKTOP.md §11's "hot paths avoid dyn dispatch" in
the Swift idiom, and the reason the composite is ~15 µs rather than a witness
table lookup per surface.

*Four bugs the benches caught, none of which a unit test would have:*

- **The margin ran away.** When the adaptive margin grew larger than the time
  remaining to the next vblank, the deadline landed in the past, so the loop
  composited immediately for a vblank it could not possibly make, missed, grew
  the margin further, and degenerated into a spin that never slept — 600 frames
  in 61 ms instead of 2499. **A metronome must aim at a vblank it can still
  hit**; skipping to the next one is C4's "fall to the next period", and its
  absence is not a slow path but a runaway.
- **The synthetic display echoed the predictor.** It computed each frame's
  vblank *from the target the compositor asked for*, so the predictor was
  observing its own guesses and could never learn the true period — a bench that
  would have passed no matter how wrong the prediction was. The display now
  keeps its own grid (`epoch + k·period`), independent of anything predicted.
  **A model that agrees with you is not a test.**
- **The present loop allocated ~1.05 times per frame**, because
  `SyntheticOutput` held its in-flight frames in a Swift `Array` and
  `append`/`removeFirst` allocate. Exactly the "a spike is not the loop" risk
  §7.2 names, caught the first time the bench ran. It is a fixed inline ring now.
- **The margin could not explain its own misses.** It measured only composite
  cost and absorbed OS wake latency and display commit latency into a blind
  feedback term, so it over-corrected and then decayed straight back into
  missing. All three terms are measured separately now, which made the margin
  both smaller and steadier.

*Verified:* **17 unit tests** (156 total) on both platforms — predictor
convergence on a 59.94 Hz display advertised as 60, a skipped frame not halving
the period estimate, implausible-sample rejection, targets always in the future
and on the grid, the margin's grow-fast/decay-slow asymmetry and its floor and
ceiling, recorder wrap-around and percentiles. **Cadence is deliberately not unit
tested** — it depends on OS scheduling and would flake in a VM (§6); it is
`abyss/tests/bench-metronome.sh`, in `run.sh`'s default lane because it needs no
compositor, no GPU and no display.

*The miss budget is a rate, and it is not zero — on purpose.* C1's
"zero missed at p99.9" is a claim about a present thread at **real-time
priority**, and this one is not: `rtprio` needs the `allow.rtprio` jail param,
which is Phase 4 on metal. Measured over eight runs, 240 Hz × 600 frames gives 0
misses seven times and 1 once — rare wake-latency outliers. The gate is
therefore **5 per mille**, an order of magnitude above that noise and an order of
magnitude below every regression the bench has actually caught (the runaway
produced ~30 per mille; the blind margin ~25). A gate that flakes one run in
eight is a gate people learn to ignore. **Zero-at-p99.9 becomes assertable in
Phase 4**, and the bench says so rather than quietly redefining C1.

**P6.2 — The wlroots bridge, and first frames. ✅ done.**
`CWlroots` (the §4.1 trampoline — and **nothing else**, because Swift imports the
rest), the server-side protocol generation, and `Backend.swift`: display, event
loop, headless backend, outputs, renderer + allocator. The metronome drives real
frames onto a real wlroots output:

```
undertow headless — HEADLESS-1 800x600 @ 60Hz, 120 frames, 128 surfaces
  wall clock        2000 ms  (nominal 1999 ms)
  period estimate   16666.66 us  (nominal 16666.66 us, 135 samples)
  composite cost    p50 5.37 us   p99 9.67 us
  missed flips      0 of 120  (0 per mille)
  presented frames  yes
  vblank source     nominal grid — this backend reports no hardware clock
```

**The inversion that makes this ours.** A wlroots compositor is normally written
to render *when the output asks*, from its `frame` handler. Undertow does not:
the metronome decides when a frame happens, and the output's job is to execute
it and report back through `present`. That is what makes the schedule ours
rather than the backend's — and the reason P6.1 came first.

*The bug worth recording, because it is the same shape as P6.1's and it will
recur on every backend:* **a headless output presents on commit, so its "vblank"
timestamps are our own commit times.** Feeding those into the predictor closes a
loop with no external reference — self-consistent at *any* period and therefore
stable at none. Measured, it ratcheted from 16.7 ms to 11.9 ms over 120 frames
while every individual number looked healthy (0 missed, present events arriving).
wlroots flags this precisely — `WLR_OUTPUT_PRESENT_HW_CLOCK` distinguishes a
driver-measured timestamp from a bookkeeping one — so the bridge uses it: with
real hardware the timestamp passes through untouched; without it we snap to the
output's nominal grid and **say so in the bench output**. A virtual output has no
vblank to discover, and pretending to measure one is worse than admitting it.
This is P6.1's "a model that agrees with you is not a test", arriving from the
other direction: here the *backend* was the agreeable model.

**Two assertions that are not about speed at all**, and are the ones that
actually catch a broken compositor: *no present events* means we committed frames
that never landed, and *no predictor samples* means flip feedback is not reaching
the scheduler. Either is fatal and either would otherwise look perfectly healthy
in a frame-time histogram.

*Verified:* **3 new unit tests** (159 total) on both platforms — the session
announcing its outputs through the trampoline, frames reaching the backend with
feedback returning, and a clockless backend still pacing at its nominal rate
(which fails by ~30% without the grid snap). Plus `undertow headless` in
`abyss/tests/bench-metronome.sh`, in `run.sh`'s default lane.

*Known debt, stated rather than discovered later:* **P6.2 is single-threaded.**
The event loop is serviced from inside the metronome's wait, which is fine while
there are no clients — but C2 requires that no client can delay the present
thread, and one thread dispatching client requests cannot promise that. The
reactor/present split lands with the clients it exists to isolate us from
(P6.3/P6.5), where it can actually be tested rather than asserted.

**P6.3 — A scene, and a real client on it. ✅ done.**
`wl_compositor` + `wl_shm` + `xdg_shell`, a socket, our own SoA scene, and each
mapped surface textured into the frame by pixman. The client is one we already
had — **AquaDemo, unmodified**:

![an Aqua window on undertow](screenshots/undertow-first-client.png)

That is a Swift compositor compositing a Swift toolkit's window, with no other
compositor anywhere: `abyss/tests/live-undertow.sh` is the first test in this
project that **starts no sway at all**.

**We do not use `wlr_scene`**, and this is the pass where that stops being a
statement and starts being code. `wlr_scene` is a perfectly good retained scene
graph, and taking it would hand away precisely the part DESKTOP.md §2 reserves
to us. `SurfaceScene` is the structure-of-arrays instead: latch the window list,
cull, and walk it linearly. Its `latchAndComposite` never calls into a client,
never takes a lock a client holds and never waits — everything it reads was
already committed, which is C2 by construction.

*Three things that were each a silent hang until found, all worth knowing before
writing a compositor:*

- **`wlr_compositor_create` does not create `wl_shm`.** Without it no client can
  attach a buffer — and our own `Display.init` requires compositor + shm +
  xdg_wm_base, so it refuses the connection outright and the client reports
  *"cannot connect to a Wayland compositor"*, an error pointing nowhere near the
  missing global. One line: `wlr_shm_create_with_renderer`.
- **A client must be answered.** xdg-shell requires the compositor to reply to
  the first commit with a configure before the client may attach anything, and
  the client must be released with `wlr_surface_send_frame_done` after each frame
  or it draws exactly once and waits for ever. Both look like a client that hung
  while doing nothing wrong.
- **`wlr_renderer_autocreate` picks the GPU when there is one**, and GPU-backed
  buffers are not CPU-readable, so the capture is impossible — *on the dev box
  only*, invisibly diverging from the VM. Phase 6 is software-rendered by scope
  (§7.1), so the session pins `WLR_RENDERER=pixman` (overridable) and both
  platforms stay on one path.

*And the capture reads the frame we actually drew.* The first attempt allocated
its own buffer and re-rendered into it; the renderer refused the pass, because a
buffer must be in its render-format set and guessing XRGB8888/INVALID is not the
same as asking. `wlr_output_begin_render_pass` negotiates that already and leaves
the buffer in `state.buffer` — so the honest capture is the presented frame, not
a re-render into something we hoped was compatible. It writes a **PPM, not a
PNG**: the compositor would otherwise link an image encoder to prove it drew
something, and the harness has probed PPM with `od` since Phase 2 (HANDOFF
§2.26).

*Verified:* **3 new unit tests** (162 total) on both platforms — the globals and
socket, an empty scene compositing to nothing, and the capture's exact PPM
geometry. Live, `abyss/tests/live-undertow.sh` runs `undertow` and `AquaDemo` as
two real processes and asserts on **pixels**: the desktop is the blue we chose,
the window's middle is window-light, and just outside its left edge is desktop
again — that last one is what stops a scene that ignored geometry and painted the
whole output from passing everything else.

*Two harness bugs found on the way, both of the §2.34 family:* probing the
window's exact centre hit a control's border (187, not the light content it was
aiming at), so the test scans a strip and counts; and `od` emits 16 bytes per
line, so RGB triples do **not** align to its columns — the first count reported
466 light pixels in a 420-pixel strip, and a count exceeding its own denominator
is the only reason that was caught.

**P6.4 — Input. ✅ done.**
`wl_seat`, a compositor-drawn cursor, pointer/keyboard routing, click-to-focus
and raise. A click driven through our own seat, landing on the app:

![a click through undertow](screenshots/undertow-input.png)

That is `Clicks: 1`, the compositor-drawn cursor sitting on the gel button, and
the counter incremented because a pointer event travelled through `undertow`'s
seat into AquaDemo.

**The pointer is driven by `abyss/tests/vpointer.c`, completely unmodified.** It
speaks `wlr-virtual-pointer-unstable-v1`, which is how this harness has driven
sway since Phase 1 — so implementing that protocol's *server* side means the
existing tool drives us with no idea it is talking to a different compositor.
That is the payoff for four phases of client work: the assertions were already
written, against a compositor that did not exist yet. Real libinput devices
arrive with real hardware in Phase 4, through the same `new_input` path.

**The cursor is compositor-drawn**, which DESKTOP.md §3/§9 argues on latency
grounds (the pointer must never round-trip to a client) and which is also the
only way a headless capture can show where the pointer is. It is a rectangle;
a cursor theme belongs with the hardware cursor plane in Phase 4.

**Routing is a pure function.** `PointerRouting.hit` takes a point and a list of
rects and returns the topmost containing one — §2.9's discipline ("one pure
function feeds both paint and hit-test") a layer down. The rule deciding which
window owns a click must not need a running desktop to verify, and it now
doesn't.

*Verified:* **5 new unit tests** (167 total) on both platforms — topmost-wins,
surface-local coordinates (get this wrong and every control in every window is
offset by the window's position, which looks like a broken toolkit), half-open
edge bounds so two adjacent windows never both claim a pixel, cursor clamping,
and the seat offering the virtual-input globals. Live,
`abyss/tests/live-undertow-input.sh` proves the thing that matters: **the client
acted on it.** It captures a frame before any input and one after the click, and
asserts the "Clicks: N" region *changed* — with a **negative control** that a
patch of bare desktop did *not*, so the diff is the client responding rather than
two captures of an animating scene failing to be identical.

*A bug the negative control did not catch, but arithmetic did.* The early capture
re-armed itself every frame: `settleFrames < 0` meant both "not started" and
"finished" (I set `-2` for done), so it fired on ~40 consecutive frames and the
"before" file held the **last** write — taken after the click, and therefore
byte-identical to the "after" one. The input test failed for a reason that had
nothing to do with input. A separate boolean fixed it; the lesson is that a
sentinel value sharing a predicate with its own initial state is not a state
machine.

**P6.5 — C2: the isolation proof.**
The headline claim, and the one that justifies the architecture. Adversarial
clients — a spinner, a socket-flooder, a never-committer — running against the
compositor while the metronome holds cadence.
*Verify:* **missed flips == 0** under adversarial load, asserted in CI on both
platforms. A regression fails the build (C5). This is the pass that makes the
phase's promise falsifiable, and it is worth reaching early rather than late.

**P6.6 — The shell, on our own compositor.**
The server halves of what the Aqua shell already speaks as a client:
`wlr-layer-shell` (anchors, exclusive zones — the `arrange()` logic `tide` is
the design reference for), `wlr-foreign-toplevel-management`, `xdg-activation`.
*Verify:* `anchor` boots the desktop on `undertow` instead of sway, and the live
modes that assert composition (§2.26's workspace-rect check) pass against it.
The destination: **the Jaguar desktop, on our compositor, on FreeBSD.**

**P6.7 — What only a compositor can do.**
The debts the client architecture could never pay (§2.22): **remembered window
positions** for the spatial Finder, and **dragging desktop icons**. Plus the
server half of `wlr-screencopy`, which PHASE7 §6.6 hands to this phase — or its
`ext-image-copy-capture-v1` successor, since upstream deprecates the one we
bound in P7.5.
*Verify:* a spatial Finder window reopens where it was left; a desktop icon
stays where it is dragged; `abyss/tests/live-screenshot.sh` passes against
`undertow` with no change to the portal.

---

## 6. Verification

Unchanged discipline, with one addition. Pure logic in unit tests, the real
thing live, **everything green on both platforms**, `abyss/tests/run.sh --vm
--live` as the gate.

The addition is C5: **the perf benches gate the build like a unit test.**
`undertow` is its own bench harness, as `tide` is — flags for rate, frame count,
surface count, adversaries — and the harness asserts on the flight recorder's
output rather than on a wall-clock guess. Two standing cautions from the
sibling's STATUS.md §2, worth inheriting rather than rediscovering:

- **RT/timing benches flake under host load.** A lone contract failure in a full
  sweep is usually a stalled vCPU, not a regression; re-run it in isolation
  before believing it. Budget headroom accordingly — and prefer asserting on
  *the compositor's own CPU cost* (which is what C1 constrains) over end-to-end
  wall time (which the hypervisor can perturb).
- **Assert p99, not max.** One outlier in a VM proves nothing.

---

## 7. Risks / open decisions

**7.1 The GPU wall is real, and it is not ours to climb here.** Everything in
this phase is software-rendered and headless. That is not a shortcut — C1–C3 are
*defined* on the compositor's own CPU work and are fully provable this way — but
"undertow composites the desktop" will mean "in software" until Phase 4 puts it
on a Mac Pro. Say it that way.

**7.2 A spike is not the loop (§4.2).** Zero allocations in a synthetic loop
body does not guarantee zero in the real one. The mitigation is that the
allocation counter is a *test*, run every build, not a one-off measurement — and
that the flight recorder makes a violation visible as a latency spike.

**7.3 wlroots is a moving substrate.** Today both platforms are on 0.19.3 and
`check.sh` asserts it, so this is fine *now*. The risk is future drift: the
guest already offers 0.20, ports will move, and wlroots breaks API between minor
versions as a matter of policy. This is the first dependency where the dev box
and the target could diverge — everything else has been the same version on
both. Treat a wlroots bump as a deliberate pass, not a `pkg upgrade` side
effect.

**7.4 The reactor/present split is where the design can go wrong quietly.** C2
holds *by construction* only if the present thread genuinely never touches
anything a client controls. In Swift the sharp edge is ARC: a stray strong
reference across the triple buffer turns a lock-free publish into a retain/
release pair on the present thread. Design the snapshot as a POD struct over
preallocated storage, and let P6.1's counter enforce it.

**7.5 Deprecated protocol, inherited.** `wlr-screencopy` is deprecated upstream
in favour of `ext-image-copy-capture-v1`. P6.7 can implement the old server half
(cheap, matches our client) or move both halves (correct, more work). Deciding
late is fine; deciding *silently* is not — the portal's client code is P7.5's
and would have to move with it.

**7.6 This is the largest phase in the project.** Seven passes, and P6.6 is
itself most of a window manager. The ordering is deliberately front-loaded with
the parts that are provable in isolation (P6.1 needs nothing; P6.2 needs no
client; P6.5 is reachable before the shell), so that a stall late in the phase
still leaves a measured, tested artifact behind rather than a half-compositor.
