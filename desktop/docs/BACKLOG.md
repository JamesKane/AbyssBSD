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
| U.1 | **Subsurfaces drawn, framed and hit-tested.** `undertow` advertises `wl_subcompositor` and never draws one (API-STUDY §1.3) | M | §2.58 exactly; Firefox's page lives in one; every foreign-app test after this inherits it | a live client with a subsurface, asserted in pixels; break it and watch the test fail |
| U.2 | **A minimised window keeps a clock.** Throttle its frame callbacks (~1 Hz) instead of withholding them; xdg-shell v3 → v6 for `suspended` and `wm_capabilities` (§1.4) | S | a FIFO client minimised today blocks for ever; small, and the same file as U.3's timestamps | a client that minimises and counts callbacks; headless |
| U.3 | **`linux-dmabuf`** (+ `linux-drm-syncobj` if the renderer offers it) (§1.2). **Spike first:** does nested `undertow` on the dev box get a GLES2 renderer? If yes, a GL client proves it here | M | no GPU client uses the GPU without it; done now, the next metal sitting tests it instead of discovering it | nested on Linux with an EGL client; headless and the guest must still fall back to shm cleanly |
| U.4 | **presentation-time, and honest frame-done timestamps** — the time the frame was shown, which `Metronome` already has (F-101) | S–M | cheap once U.2 is in that code; gives P4.5's metal sitting a client-side view too | a client reads feedback; headless timestamps match the recorder |
| P14.2 | **Appearance, and a live theme switch** (PHASE14) — was next | M | unchanged from PHASE14 | pixels after the switch; a GTK app sees `color-scheme` change |
| P14.3 | **`abyss-settings`**, the privileged half | M | every pane after it writes through it | `abyss-settingsctl` plans; refuses on Linux |
| P14.4 | **Network, wired** | M | | nested bhyve: set, reboot, held |
| P14.6 | **Sound.** Run §4.3's spike first; it now starts from API-STUDY §3's answer (reading per-channel volume works, setting does not) and chooses a route | M | the spike decides whether the pane promises per-app volume | `snd_dummy` in the guest |
| P14.7 | **Displays** — `wlr-output-management-v1` | M | the one pane with no FreeBSD-only half | multiple headless outputs, both platforms |
| P14.8 | **Energy** | S | deliberately thin; suspend is Phase 16's | |
| P14.5 | **Network, Wi-Fi** — last in the phase because it waits on the `wtap` spike and on §4.1's question | M | | harness if `wtap` associates, else metal (§3) |
| P14.9 | **The phase gate** — both `--live` lanes and `--full` | S | | |

---

## 2. Next — what Phase 15's applications need from the compositor

After Phase 14, before Phase 15 starts. Ranked by what breaks without it
(API-STUDY §2); each costs "create the global" **plus** "teach our scene what it
means" (§1.5 there).

| # | Item | Size | Missing means |
|---|---|---|---|
| U.5 | **text-input-v3 + input-method-v2** | L | no input method, so no CJK |
| U.6 | **pointer-constraints + relative-pointer** | M | games and Blender cannot lock the pointer |
| U.7 | **cursor-shape-v1**, with a real cursor theme (today a rectangle) | M | every client draws its own cursor |
| U.8 | **viewporter** (a source crop in our scene), then **fractional-scale-v1** | M | wrong video and scaled surfaces; guessed scale |
| U.9 | **primary-selection, idle-inhibit** | S each | middle-click paste; a video cannot stop the screen blanking |
| P10.8 | **Submenus open.** They draw their ▸ and have never opened (PHASE10) | S–M | every real application's menus are one level deep |
| T.1 | **The installer shows layout names**, not file names (`us.dvorak.kbd` → "Dvorak") | S | cosmetic; moves one golden |
| T.2 | **The live installer applies the layout it was given** — today only the installed system gets it | S | typing an account password on a non-US keyboard, on the medium |

Later, when something asks: xdg-output, pointer-gestures, tablet-v2,
xdg-toplevel-icon (the Dock would use it), color-management-v1, and fifo /
commit-timing (no helper in wlroots 0.19 — after a wlroots bump). The toolkit's
`poll()` loop → `kqueue` (API-STUDY §3) belongs with any port of the study's
toolkit shim, and not before U.3–U.4.

---

## 3. The metal sitting — blocked while the USB is in use

One developer medium (`live-image.sh --ssh-key`), one boot, all of it:

1. **Typing works**, and the console's `undertow: keyboard:` line names the
   layout (HANDOFF §2.70). Nothing on metal has ever typed.
2. **P4.5's margin breakdown** — `abyss/mk/metal.sh report`. The hypothesis to
   be proved wrong: the display commit dominates. Then `rtprio`, then the
   margin ceiling (HANDOFF §5 item 2).
3. **A GPU client under `undertow`**, if U.3 is done — the first time the RX
   6750 XT renders a client rather than only the compositor.
4. **Two one-minute checks:** `vulkaninfo` for `VK_EXT_external_memory_host`
   (probably absent — linuxkpi's MMU notifier is empty), and whether the
   12700KF's P/E cores are visible from userland (they should not be).
5. **The Wi-Fi question** (PHASE14 §6.5) answers itself on that boot.
6. **P4.5's second row** is still owed — the Mac Pro or a constrained run on
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
