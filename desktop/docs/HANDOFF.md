# AbyssBSD (Swift DE) — Handoff & Lessons

What has been built, what we learned building it, and where the traps are.
Read [STATUS.md](STATUS.md) for the current build state, the phase docs
([PHASE2.md](PHASE2.md), [PHASE3.md](PHASE3.md), [PHASE5.md](PHASE5.md),
[PHASE6.md](PHASE6.md), [PHASE7.md](PHASE7.md), [PHASE8.md](PHASE8.md)) for
ordered passes, and [PLAN.md](PLAN.md) for the multi-year roadmap; this doc is
the *practical knowledge* layer.

Last updated: 2026-08-24. **Phases 0–3 and 6–8 are complete.** The Jaguar shell
runs on FreeBSD, on **our own compositor** (`undertow`), over a Swift control
plane, session supervisor and hardware bridges; the portals hand out descriptors;
and **one command boots a desktop where an unmodified GTK 3 application, which
has never heard of this desktop, opens a file through the Finder**.
**234 unit tests + 35 live modes, green on Linux and FreeBSD.**
**Phase 5 — the installer — is scoped** ([PHASE5.md](PHASE5.md)), its four risks
retired on the target: a program we wrote installs a FreeBSD that boots, and the
harness can prove it booted with no hardware and no human.

**Picking this up cold?**

1. **The next pass is P5.1** — `de/install`, the install as a value. Phase 8
   closed with P8.4; the 2026-08-23 choice between Phase 4 and Phase 5 went to
   Phase 5, which is now scoped. §5 has what P5.1 is, what P5.2 proves, and the
   standing smaller items. **Phase 4 (Mac Pro bring-up) is still open and still
   independent** — and now owns the metal half of Phase 5's verify.
2. Read §1 for what exists. It is long; the two newest parts are **Phase 6**
   (the compositor) and **Phase 8** (the D-Bus bridge).
3. Skim the §2 index for the trap nearest what you're about to touch. **The
   freshest scars all generalise, and most are about *testing* rather than
   code** — which is the pattern worth carrying into the next pass:
   - **§2.37** — a probe with no positive control measures nothing. A published
     measurement had to be withdrawn over this one.
   - **§2.38** — a polite adversary is not an adversary.
   - **§2.39** — one hang is not *the* hang: an async, object-based API has more
     than one way to hang, and each is invisible to the client shape that
     exposes the other.
   - **§2.40** — an answer for one client must be *addressed* to it; and when you
     change what goes on the wire, ask what your **witness** can still see. Two
     green tests once covered a message its only real reader could not receive.
   - **§2.41** — whose lifetime is this listener, exactly? A compositor must
     outlive its input client, and only a test that shuts down in the right
     order will ever say so.
   - **§2.42** — name your sockets instead of reading back what something else
     chose, and test readiness by connecting. A discovered address is one that
     changes under you.
4. Confirm the box still works:

   ```sh
   sh abyss/tests/run.sh            # build + 234 unit tests + the fast live tests
   abyss/vm/check.sh                # is the FreeBSD VM up and usable?
   sh abyss/tests/run.sh --vm       # ... and does the guest still build + test?
   ```

   The VM may not be running after a break — `ABYSS_DAEMON=1 abyss/vm/run.sh`
   boots it, and first boot after a reset takes ~15 minutes (§2.28). Everything
   in `abyss/vm/` is idempotent, so re-running is safe.

---

## 1. What got built (Phases 0–3, 6, 7, and Phase 8 so far)

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

**Phase 3 — FreeBSD (complete, P3.1–P3.7).** The same desktop, on the target OS,
with a native substrate underneath it (PHASE3.md):

- **The build VM** (`abyss/vm`, `../abyss-swift-vm`) provisions from a corrected
  cloud-init seed and is asserted usable by `abyss/vm/check.sh` (§2.28).
- **Swift on FreeBSD — the standing #1 risk — is CLOSED.** Ports carries
  `swift6-6.3.2` (newer than our Linux 6.3.1); it builds this repo and passes
  every test in the guest, for one `Package.swift` change (§2.29,
  SWIFT-ON-FREEBSD.md). The package is `swift6`, not `swift`, and installs
  **off PATH** at `/usr/local/swift6/bin`.
- **It runs there** (§2.30) — `docs/screenshots/freebsd-desktop.png`. Every
  portability debt is paid; `CPlatform` holds what Swift can't reach.
- **The whole harness passes there** (§2.31): 35 live modes, not just the build.
- **`CurrentIPC`** — the brokerless control plane: typed messages over unix
  sockets with **SCM_RIGHTS fd passing**, our own codec rather than libnv, and
  therefore no platform fork at all (§2.32).
- **`anchor`** — the Swift session supervisor that replaces `abyss/session.sh`:
  every child a pollable descriptor (`pdfork` / `pidfd`), a control service, and
  `abyssctl status|quit` (§2.33).
- **`Vents`** — the hardware bridges: sysctl (not sysfs), OSS (not ALSA), devd
  (not udev), and the menu bar's volume/battery status items (§2.34).

**Phase 7 — portals (P7.1–P7.5, complete).** The brokerless answer to
xdg-desktop-portal, and the project's most interesting claim (PHASE7.md):

- **The Finder is a picker** (`$ABYSS_FINDER_PICK`): choose → path written,
  exit 0; cancel → nothing, exit 1. A file dialog never launches what you click.
- **`abyss-portal`** answers `file.open`/`file.save` by running the picker,
  **opening the chosen path itself**, and returning the descriptor. The
  confused-deputy rule is enforced by the *type*: a request has nowhere to put
  "the file to open".
- **`abyssopen` proves it**: in **Capsicum capability mode** — no filesystem, no
  namespace — it reads the chosen file while `open(2)` on that same path fails
  with *"Not permitted in capability mode"*. **The descriptor is the
  capability.**
- **Notifications** — an Aqua **toast** on an OVERLAY surface that reserves no
  space and takes no focus, reached through the portal by `abyssnotify`
  (§2.35, `docs/screenshots/notification-toast.png`).
- **Screenshot** — `wlr-screencopy` bound in `Surface`, captured by a separate
  `abyssgrab` helper so the portal never becomes a Wayland client, and returned
  as **a descriptor with no name at all**: the request type carries nothing, the
  reply carries no path, and the image is **unlinked the moment it is opened**.
  The sandboxed client holds a picture of a screen it cannot reach — `connect(2)`
  to the compositor fails from capability mode (§2.36,
  `docs/screenshots/portal-screenshot.png`).

**Phase 6 — `undertow`, our own compositor (P6.1–P6.7, complete).** Built out of
order on purpose (PHASE6.md), and in the canon's order — *the contract exists
before the pixels do*:

- **The frame contract first.** A metronome with EWMA vblank prediction and
  late-latching, plus the flight recorder that makes DESKTOP.md's C1–C5
  falsifiable — written and benchmarked before a single pixel was composited.
  The present path is **allocation-free**, enforced every build by a symbol-
  interposition probe rather than by a number somebody once measured (§2.37).
- **wlroots in 29 lines of C.** Swift imports the headers directly; the shim
  exists only because `wl_signal_add` is a static inline and `wl_container_of` is
  a macro (§2.1 at scale). The sibling's binding is 4,946 generated lines.
- **A scene of our own** — structure-of-arrays, deliberately not `wlr_scene` —
  hosting xdg-shell toplevels and `wlr-layer-shell` with exclusive zones.
- **C2 is proved**, and it is the claim the architecture exists to make:
  **eleven real hostile processes** — flooders that never roundtrip, zombies,
  churners, a deaf client — cannot make the compositor drop a frame, while a
  healthy client keeps drawing throughout. The fix that mattered was not a
  thread: it was *where in the frame* the event loop is pumped (§2.38).
- **The Jaguar desktop composes on it** — wallpaper, menu bar and Dock, with the
  menu bar's exclusive zone reserving its strip exactly as §2.26 asserts against
  sway. `abyss/tests/live-undertow*.sh` are the first tests here that **start no
  sway at all**.
- **P6.7 paid two cross-phase debts**: §2.22's **remembered window positions** (a
  window reopens where it was dragged, persisted through `PoolConfig`) and
  PHASE7 §6.6's **screencopy server half** (P7.5's `abyssgrab` captures
  `undertow` unmodified — the client half never knew the difference).

**Phase 8 — the D-Bus bridge (P8.1–P8.4, complete).** Portals for
everyone else (PHASE8.md), and the only place in the system that touches D-Bus:

- **`de/dbus` speaks D-Bus with no dependency at all** — no libdbus (discouraged
  by its own docs), no GDBus (that means GLib, and through it the GTK stack this
  project rejects), no sd-bus (systemd). Only `CPlatform`, for the same
  SCM_RIGHTS helpers `CurrentIPC` has used since P3.5. **The rule the format
  turns on:** every value aligns to its natural boundary *measured from the start
  of the message*, not from the buffer being filled.
- **`abyss-dbus` owns `org.freedesktop.portal.Desktop`** — `FileChooser.OpenFile`
  and `SaveFile`, the `Request`/`Response` object lifecycle, `Properties` and
  `Introspectable` — translating to the existing `abyss-portal` and the same
  Finder our own apps get, with no second code path.
- **`org.freedesktop.portal.Settings`** is the second interface, and it exists
  because a real GTK app asked for it before it drew a window (P8.3). Only
  `org.freedesktop.appearance` is standardised, so it is the only namespace we
  publish; every other namespace gets a **successful, empty** answer, which is
  the difference between an app that starts quietly and one that warns each time.
- **It is never tested against our own encoder.** `dbus-daemon` is the bus,
  `dbus-send`, `gdbus` and **an unmodified GTK 3 application** are the callers,
  and both GLib and libdbus decode our `Response` with their own parsers. See
  §2.39 and §2.40 for the *three* silent hangs this API offers, and why one
  client shape in a test proves a third of what you think.
- **A GTK application is just another client of `undertow`** (P8.3). It maps its
  own window on our compositor, `GtkFileChooserNative` opens **the Finder**, and
  it is handed a file it never named — it named a directory. That is the claim
  PHASE7 §6.7 could not make, and nothing before this pass could.
- **And `anchor` boots the whole thing with one command** (P8.4): compositor,
  bus, portal, bridge, desktop, menu bar, Dock — in that order, with
  `DBUS_SESSION_BUS_ADDRESS` in every child's environment. The bus is **first**
  because the shell is what launches applications, and its socket is one **we
  name** (`$ABYSS_RUNTIME_DIR/bus`) rather than one we read back, so the address
  outlives a restart of the daemon. Dependencies are declared as sockets and
  waited on with `connect(2)`, which is the only readiness test that is true.
- **And the plan's headline claim was wrong.** It promised a foreign app "a
  descriptor as its answer"; the interface definition on disk says `Response`
  carries `uris` — strings — with no descriptor in any version. **Their answer
  is a name; ours is a capability** (PHASE8 §6.6). The confused-deputy property
  still survives the hop: a foreign app names a directory, never a file.

The screenshots in `docs/screenshots/` are the evidence trail; `first-window.png`
and `system-preferences.png` are the Phase-1 originals, and `freebsd-*.png` are
the Phase-3 ones.

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
| 2.29 | FreeBSD build: a C target can't carry `pkgConfig:` — depend on a systemLibrary that does |
| 2.30 | FreeBSD runtime: no `<sys/sysctl.h>` from Swift, font lists that only covered *regular*, no `XDG_RUNTIME_DIR` |
| 2.31 | FreeBSD harness: `od(1)` adds a trailing space, and a `for` over a table word-splits multi-word entries |
| 2.32 | The control plane: cmsg is all macros, fds ride with the *length prefix*, and `sun_path` is 108 bytes |
| 2.33 | The supervisor: accepted sockets inherit `O_NONBLOCK` on BSD but not Linux; SIGPIPE kills a client silently |
| 2.34 | The bridges: sysctl is untyped (`"FreeBSD\0"` is 8 bytes), and a pixel probe must not depend on the font |
| 2.35 | A `LayerSurface` with no teardown: replacing one crashed the process — §2.2's trap, eight months later |
| 2.36 | Capsicum permits `socket(2)`; it forbids *naming an address* — the control was wrong, and only FreeBSD could say so |
| 2.37 | Swift allocates via `posix_memalign`, and interposition dies in a `.xctest` — a probe with no positive control reports a comfortable zero |
| 2.38 | A flooding client that roundtrips throttles itself; and *where in the frame* you dispatch matters more than which thread does it |
| 2.39 | An async, object-based API has more than one way to hang — and each is invisible to the client that exposes the other |
| 2.40 | A signal that answers **one** client must be *addressed* to it — GTK adds no match rule, and `gdbus monitor` can't see an addressed signal either |
| 2.41 | Input devices belong to clients: free a device's listeners on its `destroy`, or the compositor aborts when the harness lets go of the pointer |
| 2.42 | Name the socket; don't read the address back. A discovered address changes when the thing that chose it restarts — and readiness is `connect(2)`, never "the file exists" |

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

### 2.42 Name the socket, don't read the address back
(P8.4 — `anchor` starting a session bus, and a compositor, for the whole
desktop.)

Every `dbus-daemon` example does this:

```sh
addr=$(dbus-daemon --session --print-address=1 --fork)   # ask what it chose
export DBUS_SESSION_BUS_ADDRESS="$addr"
```

and it is wrong for a supervisor, in a way that only shows up later. **An address
you discover is an address that changes when the thing that chose it restarts.**
The moment `dbus-daemon` is a supervised component — one that can die and come
back — every child already holding `DBUS_SESSION_BUS_ADDRESS` is pointing at a
socket that no longer exists, and the variable cannot be un-inherited. The bus
becomes the one component in the session that is *not* restartable, and nothing
says so.

Inverting it costs one flag and fixes all of it:

```
--address=unix:path=$ABYSS_RUNTIME_DIR/bus
```

The address is now knowable **before the daemon exists** (so it can be exported
before anything is spawned), it is stable across restarts, and it is a property
of the *session* rather than of a process — which is also why it belongs beside
`anchor.sock` and `portal.sock` rather than in `/tmp`. `--print-address=1` is
still passed, but as a *log line* rather than a channel: it answers "which bus is
this session on" for a human, and a mismatch with what we asked for would be
visible instead of mysterious.

The same argument applied a second time, to a different socket: `undertow` picked
its display with `wl_display_add_socket_auto`, so a session had to *start* the
compositor, *read* the socket it chose, and only then start everything else —
which is two commands, not one. `undertow --socket NAME` makes the display a
name the session chooses too. Asking for a taken name is an **error**, not a
silent fallback to another: a fallback would hand every component a display
nothing is listening on.

**And the other half: readiness is `connect(2)`.** Having named a socket you must
still wait for it, and the two obvious ways are both wrong. Waiting for the file
to appear is a race with a window: `bind(2)` creates it and `listen(2)` is a
separate call, so a client that arrives in the gap gets `ECONNREFUSED` from a
dependency a file-watcher already called ready. A `sleep` is the same race with
better manners (§2.26). Connecting and dropping the connection immediately
reaches no protocol at all, which is exactly the point — it asks whether
something is listening, and nothing else.

So a component declares the sockets it cannot start without, and the supervisor
waits on **every** start rather than only the first. The restart is the case that
matters: it arrives microseconds after the thing it needs died, and a
bring-up-only gate would let it burn a whole failure budget in a millisecond and
take the session down with it.

Two things worth keeping from how this played out:

- **The gate paid for itself before it was tested.** The first run of
  `live-session-gtk.sh` failed with *"desktop needs /run/user/1000/abyss-p84-…,
  which never accepted a connection"* — because the test had forgotten to pass
  `--socket` to the compositor. Without the gate that is three components
  crash-looping against a display that does not exist, and the message is
  whatever the toolkit says about a missing socket, five restarts deep.
- **"Nothing restarted" is the assertion that tells a gate from a race.** Getting
  the order right on paper satisfies every other check — the supervisor logs
  "bridge up" the moment it spawns it, gate or no gate — so log order proves
  nothing. `up(0)` across every component says each one found what it needed
  *already listening*. Removing the wait produced `up(1)`: a session that works
  anyway, most of the time, by crashing until it doesn't have to.

### 2.41 A compositor must outlive its input
(P8.3 — `undertow` aborting on the way out of a green test.)

```
wlr_pointer_finish: Assertion `wl_list_empty(&pointer->events.motion.listener_list)' failed.
  virtual_pointer_destroy_resource → wl_client_destroy → wl_client_connection_data
```

`Seat` attached four listeners to every pointer it was handed and freed them in
its own `deinit` — the seat's lifetime, not the device's. That is fine for a
device that belongs to the machine. **A virtual pointer belongs to a client**,
and this project drives every live test through one: when the harness closes the
fifo and the vpointer exits, wlroots destroys the device, asserts that nothing is
still listening to it, and takes the compositor down. §2.2's rule about listener
*lifetime* again, in its third costume (see §2.35) — the question is never "does
this listener outlive the callback" but "**whose** life is it, exactly".

The fix is per-device: keep each device's listeners in a group keyed by the
device, subscribe to its `base.events.destroy`, and free the group there.
wlroots emits that signal with `wl_signal_emit_mutable` precisely so a listener
may remove itself from inside it.

Why it stayed hidden for a whole phase: every earlier test either killed the
compositor first or held its input open to the end of the frame budget, so the
device outlived the session that owned it and the assert never fired.
`live-gtk.sh` drops the pointer and *then* waits for undertow's summary — which
is the only reason we saw it at all.

The keyboard had the identical bug, unfound, because nothing had ever
disconnected one either. Both are now driven and asserted by
`live-undertow-input.sh`, which connects a virtual keyboard purely in order to
drop it, closes the pointer's fifo, and requires undertow to **exit 0** —
injected once each to prove it can fail (`wlr_keyboard_finish` /
`wlr_pointer_finish` assertion, exit 134).

The harness rule this leaves behind: **a live test should shut its clients down
and let the compositor finish.** The teardown path is code too, and it is the
code nobody runs.

### 2.40 An answer for one client must be addressed to that client
(P8.3 — a stock GTK 3 app hanging on `GtkFileChooserNative`, with a green bus,
a correct object path, a correct `Response`, and a witness that saw it.)

§2.39 says a bus delivers a broadcast signal only to connections that asked for
it. True, and incomplete in the way that costs an afternoon: **the real portal
does not broadcast the `Response` at all.** `xdg-desktop-portal` emits it with
the caller's unique name in the DESTINATION field, and GTK is built for that —
`G_DBUS_DEBUG=message` on the client shows *no* `AddMatch` for the request path
anywhere. It never subscribes. It simply waits to be spoken to.

So a broadcast `Response` is a message that:

- the bus routes to nobody, because nobody holds a match rule for it;
- reads as perfectly correct in every log we had — the bridge said
  `Response(0) on /org/…/request/1_8/gtk146620821`, the path was the one GTK
  predicted, the body decoded;
- **and was still seen by our own witness**, because `dbusprobe` does subscribe
  and `gdbus monitor` was eavesdropping. Two green tests over a message the one
  client that mattered could never receive.

The fix is one header field (`DBusMessage.signal(to:)`), and the diagnosis is
worth more than the fix: when a client hangs and the wire looks right, dump the
client's own `AddMatch` traffic before re-reading your encoder. `G_DBUS_DEBUG=message`
took ten minutes and named the bug outright.

**And the sting in the tail — the witness stops witnessing.** `gdbus monitor`
watches through match rules, so it sees a broadcast and is *blind to an addressed
signal*, `--dest` or not (measured: `dbus-send --type=signal --dest=…` reaches
`dbus-monitor` and never reaches `gdbus monitor`). Fixing the bug would have
silently gutted the independent-decode assertion in P8.2's live test, which would
have gone on passing on the strength of a `grep` that could no longer fail. Both
tests now use `dbus-monitor`, a real bus monitor, and `live-gtk.sh` asserts the
destination is there — the property, not just the signal. Cousin of §2.37: when
you change what goes on the wire, ask what your *witness* can still see.

### 2.39 One hang is not the hang
(P8.2 — `org.freedesktop.portal.FileChooser`. Two bugs, one symptom, and a test
that only found the first one.)

The portal API is asynchronous and object-based: a method call returns an
**object path** at once, and the answer arrives later as a `Response` **signal**
on that path. A bus delivers a broadcast signal only to connections that asked
for it, so the client has to be subscribed first. There are two ways to break
that, they produce the **identical symptom** — a client waiting for ever with no
error, no log line and nothing on the wire — and *each is invisible to the client
shape that exposes the other*.

- **The path is derived by the client, not chosen by you.** It is
  `/org/freedesktop/portal/desktop/request/SENDER/TOKEN`, where SENDER is the
  **caller's** unique name with the leading `:` dropped and every `.` turned into
  `_`, and TOKEN is the caller's own `handle_token`. A modern client computes
  that itself and subscribes *before* it calls. Invent a serial, use your own
  name, forget one substitution — and it is listening to a path you never emit
  on. Nothing errors: your signal goes out, the bus routes it to nobody.
- **The reply must be on the wire before the signal is.** An older client sends
  no token; it calls, takes the handle it is handed, and subscribes *then*. So
  the slow work — running a modal picker — must **not** happen inside the method
  handler, because a handler's return value is what gets sent. Block there and
  you answer the dialog before the caller ever learns where to listen.

The trap for the test, not just the code: the modern client cannot see the second
bug (it subscribed long before), and the old client cannot see the first (it
never predicts anything). **A live test with one client shape passes with either
bug present.** Both are now driven, and both were injected once to check the
script fails — the emit-before-reply injection left the late client waiting its
full 90s while the modern one sailed through green.

The general lesson, beyond this API: when a protocol has a *hand-off* — I tell
you where to listen, then I speak — enumerate the orderings before writing the
test, not after. And when the same symptom has several causes, one test per cause
or you have covered one of them and believe you covered all.

Related: §2.37 (a suite that has never failed has not been shown to test
anything), and P6.3's missing xdg-shell configure — the same silent-hang shape,
one layer down.

### 2.38 A polite adversary is not an adversary
(P6.5 — the C2 isolation proof. The bench was wrong before the compositor was.)

- **A flooding client that calls `wl_display_roundtrip` throttles itself to
  your own cadence.** A roundtrip waits for the compositor to *answer*, so the
  "flood" can never apply more pressure than the compositor chooses to accept.
  Our first flooder drained every 64 commits that way and the contract bench
  passed at every rate — proving nothing. The hostile version never waits for a
  reply: write until the kernel refuses, poll for writability, write again. The
  distinction between *greedy* and *hostile* is the whole test.
- **Count the load, not just the outcome.** `surfaces-created` is a positive
  control on the adversaries themselves, and it caught a serene `missed=0`
  under "8 hostile clients" that had created **zero** surfaces — they never
  connected. This is §2.37's rule in a new place: a bench whose load fails to
  arrive passes beautifully. (It caught the same class of error twice in one
  afternoon.)
- **Where in the frame you do the work matters more than which thread does
  it.** The compositor collapsed under 32 flooders while dispatching client
  traffic in `pollFlip` — *after* the deadline, between waking and compositing.
  Moving that into the pre-deadline slack, and reserving the last 500 µs for
  nothing but sleeping, took it from 600/600 missed to 0/600 at the same load.
  The threading model was not the lever; the placement was.
- **Watch for the number that falls when it should rise.** After the fix, wake
  latency *decreased* as the refresh rate increased — which looks wrong until
  you see it is backpressure: a shorter period leaves less slack to dispatch in,
  so less gets dispatched. The cadence is preserved and the clients absorb the
  degradation. A metric moving the "wrong" way is worth understanding before
  it is worth celebrating.

### 2.37 A probe with no positive control measures nothing
(P6.1 — the metronome. Third time this file has recorded the same shape, so it
is now clearly a *class* of mistake rather than three accidents: §2.29's `pkg
search`, §2.36's Capsicum control, and this.)

- **Swift allocates through `posix_memalign`, not `malloc`.** An interposer that
  wraps `malloc`/`calloc`/`realloc` — the obvious three — sees almost nothing a
  Swift program does. It does not error, it does not warn: it reports **zero
  allocations**, which is indistinguishable from success and is exactly the
  answer you were hoping for. `libswiftCore`'s dynamic symbol table is the tell
  (`nm -D | grep -E 'malloc|memalign'`).
- **Interposition works in an executable, not in a `.xctest` bundle.** A test
  bundle is a shared object loaded by a runner, so libc wins the symbol lookup
  and the probe is silently blind. That is *why* the allocation gate is a bench
  binary driven by a shell script rather than an XCTest case — not a stylistic
  preference.
- **The rule: a probe that cannot fail has not been tested.** `bench-alloc`
  refuses to report anything until `ap_alloc_probe_works()` has allocated
  deliberately and *seen it*. That control is four lines and it is the only
  reason the number means anything. The same discipline caught §2.36's bad
  Capsicum claim and would have caught the original PHASE6 §4.2 spike, which had
  no control and published a number from a blind probe.
- **And check the meter against the thing it meters.** The first
  `clock_nanosleep` spike printed `rc=0` and I recorded "it works" — but rc=0
  only says the call returned, not that it *slept*. Measuring elapsed time
  around it is one extra line and is the difference between a check and a
  ritual.
- Corollary for benches generally: **a model that agrees with you is not a
  test.** P6.1's synthetic display originally derived each vblank from the
  target the predictor asked for, so the predictor was scored against its own
  guesses and could not fail. Give the model its own independent ground truth.
- **An error message is a diagnostic, and it can lie too.** P6.3's compositor
  threw `.noDisplay` — *"could not create a wl_display"* — when what actually
  failed was `wl_display_add_socket_auto`, three calls later, because the guest
  has no `XDG_RUNTIME_DIR` (§2.31, reaching `swift test` for the first time now
  that a unit test binds a socket). The message sent me to look at the
  compositor when the problem was the environment. **One failure, one case, one
  sentence naming the actual cause** — `.noSocket` now says which call failed
  *and* names the variable. Reusable rule: if two different failures can produce
  the same message, the message is wrong.
- **Reproduce the platform's condition on the dev box before believing the
  fix.** `env -u XDG_RUNTIME_DIR swift test` turns a 20-minute VM round trip
  into a two-second one, and it is what proved the fix rather than the next
  guest run merely not failing.

### 2.36 A control that isn't a control: Capsicum permits `socket(2)`
(P7.5 — the screenshot portal. The bug was in the *proof*, not the code.)

- **`cap_enter(2)` does not forbid `socket(2)`.** Capability mode restricts
  access to **global namespaces**, and an unnamed socket is not in one — so
  creating it is allowed. What it forbids is *naming an address*: `connect(2)`
  or `bind(2)` on a path. The sandboxed client's screenshot control was written
  as "socket(2) must fail", which is simply false, and FreeBSD said so on the
  first guest run — `socket(2) SUCCEEDED inside capability mode`. The right
  control is `connect(2)` to `$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY`: that is the
  call a client would actually need to capture a screen, and it is the one
  Capsicum refuses. §2.29's lesson generalises — **check the probe**, and check
  it hardest when it is the thing the whole demo rests on.
- **The failure was the test working.** `abyssopen` treats "the control
  succeeded while `cap_getmode` says we're confined" as fatal, so a sandbox that
  isn't real cannot pass quietly. That assertion existed because P7.3 argued for
  it, and it is the only reason a wrong premise cost an hour instead of shipping
  as a false claim.
- **A control must fail *because of* the thing under test.** The Linux half now
  asserts the same `connect(2)` **succeeds** — same call, same compositor, no
  sandbox. Without that, "connect failed on FreeBSD" is equally consistent with
  "there was no compositor socket there", and the evidence proves nothing. A
  negative result needs its positive control on the other platform.
- **`--vm --live` is where the design assumption died, not the code.** Nothing
  about this was a portability bug: the Linux run was green and the FreeBSD
  build was green. What FreeBSD provided was the only kernel that could tell us
  the security claim was wrong. Third entry in this file (§2.33, §2.34) where
  the guest caught something no amount of Linux testing could.

### 2.35 The trap you documented is still a trap
(P7.4 — the notification centre, the first thing to *replace* a layer surface.)

- **`LayerSurface` had no `deinit` and no teardown**, and nothing noticed for
  eight months, because every layer surface the shell had ever made — wallpaper,
  menu bar, Dock — lived for the whole process. The notification centre creates
  and destroys one as toasts come and go, and the second toast segfaulted it.
  The cause is **§2.2 exactly**: libwayland keeps the listener pointer, so
  releasing the Swift object leaves the compositor delivering events into freed
  memory. `Window` had had `close()`/`deinit` since P2.6b; `LayerSurface` now
  has the same, with a `tornDown` guard, and callers close explicitly before
  dropping the reference.
- **The lesson isn't "add a deinit".** It is that a documented trap only
  protects the code paths that existed when it was written. A new *lifetime
  pattern* — the first component to destroy a surface rather than hold it — is
  worth re-reading the old traps for.
- **Assert the teardown, not just the effect.** The first version of the live
  test checked that a toast appeared and left the expiry loose; it passed while
  the process was crashing. The assertion that matters is "the surface was
  released **and the component is still running**".
- **An OVERLAY surface takes pointer input wherever it extends**, so a
  notification surface must be sized to its content and destroyed when empty. A
  full-screen transparent one looks identical and silently eats every click.

### 2.34 The hardware bridges: an untyped kernel API, and a font-dependent test
(P3.7 — `vents`: sysctl, OSS, devd.)

- **A sysctl has no type, and guessing "integer first" corrupts short strings.**
  `ventsctl sysctl kern.ostype` printed **19231843050418758** on its first run:
  `"FreeBSD\0"` is *exactly eight bytes*, so it reads as a perfectly plausible
  `Int64`. Any display path must test **printability before numeric width**
  (`Sysctl.display` does). The unit tests could never have caught this — only a
  real kernel has a `kern.ostype` — which is the argument for live tests in one
  line.
- **`<sys/sysctl.h>` is invisible to Swift, so sysctl needs C** exactly as the
  variadic `ioctl` does (§2.30). PHASE3.md had assumed sysctl was callable
  straight from Swift; it isn't. devd, by contrast, needed no C at all — it is a
  unix socket carrying newline-delimited text.
- **devd values can contain spaces, inside quotes.** A real CAM error looks like
  `CDB="00 00 00 00 00 00 "`; splitting fields on whitespace loses the field and
  mangles the rest. Parse quotes.
- **A pixel probe positioned relative to text is font-dependent.** The
  status-item check sampled one coordinate left of the clock, which passed on
  the dev box (Noto) and landed on bare pinstripe in the VM (DejaVu), where the
  clock is a different width. Scan a *strip* and count dark pixels instead — and
  pass `od -v`, or od collapses repeated identical lines to `*` and most of the
  strip silently disappears.
- **Absence is a first-class reading.** The VM has no mixer and no battery, so
  every bridge returns nil there and the status items hide. That is the intended
  behaviour, and the test asserts it: a facility that isn't present must be
  *reported* absent, never rendered as a confident 0%.

### 2.33 The session supervisor: two bugs that only showed up on FreeBSD
(P3.6 — `anchor`. Both cost real time; both are one-liners once seen.)

- **An accepted connection inherits `O_NONBLOCK` from the listener on the BSDs,
  and does NOT on Linux.** Any service hosted inside an event loop polls its
  listener, so its listener is non-blocking — and on FreeBSD every accepted
  connection then was too. `recvmsg` returned `EAGAIN` whenever the request
  hadn't arrived in the microsecond since `accept`, the service dropped the
  client, and the client's next write got EPIPE. It failed **about half** of all
  `abyssctl quit` calls on FreeBSD and **never once** on Linux. `Server.accept`
  now clears `O_NONBLOCK` explicitly and sets an `SO_RCVTIMEO`, so a silent
  client can't stall a supervisor either. If you write a service, do not assume
  the accepted socket's mode — set it.
- **SIGPIPE kills a client silently, and it looks like the server ignored you.**
  `abyssctl quit` died with status 141 and *no output*, which reads exactly like
  a supervisor that took the request and did nothing. A socket library must not
  leave this to its callers: `CurrentIPC` now sends through
  `ap_send_all`/`ap_sendmsg_fds` with **MSG_NOSIGNAL** (a macro Swift can't see,
  hence C) and sets **SO_NOSIGPIPE** where it exists, so a vanished peer is an
  `EPIPE` error a caller can report. The supervisor separately ignores SIGPIPE,
  because a `| head` on its log must not be able to kill the session.
- **Diagnostic worth reusing:** an empty stderr with a non-zero exit almost
  always means a signal. `rc=141` is SIGPIPE, `139` SIGSEGV — checking the exit
  code first turned "quit failed" from a mystery into a one-line fix.
- **A flake that reproduces 1-in-3 is a bug, not the weather.** It passed
  standalone and failed inside the full sweep; running it eight times in a row
  in the guest is what made it findable.

### 2.32 The control plane: passing a descriptor from Swift
(P3.5 — `CurrentIPC`, the P2.9 carry.)

- **`cmsg(3)` is entirely macros, so fd passing needs C.** `CMSG_FIRSTHDR`,
  `CMSG_DATA`, `CMSG_SPACE`, `CMSG_LEN` are all `#define`s and Swift's importer
  cannot see macros — the third time this wall has appeared (§2.1's
  static-inline requests, §2.30's `<sys/sysctl.h>`). `ap_sendmsg_fds` /
  `ap_recvmsg_fds` live in `CPlatform` for this reason; the C is 80 lines and
  identical on both platforms.
- **Send the descriptors with the LENGTH PREFIX, not the body.** The kernel
  delivers SCM_RIGHTS ancillary data alongside the first byte of the transfer it
  accompanied, so the receiver's one `recvmsg` must be the read that gets the
  4-byte length — then the body follows over ordinary reads. Attaching the fds
  to the body instead means a receiver that reads the length first has already
  lost them.
- **A message must never carry an fd in its byte stream.** Descriptors travel
  out of band, so the wire format stores an *index* into the SCM_RIGHTS array.
  Without that, two attached fds are indistinguishable on the far side.
- **Decide who owns a received descriptor, and write it down.** Ours: `set(fd:)`
  borrows (keep it open until `send` returns); a received `Msg` owns what
  arrived, and the reader either `takeFD`s it (and must close it) or `closeFDs`.
  Every error path in `receive` closes the fds it had already collected —
  otherwise each malformed message a peer sends leaks a descriptor. The C side
  likewise closes any fd beyond the caller's cap rather than dropping it.
- **`sun_path` is 108 bytes on Linux, 104 on FreeBSD** — and truncating a path
  that doesn't fit silently binds a *different* socket. `CurrentIPC` throws
  instead, which tripped on the first manual run because the scratch directory
  was 127 characters. Anything that builds a socket path (tests especially)
  should keep the runtime dir short — `live-ipc.sh` uses `/tmp` rather than
  `$TMPDIR` on purpose.
- **`SOCK_STREAM` imports as a different Swift type per platform** —
  `__socket_type` on Linux (needing `.rawValue`), a plain `Int32` on the BSDs.
  One private constant behind `#if os(Linux)` keeps the call sites identical.

### 2.31 The harness on FreeBSD: two whitespace bugs, one of them mine
(P3.4 — getting all 31 live modes green in the guest.)

- **FreeBSD's `od(1)` prints a trailing space after the last value; GNU's does
  not.** The grim pixel probes compare a string, so `"32 64 128 "` vs
  `"32 64 128"` failed on *identical pixels* — and the failure message read
  "the desktop didn't paint its configured bg", which is a lie that costs real
  time. `tr -s ' '` does not help: it squeezes runs, it doesn't trim. Normalise
  the fields instead: `od -An -tu1 | awk '{ print $1, $2, $3 }'`. `live-sway.sh`
  had happened to add `s/ $//` and `live-session.sh` had not, which is why
  exactly one mode failed.
- **`XDG_RUNTIME_DIR` does not exist on FreeBSD** (no pam_systemd). sway aborts
  without it and `set -u` trips first, so every live test died before starting.
  `abyss/common.sh` now provides `abyss_ensure_runtime_dir` (a per-uid 0700 dir
  under `$TMPDIR`), sourced by `live-sway.sh`, `live-session.sh` and
  `session.sh` — one copy, because three would drift.
- **A `for entry in $table` word-splits entries that contain spaces.** My own
  bug in `run-live.sh`: rows like `widgets-click:widgets --click` became two
  bogus modes, and the only symptom was an absurd `skipped=39` in a table of 31.
  Read the table a line at a time instead, from a here-doc on **fd 3** so the
  inner command keeps its own stdin and the counters stay in the current shell
  (a pipeline would put them in a subshell and silently report zero).
- Everything else was already portable: the virtual-input C helpers build with
  base clang because they take their flags from `pkg-config`, the
  `sway-ipc.*.$pid.sock` glob and `swaymsg exec`'s env dump (§2.26) work
  unchanged, and headless sway needs no seatd.

### 2.30 Running on FreeBSD: sysctl is invisible, and a bug that could only
### exist on the target
(P3.3 — first pixels in the guest, headless and live under sway.)

- **Swift's libc module surfaces no `<sys/sysctl.h>` on FreeBSD.** Both
  `sysctl` and `sysctlbyname` fail with `cannot find … in scope`, even though
  `import Glibc` works and the symbols are in libc. Anything needing them takes
  a C shim — hence **`CPlatform`** (`de/cplatform`), one call
  (`ap_self_executable`) with the `#ifdef` inside C: `KERN_PROC_PATHNAME` on
  FreeBSD (there is no procfs mounted by default, so `/proc/curproc/file` is not
  an option either), `/proc/self/exe` on Linux. P3.7's `vents` sysctl bridge
  grows in the same place.
- **A font list that only covers *regular* silently un-bolds the UI.**
  `ctext.c` had `/usr/local/share/fonts/dejavu/DejaVuSans.ttf` in the regular
  list, but the bold / italic / bold-italic lists carried only Linux paths — and
  a style that finds no primary falls back to regular *by design*, so text still
  renders and nothing errors. Every bold run on FreeBSD was quietly regular.
  When adding a font path, add it to **all four** lists and the fallback list.
  This class of bug is invisible on the platform you develop on.
- **libwayland on an epoll-over-kqueue shim is a non-event.** `wl_display_get_fd()`
  hands back a libepoll-shim fd; the poll-timeout run loop (§2.14) needed no
  change — the client maps, paints and keeps its frame callbacks.
- **FreeBSD sets no `XDG_RUNTIME_DIR`** for an ssh session (no systemd, no
  pam_xdg). Anything that runs sway or looks for a Wayland socket must provide
  one — `/tmp/xdg-$(id -u)` at mode 0700 works.
- **`wayland-scanner` output is identical across platforms.** Regenerating all
  four protocols in the guest produced 8 files byte-for-byte equal to the
  committed ones, so the generated glue is genuinely portable.

### 2.29 Building on FreeBSD: `/usr/local`, and where pkg-config flags come from
(P3.2 — the first build of this repo on FreeBSD. It cost **one Package.swift
change and no source changes**; all 62 tests passed.)

- **A SwiftPM C target cannot carry `pkgConfig:` — only a `systemLibrary` can.**
  `CWayland` linked wayland with `linkerSettings: [.linkedLibrary("wayland-client")]`
  and no include flags at all, which worked purely because Linux keeps the
  headers in `/usr/include`. FreeBSD puts them under `/usr/local/include`, so
  the build died on `'wayland-util.h' file not found`. The fix is the pattern
  already in the tree: a `CWaylandClient` **systemLibrary** with
  `pkgConfig: "wayland-client"` that `CWayland` **depends on** — dependent
  targets inherit a systemLibrary's pkg-config cflags/libs, which is how `CText`
  gets FreeType and HarfBuzz. Prefer that to `unsafeFlags(["-I/usr/local/..."])`:
  it's portable rather than a FreeBSD special case, and `unsafeFlags` would make
  the package unusable as a dependency.
- **`canImport(Glibc)` is TRUE on FreeBSD.** Swift names the platform libc
  module `Glibc` there. Every `#if canImport(Glibc)` in the tree took the right
  branch untouched — the feared twenty-file edit cost nothing. Don't "fix" those
  guards.
- **FreeBSD 15 has a native `timerfd(2)`**, so `<sys/timerfd.h>` and
  `timerfd_create` compile as-is — no kqueue `EVFILT_TIMER` fallback needed for
  the menu-bar clock.
- **FreeBSD's libwayland is built on an epoll-over-kqueue shim**:
  `pkg-config --cflags wayland-client` yields
  `-I/usr/local/include/libepoll-shim`. So `wl_display_get_fd()` returns a shim
  fd rather than a native one. It compiles and links fine; the place to be
  careful is §2.14's `prepare_read`/poll-timeout loop, the first time a client
  actually runs there.
- **`warning: prohibited flag(s): -D_THREAD_SAFE` on every build is benign.**
  FreeBSD's `cairo.pc` carries `-D_THREAD_SAFE`; SwiftPM refuses to forward `-D`
  flags out of pkg-config and drops it. Harmless for our single-threaded
  painting — `abyss/vm/build.sh` filters the line so it doesn't drown the
  transcript.

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
| `--menubar --status` | the volume/battery **menu extras** are drawn (fed by `Vents`, or the documented test seam) |
| `--pick` / `--cancel` | the Finder as a **portal picker**: choose → path + exit 0, Escape → exit 1, nothing launched |

**Run them all:** `abyss/tests/run-live.sh` drives every mode in order with a
per-mode timeout and prints a pass/fail table (`-o DIR` keeps the PNGs and logs,
or name a subset: `run-live.sh dock trash`). 35 modes today. These are the
*sway-hosted* modes; `undertow`'s own tests are separate scripts, listed below.

**Tests that need no compositor** (all in `run.sh`'s default lane):

| Script | What it proves |
|---|---|
| `live-ipc.sh` | two real processes hand a **descriptor** over the control plane |
| `live-vents.sh` | sysctl agrees with `sysctl(8)`; **real devd events** (it creates and destroys an `md(4)` disk); absent facilities report absent |
| `bench-metronome.sh` | the frame contract: C1 cadence, and an **allocation-free** present path enforced by a probe with a positive control (§2.37) |
| `live-undertow.sh` | a real client on **our own compositor** — no sway anywhere |
| `live-undertow-input.sh` | input reaching that client through our seat, driven by the **unmodified** `vpointer` that drives sway |
| `live-undertow-c2.sh` | **C2**: eleven hostile processes cannot make us drop a frame, while a healthy client keeps drawing (§2.38) |
| `live-undertow-shell.sh` | the Jaguar shell — wallpaper, menu bar, Dock — composing on `undertow` |
| `live-undertow-places.sh` | a window reopens where it was dragged, in a **new session** (§2.22's debt) |
| `live-dbus.sh` | we speak D-Bus, and `dbus-send`/`gdbus` — somebody else's encoder — agree |

**Tests that need a compositor** (in `run.sh --live`):

| Script | What it proves |
|---|---|
| `live-anchor.sh` | the **Swift supervisor**: kill a component, it comes back; `abyssctl quit` leaves no orphans |
| `live-portal.sh` | three processes: a client gets an fd for a file **it never named** |
| `live-portal-dbus.sh` | five processes: `dbus-daemon`, sway, `abyss-portal`, `abyss-dbus`, a caller. Both client shapes (§2.39), and **`dbus-monitor` decodes our `Response` signal with libdbus's parser** |
| `live-gtk.sh` | six processes, and the important one is not ours: a **stock GTK 3 app** on `undertow` gets the Finder from `GtkFileChooserNative` and reads a file it never named. Asserts the `Response` was *addressed* (§2.40) and that the compositor **exited cleanly after its input client left** (§2.41). Skips loudly (exit 77) with no GTK runtime |
| `live-session-gtk.sh` | the same claim with **one command**: `anchor` brings up compositor, bus, portal, bridge and shell, and a stock GTK app gets its file. Asserts **nothing restarted** — the assertion that tells a dependency gate from a race — that the bridge owns the portal name on the bus anchor exported, and that `quit` leaves no stray `dbus-daemon` |
| `live-sandbox.sh` | the client is in **capability mode** and `open(2)` fails, yet it reads the file |
| `live-notify.sh` | a notification crosses the portal, becomes a toast, reserves no space, and its surface is released on expiry |

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

**The full loop.**

```sh
abyss/tests/run.sh                 # build + 234 unit tests + smoke render + the
                                   # no-compositor live tests (incl. undertow)
abyss/tests/run.sh --live          # ... and all 35 compositor modes
abyss/tests/run.sh --vm            # the same, inside the FreeBSD VM
abyss/tests/run.sh --vm --live     # the gate before calling a pass done
```

The 234 unit tests are pure logic — no compositor, no network: toolkit geometry,
the Finder's listing/naming/scroll model, desktop-icon layout, launcher
resolution, PoolConfig's read/write/watch, the CurrentIPC codec and descriptor
passing, the supervisor's restart policy and the shape of the session it starts,
the hardware bridges' parsing, the portal's refusals, toast layout/expiry, the
compositor's metronome and layer arithmetic, the D-Bus wire format's alignment
rules, and the portal bridge's path derivation, URI escaping and Settings
namespace matching.

**Both platforms, every time.** Phase 3 earned this rule: two bugs
(`O_NONBLOCK` inheritance on `accept`, a string sysctl read as an integer) were
invisible on Linux and failed only on FreeBSD. A pass is not done until
`run.sh --vm --live` is green.

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

**Where things stand.** Phases 0–3 and 6–8 are complete. The Jaguar shell runs on
FreeBSD, on our own compositor, over a Swift control plane, session supervisor
and hardware bridges — and **one command boots a desktop where an unmodified GTK
3 application opens a file through the Finder**. **234 unit tests and 35 live
modes, green on Linux and FreeBSD.**

### The next pass is P5.1

The 2026-08-23 choice between Phase 4 and Phase 5 was settled the next day:
**Phase 5 is scoped** ([PHASE5.md](PHASE5.md), P5.1–P5.5), with its four risks
retired on the target first (PHASE5 §4).

**P5.1 — `de/install`: the install as a value.** An `InstallPlan` that compiles
to a step list — the exact `gpart`/`newfs_msdos`/`zpool`/`tar` invocations, in
order — plus the safety predicate that refuses a plan naming a mounted disk, the
running root, or something that is not a whole disk. Pure, in `Session.swift`'s
image: it resolves nothing and spawns nothing, so **every bit of it is testable
on Linux**, where not one of those commands exists. Do the refusals first; it is
the only predicate in this tree whose failure mode is somebody's data.

Then **P5.2**, which is where the phase's claim comes true: `abyss-install` runs
the step list as root, and `abyss/tests/live-install.sh` installs onto a
file-backed disk in the VM and **boots the result under nested bhyve**. The
definition of "it worked" is `login:` — everything before that line is a
diagnostic.

### The other phase that is left

- **Phase 4 — Mac Pro bring-up.** The real hardware story, and where the
  volume/battery status items finally read a real mixer and battery rather than
  reporting absent (P3.7). It is also the biggest single risk left: `amdgpu`
  `si_support` for the FirePro D-series. **And it is where Phase 6's C1
  measurements should be repeated** — every number in PHASE6.md came off a
  headless backend with a synthetic clock, and a real GPU with `rtprio` is the
  only place they mean what they claim. **It now also owns the metal half of
  Phase 5's verify**: PLAN.md wants a clean install onto the Mac Pro, and that
  needs the Mac Pro to boot first.

### Standing smaller items, none blocking

- **Golden-image tests** — snapshot the deterministic PNG scenes and diff in CI
  (`finderSampleEntries`/`desktopSampleEntries` exist for exactly this). The
  cheapest guard against silent visual regressions, and the surface worth
  guarding keeps widening.
- **A real Aqua save panel** — `file.save` currently leans on ⌘S saving into the
  folder on screen, because picking from a listing cannot name a file that does
  not exist yet (PHASE7.md P7.2). A name field and a New Folder button would
  replace it. **P8.2 raised the stakes slightly**: `SaveFile` now reaches this
  stopgap from the session bus too, carrying a `current_name` a real panel would
  put in that field.
- **A confirmation sheet for Empty Trash**, once something can host a dialog for
  a layer surface (§2.27).
- **Dragging desktop icons** — needs remembered per-item positions in config.
  **Re-scoped in P6.7:** this was filed as needing Phase 6, but §2.22 is about
  *windows*; desktop icons are drawn by the wallpaper **client** into its own
  layer surface, and dragging them needs only pointer events on that surface plus
  a position in config — both available since Phase 2. It is shell work, not
  compositor work.
- **One dialog at a time** (PHASE8 §6.7) — `abyss-portal` blocks while the picker
  is up, so `abyss-dbus` does too. A `Request.Close` sent mid-dialog is not seen
  until the picker exits. Worth fixing when something needs it; not worth threads
  now.

### Two rules that earned their place

**A pass is not done until `abyss/tests/run.sh --vm --live` is green.** Two
Phase-3 bugs were invisible on Linux and failed only on FreeBSD (§2.33, §2.34).

**A test that has never failed has not been shown to test anything.** Phase 6 and
Phase 8 both caught a false pass by deliberately breaking the code and checking
the suite noticed (§2.37, §2.39). It costs ten minutes and it is the only thing
standing between "green" and "green for the reason I think".

## 6. Gotchas inherited from the sibling (still true here)

- `abyss/vm/sync.sh` uses `rsync --delete` — it wipes the in-VM target dir; the
  Swift `.build/` is gitignored and absent on a fresh sync, so rebuild after the
  last sync.
- The VM home defaults to `../abyss-swift-vm` (separate from the sibling's
  `../abyss-vm`) so we don't clobber the Rust project's VM. Set
  `ABYSS_VM_HOME=../abyss-vm` to reuse that already-provisioned box.
- One commit per pass, with the pass number in the subject (`P7.4: notifications
  …`) — `git log --oneline` is a readable history of how this was built, and each
  commit body records **what was verified**, not just what changed. Keep that up:
  several of those bodies are the only record of why a design went the way it did.
- Swift lives **off PATH** in the guest (`/usr/local/swift6/bin`), and a
  non-interactive `ssh host 'cmd'` reads no profile — so use `abyss/vm/build.sh`
  or `abyss/tests/run.sh --vm` rather than ssh'ing `swift` by hand (§2.28).

---

## 7. Pointers

**Where things live** (Swift/C targets under `de/`, mirroring the sibling tree):

| Path | What |
|---|---|
| `de/cwayland` | libwayland + generated protocols + the `aw_*` shim (§2.1) |
| `de/surface` | the client runtime: `Display`, `Window`, `LayerSurface`, `Popup`, `Keyboard`, `ForeignToplevels`, `Activation`, `Screencopy` |
| `de/aqua` | the toolkit + the shell: `Theme`/`Draw`/`Text`/`Icons`, `Wallpaper`+`DesktopIcons`, `MenuBar`, `Dock`, `Finder`(+`FinderModel`/`FinderOps`), `Launcher` |
| `de/poolconfig` | config read/write/watch (`CPoolWatch` is the platform fork) |
| `de/cplatform` | platform facts Swift can't reach — `ap_self_executable` (`KERN_PROC_PATHNAME` / `/proc/self/exe`, §2.30) and SCM_RIGHTS fd passing (§2.32) |
| `de/dbus`, `de/dbusprobe` | **D-Bus, hand-written**: marshalling, SASL EXTERNAL, framing, dispatch — no libdbus/GDBus/sd-bus (PHASE8 §4.1). `dbusprobe` is driven by `dbus-send`/`gdbus` so the other end is never ours; its `portal-open` / `portal-open-late` modes are the **two client shapes** of §2.39 |
| `de/dbusportal`, `de/dbusbin` | the bridge: `RequestHandle` (the object path a client predicts *for itself*), `ChooserOptions`, `FileURI`, `PortalSettings` (what we tell a foreign toolkit about how the desktop looks), and the service that queues the picker **out of** the method handler and **addresses** its `Response` — plus `abyss-dbus`, which owns `org.freedesktop.portal.Desktop` |
| `de/currentipc` | the control plane: `Msg` + wire format, `Current.Server`/`connect`/`call` (§2.32) |
| `de/cproc` | process supervision: every child a pollable fd (`pdfork`/`pidfd`) + a signal self-pipe (§2.33) |
| `de/anchor`, `de/anchorbin` | `Anchor` (restart policy, the session plan, dependency gating, poll loop, control service) and the `anchor` binary — replaces `abyss/session.sh`, and since P8.4 starts the **whole** desktop: compositor, bus, portal, bridge, shell |
| `de/abyssctl` | `abyssctl status\|quit` — drive a running session over the control plane |
| `de/portal`, `de/portalbin` | the file-chooser portal: `PortalRequest` (the confused-deputy rule, enforced by the type), the service, `abyss-portal` |
| `de/abyssopen`, `de/ccap` | the sandboxed client (files **and** `--screenshot`) and Capsicum's `cap_enter` |
| `de/abyssnotify` | `notify-send`, brokerless — through the portal, as a jailed app would |
| `de/abyssgrab` | capture an output to a PNG via `wlr-screencopy`; the portal forks it, so the portal itself is never a Wayland client |
| `de/undertow`, `de/undertowbin` | **the compositor** (PHASE6.md): `Metronome`, `FlightRecorder`, `Output`/`FrameSink`, `Backend` (the wlroots bridge), `Compositor` (globals, socket, windows), `SurfaceScene` (our SoA scene — deliberately **not** `wlr_scene`), `Seat` (input, cursor, focus; `PointerRouting` is the pure hit-test) and `LayerShell` (the shell's surfaces; `LayerArrange` is the pure placement rule) — `undertow` is its own bench harness |
| `de/cwlroots` | **29 lines of C**, and that is the whole wlroots binding: Swift imports the headers directly, but `wl_signal_add` is a static inline and `wl_container_of` is a macro, so every wlroots event arrives through one trampoline (§2.1 at scale) |
| `de/cwlrootssys`, `de/cwaylandserver` | pkg-config flag carriers for wlroots-0.19 and libwayland-**server** (§2.29's pattern) |
| `de/callocprobe` | counts allocations by symbol interposition; the enforcement half of PLAN.md risk 4. **Executable-only, and useless without its positive control** (§2.37) |
| `de/vents`, `de/cvents` | the hardware bridges: sysctl, OSS volume, battery, devd (§2.34) |
| `de/ventsctl` | `ventsctl sysctl\|volume\|battery\|devd` — read the machine by hand |
| `de/ipcprobe` | `ipcprobe serve|send` — two processes, one descriptor; driven by `abyss/tests/live-ipc.sh` |
| `de/aquademo` | the runnable demo; `AQUA_SCENE` picks a scene/component |
| `abyss/session.sh` | the dev session launcher — one command boots the desktop (§2.26) |
| `abyss/tests` | `run.sh` (build+test+smoke; `--live`, `--vm`), **`run-live.sh`** (all 35 live modes, pass/fail table), `live-sway.sh`, `live-session.sh`, `live-portal.sh`/`live-sandbox.sh`/`live-notify.sh`/`live-screenshot.sh`/**`live-portal-dbus.sh`**/**`live-gtk.sh`**/**`live-session-gtk.sh`** (the portals, driven from `run.sh --live`), `live-dbus.sh`, `gtkpick.c` (a stock GTK client, `dlopen`ed so nothing here links GTK), the virtual input helpers |
| `abyss/tests/adversary.c` | hostile Wayland clients for C2: `hard` (flood, never waits for a reply), `zombie`, `deaf`, `churn` (§2.38) |
| `abyss/common.sh` | shared sh helpers — `abyss_ensure_runtime_dir` (§2.31) |
| `abyss/vm` | the FreeBSD build VM: `config.sh` (incl. `ABYSS_GUEST_SWIFT_BIN`), `fetch-image.sh`, `make-seed.sh`, `run.sh`, **`check.sh`** (is the guest usable?), `ssh.sh`, `sync.sh` |
| `protocols/` | vendored protocol XML; regenerate via `de/cwayland/generate-protocols.sh` |

**Adding a Wayland protocol** is mechanical: drop the XML in `protocols/`, add a
`gen` line to `generate-protocols.sh`, list the generated `.c` in
`Package.swift`, add one-line `aw_*` wrappers (§2.1), and fill **every** listener
slot (§2.3). **`wlr-screencopy` (P7.5) is the most recent worked example**, and
the most complete one — it binds a manager, creates a per-request object, fills
all seven of its events, and has a version fallback (`buffer_done` is v3+, so
below that the `buffer` event stands alone). Regenerating also proved the other
four protocols come out byte-identical, so the committed glue is safe to
regenerate at any time.

**External:**

- Architecture canon (Rust sibling): `../AbyssBSD/abyss/docs/{DESKTOP,SEAMS}.md`.
- Reference implementations to **rewrite from** in Phase 3+ (read, don't link):
  `../AbyssBSD/abyss/de/{tide,anchor,vents,…}`,
  `../AbyssBSD/abyss/ipc/{current,pool,shmring}`. `PoolConfig` is how that goes:
  same on-disk format, all-new Swift. Note the sibling's shell targeted
  **GNOME 2**, not Aqua — adapt its algorithms, don't copy them.
- Agent memory: `abyssbsd-swift-project`, `abyssbsd-swift-status`,
  `reef-targeted-gnome2`.
