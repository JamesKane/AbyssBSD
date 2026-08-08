# AbyssBSD (Swift DE) — Status & Handoff

The resume-from-here doc. For the *why* and the full roadmap see [PLAN.md](PLAN.md);
for lessons learned + interop traps see [HANDOFF.md](HANDOFF.md).

Last updated: 2026-08-08. **Phases 0–3, 6 and 7 are complete**, and **Phase 8 —
the D-Bus bridge — is half built** (P8.1 and P8.2 of four). The Jaguar desktop
runs on our own compositor, which holds its frame contract under eleven hostile
processes; the portals hand out descriptors; and a caller on a session bus now
gets the Finder as its file chooser.
**211 unit tests + 35 live modes, green on Linux *and* FreeBSD.**
**The next task is queued: P8.3, a real GTK application** — see
[What's next](#whats-next).

## What this is

A FreeBSD fork whose desktop environment is written in **Swift 6**, styled as a
faithful **Mac OS X 10.2 "Jaguar" Aqua** clone, on **Wayland**. Sibling project
`../AbyssBSD` (Rust DE) is the **design source we rewrite from** — its compositor
(`tide`), IPC (`current`), config (`pool`) and helpers are reference
implementations to read, not code to link. **The product is Swift**, dropping to
C only where Swift can't reach (system-library shims like `de/cwayland`).
`PoolConfig` is the pattern: a Swift rewrite of the Rust `pool` that shares the
on-disk format and none of the code. See PLAN.md for the locked-in decisions
(faithful clone; Linux-first dev; full phased roadmap).

**Phase 2 built the shell** (all of it now shipped; the tour below is the
record of how, pass by pass). P2.1 added the `wlr-layer-shell` surface role to `Surface`
and a BACKGROUND **wallpaper** (`AQUA_SCENE=wallpaper`) — the shell's foundational
surface type, verified live under sway. P2.3 added **`PoolConfig`**
(`de/poolconfig/`), the Swift port of the Rust `pool`: read/write/watch the same
`~/.config/abyss/*.ini` files (mmap read, atomic-rename write, inotify/kqueue
directory watch) so Swift and Rust components stay config-compatible. P2.2 made
the wallpaper the real **Desktop**: it reads `desktop.ini` (image / gradient /
flat `bg` / built-in Jaguar blue) and **hot-reloads** when the file changes — the
watcher fd is folded into the run loop via `Display.addFileDescriptor`. Verified
live: a config gradient, then an atomic edit repaints the desktop flat. P2.4
added the **menu bar** (`AQUA_SCENE=menubar`): a layer-shell TOP strip with an
exclusive zone, the system menu (an original water-drop glyph), the bold app menu,
File/Edit/View/…, and a live clock — clicking a title opens a real Aqua dropdown
(a grabbing popup **parented to the layer surface**), verified live
(![menu bar](screenshots/live-menubar.png)). P2.5 added the **Dock**
(`AQUA_SCENE=dock`): a layer-shell BOTTOM shelf that **magnifies** under the
pointer, with running-app indicators driven by **`wlr-foreign-toplevel-management`**
(`Surface.ForeignToplevels`) and the Trash — clicking a running tile activates its
window (![dock](screenshots/live-dock.png)). P2.6 added the **Finder**
(`AQUA_SCENE=finder`) — the first shell piece that is an ordinary xdg-shell
*application* rather than a layer surface: real `readdir` listings in an Aqua
icon grid or list view, browsing in place with a toolbar Back button, a
scrollbar, and full keyboard navigation
(![finder](screenshots/live-finder.png)). P2.7 gave the desktop its **icons**
(the boot volume + `~/Desktop`, arranged top-right-down as in Jaguar), where a
double-click opens a real Finder window
(![desktop icons](screenshots/live-desktop-icons.png)). The Finder's second pass
added **spatial mode**: hide the toolbar with the title bar's pill and every folder gets its own
window, with **xdg-activation** raising one that's already open
(![spatial finder](screenshots/live-finder-spatial.png)) — which made the client
runtime multi-window (`Display` routes input **by wl_surface**). P2.10 tied it
together: **`abyss/session.sh`** boots the whole shell with one command — a
nested (or headless, or already-running) compositor plus the desktop, menu bar
and Dock, supervised and torn down together
(![the session](screenshots/live-session.png)). P2.11 tied off the shell's loose
ends: the Dock's **Trash** fills, opens and **empties** (right-click → Empty
Trash, the only code here that unlinks —
![the Trash menu](screenshots/live-trash.png)), the **menu bar is fully
keyboard-drivable** (click a title, then Left/Right/Up/Down/Return/Escape), and
an **`.app` bundle is drawn with its own icon** from `Contents/Resources`
(PNG, including PNGs embedded in an `.icns`). See
[PHASE2.md](PHASE2.md) for the ordered scope.

## It runs on FreeBSD (Phase 3 — complete)

The point of the whole exercise, on the target OS — a Swift 6 desktop under
stock sway in the FreeBSD 15 build VM, captured with grim:
![the Jaguar desktop on FreeBSD](screenshots/freebsd-desktop.png)
And the toolkit alone, headless with no compositor at all:
![an Aqua window on FreeBSD](screenshots/freebsd-window.png)

The whole **harness** passes there too — **197 unit tests and all 35 live modes**,
including pointer/keyboard injection, file operations checked on disk, and the
desktop, menu bar and Dock brought up as one session. That session is now run by
**`anchor`**, the Swift supervisor, rather than by a shell script — and the menu
bar carries real status items fed by the Swift hardware bridges:
![the session under the Swift supervisor on FreeBSD](screenshots/menubar-status.png)

## Current state — the Aqua shell runs (Phase 1 toolkit + Phase 2 shell)

A Swift 6 package builds on Linux and renders a faithful Jaguar window
(![first window](screenshots/first-window.png) — glossy traffic lights,
gradient title bar, pinstriped content, a lickable blue gel button, HiDPI-crisp).

- **Swift 6.3.1** is installed on this Linux box; all client-side C libs are
  present (wayland-client, xkbcommon, cairo, freetype2, harfbuzz, libpng).
  `sway` (1.11) and `grim` are installed for live testing; `labwc` and `libjpeg`
  are not.
- Build: `swift build`. Tests: `swift test` (197 green — Aqua toolkit + desktop
  config + menu-bar layout + Dock magnification + the Finder's listing/geometry
  model + file ops, emptying the Trash, bundle-icon lookup and `.icns`
  extraction, self-executable resolution, PoolConfig read/write/watch, and the
  CurrentIPC codec + descriptor passing, the supervisor's restart policy, the
  hardware bridges' parsing, the portal's refusals, and the screencopy pixel
  normalisation).
  **The same 197 pass on FreeBSD** in the build VM (`abyss/vm/build.sh`).
- The package layout (`Package.swift`, targets under `de/`):
  - `CWayland` — C interop: libwayland-client + generated **xdg-shell** + a
    shm-fd helper + a shim exporting libwayland's static-inline requests so
    Swift can call them (`de/cwayland/`). Regenerate protocols with
    `de/cwayland/generate-protocols.sh`.
  - `CCairo` — system cairo (pkgConfig), the Phase-1 software 2D backend;
    now also exposes cairo-ft for real text.
  - `CText` — real text: FreeType face management (regular + bold/italic/
    bold-italic) + HarfBuzz shaping behind a small C API (`de/ctext`), with
    `CFreeType`/`CHarfBuzz` systemLibraries supplying the pkg-config flags. Aqua
    paints the shaped run via cairo-ft, caching runs and shaping at device px.
  - `Surface` — Wayland client runtime: `Display` (connection, registry,
    globals, a poll-timeout dispatch loop with **key repeat**, per-surface
    pointer routing incl. **scroll-wheel**, `wl_output` scale tracking) + `Window`
    (xdg-shell toplevel, 2× shm buffers, frame-callback pacing, pointer input,
    per-output buffer scale) + **`LayerSurface`** (a `wlr-layer-shell` role for
    shell components — layer/anchors/exclusive-zone, its own configure/ack,
    reusing the buffer/frame/scale machinery) + `Popup` (a
    grabbing xdg-popup child surface for menus) + `Keyboard` (`wl_keyboard` +
    xkbcommon keycode→keysym/UTF-8 **plus the modifier state**, via the `CXkb`
    system module) +
    `WindowDelegate`/`LayerSurfaceDelegate`/`PopupDelegate`/`PixelBuffer`. Input
    routes to the window *or* the layer surface (one per process). Also
    `ForeignToplevels` (tracks running apps via
    `wlr-foreign-toplevel-management`, for the Dock), **xdg-activation**
    (`Display.activate(surface:)` — how a client raises its own window),
    **`Screencopy`** (`wlr-screencopy`: the compositor copies an output into a
    buffer we supply, normalised to cairo's layout — the compositor dictates
    stride, format and row order, so all three are handled rather than assumed),
    and an
    `addFileDescriptor` hook to fold config-watch / timer fds into the run loop.
    `Display` holds a weak **window registry** and routes pointer/keyboard by the
    `wl_surface` the `enter` events name, so one process can run many windows
    (the spatial Finder).
  - `Aqua` — the toolkit: `Theme` (10.2 tokens), `Draw` (cairo gel buttons,
    traffic lights, gradients, pinstripe, text, and the control set: checkbox,
    radio, slider, pop-up button, progress bar, text field, group box,
    scrollbar, segmented control, tab view, modal sheet), `Text`
    (FreeType/HarfBuzz shaping via `CText`, painted through cairo-ft — with a
    cairo toy-text fallback when no font is found), `Scene`/`Widgets` (the window
    painters), `AquaWindow` (a live window wiring pointer/keyboard to the
    controls).
  - `PoolConfig` — config: read/write/watch the same `~/.config/abyss/*.ini`
    files as the Rust `pool` (mmap read, atomic-rename write, directory watch via
    the `CPoolWatch` inotify/kqueue shim). Pure syscalls, no Wayland — the shell
    components and tests use it independently (`de/poolconfig/`).
  - `CPlatform` — platform facts Swift can't reach: `ap_self_executable`
    (`/proc/self/exe` on Linux, the `KERN_PROC_PATHNAME` sysctl on FreeBSD,
    whose Swift libc module surfaces no `<sys/sysctl.h>`) and **SCM_RIGHTS fd
    passing**, since `cmsg(3)` is entirely macros.
  - `Vents` + `CVents` — the FreeBSD hardware bridges: **sysctl** (Swift's libc
    module surfaces no `<sys/sysctl.h>`, so it goes through C), the **OSS mixer**
    (`ioctl` is variadic, likewise C), the **battery** off `hw.acpi.battery.*`,
    and a **devd** reader whose fd folds into the run loop for hotplug. Every
    accessor returns nil when the facility is absent, which is what lets the
    menu bar hide a status item instead of inventing a reading. `ventsctl` reads
    them by hand.
  - `Anchor` + `anchor` — the session supervisor (`de/anchor`, `de/anchorbin`):
    starts the compositor and the shell, restarts a component that dies, and
    tears the session down as a unit. Every child is a **pollable descriptor**
    (`pdfork` on FreeBSD, `pidfd` on Linux — `de/cproc`), so it is one `poll()`
    loop carrying children, the control socket and a signal self-pipe. Drive it
    with **`abyssctl status|quit`**.
  - `CurrentIPC` — the brokerless control plane (`de/currentipc`): a typed `Msg`
    (string / u64 / bool / bytes / **fd**) with its own compact wire format, a
    `Server` on `<runtime_dir>/<service>.sock`, `connect` and one-shot `call`.
    Descriptors travel over `SCM_RIGHTS`, so a message can hand over an shm or
    dmabuf handle with no pixel copies. No Wayland, no Aqua, no platform fork —
    a Swift rewrite of the sibling's `current` that shares none of its code and,
    deliberately, not its nvlist wire format either.
  - `AquaDemo` — the runnable demo.

A **System Preferences** demo scene reproduces the Jaguar layout (toolbar with
Show All + favorites, the four category sections in order, separators, a 7-column
labeled icon grid with original procedural Aqua icons — `de/aqua/Icons.swift`):
![system preferences](screenshots/system-preferences.png)

An **Aqua Controls** scene (`AQUA_SCENE=widgets`) shows the classic control set —
checkboxes, radio group, slider, pop-up button, a candy-striped progress bar and
OK/Cancel gel buttons — all interactive (`de/aqua/Widgets.swift` + `Draw`
primitives): ![aqua controls](screenshots/widgets.png)

It also has full **keyboard focus/traversal**: Tab / Shift-Tab move a soft blue
focus ring through the controls (starting on the default OK button), Space
activates the focused control (toggling a checkbox or opening the pop-up menu),
the arrow keys nudge the focused slider or radio group, and Return / Escape fire
the default (OK) / Cancel buttons. Pop-up menus and the modal sheet take the
keyboard too (menu: arrow-keys + Return/Escape during its grab; sheet:
Return/Escape as default/cancel). Here Tab has walked focus to the slider (its
ring shows) after Space unchecked the first box and the arrows drove the level up:
![keyboard traversal](screenshots/live-keys.png)

A **Scroll** scene (`AQUA_SCENE=scroll`) shows a striped list in a clipped
viewport with a working Aqua scrollbar — blue gel gumdrop thumb, paired arrows at
the bottom (Jaguar's default) — driven by thumb-drag, arrow/track clicks, and the
arrow/page/Home/End keys (`de/aqua/Scroll.swift`):
![scroll](screenshots/scroll.png)

A **Tab View** scene (`AQUA_SCENE=tabs`) shows the two joined-button controls: a
segmented control (a view switcher) and a tab view whose selected tab merges into
a content pane that changes with the selection — click or arrow-key to switch
(`de/aqua/Tabs.swift`): ![tab view](screenshots/tabs.png)

A **Sheet** scene (`AQUA_SCENE=sheet`) shows an Aqua modal sheet that slides down
from the title bar (animated), dims and blocks the parent, and dismisses via its
Cancel/Delete buttons — recording the choice below (`de/aqua/Sheet.swift`):
![sheet](screenshots/sheet.png)

The **Finder** (`AQUA_SCENE=finder`) is the first real *application*: a Jaguar
browser window over the live filesystem — a toolbar with Back and an icon/list
view switch, a white item well with original procedural folder / document /
application / volume icons, an Aqua scrollbar, and the "12 items, 39.6 GB
available" status bar (`de/aqua/Finder.swift` + the pure `FinderModel.swift`):
![finder](screenshots/finder.png) ![finder list view](screenshots/finder-list.png)

Click selects, double-click browses into a folder *in place* (the 10.2 Finder is
a browser by default — and it is standard Aqua, since brushed metal is a 10.3
texture), Back returns and re-selects the folder you came out of. Clicking the
title bar's **pill** hides the toolbar and switches to **spatial mode**, where
each folder opens in its own window, re-opening an open folder raises it (via
xdg-activation) instead of duplicating it, and the red light closes one window —
the app quits with the last. The mode persists to `finder.ini`.
![spatial finder](screenshots/live-finder-spatial.png)
(A Wayland client can't position its own windows, so the "remembered position"
part of spatial Finder waits for a compositor of our own; size/view/mode persist.)

Double-clicking something that isn't a folder **launches** it: an `.app` bundle
runs `Contents/MacOS/<name>`, an executable runs directly, and anything else goes
to the opener command (`$ABYSS_OPEN`, else `open_command` in `finder.ini`) — with
an honest "no handler" when nothing is set. The desktop icons and the **Dock**
share that path, so a Dock tile whose app isn't running launches it (another copy
of this binary in the right scene) instead of just logging.

It also **operates on files**, with the Mac's verbs rather than a PC file
manager's: **Return** renames in place (⌘O, ⌘↓ or a double-click open), **⌘⇧N**
makes a new folder and opens its name for editing with the base pre-selected,
**⌘D** duplicates, **⌘C/⌘X/⌘V** copy/cut/paste through a clipboard shared across
windows, and **⌘⌫** moves to `~/.Trash` — nothing here unlinks what you asked to
delete. Naming follows the Finder ("untitled folder 2", "Read Me copy.txt"), and
every window showing an affected folder re-reads. Here a new folder has been
created and renamed to "Reports", and Return has opened a rename on "Read Me.txt"
with just the base name selected:
![finder file operations](screenshots/live-finder-fileops.png)
The keyboard drives it all: arrows (a whole row at a time in icon view), Home /
End, Return to open, Backspace to go up, Page keys to scroll, Tab to switch view,
and type-ahead selection. It reads `finder.ini` (`view`, `show_hidden`) and starts
in `$ABYSS_FINDER_DIR` (else `$HOME`).

The window also **tracks its output's scale** (`wl_output` + `wl_surface`
enter/leave): drop it on a HiDPI (scale-2) output and it re-cuts its buffers and
repaints crisp at 2× with no `AQUA_SCALE` — that env var is now just an optional
pin. Verified live at a scale-2 headless output (`live-sway.sh widgets --hidpi`,
a 920×720 capture of the 460×360 window):
![hidpi auto-scale](screenshots/live-hidpi.png)

It also runs **live** now: `abyss/tests/live-sway.sh` brings the window up under
a headless sway and captures it with grim — a true test of the xdg-shell /
shm / frame-callback path the PNG render skips
(![live under sway](screenshots/live-sway.png)). With `--click` it drives a real
pointer click through a wlr-virtual-pointer and the counter increments
(![a registered click](screenshots/live-click.png)). With `--type` it drives
real keystrokes through a virtual keyboard into the window's text field
(![typed text](screenshots/live-type.png)) — the full `wl_keyboard` + xkbcommon
path. On the widgets scene, `--click` toggles a checkbox and moves the slider —
real pointer-driven control interaction
(![live controls](screenshots/live-widgets.png)). On the scroll scene it drags
the scrollbar thumb and the list scrolls to the bottom
(![live scroll](screenshots/live-scroll.png)). With `--menu` it opens a **real
pop-up menu** — a grabbing xdg-popup child surface — under the Appearance button,
with hover-highlight and the current item checkmarked
(![live menu](screenshots/live-menu.png)); choosing an item sets the value and
dismisses. On the tabs scene it clicks the "Columns" segment and the "Sharing"
tab (![live tabs](screenshots/live-tabs.png)). On the sheet scene it clicks
"Delete…" and the modal sheet slides out over the dimmed window
(![live sheet](screenshots/live-sheet.png)). With `--wheel` it spins the scroll
wheel (`wl_pointer.axis`) and the list scrolls to the bottom without touching the
thumb (![wheel scroll](screenshots/live-wheel.png)); with `--repeat` it holds one
key and the field fills with repeats — real **key repeat** off the compositor's
`repeat_info`, driven by a poll-timeout event loop
(![key repeat](screenshots/live-repeat.png)).

## Portals — the capability desktop (Phase 7, complete)

The brokerless answer to xdg-desktop-portal. An app asks the desktop for
something; the desktop does it and hands back **an open descriptor**. No D-Bus,
no broker, no flatpak — `abyss-portal` is a `CurrentIPC` service, and descriptors
ride over `SCM_RIGHTS`.

- **`file.open` / `file.save`** run the **Finder as the picker** and the portal
  opens what the user chose. A request has **no field for the file to open** —
  the confused-deputy bug is unrepresentable rather than guarded against.
- **`notify`** relays to the shell's toast, so a jailed app never holds the
  notification service's socket. ![a toast](screenshots/notification-toast.png)
- **`screenshot`** captures via `wlr-screencopy` (in a separate `abyssgrab`
  process, so the portal is never a Wayland client) and returns the PNG as a
  descriptor. It **names nothing**: no request field, no `path` in the reply, and
  the image is unlinked the moment it is opened — so after the reply, the
  descriptor is the only route to those bytes that exists for anyone. Here is one
  taken through the portal by a client that has no filesystem:
  ![a screenshot taken through the portal](screenshots/portal-screenshot.png)

**And the claim is checked, not asserted.** `abyssopen` enters Capsicum
capability mode *before* asking, so it has no filesystem and cannot name any
address. It then reads a file whose path it demonstrably cannot `open(2)`, and
holds a picture of a screen it demonstrably cannot `connect(2)` to. Capsicum is
FreeBSD-only, so on Linux the same binary says plainly that it is **not**
sandboxed rather than implying a confinement it doesn't have.

## How to run

```sh
swift build && swift test

# The compositor's frame contract. The first two need no compositor, GPU or
# display at all; the third runs undertow on a real wlroots headless backend.
abyss/tests/bench-metronome.sh
.build/debug/undertow bench-metronome --hz 240 --frames 600 --surfaces 512
.build/debug/undertow bench-alloc     --frames 5000 --surfaces 512
.build/debug/undertow headless --hz 60 --frames 120 --width 800 --height 600

# undertow as a real compositor, with a real client on it (starts no sway):
abyss/tests/live-undertow.sh /tmp/frame.ppm          # a real client on it
abyss/tests/live-undertow-input.sh                   # a click reaching that client
abyss/tests/live-undertow-c2.sh                      # C2: eleven hostile processes
abyss/tests/live-undertow-shell.sh /tmp/shell.ppm    # the Aqua shell composing
abyss/tests/live-undertow-places.sh                  # a window reopens where it was left
.build/debug/undertow run --hz 60 --frames 400 --width 800 --height 600 \
    --capture /tmp/frame.ppm      # then: WAYLAND_DISPLAY=<printed> AquaDemo

# The portals, end to end (each starts its own headless sway):
abyss/tests/live-portal.sh          # a client, a picker, a descriptor
abyss/tests/live-portal-dbus.sh     # ...and the same picker, over the session bus
abyss/tests/live-sandbox.sh         # ...with no filesystem at all
abyss/tests/live-screenshot.sh /tmp/shot.png    # ...and no way to reach the screen
abyss/tests/live-notify.sh          # a toast, via the portal

# Screenshots by hand — abyssgrab is a usable tool, like ventsctl/abyssctl:
.build/debug/abyssgrab /tmp/shot.png            # --output N, --cursor
.build/debug/abyssopen --screenshot > /tmp/portal-shot.png   # ...through the portal

# The whole desktop under the Swift supervisor (the replacement for session.sh):
.build/debug/anchor --display "$WAYLAND_DISPLAY"    # or --compositor CMD
.build/debug/abyssctl status                        # ... and abyssctl quit

# The control plane between two real processes (no compositor needed; also part
# of run.sh's default lane):
abyss/tests/live-ipc.sh
abyss/tests/live-anchor.sh    # supervision: restart a killed component, quit

# Every live mode in one go (pass/fail table; -o DIR keeps the PNGs + logs):
abyss/tests/run-live.sh
abyss/tests/run-live.sh -o /tmp/shots dock trash   # ... or just some of them

# The same, on FreeBSD: sync the tree into the build VM and run there.
# (Swift lives off PATH in the guest, so use the scripts rather than ssh by hand.)
abyss/vm/check.sh          # is the guest usable? packages, pkg-config, tools
abyss/tests/run.sh --vm    # build + unit tests + smoke render, in the VM
abyss/tests/run.sh --vm --live   # ... and all 35 live modes + the portals there
abyss/vm/build.sh          # quicker: just sync + swift build + swift test
abyss/vm/build.sh --no-test -- -c release

# The whole desktop, one command (nested inside your session by default):
abyss/session.sh                       # --headless / --attach; --without dock; Ctrl-C quits
abyss/tests/live-session.sh /tmp/session.png   # ... and the live test that asserts it composes

# Headless visual check — renders one frame to PNG, no compositor needed:
AQUA_RENDER_PNG=/tmp/aqua.png AQUA_SCALE=2 .build/debug/AquaDemo
AQUA_SCENE=sysprefs AQUA_RENDER_PNG=/tmp/prefs.png AQUA_SCALE=2 .build/debug/AquaDemo
AQUA_SCENE=widgets  AQUA_RENDER_PNG=/tmp/widgets.png AQUA_SCALE=2 .build/debug/AquaDemo

# Live, against a running Wayland compositor that offers xdg-shell
# (WAYLAND_DISPLAY must be set):
.build/debug/AquaDemo                       # AQUA_SCALE=2 forces 2x; AQUA_SCENE=sysprefs

# Live smoke test under a headless sway, captured with grim (no display needed):
abyss/tests/live-sway.sh sysprefs /tmp/live.png
abyss/tests/live-sway.sh --click /tmp/click.png          # drive a real pointer click
abyss/tests/live-sway.sh --type  /tmp/type.png           # drive real keystrokes
abyss/tests/live-sway.sh widgets /tmp/widgets.png --click # toggle a checkbox + move the slider
abyss/tests/live-sway.sh scroll  /tmp/scroll.png  --click # drag the scrollbar thumb
abyss/tests/live-sway.sh --menu  /tmp/menu.png            # open a real xdg-popup menu
abyss/tests/live-sway.sh tabs    /tmp/tabs.png    --click # switch a segment + a tab
abyss/tests/live-sway.sh sheet   /tmp/sheet.png   --click # open a modal sheet
abyss/tests/live-sway.sh widgets /tmp/keys.png    --keys  # Tab/Space/arrows drive focus
abyss/tests/live-sway.sh --menu  /tmp/mkeys.png   --keys  # arrow-key the pop-up menu
abyss/tests/live-sway.sh widgets /tmp/hidpi.png   --hidpi # scale-2 output → auto 2x
abyss/tests/live-sway.sh scroll  /tmp/wheel.png   --wheel # scroll-wheel the list
abyss/tests/live-sway.sh window  /tmp/rep.png     --repeat # hold a key → it repeats
abyss/tests/live-sway.sh wallpaper /tmp/wall.png         # a layer-shell BACKGROUND wallpaper
abyss/tests/live-sway.sh --reload  /tmp/wall.png         # desktop.ini config + hot-reload
abyss/tests/live-sway.sh --menubar /tmp/mbar.png         # menu bar (TOP) + open a dropdown
abyss/tests/live-sway.sh --dock    /tmp/dock.png         # Dock (BOTTOM) magnify + foreign-toplevel
abyss/tests/live-sway.sh --finder  /tmp/finder.png       # browse a seeded dir: open, Back, list view
abyss/tests/live-sway.sh --finder --keys /tmp/fkeys.png  # ... and drive it from the keyboard
abyss/tests/live-sway.sh --spatial /tmp/spatial.png      # spatial: 2 windows, raise, close one
abyss/tests/live-sway.sh --fileops /tmp/fileops.png      # new folder/rename/copy/trash, checked on disk
abyss/tests/live-sway.sh --desktop /tmp/desk.png         # desktop icons: select, open a Finder window
abyss/tests/live-sway.sh --launch  /tmp/launch.png       # double-click an .app bundle / a document
abyss/tests/live-sway.sh --trash   /tmp/trash.png        # Dock Trash: right-click -> Empty Trash
abyss/tests/live-sway.sh --menubar --keys /tmp/mbk.png   # drive the menu bar from the keyboard alone

# Finder (an ordinary xdg-shell app) over a real directory:
ABYSS_FINDER_DIR=~/Documents AQUA_SCENE=finder .build/debug/AquaDemo

# Wallpaper (layer-shell) PNG preview, no compositor:
AQUA_SCENE=wallpaper AQUA_RENDER_PNG=/tmp/wall.png .build/debug/AquaDemo
# Config-driven live: point AquaDemo at a config dir with a desktop.ini
ABYSS_CONFIG_DIR=~/.config/abyss AQUA_SCENE=wallpaper .build/debug/AquaDemo
```

## Conventions (inherited from the sibling, adapted to Swift)

- **Minimal third-party deps.** New capability = hand FFI to a mature C system
  library (or vendored C), not a SwiftPM registry dep. See `CWayland`/`CCairo`.
- **Wrap in phase 1, rewrite in Swift later.** e.g. cairo now; a Swift/GPU
  renderer later.
- **The static-inline trap:** every `wl_*` request and `*_add_listener` is
  `static inline` and invisible to Swift — add a one-line `aw_*` wrapper in
  `de/cwayland/cwayland_shim.c` (and a decl in `cwayland.h`) and call that.
- **Listener lifetime:** libwayland keeps the listener pointer; `Display`
  heap-allocates each listener struct and frees them in `deinit`. Pass the owner
  via `Unmanaged.passUnretained(...).toOpaque()` as the `data` arg.

## What's next

**Phases 0–3, 6 and 7 are complete.** Phase 8 is half built, and its remaining
two passes are the only queued work.

> **Start here: P8.3 — a real GTK application.** `GtkFileChooserNative` on a
> stock GTK 3 app, running as a client of `undertow`, picking a file through the
> Finder. The guest already carries `gtk3`. **It is the pass that deletes
> PHASE7 §6.7's caveat** — P8.2 proved the protocol with `gdbus`, which is a
> D-Bus client, not an application. Read **HANDOFF §2.39** before writing any of
> it, and expect GTK to probe interfaces we do not have yet (PHASE8 §6.4).
> Then **P8.4**: `anchor` starts the bus alongside the shell.
>
> The rest of this section is the record of what got built, newest last.

**Phase 7 (portals) — all five passes.**
An app asks the desktop for a file, a notification or a screenshot, and gets back
a **descriptor**: no D-Bus, no broker, no flatpak. The screenshot goes furthest —
the request names nothing, the reply names nothing, and the image is unlinked the
moment it is opened, so the descriptor is the only route to it that exists.

**Phase 6 — `undertow`, the Swift compositor — is COMPLETE**
([PHASE6.md](PHASE6.md), passes P6.1–P6.7). Three risks were spiked on both
platforms before the plan was written: Swift imports wlroots **directly** (no
bindgen, unlike the sibling — the C shim is a ~15-line listener trampoline),
plain Swift measures **zero allocations** on the present path (so Embedded Swift
is struck), and the guest already carries wlroots 0.19.3, the same version as the
dev box.

**P6.1 is done — the contract before the pixels.** The metronome (EWMA vblank
prediction, a three-term adaptive latch margin, the late-latch loop) and the
flight recorder that makes C1–C5 falsifiable, with no wlroots, no GPU and no
display involved. It is a build gate now, in `run.sh`'s default lane:

```
undertow bench-metronome — 240Hz, 600 frames, 512 surfaces (after 75 warmup)
  wall clock        2499 ms  (nominal 2499 ms)
  period estimate   4166.66 us  (nominal 4166.66 us, 671 samples)
  composite cost    p50 14.11 us   p99 32.98 us   p99.9 55.43 us
  missed flips      0 of 600  (0 per mille)
```

**P6.2 is done too — the wlroots bridge.** Swift imports wlroots directly, so
the entire binding is **29 lines of C**: `wl_signal_add` is a static inline and
`wl_container_of` is a macro, so every wlroots event arrives through one
trampoline. The metronome drives the backend rather than rendering from its
`frame` handler, which is what makes the schedule ours:

```
undertow headless — HEADLESS-1 800x600 @ 60Hz, 120 frames, 128 surfaces
  wall clock        2000 ms  (nominal 1999 ms)
  period estimate   16666.66 us  (nominal 16666.66 us, 135 samples)
  missed flips      0 of 120  (0 per mille)
  presented frames  yes
  vblank source     nominal grid — this backend reports no hardware clock
```

**P6.3 is done — it is a compositor.** `wl_compositor` + `wl_shm` + `xdg_shell`,
a socket, and our own structure-of-arrays scene (not `wlr_scene` — that is the
part DESKTOP.md reserves to us). AquaDemo connects as an ordinary client and its
window is textured into our frame:

![an Aqua window on undertow](screenshots/undertow-first-client.png)

`abyss/tests/live-undertow.sh` is the first test in this project that **starts no
sway at all**.

**P6.4 is done — input.** A `wl_seat`, a compositor-drawn cursor, click-to-focus
and raise. The pointer is driven by the harness's existing `vpointer`,
**unmodified**: it speaks `wlr-virtual-pointer`, so implementing that protocol's
server side means the tool that has driven sway since Phase 1 drives us too.

![a click through undertow](screenshots/undertow-input.png)

**P6.5 is done — C2, the claim the architecture exists to make good.** Eleven
real hostile processes (socket-flooders that never wait for a reply, a zombie, a
CPU-spinning never-reader, a connect/disconnect churner) against the compositor
while a healthy client keeps drawing: **0 missed of 600 frames**, on both
platforms, with the healthy window still composited at the end.

Getting there needed a real fix, found by measurement: dispatching client traffic
*after* the deadline collapsed under 32 flooders (600/600 missed). Moving it into
the pre-deadline slack survives **64** at every rate we target. So the
reactor/present thread split P6.2 flagged is **not needed yet — and now we know
why rather than hoping**; the debt is re-scoped to Phase 4, when a GPU present
path puts far more work on that thread.

**P6.7 is done, and with it Phase 6.** `xdg_toplevel.move` is honoured and a
window's position is remembered in `~/.config/abyss/windows.ini`, so a folder's
window reopens where it was left — the debt HANDOFF §2.22 recorded in Phase 2,
when the spatial Finder found that *"a Wayland client cannot position its own
windows … position waits for Phase 6"*. And `wlr-screencopy`'s server half is in,
so P7.5's `abyssgrab` captures `undertow` **unmodified** and the screenshot
portal works against our compositor (PHASE7 §6.6, closed).

**P6.6 — the Aqua shell composes on `undertow`.** The server halves of
`wlr-layer-shell`, foreign-toplevel and xdg-activation, so the wallpaper, menu
bar and Dock — three Phase-2 clients, unmodified — come up on our own compositor:

![the Aqua shell on undertow](screenshots/undertow-shell.png)

The menu bar's exclusive zone reserves its strip (usable area `0,22,800x578`),
the desktop's `-1` zone paints underneath it, and the Dock overlaps without
reserving. That usable rectangle is the same §2.26 check `live-session.sh` has
made against sway since Phase 2 — now made against us.

**Phase 8 — the D-Bus bridge — is now scoped and half built**
([PHASE8.md](PHASE8.md), passes P8.1–P8.4). It deletes PHASE7 §6.7's caveat: a
stock GTK/Qt app gets the Finder as its file chooser. **We are the portal** —
`abyss-dbus` owns
`org.freedesktop.portal.Desktop` and translates to the existing `abyss-portal`,
rather than backing stock `xdg-desktop-portal` (which would put a broker on the
path and leave two portal frontends with different behaviour).

**P8.1 is done — `de/dbus` speaks D-Bus with no dependency at all** (only
`CPlatform`, for the `SCM_RIGHTS` helpers `CurrentIPC` already uses). No libdbus
(discouraged upstream), no GDBus (drags in the GLib/GTK stack this project
rejects), no sd-bus (systemd) — the Linux box does not even have `dbus-devel`
installed.

And it is checked against somebody else's implementation, never our own on both
ends: `dbus-daemon` is the bus, `dbus-send` calls us, and **`gdbus` — GLib's
D-Bus — round-trips the `a{sv}` options dictionary every portal method takes and
parses our introspection XML with its own parser** (`abyss/tests/live-dbus.sh`).

**P8.2 is done — `org.freedesktop.portal.Desktop` is ours.** `abyss-dbus`
answers `FileChooser.OpenFile` and `SaveFile`, runs the `Request`/`Response`
object lifecycle, and translates to the same `abyss-portal` and the same Finder
our own apps get. `abyss/tests/live-portal-dbus.sh` runs five real processes —
`dbus-daemon`, sway, `abyss-portal`, `abyss-dbus`, a caller — and drives a
D-Bus `OpenFile` through to a file a human picked, with `gdbus` decoding the
`Response` signal independently of us.

**The portal API has two ways to hang, and each is invisible to the client shape
that exposes the other.** Both end the same way: waiting for a signal that never
comes, with no error — P6.3's missing-configure failure shape again.

1. The Request path is `…/request/SENDER/TOKEN`, built from the **caller's**
   unique name and the caller's own `handle_token`, because a modern client
   computes it itself and subscribes *before* calling. Derive it any other way
   and that client listens where nothing is emitted.
2. An older client has no token: it calls, takes the handle it is given, and
   subscribes *then*. So the picker must not run inside the method handler —
   blocking there answers the dialog before the caller knows where to listen.

Both are driven by the live script, and both were **injected once** to prove the
script can fail (§2.37): running the picker inside the handler left the late
client waiting its full 90s.

**And one claim in the plan turned out to be wrong, which is worth recording.**
PHASE8 §1 promised a foreign app "a descriptor as its answer". Reading the
interface definition off disk rather than from memory
(`/usr/share/dbus-1/interfaces/org.freedesktop.portal.FileChooser.xml`) shows
`Response` carries `uris` — strings — and no descriptor in any version. So the
bridge closes the fd `abyss-portal` opened and forwards the path. **Their answer
is a name; ours is a capability** — it is why flatpak needs a FUSE daemon to make
those names mean anything, and why `abyssopen` can read a file from inside
Capsicum with no filesystem at all. The confused-deputy property still survives
the hop: a foreign app names a *directory*, never a file (PHASE8 §6.6).

**Next: P8.3** — a real GTK application, which is the pass that actually deletes
PHASE7 §6.7's caveat, and nothing before it does.

**The other directions stay open:** Phase 4 (Mac Pro bring-up — real GPU,
hardware cursor, `rtprio`, and where Phase 6's C1 measurements should be
repeated) and Phase 5 (the installer).

**The other two directions remain open and independent** (HANDOFF §5):

- **Phase 4 — Mac Pro bring-up.** Real hardware, and where the volume/battery
  status items finally read a real mixer and battery instead of reporting
  absent. Biggest remaining risk: `amdgpu` `si_support` for the FirePro D-series.
- **The D-Bus/portal bridge** — Phase 8, now at P8.2. A caller on the session bus
  gets the Finder; what remains is proving it with GTK itself (P8.3) and having
  `anchor` start the bus alongside the shell (P8.4).
(What Phase 6 finally unblocks, for the record: remembered window positions for
the spatial Finder and dragging desktop icons — both things a Wayland *client*
cannot do (HANDOFF §2.22) — plus the one Phase-7 debt, a server half for
`wlr-screencopy` or its `ext-image-copy-capture-v1` successor. They are P6.7.)

**Standing smaller items:** golden-image tests (the deterministic PNG scenes,
diffed in CI — the cheapest guard against silent visual regressions, and the
toast and status items just widened that surface); a real Aqua save panel to
replace `file.save`'s ⌘S stopgap; a confirmation sheet for Empty Trash.

**The rule:** a pass isn't done until `abyss/tests/run.sh --vm --live` is green.
Two Phase-3 bugs were invisible on Linux and failed only on FreeBSD.
