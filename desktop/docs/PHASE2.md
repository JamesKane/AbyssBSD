# Phase 2 — The Aqua Shell + Config, on Linux (scope)

Expands PLAN.md §"Phase 2" from milestone sketch to executable detail, grounded in
a read of the Rust sibling's shell (`reef`), config (`pool`), and IPC (`current`).
Read [PLAN.md](PLAN.md) for the locked decisions and [STATUS.md](STATUS.md) for the
Phase-1 baseline this builds on.

Last updated: 2026-07-27.

**Phase 2 is complete.** P2.1–P2.8 built the visible shell, P2.10 made it boot as
one desktop, P2.11 tied off the polish, and P2.9 — always a decision rather than
a coding task — was decided on 2026-07-27: `CurrentIPC` is carried to Phase 3 and
written in Swift there (§4, P2.9). Next is Phase 3, FreeBSD bring-up.

---

## 1. Scope boundary (what Phase 2 is and is NOT)

**Phase 2 = the Aqua *shell* as Wayland clients, running against stock sway on
Linux, plus the Swift config substrate.** Same dev loop as Phase 1: build on this
box, verify live under headless sway + grim, unit-test the pure logic, one pass
per commit.

**Explicitly NOT in Phase 2** (locked in PLAN.md, restated because the sibling
tempts otherwise):

- **No compositor work in this phase.** The shell runs as clients against
  **sway** (a stock wlroots compositor), which already provides
  `wlr-layer-shell`, `wlr-foreign-toplevel-management`, `xdg-activation`, and the
  seat — on FreeBSD as on Linux. A **Swift** compositor is its own later phase
  (PLAN.md); the sibling's `tide` metronome / triple-buffer / reactor are the
  design reference for it, not code to link.
- **No `anchor` session supervisor (real one).** `anchor` is FreeBSD-native
  (`pdfork(2)` + `kqueue` `EVFILT_PROCDESC`). For Linux dev we use a thin launch
  script; the real supervisor arrives with Phase 3.
- **No `vents` hardware bridges.** OSS mixer / `sysctlbyname` / `devd` are
  FreeBSD-only. The menu-bar volume/battery/status items get stubbed or hidden on
  Linux; real bridges land in Phase 3.

**Deferred within Phase 2 (the FreeBSD-coupled tail) — now resolved:**

- **`CurrentIPC` was deferred to the end of the phase, and on 2026-07-27 it was
  **carried to Phase 3** (full reasoning under P2.9 in §4). It isn't on the
  critical path: `current` carries only the shell's *control plane* (panel
  reload/menu, screenshot, notifications) — none of the visible desktop
  (wallpaper, menu bar, Dock) needs it, and the Dock gets running apps from
  foreign-toplevel instead. Its FreeBSD-native encoder (**libnv**) isn't on this
  Linux box (verified: no `pkg-config libnv`, no headers, no libbsd), and every
  peer it would speak to is itself an unwritten Phase-3 Swift component — so
  there is nothing here to talk to and nothing to verify against.

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
| Control-plane IPC | — | **`CurrentIPC`** (carried to Phase 3 — P2.9) |

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
| **Control IPC** | `current` (456 LOC) | unix socket + fd passing | *carried to Phase 3 (P2.9)* |
| Session launch | `anchor` (456 LOC) | — | `abyss/session.sh` (P2.10); a Swift supervisor in Phase 3 |

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

**Fidelity note:** the scope sketch above said "spatial multi-window", inherited
from `reef-fm`. The **10.2 Finder is a browser by default** — a toolbar window
that navigates in place — and hiding the toolbar is what makes it spatial. Both
modes now exist, switched by the title bar's pill (see the spatial pass below).

**P2.6b — spatial mode + multi-window. ✅ done.**
Clicking the pill hides the toolbar and switches the Finder to **spatial**: each
folder opens in its own window (`FinderApp` owns them all), re-opening a folder
that already has a window **raises** it via **xdg-activation** (protocol
generated + bound this pass), the red traffic light closes a single window, and
the process exits with the last one. The mode persists to `finder.ini`
(`toolbar`). That required the client runtime to go multi-window: `Display` now
keeps a weak **window registry** and routes pointer/keyboard **by wl_surface**
(from the `enter` events) instead of to one primary window, and `Window` gained
`close()` (teardown-guarded), `activate()` and a `windowShouldClose` delegate
hook so closing one window no longer stops the process. Verified live:
`live-sway.sh --spatial` hides the toolbar, opens a second real toplevel
(asserted in sway's tree), re-opens to a raise rather than a duplicate, and
closes one window with the app still running
(`docs/screenshots/live-finder-spatial.png`). See HANDOFF §2.22.

**Known limitation (protocol, not laziness):** a Wayland client can't position
its own windows, so the "remembered window position" half of spatial Finder isn't
expressible here — sway places them. Size/view/mode we can and do persist;
position waits for `tide` in Phase 3.

**P2.6c — file operations. ✅ done.**
The Finder now changes the filesystem, with the Mac's verbs: **Return renames**
in place (⌘O / ⌘↓ / double-click open), **⌘⇧N** makes "untitled folder" and drops
straight into renaming it with the base name pre-selected, **⌘D** duplicates,
**⌘C/⌘X/⌘V** copy/cut/paste through a clipboard shared by every window, and
**⌘⌫** moves to `~/.Trash` — nothing unlinks what the user asked to delete. That
needed `KeyEvent` to carry **modifiers** (xkb; Command = Mod4/Logo) and the
virtual-keyboard test helper to send the `modifiers` event itself. `FinderOps.swift`
splits the work: pure naming rules over an `exists` predicate ("untitled folder 2",
"Read Me copy.txt" — extension-aware) and a thin POSIX layer (mkdir/rename/
recursive copy/trash). Every window showing an affected folder re-reads, so a
copy in one spatial window appears in another. Verified live: `live-sway.sh
--fileops` drives the real shortcuts through the compositor and checks the
**disk** — the folder is created and renamed, the copy matches byte for byte, and
⌘⌫ lands the copy in `~/.Trash` with the original intact
(`docs/screenshots/live-finder-fileops.png`). See HANDOFF §2.23.

**P2.7 — desktop icons. ✅ done.**
The Desktop draws the boot volume and the contents of `~/Desktop`
(`$ABYSS_DESKTOP_DIR` overrides) straight onto the wallpaper's BACKGROUND layer
surface, arranged the Jaguar way — **top-right corner downward, wrapping into a
column to the left** (`DesktopIcons.swift`, pure `desktopIconRect` shared by
paint and hit-test). Labels are white-on-shadow so they read over any wallpaper.
Click selects, double-click opens a **real Finder window** — the Desktop hosts a
`FinderApp` that does *not* own the process lifetime — and a `Pool.Watcher` on
the folder makes a newly-dropped file appear with no polling. Config:
`desktop.ini`'s `show_icons`. This also forced input routing to become fully
surface-driven (a process can now own a layer surface *and* toplevels at once —
see HANDOFF §2.24). Verified live: `live-sway.sh --desktop` selects an icon,
opens a Finder window from it (asserted in sway's tree), and sees a new file
land (`docs/screenshots/live-desktop-icons.png`).

**P2.8 — launching. ✅ done.**
Double-clicking something that isn't a folder now starts a process
(`Launcher.swift`): an `.app` bundle runs `Contents/MacOS/<name>` (the Mac
convention), a plain executable runs directly, and anything else goes to the
opener command (`$ABYSS_OPEN`, else `finder.ini`'s `open_command`) — with a
plain "no handler" when nothing is configured. Spawning is fork → fork →
`execve` with argv/envp/paths all built *before* the fork, so the child makes
only async-signal-safe calls and the grandchild reparents to init (no zombies,
no `waitpid` in the run loop). The Finder, the desktop icons and the **Dock**
all go through it; a Dock tile that isn't running launches another copy of this
binary in the right `AQUA_SCENE`. Verified live: `live-sway.sh --launch`
double-clicks a real (tiny) bundle and checks its executable actually ran, then
double-clicks a document and checks `$ABYSS_OPEN` received the path; the
`--dock` run now clicks the Finder tile and asserts a real Finder window
appears. See HANDOFF §2.25.

Remaining shell work after this pass: dragging desktop icons to reposition them
(needs the per-item positions a spatial desktop remembers) — see P2.11 for the
rest, which is done.

**P2.9 — `CurrentIPC` + control plane. ⏭ decided 2026-07-27: carried to Phase 3.**

This was always a decision rather than a coding task, and the decision is to
**carry it to Phase 3 and write it in Swift there — not to vendor a portable
libnv now, and not to build it on Linux against nothing.** What settled it:

- **Every consumer is FreeBSD-only, and every consumer is still unwritten.**
  `current` has exactly two users in the sibling: `anchor` (the session control
  socket) and `tide` (compositor control, plus a push protocol to the old
  GNOME-2 panel). We are **rewriting** those in Swift rather than reusing them
  (PLAN.md, corrected 2026-07-27), so the other end of every conversation this
  component would hold is itself a Phase-3 deliverable. `vents` (volume/battery,
  for the menu bar's status items) is FreeBSD hardware by definition.
- **Nothing visible depends on it.** Our Dock learns about running apps from
  **`wlr-foreign-toplevel-management`** — a Wayland protocol — not from tide's
  panel push, so the shell already has what that seam would have carried, from
  any wlroots compositor.
- **A Linux build could only talk to itself.** libnv isn't here (confirmed
  again: no header, no pkg-config, and the `libnv*` libraries on this box are
  NVIDIA/NVMe). The sibling's own crate only *type-checks* on Linux — its build
  tree holds `.rmeta` and no linked artifact, exactly what `-lnv` failing looks
  like. So neither side of a conversation exists here.
- **Nothing can be verified here anyway.** The first honest test of a control
  plane is a real client against a real service. Both ends land in Phase 3, so
  the work should too.

**Swift-native or libnv? Decide it in Phase 3, but the default is Swift.**
Since the peers are being rewritten in Swift, nvlist's wire format stops being
a compatibility requirement and becomes just one available encoding. Under the
"Swift unless Swift can't" rule, the codec is plainly feasible in Swift —
`PoolConfig` already does mmap/atomic-rename/flock/inotify-kqueue straight from
Swift with a C shim only for the platform fork, and `sendmsg`/`recvmsg` with
`SCM_RIGHTS` is the same kind of work. Binding base libnv stays the fallback if
the format's descriptor handling proves gnarlier than it looks, and remains
worth it if we ever want to speak to FreeBSD's own nvlist users. What we should
*not* do is vendor a port of libnv into the tree: that's C we'd own forever, for
a library that's in base on the target and unnecessary off it.

**What Phase 3 should know when it picks this up** (so the traps are already
written down):

- **If we do bind libnv, expect the `#define` symbol-prefix trap.** FreeBSD's
  `<sys/nv.h>` exports its symbols prefixed `FreeBSD_nvlist_*` (to avoid
  clashing with ZFS's libnvpair) and `#define`s the short names onto them.
  Swift's C importer does not see `#define`s — the same class of problem as
  libwayland's static-inline requests (HANDOFF §2.1) and `XKB_MOD_NAME_*`
  (§2.23). The Rust side had to spell `#[link_name = "FreeBSD_nvlist_create"]`;
  Swift would get the established fix: a one-line-per-call C shim (`de/cnv`,
  mirroring `de/cwayland`'s `aw_*`).
- **Keep the sibling's *shape*** — it's a good design, and reading it is free:
  a `Msg` of typed fields (str/u64/bool/bytes/**fd**), `runtime_dir()`
  (`$ABYSS_RUNTIME_DIR`, else `$XDG_RUNTIME_DIR/abyss`, else
  `/var/run/user/<uid>/abyss`, 0700), a service socket at
  `<runtime_dir>/<service>.sock`, `Server.bind/accept`, `connect`, and a
  one-shot `call`. Rewrite it in Swift; don't link it.
- **The run-loop hook already exists.** A `Server`'s listening fd goes straight
  into `Display.addFileDescriptor` (HANDOFF §2.18) — the same mechanism the
  config watcher and the menu-bar clock use. No thread, no second loop.
- **fd passing is the point** (`SCM_RIGHTS`, for handing over shm/dmabuf handles
  with no pixel copies). Whatever encoding we pick has to carry descriptors, and
  that — not the field types — is the part to prototype first.
- Verification is a Swift client against a Swift service, both ours; the
  sibling's `current-server`/`current-client` are useful as a *reference*
  behaviour to compare against, not as the counterparty.

**P2.10 — Dev session launcher. ✅ done.**
`abyss/session.sh` boots the whole shell with one command: it starts a
compositor (`--nested` inside your session, `--headless` for tests) or targets a
running one (`--attach`), then runs the desktop, the menu bar and the Dock
against it and **keeps them alive** — a component that dies is restarted, and
Ctrl-C (or quitting the compositor) tears the session down together. That
supervision is why it's the Linux stand-in for `anchor` rather than three
backgrounded commands; `--screenshot`/`--once` make it usable from CI.
Verified live by `abyss/tests/live-session.sh`: the three layer surfaces map in
their own namespaces on one output, the menu bar's exclusive zone really
reserves space (asserted on sway's *workspace rect*, since a layer surface is
never in the tree), grim pixel probes prove the stacking order, and killing the
Dock brings a new one back. See HANDOFF §2.26 and
![the session](screenshots/live-session.png).

**P2.11 — shell polish. ✅ done.**
The three self-contained loose ends from the P2.8 list, one pass:

- **Empty the Trash from the Dock.** The Trash tile now shows full or empty
  (watching `~/.Trash` through the run loop, no polling), a plain click opens it
  in a Finder window, and a **right-click** opens a tile menu whose "Empty
  Trash" permanently removes everything — `finderEmptyTrash`/`finderRemovePath`,
  the only code in the project that unlinks. Everything else still *moves* to
  the Trash. There's no confirmation dialog: a layer surface has nowhere to host
  a sheet yet, so the deliberate menu choice is the confirmation.
- **Menu-bar keyboard navigation.** The bar takes `on_demand` keyboard
  interactivity, so clicking a title hands it focus; Left/Right then walk the
  titles, Up/Down move the highlight, Return chooses and Escape closes. This
  turned up a real bug: `Popup.close()` intentionally notifies nobody, so
  Escape used to destroy the menu while the bar still thought it was open.
- **An `.app` bundle's own icon.** `AppIcon` reads `Contents/Resources` by
  convention (`<Name>.png`, `icon.png`, …), including PNG variants embedded in
  an `.icns` container; `readDirectory` resolves it once per listing and the
  Finder and desktop draw it in place of the procedural glyph. Old RLE `.icns`
  variants still need a real decoder, and anything unreadable falls back.

Verified live: `live-sway.sh --trash` (right-click → Empty Trash, asserted **on
disk**), `--menubar --keys` (the whole bar driven with no pointer), and
`--launch` (a grim pixel probe over `Marker.app`'s icon proves the bundle's own
artwork was drawn). 62 unit tests. See HANDOFF §2.27,
![the Trash menu](screenshots/live-trash.png).

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

1. ~~**libnv on Linux (the `CurrentIPC` blocker).**~~ **Closed 2026-07-27:**
   carried to Phase 3 and bound against FreeBSD's base libnv — neither vendored
   nor reimplemented. Reasoning and the Phase-3 notes are under P2.9 in §4.
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
