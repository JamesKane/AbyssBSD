# Phase 2 — The Aqua Shell + Config, on Linux (scope)

Expands PLAN.md §"Phase 2" from milestone sketch to executable detail, grounded in
a read of the Rust sibling's shell (`reef`), config (`pool`), and IPC (`current`).
Read [PLAN.md](PLAN.md) for the locked decisions and [STATUS.md](STATUS.md) for the
Phase-1 baseline this builds on.

Last updated: 2026-07-20.

---

## 1. Scope boundary (what Phase 2 is and is NOT)

**Phase 2 = the Aqua *shell* as Wayland clients, running against stock sway on
Linux, plus the Swift config substrate.** Same dev loop as Phase 1: build on this
box, verify live under headless sway + grim, unit-test the pure logic, one pass
per commit.

**Explicitly NOT in Phase 2** (locked in PLAN.md, restated because the sibling
tempts otherwise):

- **No compositor work.** We reuse Rust `tide` in Phase 3 on FreeBSD. On Linux the
  shell runs as clients against **sway** (a stock wlroots compositor), which
  already provides `wlr-layer-shell`, `wlr-foreign-toplevel-management`,
  `xdg-activation`, and the seat. The sibling's `tide` metronome / triple-buffer /
  reactor are **not** ported here — that's Phase 6, if ever.
- **No `anchor` session supervisor (real one).** `anchor` is FreeBSD-native
  (`pdfork(2)` + `kqueue` `EVFILT_PROCDESC`). For Linux dev we use a thin launch
  script; the real supervisor arrives with Phase 3.
- **No `vents` hardware bridges.** OSS mixer / `sysctlbyname` / `devd` are
  FreeBSD-only. The menu-bar volume/battery/status items get stubbed or hidden on
  Linux; real bridges land in Phase 3.

**Deferred within Phase 2 (the FreeBSD-coupled tail):**

- **`CurrentIPC` is deferred to the end of the phase, and may slip to Phase 3.**
  It binds **libnv**, which is a FreeBSD-native library — **not present on this
  Linux box** (verified: no `pkg-config libnv`, no headers, no libbsd). Standing it
  up on Linux means vendoring a portable libnv or hand-rolling the nvlist codec
  first. And it isn't on the critical path: `current` carries only the shell's
  *control plane* (`reefctl`→panel reload/menu, screenshot, notifications) — none
  of the visible desktop (wallpaper, menu bar, Dock) needs it. So we build the
  whole visible shell over Wayland + `PoolConfig` first, and treat `CurrentIPC`
  as an isolated late pass (or hand it to Phase 3 with the rest of the FreeBSD
  bringup).

---

## 2. What we already have vs. what's new

Phase 1 gave us the client runtime and toolkit the shell sits on — the sibling's
`reef-wl` (1,930 LOC of libwayland FFI + a software canvas) is **already covered**
by our `Surface` + `Aqua`. What Phase 2 adds:

| Need | Have (Phase 1) | New (Phase 2) |
|---|---|---|
| Wayland client, shm, seat, frame pacing | `Surface` (`Display`/`Window`/`Popup`) | — |
| Toolkit: gel buttons, text, menus, controls | `Aqua` + `AquaMenu` | shell-specific chrome (menu bar, Dock tile, icon grid) |
| Window role | xdg-shell toplevel + xdg-popup | **layer-shell surface role** (new) |
| Running-app awareness | — | **foreign-toplevel** client (new) |
| Launch / raise | — | **xdg-activation** client (new) |
| Config | — | **`PoolConfig`** (new) |
| Control-plane IPC | — | **`CurrentIPC`** (deferred) |

The three new protocol XMLs are **already vendored** in `protocols/` and stubbed
(commented) in `de/cwayland/generate-protocols.sh`. Adding each is the mechanical
recipe from HANDOFF §2.1: uncomment the `gen` line, list the generated `.c` in
`Package.swift`, add `aw_*` shims for the requests we call, fill every event slot
(the NULL-listener trap, §2.3).

---

## 3. Component map (sibling → ours)

| Jaguar element | Sibling analog | Protocol / role | Notes |
|---|---|---|---|
| **Desktop / wallpaper** | `reef-desktop` (315 LOC) | layer-shell **BACKGROUND**, all-4 anchors, exclusive −1 | solid / gradient / PNG; reads `desktop.ini` |
| **Menu bar** | `reef-panel` top bar (1,903 LOC) | layer-shell **TOP**, anchor top+L+R, **exclusive ~22px**; dropdowns on **OVERLAY** | Apple menu, app menus, clock, status; reuses `AquaMenu` |
| **Dock** | *(none — new)* | layer-shell **BOTTOM**, anchored bottom-center | **magnification**, running indicators (foreign-toplevel), Trash. Jaguar-specific, no sibling code |
| **Finder** | `reef-fm` (1,356 LOC) | **xdg-shell** toplevels (not layer-shell) | real spatial FM: readdir, icon grid, multi-window; largest piece |
| **Config** | `pool` (431 LOC) | — | mmap read / atomic-rename write / watch |
| **Control IPC** | `current` (456 LOC) | unix socket + libnv | *deferred* |
| Session launch | `anchor` (456 LOC) | — | Linux: thin script; real one in Phase 3 |

Note the Dock: the sibling's `reef-panel` is a single *top* bar with an inline
taskbar — it has **no Dock**. AbyssBSD wants the full Jaguar pairing (top menu bar
*and* a magnifying bottom Dock), so the Dock is **net-new design**, taking the
running-app list from foreign-toplevel the way `reef-panel`'s taskbar does.

---

## 4. Ordered passes (recommended)

Each is one build→live-verify→test→doc→commit pass, in dependency order. The
layer-shell spike gates everything visible; `PoolConfig` is independent and can
slot in anywhere.

**P2.1 — Layer-shell in `Surface` (the foundational spike).**
Generate `wlr-layer-shell-unstable-v1`; add a `LayerSurface` role beside `Window`
(namespace, layer, anchors, exclusive zone, `configure` w/ serial ack, keyboard
interactivity). Prove it with a trivial full-screen BACKGROUND fill under sway.
Riskiest new path; do it first and thin.

**P2.2 — Desktop / wallpaper (`reef-desktop` analog).**
First real layer-shell client: BACKGROUND, all-4 anchors, exclusive −1. Solid →
gradient → PNG (we already bind libpng via `CText`/cairo). This validates the
whole layer-shell path end-to-end with almost no UI. Add `live-sway.sh desktop`.

**P2.3 — `PoolConfig` (the `pool` port).**
Pure-syscall Swift: INI parse, `mmap(MAP_PRIVATE, PROT_READ)` read, temp+`fsync`+
atomic-`rename` write under a `flock`, and a watch abstraction — **inotify on
Linux, `kqueue`/`EVFILT_VNODE` on FreeBSD** behind one `#if os(...)` protocol.
Same `~/.config/abyss/*.ini` files as the sibling (`desktop`, `panel` domains) so
Swift and Rust stay config-compatible. Fully unit-testable, no compositor. Wire
the wallpaper (P2.2) to read `desktop.ini` and hot-reload.

**P2.4 — Menu bar (`reef-panel` top-bar analog, in Aqua dress).**
layer-shell TOP, exclusive ~22px (Jaguar bar height × scale). Pinstriped bar,
Apple menu + app menus as **`AquaMenu` popups** (already built), right-aligned
clock, status items (stubbed on Linux). The Jaguar signature. Reads `panel.ini`.

**P2.5 — foreign-toplevel + Dock.**
Generate `wlr-foreign-toplevel-management`; a `ForeignToplevels` client tracking
title/app_id/state. Then the Dock: layer-shell BOTTOM, bottom-center, the
**magnification** curve (pointer-x → per-tile scale), running-app dots, Trash.
Clicking a running tile sends foreign-toplevel `activate`. Second Jaguar
signature; the magnification math is the hard part (pure + unit-testable).

**P2.6 — Finder (`reef-fm` analog).**
xdg-shell toplevels (reuse `Window`), `readdir` listing, Aqua icon grid, spatial
multi-window, keyboard nav + open. Largest pass; can be its own mini-sequence.
Generate `xdg-activation` here for raise-existing-window.

**P2.7 (deferred) — `CurrentIPC` + control plane.**
Only if we choose to land it on Linux: vendor a portable libnv (or hand-roll the
nvlist pack/unpack + `SCM_RIGHTS`), then a `reefctl`-equivalent driving menu-bar
reload/menu and notifications. Otherwise carry to Phase 3.

**P2.8 — Dev session launcher.**
A shell/Swift script that starts sway (or targets the running one), then the
wallpaper + menu bar + Dock as clients — the Linux stand-in for `anchor`. Gives us
a one-command "boot the desktop" for demos and live tests.

---

## 5. Verification (unchanged discipline)

- **Unit:** pure logic with no compositor — INI round-trip + atomic-write for
  `PoolConfig`; layer geometry (anchor/exclusive) and Dock magnification as pure
  functions (the HANDOFF §2.9 "one layout function" pattern).
- **Live:** extend `abyss/tests/live-sway.sh` with shell modes (`desktop`,
  `menubar`, `dock`, `finder`) — headless sway already advertises layer-shell and
  foreign-toplevel, so grim captures the real placement. New virtual-input helpers
  as needed (Dock hover for magnification, menu-bar clicks).
- **Config compat:** a test that writes an `ini` with `PoolConfig` and re-reads the
  bytes matches the sibling's format (§3 of the pool briefing).

---

## 6. Risks / open decisions

1. **libnv on Linux (the `CurrentIPC` blocker).** Deferred per §1; decision point
   at P2.7 — vendor portable libnv vs. hand-roll the codec vs. push to Phase 3.
2. **sway's exclusive-zone / anchor fidelity vs. `tide`.** We develop against
   sway's layer-shell; `tide`'s `arrange()`/`apply_exclusive()` may differ subtly.
   Keep placement logic in pure functions so re-targeting `tide` in Phase 3 is a
   config change, not a rewrite.
3. **The Dock is new design.** No sibling reference for magnification; the 512px
   Jaguar library is the spec (as with the toolkit).
4. **Watch portability.** inotify (Linux) vs. kqueue (FreeBSD) is the one place
   `PoolConfig` forks by OS; keep it behind a single small protocol.
5. **Standing #1 risk unchanged:** Swift-on-FreeBSD (SWIFT-ON-FREEBSD.md) still
   gates everything shipping to target; Phase 2 stays fully Linux-verifiable so it
   doesn't block on that.
</content>
</invoke>
