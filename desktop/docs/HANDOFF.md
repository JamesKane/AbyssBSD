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
  xdg-shell toplevel **and grabbing xdg-popup** child surfaces (menus),
  double-buffered `wl_shm`, frame-callback pacing, pointer **and keyboard** input
  (the latter translated through xkbcommon) with per-surface routing,
  **per-output HiDPI scale** (`wl_output` + `wl_surface` enter/leave), a dispatch
  loop.
- **`Aqua`** — the toolkit: 10.2 theme tokens, cairo drawing grammar (gel
  buttons, glassy traffic lights, gradients, pinstripe) and the classic control
  set (checkbox, radio, slider, pop-up button, progress bar, text field, group
  box, scrollbar, segmented control, tab view, modal sheet) with **keyboard
  focus/traversal** (a soft `Draw.focusRing`, Tab/Shift-Tab through `WidgetFocus`,
  Space/arrows/Return/Escape to drive controls, menus and sheets), six scenes (a
  simple window, a **System Preferences** clone, an **Aqua Controls** gallery, a
  **Scroll** list, a **Tab View**, and a **Sheet**), and original procedural pref
  icons.
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

### 2.3 Build C listener structs by zero-init — but fill every event the
### compositor emits
Imported C structs get a synthesized `init()` that zeroes. Use
`var l = wl_pointer_listener(); l.enter = {…}; l.button = {…}` (not the
memberwise initializer, which would break when libwayland adds fields — the
pointer listener has ~11 across versions). **But a zeroed slot is a NULL
callback, and libwayland calls `wl_abort` the moment it dispatches an event
whose slot is NULL** (`listener function for opcode N is NULL`). So every event
the compositor can send *at the version you bound* needs a handler — a no-op is
fine. This bit us on `wl_pointer`: we bound the seat at v5 and handled
enter/leave/motion/button but left `frame` (opcode 5, sent after every event
group by wlroots) and the axis events NULL → SIGABRT on the first pointer input.
It hid until real input existed (headless sway has no pointer; the PNG path has
no seat) — the virtual-pointer interaction pass surfaced it (see §3). `wl_seat`
has the same trap with its `name` event (v2+), which is why we set `sl.name`.

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

Related: `Draw.fillVerticalGradient` uses `fill_preserve` (so callers can stroke
the same path). If you fill several shapes in a loop with it, **clear the path
between them** (`cairo_new_path`) — otherwise each new rectangle *unions* with the
preserved ones and the fill repaints them all. This bit the segmented control:
every segment came out the selected colour because the last (selected) fill
covered the whole accumulated path.

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

**Refinements (later pass).** Three things, all in `Aqua/Text` + `de/ctext`:
- **Bold/italic.** `at_font_shape` takes a style; the C face table is flat and
  each `at_glyph.face` indexes it directly, so styles are just ordered index
  groups (regular / bold / italic / bold-italic), each loading its own primary
  ($AQUA_FONT_{BOLD,…} or sans candidates) with the regular fallbacks appended.
  A style with no own face resolves against regular — text always renders.
  `Text.Style` threads through `Draw.text/textLeft/textWidth`; first use is the
  sheet's bold question.
- **Shaped-run cache.** Runs are position-independent (advances keyed only by
  string+px+style), so `Text.shape` memoises them — static labels were re-run
  through HarfBuzz every redraw. Wholesale-cleared past a cap.
- **Device-pixel hinting.** cairo already rasterises at device px (the CTM scales
  the font), but we *shaped* at logical px, so advances were computed on a coarser
  grid than the glyphs were drawn on. Now `Text.renderScale` (set by the renderer
  each frame) makes `Text.px` return device px; shaping happens there, and
  `drawShaped` divides positions/advances **and the font size** by the scale so
  the run renders in *user* space — the CTM scales it back to device px. Doing it
  in user space (not by resetting to identity) is essential: the sliding sheet
  draws text under a translated CTM, and an identity reset would misplace it.
  `Draw.textWidth`/centring convert the device-px width/metrics back to logical.
  At scale 1 every path is a no-op, so 1× output is byte-identical.

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

### 2.8 Keyboard: xkbcommon owns the keycode→text translation
`wl_keyboard` hands the client a **keymap over a fd** (`keymap` event: format,
fd, size) plus raw **evdev** keycodes (`key` event) and a running modifier mask
(`modifiers` event). None of that is text — you translate with **xkbcommon**
(`de/cxkb`, `Surface/Keyboard.swift`):
- mmap the keymap fd `PROT_READ, MAP_PRIVATE` (the compositor may seal it
  read-only), `xkb_keymap_new_from_string`, `xkb_state_new`. Always `close(fd)`.
- `xkb_state_key_get_one_sym` / `xkb_state_key_get_utf8` per key. The **evdev →
  xkb keycode offset is +8** — forget it and every key resolves one off.
- feed every `modifiers` event to `xkb_state_update_mask` or Shift/Caps never
  register (uppercase silently fails).

Unlike libwayland's requests, xkbcommon symbols are **ordinary exported
functions**, so `CXkb` is a plain system module Swift calls directly — no `aw_*`
shim. `wl_keyboard` is bound at seat v5, so the NULL-slot trap (§2.3) applies:
all six events (keymap/enter/leave/key/modifiers/**repeat_info**) need a handler.
Verified live by `--type` (§3); found no new crash — the §2.3 discipline held.

### 2.9 One layout function feeds both paint and hit-test
The widgets scene keeps all control geometry in a single pure function
(`widgetsLayout(w:h:) -> WidgetLayout`); `paintWidgets` draws from it and
`AquaWindow` hit-tests against the *same* returned rects (stored each render).
This is the immediate-mode discipline that keeps "what you see" and "what you can
click" from drifting: never compute a control's rect twice. It also makes the
geometry unit-testable with no compositor (`testWidgetsLayoutIsSaneAndInBounds`
checks counts, in-bounds, stacking, button order). Interaction state is a plain
`Sendable` struct the delegate owns; the slider maps pointer-x through the same
thumb-radius inset the painter uses, so drag tracks the thumb exactly.

### 2.10 Pop-up menus: an xdg-popup child surface with a grab
A real menu is a *second* `wl_surface` (`Surface.Popup`), not something painted
into the window. The moving parts that each bit you if missed:
- **Positioner.** `xdg_wm_base.create_positioner` → set size + `anchor_rect` (the
  button's rect, in the parent's logical surface coords) + `anchor`/`gravity`
  (BOTTOM_LEFT / BOTTOM_RIGHT drops the menu below, left-aligned) + a constraint
  adjustment (slide/flip) so it stays on-screen. Then `xdg_surface.get_popup`
  with the *parent's* xdg_surface. Destroy the positioner immediately after.
- **Grab needs the click's serial.** `xdg_popup.grab(seat, serial)` must use the
  serial of the pointer button event that opened the menu, or the compositor
  refuses the grab (or won't dismiss on outside-click). `Display` stashes
  `lastPointerSerial` from every `wl_pointer.button`/`enter`; `Popup.init` grabs
  with it. The grab is also what makes the compositor send `popup_done` on an
  outside click.
- **Input routes by surface.** `wl_pointer.enter` carries *which* surface the
  pointer entered (imported as `OpaquePointer?`, not a raw pointer — that's a
  compile error waiting to happen). `Display` compares it to the window vs the
  active popup surface and routes motion/button to the right delegate. Without
  this, menu hover/selection silently goes to the window.
- **Teardown is a lifecycle trap.** `popup_done` means "dismissed" but you still
  own the proxies and must `xdg_popup.destroy` them. Guard teardown with a single
  `tornDown` flag and run it from `popup_done`, an explicit `close()` (after a
  choice), *and* `deinit` — and tear down the proxies BEFORE notifying the
  delegate, since the delegate may drop its last strong ref to the popup during
  that call.

`Popup` reuses the window's `ShmBuffer` + frame-callback pacing (so hover-
highlight redraws don't stall). `AquaMenu` is the `PopupDelegate` that draws the
items, tracks the hovered row, checkmarks the selection, and reports a choice.

### 2.11 Protocol-extension methods static-dispatch (the sheet animation trap)
A method that exists **only** in a protocol extension (not in the protocol's
requirement list) is **statically dispatched** when called through the
protocol-typed reference. Adding an optional delegate hook as just
`extension WindowDelegate { func windowDidRenderFrame(...) {} }` meant
`delegate?.windowDidRenderFrame(self)` always called the *no-op default*, never
the conformer's override — the sheet sat at progress 0 (invisible) because its
per-frame tick never ran. Fix: declare the method in the `protocol` body too (a
requirement), keeping the extension default for optionality → dynamic dispatch to
the override. Rule of thumb: if a conformer must be able to override it, it
belongs in the protocol body, not only the extension.

Related mechanism: **animation is driven off the frame callback.** `Window`
calls `windowDidRenderFrame` from `frameDone` (after `framePending = false`), so
the delegate can advance state and `setNeedsDisplay()` there safely — doing that
from inside `render()` would re-enter `renderAndCommit` (framePending is still
false mid-render). The loop self-sustains only while the delegate keeps calling
`setNeedsDisplay`, so it stops cleanly when the animation completes. (This also
confirmed headless sway *does* deliver frame callbacks — the interactive scenes'
redraws already depended on it.)

### 2.12 Keyboard focus/traversal: Shift-Tab is its own keysym, and the popup
### grab still routes keyboard to *your* client
Focus traversal (`WidgetFocus` + `Draw.focusRing`) needed two things worth
noting. (1) **Shift-Tab does not arrive as Tab-with-a-modifier** — xkbcommon
resolves it to a *distinct* keysym, `XKB_KEY_ISO_Left_Tab` (`0xfe20`). Our
`KeyEvent` carries no modifier mask, so back-traversal keys off that keysym
(`KeySym.backTab`), not "Tab + Shift". (2) **A grabbing xdg-popup does not
steal keyboard from your process.** While the pop-up menu's grab is active,
`wl_keyboard.key` events still come to the same client and Display still routes
them to `window.keyEvent` — so AquaWindow forwards them to the open `AquaMenu`
(arrow-keys move the highlight, Return chooses, Escape closes). Verified live by
`--menu --keys`: with the pointer kept off the menu, Down+Enter alone selected
"Graphite" and dismissed the popup. Button "press" feedback from the keyboard
uses the real key **release** (Space/Return down → `okPressed = true`, up →
false), so `keyEvent` must act on both edges for the widgets scene (the other
scenes still act on press only).

### 2.13 Per-output HiDPI scale: read the proxy from the callback, not a capture
The window follows its output's scale (`wl_output.scale`/`done` +
`wl_surface.enter`/`leave`; buffers are re-cut and `wl_surface.set_buffer_scale`
updated). Two things bit:

- **A C listener callback can't capture Swift context.** The `wl_output` done/
  scale handlers are `@convention(c)` function pointers, so `{ data, _ in … o … }`
  (closing over the bound proxy `o`) fails to compile. libwayland already hands
  the proxy back as the callback's **2nd argument** — use *that* (as it does for
  `wl_pointer.enter`'s surface), and key your per-output table off it.
- **`wl_output` batches; scale is only current on `done`.** Stage the incoming
  factor in `pendingScale` and commit it on `done` (that's also when you
  re-evaluate the window's scale). The HiDPI rule is *max* over the outputs a
  surface is currently on.

`AQUA_SCALE` is now just an optional pin (auto-detect when unset). The scale
change logs to fd 2 via `write(2,…)` — **not** `fputs(…, stderr)`: `stderr` is a
nonisolated mutable global that Swift 6 strict concurrency rejects (§2.4).
Verified live: `live-sway.sh --hidpi` runs a scale-2 headless output and asserts
the window logs `buffer scale -> 2x`; grim captures the 460×360 window at 920×720.

### 2.14 Key repeat needs a timeout in the dispatch loop (prepare_read/poll)
`wl_display_dispatch` blocks until the socket has data, so nothing wakes the
client to *emit* an auto-repeat. Key repeat therefore rebuilds `Display.run()`
around the canonical libwayland pattern: `wl_display_prepare_read` (draining
`dispatch_pending` until it succeeds) → `flush` → `poll(fd, timeout)` →
`read_events` + `dispatch_pending` on POLLIN, else `cancel_read`. The `timeout`
is the ms until the next repeat deadline (or −1). After each wake we fire any due
repeats. **Must cancel or read after a successful prepare_read** — leaving the
read armed deadlocks the next iteration. All those `wl_display_*` calls are real
exported symbols (no static-inline trap), so Swift calls them directly.

Which keys repeat and how fast comes from the compositor: `wl_keyboard.repeat_info`
gives rate (keys/s, 0 = off) + delay (ms), and `xkb_keymap_key_repeats(keymap,
evdev+8)` says whether a given key auto-repeats (letters yes, modifiers no) — so
we don't hand-maintain a list. Only the latest held key repeats; release clears
it. The repeat re-delivers the *same* `KeyEvent` as a press, so the text field /
scroll / traversal handlers need no special-casing. Scroll-wheel came free in the
same pass: `wl_pointer.axis` (wl_fixed 24.8 → logical px) routed to a new
`WindowDelegate.pointerAxis`. Verified live: `--repeat` holds one key and the
field fills with repeats; `--wheel` spins the wheel and the list scrolls without
touching the thumb (`vkeyboard` gained `d`/`u` hold/release, `vpointer` an `a`
axis command).

### 2.15 The linter lies about C includes
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
[window|sysprefs] [out.png] [--click]` runs AquaDemo against a headless sway
(pixman software renderer, `--unsupported-gpu` — no GPU touched) and grabs the
frame with grim. This exercises what the PNG path can't: the xdg-shell
handshake, shm double-buffering, frame-callback pacing, configure/resize, and
object lifetimes (it caught the §2.7 crash).

`--click` exercises the **input path** too. Headless sway attaches no input
device (seat `capabilities:0`), so the script builds and runs `vpointer`
(`abyss/tests/vpointer.c` + the vendored `wlr-virtual-pointer-*.xml`): it creates
a wlr-virtual-pointer, which registers as an input device so the seat gains a
pointer capability, AquaDemo binds `wl_pointer`, and injected motion/button
events flow through to the toolkit. It clicks the default gel button and the
`Clicks:` counter increments (found the §2.3 NULL-`frame` crash). Evidence:
`docs/screenshots/live-sway.png` (render), `docs/screenshots/live-click.png`
(a registered click).

`--type` exercises the **keyboard path** the same way with `vkeyboard`
(`abyss/tests/vkeyboard.c` + the vendored `virtual-keyboard-*.xml`): a
`zwp_virtual_keyboard` registers a keyboard device (seat gains the keyboard
capability), and — because the protocol makes the client upload its own keymap —
it builds a US keymap with xkbcommon and hands it up, which sway then forwards to
AquaDemo. It types `Abyss` (Shift for the capital) into the focused text field,
which renders it via §2.8. Evidence: `docs/screenshots/live-type.png`. `--keys`
drives keyboard **focus/traversal** (Tab/Space/arrows via `vkeyboard`'s raw
`k <code>` command; §2.12), `--hidpi` runs a **scale-2 headless output** to prove
the window auto-scales (§2.13; `docs/screenshots/live-hidpi.png`), `--wheel`
spins the **scroll wheel** (`vpointer`'s `a` axis command) and `--repeat` holds a
key to prove **key repeat** (`vkeyboard`'s `d`/`u`; §2.14).

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

1. **Real text** — ✅ done, incl. the refinements (§2.6): FreeType + HarfBuzz
   shaping painted via cairo-ft (`de/ctext`, `Aqua/Text`), now with bold/italic
   faces, a shaped-run cache, and device-pixel hinting under HiDPI. Noto Sans
   stands in for Lucida Grande (`$AQUA_FONT` to override). Only nicety left is
   rasterised-bitmap caching, and cairo already does that internally.
2. **Live compositor run + interaction** — ✅ done: `abyss/tests/live-sway.sh
   [--click]` runs AquaDemo under headless sway + grim, and drives real clicks
   via a wlr-virtual-pointer helper (`vpointer.c`). Found and fixed two
   live-only crashes (§2.7 window lifetime, §2.3 NULL `wl_pointer.frame`) and
   validated xdg-shell configure/resize + shm + frame pacing + the pointer
   path. **Keyboard input** is now done too (§2.8): `wl_keyboard` + xkbcommon in
   `Surface`, driven live by `live-sway.sh --type` via a virtual keyboard
   (`vkeyboard.c`). **Scroll-wheel and key repeat** followed (§2.14) — the input
   paths are complete; the only optional extra is keyboard focus tracking
   (enter/leave → caret blink).
3. **Per-output scale** — ✅ done (§2.13): the window tracks its output's scale
   via `wl_output` + `wl_surface` enter/leave and re-cuts its buffers to render
   crisp on HiDPI; `AQUA_SCALE` is now just an optional pin. Verified live by
   `live-sway.sh --hidpi` (a scale-2 headless output).
4. **More widgets** — ✅ the core Aqua control set now exists and is interactive
   (checkbox, radio, slider, pop-up button, progress bar, text field, group box
   in `Draw`; the **Aqua Controls** scene in `de/aqua/Widgets.swift`, driven live
   by `live-sway.sh widgets --click`). A **scrollbar** + scrolling list scene
   followed (`de/aqua/Scroll.swift`, `live-sway.sh scroll --click` drags the
   thumb; arrow/page/Home/End keys scroll too). **Real pop-up menus** followed:
   the Appearance pop-up button opens a grabbing xdg-popup child surface
   (`Surface.Popup` + `AquaMenu`; `live-sway.sh --menu`), choosing an item sets
   the value and dismisses. A **segmented control + tab view** followed
   (`de/aqua/Tabs.swift`, `live-sway.sh tabs --click`; Left/Right arrows switch
   tabs). A **modal sheet** followed (`de/aqua/Sheet.swift`, `live-sway.sh sheet
   --click`): it slides down from the title bar (animated off the frame tick),
   dims + blocks the parent, and its buttons dismiss it. **Keyboard
   focus/traversal** followed (§2.12): a soft `Draw.focusRing`, Tab/Shift-Tab
   over `WidgetFocus`, Space/arrows/Return/Escape driving the widgets scene, plus
   arrow-key + Return/Escape nav in the pop-up menu (during its grab) and the
   sheet — `live-sway.sh widgets --keys` and `--menu --keys`. That completes the
   Phase-1 control set. (A brushed-metal window variant is deliberately out of
   scope: it's a Panther/Tiger-era texture, not era-faithful to 10.2 — the
   pinstriped/white Aqua window is the Jaguar default.)
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
