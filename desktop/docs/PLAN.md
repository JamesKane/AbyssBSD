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

**Our job is not to rewrite all of that in Swift.** It is to build the *experienced*
desktop — the Aqua toolkit, shell, and apps — in Swift 6, reuse the proven Rust engine
underneath for now, and replace pieces with Swift later where it pays.

### Decisions locked in (from planning Q&A)

1. **Compositor: reuse now, rewrite later.** Keep the Rust `tide` compositor (its
   allocation-free real-time present path and the C1–C5 frame contract are proven and
   hostile to Swift's ARC). Build the Aqua shell/toolkit/apps in Swift 6 as Wayland
   *clients*. Revisit a Swift compositor only once the toolkit and Embedded-Swift
   hot-path patterns are proven (Phase 6).
2. **Aqua fidelity: faithful 10.2 clone.** Pinstripes, lickable gel buttons,
   traffic-light controls, the magnifying Dock, Apple menu, pinstriped menu
   bar. The 512pixels Aqua screenshot library is the spec. (Brushed metal is
   deliberately out of scope — it only became a widespread window texture in
   Panther/Tiger; Jaguar used it sparingly and the era-faithful default is the
   pinstriped/white Aqua window.)
3. **Dev platform: Linux-first, then port.** Swift 6 is first-class on Linux; build the
   toolkit + shell on this workstation against a stock wlroots compositor (sway/labwc)
   for fast iteration, then bring Swift up on FreeBSD and integrate with `tide`.
4. **This document: full phased roadmap.** Phase 0–1 are executable detail; later phases
   are milestone sketches to be expanded when reached.

### Inheriting the sibling's standing policies (adapted to Swift)

- **Minimal third-party dependencies.** Capability = **hand FFI to a mature C system
  library** (wayland, xkbcommon, libnv, freetype, harfbuzz, cairo, libpng/jpeg, crypto)
  or vendored C. Avoid SwiftPM registry deps the way the sibling avoids crates.io.
- **Wrap in phase 1, rewrite in Swift later.** Don't hand-fake a capability a mature C
  lib provides; wrap it behind a clean Swift interface (the `wlsys`/`sysffi` discipline).
- **The performance contract is the feature.** Keep `tide`'s C1–C5 benches as a
  CI gate; never let the Swift client layer regress input-to-photon.

---

## Naming (provisional, aquatic theme continues)

| Swift module / app | Role | Sibling analog |
|---|---|---|
| `CWayland` | C-interop target: libwayland-client + scanner-generated protocols | `reef/wl` C glue |
| `Surface` | Swift Wayland client runtime (registry, surfaces, shm, seat, event loop) | `reef-wl` |
| `Aqua` | The Aqua toolkit: 2D drawing, text, the 10.2 widget set + theme | `reef-wl::canvas` |
| `CurrentIPC` | Swift binding to `current` (libnv over unix sockets + SCM_RIGHTS) | `ipc/current` |
| `PoolConfig` | Swift reimpl of `pool` (mmap read / atomic-rename write / kqueue watch) | `ipc/pool` |
| `Dock`, `MenuBar`, `Finder`, `Desktop`, `LoginWindow`, `SystemPrefs` | the shell | `reef-*` |
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
  (a) `pkg`/ports `lang/swift` if a current 6.x exists, (b) **cross-compiling from Linux
  using a Swift SDK** built for FreeBSD, (c) building the toolchain from source in the
  VM. Capture findings in `docs/SWIFT-ON-FREEBSD.md`. **This is the #1 project risk** —
  surface results early.
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
  - `CurrentIPC` — bind `libnv` and speak the `current` wire protocol (unix sockets,
    nvlist, fd-passing via `SCM_RIGHTS`) so Swift clients interoperate with the existing
    Rust services. API shape mirrors `ipc/current/lib.rs` (`Msg.set_*/get_*`, `call`,
    `Server`).
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

## Phase 3 — Integrate with `tide` on FreeBSD

**Goal:** the Swift Aqua desktop running on its real engine, in the FreeBSD VM.

- Bring Swift up on FreeBSD per the Phase 0 spike; get `Surface`/`Aqua` linking against
  FreeBSD libwayland/cairo/freetype/harfbuzz.
- **Adopt from the sibling, as-is or lightly forked:** `tide` (compositor), `current`,
  `pool` (Rust side), `shmring`, `vents` (sysctl/OSS/devd bridges), `anchor` (session
  supervisor). The Swift shell connects to `tide` over Wayland and to services over
  `current`.
- **The D-Bus replacement story (goal #3):** `current` *is* the bus (brokerless nvlist
  IPC). Reuse the sibling's reimagined, compositor-owned portals (`reef-portal`/`open`/
  `save`/`notify` — file chooser, screenshot/cast, notifications). **Legacy adapter:** a
  **jailed D-Bus bridge** + XWayland for GTK/Qt apps, off the critical path, so legacy
  apps that expect a session bus / portals / MPRIS / AT-SPI still work.
- Run the full `tide` + Swift-shell stack on `tide`'s **headless** backend in the VM and
  keep the C1–C5 perf benches green as a gate.

**Verify:** in the VM, `tide` (headless) + Swift shell come up under `anchor`; the C1–C5
benches pass; portals hand an fd to a sandboxed Swift app.

---

## Phase 4 — Mac Pro 2013 (MacPro6,1) hardware bringup

**Goal:** real graphics and real hardware — unblocks `tide`'s GPU present path
(`DESKTOP.md` phase 2, the sibling's one true blocker).

- **Boot:** FreeBSD 15 UEFI on Apple EFI (Mac Pro 6,1 quirks); ZFS-on-root.
- **GPU:** dual **AMD FirePro D300/D500/D700** = GCN 1.0 / Southern Islands → `drm-kmod`
  **amdgpu with `si_support`** (or `radeonkms`); validate KMS, then the GPU phase:
  DRM/KMS via `seatd`, hardware cursor, atomic page-flip, real vblank, dmabuf +
  explicit-sync, direct scanout, dual-GPU handling. **`allow.rtprio`** custom-kernel jail
  param (already built in the sibling) grants the present thread bounded RT.
- **Peripherals:** Apple NVMe quirks, Thunderbolt 2, audio; Broadcom Wi-Fi is weak on
  FreeBSD — plan Ethernet/USB-NIC fallback.

**Verify:** `tide` drives a real display at refresh rate on the Mac Pro; flight recorder
shows zero missed flips under load; the Aqua desktop is interactive on metal.

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

## Phase 6 — Swift compositor (the "rewrite later" half of decision #1)

**Goal:** incrementally replace Rust `tide` with a Swift compositor without regressing
the contract.

- Use **Embedded Swift / manual memory management** (no ARC, no allocations) for the
  present thread; reuse the `wlsys`-equivalent C-shim binding to wlroots.
- Migrate piece by piece (reactor → scene → present), keeping the **headless C1–C5
  benches as the gate** at every step — a regression fails the build, exactly as today.

---

## Cross-cutting: what we borrow vs. build

- **Borrow (copy/adapt):** VM + test harness (`abyss/vm`, `abyss/tests`), and at the
  source level `tide`, `current`, `pool`, `shmring`, `vents`, `anchor`, the protocol XML
  set, the `allow.rtprio` kernel patch, and the SEAMS porting map.
- **Build new in Swift:** `CWayland`, `Surface`, `Aqua`, `CurrentIPC`, `PoolConfig`, and
  the entire shell + installer.
- **Reimplement later in Swift:** the compositor (Phase 6), optionally `pool`/`shmring`
  (read sides already in Swift).

## Top risks (track explicitly)

1. **Swift on FreeBSD** — unofficial; the whole product hinges on the Phase 0 spike.
2. **Mac Pro GCN 1.0 GPU** — `amdgpu si_support` maturity for FirePro D-series; dual-GPU.
3. **Aqua fidelity in software rendering** — gloss/blur/pinstripe at HiDPI via Cairo.
4. **Swift ARC vs. the latency contract** — kept off the critical path by reusing `tide`;
   re-enters as a risk only in Phase 6 (mitigated by Embedded Swift).
5. **Broadcom Wi-Fi** on FreeBSD — likely wired/USB fallback on the Mac Pro.

## Overall verification strategy

- **Phases 1–2 (Linux):** `swift build`/`swift test`; run clients under sway; visual diff
  against the 10.2 screenshot library; screenshots in PR descriptions.
- **Phases 3+ (FreeBSD):** adapted `abyss/tests/run.sh` in the qemu/KVM VM — host
  `swift test` + in-VM ATF/Kyua, including `tide`'s headless C1–C5 perf gate.
- **Phase 4+ (metal):** on-device bring-up checklist + flight-recorder missed-flip == 0.
