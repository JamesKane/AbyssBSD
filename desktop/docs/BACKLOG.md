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
| U.7b | **Our cursors as an XCursor theme**, installed and named in `XCURSOR_THEME`, for clients that draw their own (GTK 3, SDL, Xwayland: libwayland-cursor) | S | those draw Adwaita's arrow over our windows, not Jaguar's |
| ~~U.8~~ | ✅ **2026-09-29. viewporter, buffer transforms, fractional-scale-v1**: the scene draws each buffer's source box, turned by its transform; each surface tree is told the largest scale of the displays it is on, fractionally and as wl_surface v6's integer; a 1.5x client reaches a 1.5 display pixel for pixel (`live-viewport.sh`) | M | | done, both platforms |
| U.9 | **primary-selection, idle-inhibit** | S each | middle-click paste; a video cannot stop the screen blanking |
| U.3b | **Explicit sync** (`linux-drm-syncobj-v1`): the scene waits on each buffer's acquire point and signals its release (HANDOFF §2.73) | M | only implicit sync today — fine for radeonsi/radv, not for NVIDIA's driver; and drm-kmod's syncobj support is unverified |
| ~~U.10~~ | ✅ **2026-09-29. `wl_surface.enter`/`leave`** — every visible surface tree is told the outputs its rectangle overlaps, each loop iteration, changes only; a window dragged onto a scale-2 display redraws at 2x and back (`live-surface-enter.sh`) | S | | done, both platforms |
| P10.8 | **Submenus open.** They draw their ▸ and have never opened (PHASE10) | S–M | every real application's menus are one level deep |
| T.1 | **The installer shows layout names**, not file names (`us.dvorak.kbd` → "Dvorak") | S | cosmetic; moves one golden |
| T.2 | **The live installer applies the layout it was given** — today only the installed system gets it | S | typing an account password on a non-US keyboard, on the medium |
| T.3 | **The toolkit binds xdg-shell v6** and stops drawing while `suspended` (and handles `wm_capabilities`, `configure_bounds`) — it binds v2 today (HANDOFF §2.72) | S | a minimised Aqua window still draws at 1 Hz for nobody |

Later, when something asks (xdg-output landed with P14.7): pointer-gestures, tablet-v2,
xdg-toplevel-icon (the Dock would use it), color-management-v1, and fifo /
commit-timing (no helper in wlroots 0.19 — after a wlroots bump). The toolkit's
`poll()` loop → `kqueue` (API-STUDY §3) belongs with any port of the study's
toolkit shim, and not before U.3–U.4.

---

### Toolchain ([SWIFT-6.4.md](SWIFT-6.4.md))

| # | Item | Size | Why |
|---|---|---|---|
| S.0 | **Swift 6.3.3 on both platforms** — Linux via `swiftly`; the guest from the 2026Q4 quarterly | S | the rehearsal for 6.4 on a version both sides can run; `--full`, since the medium ships the runtime |
| S.1 | **Retire the `aw_*` shims** — Swift calls `static inline` C directly (HANDOFF §2.1 corrected) | M | ~95 wrappers and ~680 lines of C gone; adding a protocol stops needing hand-written wrappers |
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
