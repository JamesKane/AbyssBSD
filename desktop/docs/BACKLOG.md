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
| ~~M.1~~ | ✅ **C2 on metal: undertow's part done** (HANDOFF §2.118, §2.119). *Present on damage*: a static screen draws nothing (`live-damage.sh`). Every stage of undertow's frame was traced on the 12700KF under the flood and is on time; the misses that remain (≈100 of 1800 with a drawing client) are flip completions the kernel delivers late, now §6's. Left here: recheck undertow's `wake-late-p99` statistic, which the traces do not reproduce | M | | `metal-bench.sh c2` once §6's driver item is fixed |
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
| ~~P14.8b~~ | ✅ **2026-09-30. Energy Saver: power mode** — Power Saver / Balanced / Performance through `abyss-settings` (a `power-profile` plan: `sysrc power_profile=…`, `powerd_flags` cleared so the profile chooses powerd's mode, `service power_profile start`); where the base has profiles the row replaces powerd's per-source modes, and powerd turned on runs without flags. Upstream FreeBSD has only the old AC-line script: the page falls back and the helper refuses an apply, in words. `live-energy-pane.sh` §5 (the AbyssBSD base's defaults stood in by the scratch rc.conf; the service start itself is the fork's half, untested on this guest) | S | | done, both platforms |

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

## 3. The metal sitting — 2026-09-30, most of it done

One developer medium (`live-image.sh --ssh-key --frames 0`), updated in place
with `abyss/mk/metal.sh push` (PHASE4 §5.11–§5.13):

1. ~~**Typing works**~~ ✅ — after two fixes: `hms` for the USB mouse, and
   `undertow` adopting the input devices present at start (it dropped them).
2. ~~**P4.5's margin breakdown**~~ ✅ — **C1 holds: 0 of 1800 missed at a ~2 ms
   margin.** Five fixes, all measured on metal (§5.12–§5.13). `rtprio` via
   `mac_priority` is in and made no difference on an idle machine.
3. ~~**A GPU client under `undertow`**~~ ✅ — Vulkan: `vkcube` on RADV, 600
   frames at 60 Hz; GL: `abyss/tests/glclient.c` (FreeBSD's `mesa-demos` has no
   Wayland gears) on `radeonsi, navi22, ACO`, 600 frames in 10 006 ms.
4. ~~**Two one-minute checks**~~ ✅ — `VK_EXT_external_memory_host` is
   **present**; P/E cores visible only as cache topology.
5. ~~**The Wi-Fi question**~~ ✅ — no wireless device on this machine.
6. ~~**Presentation feedback on a real display**~~ ✅ — refresh is the mode's,
   flags VSYNC|HW_CLOCK|HW_COMPLETION; the sequence counter is 0 (not passed
   through by FreeBSD's DRM).
7. **P4.5's second row** is still owed (PHASE4 §6.7).
8. **New:** ~~the medium's UFS had no soft updates~~ (on now, and developer
   media grow to fill the stick at boot); an installed system sets no
   `kld_list` or `video` group (PHASE4 §6.10, §6.11) — fix with an install on
   metal.

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

- **A desktop picture per island** (PHASE13 P13.7, deferred). The picture is
  drawn by the desktop process, an ordinary client that cannot know which
  island is showing. It needs that told to it: a small protocol, or a desktop
  on the privileged socket. Island names are edited in `islands.ini` until
  the pane grows a text list.

- **No login window** — Phase 16's; wrong only for a machine with two users.
- **The live medium's root is read-write** — fix before a stick goes to anyone.
- **A real Aqua save panel** — a name field and New Folder, replacing ⌘S-into-
  the-folder-on-screen (PHASE7 P7.2).
- **A confirmation sheet for Empty Trash**, once a layer surface can host one.
- **Dragging desktop icons** — shell work, not compositor work.
- **One dialog at a time** in `abyss-portal` (PHASE8 §6.7).
- **`wlr-data-control`** (PHASE9 §6.7) — when `abyssclip` wants it.
- ~~**The installer's disk probe fails on a machine without ZFS**~~ ✅ fixed
  2026-10-01: the probe asks `kldstat -q -m zfs` first, and no ZFS means no
  imported pools (`importedPoolNames`, unit-tested both ways); with ZFS present
  a failing `zpool list` still fails the probe. (Found 2026-10-01 on the Q8B,
  UFS root.) `probeMachine()` runs `zpool list -H -o
  name`, which tries to load `zfs.ko`; for a non-root caller that fails with
  "Failed to load zfs module: Operation not permitted", and the probe
  throws. `InstallRunTests.testTheProbeRefusesLoudlyWhereItCannotWork`
  fails there. No ZFS module (`kldstat -q -m zfs` false, or a load failure)
  should mean "no pools", not a failed probe.

- ~~**`fathom` on arm64**~~ ✅ fixed 2026-10-01 (found the same day on the
  Q8B, [reports/q8b-bench-2026-10-01.md](reports/q8b-bench-2026-10-01.md)):
  - **Boot:** with no `machdep.bootmethod` (amd64 and i386 alone have it),
    arm64 reads as UEFI, since FreeBSD/arm64 starts only through `loader.efi`.
  - **Wi-Fi:** no `net.wlan.devices` *and* no `wlan` module
    (`kldstat -q -m wlan`) is "absent", since every radio driver needs `wlan`.
    With `wlan` loaded and no sysctl it stays unknown.
  - **`msm`** is now among the graphics modules, so the Q8B's report names its
    Adreno driver, not just `drm`. FathomTests cover all three.
- ~~**The Q8B missed 0–5 of 300 flips at 60 Hz**~~ ✅ fixed 2026-10-01 in
  the board's driver, not here: the vsync and GPU interrupts landed on
  powered-down cores, and the first present event carried a stale vblank;
  now 0 of 300 in five runs (same report). The 18–25 ms before `undertow`
  hears its first present event is its own start-up, if that's worth
  measuring.

*Done and dropped from the list:* golden-image tests (Phase 11's gate, 70 scenes
per platform).

## 6. For the FreeBSD fork, not this tree

What the review found belongs in the kernel (API-STUDY §3–§4). None is
scheduled; each is small and self-contained:

- a `dev.cpu.N` **core-type sysctl**, so nothing has to probe for P- and E-cores;
- a **devctl notify for the fixed-feature power button** (`acpi.c`'s
  `acpi_event_power_button_sleep`), as `acpi_button.c` already sends for a
  control-method one. Without it, the desktop's "Restart, Sleep, Cancel, Shut
  Down" can only be offered on machines whose button is a PNP0C0C device
  (PHASE16 P16.4b, HANDOFF §2.113). **Raised by the 12700KF** (§2.115): its
  board has both kinds and the case button is the fixed one, so on a typical
  desktop board the dialog is never offered;
- **amdgpu's page-flip news is late under load** (HANDOFF §2.119) — **this is
  C2 on metal now.** With twelve plain busy loops and no Wayland traffic, a
  real-time compositor that woke on time waited 294 ms once for a flip's
  completion. Under C2's flood of socket syscalls, ≈50 completions a run come
  more than half a period late, and ≈100 of 1800 frames are lost. undertow
  was traced on time at every stage. The path is amdgpu → LinuxKPI task
  queues at ordinary priority. Reproduce with `abyss/mk/metal-bench.sh c2`
  (and `--no-adversaries` plus spinners). **Ours, not the Mac Studio's**
  (2026-10-02): that machine works only on the Radxa board, so this amd64
  kernel item is the desktop side's to take on;
- **S3 resume on the 12700KF (MSI board, RX 6750 XT, igc0) leaves the machine
  dead** (HANDOFF §2.115). With no desktop running, `acpiconf -s 3` from a bare
  console suspends, and the wake brings the screen back, but the keyboard and
  `igc0` (no ARP) never return. Same with the desktop. 16-CURRENT
  `main-n289650`, stock GENERIC. The machine's own FreeBSD install is the
  control to try next. Until this is fixed, the desktop's Sleep cannot be
  checked on metal;
- a **per-channel volume ioctl** for `sndstat`, if P14.6 chooses route (a);
- `allow.rtprio`, already planned, and a **real-time CPU budget** to go with
  it — FreeBSD has no `RLIMIT_RTTIME` (Phase 18).
