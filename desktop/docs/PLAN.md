# AbyssBSD (Swift DE) — Phased Roadmap

## Context

We are starting **AbyssBSD**, a FreeBSD `releng/15.0` fork whose headline feature is a
**new desktop environment written in Swift 6**, styled as a faithful clone of
**Mac OS X 10.2 "Jaguar" Aqua**, running on **Wayland**, with a Fedora/Anaconda-style
graphical installer. The bring-up target was the **Mac Pro 2013 (MacPro6,1)**;
since 2026-09-05 it is an **Intel i7-12700KF with an AMD Radeon RX 6750 XT**
(PHASE4 §1.1), with the Mac Pro kept as the matrix's second row.

This supersedes the sibling project at `/home/jkane/Projects/OS/AbyssBSD` (Rust DE),
which is being **abandoned as the product** but is an invaluable source of design and
working code. That sibling already contains a complete, *software-rendered, headless*
Wayland DE in Rust (31 crates, ~27.5k LOC, 49/53 tests green): a performance-gated
compositor (`tide`), a shell (`reef`), brokerless IPC (`current`), daemon-free config
(`pool`), a hot-path ring (`shmring`), FreeBSD helpers (`vents`), a session supervisor
(`anchor`), and an image codec (`abyss-image`). Its architecture is documented in
`AbyssBSD/abyss/docs/{DESKTOP,SEAMS,STATUS,KERNEL-READINESS}.md`.

**The product is Swift.** The whole desktop — toolkit, shell, apps, *and* the engine
underneath — gets written in Swift 6; we drop to C (or C++) only where Swift genuinely
can't go. The sibling is therefore a **design source and reference implementation to
rewrite from**, not a runtime dependency to link against: read its algorithms, its
architecture docs and its protocol maps, then write the Swift. (Corrected 2026-07-27,
superseding the earlier "reuse the Rust engine for now" framing. `PoolConfig` — a Swift
rewrite of the Rust `pool`, sharing only the on-disk format — is the pattern.)

"Where Swift can't go" means an established C system library (libwayland, wlroots,
xkbcommon, cairo, FreeType/HarfBuzz, libnv) or a shim over one, exactly as `de/cwayland`
and `de/ctext` already do. It does not mean linking Rust crates.

### Where this stands (2026-09-05)

**Phases 0–3 and 5–8 are complete; Phase 4 is in flight, on the machine.** The
Jaguar desktop runs on FreeBSD on our own Swift compositor, foreign GTK apps get
the Finder through a D-Bus bridge we wrote, and a blank disk becomes a machine
running that desktop — all of it proven by `abyss/tests/run.sh --vm --live` on
both platforms, with no hardware and no human in the loop. The medium now boots
on the Mac Pro itself: its ESP is FAT16 because Apple's firmware would not read
the FAT32 one, and `hw.pci.enable_pcie_hp="0"` stops the machine burying its own
installer under a power-fault it re-logs forever.

**And then the target moved** (PHASE4 §1.1). Bring-up is now an i7-12700KF with
an RX 6750 XT — a machine already running FreeBSD 15.0-RELEASE-p12 with a MATE
desktop on it. That **retires the project's biggest risk by evidence rather than
argument**: Navi 22 needs no `si_support`, and `amdgpu` binding this card is not
a prediction. It also buys what the Mac Pro could never offer — **a positive
control**, since every layer below ours is demonstrably working, so a black
screen there means us (PHASE4 §1.2). The Mac Pro keeps its accommodations and
becomes a row of the matrix instead of the gate on a phase.

**And Phase 4 is no longer the last phase.** [PRODUCT.md](PRODUCT.md) is why:
this tree is engine and shell, its application layer is two programs, and the
five theses that decide what fills it — GUI over TUI, WIMP over tiling,
traditional window management, jailed agents, hardware breadth — are argued there
with a gap map. **That gap map is now on this roadmap as Phases 9–18**, and the
whole document has been re-ordered so that a phase never appears before something
it needs: see [The dependency order](#the-dependency-order). Note that **every
C1–C5 number in [PHASE6.md](PHASE6.md) is provisional** until P4.5 re-measures it
against a real vblank.

### Decisions locked in (from planning Q&A)

1. **Compositor: rewrite in Swift** (corrected 2026-07-27 — this used to read
   "reuse now, rewrite later"). The Aqua shell/toolkit/apps are built first, as
   Wayland *clients*, because that's the fastest path to a visible desktop and it
   works against any wlroots compositor; the compositor itself is then written in
   Swift over a wlroots C binding (the `wlsys` discipline), with Rust `tide` as the
   design reference for its `arrange()`/exclusive-zone logic and its C1–C5 frame
   contract. Until it exists, development runs on **stock sway/labwc** — on FreeBSD
   as on Linux, both being in ports. The hard part stays hard: the allocation-free
   real-time present path is where ARC is a genuine risk, and it is the one place
   we'd reach for Embedded Swift or a C shim (risk 4 below).
2. **Aqua fidelity: 10.2 is an *aesthetic* target, not a functional one.**
   Pinstripes, lickable gel buttons, traffic-light controls, the magnifying
   Dock, Apple menu, pinstriped menu bar. The 512pixels Aqua screenshot library
   is the spec — for how things *look*, not for what the system is allowed to
   *do*. The version number names a visual language we are cloning, not a
   feature set we are frozen at: capabilities 10.2 never had are in scope
   provided they are drawn in this vocabulary (PRODUCT.md §7.5).

   **Brushed metal is out, and its successors with it — Leopard's dark unified
   title bars, Lion-era skeuomorphism, the flattening from Yosemite onward —
   because they are ugly.** That is the whole reason and it needs no other.

   **And 10.2 is the *default*, not a limit compiled into the toolkit.** Nothing
   in the architecture may prevent a 90s retro-cyberpunk theme or a GPU-effects
   extravaganza. **The theme system is therefore a must-have**, and PRODUCT.md §8
   is its architecture: tokens and widget drawing as *data* (never a loadable
   dylib, which would put third-party code in every app process and contradict
   everything Phase 7 was for), compositor effects arbitrated against the C1
   frame budget rather than offered as a checkbox, and the shipped Aqua theme
   expressed in the theme format itself so the format cannot quietly be
   inadequate.

   **We ship exactly two themes, and the second one is the test.** Jaguar is the
   default and is the product; **`Trench`** — 90s skeuomorphic cyberpunk out of
   AmigaOS MUI, the SGI IRIX desktop and NeXTSTEP — exists because a theme format
   with one theme in it has no positive control (§2.37), and a format written by
   someone looking at Aqua will of course fit Aqua. See Phase 11.1. **Two themes
   is a proof; a curated pack of looks and the churn of keeping it current is a
   catalogue, and that we still refuse.**
3. **Dev platform: Linux-first, then port.** Swift 6 is first-class on Linux; build the
   toolkit + shell on this workstation against a stock wlroots compositor (sway/labwc)
   for fast iteration, then bring Swift up on FreeBSD and run the same way there.
4. **This document: full phased roadmap.** Phase 0–1 are executable detail; later phases
   are milestone sketches to be expanded when reached.

### Inheriting the sibling's standing policies (adapted to Swift)

- **Minimal third-party dependencies.** Capability = **hand FFI to a mature C system
  library** (wayland, xkbcommon, libnv, freetype, harfbuzz, cairo, libpng/jpeg, crypto)
  or vendored C. Avoid SwiftPM registry deps the way the sibling avoids crates.io.
- **Wrap a C *library*; rewrite a Rust *component*.** Don't hand-fake a capability a
  mature C lib provides — wrap it behind a clean Swift interface (the `wlsys`/`sysffi`
  discipline). The sibling's own crates are the opposite case: read them, then write
  the Swift.
- **The performance contract is the feature.** Keep `tide`'s C1–C5 benches as a
  CI gate; never let the Swift client layer regress input-to-photon.

---

## Naming (provisional, aquatic theme continues)

| Swift module / app | Role | Sibling analog |
|---|---|---|
| `CWayland` | C-interop target: libwayland-client + scanner-generated protocols | `reef/wl` C glue |
| `Surface` | Swift Wayland client runtime (registry, surfaces, shm, seat, event loop) | `reef-wl` |
| `Aqua` | The Aqua toolkit: 2D drawing, text, the 10.2 widget set + theme | `reef-wl::canvas` |
| `CurrentIPC` | Swift control plane: unix sockets, typed messages, fd-passing | `ipc/current` |
| `PoolConfig` | Swift reimpl of `pool` (mmap read / atomic-rename write / kqueue watch) | `ipc/pool` |
| `Dock`, `MenuBar`, `Finder`, `Desktop`, `LoginWindow`, `SystemPrefs` | the shell | `reef-*` |
| `Anchor` / `anchor` | session supervisor: pollable child descriptors, control service | `anchor` |
| `Vents` | hardware bridges: sysctl, OSS volume, battery, devd | `vents` |
| `undertow` | the compositor — Swift rewrite, Phase 6 ([PHASE6.md](PHASE6.md)) | `tide` |
| `Installer` | Fedora-style graphical installer (Aqua app), Phase 5 ([PHASE5.md](PHASE5.md)) | — (new) |
| `abyss-install` | the installer's privileged half: a plan in, a partitioned disk out | — (new) |
| `abyss-dbus` | the D-Bus bridge: `org.freedesktop.portal.*` for legacy apps, Phase 8 ([PHASE8.md](PHASE8.md)) | — (new) |

Names are a theme, not a contract — the architecture is what matters.

---

## The dependency order

This document is ordered so that **a phase never appears before something it
needs.** Two consequences worth saying out loud:

- **The phase *numbers* are historical and are not the order.** A number was
  assigned when a phase was first sketched, and the work did not oblige: 7 was
  carved out of 3 and built before 6, 6 was built before 8, and 5 shipped before
  4. The sections below run in dependency order and each carries its own edges.
- **Two kinds of edge, and they are not the same claim.** **Needs** is
  technical — the later phase cannot be built or verified without the earlier
  one. **Before** is economic — either order compiles, but one of them costs
  more, usually because the later phase multiplies the earlier one's call sites.
  A roadmap that blurs the two ends up defending a preference as if it were a
  constraint.

### The graph

```
built ───────────────────────────────────────────────────────────────────
  0 ─► 1 ─► 2 ─► 3 ─┬─► 7 ─┐
                    │      ├─► 8 ─► 5 ─► 4     ◄── in flight, on the machine
                    └─► 6 ─┘                │
                          │                 │
next ─────────────────────┼─────────────────┼────────────────────────────
                          │                 ├──────────────► 12  Fathom
                          │                 │
                          └─► 9  substrate ─┴──────────────► 13  Islands,
                                 │                               Shoals, Ebb
                                 ├─► 10  menus ──┐
                                 └─► 11  theme ──┴─► 14  preferences
                                                        │
                                                        ├─► 15  applications
                                                        │        └─► 17  delivery
                                                        ├─► 16  the session
                                                        └─► 18  confinement,
                                                                 then agents
```

Read an arrow as "needs". **13 needs both 9 and 4**, which is the only place two
branches rejoin; 17 needs 15 *and* 14; everything else takes its edges from the
table below.

### The whole roadmap, in one table

*Needs* is technical, ***before*** is economic; **✅** is shipped.

| # | Phase | Needs | Unblocks | Status |
|---|---|---|---|---|
| 0 | Foundations & the Swift toolchain | — | everything | ✅ 2026-07 |
| 1 | The Aqua toolkit, and the first faithful window | 0 | 2, 11 | ✅ |
| 2 | The Aqua shell + IPC, on Linux | 1 | 3, 6, 7 | ✅ |
| 3 | FreeBSD bring-up — `CurrentIPC`, `anchor`, `Vents` | 2 | 5, 6, 7, 8 | ✅ |
| 7 | Portals — the capability desktop | 3 | 8, 18 | ✅ |
| 6 | `undertow`, the Swift compositor | 2 | 4, 5, 8, 9, 13, 16 | ✅ |
| 8 | The D-Bus bridge — portals for everyone else | 6, 7 | 10's foreign half, 15 | ✅ |
| 5 | The installer — a machine with an empty disk | 6, 8 | 4, 12, 17 | ✅ |
| 4 | First metal — real graphics, input and numbers | 5 | 12, 13's C6, 16's power work | **in flight** |
| 9 | The interaction substrate | 6 | 10, 11, 13, 14, 15 | **next** |
| 10 | The menu protocol | 3, 8; *before* 15 | 15, and thesis 2 at all | |
| 11 | The theme system, layers 1–3 | 1; *before* 15 | 15, foreign-app looks, the a11y floor | |
| 12 | `Fathom` — the medium measures the machine | 4, 5 | the hardware matrix, 16's power work | |
| 13 | Islands, Shoals and Ebb — and C6 | 9, 4 | thesis 3's case against tiling | |
| 14 | Preferences that write | 9, 10, 11 | 15, 16, 17, 18 | |
| 15 | The application layer | 9, 10, 11, 14 | 17's `pkg` hook, and thesis 1 | |
| 16 | The session — login, lock, idle, power | 6, 12, 14 | a machine somebody else can use | |
| 17 | Delivery — the overlay, and `abyss update` | 5, 14, 15 | shipping to anyone who is not us | |
| 18 | Confinement, then agents | 7, 14 | thesis 4 | |

**Phases 9–12 are mutually independent** — 9, 10 and 11 need nothing from each
other, and 12 needs only 4. They are listed in that order because among
independent work the tiebreak is fan-out and cost growth: 9 unblocks five later
phases, 10 and 11 both get more expensive with every application Phase 15 adds,
and 12's dependency on Phase 4 is *perishable* — Fathom is [PHASE4 §5](PHASE4.md)
written down as a program, and it is cheapest to write while the checklist is
fresh and the machine is still on the bench.

**Where an edge is soft, it is marked *before* and not *needs*.** Phase 11 could
follow Phase 15; there are 192 `Theme.` call sites across 14 files today and
every application adds more, so it would simply cost several times as much. That
is an argument, not a blocker, and it is written as one.

---

## Phase 0 — Foundations & Swift toolchain (the critical-path spike)

**Needs:** nothing. **Unblocks:** everything.

**Goal:** a buildable Swift 6 environment on Linux *and* a credible path to Swift on
FreeBSD 15, plus the repo skeleton and borrowed dev infra.

- **Repo skeleton** under `/home/jkane/Projects/OS/AbyssBSD-swiftDE/`: a SwiftPM
  workspace (`Package.swift`) for the DE, plus a `de/` layout mirroring the sibling, and
  a `docs/` with this plan and a STATUS.md handoff doc.
- **Borrow the VM + test infra** from the sibling (copy and adapt, don't symlink):
  - `AbyssBSD/abyss/vm/{config,fetch-image,make-seed,run,ssh,sync}.sh` — FreeBSD 15.0
    qcow2 + qemu/KVM, cloud-init provisioning, rsync sync, key-only SSH on port 2222.
    **Adapt the cloud-init package list** to add the Swift toolchain + Swift's deps
    (icu, libxml2) alongside the existing `wlroots019 wayland-protocols freetype2
    harfbuzz png jpeg-turbo pkgconf`.
  - `AbyssBSD/abyss/tests/{run,run-vm,run-kyua}.sh`, `Kyuafile` — two-layer harness
    (host unit tests + in-VM ATF/Kyua). Add a Swift `swift test` lane.
  - `AbyssBSD/abyss/mk/` build-glue pattern for later FreeBSD packaging.
- **Linux dev environment:** install the swift.org Swift 6 toolchain; install
  `sway` (or `labwc`) + `wayland-protocols`, `cairo`, `freetype`, `harfbuzz`,
  `libxkbcommon` as the client-side test substrate.
- **FreeBSD Swift spike (start now, do not block Phase 1):** evaluate, in order,
  (a) `pkg`/ports Swift if a current 6.x exists, (b) **cross-compiling from Linux
  using a Swift SDK** built for FreeBSD, (c) building the toolchain from source in the
  VM. Capture findings in `docs/SWIFT-ON-FREEBSD.md`. **This was the #1 project
  risk; it closed on 2026-07-28** as (a) — ports `swift6-6.3.2` builds and tests
  the repo in the VM. Note the package is `swift6`, not `swift`.
- **Establish the Swift↔C FFI pattern:** SwiftPM `systemLibrary` targets + module maps
  + a `wayland-scanner` build step, mirroring `reef/wl/build.rs`'s scanner usage.

**Verify:** `swift build` succeeds on Linux; a trivial `swift run` that calls a C lib
through a system-library target links and runs; the FreeBSD VM boots and SSH works.

---

## Phase 1 — Aqua toolkit + first faithful window (Linux, against sway)

**Needs:** 0. **Unblocks:** 2, and Phase 11's theme system.

**Goal:** a Swift app that draws a pixel-faithful Aqua 10.2 window under a stock wlroots
compositor, HiDPI-aware. This is where "faithful clone" gets nailed.

- **`CWayland` target:** module map exposing `libwayland-client`, `libxkbcommon`, and
  `wayland-scanner`-generated C for `xdg-shell`, `wlr-layer-shell-unstable-v1`,
  `xdg-activation-v1`, `wlr-foreign-toplevel-management-unstable-v1` (the exact protocol
  set `reef` uses — see `AbyssBSD/abyss/de/reef/wl/`).
- **`Surface` module:** Swift wrappers for display connection, registry bind, `wl_surface`
  + `wl_shm` double-buffering, `wl_seat`/pointer/keyboard/touch, frame callbacks, and an
  event loop integrating the `wl_display` fd (use `epoll` on Linux / `kqueue` on FreeBSD;
  Swift concurrency actors for dispatch). Software-rendered to shm buffers, exactly like
  `reef-wl` (no GPU on the client side).
- **`Aqua` toolkit:**
  - **Drawing backend:** bind **Cairo** (FFI) for gradients, rounded rects, soft shadows,
    and the gloss/translucency Aqua needs — the "wrap a mature C lib" choice over
    hand-rolling a rasterizer. Text via **FreeType + HarfBuzz** (the sibling already
    proved this pairing in `reef/wl/font.rs`). Port the `abyss-image` codec usage
    (PNG/JPEG/SVG) or bind the same C libs.
  - **Theme tokens** distilled from the 512pixels 10.2 screenshot library: the pinstripe
    pattern, Lucida Grande metrics, gel-button gradient stops,
    title-bar geometry, traffic-light colors/positions, sheet/menu styling, selection
    blue.
  - **Widget set (initial):** the pinstriped/white Aqua window frame with
    traffic-light close/min/zoom, push buttons (gel), checkboxes/radios, text fields,
    scrollbars, menus + menu bar, sheets, progress/spinner. Built data-oriented and
    redraw-on-damage to respect the latency contract.
- **Deliverable:** `swift run AquaDemo` shows a faithful Aqua window with a few live
  controls under sway.

**Verify:** run under sway on the Linux box, screenshot, and compare side-by-side with
the 10.2 reference library; confirm crisp rendering at 1x and 2x scale.

---

## Phase 2 — The Aqua shell + IPC, on Linux

**Needs:** 1. **Unblocks:** 3, 6, 7.

**Goal:** a usable desktop shell (Swift Wayland clients) running against sway.

- **IPC/config in Swift:**
  - `CurrentIPC` — the control plane in Swift: unix sockets, typed messages, fd-passing
    via `SCM_RIGHTS`. API shape mirrors `ipc/current/lib.rs` (`Msg.set_*/get_*`, `call`,
    `Server`), rewritten rather than bound. **Deferred out of Phase 2 and decided
    2026-07-27 — see PHASE2.md P2.9:** every peer it would talk to is itself a Phase-3
    Swift deliverable, so it lands there, with base `libnv` as the fallback encoder if
    a Swift codec proves impractical. **Built 2026-07-30 (PHASE3.md P3.5):** the Swift
    codec was straightforward, so libnv is neither linked nor needed, and the component
    has no platform fork at all — it passes identically on Linux and FreeBSD.
  - `PoolConfig` — reimplement `pool` in Swift (mmap read, temp-file+fsync+atomic-rename
    write, kqueue/`EVFILT_VNODE` watch). It's ~458 LOC of pure syscalls; reading the same
    `~/.config/abyss/*.ini` files keeps Swift and Rust components config-compatible.
- **Shell components (Swift apps over `Surface`/`Aqua`):**
  - `MenuBar` — pinstriped top bar, Apple menu, app menus, clock, status items.
  - `Dock` — bottom dock with magnification, running-app indicators, trash.
  - `Desktop` — wallpaper + desktop icons (kqueue-watched), via layer-shell BACKGROUND.
  - `Finder` — spatial file manager (the `reef-fm` analog) in Aqua dress.
  - `LoginWindow` and a minimal `SystemPrefs`.
  - Notifications + a tray, reusing `shmring` for the hot path if needed.
- **Window management** uses `wlr-foreign-toplevel-management` for the Dock/menu, exactly
  as `reef-panel` does.

**Verify:** launch the shell stack against sway on Linux; click through Dock,
menus, and Finder; confirm config round-trips through `PoolConfig`.

---

## Phase 3 — FreeBSD bring-up

**Needs:** 2. **Unblocks:** 5, 6, 7, 8.

**Goal:** the Swift Aqua desktop running on FreeBSD in the VM — on a stock wlroots
compositor from ports, with its own Swift control plane, session supervisor and
hardware bridges underneath. (The Swift compositor is Phase 6; nothing here waits
on it.)

**Expanded to executable detail in [PHASE3.md](PHASE3.md)** — ordered passes
P3.1–P3.7, the portability-debt table, and the open decisions. One change of
scope from the sketch below: the **D-Bus replacement story is carved out to its
own phase** (PHASE3.md §6.1), since the sibling's portal design is
compositor-owned and Phase 6 owns the compositor. Nothing in Phase 3 depends on
it.

- Bring Swift up on FreeBSD per the Phase 0 spike; get `Surface`/`Aqua` linking against
  FreeBSD libwayland/cairo/freetype/harfbuzz.
- **Rewrite in Swift, reading the sibling as the spec:** `CurrentIPC` (control plane,
  PHASE2.md P2.9), the session supervisor (`anchor`'s job — `abyss/session.sh` is
  today's stand-in), the FreeBSD hardware bridges (`vents`: sysctl/OSS/devd, reached
  from Swift directly as `PoolConfig` reaches syscalls), and `shmring` if the hot path
  needs it. The compositor is its own later phase; until then the shell runs on stock
  sway/labwc from ports, exactly as it does on Linux.
- **The D-Bus replacement story (goal #3):** the control plane *is* the bus (brokerless,
  no broker process). Take the sibling's compositor-owned portal *design*
  (`reef-portal`/`open`/`save`/`notify` — file chooser, screenshot/cast, notifications)
  and write it in Swift. **Legacy adapter:** a
  **jailed D-Bus bridge** + XWayland for GTK/Qt apps, off the critical path, so legacy
  apps that expect a session bus / portals / MPRIS / AT-SPI still work.
- Run the whole stack headless in the VM (sway's headless backend today, ours later)
  and keep `tide`'s C1–C5 perf benches as the standing gate the Swift compositor will
  have to clear.

**Verify:** in the VM, the Swift shell comes up under the Swift session supervisor on a
headless compositor; config round-trips through `PoolConfig`; the control plane hands an
fd to a sandboxed Swift app.

---

## Phase 7 — Portals: the capability desktop

**Needs:** 3 (`CurrentIPC`, P3.5) — and nothing from 4–6, which is why it was built out of order. **Unblocks:** 8, 18.

**Goal:** goal #3 made real — the brokerless answer to xdg-desktop-portal. An app
asks the desktop to pick a file; the portal runs the Finder as the picker, opens the
chosen file itself, and hands back the **open descriptor** over `SCM_RIGHTS`. The
descriptor *is* the capability, and the demo client proves it by calling `cap_enter(2)`
first, so it has no filesystem at all. Plus notifications (an Aqua toast) and a
screenshot portal over `wlr-screencopy`.

**Numbered 7 but built out of order** — before Phases 4–6, because it depends on
nothing they provide (only on `CurrentIPC`, delivered in P3.5). Carved out of Phase 3
on 2026-07-27 and scoped in **[PHASE7.md](PHASE7.md)**.

**Not in it:** the D-Bus bridge and `org.freedesktop.portal.*`, so stock GTK/Qt apps
are not served yet; XWayland, MPRIS, AT-SPI; jail plumbing. Those remain the legacy
half of the story (PHASE7.md §1).

---

## Phase 6 — `undertow`, the Swift compositor

**Needs:** 2 (clients to composite). **Unblocks:** 4, 5, 8, 9, 13, 16.

**Goal:** the compositor in Swift, meeting `tide`'s contract rather than inheriting its
code. (Sequenced last because the shell is what makes the desktop *visible*, and it
runs on any wlroots compositor meanwhile — not because the rewrite is optional.)

**Expanded to executable detail in [PHASE6.md](PHASE6.md)** — ordered passes
P6.1–P6.7, the sibling→ours component map, and three risks spiked on both
platforms *before* the plan was written. Two corrections to the sketch below
came out of those spikes:

- **Swift imports wlroots directly** — no bindgen, unlike the sibling's `wlsys`.
  The C shim shrinks to a ~15-line listener trampoline, because `wl_listener` /
  `wl_container_of` / `wl_signal_add` are macros and inlines (HANDOFF §2.1's
  trap at scale). Verified on Linux and FreeBSD.
- **Embedded Swift is struck** (risk 4 above): plain Swift with preallocation
  measures zero allocations on the loop body, and Embedded Swift could not have
  been scoped to one thread anyway.

- Own the **scene, the frame scheduler and the present path**; let wlroots own
  DRM/KMS, GBM, libinput and the protocol grind (DESKTOP.md §2).
- Build it in the canon's order — **the contract and its meter before the
  pixels** — keeping the **headless C1–C5 benches as the gate** at every step; a
  regression fails the build, exactly as today.
- **Software-rendered and headless throughout.** Real GPU, hardware cursor,
  direct scanout, atomic page-flip and `rtprio` are Phase 4, on metal — the
  build VM has no `/dev/dri`, which is the same wall the sibling is stopped at.

---

## Phase 8 — the D-Bus bridge: portals for everyone else

**Needs:** 6, 7. **Unblocks:** Phase 10's foreign half, and the foreign applications of Phase 15.

**Goal:** delete PHASE7 §6.7's caveat — a stock GTK/Qt app gets the Finder as its
file chooser.

**✅ Complete (2026-08-23), P8.1–P8.4.** One `anchor` command boots a desktop
where an unmodified GTK 3 application opens a file through the Finder.

*"and a descriptor as its answer" was struck from that goal, not achieved.*
`FileChooser`'s `Response` carries `uris` — strings — with no descriptor in any
version, so the capability stops at the bridge and a foreign app opens the file
by name with the authority it already had. Their answer is a name; ours is a
capability. PHASE8 §6.6 has the full reckoning, and it is why flatpak needs a
FUSE daemon to make those names mean anything.

**Expanded to executable detail in [PHASE8.md](PHASE8.md)** — passes P8.1–P8.4,
and two risks spiked on both platforms before the plan was written.

- **We are the portal**, owning `org.freedesktop.portal.Desktop` and translating
  to the existing `abyss-portal` over `CurrentIPC` (decided 2026-08-07 over
  backing stock `xdg-desktop-portal`, which would put a broker on the path and
  leave two portal frontends with different behaviour).
- **D-Bus is spoken natively from Swift** — no libdbus (discouraged upstream), no
  GDBus (drags in the GLib/GTK stack this project rejects), no sd-bus (systemd).
  The spike connects, authenticates and calls `Hello` on both platforms in ~110
  lines, which is the same answer `CurrentIPC` reached for its own wire format.
- `dbus-daemon` from ports **is** the session bus. This phase adds a broker, and
  says so: nothing on the frame path talks to it, and if it dies the desktop does
  not notice. PLAN.md always called it a legacy adapter.

---

## Phase 5 — Fedora/Anaconda-style installer

**Needs:** 6, 8. **Unblocks:** 4, 12, 17.

**Goal:** a guided graphical installer matching goal #5 — a machine with an empty disk
boots our medium, someone clicks through an Aqua installer, and it reboots into the
Jaguar desktop.

**✅ Complete (2026-08-24), P5.1–P5.5.** The whole arc runs in the harness, nested
twice over: an empty disk, our medium, the Aqua installer on it, an install, and a
reboot into the Jaguar desktop as the account that was created. *The clicking is
proven separately* — `live-installer.sh` drives the real app with a real pointer
and keyboard against the real service; the end-to-end run installs from the
medium's console, because driving a GUI inside the nested machine would mean
putting the harness's input tools into the product image. **Input from real
hardware is untested, and belongs to Phase 4.**

**Expanded to executable detail in [PHASE5.md](PHASE5.md)** — passes P5.1–P5.5, and
four risks spiked on the target before the plan was written. Two corrections to the
sketch below came out of those spikes:

- **We do not drive `bsdinstall`** (corrected 2026-08-24 — this used to read "the GUI
  drives the proven `bsdinstall` logic"). Its components are shell scripts wrapped
  around `bsddialog`; `zfsboot` is a dialog program with an install inside it, and
  driving a dialog from a GUI is a worse job than doing the install. The spike wrote
  the GPT, the ESP, the pool and the extraction directly with `gpart`/`zpool`/`tar` —
  every tool in base, no dialog anywhere — and **the result boots**.
- **The GUI does not touch the disk.** An unprivileged `Installer` sends a plan to a
  root `abyss-install` over `CurrentIPC` and gets progress back — `abyss-portal`'s
  shape. That split is what lets the harness test the dangerous half with no GUI in it,
  and lets the GUI half develop on Linux where `gpart` does not exist.

- A **live environment** boots straight into a minimal Aqua desktop running the
  `Installer` Swift app (Aqua toolkit), with an Anaconda-style hub-and-spoke flow:
  welcome → language/keyboard → disk & partitioning (ZFS-on-root default, via `gpart`/
  `zpool`) → timezone/network → user account → summary → install → reboot. Built with
  `makefs` + `mkimg` from the same dist sets the installer extracts — no `make
  release`, no source tree, no world build.
- **Offline is a requirement, not a preference:** risk 5 below is Broadcom Wi-Fi on the
  machine this project targets, so an installer that needs a network is one that does
  not work on a Mac Pro 6,1 out of the box. The medium carries what it installs.

**Verify:** clean install onto the VM end-to-end from the live image, booting into the
Aqua desktop — proven by the harness, with **nested bhyve** booting what was installed
and waiting for the wallpaper, menu bar and Dock. **The Mac Pro half of this belongs
to Phase 4**, since installing onto that machine first requires it to boot FreeBSD
with a working GPU.

---

## Phase 4 — first metal: real graphics, real input, real numbers

**Needs:** 5 — the installer is not a convenience here, it is the delivery mechanism. **Unblocks:** 12, Phase 13's C6, and Phase 16's power work.

**Goal:** real graphics and real hardware — what a GPU present path needs (the
sibling hit the same wall: `DESKTOP.md` phase 2 was its one true blocker).

**Expanded to executable detail in [PHASE4.md](PHASE4.md)** — passes P4.1–P4.6.
**The first phase whose verification needs a machine that is not in the test
loop** — and, since [PRODUCT.md](PRODUCT.md), no longer the last phase either.
Its deliverable is split: code provable here, plus a **bring-up checklist**
(PHASE4 §5) worked through on the machine, and Phase 12 is that checklist turned
into a program so it runs on machines we do not own. The route onto
that machine is the Phase 5 installer — which is why the medium, not the
compositor, is what P4.3 has to make ready.

Two corrections to the sketch below already:

- **`undertow` chooses its backend** (P4.1, done): `wlr_backend_autocreate`
  behind `--backend auto`. Headless stays the default — it is the only thing the
  build VM can do, and the only thing that makes C1–C5 reproducible.
- **Every C1–C5 number in PHASE6.md is provisional.** They were measured against
  a synthetic clock in which a frame presents the instant it is committed;
  `WLR_OUTPUT_PRESENT_HW_CLOCK` has never once been set in this project's
  history. P4.5 re-measures them where the vblank is real.

- **Boot:** FreeBSD 15 UEFI, ZFS-on-root. Ordinary AMI UEFI on the primary
  target; Apple EFI's quirks are P4.0's and stay written down for the Mac Pro row.
- **GPU (primary):** **AMD Radeon RX 6750 XT** — Navi 22, RDNA 2, claimed by
  `amdgpu` with **no tunable at all**. Then the GPU phase proper: DRM/KMS via
  `seatd`, hardware cursor, atomic page-flip, real vblank, dmabuf +
  explicit-sync, direct scanout. **`allow.rtprio`** custom-kernel jail param
  (already built in the sibling) grants the present thread bounded RT.
- **GPU (secondary):** dual **AMD FirePro D300/D500/D700** = GCN 1.0 / Southern
  Islands → `amdgpu` with **`si_support`** (or `radeonkms`), and multi-GPU
  handling. Unproven, and now a matrix cell rather than a blocker (PHASE4 §6.2).
- **Peripherals:** audio, and `igc0` — Intel 2.5 GbE that already has a DHCP
  address. Apple NVMe and Thunderbolt 2 leave with the Mac Pro; Broadcom Wi-Fi
  leaves this phase's critical path with it.

**Verify:** the compositor drives a real display at its own refresh rate — 2560x1440
at 60 Hz, so a 16.67 ms budget and scale 1; the
flight recorder shows zero missed flips under load; the Aqua desktop is interactive on
metal. **Note what does not count:** a nested compositor presents when its *host*
does, so a miss count measured there is measured against somebody else's clock
(HANDOFF §2.48). Nested is for input and drawing; C1 is for DRM.

---

## Phase 9 — the interaction substrate

**Needs:** 6. **Unblocks:** 10, 11, 13, 14, 15 — everything below it.

**Expanded to executable detail in [PHASE9.md](PHASE9.md)** — passes P9.1–P9.7,
and four risks spiked on both platforms before the plan was written. One of them
changed the phase's shape and corrects this document's source: **the clipboard is
not missing for our applications, it is broken for everyone.** `undertow` creates
`wlr_data_device_manager` but never answers `request_set_selection`, which
wlroots requires a compositor to do, so a copy is discarded whoever makes it —
including the foreign GTK applications Phase 8 exists to serve. The server fix is
four lines and it comes first.

**Goal:** the desktop stops making claims it cannot keep. Six small pieces, none
of them research, that together are the difference between a demo and a desktop
([PRODUCT.md](PRODUCT.md) §4.2–§4.3).

- **Copy and paste.** `undertow` creates `wlr_data_device_manager`, so *foreign*
  applications can already copy to each other; **`Surface` has no client-side
  data device at all**, so no Aqua application in this tree can copy or paste.
  That is a defect rather than a missing feature, and it is first because every
  application in Phase 15 assumes it.
- **Drag and drop** — the same protocol: a file onto the Trash, into a Finder
  window, onto a Dock tile.
- **A global keybind table** in `undertow`, which has none at all. Cmd-Tab,
  Cmd-Q/W, Cmd-Space, Cmd-Shift-3/4, volume and brightness — compositor-level and
  config-driven through `PoolConfig`. **Phase 13 cannot ship without it:** an
  island switcher with no keyboard route is a toy.
- **The window requests we ignore.** `request_resize` is unhandled, and
  `set_maximized` / `set_minimized` / `set_fullscreen` have no handlers. Resize
  edges on the Aqua frame; minimize wants the Dock's genie. Plus **drag-to-edge
  snapping**, the one tiling affordance worth offering (§10).
- **Server-side decorations** (`xdg-decoration`) with `Aqua` painting the frame.
  The highest visual payoff in the gap map: a GTK headerbar on a Jaguar desktop
  looks broken in a way no missing feature does.
- **Decide XWayland, and write the reason down** (PRODUCT.md §5.2). The browser
  does not force it — both GTK stacks are Wayland-native and Chromium's port
  depends on `wayland` outright — but the long tail of ports is what thesis 5
  promises. **Cost is measured and is not the argument:** wlroots is built with
  `WLR_HAS_XWAYLAND` on both platforms, `Xwayland` is in ports, and the medium
  grows by ≈6 MiB net of what `undertow`'s own closure already carries
  (PHASE9 §4.4). Decide it the way the D-Bus bridge was decided: take it or
  refuse it, scope it, and say so.

**Verify:** live modes — copy in the Finder, paste in a text field; drag a file
to the Trash; a keybind fires with no application focused; a window resized by
its edge; a stock GTK application wearing an Aqua frame.

---

## Phase 10 — the menu protocol

**Needs:** 3 (`CurrentIPC`), 8 (`abyss-dbus`). ***Before*** **15** — every
application built without it has to be retrofitted.

**Goal:** the menu bar stops being a picture of a menu bar. `Aqua.MenuBar` draws
File/Edit/View for nobody; no application publishes a menu to it. In Jaguar the
global menu bar *is* the WIMP contract — every command discoverable in one place,
with a mouse, without memorising anything — so **thesis 2 is undelivered until
menus travel from applications to the bar** (PRODUCT.md §4.2).

Both halves, because the foreign half is already ours to write:

- **Ours** — a `CurrentIPC` channel publishing a menu tree, the bar routing
  activation back to the owning application. Keyboard equivalents come from
  Phase 9's table, so a command has one definition and two routes.
- **Theirs** — GTK exports `org.gtk.Menus`/`org.gtk.Actions` and Qt/KDE use
  `com.canonical.dbusmenu`; **`abyss-dbus` is exactly where that translation
  belongs.** A foreign application's menus in our own bar is a claim almost no
  Wayland desktop makes.
- **The Apple menu carries real actions**, and contextual menus reach the
  desktop, the Finder and Dock tiles — today only the Trash has one.
- **Decide undo before there are applications to retrofit.** It is a
  toolkit-level concern, and deciding it after the application layer exists is
  how it ends up never decided.

**Verify:** the Finder's own menus in the bar, driven live by pointer and by
keyboard; `gtkpick`'s menus in the bar through the bridge, with the other end
never ours (§2.39's discipline).

---

## Phase 11 — the theme system, layers 1–3

**Needs:** 1. ***Before*** **15** — and that timing is the whole argument for
where this sits.

**Goal:** ship an opinion without compiling it in. Decision 2 above and
[PRODUCT.md §8](PRODUCT.md) are the architecture; what makes this a phase rather
than a preference is arithmetic. **There are 192 `Theme.` call sites across 14
files today**, and every application in Phase 15 adds more. Doing this at 192 is
several times cheaper than doing it at six hundred.

- **Layer 1 — tokens.** `Theme`'s 141 lines of `public static let` become an
  instance loaded through `PoolConfig`, reached through an ambient current theme
  rather than a parameter threaded through every call.
- **Layer 2 — widget drawing.** `Draw` is already a theme engine with exactly one
  implementation compiled into it, and its primitives are the whole of Aqua. They
  become interpreters of a **declarative draw description** — filled and stroked
  rounded rects, gradients, 9-slice images, text runs, insets and offsets,
  parameterised by tokens and by widget state. **Never a dylib per theme:** that
  would load third-party code into every application process, in the tree that
  wrote Phase 7 to prevent exactly that. A theme that genuinely needs code is a
  *port*, trusted like any other package.
- **Layer 3 — chrome and metrics**, in the same format.
- **The check that keeps the format honest: the shipped Aqua theme is itself
  expressed in the theme format.** If Jaguar needs a back door no other theme can
  use, the format is wrong and we find out immediately rather than later.
  `AquaDemo` already renders scenes to PNG, so the regression gate is a
  golden-image diff — pixel fidelity as a test rather than a hope.
- **A legibility floor**, checked at load and refused with a reason: minimum
  contrast, minimum hit-target size. We have no accessibility story at all, and
  this is the cheapest down payment on one. A theme changes how things look; it
  may not change whether they are reachable.
- **The generated GTK/Qt theme** falls out of the same tokens and is emitted
  through `PortalSettings`, which today reports one key (`color-scheme`). It
  deletes work we would otherwise do by hand, and it is what makes the foreign
  applications of Phase 15 — the browser above all — tolerable to look at.

### 11.1 `Trench` — the second theme, because one theme proves nothing

**A theme format with exactly one theme in it is §2.37's probe with no positive
control.** Re-expressing Aqua in the format cannot fail in the way that matters:
the format was written by someone looking at Aqua, so of course it fits. The test
is a theme that shares none of Aqua's assumptions and still comes out of the same
interpreter.

So we ship a second one — **`Trench`**, a 90s skeuomorphic cyberpunk theme drawn
from **AmigaOS MUI**, the **SGI IRIX Interactive Desktop**, and **NeXTSTEP**.
Those three are chosen because each breaks a *different* Aqua assumption:

| Source | What it contributes | The assumption it breaks |
|---|---|---|
| **AmigaOS / MUI** | hard bevelled chrome, chunky 3D frames, configurable-to-a-fault widget geometry | that a control is a rounded rect with a gradient — MUI's are bevels and 9-slices, and layer 2 has to express both |
| **SGI IRIX / Motif** | the industrial look: deep insets, schemes-driven colour, the "engineering workstation" register | that a theme is a *palette* — IRIX schemes change geometry and shading together |
| **NeXTSTEP** | the dark, heavy, monochrome-with-one-accent register; scroll knobs and title bars that are nothing like Aqua's | that title-bar and control *layout* is fixed — this is what makes layer 3 real rather than decorative |

**Jaguar stays the default and is what we ship as the product**; `Trench` is the
proof the engine is an engine. It is not a catalogue and does not become one
(§10) — **two themes is the test; a pack of looks and the churn of keeping it
current is what we refuse.** The name is from the same water column as everything
else here (runner-up: *Hadal*).

**Layer 4 — compositor effects — is not in this phase.** Effects are declared
with a cost and arbitrated against the C1 budget rather than offered as a
checkbox, and that arbitration is meaningless until P4.5 has measured C1 against
a real vblank.

**Verify:** a golden-image diff proving the re-expressed Aqua is pixel-identical
to today's; `Trench` rendering the same `AquaDemo` scenes with no code path of
its own; a theme that fails the legibility floor refused with a reason a person
can read; and a bench, because interpreting a draw list costs more than
straight-line cairo (risk 7).

---

## Phase 12 — `Fathom`: the medium measures the machine

**Needs:** 4 — a person has to work the checklist before it can be encoded — and
5. **Unblocks:** the hardware support matrix, and every hardware pass after it.

**Goal:** Phase 4's second half. [PHASE4 §5](PHASE4.md) is a six-step ordered
checklist where each step's failure is a different problem, and it exists because
a person works down it by hand on the one machine we own. **`Fathom` is that
checklist as a program**, which is what lets it run on the machines we do not own
(PRODUCT.md §6.4). Today the medium is a delivery mechanism; a live medium's
first job is to answer "will this work here?" before anyone commits an NVMe.

- **Probes** for the boot path, bound modules, GPU and mode, input, disks,
  network, audio, power and machine identity. Most are pure functions over
  command output — `Probe.swift`'s pattern — and testable with no hardware; the
  disk half is `DiskInventory`, built and tested already.
- **The differentiator is measurement, not detection.** Every live CD can say the
  GPU bound. Ours has a metronome and a flight recorder, so it can run C1 against
  the real vblank for a few seconds and report that this machine holds the frame
  contract — or misses by how much. No other installer tells you your frame
  budget before you install.
- **Two fidelities, by the same rule P4.3 already uses**: an Aqua window where
  there is a display, a text report on the console where there is not. A report
  that cannot survive the failure it reports is not a report.
- **It gates the install.** As a spoke in P5.4's hub it can refuse in the
  attention styling before Install is reachable — no GPU, no installable disk, no
  network device.
- **Its output populates the hardware matrix.** We cannot buy every machine, so
  the medium is the instrument, and a report a user saves to the stick and sends
  back turns everyone who tries AbyssBSD into a data point. **The matrix is a
  deliverable, not a side effect.**

**The trap this phase is built against (§2.37): a probe with no positive control
measures nothing.** A `Fathom` reporting "GPU: ok" on a machine with no GPU is
worse than no `Fathom`, because it converts an obvious failure into a confident
lie. Every probe's negative case gets exercised — and the build VM, with no
`/dev/dri`, no battery and no AMD GPU, is an excellent place to prove the checks
can fail.

**Verify:** every probe's failing case in the build VM; the console fidelity with
no display at all; and a saved report from the Mac Pro as the matrix's first row.

---

## Phase 13 — Islands, Shoals and Ebb

**Needs:** 9 (the keybind table — the honest blocker), 4 (C6 is meaningless
against a synthetic clock). **Unblocks:** thesis 3's case against tiling.

**Goal:** workspaces (**Islands**), explicit window sets (**Shoals**) and an
Exposé equivalent (**Ebb**) — the three things that make traditional window
management *beat* tiling rather than merely differ from it. A tiler answers "many
windows, none lost" and "separate task contexts" with automatic layout, which is
a bad answer to the first and an accidental one to the second; these three answer
both directly and **none of them ever moves a window you placed**. [PRODUCT.md
§7](PRODUCT.md) is the full argument and the naming.

- **Cheaper than it looks, for a reason already paid for.** `undertow` does not
  use `wlr_scene`; its own structure-of-arrays scene was built that way so C1 and
  C2 were affordable. An island is a tag on `Toplevel` and a predicate in the
  latch — no new data structure, and stacking order is already paint order.
  **`SurfaceScene.render` already builds a `dst_box` with arbitrary width and
  height, so window thumbnails are already implemented**: Ebb and the Shoals
  strip need no new rendering path. A slide is an x-offset added during the
  latch. The one genuine addition is an alpha array.
- **A sixth contract number**, because the objection to Spaces and Mission
  Control is not the model — it is that a switch is an animation you cannot
  outrun, interrupt or re-target. That is a latency bug wearing a design's
  clothes, and it is the class of bug this project is equipped to refuse:

  > **C6 — an island switch is committed within 2 frames of the input that asked
  > for it, and any animation is decoration that can be skipped, interrupted and
  > re-targeted without delaying the commit.**

  Commit first, animate second; never gate input on an animation; animation
  budgeted at ~150 ms and skippable; `undertow bench-islands` joins the C5 gating
  lane.
- **Frame callbacks follow visibility, not mapping.** `Compositor.sendFrameDone`
  walks every *mapped* toplevel today, so windows on an island nobody can see
  would keep drawing. The rule wants a test, because getting it wrong is
  invisible until something is slow.
- **The Dock is the fourth member of the set.** Click an application running on
  island 3 and you go there. That is the property that beats tiling: a window is
  never lost, because something on screen always knows where it is.

**Verify:** `bench-islands` in the gating lane, C6 measured on the Mac Pro under
load; an Ebb drawn over the eleven adversary clients C2 already survives.

---

## Phase 14 — preferences that write

**Needs:** 9, 10, 11. **Unblocks:** 15 (a browser wants a network), 16, 17
(updates want a network), 18 (agents want a network and a credential store).

**Goal:** System Preferences stops being a painting.
`Aqua.paintSystemPreferences` is backed by nothing, and **thesis 5's core claim
is that `rc.conf` is not a user interface** (PRODUCT.md §4.5).

- **Network first**, because more depends on it than on anything else in this
  document: `ifconfig`, `wpa_supplicant`, `dhclient`, and `rc.conf` written for
  you. It is also FreeBSD's weak spot and thesis 5's hardest promise — see risk 5.
- **Sound** — output device choice and per-application levels over `sndstat`/OSS.
  `Vents.Volume` is master get/set and nothing else, and the menu bar's volume
  item has reported "no mixer" since P3.7.
- **Displays** — `wlr-output-management` and an arrangement UI. Outputs are
  tracked today and never arranged.
- **Energy** — the pane Phase 16's suspend work writes into.
- **The privileged half is `abyss-install`'s exact shape, built and shipped
  once**: an unprivileged pane sends a plan over `CurrentIPC` to a root helper
  that owns the writing, and the dangerous half is testable with no GUI in it.
  Nothing here re-invents that split.
- **Somewhere the machine says what failed.** `SessionPlan.notes` is the right
  instinct with no surface, and §2.45 generalises: a graceful degradation nobody
  can see is a lie.

**Verify:** a pane writes `rc.conf`, the machine reboots, the setting held; each
pane driven live the way `live-installer.sh` drives the installer, clicking the
app's own published layout rather than constants (§2.46).

---

## Phase 15 — the application layer

**Needs:** 9 (clipboard), 10 (menus), 11 (theme), 14 (network). **Unblocks:**
17's `pkg` hook, and thesis 1.

**Goal:** the answer to "how do I do X", for the set of X a person actually has.
Omarchy enumerated that set and we did not have to invent the shopping list
(PRODUCT.md §4.1); what makes this a phase rather than a pile is that everything
above it has to exist first, or every application pays the retrofit.

- **`.desktop` → `.app` first — the best ratio of payoff to lines in the gap
  map.** The Finder already reads `.app` bundles, including PNGs extracted from
  an `.icns` (P2.11), and ports install `.desktop` entries and icons under
  `/usr/local/share`. A generator that walks them and writes bundles into
  `/Applications` gives us, for a few hundred lines: every installed port as a
  Mac-shaped application, Dock tiles with real icons and names, something for
  Recent Items to contain, and **web applications as first-class citizens for
  free** — a browser's `--app=` is just another generated bundle.
- **The browser is adopted, not written** (PRODUCT.md §5.1, §10). Epiphany is the
  recommendation — GTK4, so Phase 11's generated theme reaches it; it speaks
  xdg-desktop-portal by default, the path P8.4 proved; and `--application-mode`
  with a `.desktop` file is exactly the generator's input. **Firefox ESR is the
  answer instead if WebKitGTK's port is still at 2.46.6 when this comes due** —
  see risk 6. Nothing here has been shown to render a page under `undertow`,
  which is the test that matters and which `abyss/tests/live-gtk.sh` is the
  pattern for.
- **Terminal** — `openpty`, a VT parser, Aqua chrome, scrollback, selection.
  There is no pty code in the tree. It is not a TUI: it is the escape hatch that
  lets us ship a GUI without having shipped every GUI yet, which is why it makes
  every remaining gap survivable.
- **TextEdit, Grab, Activity Monitor, Disk Utility** — the thing that opens a
  `.txt` without a terminal; a selection rectangle, a window picker and a save
  sheet over the `abyssgrab` we already have; `kvm`/sysctl; and mount, format and
  ZFS snapshots over the `DiskInventory` the installer already carries.
- **Deferred with a reason rather than omitted:** printing (CUPS is in ports, but
  a print sheet is a toolkit feature we lack), Bluetooth (FreeBSD's stack is
  thin — scoping it out honestly is a valid answer, silently omitting it is not),
  and a git client (a developer tool, not a desktop capability).

**Verify:** each application driven live and clicked by the harness, asserting on
the thing rather than on the run (§2.43, §2.46).

---

## Phase 16 — the session: login, lock, idle, power

**Needs:** 6, 12, 14. **Unblocks:** a machine somebody else can use.

**Goal:** `LoginWindow` was named in this document's Phase 2 list and never
built; there is no `ext-session-lock`, no idle notifier and no suspend. PHASE4
§6.5 already noticed it starting to matter on a real machine.

- **Login window and multi-user sessions**, with `anchor` per user.
- **Screen lock** over `ext-session-lock` and **idle blanking** over the
  idle-notify protocol — both compositor work, which is why this waits on nothing
  but Phase 14 once the compositor is ours.
- **Suspend, lid and power.** A laptop that does not sleep is not a desktop that
  just works — and Phase 12 is what tells us which machines sleep, which is why
  it comes first.
- **First run.** Jaguar had a Setup Assistant; we boot into a bare desktop. The
  installer's hub-and-spoke (P5.4) is the shape to reuse.

**Verify:** lock and unlock live; a suspend/resume cycle on the Mac Pro; two
users, two sessions, one machine.

---

## Phase 17 — delivery: the overlay, and `abyss update`

**Needs:** 5, 14 (a network), 15 (something to hook). **Unblocks:** shipping to
anyone who is not us.

**Goal:** the desktop and its configuration update as one thing, safely.
[PRODUCT.md §6.2–§6.3](PRODUCT.md) settle both halves, and they compose: tracking
a rolling upstream means an update can break the desktop through no change of
ours, and boot environments are what make that survivable.

- **Packages: FreeBSD's repositories with an Abyss overlay**, and we do not
  become a distribution until we choose to. FreeBSD's repos give thesis 5 its
  breadth for nothing — tens of thousands of ports, a security-advisory pipeline,
  and mirrors we do not run. **The overlay carries what we wrote** — the desktop,
  the generated GTK/Qt theme, the `.desktop` → `.app` generator and its `pkg`
  hook, `Fathom` — **plus the minimum patched upstream needed to make what we
  wrote work, and nothing else.** Every rebuilt upstream port is a maintenance
  obligation that does not end. Cost: a poudriere builder, a signing key, and
  somewhere to host — real, bounded, and not the cost of owning a base system.
- **`abyss update` is a boot environment.** We already install to
  `zroot/ROOT/default` and set `bootfs` (`de/install/Steps.swift`), so **boot
  environments work on every machine we install**, and `bectl` is in base: clone
  the BE, update into the clone, activate, reboot — and if it does not come up,
  the previous environment is still in the loader menu. **Migrations belong
  here**, because an opinionated OS that changes its own defaults after release
  needs them atomic and reversible in a way a rolling config merge cannot be.
- **Software Update** is a sheet, a progress bar and a Restart button; its
  privileged half is `abyss-install`'s shape for the third time.
- **Install Software** over `pkg(8)`, same split. The *medium* still carries no
  package database at all — P5.3, unchanged and correct.
- **Run the bundle generator as a `pkg` post-install hook** and the desktop stays
  current by itself.

**Verify:** an update applied to a clone in the harness, activated and rebooted
into; and a deliberately broken update rolled back, with the machine still
booting the environment it had.

---

## Phase 18 — confinement, then agents

**Needs:** 7 (the portal is the model), 14 (a network and a credential store).
**Unblocks:** thesis 4.

**Goal:** the project's strongest position, and zero code toward it today.
Everyone else's agent story is a CLI running as you, with your credentials, over
your whole home directory. **We built the alternative and proved it**:
`abyss-portal` hands out **descriptors, not paths**, and PHASE7's demo client
calls `cap_enter(2)` first, so it has no filesystem at all. An agent whose only
reach into your data is a descriptor a human granted by clicking a file in the
Finder is a claim nobody else can make.

- **Jails first, and they are not only for agents.** Nothing in `de/` calls
  `jail(2)`; `Anchor` supervises processes, it does not confine them. This needs
  jail lifecycle, a filesystem story (a private ZFS dataset per jail is cheap —
  we already install ZFS) and `vnet` where there is network. **A `pkg`-installed
  GTK application runs today with the user's full authority** (PRODUCT.md §5.4),
  so this half earns its keep before any agent exists — which is the argument for
  pulling it forward if Phase 15's foreign applications become load-bearing.
- **The grant UI**, which is where thesis 2 applies to thesis 4: the portal
  refuses, and it has no human in the loop. "This agent wants to read
  `~/Documents/foo.txt`" — Allow / Deny / Always, a revocable list, an audit log.
  A sheet and a Preferences pane, which is why this needs 10, 11 and 14 to have
  happened.
- **Where the model runs is a constraint, not a preference.** GCN 1.0 on FreeBSD
  means **no local GPU inference** — no ROCm, no CUDA. So a small CPU model or a
  remote API, and a remote API is precisely why this needs Phase 14's network
  pane and a credential store we do not have.
- **The agent application** is a chat window: WIMP-native, and it needs nothing
  from Phase 15.

**Verify:** an agent in a jail with its own `vnet` and exactly one descriptor;
the audit log showing what it was granted; and a revocation that takes effect.

---

## What is deliberately not on this roadmap

[PRODUCT.md §10](PRODUCT.md) is the list and the reasons, in short:

- **Tiling as a layout policy.** Phase 9's drag-to-edge snapping is the one
  affordance worth offering, and Phase 13 is why that is not a concession.
- **A theme *catalogue*.** The theme *system* is a must-have and Phase 11 ships
  two themes so the format is proven rather than asserted — but curating a pack
  of looks and the churn of keeping it current is not a thing we do.
- **A browser engine.** Phase 15 adopts one; §5.1 says which and why the choice
  is an engine rather than a chrome.
- **An IDE, a git client, an office suite.** Ports has them; our job is making
  them look and behave like they belong, which is Phases 11 and 15.
- **A TUI for anything.** The terminal is the one exception, and it is not a TUI.

---

## Cross-cutting: what we borrow vs. build

- **Borrow as *design*, not as code:** the algorithms and architecture of `tide`,
  `current`, `pool`, `shmring`, `vents`, `anchor` and `abyss-image` — read them, then
  write the Swift. What we do copy verbatim is the non-product scaffolding: the VM +
  test harness (`abyss/vm`, `abyss/tests`), the protocol XML set, the `allow.rtprio`
  kernel patch, and the SEAMS porting map. Where a *format* must match (the `pool`
  `.ini` files, a protocol on the wire), match the format — not the implementation.
- **Build in Swift:** everything else. `CWayland`, `Surface`, `Aqua`, `PoolConfig`,
  `CurrentIPC`, the session supervisor (`anchor`), the compositor (`undertow`), the
  D-Bus bridge, the `Vents` hardware bridges and the installer all exist. The image
  codec is the last thing on this list still to come.
- **Drop to C only where Swift can't reach:** shims over C system libraries (the
  `aw_*`/`at_*` pattern), and — if measurement demands it — the compositor's
  real-time present path.

## Top risks (track explicitly)

1. ~~**Swift on FreeBSD**~~ — **CLOSED 2026-07-28 (P3.2).** FreeBSD is still not
   an official swift.org target, but ports carries `swift6-6.3.2` (newer than our
   Linux 6.3.1), and it builds this repo and passes all 62 tests in the VM at a
   cost of one `Package.swift` change. See docs/SWIFT-ON-FREEBSD.md. The residual
   risk is ordinary: a ports toolchain can go stale, and the cross-SDK route
   stays documented as the fallback.
2. ~~**Mac Pro GCN 1.0 GPU**~~ — **DOWNGRADED 2026-09-05 by retarget, not by
   argument.** It was the biggest risk in the project and the only one that could
   end a phase. Bring-up moved to an RX 6750 XT (Navi 22, RDNA 2), which `amdgpu`
   claims with no tunable — on a machine already running FreeBSD 15.0 with a
   desktop on it, so this is evidence rather than a prediction (PHASE4 §4.2).
   **What survives is a matrix cell, not a gate:** whether `si_support` binds GCN
   1.0 is still unanswered, still only answerable by the Mac Pro, and now costs
   one empty row instead of a stalled project. `drm-{61,66}-kmod` are built for
   the FreeBSD 15 kernel ABI and all five Southern Islands firmware packages are
   in ports, so the medium still carries them.

   **The replacement risk is smaller and real: one machine's numbers are not a
   contract.** 20 threads at 5 GHz driving 60 Hz is a generous place to hold C1,
   and a second, slower row is required before P4.5's numbers replace PHASE6's
   (PHASE4 §6.7). Multi-GPU also goes untested — the 12700K**F** has no iGPU, so
   `undertow` will never have run on a machine with two (PHASE4 §6.3).
3. **Aqua fidelity in software rendering** — gloss/blur/pinstripe at HiDPI via Cairo.
4. **Swift ARC vs. the latency contract** — **downgraded 2026-08-02 by
   measurement** (PHASE6.md §4.2), not closed. A structure-of-arrays loop body
   over `UnsafeMutableBufferPointer`, run 10 000× over 2048 surfaces under a
   `malloc` interposer, made **zero allocations** with a **15 µs worst frame
   against the 2 ms C1 budget**. So **preallocation alone suffices**: of the
   three mitigations named here, only the cheapest is needed. **Embedded Swift
   is struck** — it is a whole-module (`-wmo`) language *subset* for bare metal
   and cannot be scoped to one thread of a process that links wlroots, so it was
   never available for this job. The residual risk is that a spike is not the
   loop: the real present path also touches wlroots and the triple buffer, and
   ARC hides in innocuous captures. Hence an in-tree allocation counter that
   runs as a **test** every build, with `tide`'s C1–C5 benches as the gate.
5. **Broadcom Wi-Fi** on FreeBSD — **off Phase 4's critical path since the
   retarget**, because the new target has working Intel 2.5 GbE (`igc0`). It
   stops being a Phase 4 footnote and becomes thesis 5's hardest promise at
   Phase 14, where a Network pane has to have something to configure — and at
   Phase 12, where `Fathom` has to report honestly on a machine whose wifi is
   not recognised.
6. **A stale browser engine** — Phase 15's default, and the first real test of
   §6.3's "overlay, not a fork" discipline. Verified against the build VM's own
   FreeBSD 15.0 repo: `gtk4` is 4.20.4 and `mesa-dri` 26.1.3, but `webkit2-gtk_*`
   is at **2.46.6** and `epiphany` at 47.7 — the toolkit is current and the engine
   is about two years behind. **A lagging browser engine is a security liability,
   and for a system promising "it just works" that outweighs chrome fidelity.**
   Re-check the port's cadence before committing; if it has not improved, the
   default is **Firefox ESR**, an independent engine with a real security-support
   model. Rebuilding WebKit ourselves is the move that would make us own WebKit's
   security response, which is exactly the line §6.3 refuses to cross casually.
7. **The theme system's fidelity and its cost** — Phase 11. A tokenised,
   interpreted Aqua must stay pixel-identical, and the golden-image gate is the
   only reason it is safe to attempt at all; `Trench` (§11.1) is the other half of
   that gate, since a format with one theme in it has no positive control.
   Interpreting a draw list also costs more than straight-line cairo — the toolkit
   is not on C1's path but is on input-to-photon, so bench it. And this kind of
   system grows a scripting language if nobody stops it: layer 1 first and ship
   it, layer 2 second, layer 4 not until P4.5.
8. **The overlay is an ongoing obligation, not a one-off** — Phase 17. A
   poudriere builder, a signing key and a mirror have to keep working, and
   security updates have to keep flowing, from the day the first person who is
   not us installs this. That is the point where the project stops being a tree
   and starts being something people depend on, and it should be entered
   deliberately rather than drifted into.

## Overall verification strategy

- **Phases 1–2 (Linux):** `swift build`/`swift test`; run clients under sway; visual diff
  against the 10.2 screenshot library; screenshots in PR descriptions.
- **Phases 3+ (FreeBSD):** adapted `abyss/tests/run.sh` in the qemu/KVM VM — host
  `swift test` + in-VM ATF/Kyua, including `tide`'s headless C1–C5 perf gate.
- **Phase 4+ (metal):** on-device bring-up checklist + flight-recorder missed-flip == 0.
- **Phases 9–11, 13–15, 18 (the desktop):** unchanged — `abyss/tests/run.sh
  --vm --live` on both platforms, with every new surface driven live and clicked
  by the harness, asserting on the thing rather than on the run (§2.43, §2.46).
  Phase 13 adds **C6** to the gating bench lane, and Phase 11 adds a
  **golden-image diff** so Aqua's pixels are a test rather than an argument.
- **Phases 12, 16–17 (the machine):** the loop has a person in it and the answer
  is to make the machine report on itself. `Fathom` turns [PHASE4 §5](PHASE4.md)
  from a checklist somebody works to a program anybody runs, and **the hardware
  support matrix its reports populate is a deliverable in its own right** — every
  probe's negative case exercised in the build VM first, because a probe with no
  positive control measures nothing (§2.37).
