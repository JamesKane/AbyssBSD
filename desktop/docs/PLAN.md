# AbyssBSD (Swift DE) — Phased Roadmap

## Context

We are starting **AbyssBSD**, a FreeBSD `releng/15.0` fork whose headline feature is a
**new desktop environment written in Swift 6**, styled as a faithful clone of
**Mac OS X 10.2 "Jaguar" Aqua**, running on **Wayland**, with a Fedora/Anaconda-style
graphical installer, targeting the **Mac Pro 2013 (MacPro6,1)** and newer.

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
2. **Aqua fidelity: faithful 10.2 clone.** Pinstripes, lickable gel buttons,
   traffic-light controls, the magnifying Dock, Apple menu, pinstriped menu
   bar. The 512pixels Aqua screenshot library is the spec. (Brushed metal is
   deliberately out of scope — it only became a widespread window texture in
   Panther/Tiger; Jaguar used it sparingly and the era-faithful default is the
   pinstriped/white Aqua window.)
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
| *(compositor, session supervisor, hardware bridges)* | Swift rewrites, later phases | `tide`, `anchor`, `vents` |
| `Installer` | Fedora-style graphical installer (Aqua app) | — (new) |

Names are a theme, not a contract — the architecture is what matters.

---

## Phase 0 — Foundations & Swift toolchain (the critical-path spike)

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

**Goal:** a usable desktop shell (Swift Wayland clients) running against sway.

- **IPC/config in Swift:**
  - `CurrentIPC` — the control plane in Swift: unix sockets, typed messages, fd-passing
    via `SCM_RIGHTS`. API shape mirrors `ipc/current/lib.rs` (`Msg.set_*/get_*`, `call`,
    `Server`), rewritten rather than bound. **Deferred out of Phase 2 and decided
    2026-07-27 — see PHASE2.md P2.9:** every peer it would talk to is itself a Phase-3
    Swift deliverable, so it lands there, with base `libnv` as the fallback encoder if
    a Swift codec proves impractical.
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

## Phase 4 — Mac Pro 2013 (MacPro6,1) hardware bringup

**Goal:** real graphics and real hardware — what a GPU present path needs (the
sibling hit the same wall: `DESKTOP.md` phase 2 was its one true blocker).

- **Boot:** FreeBSD 15 UEFI on Apple EFI (Mac Pro 6,1 quirks); ZFS-on-root.
- **GPU:** dual **AMD FirePro D300/D500/D700** = GCN 1.0 / Southern Islands → `drm-kmod`
  **amdgpu with `si_support`** (or `radeonkms`); validate KMS, then the GPU phase:
  DRM/KMS via `seatd`, hardware cursor, atomic page-flip, real vblank, dmabuf +
  explicit-sync, direct scanout, dual-GPU handling. **`allow.rtprio`** custom-kernel jail
  param (already built in the sibling) grants the present thread bounded RT.
- **Peripherals:** Apple NVMe quirks, Thunderbolt 2, audio; Broadcom Wi-Fi is weak on
  FreeBSD — plan Ethernet/USB-NIC fallback.

**Verify:** the compositor drives a real display at refresh rate on the Mac Pro; the
flight recorder shows zero missed flips under load; the Aqua desktop is interactive on
metal.

---

## Phase 5 — Fedora/Anaconda-style installer

**Goal:** a guided graphical installer matching goal #5.

- A **live environment** boots straight into a minimal Aqua desktop running the
  `Installer` Swift app (Aqua toolkit), with an Anaconda-style hub-and-spoke flow:
  welcome → language/keyboard → disk & partitioning (ZFS-on-root default, via `gpart`/
  `zpool`) → timezone/network → user account → summary → install → reboot.
- **Pragmatic v1:** the GUI drives the proven FreeBSD install steps (the `bsdinstall`
  logic: distextract, partitioning, bootcode, user setup) behind the Aqua front-end;
  grow native logic over time.

**Verify:** clean install onto the Mac Pro (and the VM) end-to-end from the live image,
booting into the Aqua desktop.

---

## Phase 6 — Swift compositor

**Goal:** the compositor in Swift, meeting `tide`'s contract rather than inheriting its
code. (Sequenced last because the shell is what makes the desktop *visible*, and it
runs on any wlroots compositor meanwhile — not because the rewrite is optional.)

- Use **Embedded Swift / manual memory management** (no ARC, no allocations) for the
  present thread; bind wlroots through a C shim of our own, in the `wlsys` style.
- Migrate piece by piece (reactor → scene → present), keeping the **headless C1–C5
  benches as the gate** at every step — a regression fails the build, exactly as today.

---

## Cross-cutting: what we borrow vs. build

- **Borrow as *design*, not as code:** the algorithms and architecture of `tide`,
  `current`, `pool`, `shmring`, `vents`, `anchor` and `abyss-image` — read them, then
  write the Swift. What we do copy verbatim is the non-product scaffolding: the VM +
  test harness (`abyss/vm`, `abyss/tests`), the protocol XML set, the `allow.rtprio`
  kernel patch, and the SEAMS porting map. Where a *format* must match (the `pool`
  `.ini` files, a protocol on the wire), match the format — not the implementation.
- **Build in Swift:** everything else. `CWayland`, `Surface`, `Aqua`, `PoolConfig` and
  the shell exist; `CurrentIPC`, the compositor, the session supervisor, the FreeBSD
  hardware bridges, the image codec and the installer are still to come.
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
2. **Mac Pro GCN 1.0 GPU** — `amdgpu si_support` maturity for FirePro D-series; dual-GPU.
3. **Aqua fidelity in software rendering** — gloss/blur/pinstripe at HiDPI via Cairo.
4. **Swift ARC vs. the latency contract** — now a *live* risk rather than a deferred
   one, since the compositor is to be written in Swift rather than inherited from
   `tide`. It stays off the critical path only while the shell runs as a client on a
   stock compositor. Mitigations when we get there: Embedded Swift, preallocation, and
   a C shim for the present path if measurement demands it — with `tide`'s C1–C5
   benches as the gate that tells us.
5. **Broadcom Wi-Fi** on FreeBSD — likely wired/USB fallback on the Mac Pro.

## Overall verification strategy

- **Phases 1–2 (Linux):** `swift build`/`swift test`; run clients under sway; visual diff
  against the 10.2 screenshot library; screenshots in PR descriptions.
- **Phases 3+ (FreeBSD):** adapted `abyss/tests/run.sh` in the qemu/KVM VM — host
  `swift test` + in-VM ATF/Kyua, including `tide`'s headless C1–C5 perf gate.
- **Phase 4+ (metal):** on-device bring-up checklist + flight-recorder missed-flip == 0.
