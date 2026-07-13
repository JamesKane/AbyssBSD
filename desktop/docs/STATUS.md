# AbyssBSD (Swift DE) — Status & Handoff

The resume-from-here doc. For the *why* and the full roadmap see [PLAN.md](PLAN.md);
for lessons learned + interop traps see [HANDOFF.md](HANDOFF.md).

Last updated: 2026-06-27.

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
  `sway`/`labwc` and `libjpeg` are **not** yet installed.
- Build: `swift build`. Tests: `swift test` (3/3 green — pure toolkit logic).
- The package layout (`Package.swift`, targets under `de/`):
  - `CWayland` — C interop: libwayland-client + generated **xdg-shell** + a
    shm-fd helper + a shim exporting libwayland's static-inline requests so
    Swift can call them (`de/cwayland/`). Regenerate protocols with
    `de/cwayland/generate-protocols.sh`.
  - `CCairo` — system cairo (pkgConfig), the Phase-1 software 2D backend.
  - `Surface` — Wayland client runtime: `Display` (connection, registry,
    globals, dispatch loop) + `Window` (xdg-shell toplevel, 2× shm buffers,
    frame-callback pacing, pointer input) + `WindowDelegate`/`PixelBuffer`.
  - `Aqua` — the toolkit: `Theme` (10.2 tokens), `Draw` (cairo gel buttons,
    traffic lights, gradients, pinstripe, text), `Scene` (the window painter),
    `AquaWindow` (a live window + working gel button).
  - `AquaDemo` — the runnable demo.

A **System Preferences** demo scene reproduces the Jaguar layout (toolbar with
Show All + favorites, the four category sections in order, separators, a 7-column
labeled icon grid with original procedural Aqua icons — `de/aqua/Icons.swift`):
![system preferences](screenshots/system-preferences.png)

## How to run

```sh
swift build && swift test

# Headless visual check — renders one frame to PNG, no compositor needed:
AQUA_RENDER_PNG=/tmp/aqua.png AQUA_SCALE=2 .build/debug/AquaDemo
AQUA_SCENE=sysprefs AQUA_RENDER_PNG=/tmp/prefs.png AQUA_SCALE=2 .build/debug/AquaDemo

# Live, against a running Wayland compositor that offers xdg-shell
# (install sway/labwc first; sets WAYLAND_DISPLAY):
.build/debug/AquaDemo                       # AQUA_SCALE=2 forces 2x; AQUA_SCENE=sysprefs
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

- **Phase 1 polish:** more widgets (checkboxes/radios, text fields, scrollbars,
  menus, sheets, brushed-metal window variant); real Lucida Grande via
  FreeType/HarfBuzz (cairo toy-text is the placeholder); per-output scale from
  `wl_output` instead of `AQUA_SCALE`; install `sway` for live testing.
- **Phase 2:** `CurrentIPC` (bind libnv) + `PoolConfig`; the shell apps (MenuBar,
  Dock, Finder, Desktop), generate the layer-shell / foreign-toplevel /
  xdg-activation protocols (XMLs already vendored in `protocols/`).
- **Phase 0 tail (the #1 risk):** Swift toolchain on FreeBSD 15 — see
  [SWIFT-ON-FREEBSD.md](SWIFT-ON-FREEBSD.md). VM/test infra to be borrowed from
  `../AbyssBSD/abyss/{vm,tests}` and adapted.
