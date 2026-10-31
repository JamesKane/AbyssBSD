# Phase 19 — play and broadcast: Wine, games and streaming, on Wayland only

_Scoped 2026-10-31, after two checks in the build guest (§1.1). PRODUCT's
audience was a person who lives in the desktop; this phase widens it to the
demo audience: developers, hackers, streamers, and gamers within limits._

**The goal:** a Windows program and a game run under `undertow` with nothing
in front of them but Wine's Wayland driver, and a streamer can capture the
desktop, its sound and their keys without leaving it.

**The rule this phase keeps: no XWayland** (PHASE9 §6.3, reaffirmed
2026-10-31: "XWayland is a performance nightmare"). Everything here is a
Wayland client. A person who needs an X11-only program can run rootful
`Xwayland` as an ordinary window themselves; that is theirs to install, and
`live-session.sh` still fails if `undertow` names an XWayland symbol. BACKLOG
T.5 (wlroots built without X11) stands.

**Needs:** 9 (the clipboard and the seat), 10 (the menu protocol, for the
foreign-application rows), 11 (decorations), 14 (Displays, Sound), 15
(appgen), 17 (an overlay that builds and publishes ports). Only 17 is open,
and only P19.1 and P19.6 need it.

---

## 1. Where it starts

| Have | Where | What it becomes |
|---|---|---|
| relative-pointer, pointer-constraints | `undertow` (U.6) | already enough for mouse-look |
| linux-dmabuf, explicit sync, presentation-time | `undertow` (U.3, U.4) | the GPU path a game's swapchain takes |
| `wlr-screencopy` | `undertow`, `abyssgrab` | what `wlrobs` captures through (P19.6) |
| `wlr-output-management` with adaptive sync | `abyss-sys` binds `set_adaptive_sync` | the Displays pane's variable-refresh switch (P19.4) |
| `security-context-v1` | `undertow` | how a privileged protocol is offered to some clients and not others (§6.2) |
| Server-side Aqua decorations | P9.5 | Wine windows, if Wine will ask (P19.3) |
| `abyss-appgen` | `.desktop` → `.app` | a `.exe` gets a bundle too (P19.2) |
| `abyss-dbus` | the bridge, PRODUCT §5.6 | answers the GlobalShortcuts portal (P19.7) |

### 1.1 What the checks found (2026-10-31)

In the FreeBSD 16 guest, headless `undertow`, `DISPLAY` unset, Wine 11.0 from
`pkg` (its WAYLAND option on), the prefix set to `Graphics=wayland`. Two
probes cross-built with `zig cc -target x86_64-windows-gnu`:

1. **Wine's Wayland driver works on `undertow`.** Notepad maps and draws; a
   WGL probe gets llvmpipe, GL 4.6, and presents 957 frames in 4 s; a D3D11
   probe gets feature level 11_0 through wined3d and presents 950. All three
   were grabbed with `abyssgrab` and look right.
2. **Only 64-bit Windows programs run.** FreeBSD's `wine` wrapper wants a
   separate 32-bit Wine from an i386 package set, and FreeBSD 16 has none;
   `wine64.bin` is the only way in, and Wine's own `syswow64\rundll32.exe`
   fails with `c0000135`. Most games and older programs are 32-bit.
3. **Wine asks for two protocols we lack:** `zwlr_data_control_manager_v1`
   ("clipboard functionality will be limited") and
   `xdg_toplevel_icon_manager_v1` ("window icons will not be supported").
4. **Wine draws its own Windows frame**, not the Aqua one.
5. **A fresh prefix stops on the "Wine Mono Installer" dialog**, and
   `timeout` does not stop Wine: its processes outlive the one it signals.
   `wineserver -k` does.
6. **`abyssgrab` failed once** ("the compositor could not copy that output")
   while wineboot's dialogs were up, and never again in later grabs.
   Unexplained.
7. **OBS could not be tried.** FreeBSD 15.1's repository has `obs-studio`
   32.2.2 (PIPEWIRE, WAYLAND on) and `wlrobs` 1.2; FreeBSD 16's has neither.

Not yet measured: anything on a real GPU. These are llvmpipe numbers in a VM.

---

## 2. The shape

```
 a .exe ──appgen──▶ Game.app ──▶ wine (WoW64, ours) ──winewayland──▶ undertow
                                        │                          │
                                  a prefix per app            tearing-control, VRR,
                                  under ~/Library/Wine        shortcuts-inhibit, icons,
                                                              data-control (granted)
 OBS (Qt, from our overlay) ──wlrobs──▶ wlr-screencopy ──▶ undertow
     │──GlobalShortcuts portal──▶ abyss-dbus (answers; never a bus)
     └──audio──▶ virtual_oss (BACKLOG §4's per-application route)
```

---

## 3. Ordered passes

Sizes: **S** a day or less, **M** a few days, **L** a week or more.

- **P19.0 — the probes become a live script (S).** `abyss/tests/wine/` holds
  the two probe sources; `live-wine.sh` builds them with `zig cc` (skips
  loudly without zig or Wine), makes a prefix with `WINEDLLOVERRIDES=
  "mscoree,mshtml="`, runs Notepad, WGL and D3D11 under headless `undertow`,
  asserts each maps and presents, grabs each, and ends with `wineserver -k`.
  Chase §1.1's grab failure here, with wineboot's dialogs up on purpose.
- **P19.1 — a Wine that runs 32-bit programs (M).** `ports/emulators/wine` in
  the overlay, built with Wine's new WoW64 (`--enable-archs=i386,x86_64`: 32-bit
  PE code on 64-bit Unix libraries, so no i386 package set). Needs a PE
  cross-compiler in the build (`mingw`, or clang's). Spike first: does Wine 11's
  WoW64 build and run on FreeBSD 16 at all? Done when a 32-bit probe runs from
  the overlay's package. Depends on P17.4.
- **P19.2 — Windows programs are applications (M).** appgen makes a `.app`
  for a `.exe` (and for a Wine `.desktop` entry), with a prefix per bundle
  under `~/Library/Wine/<name>`, made on first launch with Mono and Gecko
  off. The Finder opens a `.exe` the same way. Quitting from the Dock ends
  the prefix's `wineserver`, not just one process (§1.1, finding 5).
- **P19.3 — Wine windows look and behave like ours (M).**
  `xdg-toplevel-icon-v1` in `undertow` (the Dock gets real icons for every
  client, not only Wine's: API-STUDY §2's P2 row). Spike: does
  `winewayland.drv` ask for `xdg-decoration`? If it can, the Aqua frame
  follows; if not, record it and leave Wine's frame (§6.3).
- **P19.4 — the game path in `undertow` (M).** `wp-tearing-control-v1`
  honoured for a fullscreen window that asks; adaptive sync per output, and a
  Variable Refresh switch in the Displays pane; direct scanout of a
  fullscreen client's buffer (PHASE6 left it to metal). Proven headless where
  it can be (the protocol state), and on the 12700KF for the rest (§5).
- **P19.5 — keys a game, a VM or a remote desktop must own (S).**
  `keyboard-shortcuts-inhibit-v1`, with a way out the inhibitor cannot
  block (the lock chord, and one reserved chord to take keys back), shown in
  the menu bar while it holds.
- **P19.6 — OBS (M).** Why FreeBSD 16 has no `obs-studio` package; build it
  (and `wlrobs`) in the overlay. Done when OBS records `undertow`'s output to
  a file through `wlrobs` in the guest and the file's frames are not black.
  OBS is Qt: it runs as a plain Wayland client under the one-toolkit rule,
  without menu-bar integration (§6.4).
- **P19.7 — a streamer's hotkeys (S).** `abyss-dbus` answers
  `org.freedesktop.portal.GlobalShortcuts`, bound through `undertow`'s keybind
  table, listed in System Preferences, revocable there. Only ADE's service,
  as ever: the bridge does not become a bus.
- **P19.8 — sound a stream can take (M).** Desktop audio and a microphone
  as separate sources OBS can capture, through `virtual_oss`. This is
  BACKLOG §4's per-application volume decision, taken here as route (b).
- **P19.9 — the gate (S).** On the 12700KF: a 32-bit and a 64-bit Windows
  game from the overlay's Wine, through their bundles, on RADV; a tearing
  fullscreen present; OBS recording that game to a file. Numbers recorded
  beside Phase 4's.

---

## 4. What this phase does not do

- **XWayland**, in any form we ship.
- **Steam.** Its client is Linux and X11-only; through the Linuxulator it is
  someone else's project, and with no XWayland it is not ours.
- **Anti-cheat** and anything that checks for real Windows.
- **VR** (`drm-lease`).
- **HDR and colour management** (API-STUDY's P3 row).
- **Gamepads below the desktop.** FreeBSD has no driver for PS5 or Xbox
  One/Series pads and evdev has no force feedback (API-STUDY §4). Those are
  kernel work for the fork, recorded in BACKLOG §6; this phase uses the pads
  FreeBSD already drives.
- **A game store or launcher.** A game is a `.app`, like everything else.

---

## 5. Verification

P19.0's live script, in the guest, on every pass from P19.2 on; protocol
state for P19.3–P19.5 in `undertow`'s unit tests; P19.9 on metal, in one
sitting with BACKLOG §3's other owed items. Nothing here touches the
installer or the boot path, so `--full` is not this phase's lane.

---

## 6. Decisions

1. **No XWayland.** *Decided 2026-10-31.* See the top of this page.
2. **`wlr-data-control` is offered only to clients granted it.**
   *Recommendation.* PHASE9 §6.4 said "not until something asks"; Wine asks.
   But the protocol lets any client read the clipboard at any time, so offer
   it per client (a Wine bundle's launcher asks through `security-context`,
   granted per application in System Preferences), never to everyone.
3. **Wine's own frame, if Wine will not take ours.** *Recommendation:
   accept it,* and say so in the docs rather than patching Wine.
4. **OBS stays a Qt application without menu-bar integration.**
   *Recommendation.* The one-toolkit rule is about what we integrate, not
   what may run.
5. **Screen capture through PipeWire.** *Recommendation: not in this
   phase.* `wlrobs` over `wlr-screencopy` needs no daemon. If a program
   that only speaks the ScreenCast portal matters later, the bridge answers
   it and PipeWire is that pass's decision, never a bus.
