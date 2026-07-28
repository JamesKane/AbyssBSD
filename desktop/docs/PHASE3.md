# Phase 3 — FreeBSD bring-up (scope)

Expands PLAN.md §"Phase 3" from milestone sketch to executable detail, grounded in
a read of the Rust sibling's supervisor (`anchor`), hardware bridges (`vents`) and
IPC (`current`), and in a survey of this repo's own Linux-isms. Read
[PLAN.md](PLAN.md) for the locked decisions, [PHASE2.md](PHASE2.md) for the shell
this phase moves onto FreeBSD, and [HANDOFF.md](HANDOFF.md) for the traps.

Last updated: 2026-07-27.

**Phase 3 has begun — P3.1 is done.** Phase 2 left the Aqua shell — desktop,
menu bar, Dock, Finder, icons, launching — running on Linux against stock sway
and booting with one command (`abyss/session.sh`). Phase 3 makes it run **on
FreeBSD**, and gives it the native substrate underneath that Linux has been
standing in for. P3.1 built the box it happens in, and turned up the phase's
best possible news: **ports carries `swift6-6.3.2`**, newer than our Linux
toolchain (§4, P3.1).

---

## 1. Scope boundary (what Phase 3 is and is NOT)

**Phase 3 = the Swift Aqua desktop running natively on FreeBSD 15, on a stock
wlroots compositor from ports, with its own Swift control plane, session
supervisor and hardware bridges underneath.** Two halves, in order:

1. **Bring-up** — the VM, the Swift toolchain (the standing #1 risk), the C
   substrate, and every portability debt Phase 1–2 deliberately deferred. Ends
   with a screenshot of the Jaguar desktop taken *inside FreeBSD*.
2. **The native substrate** — `CurrentIPC`, a Swift session supervisor
   (`anchor`'s job, replacing `abyss/session.sh`), and the Swift hardware bridges
   (`vents`' job) that finally make the menu bar's volume and battery real.

Everything is a **Swift rewrite read from the sibling as a spec**, never a link
against it (PLAN.md, corrected 2026-07-27). `PoolConfig` is the pattern.

**Explicitly NOT in Phase 3:**

- **No compositor work.** The shell runs as clients against **stock sway/labwc**,
  which FreeBSD ports the same as Linux does. A Swift compositor is Phase 6, and
  nothing here waits on it. What that costs us is unchanged from Phase 2 and
  documented: a client can't position its own windows, so spatial Finder
  positions and desktop-icon dragging stay out of reach (HANDOFF §2.22).
- **No portals, no D-Bus bridge, no XWayland.** PLAN.md files "the D-Bus
  replacement story" under Phase 3; it is **carved out to its own phase**
  (decided 2026-07-27, §6.1). The reason is sequencing, not doubt: the sibling's
  portal design is *compositor-owned* (`reef-portal` lives in `tide`), and we
  won't own a compositor until Phase 6. A client-side subset is feasible on sway
  (a Finder-backed file chooser; screenshots via `wlr-screencopy`), but it is a
  phase of work, not a pass, and it does not gate FreeBSD.
- **No Mac Pro, no GPU.** Phase 4. Everything here is verified in the qemu/KVM
  VM under sway's **headless** backend, exactly as Phase 2 was on Linux.
- **No `shmring`.** It exists in the sibling for the compositor's hot path. We
  have no compositor and no measured need; if one appears, it's a pass then.

---

## 2. What we already have vs. what's new

| Need | Have (Phase 1–2) | New (Phase 3) |
|---|---|---|
| Toolkit, shell, client runtime | `Aqua`, `Surface`, the five shell components | — (they *port*, they don't get rewritten) |
| Config | `PoolConfig` + `CPoolWatch` (kqueue branch **written, never compiled**) | first FreeBSD build + test of the kqueue half |
| Session launch | `abyss/session.sh` (POSIX sh, supervises + tears down) | **Swift supervisor** (`pdfork` + `EVFILT_PROCDESC`) |
| Control plane | — | **`CurrentIPC`** (carried from P2.9) |
| Hardware (volume, battery, hotplug) | — (menu bar has no status items) | **sysctl / OSS / devd bridges** |
| Build + test host | this Linux box | the **FreeBSD VM** + an in-guest test lane |
| Swift toolchain | 6.3.1 on Linux | **the #1 risk** — see [SWIFT-ON-FREEBSD.md](SWIFT-ON-FREEBSD.md) |

The shell itself is the part that should need the least work — it is deliberately
POSIX-and-Wayland all the way down. The Linux-isms are few and already known:

| Debt | Where | Fix |
|---|---|---|
| `/proc/self/exe` | `Launcher.selfExecutable` (`de/aqua/Launcher.swift:124`) | `KERN_PROC_PATHNAME` sysctl; `$ABYSS_APP_BINARY` overrides meanwhile |
| inotify | `de/cpoolwatch/cpoolwatch.c` | kqueue branch is **already written** (`#elif defined(__FreeBSD__)`) — it just has never been compiled |
| `memfd_create` | `aw_create_shm` | `SHM_ANON` branch already written, likewise never compiled |
| `timerfd` | `aw_create_interval_timer` (the menu-bar clock) | FreeBSD 13+ has native `timerfd(2)` — *verify*, else a kqueue `EVFILT_TIMER` fd |
| `#if canImport(Glibc)` | ~20 Swift files | depends on what module Swift exposes on FreeBSD (§6.4) — funnel it through **one** place rather than editing twenty guards |
| `_GNU_SOURCE` | `de/cwayland/cwayland_shm.c:1` | harmless or dropped; confirm at first compile |
| `/usr/local` prefix | `Package.swift` — `CWayland` links `wayland-client` with **no** pkgConfig | pkg-config the wayland libs, or carry `-L/usr/local/lib -I/usr/local/include` |

---

## 3. Component map (sibling → ours)

| Job | Sibling analog | Ours | Notes |
|---|---|---|---|
| Session supervisor | `anchor` (456 LOC) | **Swift rewrite** (P3.6) | `pdfork(2)` + kqueue `EVFILT_PROCDESC`/`EVFILT_SIGNAL`; hosts a control service |
| Control plane | `current` (551 LOC) | **`CurrentIPC`** (P3.5) | unix sockets, typed messages, `SCM_RIGHTS` |
| Hardware bridges | `vents` (658 LOC: sysctl 127, oss 86, devd 314) | **Swift rewrite** (P3.7) | `sysctlbyname`, `/dev/mixer` ioctls, the devd socket |
| Config | `pool` (458 LOC) | `PoolConfig` — **done** (P2.3) | the pattern the rest follow |
| Compositor | `tide` (11,573 LOC) | Phase 6 | stock sway/labwc from ports until then |
| Portals | `reef-portal` (in `tide`) | carved out (§6.1) | compositor-owned in the sibling; needs Phase 6 or a client-side subset |

The sibling's crates are ~1,700 LOC total for the three we rewrite here — small,
FreeBSD-specific, and well-documented. That is why they're a rewrite and not a
port: the value is in the *design* (`anchor`'s descriptor-as-handle discipline,
`vents`' choice of native facilities over Linux ones), and it reads in an hour.

---

## 4. Ordered passes (recommended)

One build→verify→test→doc→commit pass each, as in Phase 2, with the pass number
in the commit subject. **P3.2 gates P3.3–P3.4 and P3.6–P3.7** — but note that
**P3.5 (`CurrentIPC`) does not depend on it** and can be built and tested on
Linux while the toolchain spike runs (§6.3).

**P3.1 — The build VM + a corrected seed. ✅ done.**
A fresh `../abyss-swift-vm` (FreeBSD 15.0-RELEASE-p11) now provisions from a
corrected seed and is asserted usable by a new **`abyss/vm/check.sh`**. The
sibling's `../abyss-vm` is untouched. What changed:

- **The seed no longer installs Rust.** It was there "for the BORROWED engine …
  we reuse from the sibling in Phase 3" — dead under the corrected policy. In
  its place: Swift's own runtime deps (icu, libxml2, curl, libedit) and **grim**,
  which the live tests capture with.
- **`make-seed.sh` generates the ssh key** if it's absent instead of failing, so
  the flow runs from a clean checkout. The sibling's key was made by hand, which
  is why its absence used to be a hard error.
- **The `|| true` blind spot is closed.** Every `pkg install` is best-effort so a
  missing port can't wedge first boot — which meant a silent miss looked exactly
  like success, `~/.cloud-init-done` appearing either way. The seed now records
  anything absent in `~/.pkg-missing`, and `check.sh` asserts on that, on the
  pkg-config names `Package.swift` actually uses, and on the tools
  `abyss/tests` shells out to (sway, swaymsg, grim, cc).
- **`sync.sh` excludes `.build/`** (and both VM homes) — it would otherwise push
  the host's Swift build tree into the guest on every sync.

**The headline: FreeBSD ports has Swift 6, and it's newer than ours.**
`pkg install -y swift6` lands **`Swift version 6.3.2 (swift-6.3.2-RELEASE)`,
`Target: x86_64-unknown-freebsd15.0`**, with `swift-build`, `swift-test`,
Foundation *and* XCTest. The old seed's `pkg install -y swift` was a **false
negative** — the package is named `swift6`. It installs to
`/usr/local/swift6/bin`, deliberately off PATH so 5.10 and 6.x coexist, so
`config.sh` exports **`ABYSS_GUEST_SWIFT_BIN`** rather than assuming `swift`
resolves (a non-interactive `ssh host 'cmd'` reads no profile). Findings are
dated in [SWIFT-ON-FREEBSD.md](SWIFT-ON-FREEBSD.md). This does **not** close the
#1 risk — acceptance is `swift build` *and* `swift test` on this repo, which is
P3.2 — but option (1) working at all is the best available outcome.

*Verified:* a from-scratch reprovision (overlay disk discarded, seed rebuilt) →
`check.sh` green: all seeded packages present; wayland-client 1.25.0,
wayland-scanner, xkbcommon 1.13.2, cairo 1.18.2, freetype2 26.6.20, harfbuzz
14.2.1, libpng 1.6.58 all resolvable through pkg-config; sway 1.12 / swaymsg /
grim / cc present; the Swift toolchain reporting 6.3.2. `sync.sh` puts the tree
at `~/AbyssBSD-swiftDE` in the guest.

*Two notes for later passes:* the guest's **sway is 1.12** against 1.11 on the
Linux dev box (§6.6's drift, now concrete), and first boot takes **~15 minutes**
— freebsd-update, then ~100 packages, and sshd only starts after all of it, so
`check.sh` waits generously by default.

**P3.2 — Swift on FreeBSD (the go/no-go spike).**
The standing #1 risk. **P3.1 already settled which branch we're on:** option (a),
the ports toolchain — `swift6-6.3.2`, targeting `x86_64-unknown-freebsd15.0`,
installed in the guest and reporting itself, with `swift-build`, `swift-test`,
Foundation and XCTest all present. The cross-SDK and build-from-source routes
stay documented but unneeded unless this one fails to build the repo.
What's left is the acceptance that actually matters: **`swift build` succeeds on
this repo, and `swift test` runs the 62 tests.** Expect the first failures to be
the §2 debt table rather than the compiler, which is why P3.3 exists — the split
is deliberate: P3.2 answers "does Swift work here", P3.3 answers "does *our
code* work here". Note `swift test` remains a *separate* risk from `swift build`
(XCTest and Foundation are a different project from the compiler) — but its
presence in the package is a good sign, and it downgrades §6.5.
Append dated findings to SWIFT-ON-FREEBSD.md's "Notes / findings" as you go; that
file is the deliverable as much as the working toolchain is.

The outcome forks the rest of the phase, so record which branch we're on:

| Outcome | Dev loop | Cost |
|---|---|---|
| **(a) native toolchain in the guest — this is the one (P3.1)** | unchanged: `sync.sh` then build+test in the guest, with `$ABYSS_GUEST_SWIFT_BIN` on the front | none |
| (b) cross-SDK only | build on Linux (`--swift-sdk x86_64-unknown-freebsd`), rsync artifacts, run in the guest | `abyss/tests/run.sh` gains a lane; in-guest `swift test` may not exist |
| (c) from source | as (a), after a multi-hour build | capture the exact recipe or it isn't reproducible |
| (d) none of the three | **Phase 3 is blocked** | fall back to the Linux track — golden-image tests, more of the shell — and keep the spike running |

**P3.3 — The C substrate + first pixels on FreeBSD.**
Get `swift build` producing a working `AquaDemo` in the guest and pay every debt
in §2's table. The two branches that have **never been compiled anywhere**
(`CPoolWatch`'s kqueue watch and `aw_create_shm`'s `SHM_ANON`) are the ones to
expect trouble from; the `PoolConfig` watcher test is the kqueue branch's proof
and it already exists. `wayland-scanner` comes from the `wayland` package and the
protocol XML is vendored, so `generate-protocols.sh` should need nothing — but
regenerate in the guest once to prove it.
*Verify:* first, the headless PNG render (`AQUA_RENDER_PNG=/tmp/aqua.png
AquaDemo`) in the guest with **no compositor at all** — that isolates cairo /
FreeType / HarfBuzz / the toolkit from Wayland entirely; diff it against the
Linux render. Then `AquaDemo` under sway's headless backend + grim: **the first
FreeBSD screenshot**, checked in. That is this pass's milestone and the phase's
first real one.

**P3.4 — The harness and the session, in the guest.**
Make the Phase-2 verification machinery run under FreeBSD: `abyss/tests/run.sh`,
`live-sway.sh` (all ~20 modes), `live-session.sh`, and `abyss/session.sh` itself.
Known suspects: the virtual-pointer/keyboard C helpers (base clang, should be
fine), sway's IPC socket naming and the `sway-ipc.*.$pid.sock` glob
`session.sh` matches on, `swaymsg exec`'s environment dump (HANDOFF §2.26), and
whether headless sway wants seatd in the guest. Add an in-VM lane to
`abyss/tests/run.sh` (the sibling's `run-vm.sh`/`run-kyua.sh` are the model).
*Verify:* the same live tests that pass on Linux pass in the guest, screenshots
checked in beside their Linux counterparts.

**P3.5 — `CurrentIPC` (the P2.9 carry).**
The Swift control plane, finally with peers to talk to. Shape from the sibling
(read it, don't link it): a `Msg` of typed fields (str/u64/bool/bytes/**fd**),
`runtimeDir()` (`$ABYSS_RUNTIME_DIR`, else `$XDG_RUNTIME_DIR/abyss`, else
`/var/run/user/<uid>/abyss`, 0700), a socket per service at
`<runtime_dir>/<service>.sock`, `Server.bind/accept`, `connect`, and a one-shot
`call`. The listening fd folds into `Display.addFileDescriptor` — no thread, no
second loop (HANDOFF §2.18).
**Prototype fd passing first.** `sendmsg`/`recvmsg` with `SCM_RIGHTS` is the part
that decides the encoding, not the field types (PHASE2.md P2.9). Default to a
Swift-native codec; base libnv stays the fallback, and if we bind it, expect the
`#define` symbol-prefix trap — `<sys/nv.h>` maps the short names onto
`FreeBSD_nvlist_*` and Swift's importer can't see `#define`s, so it needs a
`de/cnv` shim in the `aw_*` style. **Never vendor a port of libnv.**
*Verify:* codec round-trips as unit tests (pure bytes, both platforms); a live
test where one process hands a real shm fd with known bytes to another and the
receiver reads them back; and a small `abyssctl` that talks to a running service.

**P3.6 — The session supervisor, in Swift (`anchor`'s job).**
Launch the compositor, read the `WAYLAND_DISPLAY` it prints, launch the desktop /
menu bar / Dock against it, supervise them, tear the session down together — no
systemd, no polling. Native facilities: `pdfork(2)` for children (the descriptor
*is* the handle — closing it reaps, so no zombies and no `waitpid` races),
kqueue `EVFILT_PROCDESC` to notice a death, `EVFILT_SIGNAL` for its own
lifecycle. Points `$ABYSS_RUNTIME_DIR` at the session runtime dir so every
component's sockets share one namespace, and hosts a `CurrentIPC` control service
(`status`, `quit`) — which is what makes P3.5 land before it.
This replaces `abyss/session.sh`, whose restart-counter and teardown-ordering
behaviour is the spec to match (HANDOFF §2.26). Recommendation (§6.2): write it
**portable** — a small platform shim (pdfork/kqueue on FreeBSD, pidfd/epoll on
Linux) like `CPoolWatch` — so it can be developed and tested on this box instead
of only in the VM.
*Verify:* `live-session.sh`'s assertions, driven by the Swift supervisor instead
of the script: three layer surfaces in their namespaces, the exclusive zone
reserved, killing the Dock brings a new one back, and `quit` over the control
socket tears the session down cleanly.

**P3.7 — Hardware bridges + the menu bar's status items.**
`vents`' job, in Swift, and the phase's visible payoff. Three bridges, each
small: **sysctl** (`sysctlbyname(3)` — callable straight from Swift, as
`PoolConfig` calls `mmap`), **OSS** volume (`/dev/mixer` ioctls — `ioctl`'s
varargs need a one-line C shim, the `CPoolWatch` pattern again), and **devd**
(read `/var/run/devd.seqpacket.pipe`, fold the fd into the run loop for hotplug
and power events).
Then wire them to the UI that has been waiting for them since P2.4: a real
**volume** menu extra with a slider, a **battery** extra off the `hw.acpi.battery`
sysctls, and — if devd makes it cheap — a removable volume appearing on the
desktop when it's plugged in.
*Verify:* pure parts unit-tested; in the guest, set the mixer underneath and
watch the extra follow; a screenshot of the FreeBSD menu bar showing real status
items closes the phase.

---

## 5. Verification (the discipline, extended by one layer)

- **Unit (host):** `swift test` on Linux stays the fast loop — every pure piece
  (codec round-trips, supervisor state machine, sysctl parsing) must be testable
  with no VM and no compositor. This is why P3.5/P3.6 are worth writing portable.
- **Unit (guest):** the same `swift test` in the VM is what proves the platform
  forks — `CPoolWatch`'s kqueue branch has no other honest test.
- **Live (guest):** `live-sway.sh` and `live-session.sh` under headless sway +
  grim in the VM, screenshots checked in beside the Linux ones so a regression is
  visible rather than described.
- **Two-layer harness:** `abyss/tests/run.sh` grows an in-VM lane (host build +
  test, then sync + in-guest build + test + live), adapting the sibling's
  `run-vm.sh`/`run-kyua.sh`.
- **The perf gate is not yet ours to clear.** `tide`'s C1–C5 benches measure a
  compositor; we don't have one until Phase 6. Phase 3 inherits the *contract*
  (don't regress input-to-photon on the client side), not the benchmark.

---

## 6. Risks / open decisions

**6.1 Portals + the legacy D-Bus story: carved out (decided 2026-07-27).**
PLAN.md files it under Phase 3. It moves to its own phase, because the sibling's
portal design is compositor-owned and Phase 6 owns the compositor, and because
"GTK/Qt apps work" is a product goal with its own surface area (a jailed session
bus, XWayland, MPRIS, AT-SPI) rather than a step in bringing Swift up on FreeBSD.
Nothing in Phase 3 depends on it. When it comes back, note that a useful subset
*is* reachable from a client on sway: a Finder-backed file chooser over
`CurrentIPC`, and screenshots via `wlr-screencopy`.

**6.2 Supervisor: FreeBSD-only or portable?** *Recommendation: portable.*
`anchor` is unapologetically FreeBSD-native and that's right for it. But a
FreeBSD-only supervisor can only be tested in the VM, and it would leave Linux
dev on `session.sh` forever — two implementations of one behaviour. One small
platform shim (pdfork+kqueue / pidfd+epoll) buys host-side testing and a single
implementation. Decide at P3.6; `CPoolWatch` is the precedent that it costs
about thirty lines of C.

**6.3 `CurrentIPC` can start before the toolchain lands.** Unix sockets and
`SCM_RIGHTS` are POSIX, and the codec is ours — so if we take the Swift-native
default, P3.5 builds and tests **on Linux today** and merely gains real peers on
FreeBSD. That makes it the right work to do if P3.2 stalls. It is only blocked if
we choose libnv, which is itself an argument for the Swift codec.

**6.4 Which C-stdlib module does Swift expose on FreeBSD?** Every one of ~20
files opens with `#if canImport(Glibc)`. If FreeBSD's Swift presents something
other than `Glibc`, that's a twenty-file edit — and the right fix is *one* module
(`AbyssPlatform`) that re-exports the correct one, not twenty new guards. Settle
it in the first hour of P3.3.

**6.5 `swift test` may lag `swift build`.** *Downgraded 2026-07-28:* the
`swift6` package ships `swift-test` and an `XCTest.swiftmodule` for `freebsd`
alongside Foundation, so the machinery is at least present. Whether the 62 tests
*pass* is still P3.2's to find out. If they can't run, the fallback is unchanged:
host-side `swift test` stays the unit gate and the guest is verified live only —
weaker, and worth saying out loud in the pass that discovers it.

**6.6 wlroots/sway version drift in ports.** We develop against sway 1.11 here;
the guest has **sway 1.12 / wlroots019 0.19.3** (measured in P3.1). Layer-shell,
foreign-toplevel and xdg-activation are all we need, and all are old and stable —
but a version mismatch shows up as a *missing global*, which our clients should
report clearly rather than crash on. Check that behaviour early.

**6.7 Naming the rewrites.** *Recommendation: keep the aquatic names* —
`Anchor`, `Vents`, `CurrentIPC` — as Swift module names. The sibling is abandoned
as a product, so there's no clash, and PLAN.md's naming table already reads that
way. Names are a theme, not a contract.

**6.8 Unprivileged access to the hardware bridges.** OSS mixer writes and some
sysctls want permissions the desktop user may not have. `vents` splits reads from
"privileged writes" for this reason. Find out in P3.7 what the shell can do as
the logged-in user, and don't design a status item that needs root.

**6.9 The standing #1 risk, materially reduced (2026-07-28).** Swift-on-FreeBSD
gates everything that ships to target, and P3.1 found the good branch: a current
6.3.2 toolchain in ports, installed and running in the guest. It is *reduced*,
not closed — nothing of ours has compiled there yet, and the remaining unknowns
have moved downstream: does the C substrate link under a `/usr/local` prefix, do
the never-compiled kqueue and `SHM_ANON` branches work, do the tests pass. Those
are P3.2/P3.3, and they are ordinary bring-up problems rather than existential
ones. §6.3 remains the hedge if the repo build turns out worse than the
toolchain.
