# AbyssBSD (Swift DE) — Status & Handoff

The resume-from-here doc. For the *why* and the full roadmap see [PLAN.md](PLAN.md);
for lessons learned + interop traps see [HANDOFF.md](HANDOFF.md).

Last updated: 2026-07-19.

## What this is

A FreeBSD fork whose desktop environment is written in **Swift 6**, styled as a
faithful **Mac OS X 10.2 "Jaguar" Aqua** clone, on **Wayland**. Sibling project
`../AbyssBSD` (Rust DE) is the design source and supplies the engine we reuse
(compositor `tide`, IPC `current`, config `pool`, …). See PLAN.md for the
locked-in decisions (reuse Rust `tide` now / rewrite later; faithful clone;
Linux-first dev; full phased roadmap).

## Current state — Phase 1 vertical slice works

A Swift 6 package builds on Linux and renders a faithful Jaguar window
(![first window](screenshots/first-window.png) — glossy traffic lights,
gradient title bar, pinstriped content, a lickable blue gel button, HiDPI-crisp).

- **Swift 6.3.1** is installed on this Linux box; all client-side C libs are
  present (wayland-client, xkbcommon, cairo, freetype2, harfbuzz, libpng).
  `sway` (1.11) and `grim` are installed for live testing; `labwc` and `libjpeg`
  are not.
- Build: `swift build`. Tests: `swift test` (3/3 green — pure toolkit logic).
- The package layout (`Package.swift`, targets under `de/`):
  - `CWayland` — C interop: libwayland-client + generated **xdg-shell** + a
    shm-fd helper + a shim exporting libwayland's static-inline requests so
    Swift can call them (`de/cwayland/`). Regenerate protocols with
    `de/cwayland/generate-protocols.sh`.
  - `CCairo` — system cairo (pkgConfig), the Phase-1 software 2D backend;
    now also exposes cairo-ft for real text.
  - `CText` — real text: FreeType face management + HarfBuzz shaping behind a
    small C API (`de/ctext`), with `CFreeType`/`CHarfBuzz` systemLibraries
    supplying the pkg-config flags. Aqua paints the shaped run via cairo-ft.
  - `Surface` — Wayland client runtime: `Display` (connection, registry,
    globals, dispatch loop, per-surface pointer routing) + `Window` (xdg-shell
    toplevel, 2× shm buffers, frame-callback pacing, pointer input) + `Popup` (a
    grabbing xdg-popup child surface for menus) + `Keyboard` (`wl_keyboard` +
    xkbcommon keycode→keysym/UTF-8, via the `CXkb` system module) +
    `WindowDelegate`/`PopupDelegate`/`PixelBuffer`.
  - `Aqua` — the toolkit: `Theme` (10.2 tokens), `Draw` (cairo gel buttons,
    traffic lights, gradients, pinstripe, text, and the control set: checkbox,
    radio, slider, pop-up button, progress bar, text field, group box,
    scrollbar), `Text`
    (FreeType/HarfBuzz shaping via `CText`, painted through cairo-ft — with a
    cairo toy-text fallback when no font is found), `Scene`/`Widgets` (the window
    painters), `AquaWindow` (a live window wiring pointer/keyboard to the
    controls).
  - `AquaDemo` — the runnable demo.

A **System Preferences** demo scene reproduces the Jaguar layout (toolbar with
Show All + favorites, the four category sections in order, separators, a 7-column
labeled icon grid with original procedural Aqua icons — `de/aqua/Icons.swift`):
![system preferences](screenshots/system-preferences.png)

An **Aqua Controls** scene (`AQUA_SCENE=widgets`) shows the classic control set —
checkboxes, radio group, slider, pop-up button, a candy-striped progress bar and
OK/Cancel gel buttons — all interactive (`de/aqua/Widgets.swift` + `Draw`
primitives): ![aqua controls](screenshots/widgets.png)

A **Scroll** scene (`AQUA_SCENE=scroll`) shows a striped list in a clipped
viewport with a working Aqua scrollbar — blue gel gumdrop thumb, paired arrows at
the bottom (Jaguar's default) — driven by thumb-drag, arrow/track clicks, and the
arrow/page/Home/End keys (`de/aqua/Scroll.swift`):
![scroll](screenshots/scroll.png)

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
dismisses.

## How to run

```sh
swift build && swift test

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

- **Phase 1 polish:** the core control set now exists and is interactive
  (checkbox, radio, slider, pop-up button, progress bar, text field, group box —
  `de/aqua/Widgets.swift`) plus a **scrollbar** + scrolling list
  (`de/aqua/Scroll.swift`) and **real pop-up menus** (a grabbing xdg-popup child
  surface — `Surface.Popup` + `AquaMenu`); still to do: tabs/segmented controls,
  sheets, brushed-metal window variant, and keyboard focus/traversal between
  controls. Per-output scale from `wl_output` instead of `AQUA_SCALE`. Real text now shapes via FreeType/HarfBuzz (Noto Sans as the
  stand-in — drop Lucida Grande in via `$AQUA_FONT` for pixel-faithful text);
  remaining text refinements are device-pixel hinting under HiDPI and glyph
  caching. Live runs + **pointer and keyboard** interaction work under headless
  sway (`abyss/tests/live-sway.sh [--click] [--type]`, driving a
  wlr-virtual-pointer / a zwp-virtual-keyboard); follow-ups are hover/scroll and
  key repeat.
- **Phase 2:** `CurrentIPC` (bind libnv) + `PoolConfig`; the shell apps (MenuBar,
  Dock, Finder, Desktop), generate the layer-shell / foreign-toplevel /
  xdg-activation protocols (XMLs already vendored in `protocols/`).
- **Phase 0 tail (the #1 risk):** Swift toolchain on FreeBSD 15 — see
  [SWIFT-ON-FREEBSD.md](SWIFT-ON-FREEBSD.md). VM/test infra to be borrowed from
  `../AbyssBSD/abyss/{vm,tests}` and adapted.
