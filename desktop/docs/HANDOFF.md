# AbyssBSD (Swift DE) — Handoff & Lessons

What has been built, what we learned building it, and where the traps are.
Read [STATUS.md](STATUS.md) for the current build state, the phase docs
([PHASE2.md](PHASE2.md), [PHASE3.md](PHASE3.md), [PHASE4.md](PHASE4.md),
[PHASE5.md](PHASE5.md), [PHASE6.md](PHASE6.md), [PHASE7.md](PHASE7.md),
[PHASE8.md](PHASE8.md), [PHASE9.md](PHASE9.md), [PHASE10.md](PHASE10.md), [PHASE11.md](PHASE11.md), [PHASE12.md](PHASE12.md), [PHASE14.md](PHASE14.md)) for ordered passes, [PLAN.md](PLAN.md) for the multi-year roadmap, and [API-STUDY.md](API-STUDY.md) for what an outside study of applications says about both; this doc is
the *practical knowledge* layer.

Last updated: 2026-09-26. **Phases 0–3, 5–11 are complete; Phase 14 is in progress (P14.1 done); Phase 4 is in flight
on metal and Phase 12 is mostly done.** The Jaguar shell runs on FreeBSD,
on **our own compositor** (`undertow`), over a Swift control plane, session
supervisor and hardware bridges; the portals hand out descriptors; **one command
boots a desktop where an unmodified GTK 3 application, which has never heard of
this desktop, opens a file through the Finder**; since Phase 9 it is a desktop
you can *use*; since Phase 10 applications publish their menus to our bar (GTK's
and Qt's included); and since Phase 11 **its look is data** — Jaguar re-expressed
pixel for pixel, and a second theme, Trench, that no code names.
**592 unit tests, 33 live modes and 40 live scripts, green on Linux and FreeBSD,
and a golden gate of 72 scenes on each.**
**Phase 5 — the installer — is COMPLETE** ([PHASE5.md](PHASE5.md), P5.1–P5.5): a
machine with an empty disk boots our medium, the Aqua installer comes up on it,
and it reboots into the Jaguar desktop as the account that was created — proven
on every run, nested twice over, with no hardware and no human.
**On metal** (an i7-12700KF with an RX 6750 XT, PHASE4 §1.1) **the stick boots,
`amdgpu` binds, and the Aqua installer is on screen**: PHASE4 §5 steps 1–5 pass.

**Picking this up cold?** **The ordered list of everything open is
[BACKLOG.md](BACKLOG.md)** (2026-09-28): `undertow`'s defects first (U.1–U.4),
then Phase 14 from P14.2, then what Phase 15 needs; metal work is batched for
one sitting, because the bring-up machine's USB is in use elsewhere for now.
The items below are the context for it.

1. **The phase in progress is 14, preferences that write** — scoped in
   [PHASE14.md](PHASE14.md), §6's recommendations adopted (all but §6.5).
   **P14.1 is done**: System Preferences is an application — 25 panes drawn
   from the theme's icon set, one layout for paint and hit-test, an honest
   page per pane ("cannot change anything yet"), pointer, keyboard and a
   Phase 10 vocabulary (`menus.systempreferences.<pid>`), driven live by
   `live-prefs.sh` on both platforms. **P14.2 is done** (2026-09-28): the
   theme changes while the desktop runs — the General pane or `abyss-theme
   set` writes `appearance.ini`, and `undertow`, every toolkit process and the
   portal (`SettingChanged`) follow, checked in pixels and back byte for byte
   (`live-appearance.sh`). **P14.3 is done** too: `abyss-settings`, the
   privileged half, in the installer's shape — typed plans, `wheel` asked at
   every connection, `rc.conf` written with `sysrc` whole or not at all, an
   `rc.d` service on installed systems. **P14.4 is done**, its reboot gate
   green: the Network pane (wired) shows the kernel's status beside
   rc.conf's configuration and applies through the helper
   (`live-network-pane.sh`); `live-network-reboot.sh`, in `--full`, reboots
   an installed machine and checks the address held. **P14.6 is done** too
   (2026-09-28): §4.3's spike answered — per-application volume is read-only
   now, `virtual_oss` in Phase 18 — and the Sound pane, the default device
   through the helper (`sysctl.conf`), and a real volume item in the menu
   bar, all driven on the guest's `snd_dummy`. **Next is P14.7**, Displays
   (`wlr-output-management-v1`), the one pane with no FreeBSD-only half. **Open, for the person:** §6.5,
   whether the i7-12700KF has a Wi-Fi card. **Phase gates** (`run.sh --live`,
   `--vm --live`, `--full`) are run only when the phase closes.
   **Phase 11, the theme system, is COMPLETE**
   ([PHASE11.md](PHASE11.md)): a theme is a directory of data (tokens, draw lists,
   an icon set), Jaguar is proved byte-identical to the Swift it replaced,
   Trench — the Plan Neo chrome study — is the second theme, and there is a
   legibility floor and a portal that tells foreign toolkits the real theme.
   **Phase 10, the menu protocol, is COMPLETE** ([PHASE10.md](PHASE10.md)). Both
   closed with `run.sh --live` and `run.sh --vm --live --full` green.
   **The PHASE11 §6 decisions still wait for confirmation** (the menu-bar rule and layer 5,
   refuse/warn, icons as data, `calc()` operands).
2. **Phase 4 has one open result, and it is a failure: the frame contract does
   not hold on real hardware.** 58 of 300 frames missed while compositing in
   12 µs (PHASE4 §5.7). Run mode now reports the margin's four terms separately,
   and **that breakdown has never been run on the machine** — one
   `abyss/mk/metal.sh report` on an `--ssh-key` medium tests the written
   hypothesis. That is the whole diagnostic loop now; nobody photographs a
   screen any more (PHASE4 §5.8).
   **Also open, for metal (2026-09-28):** a review of the NeoDarwin platform API
   study against our tree ([API-STUDY.md](API-STUDY.md)) found four `undertow`
   defects nested runs cannot show. The keymap one is fixed (§2.70); **no
   `linux-dmabuf`**, **subsurfaces never drawn** and **a minimised window's
   frame clock withheld** are not (API-STUDY §1.2–1.4).
3. **What is settled, so nobody re-asks it.** The Mac Pro is the matrix's second
   row, not the target; `si_support` is a matrix cell, not a gate. **Installing
   onto the bring-up machine is deferred** until the desktop is mature (its only
   disk is the positive control), which retired P4.6's install half and P12.6.
   `Fathom` (Phase 12) was pulled forward instead and P12.1–P12.5 are in.
4. Read §1 for what exists. It is long; the newest parts are **Phase 11**,
   **Phase 10** and **Phase 4 so far**. **Read §2.43–§2.59 before writing anything** — almost
   every one of them was found by *running* something rather than reading it,
   and together they are why the recent phases are verified the way they are.
5. Skim the §2 index for the trap nearest what you're about to touch. **The
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
   - **§2.48** — a nested compositor presents when its *host* does, so a
     frame-contract number measured there is measured against somebody else's
     clock. And a real display's size is the truth, not your command line.
   - **§2.47** — `getty` calls `revoke(2)` on the console, so a backgrounded
     service goes mute the moment a login prompt appears. Silent, and it looks
     exactly like a crash.
   - **§2.46** — a GUI cannot be trusted to be right about itself: twenty
     green model tests missed a screen that looked like it worked. And never
     put coordinates in a test that clicks — make the app publish them.
   - **§2.45** — a package manager's closure is not your program's closure
     (5.66 GB vs 327 MB); and a silent graceful fallback is invisible to every
     test downstream unless something announces it.
   - **§2.41** — whose lifetime is this listener, exactly? A compositor must
     outlive its input client, and only a test that shuts down in the right
     order will ever say so.
   - **§2.44** — an install that reports success is not an install that
     worked. Every step said ok, the log said ok, and the machine booted to the
     loader prompt. Where the output is a *thing*, assert on the thing.
   - **§2.43** — a list of commands is not verified until something runs it. A
     plan with 28 tests and a golden render was wrong in four ways, each of
     which shipped a broken machine; all four were found by executing it.
   - **§2.42** — name your sockets instead of reading back what something else
     chose, and test readiness by connecting. A discovered address is one that
     changes under you.
6. Confirm the box still works:

   ```sh
   sh abyss/tests/run.sh            # build + 538 unit tests + the fast live tests
   abyss/vm/check.sh                # is the FreeBSD VM up and usable?
   sh abyss/tests/run.sh --vm       # ... and does the guest still build + test?
   ```

   The VM may not be running after a break — `ABYSS_DAEMON=1 abyss/vm/run.sh`
   boots it, and first boot after a reset takes ~15 minutes (§2.28). Everything
   in `abyss/vm/` is idempotent, so re-running is safe.

---

## 1. What got built (Phases 0–3, 5–8 and 9, and Phase 4 so far)

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
- **The whole harness passes there** (§2.31): all the live modes, not just the build.
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

- **Phase 5 put it on a disk.** `de/install` is the install as a *value* — an
  `InstallPlan` compiled to a step list of exact `gpart`/`zpool`/`zfs`/`tar`
  invocations, with the refusals as a pure function of plan-and-machine, so a
  Linux unit test can build the exact machine on which one must fire.
  `abyss-install` runs that list as **root**; the Aqua installer commands it as
  an **unprivileged** process over `CurrentIPC`, and the socket is handed to one
  uid and the caller checked against it. `abyss/mk/live-image.sh` builds the
  medium out of the same distribution sets the installer extracts — the runtime
  closure computed with `ldd` rather than resolved by a package manager (§2.45)
  — and the whole arc runs in the harness, nested twice over: **a blank disk
  becomes a machine running the Jaguar desktop**, as the account the installer
  created.
- **Phase 4 is on metal, and it is the first phase a test cannot finish.**
  `undertow` chooses its backend (`--backend auto`: DRM on metal, nested inside
  another compositor, headless by default). On the i7-12700KF / RX 6750 XT the
  stick boots, `amdgpu` binds at 2560x1440 and **the Aqua installer is on
  screen** (PHASE4 §5.3–§5.6), after three fixes no VM could have found: the
  dlopened Mesa driver (§2.52), libglvnd's vendor chain (§2.54), and a
  `--frames` default that made a desktop exit like a bench. `Fathom` (Phase 12)
  measures the machine and writes the report to the ESP; its first C1 against a
  real vblank **fails** (PHASE4 §5.7). An `--ssh-key` medium plus
  `abyss/mk/metal.sh` drives the machine from here. Installing onto it is
  deferred.

The screenshots in `docs/screenshots/` are the evidence trail; `first-window.png`
and `system-preferences.png` are the Phase-1 originals, `freebsd-*.png` are the
Phase-3 ones, and `live-medium.png` / `installer.png` are Phase 5's.

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
| 2.43 | A list of commands is not verified until something runs it — a plan with 28 tests and a golden render was wrong four ways |
| 2.44 | An install that reports success is not one that worked — assert on `login:`; and `geom disk list` cannot see `md(4)` |
| 2.45 | A package manager's closure is not your program's closure — `ldd`, not `pkg`; and announce a graceful fallback or no test can see it |
| 2.46 | A GUI cannot be trusted to be right about itself — click it live, and let it publish its own geometry; `print` is buffered and invisible |
| 2.47 | `getty` calls `revoke(2)` on the console — every other process's descriptor to it dies, silently |
| 2.48 | A nested compositor's schedule is not its own — C1 there is measured against the host's clock; and the display's size beats your flags |
| 2.49 | "The option was accepted" is not "the value was accepted" — `makefs` takes `media_descriptor` in decimal only, and a fix verified by hand never ran in the builder |
| 2.50 | A check that dies inside `$( )` under `set -e` fails **silently** — and `dd bs=1` on a raw device is `Invalid argument` |
| 2.51 | Every safety predicate you have describes the **running** system — and on a live medium the running system is the USB stick |
| 2.52 | `ldd` is not your closure either, when something in it `dlopen`s — Mesa's driver is a plugin, and headless never asks for it |
| 2.53 | Take **every** fact from the display, not just the ones that broke first — we fixed size in P4.1 and reported a 60 Hz panel as 240 Hz for a phase |
| 2.54 | A plugin chain fails at whichever link you did not carry, and names none of them — `test -s` proves presence, only the loader proves resolution |
| 2.55 | A drag that ends where it started is one process asking itself |
| 2.56 | A surface the pointer cannot reach is not a drop target |
| 2.57 | `wl_proxy_destroy` tells the compositor nothing |
| 2.58 | A global with nothing behind it is the same defect twice |
| 2.59 | Routing a key is not telling a window it has focus |
| 2.60 | A `weak` focus goes nil without telling anyone — closing the focused window left the desktop deaf, the close-side twin of P9.4's minimize fix |
| 2.61 | A wait the past can satisfy is not a wait — polling for a log line proves nothing if the line was there before you started |
| 2.62 | undertow never drew, hit-tested or paced an `xdg_popup` — every menu mapped and was invisible; and an injected fault withdrew the first explanation |
| 2.63 | A compositor that ignores `keyboard_interactivity` sends the menu bar's arrow keys to the window behind the menu |
| 2.64 | Snapshot a set where you poll it, not after dispatching — a handler that registers from inside a Wayland event made them disagree |
| 2.65 | A privileged process hands its privilege to every child by default — the bar's first launched app inherited its privileged `WAYLAND_DISPLAY` |
| 2.66 | SwiftPM does not recompile across an `@_exported` re-export — a type's layout changed and three targets ran the old one (a crash at exit, a crashed test bundle, a failed link) |
| 2.67 | `cairo_fill_preserve` keeps the path, and the next shape is *added* to it — four Aqua controls glossed their whole body, the menu bar, toasts and prefs toolbar were outlined by accident, the toast's border was never drawn, and an icon's leftover path got outlined by the next stroke |
| 2.68 | wlroots' protocol tables are hidden — a protocol of ours that names `xdg_toplevel` could not link in undertow until xdg-shell's tables lived once, in `CAbyssProtocols` |
| 2.69 | A pipe's status is its last command's — `swift build | filter` printed "done" over a failed guest build, and the guest's tests ran the last good binaries |

### 2.1 The static-inline trap (the big one)

> **Correction, 2026-09-28: this is not true of the compilers we use.** Swift
> 6.3.1 (Linux) and 6.3.2 (FreeBSD) both call libwayland's `static inline`
> requests and `*_add_listener` directly — a probe compiled, linked and (on
> Linux) ran against a live compositor with no shim. The rule was inherited and
> never re-tested. The wrappers still work; retiring them is
> [SWIFT-6.4.md](SWIFT-6.4.md) S.1. What follows is kept as the record of why
> they exist.

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

### 2.79 A capture that renders the last frame's latch renders freed textures
(P14.7a. Found only with a second output, and only in the guest, 2 runs in 6.)

`capturePPM` drew the scene's *last latch*: the texture pointers gathered at
that output's last frame. With one output nothing ran between that latch and
the capture. With several, other outputs' waits dispatch the event loop in
between; a client commits a new buffer, wlroots frees the old texture, and the
capture hands pixman a dangling pointer: `Assertion failed:
(wlr_texture_is_pixman(wlr_texture))`, exit 134, on the *second* output's
capture. A capture now latches afresh first.

The rule: **a latch is valid until the event loop next runs**, not until the
next frame. Anything that renders a latch later — a capture, a screenshot, a
thumbnail — latches again. The first guest failure read as a flaky test ("the
cursor ended in a gap: " with nothing after the colon) because the test did not
say that undertow had died; it does now (exit status and stderr), and that is
what turned a flake into an assertion message.

### 2.78 libmixer sets the *selected* control, and looking one up does not select it
(P14.6a. Found by comparing with mixer(8), not with our own reader.)

`av_mixer_set(unit, "pcm", 40, 40)` found `pcm` with `mixer_get_dev_byname`,
called `mixer_set_vol`, and changed **`vol`**. libmixer's setters act on
`m->dev`, the *selected* control, which `mixer_open` points at the first one;
`mixer_get_dev_byname` returns a control and leaves the selection alone.
`mixer(8)` itself selects it (`m->dev = dp`) before it sets anything. Ours does
too now, for both level and mute.

Our own `ventsctl sound` read back 40 for… `vol`, and would have agreed with
itself whatever it set. Reading the result back through **mixer(8)** is what
showed which control had moved. live-vents.sh now asserts that setting `pcm`
leaves `vol` alone, and that assertion fails when the selection is removed.
The rule is §2.44's, "assert on the thing": check a write with the system's
own tool, not with the reader written beside the writer.

### 2.77 A test helper that skips what it cannot do, in silence
(P14.4c. Found because the pane logged what it sent.)

`vkeyboard` maps characters to evdev keycodes, and its table had letters,
digits and space. For anything else it did `continue`. Every test before
P14.4c typed a user name or a password, so nothing noticed. The Network pane's
test typed `10.0.2.300` and the pane sent `1002300`. The pane was right about
what it received: the dots were never pressed.

It types `. , - / : _` now, and **an unknown character goes to stderr**:
`vkeyboard: cannot type 'x'`. The general rule is the §2.75 one, applied to
the tools: **a harness tool that cannot do what it was asked must say so**,
because the test reading its result cannot tell "not done" from "done, and the
product ignored it". It helped that the pane logs what it will send, not only
the outcome. A test that had checked only the helper's refusal would have
reported a helper bug.

### 2.76 rc.subr owns `${name}_user`
(P14.3b. Found by running the `rc.d` script under the real rc.subr.)

`abyss_settings` was configured with `abyss_settings_user`, by analogy with
`abyss_desktop_user`. Under rc.subr that name is not ours: with `command=` set,
**rc.subr runs the command as `${name}_user`** — so the root helper was started
as the administrator, and `daemon(8)` failed with `daemon: open: Permission
denied` writing its pid file. `abyss_desktop_user` has never hit this only
because that script supplies its own `start_cmd`, which rc.subr does not wrap.
It is `abyss_settings_admin` now.

rc.subr reserves more suffixes than it looks like it does — `_user`, `_group`,
`_flags`, `_env`, `_chroot`, `_nice`, `_fib`, `_limits`, `_login_class`,
`_umask`, `_program`, `_pidfile`, `_oomprotect` among them. **Name a
variable of our own something rc.subr has no reason to know.** And the general
form, again: a script written to run under a framework is not verified until
it has run under that framework; `sh -n` said it was fine.

### 2.75 A test's own arithmetic fails quietly, and reads like the product's
(P14.2. Three in one pass, each first reported as a product failure.)

`live-appearance.sh` failed three times with the code working:

- **`grep -c … || echo 0` prints `0` twice** when nothing matches — `grep -c`
  prints the count *and* exits 1 — so a baseline of "0\n0" made every later
  numeric comparison false, and a wait timed out claiming the portal had sent
  nothing. It had sent 46 signals. Use `|| true`.
- **A baseline counted on one pattern, waited on with another.** The pane's
  helper counted *all* earlier writes, then waited for more than that many
  lines matching *this* write — which can only ever be one. The pane had
  written; the test could not see it. Count what you wait for.
- **An empty match fed to shell arithmetic is a number.** The slider's track
  was grepped from "the last line starting `appearance `" — which by then was
  the pane's own write log, not its layout — so `x0` was empty and
  `$((68 + x0 + 5))` quietly became 73: a press on the title bar, which began a
  window move. Guard every parsed coordinate with `[ -n … ] || fail`.

**The rule:** a helper that turns log lines into numbers is code, and gets the
same suspicion — the tell in all three was a failure message that named the
product for something the product had demonstrably done (the log said so).
Read the log before believing the verdict.

### 2.74 Only the compositor knows when a frame was shown — so say so
(U.4, 2026-09-28. F-101; API-STUDY §2.)

`undertow` measures every present for its own frame contract and told no
client any of it, so every toolkit estimated. `wp_presentation` is now offered
(`wlr_presentation_create`), and wlroots answers each surface's feedback from
the output's own present event — **but only for surfaces it is told were in
the frame.** `wlr_scene` does that telling; ours now does it too
(`SurfaceScene.markPresented`, before the output commit, from the same latched
entries the frame was drawn from). Remove that one call and every feedback is
*discarded*: 0 presented of 361 in the test. The global alone would have been
§2.58 again.

What headless reports is honest and thin: the time is the commit's, `refresh`
is 0 and no flags are set — "unknown", in the protocol's words, because there is
no hardware clock. On DRM wlroots fills the refresh from the mode and sets
`HW_CLOCK`/`VSYNC`; that is a metal check (BACKLOG §3).

**Scope, corrected:** the backlog also promised frame-done callbacks stamped
with the time the frame was shown. The core protocol says a frame callback
carries the *current* time, and the time of presentation is precisely what
`wp_presentation` is for — so frame-done stays as it is.

**A portability trap in the test, not the code:** clock ids are per platform —
`CLOCK_MONOTONIC` is 1 on Linux and 4 on FreeBSD — so the client reports
whether the clock named *is* `CLOCK_MONOTONIC` rather than printing a number
for the script to compare. Both platforms green.

### 2.73 The harness renders in software, and so it never met a GPU client
(U.3, 2026-09-28. API-STUDY §1.2.)

Every run in this project renders with pixman — headless pins it, and the build
VM has no GPU — and pixman imports no dma-bufs. So `undertow` offered only
`wl_shm`, nothing ever complained, and the first GPU client would have met it on
the RX 6750 XT. Measured on the dev box's AMD iGPU (RADV/radeonsi, the same
driver family): **a Vulkan client segfaulted, and a GL client silently fell back
to drawing in software.** `linux-dmabuf` is now created from the renderer, and
where the renderer imports none, `undertow` says so in words.

**Headless `undertow` can run on a GPU**: `WLR_RENDERER=gles2` overrides the
pixman pin, and `WLR_RENDER_DRM_DEVICE` chooses the node — which matters,
because wlroots' default on this box was the NVIDIA card, not the AMD iGPU.
That is what made this testable here rather than on metal. Four things that
cost time:

- **Check the device, not the claim.** Mesa follows the dma-buf feedback's main
  device, so a GL client lands on whatever node the renderer is on; `vkcube`
  picks a discrete GPU by type, and Vulkan's device *numbering* is reordered by
  Mesa's device-select layer according to the compositor it is talking to —
  index 1 was AMD under `vulkaninfo` and NVIDIA under `undertow`. The test names
  the device (`MESA_VK_DEVICE_SELECT=vendor:device`) and asks the kernel which
  node each client holds (`/proc/<pid>/fd`).
- **`es2gears` crashes on a seat with no devices** — it destroys a pointer and a
  keyboard it never created. Its bug; the test gives the seat both first, as
  every real desktop's has. A crash that looks like the compositor's is worth a
  backtrace before a fix.
- **Screencopy's format is the renderer's.** pixman offers XRGB8888; AMD's GLES2
  offers `XB24`; NVIDIA's offers 24-bit `BG24`, which `abyssgrab` could not read
  (format table) and then could not allocate (`ShmBuffer` held every stride to
  four bytes a pixel). Both fixed; the RX 6750 XT was never affected — the
  first reading of the failure said it was, before the formats were asked for.
- **`--capture` does not work on a GPU renderer** — it reads the swapchain
  buffer from the CPU. Screencopy does, so a GPU test grabs with `abyssgrab`.

**Not done: explicit sync** (`linux-drm-syncobj`). Our scene would have to wait
on each buffer's acquire point and signal its release, which `wlr_scene` does
and ours does not; advertising it without that would be §2.58 again. Implicit
sync is enough for radeonsi and radv. BACKLOG U.3b.

`live-gpu.sh`: each fix was removed in turn and the test failed where it should
— no global (with the log still claiming one): `es2gears` on the wrong node; no
`BG24`: the NVIDIA screenshot's format; the old stride guard: its allocation.

### 2.72 A window nobody can see still needs a clock
(U.2, 2026-09-28. API-STUDY §1.4.)

`sendFrameDone` walked `mappedToplevels`, which leaves minimized windows out —
correctly for the scene and the hit-test, and wrongly here. A client presenting
in FIFO mode, which is Mesa's default, blocks inside its swap until a frame
callback arrives; minimize it under `undertow` and it never came. The study
found SDL, Blender and zed each hitting this on some compositor. Nothing in our
tree waits that way, so nothing here noticed.

A minimized window now gets one callback a second, and xdg-shell is created at
**v6** so the window is also told it is `suspended` — the polite half, for a
client that listens; the clock is for one that does not. Two traps in doing it:

- **wlroots' default `wm_capabilities` claims all four**, including a window
  menu `undertow` does not draw, so a v5 client would ask for one on a
  right-click and get nothing. They are now set per window to what we serve
  (maximize, fullscreen, minimize) — from the first-commit handler, since
  scheduling a configure earlier is P9.6's assertion. Found by removing the
  call and watching the test fail on `window_menu`; the comment first written
  here had guessed the default was *empty*.
- **Our own toolkit binds xdg-shell v2**, so the version bump changes nothing
  for Aqua applications — and they do not hear `suspended` either. That is the
  client half, BACKLOG T.3.

`live-hidden.sh` asserts the four claims separately (capabilities, suspended
both ways, the slow clock, the clock's return) and each was shown to fail
alone: no hidden clock → the clock stops; no throttle → 210 callbacks in 3.5 s;
no `set_suspended` → never told; default capabilities → `window_menu`. GTK and
Qt, which do bind v6, pass their live tests unchanged on both platforms.

### 2.71 A window is a tree, not a rectangle
(U.1, 2026-09-28. The third global with nothing behind it — §2.58, §2.62.)

`undertow` created `wl_subcompositor` in Phase 6 and never drew a subsurface,
never sent one a frame callback, and hit-tested each window as its root's
rectangle. A client could build a subsurface tree without an error; nothing in
it past the root was ever seen, clicked or clocked. Our toolkit never makes a
subsurface, so no test could notice; Firefox puts its page in one.

The fix is wlroots' own tree, not a second one of ours: the scene, frame-done
and the hit-test each walk `wlr_surface_for_each_surface` /
`wlr_surface_surface_at` from every root — window, layer surface, popup. Three
things worth knowing:

- **Paint order is the tree's, not "parent then children".** A subsurface
  placed *below* its parent is painted first; the walk gives that order, and
  `live-subsurface.sh` has a child placed below to prove it.
- **A pointer event belongs to the leaf, in the leaf's coordinates.** The
  window still takes focus on a click; the *events* go to whichever surface of
  it is under the pointer, which also means input regions are honoured now,
  where a rectangle never did.
- **No allocation in the present path.** The C iterators carry their context in
  the data pointer (the scene itself; the frame time), so walking a tree costs
  the latch nothing it did not cost before. C2 is unchanged on both platforms.

**Each of the test's three claims was shown to fail alone**: with the old scene
only the pixels fail, with the old hit-test only the routing, and with all of
it the frame clock fails first. The general rule is §2.58's, one level down:
for each global, name the object a client receives — and for each object, the
*children* a client can hang off it.

**Found while doing it, not fixed:** `undertow` never sends `wl_surface.enter`
for an output, to any surface. A client never learns which output it is on,
which is how GTK and others pick their scale. BACKLOG U.10.

### 2.70 A virtual keyboard is not a keyboard
(2026-09-28. Found by reading, not running — the NeoDarwin API study review,
[API-STUDY.md](API-STUDY.md) §1.1.)

A client that creates a virtual keyboard must hand the compositor a keymap
before it may send a key, so every keyboard the harness has ever typed through
arrived with one. **A libinput keyboard arrives with none**, and wlroots does not
make one up: tinywl compiles a keymap for every new keyboard for exactly this
reason, and `undertow` did not. The seat would have told clients nothing, keys
would have arrived as codes no client could read, and `intercept` would have
found no keysyms, so no keybind would have fired either. The first keyboard
this would have met is the 12700KF's; the install being deferred is the only
reason nobody typed on it.

`Seat.giveKeymap` now compiles xkbcommon's default (which reads
`XKB_DEFAULT_LAYOUT` and friends) for a keyboard that has none, and sets a
repeat rate; one that brought a keymap keeps it. The tests build a bare
`wlr_keyboard` with `wlr_keyboard_init`, which is how a backend makes one, rather
than a virtual keyboard, which is the thing that hid it.

**The rule is §2.58's, turned from globals to devices:** when the harness drives
something through a stand-in, ask what the real one does *not* bring that the
stand-in does. A virtual keyboard brings a keymap; a nested output brings
somebody else's vblank (§2.48); shm buffers bring no GPU. Each hides a defect
that only metal can show.

**The layout (same day).** The installer writes rc.conf's `keymap=`, a
`kbdmap` name (`uk.kbd`), and the seat needs an XKB layout (`gb`). rc.conf stays
the one place the choice lives: `Install.Keymaps` translates the installer's
eight exactly, guesses any other from its prefix (`de.acc.kbd` → `de`), and
`giveKeymap` reads it — after `XKB_DEFAULT_LAYOUT`, which still wins, and before
xkbcommon's US default, which is what a guess XKB refuses gets. Writing it
turned up two more:

- **Two of the eight names did not exist.** The installer offered `dvorak.kbd`
  and `colemak.kbd`; FreeBSD ships `us.dvorak.kbd` and `colemak.acc.kbd`
  (confirmed on 15.0-RELEASE-p11), so choosing either wrote a console keymap
  that could not load. A test in the guest now stats every offered name in
  `/usr/share/vt/keymaps`.
- **The dev box exports `XKB_DEFAULT_LAYOUT=us`**, from its own desktop session,
  and that outranks rc.conf on purpose. A test that set the variable and then
  *unset* it cleared the box's value for every test after it, so whether the
  rc.conf tests passed depended on which ran first. Tests now save and restore
  it, and clear it where they mean rc.conf to decide. A test that touches the
  environment borrows it; it does not get to keep it.

### 2.69 A pipe's status is its last command's
(P11.10. One scene moved on Linux and not on FreeBSD, and that was the clue.)

`abyss/vm/build.sh` ran the guest build as `swift build 2>&1 | grep -v …`, to
drop FreeBSD's harmless "prohibited flag" warning. The pipeline's status is the
`grep`'s, so **a failed build printed "[build] done"**. Everything run in the
guest after it (the golden gate, `swift test`, live scripts) ran against
whatever binaries the last successful build left behind. It surfaced because
a golden that depended on a changed compiled default moved on Linux and not in
the guest, whose `AquaDemo` was older than its source. The build had failed on
a FreeBSD-only type (`posix_spawn_file_actions_t` is a struct on Linux and a
pointer on FreeBSD).

**The rule: never pipe a command whose status you need.** Send it to a file,
filter the file, return the command's status. `build.sh` does that now, and
exits 1 with the compiler's error, seen on a deliberate one. When a check is
green on one platform and "unchanged" on the other, compare the binary's
timestamp with its source's before trusting either.

### 2.68 wlroots' protocol tables are hidden
(P11.6. `abyss-window-v1` names an `xdg_toplevel`, and undertow stopped linking.)

A wayland-scanner `private-code` file for a protocol that names another
protocol's interface refers to that interface's table by symbol:
`extern const struct wl_interface xdg_toplevel_interface;`. Clients had one,
from CWayland's `xdg-shell-protocol.c`. undertow did not: wlroots generates
and links its own xdg-shell tables, **with hidden visibility**. So they are in
the binary and cannot be named, and the link fails with
`undefined reference to 'xdg_toplevel_interface'`. The Phase 6 comment
"wlroots links the protocol implementations itself" was right, and not the
whole story: it links them *for itself*.

Adding the table to undertow's own C target would put it in every binary twice
that links both halves (every `swift test` build), which is exactly why
`CAbyssProtocols` exists. **So xdg-shell's tables moved there**, the one copy
for client and compositor alike, and `generate-protocols.sh` writes them there.
The interface is matched by name at runtime, so undertow's copy and wlroots'
hidden one agree.

### 2.67 `cairo_fill_preserve` keeps the path, and the next shape is added to it
(P11.4. Found by making the draw lists byte-identical to the Swift.)

`Draw.fillVerticalGradient` fills with `cairo_fill_preserve`, so the path it
filled is still there afterwards. A recipe that then built its gloss capsule
with `roundedRect` and filled it *added* the capsule to the kept body: the fill
covered body and capsule, so **the gloss gradient washed the whole control**,
not the top 42% it was drawn for. Four controls did it: the checked checkbox,
the pop-up button's cap, the scrollbar thumb, and the scroll track, whose
"inset shadow" on one edge is in fact a 10% darkening of the whole channel.
It has looked like that since the recipes were written, and every golden
pictures it.

It could not be seen by reading the code, which reads as if the capsule is
filled alone. It was found because P11.4 had to be pixel-identical: drawing
the body alone with the gloss's gradient matched in every case but one, and
there **one byte** of antialiasing differed between "body" and "body plus a
capsule inside it". The draw-list format gained `and SHAPE`, a second subpath
in one fill, to say what the Swift really did. **The rule: after a
`_preserve`, start the next shape with `cairo_new_path` unless adding to the
path is the point**, and say so where it is. The lists keep the look on
purpose (the gate for P11.4 is that nothing moves); making each gloss the
capsule it was meant to be is a look change for later, with the goldens
updated.

**P11.5 found it everywhere the pattern was used.** The menu bar, the toast and
System Preferences' toolbar are each outlined in the colour of whatever
stroked next (a pinstripe's first hairline, a separator), because their
gradient's rectangle was still the path. The toast's `toastBorder` stroke
drew **nothing**, because that pinstripe stroke had consumed the path;
deleting the stroke moved no pixel. And a leak crosses functions: Sharing's
folder icon ends in `fill_preserve`, and the section rule drawn after it
outlined the folder in the separator colour. **A leaked path belongs to the
next stroke, whoever's it is.** The draw lists cannot leak (every shape starts
a new path), which is why converting the rule moved the folder, and why that
rule waits for the icon to be fixed (P11.8).

**P11.8 closed it.** The icons are draw lists, which leak nothing. The held
rule moved, and `sysprefs` moved by exactly the 209 pixels predicted, at the
same place: the folder's accidental outline, gone on purpose. The icon set
also keeps three more cases faithfully: every glossy tile glossed whole, the
Desktop icon's screen filled entirely yellow by its "sun", and the
microphone's capsule outlined by its stem.

### 2.66 SwiftPM does not recompile across an `@_exported` re-export
(P11.2. `ThemeTokens` grew by 41 fields, and three targets kept the old size.)

`Aqua` re-exports `AquaDraw` (`@_exported import`, since P9.6), so a target that
depends on `Aqua` can use `Theme` without naming `AquaDraw` at all. It compiles.
And when `AquaDraw` changes a type's **layout**, SwiftPM's incremental build
does not always recompile it. Three failures in one pass, each looking unlike
the others:
- a **link error** on a symbol that had changed from a stored `static let` to
  a computed property;
- **`AquaDemo` crashing on exit**, destroying a `ThemeLoader.Outcome` with the
  old struct size (signal 11, `swift_release` of garbage);
- **the whole test bundle** dying with signal 11.

A forced rebuild fixed each, which is exactly what makes it dangerous: it looks
like flakiness. **The rule: a target that uses a module's types depends on that
module and imports it directly**, rather than reaching it through a re-export.
`AquaDemo`, `AquaTests` and `DBusPortalTests` now do. It was proved by growing
the struct by two fields and back with no forced rebuild, and it ran both
times. When a crash appears right after a struct change, suspect the build
before the code.

### 2.65 A privileged process hands its privilege to every child by default
(P10.8. Found by the test that launched System Preferences from the bar.)

The menu bar connects to undertow's privileged socket (§6.1 of PHASE10), and
that is what lets it watch focus and force-quit applications. The first thing
it launched — System Preferences — inherited `WAYLAND_DISPLAY` like any child,
and so connected to the *privileged* socket too: an ordinary application with
the bar's powers, by accident, with nothing on screen to say so.

Nothing about the launch was wrong in isolation. `launchDetached` passes the
environment through because that is what a launcher is for. The mistake is the
default: **a privileged process's environment is part of its privilege**, and a
child that inherits it inherits the privilege. The bar now launches on the
ordinary display, which `anchor` hands it as `ABYSS_APP_WAYLAND_DISPLAY`; not
knowing it is a refusal, never a fallback to its own. `live-context.sh` reads
the display the child actually received, and failed with the fix removed. The
same question belongs to every privileged component that can start one:
`abyss-install` (root), the portal, and whatever Phase 17 confines.

### 2.64 Snapshot a set where you poll it, not after dispatching
(P10.4. The first handler in the project's history to register a descriptor
from inside a Wayland event.)

`Display.run` built its `pollfd` array from `extraFds`, polled, dispatched the
Wayland events, and *then* took a snapshot of `extraFds` to walk alongside the
poll results. If anything in that dispatch registered a descriptor, the snapshot
was one longer than the array: `pfds[i + 1]` out of range, and the process gone.
The menu bar subscribing to an application when a focus event arrives was the
first code to do that; everything before registered from descriptor handlers,
after the walk. **Take the snapshot at the moment the set is polled** — the list
that produced the results is the only one that can be indexed by them.

### 2.63 A compositor that ignores `keyboard_interactivity` sends the bar's keys elsewhere
(P10.4. Every keyboard test of the menu bar ran on sway.)

The bar is a layer surface with `keyboard_interactivity: on_demand`, so that a
click on a title gives it the keyboard and the arrow keys walk the menus
(§2.27). undertow gave the keyboard to windows and nothing else, so under our
compositor Down and Return in an open menu went to the Finder window behind it.
Now a click on such a layer hands it the keyboard **without** changing who is
frontmost — the bar is not an application — and the keyboard returns to the
active window when the last menu closes.

The return has a race worth knowing: walking the bar with ← → closes one popup
and opens the next, and the client may flush between the two, so "no popups" is
briefly true. Restoring at once, or on the next idle, takes the keyboard from
the bar mid-walk (the idle version was tried and failed the test). A 100 ms
timer lets the next menu arrive. The test that caught it walks → and then
presses Escape, which only the bar would answer.

### 2.62 undertow never drew, hit-tested or paced an `xdg_popup`
(P10.4. Found when the bar became real and "New Folder" was clicked.)

wlroots implements xdg-shell's popups at the protocol level — including their
initial configure and the grab that dismisses them — so a client's menu *mapped*
under undertow. And then nothing: undertow had no `new_popup` listener, so no
popup was in the paint order, the hit-test or the frame callbacks. The menu
bar's dropdowns, the Dock's Trash menu and every pop-up button were mapped,
invisible and unclickable on our own compositor; every test that opened one ran
on sway, and the client's log line — "opened File" — was true of the client.
§2.56 (layer surfaces not hit-tested) and §2.58 (a global with no objects) are
the same shape; this is the third time, and the lesson is the same: **list the
surface roles a client can create and check each is in the scene, the hit-test
and the frame callbacks.** Subsurfaces have not been checked yet.

**And the first explanation was wrong.** The first draft of `Popups.swift` said
the missing piece was the initial configure, and scheduled one. Removing that
call left the test green: wlroots sends it. The injected faults that do break
menus are removing the popup hit-test (a click lands on nothing) and removing
popups from the scene (a pixel in the open menu is the desktop's blue). A cause
stated before it has been falsified is a guess wearing a comment.

### 2.61 A wait the past can satisfy is not a wait
(P10.3. The compositor was right; the test said it was wrong.)

`live-menu-focus.sh` closes the last window and waits for the bar to log
`frontmost: nothing`. The bar had already logged exactly that line once — when it
bound, before any window existed — so the wait returned at once, the count was
checked before the new event had arrived, and the test failed a compositor that
had done its job. It now waits for a **second** occurrence.

The failure mode is general and it is quiet in the other direction too: had the
assertion been "the line is present" rather than "the count went up", the test
would have *passed* with the compositor sending nothing at all. **When a harness
polls for evidence, check the evidence could not have been there before the
thing under test ran** — count it before and after, or clear the log, or wait
for something only the new event can produce. §2.37's positive control, applied
to the harness's own clock.

### 2.60 A `weak` focus goes nil without telling anyone
(P10.3. The menu bar is the first thing that has to be told who is frontmost
after a close.)

`Seat.focused` is `weak`, which is right — a seat must not keep a dead window
alive — and it means closing the focused window made the reference go quietly
nil. No other window was activated, no keyboard focus moved, and the desktop was
deaf until somebody clicked. P9.4 had fixed precisely this for **minimize**
(`focusTopmost` when the focused window is put away); the close path is the same
hole through a different door, and nothing looked at it because nothing
downstream of focus cared about the *next* window until the bar did.

`Compositor.forget` now focuses the topmost window when the one going was
focused, and tells the bar. `live-menu-focus.sh` fails with that line removed.
The rule: **wherever a weak reference can become nil, find the code that should
have been told** — a weak reference makes the lifetime correct and the
notification disappear, and the second is the one that shows up as a bug.

### 2.59 Routing a key is not telling a window it has focus
(P9.5. Six phases of windows drawing themselves active whether they were or not.)

`Seat.focus` called `wlr_seat_keyboard_notify_enter` and stopped. That routes the
*keys*; it says nothing about the **activated** state, which is the half a client
draws with — the live title bar, the caret that blinks, the selection that is not
grey. undertow set it on nobody, so every Aqua window since Phase 6 has rendered
as the focused one, including the ones behind it.

Nothing could catch it. The screenshots are of single-window scenes, where
"always active" and "correctly active" are the same picture; the client had no
way to ask; and the compositor was not lying, it was silent. It surfaced only
when a test needed focus as an *observable* — Cmd-Tab's entire visible effect is
which window says it now has focus — which is the same shape as §2.56 and §2.58
from a third direction:

> **A thing nothing ever asked for is a thing nobody notices is missing.** The
> gap is never in the code that runs; it is in the state nobody reads until a
> feature finally needs it.

The client half was already there — P9.4 taught `Surface.Window` to decode the
configure states and it has reported `activated` faithfully ever since. It was
reporting a state the compositor never set.

### 2.58 A global with nothing behind it is the same defect twice
(P9.4, one pass after §2.56, in the same file and for the same reason.)

undertow called `wlr_foreign_toplevel_manager_v1_create` at start-up and never
created a **handle** for any window. The global was advertised, the Dock bound
it, and it was told about nothing: no running applications, no dots on the tiles,
and a click on a tile with nothing to raise. Found because minimize needs
somewhere to go — a window that cannot be un-minimized is worse than one that
cannot be minimized — and the somewhere is a tile that has to exist.

This is §2.56's shape (the Dock could not be clicked under our own compositor)
and §2.54's (a dispatch with no vendor), which makes three in two passes:

> **Creating the manager is not implementing the protocol.** The half that
> carries the data is the half nobody writes, and every test that would have
> noticed was pointed at sway, which implements both halves.

The general form, worth applying to the next protocol before it bites: for each
global we advertise, name the object a client actually *receives* through it. If
nothing in the tree constructs one, the global is furniture.

### 2.57 `wl_proxy_destroy` tells the compositor nothing
(P9.3. A drop that vanished, traced back to every window this project has closed.)

A file dragged onto the Dock arrived. The next one, dragged after a window had
been closed, did not — and neither did a click. The Dock was alive, it held its
layer surface, and the pointer was over a tile. undertow's hit-test said why:

```
HIT 540,550 -> toplevel Documents @164,300 520x400 (tops=2 layers=1)
```

The Finder had closed that window. `Surface.Window.close()` destroyed the local
proxies with `aw_proxy_destroy` — and **`wl_proxy_destroy` sends no request**.
The destructor request lives in the generated per-interface function
(`xdg_toplevel_destroy`, `wl_surface_destroy`), so freeing the proxy frees *our*
handle and leaves the compositor's object mapped, buffered and hit-testable for
the rest of the connection. Every window, popup and layer surface this project
has ever closed has leaked one, and each left a rectangle of dead screen that
swallowed clicks into a window nobody could see.

Nothing could observe it from either side. The client is right that the window
is gone; the compositor is right that nothing asked it to let go. And every
close test ever written asked the *client* whether it had closed the window —
`Finder: closed … (1 open)`, a tree count taken before the close — so all of
them passed.

The fix is three one-line wrappers (`aw_surface_destroy`,
`aw_xdg_surface_destroy`, `aw_xdg_toplevel_destroy`; popups and layer surfaces
already had theirs and used them for the role object only). The rule is the
general one: **`wl_proxy_destroy` is for objects with no destructor request.
Everything else has one, and not sending it is a leak on the other side of the
socket.** The regression test is `live-dnd.sh` dropping on a Dock tile that sits
exactly where a closed window used to be.

### 2.56 A surface the pointer cannot reach is not a drop target
(P9.3, found while the file kept falling through the Trash.)

undertow's pointer routing searched `mappedToplevels` and stopped. Layer
surfaces — the Dock, the menu bar, the desktop, everything the *shell itself*
draws — were never in the hit-test, so under our own compositor none of them
could be clicked, hovered or dropped on. Nothing had noticed because every test
that clicks the Dock runs on **sway** (`live-sway.sh` and all 35 modes of
`run-live.sh`), which routes them correctly. The compositor under test was the
one component the Dock tests never exercised: §2.37's shape again, a probe that
only ever ran against the positive control.

Routing is the protocol's own order — overlay and top above the windows, bottom
and background below them — and a click on a layer surface must **not** take
keyboard focus, which is what `keyboard_interactivity: none` asks for.

### 2.55 A drag that ends where it started is one process asking itself
(P9.3. §2.45's deadlock, reached by the other door.)

`ownsSelection` exists because a client that reads a selection it owns blocks
the event loop that would have delivered its own `send`. Drag and drop has the
identical hazard and a much more ordinary trigger: **drag a file from one window
to another window of the same application.** The drop handler pipes, calls
`receive`, and reads to EOF — from itself. The Finder hung with `dragging …` as
its last line.

Same fix, same reason: if the drag source is ours, the bytes are already in
hand — hand them to the drop callback and finish the offer without the pipe. The
lesson is worth stating once for the whole protocol family: **any Wayland
transfer where this process is both ends must short-circuit, because the
"transfer" is a request for an event only our own blocked loop could deliver.**

### 2.54 Present is not resolved — carry the whole plugin chain, then prove it
(Third metal boot, `--verbose`. The one that finally named the link.)

§2.52 added Mesa's DRI driver to the medium because `ldd` cannot see a `dlopen`.
The next boot failed the same way, and wlroots' own log said why:

```
[render/egl.c:208] EGL_EXT_platform_base not supported
[render/egl.c:563] Failed to create EGL context
[render/wlr_renderer.c:199] Failed to create a GLES2 renderer. Skipping!
[render/vulkan/vulkan.c:182] Could not create instance: ERROR_INCOMPATIBLE_DRIVER
```

DRM was fine throughout — 1 GPU, atomic interface, 6 CRTCs, 14 planes. **The
chain is three deep and we had carried the ends:**

| Link | What it is | On the stick? |
|---|---|---|
| `libEGL.so.1` | libglvnd's vendor-neutral **dispatch** | yes — our binaries link it |
| `egl_vendor.d/50_mesa.json` | says which vendor to load, **read by path** | **no** |
| `libEGL_mesa.so.0` | Mesa's actual EGL, `dlopen`ed by the dispatch | **no** |
| `dri/*_dri.so` → `libgallium` | the driver proper | yes, since §2.52 |

`EGL_EXT_platform_base` is a **client** extension — queried on `EGL_NO_DISPLAY`,
before any device exists — so its absence means the dispatch found no vendor at
all. The message says nothing about a missing JSON, and the Vulkan line beneath
it is a second instance of the same thing (`libvulkan.so.1` linked by wlroots,
no ICD carried) producing a scary error that is a **false lead**.

Two rules, and the second is the one worth keeping:

1. **Carry the whole chain, or do not carry the loader.** A dispatch with no
   vendor and a loader with no driver are the same artifact: present, resolving
   every symbol, answering every call, and doing nothing. We could not decline to
   ship `libvulkan.so.1` — wlroots links it — so it got completed instead.
2. **`test -s` proves presence; only the loader proves resolution.** Three
   consecutive boots died on a file that was there being unable to reach a file
   that was not, and every filename assertion we had passed each time.

So the check is now the mechanism rather than the manifest: `abyss/tests/eglprobe.c`
asks libEGL for its client extensions with `__EGL_VENDOR_LIBRARY_DIRS` and
`LD_LIBRARY_PATH` pointed at the *medium's* tree. Because client extensions need
no device, **the build VM — which has no `/dev/dri` at all — can run it**, and it
reproduces the metal failure exactly when the vendor directory is pointed
elsewhere. A three-times-repeated runtime surprise became a check that runs on
every build.

### 2.53 Half a lesson is a lesson you get to learn twice
(Second metal boot. The compositor drove a real display and mislabelled it.)

§2.48 said: **on a real backend the display's size is the truth, not your flags.**
P4.1 applied it — `width` and `height` now come from `wlr_output` — and stopped
there. `--hz` kept its default of 240, so the first run on a 60 Hz panel printed:

```
undertow: DP-1 2560x1440 @ 240Hz
```

Two thirds measured, one third invented, in one line, with nothing to mark which
was which. The metronome was fine — it seeds from `output.periodHintNs`, which
reads the output's real millihertz — so this was never a *behaviour* bug. It was
a **reporting** bug, and it is the worse kind here: every other number in that
report is a duration, and a duration is meaningless without the period it is
measured against. A frame budget quoted at 240 Hz when the panel runs at 60 is
off by a factor of four in the reader's head, and the reader was me.

The generalisation, and the reason this gets a number of its own: **when a class
of fact turns out to come from the machine rather than from you, take the whole
class.** Size and refresh arrived from the same struct, in the same commit's
reach, for the same reason. Fixing the field that broke first and leaving its
siblings is how one lesson becomes two bugs a phase apart.

Worth pairing with §2.45 → §2.52, which is the same shape: a rule about closures
learned from packages, then re-learned from `dlopen` within the hour.

### 2.52 `ldd` is not your closure either — Mesa loads its driver by name
(The first boot of our own medium on a real GPU. It got further than anything
before it and stopped one step short of a picture.)

`live-image.sh` computes what the medium carries by running `ldd` over the twelve
binaries we ship — 67 shared objects, 22 MB — rather than asking `pkg`, which
P5.3 measured at 5.66 GB for the same job (§2.45). That is the right method and
it was carried one step too far.

On the RX 6750 XT the medium booted, reached multi-user, bound `amdgpu`, and put
`/dev/dri/card0` **and** `renderD128` on the console. Then:

```
abyss-session: auto backend (card0 render128)
undertow: could not create a wlroots renderer
anchor: failed to start the session
```

**`libEGL` and `libgbm` are dispatch stubs.** They are what our binaries link, so
they are what `ldd` names, and they are not the driver. The code that drives an
AMD card is `libgallium` (42 MB), reached through
`/usr/local/lib/dri/radeonsi_dri.so`, opened **by name at runtime** — and it in
turn wants `libLLVM.so.19.1` (118 MB), because radeonsi compiles shaders with
LLVM. Nothing we build mentions any of the three, so none of them was on the
stick, and `wlr_renderer_autocreate` had nothing to create a renderer with.

**Why no test could have caught it.** The build VM has no `/dev/dri`, so there is
no render node, so `undertow` takes the **pixman software renderer** and never
asks Mesa for anything. The GLES2 path had never been executed in this
project's history. Worth knowing: `WLR_RENDERER=gles2` fails headless in the VM
with the *same message* even with `mesa-dri` installed — one sentence for two
unrelated causes, which is its own small trap.

**The fix is a root, not a package.** These are extra roots for the same `ldd`
closure, so `libgallium` pulls `libLLVM` and the rest exactly as every other
library arrives. Adding `mesa-dri`/`mesa-libs` to the package list instead — the
first thing tried — produced a **5 GB staging root against a 3 GB image**,
because `pkg fetch -d` is transitive and Mesa drags in the world. That is P5.3's
lesson re-learned from the other side within the same hour.

> **The rule: a closure computed over what you link is complete only if nothing
> you link loads code by name.** Any plugin host — Mesa, PAM, `nss`, a codec
> loader, `dlopen` anywhere — is a root your closure does not know about, and the
> failure appears only on a machine that reaches the plugin.

The whole `dri/` directory rides along because its 51 entries are symlinks to one
small loader, so Intel's `iris` and the `swrast` fallbacks cost nothing beyond
AMD's — a medium that refuses to start on the next machine along cannot populate
a hardware matrix.

### 2.51 On a live medium, "is this disk in use?" has the wrong subject
(The retarget, again — checking whether the medium was safe to boot on a machine
whose single disk could not be lost.)

`Safety.swift` had three refusals guarding somebody's data, and on a live medium
**all three are silent about the disk you are about to erase**:

| Refusal | What it actually asks | On a medium |
|---|---|---|
| `diskHoldsRunningRoot` | is this the disk I booted from? | that is the **USB stick** |
| `diskIsMounted` | is anything mounted from it? | nothing is — see below |
| `poolNameInUse` | is a pool of that name imported? | none are imported at all |

The common cause is one word: every one of them describes the **running** system,
and the whole point of a live medium is that the running system is not the
machine's. The medium deliberately sets no `zfs_enable`, so it imports nothing —
which is what makes it *safe to boot* and simultaneously what makes it *blind*.
A disk carrying a complete FreeBSD install is unmounted, unimported, and
indistinguishable from an empty one.

The missing question is "what is *on* it", and the answer is a scan rather than a
mount: **`zpool import` with no arguments lists pools available to import and
imports nothing.** Verified both ways before the code was written — the scan
found a pool on a disk and `zpool list` afterwards was unchanged. `gpart show` is
the same shape for the non-ZFS case.

The generalisation is worth more than the fix: **when a program runs somewhere
other than the system it is acting on, re-read every predicate for whose system
it is asking about.** An installer, a rescue image, a recovery tool and a jail
all have this seam, and the predicate that looks most obviously correct — "am I
running from that disk?" — is the one that inverts.

**And the fix was half-invisible for the same reason twice.** `InstallerModel.objection(to:)`
matched refusals with a `switch` ending in `default: continue`, so the new
refusal was raised by the model and *silently dropped by the picker* — the disk
stayed choosable (§2.46, for the second time in this installer). The repair is
structural, not a test: the switch is now exhaustive, so the next refusal added
to `Safety.swift` will not compile until the screen has been taught to show it.

### 2.50 A check that dies inside a command substitution fails silently
(Retarget to the RX 6750 XT — the first time `live-image.sh` ran its own ESP
code, which P4.0 had said in writing it never had.)

`live-medium.sh` asserts the ESP's shape by reading two fields out of the boot
sector:

```sh
esp_type=$(sudo dd if="/dev/${md}p1" bs=1 skip=54 count=8 2>/dev/null)
```

Two things wrong, and the second hides the first.

- **`dd bs=1` on a raw FreeBSD device is `Invalid argument`.** A character device
  does whole-sector transfers only, so an unaligned single-byte read cannot work
  no matter what is on the disk. Read the sector once into a file and slice
  *that*.
- **Under `set -eu`, a command substitution in an assignment takes the whole
  script with it.** The `2>/dev/null` swallowed dd's complaint, `set -e` saw a
  non-zero status, and the script exited **with no FAIL line and no last check
  named** — the log simply stopped one `ok:` short of where the failure was. Ten
  minutes went into "which assertion is missing" before "why is there no error".

The rule: **a check that cannot fail out loud is worth less than no check**,
because a silent exit reads as a suite that ran out of things to say. Where a
test's own plumbing can fail, give it its own `|| fail` with a message naming the
device, and never let a `$( )` be the thing that decides whether the script
lives.

### 2.49 "The option was accepted" is not "the value was accepted"
(Same run. The medium had not been buildable for two weeks and nothing said so.)

P4.0 fixed a real bug on real hardware: a Mac Pro would not list our stick until
the ESP was FAT16 with media descriptor **0xf8** instead of makefs's FAT32 with
0xf0, the *floppy* byte. It was verified by reformatting the stick **by hand**,
and the pass said plainly that `live-image.sh`'s own run of the same thing was
still to be exercised.

It was exercised, and it failed on the first line:

```
makefs: Media descriptor `f8': illegal number
```

**`makefs(8)` parses `media_descriptor` in decimal only.** Measured across the
spellings rather than guessed:

| value | result |
|---|---|
| `0xf8`, `0xF8`, `f8`, `F8` | `illegal number` |
| `0370` | read as **370**, "greater than 255" |
| **`248`** | builds, and writes 0xf8 at offset 21 |

What made it survivable for two weeks is the shape of the earlier claim.
P4.0 checked that makefs **accepted the four option *names*** it was using, and
reported that as evidence the invocation worked. Accepting a name is a check on
the parser's vocabulary, not on its arithmetic — the same gap as §2.37's probe
with no positive control, one level down: **the thing that was verified was
adjacent to the thing that mattered.**

The pairing is the lesson. This bug was unrunnable *and* undetected because the
assertion written to catch it could not execute (§2.50). One bug hid the other,
and both lived in the exact path a commit message had already pointed at.

### 2.48 A nested compositor's schedule is not its own
(P4.1 — `undertow` on a backend that is not headless, for the first time.)

`undertow run --backend auto` inside a Wayland session works: a real output, a
real mode, real buffers, real input from an actual mouse. It also reported
**107 missed flips of 180**, while compositing in 18 µs against an 8 ms margin.

Nothing is slow. A compositor inside another compositor presents when its *host*
presents, so "missed" is measuring our latency against a clock we do not own.
The metronome already distinguishes two cases — a hardware timestamp, passed
through untouched, and a synthetic one, snapped to the nominal grid — and nesting
is a **third** it does not model: a real timestamp from somebody else's clock.

The decision is to leave it: nested is for input and drawing, and its miss count
is *not applicable*. Tuning until that number looked good would be optimising
against a clock we do not own, which is §2.37's error wearing different clothes.
C1 gets re-measured on DRM, where the vblank really is ours — and where
`WLR_OUTPUT_PRESENT_HW_CLOCK` will be set for the first time in this project's
history. **Every C1–C5 number in PHASE6.md is provisional until then.**

And the smaller one, from the same first run:

- **On a real backend the display's size is the truth, not yours.** Headless
  invents an output at whatever size it was asked for, so eight phases of code
  learned to trust its own `--width`/`--height`. Given 900x700 on a 1280x720
  output, the compositor laid the desktop out for a screen that was not there and
  the menu bar reserved its strip across the wrong width. A monitor arrives with
  a mode already; take it.

### 2.47 getty revokes the console, and your background service goes mute
(P5.5 — the live medium running the installer, and installing from its own
console.)

The live session was backgrounded so that rc would finish and the console come
up while the desktop ran. It printed **exactly one line** and then went silent —
no error, no exit, no core. It looked like a crash three separate times.

It is a redirection. `getty` calls **`revoke(2)`** on the terminal it is about to
offer a login on, and `revoke` invalidates *every* descriptor any other process
holds to that device. A background process that inherited the console from rc —
or that opened `/dev/console` itself, which was the second thing tried — has its
writes fail from the instant the login prompt appears. Reopening per write would
work and is ridiculous.

The fix was to stop wanting the thing: the session runs in **rc's foreground**,
and the console arrives when it ends. A medium built `--stay` then waits there,
which is when a person — or a test — can use it. The trace that found this is
worth keeping (`ABYSS_LIVE_TRACE=1` puts `set -x` in the live session), because
on a headless medium the console is the only instrument there is.

Two more from the same pass:

- **An unprivileged session cannot write to `/var/log`.** The compositor's frame
  capture failed with a message naming a path, which reads as a compositor bug
  and is a permissions one — the session runs as the live user *on purpose*
  (§4.4 is only load-bearing if the GUI is not root). It writes into its own
  runtime directory and root moves the result somewhere findable.
- **The peer check will refuse you, and that is it working.** Driving the install
  from the medium's console as `root` fails: the service was started for uid
  1001 and hands its socket to exactly that uid. Log in as the session user
  instead. The medium's `.profile` points `abyss-installctl` at the session's
  runtime directory, because nothing else would find it.

### 2.46 A GUI cannot be trusted to be right about itself
(P5.4 — the Aqua installer, and the live test that clicks it.)

Three findings, and the first is the general one.

**The model's tests all passed, and the app was still wrong.** Pressing Choose on
a disk that cannot be used returned you to the hub with nothing chosen — which
looks exactly like success. Twenty unit tests over the model had nothing to say,
because each of them called `chooseSelection()` and then asked what the model
held; none of them asked *where the user now was*. The live test found it in the
crudest possible way: the list it was about to click had disappeared. A choice
that does not take must not leave the screen that explains why.

**Do not put coordinates in a test that clicks things.** They are a copy of a
screenshot from the day it was written, and they rot silently — the clicks still
land, just not on anything. `ABYSS_INSTALLER_DUMP` makes the app publish the
centre of every rect it drew *and its own surface size*, and the test clicks
those. Injecting the classic failure — the painter no longer updating the layout
the hit-tester reads, so what is drawn and what is clickable drift apart — is
then caught at once. It is also a bug no unit test can see, because in a unit
test there is only one copy of the layout.

**`print` is invisible to whatever is watching your log.** Swift buffers stdout
when it is not a terminal, so the installer's startup line never reached the
file the live test was polling — the app was up and drawing, and the test timed
out waiting to be told. Everything the harness waits on goes out through
`write(2, …)`, which the tree already does for the reason in §2.4.

Two smaller things worth keeping:

- **Unregister a descriptor before closing it, and make the loop enforce it.**
  `Display` had no `removeFileDescriptor`, so an install's progress socket could
  not leave the poll set — and a closed fd left in it returns `POLLNVAL`
  immediately, for ever. The dispatch also now skips a handler that was
  unregistered earlier in the same pass: it would otherwise read a descriptor it
  already closed and close it twice, which in a process full of sockets can shut
  somebody else's connection that inherited the number.
- **Link the protocol, not the executor.** `Wire` became its own target so the
  GUI can speak to `abyss-install` without linking the code that forks `gpart`.
  "The GUI does not touch the disk" is worth making true of the *binary*, not
  just of the design — there is then no path from a click to a partition table,
  because the instructions are not in that process.

### 2.45 A package manager's closure is not your program's closure
(P5.3 — the live medium, and what belongs on it.)

The obvious way to put a desktop on an image is to install the packages it was
built against. Asking `pkg -r $stage install wlroots019 cairo harfbuzz dejavu …`
produced a **5.66 GB** staging root in 224 seconds — wlroots pulls Xwayland, mesa
pulls LLVM, something pulls avahi — and left **409 binaries** in
`/usr/local/bin`, `2to3` among them, on a medium whose job is to partition a
disk.

`ldd` over the twelve binaries we ship answers the same question exactly: **67
shared objects, 17 MB**, transitively closed. It cannot drift from the product,
because it *is* the product. Result: **327 MB, built in 15 seconds.**

A package manager resolves *what a build needs*, which is the right question for
a general-purpose system and the wrong one for an appliance image. The cost of
the other answer is real and has to be stated: no package database on the medium,
so nothing on it can install anything. Say that out loud rather than discovering
it.

Three more from the same pass:

- **Carry only what is not already there.** `ldd` also names `/lib/libc.so.7`;
  copying that makes the medium a mixture of the builder and the distribution
  sets. base.txz marks those files `schg`, so the attempt fails loudly — which
  is how it was found rather than shipped. Only `/usr/local` crosses over.
- **`-static-stdlib` is the wrong trade at this count.** Measured on the
  smallest binary in the tree: **296 KB dynamic → 9.1 MB static**. Twelve
  binaries of that is worse than one shared 80 MB copy of the Swift runtime,
  itself a fraction of the 2.70 GiB swift6 package.
- **A silent fallback defeats a pixel test.** A medium built with no fonts at
  all passed every assertion — three layers composited, the chrome in the right
  places — because `Aqua.Text` falls back to toy text without saying so. Right
  for a missing italic; wrong for a machine that has lost every glyph. The menu
  bar had 25 dark pixels with fonts and 15 without: far too close to assert on.
  The fix was not a cleverer probe but a **report**: the desktop now says what
  its text stack got. Where a component degrades gracefully, something has to
  announce the degradation, or no test downstream can see it.

### 2.44 An install that reports success is not an install that worked
(P5.2 — `abyss-install`, and the live test that boots what it installed.)

§2.43's lesson, one level up. The step list is now run by a real program that
reports each step over the control plane, and the first fault injected into it
was the `zpool set bootfs=` step replaced by `true`. Every step succeeded. The
service logged **"install: 39 steps, ok"**. The client printed **"installed."**
And the machine booted to the loader's `OK` prompt, because nothing had told it
what to boot.

Only `grep -q "login:"` knew. Not the exit status, not the pool importing, not
the absence of any error anywhere — a machine we partitioned, from a kernel we
extracted, reaching multi-user. Where a program's output is a *thing* rather than
a value, the test has to assert on the thing.

Three more, from the same pass:

- **`geom disk list` does not show `md(4)` devices**, and neither does
  `sysctl kern.disks`. P5.1 installed onto a file-backed md and it worked
  perfectly — but the installer's own machine probe cannot see such a disk, so
  the live test could not use one. The fix is a **real** scratch disk on the
  build VM, not a probe taught about memory disks: a test that needs the product
  to grow a code path is a test of something the product does not do.
- **"May command it" and "can reach it" are different questions.** The peer
  check (§4.4 / `getpeereid` / `SO_PEERCRED`) answers the first and does nothing
  about the second: a root-owned 0600 socket is one the caller cannot open at
  all. `abyss-install` therefore hands its socket to the one uid it was started
  for *and* asks the kernel who called. Neither alone is enough — permissions
  are defeated by anything running as root, and a peer check grants nobody
  access.
- **A force-unwrap in an XCTest kills the process**, so one broken thing hides
  every test after it. Two injected faults reported the wrong test's name until
  the `!`s became `XCTUnwrap`. A suite that dies on the first failure tells you
  less than one that fails.

### 2.43 A list of commands is not verified until something runs it
(P5.1 — the install as a value, and the first pass whose output is a *plan*
rather than a program.)

`de/install` compiles an `InstallPlan` into a step list: the exact `gpart`,
`zpool`, `zfs` and `tar` invocations, in order. It has 28 unit tests, a golden
render of the whole list, and four injected faults to prove the suite can fail.
Reading that list, it looks right. It was wrong in **four** ways, and every one
of them was found by turning the rendered output into a shell script and running
it against a file-backed disk — then booting the result.

- **`zpool create -o cachefile=X` sets a property and does not write X.** The
  copy into `/boot/zfs/zpool.cache` failed with ENOENT against a pool whose
  `cachefile` property `zpool get` reported correctly. Ask for the write.
- **`zfs mount -a` / `zfs umount -a` are machine-wide.** They act on every pool,
  including the running installer's own root — the first run reported *"cannot
  unmount '/var/log': pool or dataset is busy"* about the live system. An
  install touches the pool it is building and no other, so name the datasets.
  (`zpool export` unmounts its own pool, which is exactly the right set.)
- **`zfs create` mounts what it creates.** Create `pool/home` before
  `pool/ROOT/default` is mounted and it mounts at `/mnt/home` on the *live*
  filesystem, which the root mount then hides. The install completes, extracts,
  and produces a machine whose `/home` is empty and whose files are somewhere
  nobody will look. The boot environment must exist **and be mounted** before any
  other dataset is created.
- **The machine booted with no swap**, and said so in one line of a log nobody
  reads. `fstab` named `/dev/gpt/<pool>swap`, and there was no `/dev/gpt` at all:
  GEOM's disk-ident class had consumed the disk, so the GPT sat under
  `diskid/DISK-BHYVE-…` and no label provider was ever created. `gpart show -l`
  **still listed the labels**, which is what makes this so convincing to look at
  and so wrong. Measured both ways: with
  `kern.geom.label.disk_ident.enable="0"` in `loader.conf`, `/dev/gpt` appears
  and `swapinfo` shows the partition; without it, neither.

None of the four is a mistake a careful reader catches, and each ships a broken
machine. The generalisation is the one this project keeps relearning from a new
angle (§2.37, §2.39): **a model of the work is not the work.** A plan is a good
idea precisely because it can be inspected — and inspecting it is not the same as
executing it. Where the output of a pass is a description of what some other
program will do, the pass is not finished until something has done it.

*The corollary that made it cheap:* the list is a value, so the check cost
nothing to build — render, mechanically translate, run. The same property that
makes a plan testable makes it **executable in anger**, which is the whole reason
P5.2 has a live test and not a demonstration.

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

> **2026-09-28 (BACKLOG S.2):** `undertow`'s keybind `run:` action broke this
> rule for a whole phase — its child `strdup`ed every word, bridged a Swift
> `String` for the path and searched `PATH` inside `execvp`, all after `fork`.
> Found by a survey, not a hang: the deadlock is a race nobody had lost yet.
> It now uses `Spawn.detached` (`de/spawn`, no dependencies), which also takes
> the argv pointer before forking so the child runs no Swift at all. `Launcher`
> and `anchor` still carry their own copies; moving them is S.3.
>
> **S.3, the same day, found the mistake three more times** — the installer's
> step runner (which runs as root) and its machine probe each built argv inside
> the child with a `withCStrings` that `strdup`s, and `fathom` `strdup`ed there
> too — and two more faults beside them: `fathom` drained stdout to its end
> before reading stderr, so a child that filled stderr first would hang both;
> and the installer closed its pipe at 8 KiB, so a chattier step died of
> SIGPIPE and was reported as a failed step. All of them now call `Spawn.run`,
> which does not fork in Swift at all (`posix_spawn`), services input and both
> outputs in one `poll` loop, drains past its limit, and blocks SIGPIPE while
> writing input. `Launcher` uses `Spawn.detached(_:environment:)`; `anchor` and
> the portal keep `cproc` (pdfork) and share `Spawn.withCStrings`. There is one
> `resolveExecutable`. **No Swift in this tree forks except `de/spawn`.**
> Each fault was put back and its test failed — the limit test only after it
> stopped running `head` under `sh -c`, whose shell exited 0 over its child's
> SIGPIPE and hid the bug.
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

**What the numbers mean**, because they are three different things and the docs
once drifted on it: **33 live modes** are `run-live.sh`'s scenes (the sway- and
`undertow`-driven ones in the two tables above it); **33 live scripts** are the
standalone `live-*.sh` ones `run.sh` invokes, listed below; **538 unit tests**
are `swift test`; **72 golden scenes** are `golden.sh`'s, per platform.
(Recounted 2026-09-25: the docs had said 35 modes and 31 scripts.) A count that is incremented without checking its denominator is a
count that will be wrong, and this one was.

**Run them all:** `abyss/tests/run-live.sh` drives every mode in order with a
per-mode timeout and prints a pass/fail table (`-o DIR` keeps the PNGs and logs,
or name a subset: `run-live.sh dock trash`). 33 modes today. These are the
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
| `live-subsurface.sh` | a window made of **subsurfaces** — over, outside and below its parent — drawn, framed and routed to the leaf (§2.71) |
| `live-hidden.sh` | a **minimized** window keeps a slow frame clock (not none, not 60 Hz), is told it is `suspended`, and what the compositor can do (§2.72) |
| `live-present.sh` | **presentation-time**: every frame a client commits is reported shown, on `CLOCK_MONOTONIC`, at the display's period — 60 and 144 Hz (§2.74) |
| `live-settings.sh` | **System Preferences' privileged half**: a non-administrator refused; check, dry run, the Linux refusal; in the guest, as root, root refused by the peer check and a real `sysrc` apply to a scratch `rc.conf` (P14.3) |
| `live-appearance.sh` | **the theme changes while the desktop runs**: `undertow`, the desktop, bar, Dock and an Aqua window (each its own process), and the portal (`SettingChanged`, decoded by GLib) follow `abyss-theme set` and the General pane; pixels change and come back byte for byte (P14.2, §2.75) |
| `live-gpu.sh` | **GPU clients through `linux-dmabuf`**: pixman says it offers none; on a render node, es2gears and vkcube run on it and are seen moving; a screenshot on every renderer is the right colour. GPU half skips without a render node (§2.73) |
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
| `live-screenshot.sh` | a client that cannot call `socket(2)` — so cannot reach the compositor — holds a picture of the screen, and the file it came from is already unlinked |
| `live-install.sh` | **an install, and the machine it made boots.** A root `abyss-install` commanded by an unprivileged caller partitions the VM's scratch disk, and nested `bhyve` boots the result to `login:`. Refuses the disk it is running from, live. On Linux, a positive control: the probe must say what it could not find |
| `live-medium.sh` | the live medium is **built** (`makefs` + `mkimg`, no `make release`) and **booted**, and the frame it captured is probed pixel by pixel. Asserts it carries `amdgpu.ko`, the Southern Islands firmware, `seatd` and the `si_support` knob — what a VM can check of PHASE4 §5 |
| `live-installer.sh` | the **Aqua installer**, driven by a real pointer and a real keyboard on `undertow` against the real service in dry-run. Clicks come from the app's own published layout, never from constants (§2.46) |
| `live-desktop.sh` | the whole arc, nested twice over: **a blank disk, our medium, an install from its console, and a reboot into the Jaguar desktop** as the account created |

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
abyss/tests/run.sh                 # build + 538 unit tests + smoke render + the
                                   # no-compositor live tests (incl. undertow)
abyss/tests/run.sh --live          # ... and all 35 compositor modes
abyss/tests/run.sh --vm            # the same, inside the FreeBSD VM
abyss/tests/run.sh --vm --live     # the FreeBSD half of the gate  (~280s)
                                   # — it runs ONLY in the guest; Linux is
                                   # `run.sh --live`, a separate run
abyss/tests/run.sh --vm --live --full   # ... and the two nested installs (~1000s)
```

**`--full` is the lane that puts an operating system on a disk**, and it is off
by default because it was 681 of the 1111 seconds a run used to cost — more than
everything else in the suite combined. `live-install.sh` installs under nested
bhyve and `live-desktop.sh` installs and boots the result. Run them for anything
touching the installer, the medium, the distribution sets or the boot path; the
default lane names them, prices them and says so, because a skip nobody sees is a
claim nobody checks.

Two other things pay for that number, and both are measured rather than assumed
(`run.sh` prints per-phase seconds now):

- **The medium is cached** (`abyss/mk/live-image.sh`). The key covers the script
  itself, the flags, the distribution sets and **every binary the medium carries,
  by content** — so a one-line Swift change rebuilds, and only a genuinely
  identical image is reused. What a hit skips is the assembly; the tests still
  boot the image, so a wrong one fails exactly where a freshly built wrong one
  would. `ABYSS_NO_CACHE=1` forces the build.
- **The desktop set is zstd, not xz.** `tar -cJf` over that tree was 48 of the 92
  seconds a build cost — 103s for 625 MB on the guest, against 1.7s for zstd at
  +42% size, and bsdtar exposes no xz level knob. The set is `abyss.tzst` now,
  because a `.txz` that is not xz is a trap for whoever next reaches for `xz -d`.


The 538 unit tests are pure logic — no compositor, no network: toolkit geometry,
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
`run.sh --vm --live` is green — plus `--full` when the pass touched the
installer, the medium or the boot path.

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

> **Superseded for ordering by [BACKLOG.md](BACKLOG.md)** (2026-09-28), which
> merges this section with PHASE14's passes and the API-study review's
> findings. What follows is still the context for its items; the
> golden-image item in §3 is done (Phase 11's gate).

**Where things stand.** Phases 0–3, 5–8 **and 9** are complete. The Jaguar shell
runs on FreeBSD, on our own compositor, over a Swift control plane, session
supervisor and hardware bridges; one command boots a desktop where an unmodified
GTK 3 application opens a file through the Finder; **a blank disk becomes a
machine running that desktop**; and since Phase 9 the desktop is one you can
*use* — copy and paste, drag and drop, move and resize and zoom and minimise
windows, keyboard shortcuts, and an Aqua frame around applications that never
heard of it. **543 unit tests, 33 live modes and 34 live scripts, green on Linux
and FreeBSD** (and 70 golden scenes on each, since Phase 11). On metal, the Aqua installer is on screen on the bring-up machine
and the frame contract does not yet hold there (item 2).

Per-pass detail lives in the phase docs; this section is what to do next, not a
record of what was done.

### 0. Read this first: what Phase 9 changed underneath everything

Phase 9 was the interaction substrate ([PHASE9.md](PHASE9.md), P9.1–P9.7), and
five of its seven passes found something **already broken** rather than merely
missing. If you are picking this up cold, these are the ones that change how you
read the rest of the tree:

| Pass | What it added | What it found (§) |
|---|---|---|
| P9.1–9.2 | clipboard, ⌘C/⌘V across processes | a client must never read a selection it owns (§2.45) |
| P9.3 | drag and drop, three targets | **`wl_proxy_destroy` sends nothing** — every closed window leaked a mapped surface (§2.57); layer surfaces were never hit-tested (§2.56); a self-drag deadlocks (§2.55) |
| P9.4 | move/resize/zoom/minimise, edge snapping | undertow made **no foreign-toplevel handles**, so the Dock saw nothing under our own compositor (§2.58) |
| P9.5 | the keybind table, `keys.ini`, `[passthrough]` | `Seat.focus` never set **`xdg_toplevel.activated`**, so every window had drawn itself focused since Phase 6 (§2.59) |
| P9.6 | server-side decorations | `set_mode` before the initial commit **crashes wlroots**; GTK never asks to be decorated |
| P9.7 | the XWayland decision: **no** | the reason is written in PHASE9 §6.3, and `live-session.sh` enforces it |

**The pattern is one lesson in five costumes** (§2.54, §2.56, §2.58, §2.59): the
gap is never in the code that runs. It is in the state nobody reads, or the
object nobody creates, until a feature finally needs it. When you add a protocol,
name the object a client actually *receives* through it; if nothing constructs
one, the global is furniture.

**Two structural changes to know about.** `AquaDraw` is now its own target —
`Rect`, `Theme`, `Draw`, `Text` and the window chrome — because the compositor
links it to paint frames; `Aqua` re-exports it, so call sites are unchanged. And
the suite has lanes: `run.sh --vm --live` is ~280s, while **`--full` adds the two
nested-bhyve install tests (~1000s total) and is the rule for anything touching
the installer, the medium, the distribution sets or the boot path.**

### 1. Phase 11 — the theme system

**COMPLETE** ([PHASE11.md](PHASE11.md)): ten passes, and `run.sh --live` plus
`run.sh --vm --live --full` green (after one fix: the theme loader announced
`bin/../share`, and the medium's check read the path literally). What it built:
- **a theme is a directory**: `theme.ini` (tokens, schemes, bounded
  parameters, metrics, `[fonts]` roles, `[chrome]`), `draw/*.dl` and
  `icons/*.dl`, loaded strictly, with the compiled Jaguar (`JaguarLists`,
  `ThemeTokens.jaguar`) behind it;
- **Jaguar as data**, proved byte-identical to the Swift it replaced
  (`DrawParityTests`, `IconParityTests`);
- **one chrome layout function** feeding both sides' paint and hit-test, with
  a depth gadget over `abyss-window-v1`;
- **Trench** (`themes/trench`), Plan Neo, which `golden.sh` refuses to let code
  name;
- **`svg2dl`**, build-time SVG import; **`abyss-theme`** (`palette`, `check`);
- **the golden gate**: 69 scenes on each platform.

The traps it added are §2.66–§2.69. **What it leaves** is in PHASE11 ("What
Phase 11 leaves"): the §6 decisions, the format gaps P11.9 recorded, and
layers 4 and 5.

### 1a. Phase 10 — the menu protocol

Scoped in **[PHASE10.md](PHASE10.md)**; **Phase 10 is COMPLETE**: all eight passes, and `run.sh --live` plus
`run.sh --vm --live --full` green. The next phase is 11, the theme system. **What Phase 10 leaves:
submenus draw their ▸ and have never opened** (PHASE10 P10.8). The spikes moved work into
the compositor: under `undertow` a GTK application exports its menus on the bus
and tells nobody where, so undertow has to speak `gtk_shell1` — the first
protocol it implements itself. The phase ([PLAN.md](PLAN.md)): the menu bar stops being a picture
of a menu bar. It is `Before` Phase 15 in the dependency order for a reason —
every application built without it has to be retrofitted — and it is on Phase
18's critical path because what it publishes is a **vocabulary**, not a drawing.
Phase 9 left it two things: the keybind table already turns a combination into
an action (P9.5), and §6.5 records that **undo has to be decided here**, before
there are applications to retrofit.

Phase 9 also left one thing open on purpose: **`wlr-data-control`** (PHASE9 §6.7)
— the protocol a surfaceless clipboard tool needs, in both directions. Nothing
asks for it yet; `abyssclip` is the thing that would.

### 2. Phase 4's open result: the frame contract fails on metal

Where the metal work stands (PHASE4 §5.3–§5.10): **steps 1–5 of the checklist
pass** on the i7-12700KF / RX 6750 XT; the install is **deferred** (the machine's
only disk is the positive control), so P4.6's install half and P12.6 are
dropped; and `Fathom`'s report comes off the stick's ESP or over ssh.

The one open result is P4.5: **58 of 300 frames missed, compositing in 12 µs
against a 16.68 ms period**, with the margin pinned at its 8 ms ceiling. PHASE6's
C1–C5 are therefore known not to transfer, not merely provisional. Run mode now
reports `margin-wake/cost/commit/safety-us` and `margin-pinned`, and
**that breakdown has not yet been run on the machine**. The hypothesis written
down to be wrong: `commitHigh` dominates. If so, the fixes are ordered — `rtprio`
for the present thread, then the margin ceiling. The loop:

```
abyss/mk/live-image.sh --ssh-key ~/.ssh/id_ed25519.pub ...   # developer medium
abyss/mk/metal.sh report                                      # fathom --measure
```

And a number measured only on one fast machine is measured once (PHASE4 §6.7):
P4.5 needs a second row — the Mac Pro, or a deliberately constrained run —
before it is finished. **The volume status item** has a mixer to read at last
(`pcm0`…`pcm7`), which is what is left of P4.6.

### 3. Standing smaller items, none blocking

- **There is no login window** (PHASE5 §6.8). The installed machine starts the
  desktop from `rc` as the account the installer created — right for a machine
  with one user, wrong for a machine with two. PLAN.md's Phase 2 sketch listed
  `LoginWindow`; this is the first thing that actually wants it.
- **The live medium's root is mounted read-write.** Fine for a disk image,
  wrong for a USB stick somebody can pull out mid-write; a shipped medium wants
  read-only plus tmpfs (PHASE5 P5.3).
- **Golden-image tests** — snapshot the deterministic PNG scenes and diff in CI
  (`finderSampleEntries`/`desktopSampleEntries` exist for exactly this). The
  cheapest guard against silent visual regressions, and the surface worth
  guarding keeps widening — the installer added five more screens.
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

### Three rules that earned their place

**A pass is not done until `abyss/tests/run.sh --live` and `run.sh --vm --live`
are both green** — two runs, because `--vm` runs the suite *only* in the guest.
(P10.1's commit claimed both platforms off one `--vm` run, whose log prints
"Executed 430 tests" twice: that is XCTest's suite line and its total, not two
platforms. The Linux gate was run afterwards, with P10.2, and is green.) Two
Phase-3 bugs were invisible on Linux and failed only on FreeBSD (§2.33, §2.34).
Add `--full` when the pass touched the installer, the medium, the distribution
sets or the boot path — that lane is the only one that puts an operating system
on a disk and boots it.

**A test that has never failed has not been shown to test anything.** Phases 6,
8, 5 and 4 each caught a false pass by deliberately breaking the code and
checking the suite noticed (§2.37, §2.39, §2.43, §2.46). It costs ten minutes and
it is the only thing standing between "green" and "green for the reason I think".

**A model of the work is not the work.** Five of the last six traps (§2.43–§2.48)
were found by *running* something that had already been reviewed, tested and
believed: a step list with 28 tests was wrong four ways, an install that reported
success booted to a loader prompt, a medium that passed every pixel check had no
fonts, a GUI with twenty green model tests had a screen that only looked like it
worked. Where a pass's output describes what some other program will do, or what
some other machine will show, it is not finished until something has done it.

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
- **The build VM has a third disk, and the tests wipe it.** `abyss/vm/run.sh`
  attaches `../abyss-swift-vm/abyss-scratch.qcow2` (12G) as `vtbd2`, and
  `live-install.sh` writes a GPT over whatever is on it on every `--live` run.
  It is a real virtio disk rather than an `md(4)` device because `geom disk
  list` does not show md devices, so the installer's own probe cannot see one.
- **The distribution sets are cached in the guest at `/home/build/dist`**, which
  is *outside* the rsync'd tree (`sync.sh --delete` would otherwise remove them).
  `live-install.sh`, `live-medium.sh` and `live-desktop.sh` skip loudly without
  them rather than failing; fetch base.txz and kernel.txz there once.
- **`--vm --live` is about twelve minutes now**, most of it the two nested boots.
  If that becomes a reason not to run it, the boot checks belong behind their own
  flag — said out loud in `run.sh`, never quietly dropped (PHASE5 §6.6).

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
| `de/install` | the installer's thinking half: `InstallPlan` and `DiskInventory` (the machine as an *argument*), the refusals, and the step list a plan compiles to — no dependency at all, so every test runs on Linux where `gpart` does not exist |
| `de/installrun`, `de/installbin`, `de/installctl` | the doing half: the step runner, the machine probe (`geom disk list` / `mount -p` / `glabel` / `zpool`, parsed pure and tested against captured output), the peer check, the wire codec — plus `abyss-install` (root) and `abyss-installctl` (the caller) |
| `abyss/mk/live-image.sh` | the live medium: base + kernel from the distribution sets, the runtime closure computed with `ldd` (not `pkg` — §2.45), the desktop, and a session started by rc; assembled with `makefs` + `mkimg` |
| `de/installwire` | the install protocol on the control plane — its own target so the **GUI links the protocol and not the executor** (§2.46) |
| `de/abyssctl` | `abyssctl status\|quit` — drive a running session over the control plane |
| `de/portal`, `de/portalbin` | the file-chooser portal: `PortalRequest` (the confused-deputy rule, enforced by the type), the service, `abyss-portal` |
| `de/abyssopen`, `de/ccap` | the sandboxed client (files **and** `--screenshot`) and Capsicum's `cap_enter` |
| `de/abyssnotify` | `notify-send`, brokerless — through the portal, as a jailed app would |
| `de/abyssgrab` | capture an output to a PNG via `wlr-screencopy`; the portal forks it, so the portal itself is never a Wayland client |
| `de/undertow`, `de/undertowbin` | **the compositor** (PHASE6.md): `Metronome`, `FlightRecorder`, `Output`/`FrameSink`, `Backend` (the wlroots bridge), `Compositor` (globals, socket, windows), `SurfaceScene` (our SoA scene — deliberately **not** `wlr_scene`), `Seat` (input, cursor, focus; `PointerRouting` is the pure hit-test) and `LayerShell` (the shell's surfaces; `LayerArrange` is the pure placement rule) — `undertow` is its own bench harness. **`Backend.Kind` (P4.1)** picks headless or `wlr_backend_autocreate`; headless is the default because it is the only thing the build VM can do |
| `de/cwlroots` | **29 lines of C**, and that is the whole wlroots binding: Swift imports the headers directly, but `wl_signal_add` is a static inline and `wl_container_of` is a macro, so every wlroots event arrives through one trampoline (§2.1 at scale) |
| `de/cwlrootssys`, `de/cwaylandserver` | pkg-config flag carriers for wlroots-0.19 and libwayland-**server** (§2.29's pattern) |
| `de/callocprobe` | counts allocations by symbol interposition; the enforcement half of PLAN.md risk 4. **Executable-only, and useless without its positive control** (§2.37) |
| `de/vents`, `de/cvents` | the hardware bridges: sysctl, OSS volume, battery, devd (§2.34) |
| `de/ventsctl` | `ventsctl sysctl\|volume\|battery\|devd` — read the machine by hand |
| `de/ipcprobe` | `ipcprobe serve|send` — two processes, one descriptor; driven by `abyss/tests/live-ipc.sh` |
| `de/aquademo` | the runnable demo; `AQUA_SCENE` picks a scene/component |
| `abyss/session.sh` | the dev session launcher — one command boots the desktop (§2.26) |
| `abyss/tests` | `run.sh` (build+test+smoke; `--live`, `--vm`), **`run-live.sh`** (all 33 live modes, pass/fail table), `live-sway.sh`, `live-session.sh`, `live-portal.sh`/`live-sandbox.sh`/`live-notify.sh`/`live-screenshot.sh`/**`live-portal-dbus.sh`**/**`live-gtk.sh`**/**`live-session-gtk.sh`** (the portals, driven from `run.sh --live`), `live-dbus.sh`, `gtkpick.c` (a stock GTK client, `dlopen`ed so nothing here links GTK), the virtual input helpers |
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
