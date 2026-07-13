# AbyssBSD (Swift DE) — Handoff & Lessons

What this session built, what we learned doing it, and where the traps are.
Read [STATUS.md](STATUS.md) for the current build state and [PLAN.md](PLAN.md)
for the multi-year roadmap; this doc is the *practical knowledge* layer.

---

## 1. What got built (Phase 0–1)

A working Swift 6 desktop foundation that builds and tests clean on Linux and
renders faithful Jaguar UI:

- **C interop** (`de/cwayland`, `de/ccairo`) — libwayland-client + generated
  xdg-shell + a Swift-callable shim; system cairo as the software 2D backend.
- **`Surface`** — a real Wayland client runtime: connect, registry/globals,
  xdg-shell toplevel, double-buffered `wl_shm`, frame-callback pacing, pointer
  input, a dispatch loop.
- **`Aqua`** — the toolkit: 10.2 theme tokens, cairo drawing grammar (gel
  buttons, glassy traffic lights, gradients, pinstripe), two scenes (a simple
  window and a **System Preferences** clone), and original procedural pref icons.
- **`AquaDemo`** — runs live against a compositor *or* renders a scene to PNG.
- **Infra** — borrowed/adapted FreeBSD VM + test harness under `abyss/`, plus
  the `docs/`.

Two screenshots in `docs/screenshots/` are the evidence: `first-window.png`,
`system-preferences.png`.

---

## 2. Lessons that cost time (read before you code)

### 2.1 The static-inline trap (the big one)
Every libwayland request (`wl_surface_commit`, `wl_registry_bind`, …) **and**
every `*_add_listener` is a `static inline` in the generated headers. Swift's C
importer **cannot see `static inline` functions** — they simply don't exist from
Swift. The fix is a thin C shim (`de/cwayland/cwayland_shim.c`) that exports real
`aw_*` wrappers. Two payoffs worth remembering:
- **One generic `aw_add_listener`** works for *every* proxy — add_listener is
  always `wl_proxy_add_listener((wl_proxy*)obj, (void(**)())listener, data)`.
- For requests you still need one wrapper each, but they're one line. To add a
  protocol: vendor its XML in `protocols/`, add it to
  `de/cwayland/generate-protocols.sh`, list the generated `.c` in `Package.swift`,
  and add `aw_*` wrappers for the requests you call.

### 2.2 Listener lifetime + the data pointer
libwayland **keeps the listener struct pointer** for the proxy's life. A Swift
stored property's address isn't guaranteed stable, so `Display` heap-allocates
each listener (`UnsafeMutablePointer.allocate`), keeps it, and frees it in
`deinit`. The owner object is passed as the listener `data` via
`Unmanaged.passUnretained(self).toOpaque()` and recovered in the
`@convention(c)` callback with `Unmanaged.fromOpaque(...).takeUnretainedValue()`.
(`passUnretained` because the owner outlives the proxy; don't retain.)

### 2.3 Build C listener structs by zero-init, not memberwise
Imported C structs get a synthesized `init()` that zeroes. Use
`var l = wl_pointer_listener(); l.enter = {…}; l.button = {…}` and leave the rest
nil. This is robust against libwayland adding fields (the pointer listener has
~11 across versions); the memberwise initializer would break on a version bump.

### 2.4 Swift 6 strict concurrency bites global state
- Value types used in `static let` theme/data tables must be **`Sendable`**
  (`Color`, `PrefIcon`). Tuples of Sendable are Sendable, so marking the enum was
  enough for the `prefSections` tables.
- `stderr`/`stdout` are non-Sendable globals — using them tripped the checker;
  we use `print` (or wrap a FILE* if real stderr is needed later).

### 2.5 cairo's `arc` connects from the current point
`cairo_arc` does **not** start a new subpath — it draws a line from the current
point to the arc start. After `cairo_show_text` (which leaves a current point),
the next icon's leading `arc` drew a stray line across the window. Fixes:
`cairo_new_path()` at the start of each icon, and `cairo_new_sub_path()` before
arcs that follow a `fill_preserve`. Symptom to recognize: a thin diagonal line in
the *stroke colour* of a shape, originating from a previously drawn label.

### 2.6 Real text: give cairo its OWN FT_Face (the shared-face trap)
Text now shapes with HarfBuzz and paints via cairo-ft (`de/ctext` + `Aqua/Text`).
FreeType/HarfBuzz/cairo-ft are **real** exported functions — no static-inline
trap — so Swift could call them directly; we keep a thin C shim only because the
FreeType header macros (`ft2build.h` + `FT_FREETYPE_H`) and the hb buffer
lifecycle are awkward from Swift.

The trap that cost time: an `FT_Face` has a single mutable pixel size. We
resized the face for HarfBuzz shaping (`hb_ft_font_create_referenced` even
installs its own `FT_Size`) while *also* handing that same face to cairo via
`cairo_ft_font_face_create_for_ft_face`. cairo assumes it owns its face's size
across all point sizes; when shaping mutated it underneath, cairo rendered
glyphs at stale cached sizes — the symptom was labels with mixed glyph sizes and
blown-out letter spacing, and it was *order-dependent* (the same string drew
fine the first time, wrong the second). Fix: the shim opens **two** faces per
font from the same file — one it resizes for shaping, one it never touches and
hands to cairo. Rule: never mutate an FT_Face you've given to cairo.

Include/link flags stay portable via `CFreeType`/`CHarfBuzz` systemLibraries
(pkgConfig `freetype2`/`harfbuzz`) that `CText` depends on — no hard-coded
`/usr/include` paths, so the FreeBSD port inherits the right flags. No Lucida
Grande ships free; Noto Sans is the stand-in, overridable via `$AQUA_FONT`
(colon-separated `$AQUA_FONT_FALLBACK` for coverage).

### 2.7 The window must be owned across the event loop (live-only crash)
`Display.window` and `Window.delegate` are both **weak** (deliberately — the
window holds its delegate and Display references it back, so weak breaks the
cycle). That means the *caller* is the sole owner of the window. `AquaDemo`
originally did `guard let _ = AquaWindow(...)`, discarding that only strong
reference; the window (and the `Unmanaged.passUnretained(self)` data pointers
its Wayland listeners carry) was freed before the first `xdg_surface.configure`,
so the configure callback did `takeUnretainedValue()` on freed memory →
`incrementSlow` SIGSEGV. Fix: bind it and `withExtendedLifetime(window) {
display.run() }`. The PNG path never builds a `Window`, so only the live run
surfaced this — see §3.

### 2.8 The linter lies about C includes
The standalone clang linter flags `'cairo.h' file not found` etc. because it
doesn't know SwiftPM injects `-Iinclude` / pkg-config flags. Ignore those;
trust `swift build`.

---

## 3. How we verify

**Offscreen PNG path** (fastest fidelity loop): `AQUA_RENDER_PNG=/path
[AQUA_SCENE=sysprefs] [AQUA_SCALE=2] .build/debug/AquaDemo`. The same `paint*`
functions drive both the live Wayland window and the PNG, so the PNG is a true
render of production code, viewable inline. Consider golden-image tests later.
It renders straight to a cairo surface, though — it never builds a
`Surface.Window`, so it can't catch bugs in the live path.

**Live path** (`sway` is now installed): `abyss/tests/live-sway.sh
[window|sysprefs] [out.png]` runs AquaDemo against a headless sway (pixman
software renderer, `--unsupported-gpu` — no GPU touched) and grabs the frame
with grim. This exercises what the PNG path can't: the xdg-shell handshake, shm
double-buffering, frame-callback pacing, configure/resize, and object lifetimes
(it's what caught the §2.7 crash). Caveat: the headless backend attaches no
input devices (seat `capabilities:0`), so the pointer path isn't exercised —
`--click` drives sway's cursor over IPC but the events aren't delivered; testing
input headlessly needs a wlr-virtual-pointer client (TODO). Evidence:
`docs/screenshots/live-sway.png`.

Full loop: `sh abyss/tests/run.sh` (build + `swift test` + a headless smoke
render). Tests are pure toolkit logic (no compositor).

---

## 4. Fidelity notes (from the Jaguar reference)

What matched the real 10.2 screenshot once corrected: **lighter** smooth
title-bar gradient with a near-white top edge and faint pinstripes; **glassy
"water-drop" traffic lights** (vertical body gradient + broad upper sheen + a
small upper-left specular dot); **flat light-grey** system-window body (not white,
no blue pinstripe); **rounded top / square bottom** corners; the toolbar toggle
**pill** at the title bar's right. The reference is the spec — refine `Theme` and
`Draw` against it, not from memory.

Known-not-faithful, on purpose:
- **Icons are original procedural glyphs**, not Apple artwork (copyright). They
  read correctly but aren't pixel-identical.
- **Text is real** now (FreeType/HarfBuzz shaping via cairo-ft) but the face is
  **Noto Sans**, not Lucida Grande (which ships with no free equivalent) — the
  metrics/letterforms differ. Set `$AQUA_FONT` to a Lucida Grande file for
  pixel-faithful text. cairo toy-text remains only as the no-font fallback.

---

## 5. What I'd do next (in order)

1. **Real text** — ✅ done: FreeType + HarfBuzz shaping painted via cairo-ft
   (`de/ctext`, `Aqua/Text`). Noto Sans stands in for Lucida Grande (`$AQUA_FONT`
   to override). Follow-ups: device-pixel hinting under HiDPI, glyph caching,
   and bold/italic faces (only regular is loaded today).
2. **Live compositor run** — ✅ done: `abyss/tests/live-sway.sh` runs AquaDemo
   under headless sway + grim (found and fixed the §2.7 lifetime crash;
   validated xdg-shell configure/resize + shm + frame pacing). Remaining: an
   interaction pass over real input — headless sway has no input device, so
   wire a wlr-virtual-pointer client (or run nested with devices) to drive
   clicks/hover.
3. **Per-output scale** from `wl_output` instead of `AQUA_SCALE`.
4. **More widgets** — checkboxes/radios, text fields, scrollbars, menus, sheets,
   brushed-metal window variant — toward a real toolkit.
5. **Golden-image tests** — snapshot the PNG renders and diff in CI.
6. **Phase 2** — `CurrentIPC` (bind libnv) + `PoolConfig`, then the shell apps
   (Dock, MenuBar, Finder). The extra protocol XMLs (layer-shell,
   foreign-toplevel, xdg-activation) are already vendored in `protocols/`.
7. **The standing risk** — keep chipping at Swift-on-FreeBSD
   ([SWIFT-ON-FREEBSD.md](SWIFT-ON-FREEBSD.md)); nothing ships to the target
   until it's resolved.

---

## 6. Gotchas inherited from the sibling (still true here)

- `abyss/vm/sync.sh` uses `rsync --delete` — it wipes the in-VM target dir; the
  Swift `.build/` is gitignored and absent on a fresh sync, so rebuild after the
  last sync.
- The VM home defaults to `../abyss-swift-vm` (separate from the sibling's
  `../abyss-vm`) so we don't clobber the Rust project's VM. Set
  `ABYSS_VM_HOME=../abyss-vm` to reuse that already-provisioned box.
- The repo is `git init`'d but **not committed** — no commit was requested.

---

## 7. Pointers

- Architecture canon (Rust sibling): `../AbyssBSD/abyss/docs/{DESKTOP,SEAMS}.md`.
- Reusable engine to adopt in Phase 3: `../AbyssBSD/abyss/de/{tide,…}`,
  `../AbyssBSD/abyss/ipc/{current,pool,shmring}`.
- Agent memory: `abyssbsd-swift-project`, `abyssbsd-swift-status`.
