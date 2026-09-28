# Phase 14 — preferences that write (scope)

System Preferences stops being a painting. Read [PLAN.md](PLAN.md) for where
this sits (it needs 9, 10 and 11, and unblocks 15–18: a browser, an updater and
a remote model all want a network), [PRODUCT.md §4.5](PRODUCT.md) for thesis 5 —
**`rc.conf` is not a user interface** — and [HANDOFF.md](HANDOFF.md) for the
traps this phase will meet: §2.37 (a probe with no positive control), §2.45 (a
silent fallback is invisible) and §2.61 (a wait the past can satisfy).

Last updated: 2026-09-25. **Scoped, and §6's recommendations are decided**
(all but §6.5, which is a fact about the bring-up machine). **The plan was
re-measured and its risks spiked on the FreeBSD guest before this was written**
(§4). What changed from
PLAN: **two of the four panes can be tested on a machine with no such
hardware** — FreeBSD 15.0 ships a virtual sound card (`snd_dummy`) and an
802.11 simulator (`wtap`) — and one of PLAN's promises, per-application volume,
**may not be keepable on OSS**, which a spike decides before a pane promises it.

---

## 1. What this phase is

**Goal (PLAN):** a person changes the machine's network, sound, displays and
power from System Preferences, and the change is *real*: written where FreeBSD
keeps it, applied now, and still there after a reboot. And when something
fails, the machine says what failed.

**The shape is decided already** — it is the installer's (PHASE5, HANDOFF
§1): **the GUI does not touch the system.** An unprivileged pane builds a
*plan* and sends it over `CurrentIPC` to a root helper that owns the writing,
checks the caller with the kernel (`getpeereid`/`SO_PEERCRED`, not socket
modes), refuses or compiles the plan, runs it, and reports progress. The
dangerous half is testable with no GUI in it, and the GUI is testable with the
dangerous half in dry-run. Nothing here re-invents that split.

**What it is not:** a login window or a password prompt (Phase 16), updates
(17), or a settings daemon for applications (preferences that a *program*
reads are `PoolConfig`'s, and already work).

---

## 2. What we have vs. what's new

| Area | Today | Phase 14 |
|---|---|---|
| System Preferences | `paintSystemPreferences`: a scene in `AquaDemo`, a picture of a pane grid backed by nothing | a real application: the grid, panes, Show All, a pane that can fail and say so |
| Appearance | `appearance.ini` is read once at startup (P11.2); nothing writes it | an Appearance pane writes it, and **every process redraws when it changes** — the theme system becomes something a person can use |
| Network | nothing; the medium runs `dhclient` from `rc.conf` | wired (DHCP / manual IPv4, DNS) and Wi-Fi, written to `rc.conf` / `wpa_supplicant.conf`, applied with `service netif` |
| Sound | `Vents.Mixer`: master get/set; the menu bar's volume item has said "no mixer" since P3.7 | devices, the default device, levels and mute, persisted; the menu bar's item live |
| Displays | `undertow` tracks outputs and never arranges them | `wlr-output-management-v1` in undertow, and an arrangement pane (both platforms) |
| Energy | nothing | the settings Phase 16's idle and suspend will read; `powerd` |
| Privileged writing | `abyss-install` (disks only) | **`abyss-settings`**, the same shape for system settings, started at boot on an installed system |
| Failures | `SessionPlan.notes` exists with no surface | a pane shows what the helper refused or what failed, in words |

---

## 3. Ordered passes

**P14.1 — System Preferences is an application.** A real Aqua window:
the pane grid from the theme's icon set (P11.8), Show All, navigation, and the
pane protocol every later pass fills in (a pane has a model, a view, and a
"what failed" line). The existing `sysprefs` golden stays the grid's picture,
now drawn by the application rather than a scene. **Gate:** the app opens, the
grid is what the golden says, each pane opens and says "not yet" honestly.

**Done.** What landed:

- **`de/aqua/SystemPreferences.swift`**, the application:
  - Jaguar's 25 panes in their four sections, each with an id (the icon
    set's name, so every pane draws from the theme, P11.8) and a sentence
    saying what it is for;
  - a model (grid or page, keyboard focus, each pane's note);
  - **one layout, read by the painter and the hit-test** (§2.9);
  - a page per pane that is honest: titled with the pane's name, its
    purpose, and *"This pane cannot change anything yet."* until a later
    pass builds it — or what failed, when something does.
- **Navigation:**
  - the pointer (grid, Show All, the toolbar's favourites, which work from a
    page too);
  - the keyboard (arrows walk the grid in reading order, Return opens,
    Escape and ⌘L show all);
  - the window's title becomes the pane's, as Jaguar's did.
- **Its vocabulary** (Phase 10), `menus.systempreferences.<pid>`:
  - System Preferences, View (Show All ⌘L, then every pane in the grid's
    order), and Window;
  - each verb validated with a reason ("every pane is showing", "that pane
    is showing").

  The key handler is the model's own `verb(for:)`.
- `AquaDemo`'s live `sysprefs` is the application; the PNG scene draws its
  default model. The grid moved there **pixel for pixel**: the `sysprefs`
  golden did not move. There is a new golden, `sysprefs-pane` (Network's
  page), and 70 scenes in all.

**What it found:** the grid's cells merely touched, and **touching cells
overlapped by a rounding error**, so a click on the seam belonged to whichever
came first. They are 1 pt apart now. The unit test that every cell's hit rect
is disjoint from every other's caught it before any person could.

**Verified (short checks only):**
- **`live-prefs.sh`** (new, ~3 s, in `run.sh`'s live lane), on Linux **and in
  the FreeBSD guest**, on our own compositor:
  - a click on Network opens it, and undertow sees the window retitled;
  - Show All goes back;
  - → → from the pane last visited lands where a Mac's would, Return opens,
    ⌘L shows all;
  - `abyssmenu` lists System Preferences, opens Sound by its verb, and is
    refused re-opening it, with the reason.

  Every coordinate comes from the application's published layout (§2.46).
  **Seen to fail:** with the hit-test sabotaged, it failed at the first click,
  naming it.
- `SystemPreferencesTests` (5):
  - the catalogue is unique and fully drawable from the icon set;
  - every cell is hit at its icon and its label, and no two overlap;
  - the grid does not answer on a page;
  - pages are titled and honest;
  - the keyboard walks in reading order, clamped;
  - the vocabulary has no conflicting keys, and its View menu is the grid.
- The golden gate, 70 scenes, on both platforms; `swift test` on Linux, 543,
  green.

**P14.2 — Appearance, and a theme you can change while it is running.** The
one pane that needs no root. It writes `appearance.ini` — theme, scheme, the
theme's own parameters (Trench's glow, bevel) — and **every process that draws
reloads**: the toolkit, the shell, `undertow`'s frames, and the portal, which
re-publishes its palette (P11.10) and emits `SettingChanged` so a running GTK or
Qt application follows. `PoolConfig`'s watch (P2) is the mechanism. **Gate:**
switching Aqua → Trench in the pane restyles a live session with no restart,
checked in pixels, and a GTK application sees `color-scheme` change.

**Done** (2026-09-28, in four commits, P14.2a–d). What landed:

- **The drawing layer can change its mind.** `Theme.generation` is bumped by
  every `Theme.use`, which also drops the glow and halo masks (keyed by a
  shape's name and shaped from a role's font — both theme-owned); noise tiles
  stay. Fonts are added per directory, so a theme switched to later finds its
  own. `ThemeLoader.reloadIfChanged`, `ThemeLoader.Watch` (a config-dir
  descriptor for the caller's own loop) and `ThemeLoader.store`.
- **`undertow`** loads its theme after `--config-dir` (it used to read the
  environment's), watches from its own wayland event loop, and keys each frame
  texture on the generation it was drawn in.
- **Every toolkit process** — one watch in AquaDemo's `main`, where every
  scene passes, and `Display.setEverythingNeedsDisplay`.
- **The portal** asks the palette again and emits `SettingChanged` for each
  key that differs — the first time anything here has.
- **`abyss-theme set NAME [SCHEME]`**, refusing in words what would not load.
- **The General pane** (Jaguar's name for it): the installed themes, the chosen
  theme's schemes, a slider per setting within its bounds — read from
  `appearance.ini` each time it draws, written at once on a click, a slider on
  release. Two goldens, `sysprefs-general` and `trench-sysprefs-general`.

**Verified** — `live-appearance.sh`, on Linux **and in the FreeBSD guest**:
a decorated window, the desktop, the bar, the Dock and an Aqua window, each its
own process, plus the portal on a private bus with `gdbus monitor` listening:
1. `abyss-theme set` Aqua → Trench → Trench daylight → Aqua: every process
   reloads, five pixel strips change and come back **byte for byte**;
2. the portal's `SettingChanged` decoded by GLib (color-scheme 1, then 2), and
   `ReadOne` agreeing;
3. the pane: a click on Trench, on Daylight, a slider dragged and released
   (written once, `gk = 0.25`), and Aqua again with Trench's settings dropped.

Every fix was put back and the test failed where it should — including one it
missed at first: Aqua → Trench changes the title bar's height, so a frame cache
that ignored the theme missed by accident; the colour-only neon → daylight step
exists because of that. The test's own bugs are HANDOFF §2.75. **Not caught
live:** keeping the glow/halo masks (no sampled strip holds one); the unit test
guards it. **Known limits:** the Dock's surface is sized from theme metrics once,
at creation; parameters are labelled by their raw names (`gk`) — a theme cannot
name them yet; a theme file edited in place is not a change until
`appearance.ini` is touched.

**P14.3 — `abyss-settings`, the privileged half.** `abyss-install`'s shape,
built once more on purpose rather than generalised prematurely:
- typed plans (`NetworkPlan`, `SoundPlan`, `EnergyPlan`), a wire, a peer-uid
  check (§6.1 decides who is admitted), refuse-or-compile, a journal of what it
  ran, `--dry-run`;
- **`rc.conf` is written with `sysrc(8)`** — base, and the tool FreeBSD itself
  provides for exactly this — into a staged copy first, applied only when the
  whole plan compiles;
- an `rc.d` script (`abyss_settings_enable`) that the installer writes, so an
  installed system has the helper from boot; `anchor` runs it on the medium;
- `abyss-settingsctl`, so every plan is testable without a GUI;
- **on Linux it refuses, and says why** — the installer's positive control,
  not a skip.

**Done** (2026-09-28, P14.3a–b). What landed:

- **`Settings`** (imports nothing): typed plans, refusals, compile to steps.
  The first plan is the Energy pane's `powerd` half (P14.8's), because it is
  real and harmless in a build guest; the network plan (P14.4) is neither. The
  pane never names a command, a file or a variable.
- **`SettingsWire`**, **`SettingsRun`** (read / check / apply; the journal;
  `rc.conf` edited with `sysrc` in a staged copy that replaces the file in one
  `rename` once every edit succeeded), **`abyss-settings`** (root, `--uid`
  required, socket handed to that uid alone) and **`abyss-settingsctl`**.
- **Who** (§6.1): the uid it was started for, and only while it is in `wheel`,
  asked at every connection. **Linux** (§6.4): a real read or apply is refused
  in words; dry run works everywhere.
- **Delivery:** `/etc/rc.d/abyss_settings` in the desktop set (before
  `abyss_desktop`, the same runtime directory); the installer writes
  `abyss_settings_enable` and **`abyss_settings_admin`** for the administrator
  it creates, and nothing when there is none; the medium's live session starts
  it as root beside `abyss-install`. **§6.2 said `anchor` would start it on the
  medium** — `anchor` is not root there; the live session's root half is.

**Verified:** `SettingsTests` (11) — including, on FreeBSD, a plan whose second
`sysrc` edit fails leaving `rc.conf` untouched; `live-settings.sh` on both
platforms (a non-administrator refused; check shows the commands; dry run
journalled and writes nothing; Linux refuses; in the guest, as root, root
itself refused by the peer check and a real apply to a scratch `rc.conf`); and
**the `rc.d` script run under the real `rc.subr` in the guest** — start as
root, the socket answering the build user, status, stop. That run found the
`${name}_user` collision (HANDOFF §2.76). Not yet run: `live-medium.sh` and
`live-desktop.sh`, which now assert the helper comes up on the medium and on
an installed system — the `--full` lane.

**P14.4 — Network, wired.** Interfaces (`getifaddrs`, link state from the
routing socket), DHCP or manual IPv4 (address, mask, router), DNS. Written as
`ifconfig_<if>`, `defaultrouter` and `resolvconf`; applied with `service netif
restart <if>` and `service routing restart`; status live. **Gate** (§6.3): in a
nested bhyve guest, a manual address is set from the pane, the guest reboots,
and the address held.

**Done** (2026-09-28, P14.4a–d, the gate green in the guest). What
landed:

- **The plan** (P14.4a): `NetworkPlan` — an interface, DHCP or a manual address
  with mask and router, name servers — compiled to `ifconfig_<if>`
  (`SYNCDHCP`, or `inet A netmask M`), `defaultrouter` (set, or removed),
  resolvconf.conf's `name_servers`, then `service netif restart <if>`,
  `service routing restart` and `resolvconf -u`. Both files are written in
  staged copies that replace the real ones only once every write succeeded.
  The helper refuses an interface the machine lacks, a router outside the
  subnet, and the loopback, in words. **`--write-only`** writes the files and
  skips the three actions, *saying so*, for a harness whose network is how it
  is reached.
- **Status without privilege** (P14.4b): `Vents.Network` — `getifaddrs`, link
  state, the default route (`route -n get` / `/proc/net/route`), resolv.conf —
  and a routing-socket (rtnetlink on Linux) watch; `ventsctl network [--wait]`.
- **The pane** (P14.4c): Status is the kernel's, redrawn when the watch fires;
  Configure is rc.conf's, read through the helper. It offers wired interfaces
  only (Wi-Fi is P14.5's). DHCP or Manually, four fields with Tab between
  them, Revert, and Apply Now (or Return), whose events arrive on the run loop.
  It links `SettingsWire`, not `SettingsRun`; what was typed is sent, and the
  helper's refusals are shown in its words. A write-only apply is "saved, and
  not put into effect", never "applied".
- **The gate** (P14.4d): `live-network-reboot.sh`, in `--full` after
  `live-desktop.sh`, on the disk that test installed: a one-shot rc script
  planted on it runs `abyss-settingsctl apply network` **as the
  administrator**, the machine reboots itself, and the second boot must have
  the address, the router and the name server from rc.conf alone. As with
  P5.5, nobody clicks inside the nested machine; the clicking is
  `live-network-pane.sh`'s, on the same binary and helper.

**Verified:** `SettingsTests` +7, `VentsTests` +4, `NetworkPaneTests` 8 — 611 on
both platforms; `live-settings.sh` §6 (a write-only apply on the guest's own
vtnet0, both files written, three actions skipped and said, read back, back to
DHCP); `live-vents.sh`'s network half against ip(8) / ifconfig, and the watch
seen to fire on an lo0 alias; `live-network-pane.sh` on both (the pane's status
equals `ventsctl`'s; a bad address refused in the helper's words; corrected and
applied write-only, the files read back and vtnet0 untouched; Revert; an lo0
alias redraws the page), with fault injections each seen to fail; the golden
`sysprefs-pane` re-pictured on both. **The gate:** `live-desktop.sh` green
(7m10s, including its first run of the P14.3b check that the installed system
starts the settings helper). Then, on the disk it installed,
`live-network-reboot.sh` green (2m30s): six steps applied as `abyss`, 10.77.0.5
on vtnet0 at once, the machine rebooted itself, and after the reboot it had
10.77.0.5/24, router 10.77.0.1 and name server 10.77.0.1 from rc.conf alone.
Its refusal path was seen first, against a disk installed before P14.3b.

**P14.5 — Network, Wi-Fi.** Scan (`ifconfig wlan0 scan`), join (a
`wpa_supplicant.conf` network block, `wlans_<dev>` in `rc.conf`), forget.
Its testability is a spike (§4.2): `wtap(4)` loads in the guest; whether it can
put a station against a `hostapd` on another `wtap` decides whether the join is
verified in the harness or only on metal (§6.5).

**P14.6 — Sound.** Devices (`/dev/sndstat`, `sndctl(8)`), the default device
(`hw.snd.default_unit`), levels and mute through the mixer, persisted by
`rc.d/mixer`. **The menu bar's volume item becomes real** — tested on the
guest's `snd_dummy`. Per-application volume only if §4.3's spike says OSS can
do it from outside the application; otherwise the pane does not pretend.

**Done** (2026-09-28, P14.6a–d). §4.3's spike answered the per-application
question: OSS lets another process read a channel's volume and not set it.
Decided: shown read-only now, with control via `virtual_oss` in Phase 18 (§4.3
has the measurements; PLAN is amended). What landed:

- **`Vents.Sound`** (P14.6a): devices and each channel's pid, command and
  volume from `/dev/sndstat`'s nvlist; each device's controls, levels and mute
  through libmixer; the default unit. `ventsctl sound [set|mute]`. Found
  against `mixer(8)`: libmixer acts on the *selected* control (HANDOFF §2.78).
- **The default device through the helper** (P14.6b): a `sound` plan writes
  `hw.snd.default_unit` to `/etc/sysctl.conf`, the helper's third file, which
  it edits itself because `sysrc` refuses dotted names. Then it runs `sysctl`.
  Levels and mute stay the user's, and `rc.d/mixer` (on by default) keeps them
  across a reboot.
- **The pane** (P14.6c): output device, levels and mute on the default device
  (applied as the slider moves), and "Playing now", read-only, with the page
  saying why. It re-reads once a second while it shows.
- **The menu bar's volume item** (P14.6d): it follows the default device's
  `vol` each tick; a muted output is dimmed; a click drops Jaguar's vertical
  slider, and a drag sets the level.

**Verified:** 624 unit tests on both platforms. On both, `live-vents.sh`'s
sound half, `live-settings.sh` §7, `live-sound-pane.sh` and
`live-menubar-volume.sh`: Linux as the positive control (no devices, nothing
to click); the guest against `snd_dummy`, every change read back by `mixer(8)`
and the guest's levels restored. Six fault injections, each seen to fail. Two
new goldens (`sysprefs-sound`, `menubar-muted@2x`). **Not verified:** moving
the default to a *different* device, because the guest has one and `snd_dummy`
loads once. That waits for metal.

**P14.7 — Displays.** `wlr-output-management-v1` in `undertow` (wlroots 0.19
has it on both platforms), and a pane that arranges outputs by dragging, and
sets mode and scale. Saved per user (`displays.ini`), applied by `undertow` at
start. Tested on both platforms against multiple headless outputs — the one
settings pane with no FreeBSD-only half.

**P14.8 — Energy.** Display sleep and system sleep delays (the values Phase
16's idle will read), `powerd` on/off and its mode, and the battery where
`Vents` finds one. Deliberately thin: suspend itself is Phase 16's.

**P14.9 — The phase gate.** PLAN's verification, whole: a pane writes
`rc.conf`, the machine reboots, the setting held; and each pane is driven
live the way `live-installer.sh` drives the installer, by pointer and keyboard,
against the helper in dry-run on Linux and for real in the guest.

---

## 4. The spikes

Run on the FreeBSD 15.0-RELEASE-p11 build guest (QEMU, one `vtnet0` on user
networking, no wireless, no sound) before this was written.

### 4.1 Is the network tooling in base? — **Yes, all of it.**

`ifconfig`, `route`, `dhclient`, `resolvconf`, `service`, `wpa_supplicant`,
`wpa_cli` and **`sysrc`** are in `/sbin` and `/usr/sbin`. The guest's own
network is `ifconfig_DEFAULT="SYNCDHCP accept_rtadv"`. So Phase 14 installs no
network packages; it writes base's configuration with base's tools.

### 4.2 Can Wi-Fi be tested without a Wi-Fi card? — **Maybe. `wtap` loads; the rest is a spike.**

`wtap.ko` ships and loads, and creates `/dev/wtapctl`. Its control tool (in
`tools/tools/wtap`) is not installed and no man page ships, so device creation
is an ioctl a small helper makes. **Open:** whether a `wtap` station can
associate with `hostapd` on a second `wtap`. If it can, joining is verified in
the harness; if not, scan and join are verified on metal only.

### 4.3 Can sound be tested without a sound card? — **Yes: `snd_dummy`.**

`kldload snd_dummy` gives `pcm0: <Dummy Audio Device> (play/rec) default` with a
real mixer (`vol`, `pcm`, `rec`, levels settable). `sndctl(8)` (new in 15)
reports device properties; `rc.d/mixer` persists levels; `hw.snd.default_unit`
picks the default. **Open:** per-application levels. OSS gives each channel a
volume that its *own* process sets (`SNDCTL_DSP_SETPLAYVOL`); whether another
process can read or set it — through `sndstat`'s channel list, virtual
channels, or `sndctl` — is unproven. PLAN promised it; this spike decides it.

**What the source says, before the spike runs (2026-09-28,
[API-STUDY.md](API-STUDY.md) §3):** reading is possible — `sndstat`'s nvlist
reports each channel's pid, command and volume — and setting is not:
`SETPLAYVOL` acts only on the caller's own channel, and the `vpc` sysctls act on
all of them. So the spike should confirm that, then choose between **(a)** a
small fork patch, an ioctl that sets a channel's volume by (unit, channel) with
an ownership check, and **(b)** one `virtual_oss` node per application (in base
in our tree; whether 15.0 ships it is unverified), which also gives
default-device following for free and fits Phase 18's jails. A mixing server in
front of OSS is not recommended: vchans already mix. §6.6's fallback still
stands if neither is worth it.

**The spike, run 2026-09-28 in the build guest (15.0-RELEASE-p11, `snd_dummy`):**

- **Reading works, as the source said.** Two players set their own channels
  to 30 and 80 with `SNDCTL_DSP_SETPLAYVOL`. An unrelated, unprivileged process
  read both from `/dev/sndstat`'s nvlist (`dsp0.virtual_play.0 pid … comm
  player vol 30:30`, `…1 … 80:80`).
- **Setting from outside does not.** Another process's `SETPLAYVOL` opens a
  channel of its own. The mixer's `pcm` control leaves channel volumes alone
  (`hw.snd.vpc_mixer_bypass=1`). The one outside lever is `hw.snd.vpc_reset`:
  root-only, and it resets *every* channel to 0 dB at once.
- **Route (b) works, with two costs.** `virtual_oss` is in 15.0's base
  (`/usr/sbin/virtual_oss`, needs `cuse`). Two applications on two
  `virtual_oss` devices, measured through a loopback device, each playing a
  tone that peaks at 8000 (16000 mixed): `VIRTUAL_OSS_SET_DEV_INFO` on the
  control device, **at runtime and for one device only**, took app1 to −6 dB
  (mix 12000), muted it (8000), and took app2 to −12 dB (10000). The playback
  direction is `tx`. The costs: gain is a bit shift (−31…31), **6 dB steps**;
  and an application only gets its own device if it is *handed* one when it
  starts, because applications open `/dev/dsp`.
- `virtual_oss_cmd … -a o,-1` changed nothing at runtime. The ioctl is the
  interface; the header is not installed (it lives in the source tree).

**Decided 2026-09-28 (the person): read-only now, route (b) later.** P14.6
shows which applications are playing and at what level, read from
`/dev/sndstat`, and does not offer to change them. Per-application control goes
through `virtual_oss`, one device per application, and arrives with Phase 18,
whose jails give each application its own `/dev/dsp`. PLAN's promise is amended
to say so.

### 4.4 Can displays be arranged? — **The protocol is there on both platforms.**

`wlr_output_management_v1.h` is in wlroots 0.19 on Fedora and FreeBSD, beside
`wlr_output_layout` (which `undertow` already uses) and output power
management. The work is undertow's, and testable with headless outputs.

### 4.5 Energy — **ACPI S3, S4 and S5 in the guest; no battery.**

`hw.acpi.supported_sleep_state` is `S3 S4 S5`; there is no battery in the VM.
The battery row is verified on metal, or against `Vents`' documented seam.

---

## 5. Verification

- **The helper first, with no GUI:** `abyss-settingsctl` plans in dry-run on
  both platforms; for real in the guest; refused on Linux with its reason.
- **Each pane driven live** (pointer and keyboard), against the helper, the way
  `live-installer.sh` drives the installer — and the goldens (P11.1) for how
  each looks, in Aqua and Trench.
- **Changes survive a reboot:** in a nested bhyve guest (the `--full` lane's
  machinery), because the build guest's only interface is the harness's own
  way in (§6.3).
- **Nothing silent:** every refusal and failure is shown in the pane and
  logged by the helper, and a test asserts each one is (§2.45).

---

## 6. Risks and open decisions

**6.1 Who may change the machine?** **Decided 2026-09-25: the recommendation.**  The installer already says `wheel` makes
an administrator. **Recommendation:** `abyss-settings` admits the console
session's user if it is in `wheel`, and refuses anyone else by name — with no
password prompt in this phase, because asking for one needs a trustworthy
prompt, which is Phase 16's (the login window's) to build. The consequence to
accept: an administrator's session can change network settings without
re-typing a password, as on a single-user Mac with an admin account and no
"require password" setting.

**6.2 How the helper runs.** **Decided 2026-09-25: the recommendation.**  **Recommendation:** an `rc.d` service started at
boot on an installed system (`abyss_settings_enable`, written by the
installer, as `abyss_desktop_enable` is), and started by `anchor` on the
medium. The alternative — `anchor` launching a root helper on demand — needs
`anchor` to be root, which it is not.

**6.3 Testing a pane that can cut the harness off.** **Decided 2026-09-25: the recommendation.**  The build guest's only
interface is how the harness reaches it; a wrong network plan there ends the
run. **Recommendation:** dry-run in the build guest, and real apply-and-reboot
in a nested bhyve guest, as the installer's tests do.

**6.4 Linux.** **Decided 2026-09-25: the recommendation.**  `rc.conf` has no Linux meaning. **Recommendation:** on Linux the
helper refuses root plans with a reason (a positive control), and the panes run
against it in dry-run; Appearance and Displays are real on both.

**6.5 Wi-Fi on metal. — still open.** If `wtap` cannot associate (§4.2), Wi-Fi join is
verified only on a machine with a wireless card. **Open:** whether the bring-up
machine (i7-12700KF) has one — if not, the join is unverified until there is
one, and that is said, not glossed.

**6.6 Per-application volume.** **Decided 2026-09-25: the recommendation.**  If §4.3's spike says OSS cannot, the Sound pane
offers devices, master and per-device levels, and PLAN's promise is amended in
the open rather than faked.

**6.7 Live theme switching reaches every process.** **Decided 2026-09-25: the recommendation.**  P14.2 touches the toolkit,
the shell, `undertow` and the portal at once, and the traps are known: a
process that misses the change draws the old theme next to one that did
(§2.45's cousin), and a cached glow, halo or noise tile from the old theme
survives it. **Mitigation:** the caches key on the theme's identity, and the
gate compares a live session's pixels to the goldens *after* the switch.
