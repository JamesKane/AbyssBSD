# Phase 2 — The Aqua Shell + Config, on Linux (scope)

Expands PLAN.md §"Phase 2" from milestone sketch to executable detail, grounded in
a read of the Rust sibling's shell (`reef`), config (`pool`), and IPC (`current`).
Read [PLAN.md](PLAN.md) for the locked decisions and [STATUS.md](STATUS.md) for the
Phase-1 baseline this builds on.

Last updated: 2026-07-24.

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

**P2.1 — Layer-shell in `Surface` (the foundational spike). ✅ done.**
Generated `wlr-layer-shell-unstable-v1`; added a `LayerSurface` role beside
`Window` (namespace, layer, anchors, exclusive zone, `configure`+ack, keyboard
interactivity, buffer pool + frame pacing + per-output scale). `Display` binds
`zwlr_layer_shell_v1` and routes input/scale to a layer surface when no window is
present (`routeKeyEvent` + the pointer routes fall through). Proved by a
BACKGROUND wallpaper (`Aqua/Wallpaper.swift`, `AQUA_SCENE=wallpaper`) that fills
the output with the Jaguar blue gradient — verified live under sway
(`live-sway.sh wallpaper`, which asserts on the app's `LayerSurface: mapped` log
since layer surfaces don't appear in `get_tree`). See HANDOFF §2.16.

**P2.2 — Desktop / wallpaper (`reef-desktop` analog). ✅ done.**
`Wallpaper` now reads `desktop.ini` via `PoolConfig` and resolves a `DesktopStyle`
(precedence: `image` PNG → `grad_top`/`grad_bot` gradient → flat `bg` →
built-in Jaguar blue), painted by the pure `paintDesktop` (image is cover-scaled;
`Color(cssHex:)` parses `#aarrggbb`). Hot-reload: a `Pool.Watcher` fd is folded
into the run loop via the new **`Display.addFileDescriptor(_:onReadable:)`** (a
reusable extra-fd hook — later the menu-bar clock timer and IPC sockets use it
too), so a rewrite of `desktop.ini` repaints with no polling. Verified live:
`live-sway.sh --reload` loads a gradient from config, then an atomic swap to a
flat `bg` hot-reloads the desktop (`docs/screenshots/live-desktop-reload.png`).
See HANDOFF §2.18. (Desktop *icons* remain future — the backdrop is the P2.2
scope.)
First real layer-shell client: BACKGROUND, all-4 anchors, exclusive −1. Solid →
gradient → PNG (we already bind libpng via `CText`/cairo). This validates the
whole layer-shell path end-to-end with almost no UI. Add `live-sway.sh desktop`.

**P2.3 — `PoolConfig` (the `pool` port). ✅ done.**
Pure-syscall Swift (`de/poolconfig/`, no Wayland): `Config` (INI parse/serialize,
typed string/uint64/int64/bool reads with the same coercions), `Pool.load`
(`mmap(MAP_PRIVATE, PROT_READ)` read → parse → empty on missing), `Config.store`
(temp + `fsync` + atomic `rename` under a `flock`), and `Pool.Watcher`. The one
platform fork — **inotify on Linux, `kqueue`/`EVFILT_VNODE` on FreeBSD** — is
isolated in a tiny C shim (`CPoolWatch`) that returns a pollable fd, so a
component can fold config wakeups into its own loop next to the Wayland fd. Same
`~/.config/abyss/*.ini` files as the sibling (`desktop`/`panel` domains) so Swift
and Rust stay config-compatible. 9 unit tests incl. a live watcher wake. P2.2/P2.4
wire the wallpaper/menu bar to read their `.ini` and hot-reload. See HANDOFF §2.17.

**P2.4 — Menu bar (`reef-panel` top-bar analog, in Aqua dress). ✅ done.**
`MenuBar` — layer-shell TOP, exclusive 22px, anchored top+L+R: a pinstriped Aqua
bar with an original water-drop system glyph (not Apple's apple), the bold app
menu, the standard menus (File/Edit/View/Go/Window/Help), and a right-aligned
clock. The first *interactive* layer surface: clicking a title opens a real
dropdown — an **`AquaMenu` in a grabbing popup parented to the layer surface**.
That needed generalising `Popup` (a shared designated init + Window- and
LayerSurface-parented convenience inits; a layer popup is a parent-less xdg_popup
then `zwlr_layer_surface_v1.get_popup`). The clock ticks via a `timerfd`
(`aw_create_interval_timer`) folded into the run loop with `addFileDescriptor`.
Reads `panel.ini` (`show_clock`, `menubar_height`). Verified live: `live-sway.sh
--menubar` maps the 800×22 bar and clicks the system title to open a dropdown
(`docs/screenshots/live-menubar.png`). See HANDOFF §2.19. (Menu-bar *keyboard*
nav and hardware status items — volume/battery — are future; the latter needs the
FreeBSD `vents` bridges.)

**P2.5 — foreign-toplevel + Dock. ✅ done.**
`Surface.ForeignToplevels` binds `wlr-foreign-toplevel-management` (captured by
Display, bound+listened in one step so no `toplevel` event hits a NULL listener),
tracking title/app_id/activated per handle and notifying a delegate on `done`.
The **`Dock`** (layer-shell BOTTOM, full-width, height fits a magnified tile) is
net-new design: a translucent shelf of procedural app tiles that **magnify** under
the pointer (`dockMagnify` — a pure, unit-tested curve: base-coordinate distance →
raised-cosine falloff → re-laid-out at scaled sizes, centred), running-app
triangles beneath open apps (from `ForeignToplevels`), a hovered-tile tooltip, and
the Trash behind a separator. Clicking a running tile calls foreign-toplevel
`activate`. Config from `dock.ini` (`tile_size`, `magnify`). Verified live:
`live-sway.sh --dock` maps the shelf, hovers to magnify (captured — the pointer is
held present since magnification is hover-driven), and a second window proves the
foreign-toplevel tracker sees it (`Dock: running …`).
`docs/screenshots/live-dock.png`. See HANDOFF §2.20. (App *launching* from a
pinned-not-running tile needs exec/xdg-activation — future.)

**P2.6 — Finder (`reef-fm` analog). ✅ first pass done.**
The first shell component that is an ordinary **xdg-shell application** (it
reuses `Window`, not `LayerSurface`). `FinderModel.swift` is the pure half —
`readDirectory` (POSIX `opendir`/`stat`, dot-files filtered, Finder sort),
path helpers, `finderLayout` / `finderItemRect` / `finderIndex(atX:y:)` /
`finderScrollToShow` / `finderMove` — so paint and hit-test share one geometry
and the whole model unit-tests with no compositor. `Finder.swift` paints it
(toolbar with Back + an icon/list view switch, white item well, procedural
folder/document/app/volume icons, Aqua scrollbar, status bar) and wires the live
window: click to select, double-click to open, Back, wheel/thumb/arrow scrolling,
and keyboard nav (arrows by row, Home/End, Return, Backspace-up, Page keys, Tab
to switch view, type-ahead). Config from `finder.ini` (`view`, `show_hidden`);
starts in `$ABYSS_FINDER_DIR` (else `$HOME`). Verified live against a seeded
directory: `live-sway.sh --finder [--keys]` browses into a folder, returns via
Back, switches to list view and repeats it from the keyboard
(`docs/screenshots/live-finder.png`). See HANDOFF §2.21.

**Fidelity correction (deliberate):** the scope sketch above said "spatial
multi-window", inherited from `reef-fm`. The **10.2 Finder is a browser** — a
toolbar window that navigates in place, where hiding the toolbar is what gives
you a spatial window. So this pass browses in place; the toolbar-hidden spatial
mode (and with it multi-window routing, which needs `Display` to route input by
surface rather than to one primary window) is deferred to the Finder's second
pass, along with `xdg-activation` (raise an existing window), file operations
(new folder / rename / delete / copy) and launching what you double-click.

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
