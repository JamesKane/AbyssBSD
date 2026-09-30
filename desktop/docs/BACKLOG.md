# Backlog — everything open, in one order

_2026-09-28. Gathered from STATUS "What's next", HANDOFF §5, PHASE14's passes, the
phase docs' "what it leaves", and the API-study review ([API-STUDY.md](API-STUDY.md)).
This is the list to work from; the phase docs keep the detail._

**The constraint that shapes it:** the bring-up machine's USB is in use elsewhere
for now, so **nothing here may need metal to be verified**. Metal work is
collected in §3, to be done in one sitting when the machine is free, and the
work before it is ordered so that sitting tests as much as possible.

**The ordering principle.** `undertow` defects first, because each one is a
global or a clock that lies to every client and every later test inherits it
(HANDOFF §2.58 — five times now). Then Phase 14 as scoped. Then what Phase 15's
applications need from the compositor. **The one ordering call worth your
veto is the first:** it puts three `undertow` passes ahead of P14.2, which was
next.

Sizes are rough: **S** is a pass of a day or less, **M** a few days, **L** a week
or more.

---

## 1. Now — no hardware needed, in order

| # | Item | Size | Why here | Verified by |
|---|---|---|---|---|
| ~~U.1~~ | ✅ **2026-09-28. Subsurfaces drawn, framed and hit-tested** (HANDOFF §2.71, `live-subsurface.sh`) | M | | done, both platforms |
| ~~U.2~~ | ✅ **2026-09-28. A minimised window keeps a clock** — 1 Hz, xdg-shell v6 `suspended`, `wm_capabilities` (HANDOFF §2.72, `live-hidden.sh`) | S | | done, both platforms |
| ~~U.3~~ | ✅ **2026-09-28. `linux-dmabuf`** — GL and Vulkan clients on the AMD iGPU under headless GLES2 `undertow`; screenshots fixed for 24-bit renderers (HANDOFF §2.73, `live-gpu.sh`) | M | | done; GPU half on Linux, pixman half both platforms |
| ~~U.4~~ | ✅ **2026-09-28. presentation-time** — feedback from the output's present event; frame-done keeps the current time, as the protocol says (HANDOFF §2.74, `live-present.sh`) | S–M | | done, both platforms |
| ~~P14.2~~ | ✅ **2026-09-28. The theme changes while the desktop runs** — the General pane and `abyss-theme set`; `undertow`, every toolkit process and the portal (`SettingChanged`) follow (PHASE14 P14.2, `live-appearance.sh`) | M | | done, both platforms |
| ~~P14.3~~ | ✅ **2026-09-28. `abyss-settings`**, the privileged half — typed plans (powerd first), `wheel` at every connection, `sysrc` in a staged `rc.conf`, an `rc.d` service (HANDOFF §2.76, `live-settings.sh`); `live-medium`/`live-desktop` assertions await the `--full` lane | M | | done, both platforms |
| ~~P14.4~~ | ✅ **2026-09-28. Network, wired** — plan and helper, status without privilege (`Vents.Network`), the pane (`live-network-pane.sh`); the reboot gate `live-network-reboot.sh` green in the guest after `live-desktop.sh` (HANDOFF §2.77) | M | | done, both platforms; gate green |
| ~~P14.6~~ | ✅ **2026-09-28. Sound** — §4.3 answered (per-app volume read-only now, `virtual_oss` in Phase 18); `Vents.Sound`, the default device via the helper (`sysctl.conf`), the Sound pane, a real menu-bar volume item (HANDOFF §2.78; `live-sound-pane.sh`, `live-menubar-volume.sh`) | M | | done, both platforms; a *different* default device waits for metal |
| ~~P14.7~~ | ✅ **2026-09-28. Displays** — re-scoped M→L (undertow drove one output): multi-output undertow (EDF `Conductor`), `wlr-output-management-v1` + `displays.ini` (`abyss-displays`; wlr-randr in the guest), the pane (drag, snap, resolution, scale) — `live-displays*.sh` (HANDOFF §2.79) | L | | done, both platforms; display-off and mirroring not offered |
| ~~P14.8~~ | ✅ **2026-09-28. Energy** — `energy.ini` (`EnergyPrefs`, for Phase 16), Energy Saver pane (sleep sliders, powerd via the helper, battery), `live-energy-pane.sh` | S | | done, both platforms; the battery row waits for metal |
| ~~P14.5~~ | ✅ **2026-09-28. Network, Wi-Fi** — `wtap` backported to the guest (upstream d4de0a69a92) with three panic fixes; join/forget through the helper by rc's own path; the passphrase never leaves the pane; Wi-Fi on the Network pane (HANDOFF §2.80; `live-wifi*.sh`) | M | | done: the join verified in the harness |
| ~~P14.9~~ | ✅ **2026-09-29. The phase gate** — `--live` 404 s, `--vm --live --full` 1423 s, green; **Phase 14 complete** (HANDOFF §2.81) | S | | done |

---

## 2. Next — what Phase 15's applications need from the compositor

After Phase 14, before Phase 15 starts. Ranked by what breaks without it
(API-STUDY §2); each costs "create the global" **plus** "teach our scene what it
means" (§1.5 there).

| # | Item | Size | Missing means |
|---|---|---|---|
| ~~U.5~~ | ✅ **2026-09-29. text-input-v3 + input-method-v2**: undertow relays a field's state to the input method and the IM's preedit and commits back, and its keyboard grab takes keys from the application while held. An IM composes 日本語 into zenity's GTK entry (`live-ime.sh`) | L | | done, both platforms |
| ~~U.6~~ | ✅ **2026-09-29. pointer-constraints + relative-pointer**: every motion is also a delta; a lock holds the pointer and a confinement keeps it in a region, only for the focused window with the pointer over it; a lock's cursor hint is where the pointer goes when it ends (`live-lock.sh`) | M | | done, both platforms |
| ~~U.7~~ | ✅ **2026-09-29. cursor-shape-v1, with the theme's cursors**: 18 Jaguar shapes as draw lists (`cursor.*`, hotspot in the list header), rasterised per scale; sizing arrows on the frame; a client with the pointer sets a shape, its own surface, or none (`live-cursor.sh`, `cursors` goldens) | M | | done, both platforms |
| ~~U.7b~~ | ✅ **2026-09-29. Our cursors as an XCursor theme**: `abyss-theme cursors` writes the theme's shapes as "Abyss" (34 names, 4 sizes, 44 X11 names linked), from the same rasteriser undertow draws with; anchor writes it into the runtime directory at login and names it (`XCURSOR_THEME`, `_SIZE`, `_PATH`), keeping a person's own choice (`live-xcursor.sh`). GTK 3.24 turned out to ask for shapes by cursor-shape-v1 already (§2.88) | S | | done, both platforms |
| ~~U.8~~ | ✅ **2026-09-29. viewporter, buffer transforms, fractional-scale-v1**: the scene draws each buffer's source box, turned by its transform; each surface tree is told the largest scale of the displays it is on, fractionally and as wl_surface v6's integer; a 1.5x client reaches a 1.5 display pixel for pixel (`live-viewport.sh`) | M | | done, both platforms |
| ~~U.9~~ | ✅ **2026-09-29. primary-selection, and display sleep with idle-inhibit** (user chose display sleep in undertow over protocols-only): the displays sleep after energy.ini's `display_sleep_minutes` without input and wake on the next, clients get the 1 Hz clock meanwhile; an inhibitor on a visible surface holds them; ext-idle-notify-v1 shares the same activity and inhibition, for Phase 16 (`live-idle.sh`) | M | | done, both platforms |
| ~~U.3b~~ | ✅ **2026-09-29. Explicit sync** (`linux-drm-syncobj-v1`): offered where the renderer and backend take timelines; the scene draws each texture behind its acquire point, and every new buffer's release point is armed; vkcube runs on the AMD iGPU and the NVIDIA card (`live-syncobj.sh`). drm-kmod's support is still unverified, and will be checked on the metal box (PHASE4 §6.8) | M | | done on Linux; FreeBSD offers it only if drm-kmod does |
| ~~U.10~~ | ✅ **2026-09-29. `wl_surface.enter`/`leave`** — every visible surface tree is told the outputs its rectangle overlaps, each loop iteration, changes only; a window dragged onto a scale-2 display redraws at 2x and back (`live-surface-enter.sh`) | S | | done, both platforms |
| ~~P10.8~~ | ✅ **2026-09-29. Submenus open**: on hover, or → / Return on the row; ← and Escape close them, and a chain closes children first; nested popups placed in their root's coordinates in undertow. A GTK app's File ▸ Export ▸ More ▸ (`live-submenus.sh`) and kcalc's Constants ▸ Mathematics ▸ Pi (`live-menus-qt.sh` claim 5) | S–M | | done, both platforms |
| ~~P10.9~~ | ✅ **2026-09-29. The bar follows a GTK or Qt application's menus changing under it**: the bridge watches `org.gtk.Menus.Changed` (holding a `Start` on every group, without which GTK sends nothing) and dbusmenu's `LayoutUpdated`/`ItemsPropertiesUpdated`, coalesces them, re-reads, and pushes MenuWire `changed` only when the model differs; the bar subscribes for every application. kcalc's Constants and gtkmenu's Tools appear with no focus change (`live-menus-qt.sh`, `live-menus-gtk.sh`) | S–M | | done, both platforms |
| ~~T.1~~ | ✅ **2026-09-29. The installer shows layout names**: Jaguar's ("U.S.", "British", "Dvorak"…) on the Keyboard page and the hub, from a `name` on each offered `Keymap`; rc.conf still gets the file. A hand-written keymap the installer does not offer is shown by its file. Three goldens moved on purpose (hub, empty hub, keyboard) on both platforms | S | | done, both platforms |
| ~~T.2~~ | ✅ **2026-09-29. The live installer applies the layout it was given**: choosing one on the Keyboard page makes it the session's (`keyboard.ini`), and undertow puts it on every keyboard with no keymap of its own at once; rc.conf still gets the file for the installed system. Verified with a stand-in hardware keyboard: German turns the keys y-e-b-r-a from "yebra" into "zebra" (`live-installer-keyboard.sh`) | S | | done, both platforms |
| ~~T.3~~ | ✅ **2026-09-29. The toolkit binds xdg-shell v6**: a suspended window draws and commits nothing (a redraw waits, and happens once on resume); `wm_capabilities` recorded, and minimise/zoom not asked of a compositor that does not serve them; `configure_bounds` kept to (undertow now sends the usable area). undertow counts buffers from hidden windows (`live-suspend.sh`) | S | | done, both platforms |

Later, when something asks (xdg-output landed with P14.7): pointer-gestures, tablet-v2,
xdg-toplevel-icon (the Dock would use it), color-management-v1, and fifo /
commit-timing (no helper in wlroots 0.19 — after a wlroots bump). The toolkit's
`poll()` loop → `kqueue` (API-STUDY §3) belongs with any port of the study's
toolkit shim, and not before U.3–U.4.

---

### Toolchain ([SWIFT-6.4.md](SWIFT-6.4.md))

| # | Item | Size | Why |
|---|---|---|---|
| ~~S.0~~ | ✅ **2026-09-30. Swift 6.3.3 on both platforms** — Linux via `swiftly`, pinned by `desktop/.swift-version`; the guest's `swift6` from ports *latest* ahead of 2026Q4 (SWIFT-ON-FREEBSD). Unit tests and both golden gates green; the long lanes skipped by the user's call (a patch release) | S | done, both platforms |
| ~~S.1~~ | ✅ **2026-09-30. The `aw_*` shims retired** — 95 wrappers and `cwayland_shim.c` gone; Swift calls libwayland's requests directly; binds through `wlBind` and `*_iface` pointers, because a release build passes a *copy* of a C global (HANDOFF §2.93) | M | ~95 wrappers and ~680 lines of C gone; adding a protocol stops needing hand-written wrappers |
| ~~S.2~~ | ✅ **2026-09-28. `undertow`'s keybind spawn is async-signal-safe** — the new dependency-free `Spawn` target (`de/spawn`): resolve and allocate in the parent, only `fork`/`setsid`/`execve`/`_exit` in the child (HANDOFF §2.25) | S | done, both platforms |
| ~~S.3~~ | ✅ **2026-09-28. One spawn helper** — `Spawn.run` (posix_spawn, one poll loop, drain past the limit, SIGPIPE blocked) and `Spawn.detached` with an environment; the installer's runner and probe, `fathom`, `abyss-dbus` and `Launcher` moved onto it; one `resolveExecutable`, one `withCStrings` (HANDOFF §2.25) | S–M | done, both platforms; `live-install.sh` green on 782c198 — the new runner ran all 39 install steps as root and the result booted |
| S.4 | `InlineArray` for the scene's columns and the flight recorder — **only with bench numbers before and after** | S | safety and less code, not speed |
| S.5 | `Span`/`RawSpan` in the wire parsers | M | bounds safety without copies |
| S.6 | **Swift 6.4** — blocked until FreeBSD ports has it; first fix the font/theme search paths under Swift Build and decide the guest's build system (SWIFT-6.4 §4.2, §5) | M | the bump itself |

S.2 is a bug and belongs early; S.0 whenever the quarterly lands; S.1 is worth
doing before Phase 15 adds protocols; S.4–S.5 are opportunistic.

## 3. The metal sitting — blocked while the USB is in use

One developer medium (`live-image.sh --ssh-key`), one boot, all of it:

1. **Typing works**, and the console's `undertow: keyboard:` line names the
   layout (HANDOFF §2.70). Nothing on metal has ever typed.
2. **P4.5's margin breakdown** — `abyss/mk/metal.sh report`. The hypothesis to
   be proved wrong: the display commit dominates. Then `rtprio`, then the
   margin ceiling (HANDOFF §5 item 2).
3. **A GPU client under `undertow`** — U.3 is done: run `abyss/tests/live-gpu.sh`
   on the machine (it needs `es2gears_wayland` and `vkcube`). The first time the
   RX 6750 XT renders a client rather than only the compositor, on drm-kmod.
4. **Two one-minute checks:** `vulkaninfo` for `VK_EXT_external_memory_host`
   (probably absent — linuxkpi's MMU notifier is empty), and whether the
   12700KF's P/E cores are visible from userland (they should not be).
5. **The Wi-Fi question** (PHASE14 §6.5) answers itself on that boot.
6. **Presentation feedback on a real display**: headless reports `refresh 0`
   and no flags, honestly; under DRM a client should see the mode's refresh and
   `HW_CLOCK`/`VSYNC` (HANDOFF §2.74). The `present` client from
   `live-present.sh`, run against the metal session, says which.
7. **P4.5's second row** is still owed — the Mac Pro or a constrained run on
   this machine (PHASE4 §6.7). Not this sitting unless it is cheap.

---

## 4. Decisions only you can make

| Where | Question |
|---|---|
| here, §1 | **U.1–U.4 before P14.2?** Recommended; P14.2 first costs nothing but leaves the metal sitting with less to test |
| PHASE11 §6 | the menu-bar rule and layer 5; refuse/warn; icons as data; `calc()` operands — adopted in practice, never confirmed |
| PHASE14 §6.5 | does the 12700KF have a Wi-Fi card? (§3 can answer it) |
| PHASE14 §6.6 | per-application volume: after the spike, route (a) a small kernel patch or (b) a `virtual_oss` node per application (API-STUDY §3) |

---

## 5. Standing items, none blocking

From HANDOFF §5.3, still true:

- **No login window** — Phase 16's; wrong only for a machine with two users.
- **The live medium's root is read-write** — fix before a stick goes to anyone.
- **A real Aqua save panel** — a name field and New Folder, replacing ⌘S-into-
  the-folder-on-screen (PHASE7 P7.2).
- **A confirmation sheet for Empty Trash**, once a layer surface can host one.
- **Dragging desktop icons** — shell work, not compositor work.
- **One dialog at a time** in `abyss-portal` (PHASE8 §6.7).
- **`wlr-data-control`** (PHASE9 §6.7) — when `abyssclip` wants it.

*Done and dropped from the list:* golden-image tests (Phase 11's gate, 70 scenes
per platform).

## 6. For the FreeBSD fork, not this tree

What the review found belongs in the kernel (API-STUDY §3–§4). None is
scheduled; each is small and self-contained:

- a `dev.cpu.N` **core-type sysctl**, so nothing has to probe for P- and E-cores;
- a **per-channel volume ioctl** for `sndstat`, if P14.6 chooses route (a);
- `allow.rtprio`, already planned, and a **real-time CPU budget** to go with
  it — FreeBSD has no `RLIMIT_RTTIME` (Phase 18).
