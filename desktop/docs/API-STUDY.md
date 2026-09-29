# The NeoDarwin platform API study, read from FreeBSD

_2026-09-28. A review of `~/Projects/OS/NeoDarwin-api-study` (at `77e9b08`) and of
the digest written from it for us, `~/Projects/OS/AbyssBSD-api-learnings/LEARNINGS.md`.
FreeBSD facts are from `~/Projects/OS/freebsd-src` at `c263dd413ca`
(`__FreeBSD_version` 1600019, a shallow clone of main — **not** the `050683bb8e1`
/ 1600026 the digest cites, which is not in our tree)._

**What the study is.** A reading of 44 pinned open-source applications (game
engines, emulators, browsers, toolkits), 20 API specs and 25 heritage systems, for
NeoDarwin, done on a macOS host. It asks where applications converge and where
they fight the platform, and records each fight as a friction entry
(`friction/F-nnn`). The digest re-reads that for a BSD desktop and proposes a
shared application surface between NeoDarwin and us.

**How this was reviewed.** Four readers in parallel (method; loop, time, audio
and I/O; windows and input; GPU and the prototypes), each checking the study's
claims against `freebsd-src` and against what the corpus projects' own FreeBSD
code paths do, then a pass over our own tree. **Everything here is a source
read unless it says it was run.** The one thing that was run is §1.1's fix.

**The short of it.** The study's direction survives a FreeBSD reading. Several of
its FreeBSD facts do not (§4), three of its headline numbers were never measured,
and — the part that matters to us — holding its friction list up against
`undertow` found **four defects in our compositor**, one of which would have made
the metal box's keyboard type nothing.

---

## 1. What it found in our tree

### 1.1 Fixed: a hardware keyboard reached clients with no keymap

`Seat.attach(device:)` passed a backend keyboard to the seat as it arrived, and a
libinput keyboard arrives with **no keymap**. The seat then tells clients
nothing: keycodes reach them with no way to read them, and `intercept` finds no
keysyms, so no keybind fires either. Every keyboard the harness has ever used is
a virtual one, which brings its own keymap from the client that made it — so no
test could see this, and the first real keyboard would have been the 12700KF's.

Fixed 2026-09-28 (`Seat.giveKeymap`): a keyboard with no keymap is given
xkbcommon's default, which reads `XKB_DEFAULT_LAYOUT` and friends from the
environment, and a repeat rate of 25/600; one that brought a keymap keeps it.
Three unit tests build a bare `wlr_keyboard` the way a backend does and assert on
the keymap, the state, the repeat and the layout. HANDOFF §2.70.

**Then the layout, the same day.** The installer writes `keymap="uk.kbd"` to
rc.conf — a `kbdmap` name, not an XKB one — and `undertow` now reads and
translates it (`Install.Keymaps`), so the desktop types what the console types.
Doing so found two of the installer's eight names were files FreeBSD does not
ship (HANDOFF §2.70).

### 1.2 Fixed (U.3): `undertow` offered no `linux-dmabuf`

`undertow` creates `wl_shm` and nothing else for buffers (`Compositor.swift:376`).
Mesa's Wayland code on this box (`libEGL_mesa`, `libvulkan_radeon`) names
`zwp_linux_dmabuf_v1` and not the older `wl_drm`. So on the RX 6750 XT a GL
client most likely falls back to software and a Vulkan client most likely fails
to present — **inferred from the libraries' strings, not run**. The study counts
six clients that bind it directly; the real number is every client that renders
through Mesa. PLAN's Phase 4 already lists "dmabuf + explicit-sync"; this says it
is not optional. wlroots 0.19: `wlr_linux_dmabuf_v1_create_with_renderer`, and
`wlr_linux_drm_syncobj_manager_v1_create` for explicit sync (whether drm-kmod
wires syncobj eventfd is unverified).

**Measured, then fixed, 2026-09-28** (HANDOFF §2.73). On the dev box's AMD iGPU —
RADV and radeonsi, the RX 6750 XT's driver family — the inference was right:
with `wl_shm` alone, `vkcube` segfaulted and `es2gears` fell back to software.
`linux-dmabuf` is now created from the renderer, and `live-gpu.sh` runs both on
the AMD node under our compositor. Explicit sync is not offered yet (U.3b).
Metal still has to confirm it on FreeBSD's drm-kmod.

### 1.3 Fixed (U.1): subsurfaces were advertised and never drawn

`wlr_subcompositor_create` is called (`Compositor.swift:367`) and nothing in
`de/undertow` touches a subsurface: none is drawn, and none is sent frame-done.
Eleven corpus projects create subsurfaces, and Firefox puts its web content in
one (`firefox/widget/gtk/WaylandSurface.cpp:449`), so under `undertow` it would
draw its chrome and no page, or hang waiting for a callback. **§2.58 exactly** —
a global with nothing behind it — in the one place §2.58's own rule ("name the
object a client receives through each global") was not yet applied.

Fixed 2026-09-28: the scene, frame-done and the hit-test walk each root's tree,
and `live-subsurface.sh` proves drawing, frame callbacks and pointer routing
separately, on both platforms (HANDOFF §2.71).

### 1.4 Fixed (U.2): a minimised window's frame clock stopped

`sendFrameDone` walks `mappedToplevels`, which excludes minimised windows
(`Compositor.swift:925`). A client in Mesa's FIFO mode blocks for ever on the
callback it never gets — the stall the study found independently in SDL, Blender
and zed (F-102, F-209). The fix is a throttled clock (about 1 Hz) rather than a
withheld one, and `xdg_toplevel.suspended` once xdg-shell is past **v3**, which is
what we create (`Compositor.swift:378`; `suspended` is v6).

Fixed 2026-09-28: one callback a second while minimised, xdg-shell v6 with
`suspended`, and `wm_capabilities` set to what `undertow` serves
(`live-hidden.sh`, HANDOFF §2.72).

Also: the frame-done timestamp is `clock_gettime` at send, not the time the frame
was presented. That is what the core protocol asks of a frame callback; the
time of presentation now goes where it belongs, `wp_presentation` (U.4,
HANDOFF §2.74).

### 1.5 Structural: every protocol costs twice

`undertow` draws with its own scene, not `wlr_scene`, which is why it can be
measured the way PHASE6 does. The price shows here: `wlr_scene` would do
viewporter cropping, presentation feedback, fractional-scale notification and
output enter/leave by itself. Ours sets only a destination box
(`Scene.swift:156`), so each protocol below is "create the global" **plus** "teach
our scene what it means". The table's costs assume that.

---

## 2. The protocols applications expect, as a work list for `undertow`

The digest's "core+" list, re-ranked by **what breaks when it is missing**
rather than by how many clients bind it. Client counts are the study's (of its 14
Wayland clients); a reader's own count agreed within ±1 for 11 of 19 and within
±3 for all. Every row but the last has a wlroots 0.19 helper.

| Protocol | Clients | Have | Missing means | Rank |
|---|---|---|---|---|
| linux-dmabuf-v1 | 6 + all of Mesa | no | GPU clients do not use the GPU (§1.2) | **P0** |
| (subsurfaces) | 11 | **yes** (U.1) | Firefox's page was not drawn (§1.3) | done |
| xdg-activation-v1 | 11 | yes | — | done |
| xdg-decoration | 10 | yes (server-side) | — | done |
| presentation-time | 3 | **yes** (U.4) | toolkits estimated present times (F-101) | done |
| text-input-v3 + input-method-v2 | 9 | **yes** (U.5) | there was no input method, so no CJK | done |
| relative-pointer, pointer-constraints | 9, 9 | **yes** (U.6) | games and Blender could not lock the pointer | done |
| cursor-shape-v1 | 10 | **yes** (U.7) | clients drew their own cursor, and ours was a rectangle | done, with the theme's cursors |
| viewporter | 10 | **yes** (U.8) | video and scaled surfaces were wrong; the scene now crops (and turns) | done |
| fractional-scale-v1 | 12 | **yes** (U.8) | clients guessed their scale | done, with wl_surface v6 preferred_buffer_scale |
| primary-selection | 8 | no | middle-click paste | P1, cheap |
| idle-inhibit | 7 | no | video players cannot stop the screen blanking (Phase 16) | P1, cheap |
| xdg-output | 7 | no | mostly covered by `wl_output` v4 | P2 |
| pointer-gestures, tablet-v2 | 9, 9 | no | no pinch or pen | P2 |
| xdg-toplevel-icon | 8 | no | the Dock guesses icons | P2 |
| color-management-v1 | 8 | no | no HDR or wide gamut | P3 |
| fifo, commit-timing | 2, 1 | no | — (no helper in wlroots 0.19) | P2, after a wlroots bump |

**No XWayland** (PHASE9 §6.3) takes four corpus projects off the table outright
(JUCE, sokol, ogre-next and Dolphin are X11-only).

---

## 3. What it gives the phases

**Phase 4, metal.**
- §1.1–1.4 are metal defects wearing nested clothes: the harness types through
  virtual keyboards, draws with shm and never minimises a FIFO client.
- `VK_EXT_external_memory_host` is probably broken on FreeBSD: radv implements
  it with amdgpu userptr, which needs MMU notifiers, and linuxkpi's is an empty
  struct (`sys/compat/linuxkpi/common/include/linux/mmu_notifier.h`). One
  `vulkaninfo` on the 6750 XT settles it.
- The kernel side of the GPU stack is drm-kmod tracking **Linux 6.6 DRM**;
  dma-buf, fences and syncobj live there, not in base. "Done by drm-kmod + Mesa"
  holds for RDNA 2 and is where anything newer will break.
- **The 12700KF is a hybrid CPU and ULE does not know it.** The kernel reads the
  core type (`sys/amd64/amd64/initcpu.c`) for its own workarounds and exports
  nothing; a `dev.cpu.N` core-type sysctl is the smallest useful step (F-204).

**Phase 14, Sound.** Per-application volume, PHASE14 §4.3's open question, has
an answer from source, not yet from a run:
- **Reading is possible, setting is not.** `sndstat`'s nvlist reports each
  channel's pid, command and volume; `SNDCTL_DSP_SETPLAYVOL` sets only the
  caller's own channel, and the `vpc` sysctls act on all of them.
- **Route (a): a fork patch** — an ioctl that sets a channel's volume by (unit,
  channel), with an ownership check. Small, and `/dev/dsp` stays as it is.
- **Route (b): one `virtual_oss` node per application or jail.** `virtual_oss`
  is in base in our tree (`usr.sbin/virtual_oss`, and UPDATING 20251002 moves it
  into the FreeBSD-sound package); whether 15.0-RELEASE ships it is unverified.
  It also switches its backing device at runtime, which is default-device
  following with applications unchanged — and it fits Phase 18's jails.
- **Not a PulseAudio-style server.** vchans already mix in the kernel; a server
  that mixes again is a second authority, not a first.
- **OSS under-reports latency.** `GETODELAY` counts the application channel's
  buffer and not the vchan parent's, and SDL3's OSS backend sleeps 10 ms whenever
  it is short. Real-time audio at small periods will look worse here than the
  study's macOS numbers; measure before promising.

**Phase 15, applications.** §2's P0 and P1 rows are what "an application runs
under `undertow`" costs beyond Phases 9 and 10. Firefox is the forcing case
(subsurfaces, dmabuf), and it is PLAN's fallback browser.

**Phase 18, confinement.** FreeBSD has more of this than PLAN assumes:
- `EVFILT_JAILDESC` (`sys/sys/event.h:49`) lets a supervisor wait on a jail's
  life in the same `kevent` as everything else; `pdfork` + `EVFILT_PROCDESC` do
  the same for processes.
- rctl's `memorylocked` is the per-jail wired-memory budget the study wishes for,
  but `GENERIC` ships `RACCT_DEFAULT_TO_DISABLED` (`kern.racct.enable=1` needed).
- `mac_priority(4)` **cannot** grant real-time inside a jail:
  `prison_priv_check()` runs before `mac_priv_grant()` (`kern_priv.c:174`) and
  `kern_jail.c` does not allow `PRIV_SCHED_RTPRIO`. That is `allow.rtprio`'s
  reason to exist. Outside jails it works today, with no patch.
- There is **no `RLIMIT_RTTIME`**: a real-time thread that spins has no watchdog.
  The study's "per-user budget with an admission test" is a kernel gap, not a
  policy knob.

**The toolkit loop.** `de/surface` waits in `poll()` with key repeat as its only
deadline. Moving to `kqueue` is what the study's one-wait design means here, and
two FreeBSD rules come with it: a deadline goes in an `EVFILT_TIMER`, never in
`kevent`'s timeout (which the kernel coalesces, by up to 5% by default); and
`NOTE_ABSTIME` takes a **wall-clock** time (`kern_event.c:920` subtracts boot
time once, at attach), so a monotonic deadline is a relative timer or
`clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME)`.

**The shared toolkit.** Porting the study's toolkit shim to FreeBSD + Wayland is
about 1.5–2k new lines, reusing `de/surface`, `cxkb` and our text stack. It is
worth doing only after §1.2–1.4 and presentation-time; before that three of its
five programs run. What it would measure that nothing here does: a client's
end-to-end pacing, OSS latency under UI load, and a client's idle wakeups.

---

## 4. Corrections to the digest, for whoever owns it

| Digest says | Source says |
|---|---|
| "28 of 37 corpus projects ran (32 with Xwayland)" | Nothing was run: a hand-written path table and a SQL rule (`reports/queries/q5.sql`). For us, 28 at most, and that counts Chromium and Firefox, which still need OS ports. |
| `EVFILT_TIMER` + `NOTE_ABSTIME` as the deadline primitive | A wall-clock deadline, converted once (above). |
| Reserve with `MAP_GUARD`, place with `MAP_FIXED \| MAP_EXCL` | A guard is a map entry, and `MAP_EXCL` refuses an occupied range (`vm_map.c:1993`). Place with plain `MAP_FIXED` over the guard; return a range with `MAP_GUARD \| MAP_FIXED`. |
| `security.mac_priority.realtime_gid` | `security.mac.priority.realtime_gid`, and not inside a jail (above). |
| Kernel drivers `ps5dsense`, `hidwacom` | Neither exists in `sys/dev/hid`. Nor do Xbox One/Series pads, and evdev does not support `EV_FF`, so no rumble (`sys/dev/evdev/cdev.c:712`). |
| "Mesa's `VK_EXT_external_memory_host`" | Probably not on FreeBSD (§3). |
| "Vulkan: done by drm-kmod + Mesa" | For RDNA 2; drm-kmod is Linux 6.6 DRM. |
| "A text editor with IME was 44 lines against 365" | 44 lines on a 1,163-line toolkit with a text field, against SDL3 building its own; a widget toolkit against a library. |
| "12 calls … against 11 for SDL3" | Presented as a win; SDL3 needed fewer. The game loop was 36 calls to SDL3's 18 with `webgpu.h` setup counted. |
| "Being Linux-like buys reach" | "Freedesktop-stack-like": the study has no FreeBSD platform table and never counted BSD guards. A count: `__FreeBSD__` 190 against `__linux__` 370, with real FreeBSD paths in Wine, Dolphin, rpcs3, Godot and SDL. It transfers; it was not shown. |
| "In main: `eventfd`, `timerfd`, `memfd_create`, `inotify`" | All four are in 15.0 (symbol set `FBSD_1.8` or earlier), which is what we ship. `inotify` differs from Linux on hard links. |
| §6: whether `mac_priority` should apply in jails is policy | It cannot, without a kernel change. |
| §6: `allow.mlock` for `mlock` in jails | Right: the jail check runs before `unprivileged_mlock` (`kern_priv.c`), so without it even a small lock is refused. |

**What holds.** One wait for everything; Vulkan as the one GPU API and Metal as
no reach at all; server-side decorations by default; styling owned by the theme;
the core+ list as a list; the wgpu-native storage patch, which is
backend-generic and matters on Vulkan too.

---

## 5. Not verified

- Mesa's behaviour with no `linux-dmabuf` (§1.2): inferred from strings.
- drm-kmod: syncobj eventfd, amdkfd, userptr — its source is not in our tree.
- Whether `virtual_oss` and `sndstat`'s per-channel keys shipped in 15.0; the
  build VM was down and a boot is a quarter of an hour.
- The vchan wake period and `GETODELAY` under-report: read, not measured.
- Whether swift6 6.3.2 on FreeBSD accepts the study toolkit's `@_noLocks` and
  `Span` features.
- §1.1's fix on metal. Its unit tests are green on Linux and in the FreeBSD
  guest (`run.sh --vm`, 2026-09-28); nobody has typed on the 12700KF yet.
