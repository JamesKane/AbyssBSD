# Phase 3 — FreeBSD bring-up (scope)

Expands PLAN.md §"Phase 3" from milestone sketch to executable detail, grounded in
a read of the Rust sibling's supervisor (`anchor`), hardware bridges (`vents`) and
IPC (`current`), and in a survey of this repo's own Linux-isms. Read
[PLAN.md](PLAN.md) for the locked decisions, [PHASE2.md](PHASE2.md) for the shell
this phase moves onto FreeBSD, and [HANDOFF.md](HANDOFF.md) for the traps.

Last updated: 2026-07-27.

**Phase 3 has begun — P3.1–P3.3 are done. The Jaguar desktop runs on FreeBSD,
and the project's #1 risk is closed.** Phase 2 left the Aqua shell — desktop,
menu bar, Dock, Finder, icons, launching — running on Linux against stock sway
and booting with one command (`abyss/session.sh`). Phase 3 makes it run **on
FreeBSD**, and gives it the native substrate underneath that Linux has been
standing in for. P3.1 built the box and found that **ports carries
`swift6-6.3.2`** — newer than our Linux toolchain. P3.2 built this repo with it
(**62/62 tests**, one `Package.swift` change, no source changes;
[SWIFT-ON-FREEBSD.md](SWIFT-ON-FREEBSD.md) is closed). P3.3 ran it:

![the Jaguar desktop on FreeBSD](screenshots/freebsd-desktop.png)

Next is the harness (P3.4), then the native substrate the shell has been faking
on Linux — the control plane, the session supervisor, the hardware bridges.

---

## 1. Scope boundary (what Phase 3 is and is NOT)

**Phase 3 = the Swift Aqua desktop running natively on FreeBSD 15, on a stock
wlroots compositor from ports, with its own Swift control plane, session
supervisor and hardware bridges underneath.** Two halves, in order:

1. **Bring-up** — the VM, the Swift toolchain (the standing #1 risk, **closed in
   P3.2**), the C substrate, and every portability debt Phase 1–2 deliberately
   deferred. Ends with a screenshot of the Jaguar desktop taken *inside FreeBSD*.
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
| Swift toolchain | 6.3.1 on Linux | ✅ ports `swift6-6.3.2` in the guest — was the #1 risk, [closed in P3.2](SWIFT-ON-FREEBSD.md) |

The shell itself is the part that should need the least work — it is deliberately
POSIX-and-Wayland all the way down. The Linux-isms were few and already known,
and **P3.2 settled all but one of them at a cost of one `Package.swift` edit**:

| Debt | Where | Outcome |
|---|---|---|
| `/usr/local` prefix | `Package.swift` — `CWayland` linked `wayland-client` with **no** pkgConfig | ✅ **the only real fix**: a `CWaylandClient` systemLibrary with `pkgConfig: "wayland-client"`, which `CWayland` depends on (P3.2) |
| `#if canImport(Glibc)` | ~20 Swift files | ✅ free — Swift names the platform libc module **`Glibc`** on FreeBSD too, so every guard was already right |
| inotify | `de/cpoolwatch/cpoolwatch.c` | ✅ the kqueue branch compiled and **passed its test** — first execution anywhere |
| `memfd_create` | `aw_create_shm` | ✅ the `SHM_ANON` branch compiled, likewise never built before |
| `timerfd` | `aw_create_interval_timer` (the menu-bar clock) | ✅ free — FreeBSD 15 has native `timerfd(2)`; no `EVFILT_TIMER` fallback needed |
| `_GNU_SOURCE` | `de/cwayland/cwayland_shm.c:1` | ✅ harmless — compiles clean |
| `/proc/self/exe` | `Launcher.selfExecutable` | ✅ **paid (P3.3)** — the new `CPlatform` C shim (`ap_self_executable`): `KERN_PROC_PATHNAME` there, `/proc/self/exe` here. Swift can't see `<sys/sysctl.h>` at all |
| epoll-over-kqueue | FreeBSD's libwayland (`wayland-client.pc` adds `-I/usr/local/include/libepoll-shim`) | ✅ **a non-event (P3.3)** — the client maps, paints and keeps frame callbacks with no run-loop change |
| bold/italic fonts | `de/ctext/ctext.c` style lists | ✅ **found and fixed in P3.3** — only the *regular* list had a FreeBSD path, so styled runs silently fell back to regular. A bug that could only exist on the target |

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
in the commit subject. P3.2 gated P3.3–P3.4 and P3.6–P3.7 — **that gate is now
open**: Swift builds and tests this repo on FreeBSD, so every remaining pass is
verifiable on the target rather than only on Linux. (P3.5 never depended on it;
§6.3.)

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
dated in [SWIFT-ON-FREEBSD.md](SWIFT-ON-FREEBSD.md). Finding it did not by
itself close the #1 risk — acceptance was `swift build` *and* `swift test` on
this repo — but it put the best of the three routes on the table, and P3.2 then
met that acceptance in full.

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

**P3.2 — Swift on FreeBSD. ✅ done — the #1 risk is closed.**
`swift build` succeeds and **all 62 tests pass** in the guest. The cost was
**one `Package.swift` change and no source changes at all**:

- **`CWayland` had no include flags.** It was a plain C target carrying
  `.linkedLibrary("wayland-client")`, which worked only because Linux keeps the
  headers in `/usr/include`; FreeBSD puts them under `/usr/local/include` and
  the build died on `'wayland-util.h' file not found`. Fix: a new
  **`CWaylandClient` systemLibrary** with `pkgConfig: "wayland-client"` that
  `CWayland` depends on — a C target can't carry a `pkgConfig:` itself but
  inherits one from a systemLibrary dependency, exactly as `CText` inherits
  FreeType and HarfBuzz. Portable, not a FreeBSD special case.

Four of the §2 debts turned out to be free, which is why this pass didn't need
P3.3's help:

- **`canImport(Glibc)` is true on FreeBSD** — Swift names the platform libc
  module `Glibc` there, so all ~20 guards took the right branch untouched. §6.4
  cost nothing.
- **`CPoolWatch`'s kqueue watch compiled and works.** `testWatcherWakesOnStore`
  passing is that branch's first execution anywhere in the project's life.
- **`aw_create_shm`'s `SHM_ANON` branch compiled**, likewise never built before.
- **`timerfd` is real on FreeBSD 15**, so the menu-bar clock needed no fallback.

Left for P3.3, because they are *runtime* debts a build can't reach:
`Launcher.selfExecutable`'s `/proc/self/exe`, and how the run loop behaves given
that FreeBSD's libwayland is built on an **epoll-over-kqueue shim**
(`wayland-client.pc` adds `-I/usr/local/include/libepoll-shim`, so
`wl_display_get_fd()` returns a shim fd — HANDOFF §2.14's poll-timeout loop is
the thing to watch).

*Verified:* `abyss/vm/build.sh` — new this pass — syncs and runs
`swift build` + `swift test` in the guest in one command, since Swift is off
PATH there and a non-interactive `ssh host 'cmd'` reads no profile. `AquaDemo`
links with all 48 shared libraries resolving. Findings dated in
[SWIFT-ON-FREEBSD.md](SWIFT-ON-FREEBSD.md), which is now **closed**.

*Known benign noise:* FreeBSD's `cairo.pc` carries `-D_THREAD_SAFE`, which
SwiftPM refuses to forward — every build prints
`warning: prohibited flag(s): -D_THREAD_SAFE`. The flag is dropped, which is
harmless for our single-threaded painting; `build.sh` filters the line.
Append dated findings to SWIFT-ON-FREEBSD.md's "Notes / findings" as you go; that
file is the deliverable as much as the working toolchain is.

The outcome forked the rest of the phase. **It came out (a)** — recorded here
because the alternatives shaped the plan and are worth keeping if the ports
toolchain ever goes stale:

| Outcome | Dev loop | Cost |
|---|---|---|
| **(a) native toolchain in the guest — this is the one (P3.1)** | unchanged: `sync.sh` then build+test in the guest, with `$ABYSS_GUEST_SWIFT_BIN` on the front | none |
| (b) cross-SDK only | build on Linux (`--swift-sdk x86_64-unknown-freebsd`), rsync artifacts, run in the guest | `abyss/tests/run.sh` gains a lane; in-guest `swift test` may not exist |
| (c) from source | as (a), after a multi-hour build | capture the exact recipe or it isn't reproducible |
| (d) none of the three | **Phase 3 is blocked** | fall back to the Linux track — golden-image tests, more of the shell — and keep the spike running |

**P3.3 — First pixels on FreeBSD. ✅ done.**
**The Jaguar desktop runs on FreeBSD.** The window first, headless with no
compositor at all, then live under sway + grim:

![an Aqua window on FreeBSD](screenshots/freebsd-window.png)
![the Jaguar desktop on FreeBSD](screenshots/freebsd-desktop.png)

Both remaining debts are paid, and one new bug turned up that only existed here:

- **`/proc/self/exe` → `KERN_PROC_PATHNAME`.** Swift's libc module surfaces no
  `<sys/sysctl.h>` on FreeBSD — `sysctl` and `sysctlbyname` are simply not in
  scope — so this became a small C shim, **`CPlatform`** (`de/cplatform`), in
  the `CPoolWatch` mould: one call, `ap_self_executable`, with the `#ifdef`
  inside C where it belongs. `Launcher.selfExecutable` now has no Linux-ism in
  it at all. That shim is also where P3.7's `vents` sysctl bridge will grow.
- **The epoll-over-kqueue shim is a non-event.** FreeBSD's libwayland is built
  on libepoll-shim, so `wl_display_get_fd()` returns a shim fd — the client maps,
  paints, and keeps its frame callbacks with no change to the poll-timeout run
  loop (HANDOFF §2.14).
- **Bold text was silently falling back to regular.** `ctext.c`'s *regular* font
  list had a FreeBSD path but the **bold / italic / bold-italic lists did not**,
  so every styled run quietly resolved to the regular face. FreeBSD ships DejaVu
  at `/usr/local/share/fonts/dejavu/`; those paths are now in every list. Visible
  in the screenshot above as the bold **Finder** app menu — and it would have
  been invisible on Linux forever.

**Layer-shell works on the guest's newer sway**, which was §6.6's open question:
the wallpaper maps 800×600 on BACKGROUND, the menu bar 800×22 on TOP, and the
exclusive zone really reserves space — sway's workspace rect comes back
`y=22, height=578`, the same assertion `live-session.sh` makes on Linux.

**`wayland-scanner` needs nothing.** Regenerating all four protocols in the
guest produces **8 files byte-identical** to the committed ones, so the vendored
XML + generated glue is genuinely portable rather than accidentally Linux-shaped.

*Verified:* `swift build` + **63/63 tests** in the guest (a new test covers
`selfExecutable` on both platforms), the headless PNG render matching Linux's
bar the font choice — the guest has DejaVu where Fedora has Noto — and the two
live captures above.

*Noted for P3.4:* FreeBSD sets no **`XDG_RUNTIME_DIR`** for an ssh session, so
the harness must provide one rather than assume it; the manual runs here set
`/tmp/xdg-$(id -u)` at 0700.

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

**6.4 Which C-stdlib module does Swift expose on FreeBSD?** ✅ **Closed
(P3.2): it's `Glibc`.** Swift names the platform libc module `Glibc` on FreeBSD,
so `#if canImport(Glibc)` is true there and all ~20 guards took the right branch
with zero edits. No `AbyssPlatform` module needed.

**6.5 `swift test` may lag `swift build`.** ✅ **Closed (P3.2): 62/62 pass in
the guest**, XCTest and Foundation included. No fallback needed; the in-guest
test run is a real gate, which is what makes P3.3–P3.7 verifiable on the target
rather than only on Linux.

**6.6 wlroots/sway version drift in ports.** ✅ **Answered (P3.3): no drift that
matters.** We develop against sway 1.11 here; the guest has **sway 1.12 /
wlroots019 0.19.3**, and layer-shell works there unchanged — BACKGROUND and TOP
surfaces map, and the exclusive zone reserves space exactly as on Linux
(workspace rect `y=22`). Foreign-toplevel and xdg-activation are still to be
exercised live in the guest (P3.4). Original note: Layer-shell,
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

**6.9 The standing #1 risk: ✅ CLOSED (2026-07-28).** Swift-on-FreeBSD gated
everything that ships to target, and it is retired: a 6.3.2 toolchain from ports
(P3.1) builds this repo and passes all 62 tests in the guest (P3.2), at a cost
of one `Package.swift` change. Every downstream unknown it implied went the same
way — the C substrate links under the `/usr/local` prefix, the never-compiled
kqueue and `SHM_ANON` branches work, `Glibc` is the right module name. What
remains is ordinary bring-up: does the thing *run* (P3.3), and does the harness
run with it (P3.4). §6.3's hedge is no longer needed, though it stays true.
