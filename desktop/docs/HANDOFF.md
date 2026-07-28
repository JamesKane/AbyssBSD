# AbyssBSD (Swift DE) — Handoff & Lessons

What has been built, what we learned building it, and where the traps are.
Read [STATUS.md](STATUS.md) for the current build state, [PHASE2.md](PHASE2.md)
for the shell's ordered passes, and [PLAN.md](PLAN.md) for the multi-year
roadmap; this doc is the *practical knowledge* layer.

Last updated: 2026-07-27 (P2.1–P2.8, the P2.10 session launcher, and the P2.11
polish — the shell boots as one desktop and the loose ends are tied off).

**Picking this up cold?** Read §1 (what exists), skim the §2 index for the trap
nearest what you're about to touch, then §5 (what's next). Then run
`sh abyss/tests/run.sh` and one live mode (§3) to confirm the box still works.

---

## 1. What got built (Phase 0–2)

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

**Phase 2 — the Aqua shell**, all of it as Wayland clients against stock sway
(no compositor work — a Swift compositor is a later phase; see PLAN.md):

- **`Surface` grew up** — a `wlr-layer-shell` surface *role* beside `Window`
  (§2.16), **foreign-toplevel** tracking, **xdg-activation**, a **weak window
  registry with input routed by `wl_surface`** so one process can own many
  windows *and* a layer surface at once (§2.22, §2.24), `Window.close()`, and an
  `addFileDescriptor` hook that folds config-watch/timer/IPC fds into the run
  loop (§2.18).
- **`PoolConfig`** — the Swift port of the Rust `pool`: mmap read, atomic-rename
  write, inotify/kqueue directory watch, same `~/.config/abyss/*.ini` files as
  the sibling, so Swift and Rust components stay config-compatible (§2.17).
- **The shell components** — the config-driven **Desktop** (with hot-reload and
  **desktop icons**, §2.24), the **menu bar** with real dropdowns from a layer
  surface (§2.19), the magnifying **Dock** (§2.20), and the **Finder**: a
  browser-mode file manager with icon/list views, spatial mode (one window per
  folder, raise-not-duplicate), Mac-verb file operations onto the real
  filesystem, and **launching** (§2.21, §2.22, §2.23, §2.25).
- **Shell polish (P2.11)** — the Dock's Trash fills and empties for real
  (right-click → Empty Trash, the one path that unlinks), the menu bar is fully
  keyboard-drivable, and an `.app` bundle is drawn with its own icon (§2.27).
- **The session** — `abyss/session.sh` boots all of it with one command: a
  nested/headless/attached compositor plus the desktop, menu bar and Dock,
  supervised (a component that dies comes back) and torn down together (§2.26).
  That is the first time the shell is a *desktop* rather than three scenes.
- **Evidence** — every pass has a live-verified screenshot in
  `docs/screenshots/` (`live-finder*.png`, `live-desktop-icons.png`,
  `live-dock.png`, `live-menubar.png`, …) produced by `abyss/tests/live-sway.sh`
  under a headless compositor, not mocked.

Not done in Phase 2, on purpose: `CurrentIPC` (binds FreeBSD-only libnv — see
PHASE2.md P2.9).

The screenshots in `docs/screenshots/` are the evidence trail; `first-window.png`
and `system-preferences.png` are the Phase-1 originals.

---

## 2. Lessons that cost time (read before you code)

Newest first after §2.15 (so the freshest traps are at the top of the section);
this index is in numeric order. Each entry is a mistake that actually cost time.

| § | Trap |
|---|---|
| 2.1 | libwayland's requests are `static inline` — Swift can't call them; use the `aw_*` shim |
| 2.2 | Listener structs must outlive the proxy; owner passed via `Unmanaged` |
| 2.3 | A NULL listener slot **aborts** the client — fill every event of the bound version |
| 2.4 | Swift 6 rejects `stderr`-style mutable globals; `write(2, …)` instead |
| 2.5 | cairo's `arc` connects from the current point (`new_sub_path`) |
| 2.6 | Never mutate an `FT_Face` cairo is rendering from — open two |
| 2.7 | The window must be owned across the run loop (live-only crash) |
| 2.8 | xkbcommon owns keycode→text; evdev→xkb is **+8**; feed it every `modifiers` |
| 2.9 | One pure layout function feeds both paint and hit-test |
| 2.10 | xdg-popups: grab needs the click's serial; route by surface; teardown order |
| 2.11 | Protocol-**extension** methods static-dispatch — declare in the body |
| 2.12 | Shift-Tab is its own keysym; a popup grab still routes keyboard to *you* |
| 2.13 | Read the proxy from the callback argument, not a capture |
| 2.14 | Key repeat needs a poll timeout; resolve `prepare_read` or deadlock |
| 2.15 | The linter lies about C includes |
| 2.16 | Layer-shell is a second surface *role*, and it isn't in sway's tree |
| 2.17 | PoolConfig: mmap read / atomic write / watch the **directory** |
| 2.18 | Fold the watch fd into the run loop — resolve the Wayland read *first* |
| 2.19 | Popups from a layer surface; a timerfd clock |
| 2.20 | Dock magnification math + foreign-toplevel + headless-seat quirks |
| 2.21 | The Finder: POSIX from Swift (`d_name`, `d_type`, `mode_t` widths) |
| 2.22 | Many windows: route by surface; a client can't place its own windows |
| 2.23 | File ops: Mac verbs, xkb modifiers, and a test that owns `$HOME` |
| 2.24 | One process, two surface *kinds* — "is there a window?" is not a routing rule |
| 2.25 | Launching: resolve before the fork, double-fork so nothing zombies |
| 2.26 | The session: kill the supervisor before the child; assert composition on the workspace rect |
| 2.27 | Shell polish: `on_demand` keyboard, a popup `close()` that told nobody, `.icns` is a container |
| 2.28 | The VM: a package named `swift6`, a toolchain off PATH, and `\|\| true` hiding a miss |

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
trust `swift build`. (New corollary: it also flags `'namespace' is a keyword`
in the generated `wlr-layer-shell` header — that param is fine in C, and Swift
never imports the generated symbol, only our `aw_*` shims. `swift build` is green.)

### 2.28 The FreeBSD VM: a false negative on the biggest question in the project
(P3.1 — the build VM and its cloud-init seed.)

- **The Swift package on FreeBSD is `swift6`, not `swift`.** The seed had run
  `pkg install -y swift || echo "swift pkg unavailable…"` since Phase 0, which
  reported exactly what we feared about the #1 project risk. It was a **naming
  miss**: `pkg search -q swift` returns `swift510-5.10.1_2` and **`swift6-6.3.2`**
  — a *newer* toolchain than the 6.3.1 we develop against on Linux, targeting
  `x86_64-unknown-freebsd15.0`, with `swift-build`, `swift-test`, Foundation and
  XCTest. Lesson beyond the typo: when a probe confirms your worst assumption,
  check the probe. Costly assumptions deserve *more* scepticism, not less.
- **The toolchain installs off PATH**, at `/usr/local/swift6/bin`, so
  `lang/swift510` and `lang/swift6` can coexist. A non-interactive
  `ssh host 'cmd'` reads neither `.profile` nor `/etc/profile`, so *nothing
  scripted may assume `swift` resolves* — `abyss/vm/config.sh` exports
  `ABYSS_GUEST_SWIFT_BIN` and the scripts spell it out.
- **`|| true` on every `pkg install` turns a missing port into a silent
  success.** It's there so one bad port can't wedge first boot, and
  `~/.cloud-init-done` appears either way — so provisioning "worked" whatever
  happened. The seed now writes anything absent to `~/.pkg-missing` and
  `abyss/vm/check.sh` asserts on it, on the pkg-config names `Package.swift`
  needs, and on the tools `abyss/tests` shells out to.
- **First boot takes ~15 minutes and sshd is last.** freebsd-update runs, then
  ~100 packages install, and only then does sshd start — so an ssh probe fails
  with `kex_exchange_identification: read: Connection reset by peer` (qemu's
  hostfwd accepts at the host end; the guest port is closed). That is "still
  booting", not "broken". `check.sh` waits 20 minutes by default and exits the
  moment ssh answers.

### 2.27 Shell polish: keyboard focus for a bar, a close that told nobody, and
### what an `.icns` actually is
(Phase 2.11–2.13 — empty the Trash, menu-bar keyboard navigation, bundle icons.)
Three small passes, three findings worth keeping:

- **A shell bar wants `on_demand` keyboard interactivity, not `none`.** The menu
  bar can't drive its menus from the keyboard without focus, and it must not
  *hold* focus (everything you type would leave the app you're typing into).
  The layer-shell answer is `keyboard_interactivity = on_demand` (v4): the
  compositor grants focus when the surface is clicked and takes it back when
  something else is focused — which is exactly the Mac rule. The obvious
  alternative, flipping to `exclusive` when a menu opens and back to `none`
  when it closes, **did not work**: with the interactivity change committed on
  its own (no new buffer) while the menu's popup grab was active, no
  `wl_keyboard.enter` ever arrived and not one key reached the client. Set at
  creation, both `exclusive` and `on_demand` work immediately. Don't spend an
  afternoon on the dynamic path — declare `on_demand` and be done.
- **`Popup.close()` deliberately does *not* call `popupDismissed`** (the owner
  calls it after a choice, and a double notification would re-enter teardown).
  So Escape-inside-a-menu, which routed to `close()`, tore the popup down and
  told *nobody*: the menu bar kept `openIndex` set, left the title highlighted,
  and thought a destroyed menu was still open. Escape is a dismissal, so the
  menu now fires `onDismiss` itself. Rule: if a path destroys a popup for a
  *user* reason, it owes the owner a notification; only the owner's own
  teardown is silent.
- **`.icns` is a container, not a codec.** Since 10.7 its large variants are
  whole PNG files, so "read the app's icon" is: walk `{4-byte type, 4-byte
  big-endian length, payload}` chunks, take the biggest payload starting with
  the PNG magic, and hand *that* to cairo (via
  `cairo_image_surface_create_from_png_stream`, whose read callback is a
  `@convention(c)` function taking a cursor as its context). Genuine 10.2-era
  RLE variants are *not* decoded — that needs a real ICNS decoder, the same
  call already made for JPEG wallpapers (§2.18). Every failure falls back to
  the procedural glyph, so an unreadable icon is never an error.
- **Resolve an icon once per listing, not once per frame.** `readDirectory`
  fills `FinderEntry.iconPath` for `.app` bundles; the painter only draws.
  Decoded surfaces are cached by path (including failures) for the process's
  life. Probing the filesystem from a paint function would do it every frame,
  for every visible item.
- **Trash-tile geometry is magnification-dependent.** A Dock tile's rect comes
  from the *drawn* frames, which depend on where the pointer was for the last
  render — so a live test can't aim at the base layout. Compute the fixed point
  (hover x → that tile's magnified span contains x) rather than guessing:
  pointer 540 on an 800px output puts the Trash across 501..592. The Trash menu
  itself needs no special positioning — the positioner's flip-Y constraint
  (§2.10) puts it above the tile, since the Dock leaves no room below.
- **Emptying the Trash is the only code in the project that unlinks.**
  `finderRemovePath` is depth-first (children, then `rmdir`) and lives behind
  `finderEmptyTrash`; everything else still *moves* to `~/.Trash` (§2.23). No
  confirmation dialog yet — a layer surface has no window to host a sheet, so
  the deliberate menu choice is the confirmation. Note it as a known deviation
  rather than assuming it was forgotten.

### 2.26 The session: supervise the components, and prove they *compose*
(Phase 2.10.) `abyss/session.sh` is the one-command desktop — a compositor plus
the desktop, menu bar and Dock, kept alive. It is shell, not Swift, deliberately:
its job is process lifetime (the `anchor` role), and none of it belongs inside a
Wayland client. What the pass taught:

- **The components need no IPC to compose.** Each connects to the compositor on
  its own and the *compositor* arranges them: the menu bar's exclusive zone
  reserves 22px, the desktop asks for `exclusiveZone: -1` so it ignores every
  reservation and fills the output, the Dock overlaps. Start order doesn't
  matter, and there is nothing to synchronise — worth knowing before inventing a
  session protocol for it.
- **Kill the supervisor *before* the child.** A restart loop plus a teardown that
  kills children first means the loop dutifully respawns everything you just
  killed. Teardown drops a `stopping` sentinel file, kills each supervisor, then
  each recorded child pid. The sentinel is also how the loop tells "the session
  is ending" from "this component crashed".
- **Restart, but don't spin.** A component that dies is restarted; one that dies
  *immediately*, five times running, is a broken build and the supervisor gives
  up. The counter resets after a run of ≥5s, so a long-lived component that
  crashes occasionally never exhausts it.
- **`sway -c <config>` replaces the defaults — including every keybinding.** A
  nested session with no binding has no way out but killing the launcher, so the
  generated config binds `Mod4+Shift+Q` to exit.
- **sway refuses to start on a proprietary-driver box without
  `--unsupported-gpu`**, even for the *nested* wayland backend and the headless
  one, which draw nothing on the GPU. The check fires before the backend is
  chosen. Symptom: "session: sway exited" and an Nvidia rant in the log.
- **Ask sway which socket it opened; don't scan the runtime dir.** The harness's
  "first `wayland-N` that isn't the parent's" heuristic (§3's *kill stray sways*
  rule) picks the wrong compositor the moment two sessions start at once — both
  chose `wayland-1` and the second one's clients, and its `grim`, all landed on
  the first's output. Instead match the IPC socket by **our sway's pid**
  (`sway-ipc.*.$pid.sock`), then `swaymsg exec -- sh -c "env > file"` and read
  `WAYLAND_DISPLAY` out of it — sway puts it in every child's environment. Two
  concurrent sessions now get distinct displays. **sway lexes the exec string
  itself**, so quotes inside it don't reach the shell: dump the whole
  environment and grep it, rather than trying to `printf "$WAYLAND_DISPLAY"`
  (that silently writes an empty file, which then falls back to the guess).
- **Assert composition on the workspace rect.** A layer surface is never in
  `swaymsg -t get_tree` (§2.16), so "did the menu bar reserve its space?" can't
  be read off the surface — but `-t get_workspaces` shows the usable area
  starting at y=22, which is the exclusive zone's *effect*. Side effects again
  (§3), one level up: the test asserts the components form a desktop, not merely
  that three processes are running.
- **A pixel probe needs no image library:** `grim -g "x,y 1x1" -t ppm -` writes
  an 11-byte header and three bytes, so `tail -c 3 | od -An -tu1` is the pixel.
  Driving the desktop from a known flat `bg` makes the middle-of-screen probe an
  exact equality, and top/bottom probes differing from it prove the stacking.

### 2.25 Launching: resolve before the fork, and double-fork so nothing zombies
(Phase 2.8.) Double-clicking an app bundle, an executable or a document now
starts a process (`Launcher.swift`):

- **Do every allocation before `fork()`.** After a fork, only async-signal-safe
  calls are legal in the child — no Swift allocation, no `setenv`, no PATH walk.
  So argv, envp and the resolved absolute executable path are all built (with
  `strdup`) *before* forking; the child does `setsid` + `execve` and nothing else.
- **`execvpe` isn't portable** (GNU-only; FreeBSD lacks it), which is the other
  reason PATH resolution happens up front: with an absolute path, plain `execve`
  is enough. `resolveExecutable` is a pure function and unit-tested.
- **Double-fork instead of a SIGCHLD handler.** fork → fork → `execve`, with the
  parent reaping the *middle* child immediately; the grandchild reparents to init
  and can never become a zombie. The run loop must not block in `waitpid`, and
  installing `SIGCHLD = SIG_IGN` from a library would be a rude global change.
- **Bundle convention:** `Foo.app/Contents/MacOS/Foo`, falling back to the first
  executable in that directory. A bundle with nothing runnable resolves to nil
  rather than launching something arbitrary.
- **Documents need a configured opener** (`$ABYSS_OPEN`, else `open_command` in
  `finder.ini`) — there is no LaunchServices. With none set the Finder logs "no
  handler"; a double-click that silently does nothing is a worse bug report.
- **The Dock launches by running this same binary** with `AQUA_SCENE` set
  (`/proc/self/exe`, `$ABYSS_APP_BINARY` to override). Clicking a running tile
  still activates it; only a non-running one launches.
- **Live-test timing:** after a window that covered the Dock is killed, sway does
  not hand pointer focus back to the layer surface until the pointer *moves* —
  the test jiggles the pointer before clicking the tile. Without it the click
  vanishes with no log at all, which reads exactly like a broken hit-test.

### 2.24 Desktop icons: one process, two surface *kinds* — route by surface
(Phase 2.7.) The desktop grew icons (the boot volume + ~/Desktop), and
double-clicking one opens a Finder window — so the wallpaper process now owns a
layer surface *and* xdg toplevels at the same time. That broke an assumption:

- **"Is there a window?" is not a routing rule.** Pointer/keyboard routing fell
  back to `pointerWindow ?? window`, so the moment the desktop opened its first
  Finder window, clicks on the *desktop* went to that window instead. Routing is
  now fully surface-driven: the `enter` events set `pointerOnLayer` /
  `keyboardOnLayer` alongside the window refs, and the layer surface is a target
  in its own right. §2.22 made input multi-*window*; this makes it multi-*kind*.
- **A hosted app must not own the process lifetime.** `FinderApp` quits the
  display when its last window closes — correct when the Finder *is* the app,
  fatal when the Desktop hosts it. Hence `quitsWithLastWindow`, and an init that
  opens no window (`openInitialWindow()` is now explicit).
- **Desktop icons are laid out the other way round.** Jaguar fills the *top-right
  corner downward*, then wraps into a column to the **left** — the mirror of the
  Finder's left-to-right grid. Same "one pure function" rule (`desktopIconRect`),
  and the hit-test only covers the icon and its label, not the whole cell.
- **Labels need their own contrast.** Desktop labels are white with a dark
  shadow, because they sit on whatever wallpaper the user picked; the Finder's
  dark-on-white text is unreadable over a photograph.
- **`Pool.Watcher(in:)` works on any directory.** Pointing one at ~/Desktop gets
  "a file appeared on the desktop" for free, reusing the run-loop fd hook from
  §2.18 — no polling, and the live test asserts on it.
- **Test-harness trap that cost the most time here:** `live-sway.sh` sizes the
  virtual pointer's coordinate space per scene, and `wallpaper` was missing from
  that list, so it silently used the 440×300 default and every injected click
  landed somewhere else. The app was right the whole time; only the harness was
  wrong. When an injected click "does nothing" on a new scene, check `vpw/vph`
  before you touch the app. (Related: a `grim` capture between two clicks blows
  the 450 ms double-click window — send a fresh pair rather than appending one
  click to an earlier selection.)

### 2.23 File operations: Mac verbs, xkb modifiers, and a test that owns $HOME
(Phase 2.6c.) New folder / rename / duplicate / copy / cut / paste / delete, on
the real filesystem:

- **The toolkit had no modifiers.** `KeyEvent` carried keysym/text/pressed only,
  which is fine for a text field and useless for ⌘-shortcuts. It now carries
  `KeyModifiers`, read from xkb with `xkb_state_mod_name_is_active`. Pass the
  modifier names as **literal strings** ("Shift"/"Control"/"Mod1"/"Mod4"/"Lock")
  — `XKB_MOD_NAME_*` are string `#define`s the Swift importer doesn't reliably
  surface. **Command is Mod4** (Logo/Super) on PC hardware.
- **The virtual keyboard must send `modifiers` itself.** wlroots does *not*
  derive modifier state from the modifier keycodes a virtual keyboard injects, so
  pressing evdev 125 does nothing on its own. `vkeyboard.c` gained
  `c <mask> <code>...` — set the mask, tap the keys, clear the mask — which is
  how the live test drives ⌘⇧N / ⌘C / ⌘V / ⌘⌫.
- **Mac verbs, not PC ones.** In the Finder **Return renames** and ⌘O (or ⌘↓, or
  a double-click) opens. Getting this right meant changing the existing keyboard
  live test to open with ⌘O — worth it: the alternative is a file manager that
  looks like Aqua and behaves like Explorer.
- **A rename opens with the name pre-selected.** The first live run typed
  "Reports" into a fresh folder and got `untitled folderReports`: the field
  appended because nothing modelled the selection. `FinderEdit` now carries
  `selectedPrefix` (the base name, extension excluded, as on Mac), the first
  keystroke replaces it, and the painter draws it on the blue highlight.
- **Delete moves to `~/.Trash`; nothing here unlinks.** `rename(2)` can't cross
  filesystems, and a copy+delete that fails halfway is worse than a refusal — so
  a cross-device trash attempt reports failure and leaves the file alone. Names
  colliding in the Trash get the same " copy" uniquing as a paste.
- **Any test that trashes must own `$HOME`.** Both the unit test (`setenv`,
  restored in `defer`) and the live test (`HOME=$finderdir`) point it into their
  temp tree, or the suite quietly fills the developer's real Trash. The unit test
  also removes its tree afterwards — an earlier version left `/tmp/finderops.*`
  behind on every run.
- **Naming rules are pure, over an `exists` predicate.** "untitled folder 2" and
  "Read Me copy 3.txt" are unit-tested with no filesystem; only the syscall layer
  touches disk.

### 2.22 Many windows in one process: route by surface, and you can't place them
(Phase 2.6b — the spatial Finder.) Hiding the Finder's toolbar makes it spatial
(one window per folder), which turned the client runtime multi-window:

- **Input routes by `wl_surface`, not by "the window".** `Display` used to hold a
  single primary `window`; it now keeps a weak registry, and `wl_pointer.enter` /
  `wl_keyboard.enter` (both carry the surface) select `pointerWindow` /
  `keyboardWindow`. The old primary stays as the fallback for events that arrive
  before the first `enter`. Get the keyboard half wrong and typing goes to the
  wrong folder — with tiled windows both are visible, so it's obvious on screen.
- **`wl_keyboard.leave` must stop key repeat.** Otherwise a held key keeps
  repeating into a window that no longer has focus.
- **`windowShouldClose` is another §2.11 protocol-body case.** `xdg_toplevel.close`
  used to call `display.stop()` directly, which kills a multi-window app. It's a
  delegate call now — and declared in the protocol *body*, not just the
  extension, or the default (stop the display) would static-dispatch and the
  app's override would never run.
- **Window teardown needs the popup discipline (§2.10).** One `tornDown` flag,
  guarded `setNeedsDisplay`/`renderAndCommit`/`frameDone`, destroy proxies, and
  unregister from `Display` — a frame callback landing after teardown is
  otherwise a use-after-free.
- **xdg-activation is a two-step handshake with a lifetime trap.**
  `get_activation_token` → `set_serial`/`set_surface`/`commit` → the token
  object's `done` event carries the string, which you then pass to
  `activate(token, surface)`. The request therefore outlives the call: pass it as
  `Unmanaged.passRetained(...)` and `takeRetainedValue()` in `done`. Root the
  token in a **real input serial** (we stash the last pointer serial) or
  compositors are entitled to ignore it.
- **A Wayland client cannot position its own windows.** Real spatial Finder
  remembers each folder's window position; xdg-shell has no set-position, so
  placement is the compositor's (sway tiles them). What we can persist is size,
  view and mode — position waits for `tide` in Phase 3. Not a bug to hunt.
- **Test coordinates shift when a second window appears.** sway tiles, so opening
  window 2 halves window 1. The `--spatial` test works because the left tile
  keeps origin (0,0) and its surface-local coordinates; anything aimed at the
  right-hand window needs the tile offset added (the close-light click is at
  260+16).

### 2.21 The Finder: an app, not a shell surface — and POSIX from Swift
(Phase 2.6.) The Finder is the first component that is an ordinary xdg-shell
**application** (it reuses `Window`), so the interesting traps were in the model
layer, not Wayland:

- **`readdir`'s `d_name` is a C array field.** Reading it needs
  `withUnsafePointer` + `withMemoryRebound(to: CChar.self, …)`. Compute the
  capacity **before** the closure: `MemoryLayout.size(ofValue: raw)` *inside*
  `withUnsafePointer(to: &raw)` is an exclusivity violation ("overlapping
  accesses to 'raw'") and fails to compile.
- **Don't trust `d_type`** — it is `DT_UNKNOWN` on some filesystems. `stat` the
  joined path instead (which also follows symlinks, as the Finder does).
- **Spell the `stat` mode bits yourself.** `mode_t` is `UInt32` on Linux and
  `UInt16` on FreeBSD, and the `S_IF*` macros don't reliably surface, so compare
  `UInt32(st.st_mode) & 0o170000 == 0o040000`. Same discipline as `LOCK_EX` in
  §2.17.
- **Scroll-to-reveal must include the view's margin.** The first version scrolled
  an item just barely into view, which meant the first item could never reach the
  very top (the grid's 10px pad stayed clipped) and the last item never reached
  the bottom. `finderScrollToShow` reveals item ± the grid margin. A unit test
  caught this, not the eye.
- **Double-click has no protocol support.** `wl_pointer.button` carries no click
  count, so it's derived: same item + `CLOCK_MONOTONIC` delta ≤ 450 ms. Clear the
  remembered index after opening, or a third click chains into another open.
- **A new app needs a new app_id in the live harness.** `live-sway.sh` waits for
  the surface to map by grepping `get_tree` for `org.abyssbsd.aquademo`; the
  Finder maps as `org.abyssbsd.finder`, so the expected id is now per-scene.
  Symptom without it: "FAIL: surface never mapped" while the app's own log shows
  it working fine.
- **Order-dependent keyboard tests.** Back re-selects the folder you came out of
  (the Finder does this), so a test that pressed Down assumed the wrong starting
  point. Press Home first — assert from a pinned state, not an inherited one.

Fidelity: the 10.2 Finder is a **browser** (toolbar + navigate in place), not a
spatial file manager, and it is standard Aqua — brushed metal is 10.3, which is
consistent with the descope in §4. The sibling's `reef-fm` is spatial and sorts
folders first; the Mac Finder sorts one case-insensitive alphabetical run over
every kind. Adapt, don't copy.

### 2.20 The Dock: magnification math + foreign-toplevel + a test-harness quirk
(Phase 2.5.) The magnifying Dock (`Dock`, layer-shell BOTTOM) is net-new design.
Key pieces:
- **The magnification curve is a pure function** (`dockMagnify`), which is what
  makes it testable and keeps paint/hit-test in sync. Distances are measured
  against the *fixed base layout* (stable — not the scaled layout, which would
  feed back on itself), a raised-cosine `(cos(πt)+1)/2` falloff over a range of a
  few tiles gives each tile's scale, then tiles are re-laid-out at their scaled
  sizes and re-centred. Hit-testing uses the drawn frames (layout-is-truth). The
  surface must be tall enough for a fully magnified tile (icons rise out of the
  shelf); `DockMetrics.surfaceHeight` sizes it.
- **foreign-toplevel tracking** (`ForeignToplevels`). The manager global is
  *captured* by Display (name+version) but *bound* by ForeignToplevels, which
  attaches the manager listener in the same step — otherwise the `toplevel`
  events the compositor replays for existing windows hit a NULL listener and
  abort (§2.3). Bound at v3 → all 8 handle slots need handlers; `done`/`closed`
  take (data, handle) (2 args) while title/app_id/state/parent take 3 — a
  mismatch is the "failed to produce diagnostic" compile error. Parse the `state`
  `wl_array` as uint32s (ACTIVATED == 2). On `closed`, destroy the handle proxy.
- **Magnification resets on pointer leave**, so `LayerSurfaceDelegate` gained
  `pointerLeft()`, routed from `wl_pointer.leave` (when not entering a popup).
  This bit the live test: closing the virtual-pointer fifo destroys the pointer,
  which sends a leave that resets magnification *before* grim — so `--dock` keeps
  the pointer alive (skips `exec 3>&-`) and captures while hovering.
- **sway's `get_seats` "capabilities" is unreliable** under the headless backend
  + a virtual pointer — it often reads 0 even though pointer events flow (proven:
  magnification renders, clicks register). It read 1 by luck before; the check is
  now a soft warning, and the behaviour assertions (counters, menu-open logs, the
  magnified screenshot) are the real gate. Also: **kill stray sways** — a leftover
  `sway --unsupported-gpu` from a manual debug run makes the socket auto-detect
  pick the wrong display and every live test "never maps".

### 2.19 Menu bar: popups from a layer surface, and a timerfd clock
(Phase 2.4.) The menu bar (`MenuBar`, layer-shell TOP + exclusive zone) is the
first interactive layer surface. What was new:
- **Popups parent differently off a layer surface.** An xdg-toplevel menu uses
  `xdg_surface.get_popup(parentXdgSurface, positioner)`. A layer-shell menu has
  no xdg parent: create a *parent-less* xdg_popup
  (`xdg_surface.get_popup(NULL, positioner)`), then attach it with
  `zwlr_layer_surface_v1.get_popup(popup)`. `Popup` was refactored to one private
  designated init (listeners + grab + commit) with two convenience inits (Window
  vs LayerSurface parent) sharing a `makeSurfaceAndPositioner` helper — the
  existing window menus kept working unchanged. The grab still uses
  `display.lastPointerSerial` (set from the click on the bar, which the P2.1
  input routing delivers to the layer surface).
- **Reuse `AquaMenu` for the dropdowns** (pass `selected: -1` for no checkmark);
  it's already a `PopupDelegate` with hover + choose. `LayerSurface.openPopup`
  mirrors `Window.openPopup`.
- **A ticking clock via `timerfd`.** `aw_create_interval_timer(ms)` returns a
  periodic non-blocking timerfd; register it with `Display.addFileDescriptor`
  (§2.18), read 8 bytes to clear each tick, reformat, and `setNeedsDisplay` only
  when the string changed. `formatMenuClock` is pure (unit-tested); the live clock
  reads `localtime_r`.
- **Layout-is-truth** again: `menuBarLayout` (title/clock rects) is computed each
  render from shaped text widths and cached; pointer hit-testing uses the cache
  (handlers have no cairo context — `menuWidth` uses a 1×1 scratch surface to
  measure popup width). The system glyph is an original water-drop, per the
  "original glyphs, not Apple artwork" policy (§4).
- Verified live by `live-sway.sh --menubar`: the 800×22 bar maps (asserted via
  `LayerSurface: mapped … [abyss.menubar]`), a click on the system title opens a
  dropdown (asserted via `MenuBar: opened System`), and a pixel check confirms
  the open title is highlighted blue with a white glyph.

### 2.18 Config-driven desktop + hot-reload: fold the watch fd into the run loop
(Phase 2.2.) The wallpaper became the real Desktop: `Wallpaper` reads
`desktop.ini` (`PoolConfig`) into a `DesktopStyle` (image → gradient → flat →
Aqua default) and repaints when it changes. The reusable mechanism worth
remembering:
- **`Display.addFileDescriptor(_ fd:onReadable:)`.** Shell components have extra
  event sources besides Wayland — a config-watch fd now, timers and IPC sockets
  later. Rather than a second thread, `run()` polls the Wayland fd (slot 0) *plus*
  every registered extra fd in one `poll()`, and calls each handler when its fd is
  readable. **Order matters:** resolve the armed Wayland read (`read_events` or
  `cancel_read`) *before* running any extra handler, because a handler may issue
  Wayland requests (the wallpaper's config handler calls `setNeedsDisplay` →
  commit). The `prepare_read`/`poll` structure from §2.14 already had the right
  shape; this just widens the pollset.
- **Watch → drain → reload → repaint.** The handler drains the watcher (clears the
  inotify queue), reloads the config, and only repaints if the resolved
  `DesktopStyle` actually changed (avoids redundant frames on unrelated dir
  churn — the `.lock`/`.tmp` files a `store` creates also wake the watch).
- **cairo loads PNG itself** (`cairo_image_surface_create_from_png`), no libpng
  binding needed; check `cairo_surface_status`, cover-scale (`max` ratio, centre),
  and fall back to the Aqua default on any failure. JPEG/SVG need a real codec
  (the sibling's `abyss-image`) — future.
- Verified live end-to-end by `live-sway.sh --reload`: a private `ABYSS_CONFIG_DIR`
  seeded with a gradient `desktop.ini`, asserted via the app's `Wallpaper: applied
  gradient` log, then an atomic rewrite to a flat `bg` asserted via `applied flat`
  — proof the watch fired through the real run loop and repainted.

### 2.17 PoolConfig: mmap-read / atomic-write / directory-watch, in Swift
(Phase 2.3.) `PoolConfig` (`de/poolconfig/`) ports the Rust `pool` — same
`~/.config/abyss/*.ini` files, so Swift and Rust components read each other's
config. It's pure syscalls (Glibc/Darwin), no Wayland, so it's its own target
and test suite. The discipline that matters:
- **Read = mmap `MAP_PRIVATE, PROT_READ` then parse in place.** Lock-free, and an
  atomic `rename()` underneath can't tear the read (we hold the old inode until
  `munmap`). A missing/empty file is an *empty* `Config`, not an error.
- **Write = temp + `fsync` + atomic `rename`, under an exclusive `flock`.** A
  reader always maps a whole file — never a torn one. `unlink` the temp on any
  error (a `committed` flag + `defer`). Best-effort `fsync` the directory after
  the rename so it's durable.
- **Watch = a pollable fd, in C.** The one platform-specific piece — inotify on
  Linux, `kqueue`/`EVFILT_VNODE` on FreeBSD — lives in `CPoolWatch` where the
  `#ifdef` is natural, behind `awc_watch_open/wait/close`. It watches the
  *directory* (atomic writes land as a `rename` into it, so per-file
  registration would miss them) and returns a fd a component can add to its own
  poll loop next to the Wayland fd. Verified live: a `store` wakes the watcher in
  ~4 ms.
- **Two Swift/Glibc gotchas.** (1) `LOCK_EX`/`LOCK_UN` aren't reliably surfaced as
  Swift constants — define them (`2`/`8`) rather than trust the macro import;
  `flock` itself imports fine. (2) `mkdtemp` wants a non-optional
  `UnsafeMutablePointer<CChar>` — pass `buf.baseAddress!` (force-unwrap the
  buffer base) or it won't type-check.

### 2.16 Layer-shell: a second surface *role*, and it isn't in the tree
(Phase 2.1.) The shell's surfaces are `wlr-layer-shell` surfaces, not xdg
toplevels: the compositor owns placement (layer + anchors + exclusive zone) and
the client just paints what it's handed. `Surface.LayerSurface` is that role,
built by mirroring `Window` and trimming:
- **No xdg_surface in between.** The `zwlr_layer_surface_v1` *itself* carries
  `configure`/`ack_configure` (and `closed`). Set size/anchor/exclusive-zone/
  keyboard-interactivity, commit *with no buffer* to trigger the first configure,
  then allocate/paint/attach on configure. The configure delivers the size the
  compositor chose (e.g. the full output for an edge-anchored bar); width/height
  0 on an axis means "you decide" — pass 0 + anchor both edges to fill.
- **The NULL-listener trap still applies** (§2.3): fill both `configure` and
  `closed`. Layer-shell has no events on the *manager* (`zwlr_layer_shell_v1`),
  so binding it needs no listener.
- **Input routing generalised.** `Display` drove input at `window`; a process
  runs *either* a window *or* a shell layer surface (reef-style: one surface per
  process), so it now also holds a weak `layerSurface` and every route
  (`routePointerMotion/Button/Axis`, the new `routeKeyEvent`, `recomputeScale`)
  falls through to it when `window` is nil. Reused `WindowDelegate`'s shape as a
  parallel `LayerSurfaceDelegate` (its frame hook is `layerSurfaceDidRenderFrame`,
  since there's no `Window` to hand back).
- **A layer surface is NOT in `sway -t get_tree`.** It has no `app_id` and isn't
  a toplevel, so the live test can't wait on the tree like it does for windows.
  Instead `LayerSurface` logs `LayerSurface: mapped WxH [ns]` to fd 2 on its
  first configure (the proof the handshake was accepted) and `live-sway.sh
  wallpaper` asserts on that log line. Verified: the wallpaper maps 800×600 under
  headless sway and grim captures the gradient full-bleed.

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

**The live modes today.** `abyss/tests/live-sway.sh [scene] [out.png] [flags]`:

| Flag | What it proves |
|---|---|
| `--click` / `--type` / `--keys` | pointer / keyboard / focus-traversal paths |
| `--wheel` / `--repeat` / `--hidpi` | scroll axis, key repeat, scale-2 auto-scaling |
| `--menu` / `--menubar` | a grabbing xdg-popup from a window / from a layer surface |
| `--reload` | `desktop.ini` drives the desktop, and an atomic edit hot-reloads it |
| `--dock` | Dock magnifies on hover, sees running apps, **launches** from a tile |
| `--finder` | real `readdir`, double-click into a folder, Back, view switch |
| `--spatial` | two real toplevels, re-open **raises** (xdg-activation), close one |
| `--fileops` | ⌘⇧N / rename / ⌘C⌘V / ⌘⌫ — asserted **on disk**, not in the log |
| `--desktop` | desktop icons: select, open a Finder window, notice a new file |
| `--launch` | an `.app` bundle really executes (and is drawn with **its own icon**); a document reaches `$ABYSS_OPEN` |
| `--trash` | the Dock's Trash: full glyph, right-click menu, **Empty Trash** — checked on disk |
| `--menubar --keys` | the menu bar driven **only** by the keyboard: Right walks titles, Down/Return chooses, Escape closes |

**The whole desktop at once:** `abyss/tests/live-session.sh [out.png]` runs
`abyss/session.sh --headless` and asserts the shell *composes* — three layer
surfaces mapped in their own namespaces on one output, the menu bar's exclusive
zone reflected in sway's workspace rect, grim pixel probes in the right stacking
order, and a killed Dock restarted by the supervisor (§2.26). Evidence:
`docs/screenshots/live-session.png`. To just *look* at it:
`abyss/session.sh --nested`.

**Rules the harness taught us** (each cost a debugging cycle):

- Assert on **side effects** — files on disk, toplevels in `swaymsg -t get_tree`,
  the app's own fd-2 log lines — not on "it didn't crash".
- `live-sway.sh` sizes the virtual pointer's coordinate space **per scene**. A
  scene missing from that list silently gets the default and every injected click
  lands somewhere else (§2.24). Check `vpw/vph` before suspecting the app.
- A `grim` capture between two clicks blows the 450 ms double-click window; send
  a fresh pair instead of appending a click to an earlier selection.
- After a window that covered a layer surface is destroyed, sway won't hand
  pointer focus back until the pointer **moves** — jiggle before clicking (§2.25).
- Tests that write must own their environment: `$HOME` (→ `~/.Trash`),
  `$ABYSS_CONFIG_DIR` (the Finder persists its mode), `$ABYSS_DESKTOP_DIR`.
  Otherwise the suite quietly edits the developer's real home.
- Kill stray `sway --unsupported-gpu` processes if a run reports "never maps" —
  socket auto-detect will pick the wrong display.

Full loop: `sh abyss/tests/run.sh` (build + `swift test` + a headless smoke
render). The 58 unit tests are pure logic — no compositor, no network: toolkit
geometry, the Finder's listing/naming/scroll model, desktop-icon layout, launcher
resolution, and PoolConfig's read/write/watch.

---

## 4. Fidelity notes (from the Jaguar reference)

What matched the real 10.2 screenshot once corrected: **lighter** smooth
title-bar gradient with a near-white top edge and faint pinstripes; **glassy
"water-drop" traffic lights** (vertical body gradient + broad upper sheen + a
small upper-left specular dot); **flat light-grey** system-window body (not white,
no blue pinstripe); **rounded top / square bottom** corners; the toolbar toggle
**pill** at the title bar's right. The reference is the spec — refine `Theme` and
`Draw` against it, not from memory.

**Behaviour is part of fidelity, and these are decisions — don't "fix" them:**
- The 10.2 **Finder is a browser** (toolbar, navigate in place); hiding the
  toolbar with the title bar's pill is what makes it *spatial*. Both modes exist
  (§2.22). The sibling's `reef-fm` was spatial-only — a GNOME-2 model.
- **Brushed metal is 10.3**, not Jaguar: the Finder is standard Aqua here, which
  is why it reuses `paintWindowChrome`. (A brushed-metal window variant was
  explicitly descoped for the same reason.)
- **Mac verbs, not PC ones:** Return *renames*, ⌘O/⌘↓/double-click open, ⌘⌫
  moves to the Trash. A rename opens with the base name pre-selected (§2.23).
- The Finder sorts **one case-insensitive alphabetical run** — folders do *not*
  float to the top (that's the sibling's GNOME-2 behaviour).
- **Desktop icons fill from the top-right corner downward**, wrapping leftward —
  the mirror of the Finder's grid, not a reuse of it (§2.24).

Known-not-faithful, on purpose:
- **Icons are original procedural glyphs**, not Apple artwork (copyright). They
  read correctly but aren't pixel-identical.
- **Text is real** now (FreeType/HarfBuzz shaping via cairo-ft) but the face is
  **Noto Sans**, not Lucida Grande (which ships with no free equivalent) — the
  metrics/letterforms differ. Set `$AQUA_FONT` to a Lucida Grande file for
  pixel-faithful text. cairo toy-text remains only as the no-font fallback.
- **Window and desktop-icon *positions* aren't remembered**, because a Wayland
  client cannot place its own surfaces — the compositor does. Size, view and mode
  do persist. This is a protocol limit, not an omission; `tide` can honour
  remembered placement in Phase 3 (§2.22).

---

## 5. What I'd do next (in order)

Phase 0/1 are complete (real text, live input paths, the full control set,
per-output HiDPI) and Phase 2's *visible* shell is complete (P2.1–P2.8: desktop,
config, menu bar, Dock, Finder, desktop icons, launching) and now boots as one
desktop (P2.10). What's left:

1. ~~**Finish Phase 2's tail**~~ — **done. Phase 2 is complete.** Its last open
   item, **P2.9 `CurrentIPC`**, was a decision rather than a coding task, and it
   was decided on 2026-07-27: **carried to Phase 3 and written in Swift there**
   (PHASE2.md P2.9 has the full reasoning and the traps to expect). The short
   version: every peer it would talk to — session supervisor, compositor,
   hardware bridges — is itself an unwritten Phase-3 Swift component, its
   FreeBSD-native encoder isn't on this box, and the Dock already gets running
   apps from foreign-toplevel. There is nothing here to talk to and nothing to
   verify against, so building it now would be building against a mirror.
2. **Shell polish** — the three self-contained ones are **done** (P2.11, §2.27):
   emptying the Trash from the Dock, menu-bar keyboard navigation, and reading
   an `.app` bundle's own icon. What's left of that list:
   - Dragging desktop icons — blocked on the same thing as spatial window
     placement: a Wayland client can't position itself, so this needs remembered
     per-item positions in config (§2.22).
   - The menu bar's **status items** (volume/battery need the FreeBSD `vents`
     bridges — Phase 3).
   - A confirmation sheet for Empty Trash, once something can host a dialog for
     a layer surface (§2.27).
3. **Golden-image tests** — snapshot the PNG renders and diff in CI. The scenes
   are deterministic (`finderSampleEntries`, `desktopSampleEntries` exist for
   exactly this); this is the cheapest guard against silent visual regressions.
4. **Phase 3 — FreeBSD. In progress: P3.1 is done.** Scoped pass-by-pass in
   **[PHASE3.md](PHASE3.md)** (P3.1–P3.7, written 2026-07-27). The build VM
   provisions and is asserted usable (`abyss/vm/check.sh`), and the standing #1
   risk is **materially reduced**: FreeBSD ports carries **`swift6-6.3.2`**,
   newer than our Linux toolchain, with `swift-build`/`swift-test`/XCTest — the
   old seed's `pkg install -y swift` was a naming false negative (§2.28,
   [SWIFT-ON-FREEBSD.md](SWIFT-ON-FREEBSD.md)). Not closed: nothing of ours has
   compiled there yet, and acceptance is `swift build` + `swift test` on this
   repo (P3.2). Everything above is deliberately Linux-verifiable so it doesn't
   block on that. Bring-up continues (build the repo in the guest, the C
   substrate, and the portability debts listed below), then the native
   substrate — all **Swift
   rewrites**, not adoptions of the Rust components (PLAN.md, corrected
   2026-07-27): `CurrentIPC` (PHASE2.md P2.9), a session supervisor to replace
   `abyss/session.sh` and §2.25's double-fork stand-in, and hardware bridges for
   the menu bar's status items. A Swift compositor over a wlroots binding is its
   own later phase; until it exists the shell keeps running on stock sway/labwc,
   which FreeBSD ports too. The sibling's `tide`/`anchor`/`vents` are what you
   *read* before writing each one. Two things worth knowing before you start:
   **`CurrentIPC` isn't blocked by the toolchain** (unix sockets + `SCM_RIGHTS`
   are POSIX, so it builds and tests here today — PHASE3.md §6.3), and the
   **portals / legacy-D-Bus story is carved out** of the phase (§6.1).

**Portability debts to pay when FreeBSD arrives** (all flagged in code):
`/proc/self/exe` in `Launcher.selfExecutable` (needs the `KERN_PROC_PATHNAME`
sysctl; `$ABYSS_APP_BINARY` overrides meanwhile), the inotify half of
`CPoolWatch`, and `mode_t` width assumptions already handled by spelling the
`stat` bits out (§2.21).

---

## 6. Gotchas inherited from the sibling (still true here)

- `abyss/vm/sync.sh` uses `rsync --delete` — it wipes the in-VM target dir; the
  Swift `.build/` is gitignored and absent on a fresh sync, so rebuild after the
  last sync.
- The VM home defaults to `../abyss-swift-vm` (separate from the sibling's
  `../abyss-vm`) so we don't clobber the Rust project's VM. Set
  `ABYSS_VM_HOME=../abyss-vm` to reuse that already-provisioned box.
- The repo is committed now, one commit per pass, with the pass number in the
  subject (`P2.8: launching …`) — `git log --oneline` is a readable history of
  how the shell was built, and each commit's body records what was verified.

---

## 7. Pointers

**Where things live** (Swift/C targets under `de/`, mirroring the sibling tree):

| Path | What |
|---|---|
| `de/cwayland` | libwayland + generated protocols + the `aw_*` shim (§2.1) |
| `de/surface` | the client runtime: `Display`, `Window`, `LayerSurface`, `Popup`, `Keyboard`, `ForeignToplevels`, `Activation` |
| `de/aqua` | the toolkit + the shell: `Theme`/`Draw`/`Text`/`Icons`, `Wallpaper`+`DesktopIcons`, `MenuBar`, `Dock`, `Finder`(+`FinderModel`/`FinderOps`), `Launcher` |
| `de/poolconfig` | config read/write/watch (`CPoolWatch` is the platform fork) |
| `de/aquademo` | the runnable demo; `AQUA_SCENE` picks a scene/component |
| `abyss/session.sh` | the dev session launcher — one command boots the desktop (§2.26) |
| `abyss/tests` | `run.sh` (build+test+smoke), `live-sway.sh`, `live-session.sh`, the virtual input helpers |
| `abyss/vm` | the FreeBSD build VM: `config.sh` (incl. `ABYSS_GUEST_SWIFT_BIN`), `fetch-image.sh`, `make-seed.sh`, `run.sh`, **`check.sh`** (is the guest usable?), `ssh.sh`, `sync.sh` |
| `protocols/` | vendored protocol XML; regenerate via `de/cwayland/generate-protocols.sh` |

**Adding a Wayland protocol** is mechanical: drop the XML in `protocols/`, add a
`gen` line to `generate-protocols.sh`, list the generated `.c` in
`Package.swift`, add one-line `aw_*` wrappers (§2.1), and fill **every** listener
slot (§2.3). xdg-activation (P2.8) is the most recent worked example.

**External:**

- Architecture canon (Rust sibling): `../AbyssBSD/abyss/docs/{DESKTOP,SEAMS}.md`.
- Reference implementations to **rewrite from** in Phase 3+ (read, don't link):
  `../AbyssBSD/abyss/de/{tide,anchor,vents,…}`,
  `../AbyssBSD/abyss/ipc/{current,pool,shmring}`. `PoolConfig` is how that goes:
  same on-disk format, all-new Swift. Note the sibling's shell targeted
  **GNOME 2**, not Aqua — adapt its algorithms, don't copy them.
- Agent memory: `abyssbsd-swift-project`, `abyssbsd-swift-status`,
  `reef-targeted-gnome2`.
