# Swift 6.4 — what bumping the toolchain buys, and what it costs (scope)

_2026-09-28. Swift 6.4 was released on 2026-09-15. This scopes moving to it: where
each platform's toolchain actually is, which of its features would simplify or
speed up this tree, which of those do not need 6.4 at all, and what was spiked
before writing any of it down._

## 0. The short of it

1. **6.4 cannot be the project's toolchain yet, because FreeBSD does not have
   it.** Ports carries `swift6` **6.3.3** (latest) and 6.3.2 (quarterly, which
   the build guest follows); swift.org publishes no FreeBSD 6.4 release, only a
   nightly of `main`; the one community 6.4 build is aarch64-only. A `lang/swift64`
   port is planned upstream, with no date. The rule that every pass is green on
   both platforms means **no code may use a 6.4-only feature until the guest has
   6.4.** Linux could move today and would only drift.
2. **The largest simplification on offer needs no new toolchain.** HANDOFF §2.1 —
   "Swift's C importer cannot see `static inline` functions", the reason for the
   ~95 `aw_*` wrappers in `de/cwayland` — **is false for the compilers we use.**
   A probe calling libwayland's `static inline` `wl_display_get_registry` and
   `wl_registry_add_listener` directly compiled, ran against a live compositor
   on Swift 6.3.1 (Linux), and compiled and linked on 6.3.2 (FreeBSD). (§3, S.1)
3. **Most of what 6.4 advertises for performance is already here.**
   `InlineArray` and `Span` are 6.2; noncopyable types, typed throws and the
   `Synchronization` module are 6.0. What 6.4 adds on top is ergonomics for
   those (borrow/mutate accessors, `UniqueArray`, `UniqueBox`, `Ref`), and none
   of it is a speed-up this tree is waiting for.
4. **The real risk in 6.4 is the build system, and it has been measured.** 6.4
   makes Swift Build SwiftPM's default. Opted into on 6.3 today, it builds the
   whole tree on Linux, **fails three tests** (the vendored fonts are not found —
   the executable's directory layout changed), and **cannot start on FreeBSD at
   all** (it does not recognise the ports toolchain's layout). (§4)

**Recommended order:** 6.3.3 on both platforms now (§2); retire the `aw_*` shims
and fix one real bug the survey found (§3); carry the Swift Build findings until
FreeBSD has 6.4, then bump (§5).

---

## 1. Where the toolchains are

| | Linux (dev box) | FreeBSD (build guest, the medium) |
|---|---|---|
| In use | 6.3.1, via `swiftly` | `swift6-6.3.2`, ports quarterly, `/usr/local/swift6/bin` |
| Available now | 6.3.3 (`swiftly install 6.3.3`); 6.4.0 released upstream — `swiftly list-available` on this box did not list it yet | 6.3.3 on the ports *latest* branch (2026-07-15); the 2026Q4 quarterly branch opens in early October |
| 6.4 | released 2026-09-15 | **none**: not in ports, no swift.org release (a nightly of `main` only), community builds aarch64-only; `lang/swift64` planned, undated |

**What a bump touches in this tree:** no version pin in code. `Package.swift` is
`swift-tools-version: 6.0` with no settings beyond one linked library; the guest
finds Swift at `ABYSS_GUEST_SWIFT_BIN` (`abyss/vm/config.sh`), a ports *path*,
not a version. The live medium and the installed system ship whatever runtime
`ldd` finds (`abyss/mk/live-image.sh`: 19 Swift runtime libraries of 84 shared
objects), so a bump changes what the medium carries **automatically** — which is
why any bump runs the `--full` lane (HANDOFF §5, "the medium").

**A FreeBSD bug in the news that does not touch us:** the aarch64 6.4 work found
`Synchronization.Mutex` deadlocking on FreeBSD (waiters parked on the wrong
kernel queue) and it may affect amd64 too. The tree uses **no `Mutex`** — its one
`Synchronization` use is `Atomic<UInt64>` in the flight recorder. Worth
remembering the day anything reaches for `Mutex`.

---

## 2. Step A — 6.3.3 on both platforms (now, S)

A patch release, available on both sides today. Linux: `swiftly install 6.3.3 &&
swiftly use 6.3.3`. FreeBSD: the guest (and the machine that builds the medium)
takes it from the 2026Q4 quarterly once that branch opens, or from *latest*
sooner; `abyss/vm/make-seed.sh` names the package, not the version.

**Verify:** `run.sh --live`, `run.sh --vm --live --full` (the medium's runtime
changes), both golden gates. Nothing else changes; this is the rehearsal for the
6.4 bump, on a version both platforms can actually run.

---

## 3. Step B — what 6.3 already allows, in order of payoff

| # | Item | Size | Payoff | Needs |
|---|---|---|---|---|
| ~~S.1~~ | ✅ **Done 2026-09-30** (BACKLOG, HANDOFF §2.93: binds keep a C pointer per global). **Retire the `aw_*` shims.** Call libwayland's generated requests and `*_add_listener` directly; keep the generated `*-protocol.c` interface tables. 136 call sites in 11 files, ~95 wrappers, ~680 lines of C and header | M | adding a protocol stops being "vendor the XML *and* hand-write a wrapper per request"; one layer of indirection and one class of drift gone | 6.2+ (spiked on 6.3.1 and 6.3.2) |
| S.2 | **Fix `Seat.spawnDetached`**: the child calls `strdup` after `fork` — allocation where only async-signal-safe calls are allowed, which this codebase's own rule forbids (`anchor/Policy.swift`, HANDOFF §2.25). Build argv before forking, as `Launcher` does, or use `de/cproc` | S | a real bug: a deadlock waiting to happen the first time the allocator's lock is held across a keybind's fork | nothing |
| S.3 | **One spawn helper.** Six Swift files fork/exec by hand (`Launcher`, `Seat`, installer `Runner` and `Probe`, `fathombin`, `dbusbin`); `withCStrings` is duplicated twice | S–M | one place to be async-signal-safe, instead of six | nothing |
| S.4 | **`InlineArray` for the fixed-capacity present-path buffers**: `SurfaceScene`'s six preallocated columns (capacity 256) and the flight recorder's ring | S | no manual allocate/deinitialize/deallocate, bounds-checked by construction; one allocation instead of seven | 6.2+; **only with `bench-metronome` and C1/C2 before and after** — the payoff is safety, and the present path must not get slower to buy it |
| S.5 | **`Span`/`RawSpan` for wire parsing** — D-Bus marshalling, `CurrentIPC` framing, `PoolConfig`'s mmap parse, screencopy normalisation | M | bounds safety without copying; the parsers currently index raw buffers | 6.2+; per parser, each with its tests unchanged |
| — | Typed throws for the 12 error types | S each | clarity, not speed | optional; not recommended as a pass of its own |

**Not recommended, and why:**
- **Subprocess 1.0** (needs only 6.2, lists FreeBSD) is **async-only**, and this
  tree has no async code by design — `undertow` is single-threaded (PHASE6).
  Nor does it expose `pdfork`, which is how `anchor` makes every child a
  pollable descriptor. S.3 is the simplification that fits.
- **Adopting concurrency** (actors, `Task`) for its own sake: the synchronous,
  one-wait design is deliberate and is what C2 is measured on.
- **Embedded Swift** for the realtime path: rejected in PHASE6, and 6.4's
  improvements (existentials, errors) do not touch the reason.

---

## 4. The spikes

**4.1 Can Swift call `static inline` C? — Yes, on both platforms.** A scratch
package with a `systemLibrary` over `wayland-client` called
`wl_display_get_registry` and `wl_registry_add_listener` — both `static inline`
in `wayland-client-protocol.h` — with no shim. Linux 6.3.1: compiled, ran against
the dev box's compositor, listed its globals; the binary imports
`wl_proxy_marshal_flags` and `wl_proxy_add_listener`, i.e. Clang compiled the
inline bodies in. FreeBSD 6.3.2: compiled and linked the same (the guest has no
compositor to run it against). HANDOFF §2.1 was inherited as a rule and never
re-tested; it now carries a correction.

What stays in C after S.1: `wl_container_of` is a macro (offset arithmetic), and
`wl_signal_add` in wlroots' server headers — static inline, so importable, but
the `tw_listen` trampoline that recovers a Swift context from a bare
`wl_listener *` is still simplest in C until 6.4's `@c @implementation` (§5).

**4.2 Does the tree build under Swift Build? — On Linux, yes, and three tests
fail. On FreeBSD, it does not start.** Swift Build is opt-in on 6.3
(`swift build --build-system swiftbuild`) and 6.4's default.

- **Linux:** the whole tree built (≈7 s from clean with 9 cores busy) with the
  warnings the native build already prints, plus an unused `-rdynamic` on every
  target. `swift test` ran every bundle separately: **553 passed, 3 failed**, all
  in `TextRoleTests`: the vendored fonts (Chakra Petch, VT323) were not found
  and text fell back to Noto. The font search locates `fonts/` relative to the
  executable, and Swift Build's product layout (`Products/Debug-linux/…`) is not
  `.build/debug`. The theme loader's search path (P11.10) is the same shape and
  deserves the same look. *A counting trap on the way:* each bundle prints its
  own "Executed N tests" line, and the last one said 29 — the first reading was
  "the suite shrank"; summing every bundle says it did not.
- **FreeBSD:** `error: Unexpected toolchain layout for Swift installation path:
  /usr/local/swift6/bin` — Swift Build does not recognise the ports layout, so
  under 6.4's default the guest could not build anything. Either ports' 6.4
  layout satisfies it, or the guest passes `--build-system native` until it
  does.

---

## 5. Step C — 6.4, once FreeBSD has it

**The bump itself (M, mostly verification):** Linux via `swiftly`; the guest via
whichever FreeBSD 6.4 arrives first (§6.1). Carry §4.2's two findings in: the
font and theme search paths must not assume `.build/debug`, and the guest's build
must either work under Swift Build or pin `--build-system native` in
`abyss/vm/build.sh` explicitly, with the reason. Also re-check §2.66 (SwiftPM
not recompiling across an `@_exported` re-export) under the new build system —
it may be fixed, or it may be different.

**6.4 features that fit this tree, when it is allowed to use them:**

| Feature | Where it fits | Verdict |
|---|---|---|
| Borrow/mutate accessors for `Span`/`InlineArray` (SE-0507) | S.4's columns, S.5's parsers | makes S.4/S.5 read better; adopt as they are touched |
| `UniqueArray` (SE-0527), `UniqueBox` (SE-0517) | the scene and recorder, if a fixed 256 ever has to grow | only then; `InlineArray` fits a fixed capacity better |
| `@c` + `@implementation` | implement C-declared functions in Swift: the `tw_*` trampolines, some of `de/cplatform` | a spike: could retire most of the C that S.1 leaves |
| `withTemporaryAllocation`, initialized (SE-0524) | `DrawList`'s glow/halo scratch buffers | small; adopt when touched |
| `RawSpan` safe loading (SE-0525) | D-Bus and `CurrentIPC` field reads | with S.5 |
| `@diagnose` (SE-0522) | local control of one warning rather than a target-wide flag | when a warning needs it |
| Precise module tracking in debug info | LLDB in a tree of ~40 targets | free with the bump |
| Swift Build default | — | the cost, not a feature (§4.2) |

**Not relevant here:** Java and C++ interop, WebAssembly, Android, Embedded Swift,
async `defer` and cancellation shields (no async code), `@Observable`,
SBOM generation, the VS Code extension.

---

## 6. Risks and decisions

**6.1 How FreeBSD gets 6.4.** (a) Wait for `lang/swift64` / `swift6` to move —
recommended; (b) build 6.4 from source in the guest — hours, ~3 GiB, and a
toolchain nobody else runs; (c) the swift.org FreeBSD nightly — a `main`
snapshot, not a release. **Recommendation: (a), and revisit when ports moves.**

**6.2 S.1 is a large mechanical diff.** 136 call sites across the toolkit's
Wayland layer. It changes no behaviour, which is exactly what makes it risky to
review; the gate is the whole `--live` lane on both platforms, and doing it one
file at a time with the suite green between.

**6.3 S.4 touches the present path.** C1 fails on metal already (PHASE4 §5.7). No
change to the scene's storage lands without `bench-metronome` and the C1/C2
numbers before and after, on both platforms.

**6.4 A toolchain bump changes what the medium ships.** Always `--full`.
