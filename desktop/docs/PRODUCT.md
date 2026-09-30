# What kind of OS this is — five theses, and the gap between them and the tree

The argument about what we are building a desktop *for*, and a map of where each
need it names has landed. **[PLAN.md](PLAN.md) is the roadmap** — everything argued
here lands there as Phases 9–18, ordered by dependency (§9) — [STATUS.md](STATUS.md)
and [BACKLOG.md](BACKLOG.md) are what is built and what is next, [HANDOFF.md](HANDOFF.md)
the traps.

_Reviewed 2026-09-30, after Phase 14, the BACKLOG's U/T passes and the move into
the AbyssBSD monorepo. This document keeps the argument and says where each need
went; it does not narrate progress, which is how it went stale before. When a
row changes state, change it here in one line and put the detail in STATUS._

---

## 0. The one-line version

**We have built a desktop, and the half of a system that configures the machine
it runs on. We have not built the half a person lives in.** About 43,000 lines of
Swift across 80 targets (22 of them programs): a compositor, a toolkit, a control
plane, portals, a supervisor, an installer, a menu protocol, a theme engine. The
application layer is **three Aqua programs** — the Finder, the Installer, and
System Preferences, whose Appearance, Network (wired and Wi-Fi), Sound, Displays
and Energy Saver panes now change the machine through a privileged helper — plus
`Fathom`, which reports on a machine as text. There is still **no terminal, no text
editor, no browser, no login window, no lock screen and no way to update**. That
list is Phases 15–17.

*(On 2026-09-05 this paragraph said "23,600 lines, 40 targets, two programs, and
System Preferences is a painting". It was true then.)*

Omarchy is the mirror image: almost no engine, a very deliberate application
layer. It is strong exactly where we are empty, and the thing it gets right is
not Hyprland.

---

## 1. The five theses

An opinion is a rejection, so each is stated with what it rules out.

1. **TUIs are the wrong shape on a machine with a GPU — but the app ideas are
   right.** *Rejects:* a terminal-first desktop, and "configure the network"
   meaning a text UI. *Keeps:* that the set of things a person needs is small,
   knowable, and already enumerated by somebody else.
2. **WIMP won. Keyboard shortcuts are for power users and are secondary.**
   *Rejects:* discovery-by-cheatsheet. Every command reachable with a mouse,
   visible without being memorised, and *then* also bound to a key.
3. **Traditional window management beats tiling for almost everything.**
   *Rejects:* automatic layout — the machine moving windows you placed. This does
   **not** reject workspaces, window sets or an Exposé equivalent; §7 argues they
   are how the thesis wins.
4. **Agents are a good idea and belong in jails.** *Rejects:* the industry
   default — a CLI agent running as you, with your credentials, over your whole
   home directory — and, equally, permission-by-popup, which is that same agent
   with a dialog in front of it. Confinement is the grant; a requester is for the
   few things confinement cannot say (§4.4).
5. **It should just work on the vast majority of systems.** *Rejects:* "read the
   handbook", `rc.conf` as a user interface, and a hardware story that is one
   machine.

Thesis 5 was in tension with the roadmap: **Phase 4 was scoped as "the Mac Pro",
and thesis 5 says the deliverable is a hardware *matrix*.** Resolved on
2026-09-05 — bring-up retargeted to an i7-12700KF / RX 6750 XT and the Mac Pro
became the matrix's second row (PHASE4 §1.1), which is the shape thesis 5 asked
for. **The 12700KF is still the machine the desktop is brought up on** (reaffirmed
2026-09-30). The monorepo also carries a second architecture, the Radxa Dragon Q8B
(aarch64, board work under `src/` and `kmod/`), but it is not far enough along to
host the desktop: a row the matrix will gain, not the target. See §4.5 and §9.

---

## 2. What to take from Omarchy

Omarchy is Arch plus Hyprland plus a curated everything, installed by one script
and updated by one command. Its interesting property is neither the window
manager nor the theme pack:

> **A desktop is not a compositor and a shell. It is the set of answers to "how
> do I do X", and that set is a product — curated, versioned, updated and
> documented as one thing.**

It enumerates the set and ships an answer for every entry. Nothing in it is
novel; the *completeness* is the product.

**Take:** the capability checklist (§4.1 — we did not have to invent the shopping
list); one command that updates the system *and its configuration*, with
migrations; a single discoverable entry point to system actions (ours is the
Apple menu and System Preferences — the same idea in the WIMP dialect); foreign
programs presented as first-class local applications (§6.1); documentation as a
shipped surface.

**Leave:** TUIs, tiling, keybind-primary discovery — and Omarchy's *theme
catalogue*, the curated pack of looks and the churn of keeping it current. **We
ship Jaguar as the product**, and a second theme only as proof the format is one
(§8.7). The *mechanism*, though, is a must-have: §8.

---

## 3. Where we stand

**Engine — done enough that the next gaps are not in it.**

| | |
|---|---|
| Compositor | `undertow`: wlroots-backed, three backends (headless/nested/DRM), frame contract with metronome and flight recorder, its own scene, several outputs on one metronome, server-side Aqua decorations, the keybind table, linux-dmabuf and explicit sync, presentation-time, viewporter and fractional scale, text input and input methods, pointer constraints, cursor shapes drawn from the theme, display sleep with idle inhibit |
| Client runtime | `Surface`: xdg-shell v6, layer shell, popups and submenus, keyboard + xkb, pointer + scroll, per-output HiDPI, clipboard and drag-and-drop, foreign-toplevel, xdg-activation, screencopy, output management |
| Toolkit | `Aqua` over `AquaDraw`: the 10.2 widget set, drawn from **theme data** (tokens, draw lists, chrome, fonts, icons, cursors — Phase 11), FreeType/HarfBuzz text, focus traversal, sheets, menus, undo |
| Control plane | `CurrentIPC`, `PoolConfig`, `Anchor` (supervisor, session plan), `Vents` (sysctl, sound, battery, devd, network), `Spawn` (the one async-signal-safe way to start a process) |
| Menus | the menu protocol: an application publishes its **vocabulary**, the bar is its first consumer; GTK (`org.gtk.Menus`) applications appear in the same bar through `abyss-dbus` (Phase 10). **One foreign toolkit, GTK** — Qt's `dbusmenu` path was removed 2026-09-30 (PLAN: one toolkit) |
| Portals | `abyss-portal` (file chooser returning a *descriptor*, screenshot, notify) + `abyss-dbus` (`org.freedesktop.portal.*`, including the theme's palette) |
| Privileged helpers | `abyss-install` and `abyss-settings`: an unprivileged GUI sends a typed plan, a root service checks who is asking and does the writing |
| Delivery | a live medium that boots, runs `Fathom`, and installs onto an empty disk |

**Shell — present and wired.** Desktop with icons, a menu bar that shows the
frontmost application's menus (ours or GTK's) with status items and a real
volume control, a Dock with magnification and a working Trash, the Finder (browser
+ spatial, real file operations, contextual menus), notifications, `Launcher`.

**Applications — three, and a report.** The Finder, the Installer, System
Preferences (five panes that write), and `Fathom` as text. **System:** it installs
and it configures, and nothing else yet — no updates, no package UI, no login
window, no lock screen, no suspend. **Machines:** the installer is on screen on the
12700KF, and nothing has been installed on metal (§4.5).

---

## 4. The gap map

Sizes are relative to this tree: **S** ≈ a few hundred lines (`Portal` is 224);
**M** ≈ `Dock` (575); **L** ≈ `Finder` (1340); **XL** is a phase. A ✅ row names
where it landed; the rest name the phase that owns them.

### 4.1 Thesis 1 — GUI answers to the TUI questions

| The need | Omarchy | Us | Where it lands | Size |
|---|---|---|---|---|
| Files | yazi | **Finder** ✅ | — | — |
| Wifi / network | impala | ✅ **Network pane**, wired and Wi-Fi: status without privilege, joins through `abyss-settings` by rc's own path, the passphrase never leaves the pane (P14.4, P14.5) | Proven in the harness on a simulated radio (`wtap`); no real radio yet | — |
| Audio mixing | wiremix | ✅ **Sound pane** and a real menu-bar volume item: device choice, levels, who is playing (P14.6) | Per-application volume is read-only: OSS cannot set another process's level, and `virtual_oss` is the route, with Phase 18's jails | **M** |
| Launcher / menu | walker | The Apple menu's items now do what they say (P10.8); the Dock's tiles are still a fixed list | Phase 15: §6.1's generated bundles give both real applications | **S–M** |
| Idle | hypridle | ✅ display sleep in `undertow`, idle-inhibit, ext-idle-notify (U.9) | — | — |
| Lock | hyprlock | **nothing** — no `ext-session-lock` | Phase 16, with the login window | **L** |
| Terminal | Ghostty | **nothing** — no pty code in the tree | Phase 15: `openpty`, a VT parser, Aqua chrome, scrollback, selection | **L** |
| System monitor | btop | **nothing** | Phase 15: Activity Monitor over `kvm`/sysctl | **M** |
| Screenshots | hyprshot | `abyssgrab` (portal + CLI) | Phase 15: Grab — selection rectangle, window picker, save sheet | **S** |
| Editing | nvim | **nothing** | Phase 15: TextEdit. Not an IDE — the thing that opens a `.txt` without a terminal | **M** |
| Web apps | Chromium `--app=` | **nothing**, and no browser at all | Phase 15: §6.1 generates the bundles; §5.1 picks the browser that backs them | **M** |
| Disks | — | `DiskInventory` (installer only) | Phase 15: Disk Utility — mount, format, ZFS snapshots | **M** |
| Package install | pacman/yay | **nothing**; the medium has *no package database* (P5.3, by design) | Phase 17: Install Software over `pkg(8)`, through the privileged split the helpers already model | **L** |
| System update | `omarchy-update` | **nothing** | Phase 17: §6.2 — ours can be better than theirs | **M** |
| Bluetooth | bluetui | **nothing** | FreeBSD's stack is thin. Scoping it out honestly is a valid answer; silently omitting it is not | **M–XL** |
| Printing | — | **nothing** | CUPS is in ports; a print sheet is a toolkit feature we lack | **L** |
| Git | lazygit | **nothing** | A developer tool, not a desktop capability. Defer without apology | |

### 4.2 Thesis 2 — WIMP, keyboard second

**Delivered, except the switcher.** This section used to open "our menu bar is a
picture of a menu bar", and it was: titles drawn for nobody. Phase 9 and Phase 10
made it the WIMP contract Jaguar had — every command in one place, found with a
mouse, then bound to a key — and extended it to applications that have never
heard of us.

| | Where it landed |
|---|---|
| Menus in the bar | ✅ **The menu protocol** (Phase 10): an application publishes its vocabulary over `CurrentIPC`, the bar routes activation back, submenus open by pointer and keyboard. GTK menus arrive through `abyss-dbus` and follow the application's own changes (P10.6–P10.9); Qt's were removed with the one-toolkit rule |
| Global key bindings | ✅ the keybind table in `undertow`, config-driven (P9) |
| Copy and paste | ✅ `wl_data_device` in `Surface`, the selection arbitrated in `undertow` (P9). *It had been broken for everyone, foreign apps included — PHASE9 §4.1* |
| Drag and drop | ✅ to the Trash, a Finder window, a Dock tile (P9) |
| Contextual menus | ✅ the Finder's items and background, the desktop, Dock tiles — the same commands the bar shows (P10.8) |
| Undo | ✅ per window, in the toolkit (P10) |
| Application switcher | The Cmd-Tab binding exists; **its UI is Phase 13's**, drawn with the island switcher |

### 4.3 Thesis 3 — traditional window management

**Delivered, except the part that beats tiling.**

| | Where it landed |
|---|---|
| Click to focus, raise | ✅ `Seat.focus` |
| Interactive move and resize | ✅ the title-bar drag sends `move`, the frame's edges send `resize`, and `undertow` answers both (P9.4). *Until then no Aqua window could be dragged by its title bar* |
| Zoom / minimize / fullscreen | ✅ handled (P9.4); a minimised window keeps a 1 Hz clock and is told it is suspended (U.2, T.3) |
| Remembered positions | ✅ `WindowPlaces` |
| **Decorations for foreign windows** | ✅ server-side decorations with the Aqua frame (P9.5) — every foreign window is Mac-shaped |
| Multi-monitor | ✅ several outputs, `wlr-output-management`, the Displays pane (P14.7). Mirroring and display-off are not offered |
| Snapping | ✅ drag-to-edge halves — the one tiling affordance worth offering |
| **Islands, Shoals, Ebb** | **Phase 13.** Workspaces, window sets, an Exposé equivalent — the largest piece here, and the part of thesis 3 that beats tiling; §7. **M–L** |

### 4.4 Thesis 4 — agents in jails

**Zero agent code, zero jail code — and our strongest position.** Everyone else's
agent story is a CLI running as you, over your entire home directory. We built
the alternative and proved it: `abyss-portal` hands out **descriptors, not
paths**, and PHASE7's demo client calls `cap_enter(2)` first, so it has no
filesystem at all. An agent whose only reach into your data is a descriptor a
human granted by clicking a file in the Finder is a claim nobody else can make.

Much of what follows is adapted from `GHOST`, a Plan 9 agent design read on
2026-09-05, the way §2 adapts Omarchy: **the mechanism does not transfer and the
arguments do.** Plan 9 gives an agent a per-process namespace for the price of a
syscall; we have `jail(2)`, `nullfs` and Capsicum, which are coarser and are
*not* free per task. Where that changes a cost, it is said so.

#### The confinement is the grant

**This document used to propose the wrong thing.** It asked for "This agent wants
to read `~/Documents/foo.txt` — Allow / Deny / Always" as the human in the loop.
That is the model `GHOST` refuses in one line — *an agent that asks before every
action trains a person to say yes; a sandbox that cannot name a file cannot touch
it, and needs no popup* — and it is right. We built the capability substrate
first and then wrote the popup down anyway. The grant already happened, at the
moment a person clicked a file in a Finder; a dialog stacked on top of a
descriptor re-introduces precisely the fatigue the descriptor exists to remove.

So the requester is for the short, **enumerated** list of actions confinement
cannot express, and nothing else:

1. the first write, in a session, to a file that already exists;
2. anything in the `admin` class;
3. egress to a host not already granted;
4. a spend that would cross the budget (below).

Everything else is inside the jail or impossible. **A list that grows is the
design failing; a list that stays at four is the design working.** The surface is
a sheet and a Preferences pane — thesis 2 still applies to thesis 4 — but it is a
sheet a person sees a few times a session, not a few times a minute.

Missing:

- **Jail plumbing, and a class is data.** Nothing in `de/` calls `jail(2)`.
  `Anchor` supervises processes; it does not confine them. Needs jail lifecycle,
  a filesystem story (a private ZFS dataset per agent is cheap — we already
  install ZFS), and `vnet` where there is network. **What a jail contains should
  be a declared class, not code**: `edit` gets one directory and the toolkit,
  `debug` gets one process's view and the debugger and no other, `admin` gets
  what a person names and asks first. That is a `PoolConfig` table, which is a
  mechanism we already have. **The cost that does not transfer:** a jail is a
  process tree, a devfs ruleset and a dataset, so one per prompt is not
  affordable the way a mount table is — expect pooled, long-lived jails per class
  rather than one per task, and say so before someone designs for the cheap case.
- **The vocabulary the agent acts through.** Not a tool API of its own — §5.5.
  This was the single largest dependency thesis 4 had, and **Phase 10 built it**
  for another reason entirely: `abyssmenu` already asks an application what it can
  do and invokes its verbs, with nothing written per application.
- **Where the model runs: on this machine, by default.** A local model is the
  **preferred** backend in the current design, not a fallback waiting for better
  hardware. It is the only choice consistent with the rest of this section: an
  agent whose every prompt leaves the machine is exactly the reach confinement
  exists to remove, and a local model needs no credential, no egress grant, no
  spend budget and no network — it works on a laptop on a train. **A person may
  still use whatever provider they want** — a remote API, their own server — by
  pointing the same wire (below) somewhere else; that is their decision, and the
  desktop does not make it harder. It is not the default we ship.
  **What makes the default practical changed.** This used to say "no local GPU
  inference on FreeBSD — no ROCm, no CUDA", and both are still absent. But ports'
  `ggml`, the library under `llama-cpp` and `ollama`, builds with its **Vulkan**
  backend on by default (latest branch, checked 2026-09-30), and the RX 6750 XT is
  RDNA 2 under Mesa's RADV. So GPU inference on the bring-up machine no longer
  waits on FreeBSD gaining a vendor stack. *Availability is checked; nothing has
  been run* — a model answering under `undertow` on the 12700KF is the test that
  matters (§2.43), with CPU inference from the same packages as the floor.
  **We do not write an inference engine** (§10) — `GHOST` budgets four thousand
  lines for one because Plan 9 has no ports tree; we have one.
- **One wire format, local and remote alike.** The interface between the desktop
  and a model is the Messages API's JSON whichever end answers it. This is what
  lets local be the default without taking the choice away: local or remote,
  CPU or GPU, is a *backend swap instead of a redesign*, and nothing above the
  backend learns which one answered.
- **The credential, which is a design and not a gap.** "A credential store we do
  not have" was the wrong framing. The requirement is `factotum`'s principle: the
  key lives in a process **outside** the jail, egress goes through something that
  adds the header, and the agent cannot read the credential because the thing
  holding it is not in its namespace. Stated that way it is a small daemon and a
  `CurrentIPC` channel, not a keychain we have to invent first. The default
  local backend needs none of it; the daemon exists for the person who chooses a
  remote provider.
- **The budget is a line.** Tokens or currency per session, counted as it spends,
  stopping at the next tool call with the reason where the person can see it.
  This is §8.5's rule in another dimension — *a budget, not a boolean* — and the
  same instinct that gates effects on C1's miss budget should gate an agent on a
  number the user set.
- **Off is one file.** Present, and the agent does not start: no menu item, no
  chord, no spend indicator, no process parked on a crash, and **the rest of the
  desktop does not know the difference.** For an OS whose thesis 5 is "it just
  works", an agent that cannot be removed is a liability, so this is a rejection
  and it is in §10.

#### What it is for, and how it is tested

- **The agent application** is a chat window: WIMP-native, and it needs nothing
  from §4.1. But a chat window is not an *answer* to what an agent is for on a
  desktop. The concrete one, taken from `GHOST` (which took it from Omarchy):
  **a crash is handed to the agent from the notice that says it crashed.** The
  "application quit unexpectedly" notification carries a button; the click starts
  a session in the `debug` class, on that process and no other. It reads and
  reports and writes nothing. It needs no network and no menu vocabulary, which
  makes it the first task rather than the last.
- **State is shown where a person is looking.** Working, waiting, idle — on the
  Dock tile and in the menu bar, and once §7 exists, **on the island switcher**,
  so an agent waiting for a yes on another island is visible without hunting for
  its window. Thesis 4 and §7 have no relationship in this document today, and
  this is it. It is also §4.5's rule again: a state nobody can see is a lie.
- **The transcript is append-only, and it is a file.** Not a feature of the grant
  UI — the session *is* the log, it outlives the process, and a person can read
  or grep it. There is a technical reason as well as an audit one: the frontier
  models refuse an edited history, so a transcript that is rewritten is a
  transcript that stops working.
- **Pixels are the fallback, never the way in.** `Surface` already has
  `screencopy` and we ship `abyssgrab`, so an application with no published
  vocabulary can still be read as an image. It is slow, costly and blind to what
  the program knows about itself, and it stops the day that application publishes
  a vocabulary. Driving a desktop by screenshot when the desktop can describe
  itself is the industry's answer and we should say we are not taking it.
- **A stub backend is how any of this is testable.** Canned replies, tool calls
  included, answering the same wire format. Every check here — the class
  boundary, the four requesters, the budget stop, the transcript — then runs in
  the build VM with **no model on disk and no network**, which is §2.43's
  discipline and the only way this phase gets tested before it gets hardware.
  And the check that makes the sandbox check mean something is §2.37's: **one
  control, a jail deliberately built without the restriction, so we can watch the
  check fail.** A confinement test that has never failed is a comment.

**What this phase does *not* cost us.** `GHOST` spends roughly half its total
budget on a TLS 1.3 client, an X.509 parser and an HTTP client, because Plan 9
has none. We have base OpenSSL and a ports tree, and we are not writing an
inference engine either. Most of that design's line count is not our line count —
which is worth knowing before this phase is estimated from the outside.

Ordering consequence: thesis 4 depended on thesis 5's network, thesis 2's
preferences and, most importantly, **thesis 2's menu protocol** (§5.5). All three
now exist (Phases 10 and 14). What still stands between here and an agent is
Phase 18's own first half — the jails — which is why it is "jails, then agents".

### 4.5 Thesis 5 — it just works

Still the widest gap, and the least code-shaped — but it now has software under
it and one machine in front of it.

| | Have | Gap |
|---|---|---|
| Machines that boot it | **The 12700KF / RX 6750 XT is the machine** (reaffirmed 2026-09-30). The medium boots there, `amdgpu` binds, `undertow` finds the output and **the Aqua installer is on screen** — PHASE4 §5 steps 1–5. **Nothing is installed on metal**: that machine's only disk is its positive control (PHASE4 §6.6). The Mac Pro is the matrix's second row | Install to a second disk. **C1 fails on metal** — 58 of 300 frames missed, margin pinned at 8 ms — and the per-term breakdown that would say why has not been run (PHASE4 §5.7). Metal work is paused while the USB is in use for the Q8B |
| GPUs | `amdgpu` + **RDNA 2 and Southern Islands** firmware + `i915kms` on the medium; **RDNA 2 proven** on the 12700KF. `undertow` can render on the GPU with linux-dmabuf and explicit sync (proven on Linux; FreeBSD's timeline support unverified) | Intel and AMD are plausible from what the medium carries; NVIDIA is a separate decision. **A hardware support matrix is a deliverable, not a side effect** — and `Fathom` (§6.4) is how people who are not us populate it |
| A second architecture | The Radxa Dragon Q8B (aarch64, SC8280XP): the board boots stock GENERIC, its GPU runs GL ES 3.2 and Vulkan 1.3, display is the firmware framebuffer only ([board notes](../../docs/boards/radxa-dragon-q8b/README.md)) | **Not far enough along for the desktop**, and not the focus. Before it can be a row: **Swift on aarch64** — ports' `lang/swift6` is amd64-only, and the one aarch64 build is a community one, untested on 16-CURRENT — plus display KMS rather than a fixed framebuffer |
| Wifi | ✅ the Network pane joins and forgets networks (P14.5) | **Proven only in the harness**, on a simulated radio. FreeBSD's weak spot and thesis 5's hardest promise: `iwlwifi` covers modern Intel; Broadcom is risk 5 |
| Suspend / lid / power | Energy Saver writes sleep delays and `powerd` (P14.8); displays sleep (U.9) | **The machine never sleeps.** Suspend, lid and battery behaviour are Phase 16. A laptop that does not sleep is not a desktop that just works |
| Login | **nothing** | Phase 16: login window, multi-user sessions, `anchor` per user |
| Preferences that write | ✅ **five panes** — Appearance, Network, Sound, Displays, Energy Saver — through `abyss-settings`, `wheel` checked on every connection (Phase 14). `rc.conf` is no longer the user interface for any of them | The rest of the catalogue's 25 panes are honest pages that say so |
| First run | **nothing** | Jaguar had a Setup Assistant; we boot into a bare desktop. Phase 16 |
| Updates | **nothing** | Phase 17, §6.2 |
| Software | the medium has **no package database** by design; `ports/` in the monorepo is the overlay's first contents (§6.3) | **The desktop itself is not packaged yet**; a builder, a signing key and a mirror are Phase 17 |
| When something is wrong | `SessionPlan.notes`, notifications, `Fathom`'s report | Somewhere the running machine says what failed. §2.45 generalises: a graceful degradation nobody can see is a lie |
| Documentation | good repo docs, no user documentation | A manual is a shipped surface |
| Accessibility | ✅ **the legibility floor** — a theme whose body text fails contrast is refused at load, secondary pairs are warned about with their ratios (P11.10) | That is the down payment, not the story: no screen reader, no keyboard-only audit, no reduced motion |

---

## 5. Cross-cutting gaps

These block several theses at once, which is what made them worth doing first.
Three are already above and are built — **the clipboard** and **the menu
protocol** (§4.2), and **server-side decorations** (§4.3). Five more, of which
§5.2 is decided and §5.5 is built:

### 5.1 The browser — pick an engine, not a browser

We will not write one (§10). Shell size is an illusion; installed footprints from
the FreeBSD 15.0 amd64 repo (measured 2026-09; the base is now FreeBSD `main`,
whose packages come from the *latest* branch, so re-measure before choosing):

| Browser | Shell | Engine + toolkit | Total |
|---|---|---|---|
| badwolf 1.4.0 | 151 KiB | `webkit2-gtk_40` 180 MiB + `gtk3` 80 MiB | ~260 MiB |
| Epiphany 47.7 | 11.6 MiB | `webkit2-gtk_60` 156 MiB + `gtk4` 66 MiB | ~233 MiB |
| Firefox 155.0 | — | self-contained | 339 MiB |
| Chromium 151.0 | — | self-contained | 503 MiB |

badwolf's 151 KiB is marketing. FreeBSD has three engines — WebKit, Gecko, Blink —
and the chrome on top is nearly free, so "fast and minimal" is decided by the
engine and nothing after it.

Also in ports: `firefox-esr` 153.2.0, `luakit`, `midori`, `netsurf`, `dillo`,
`otter-browser`, `nyxt`, `vimb`. Absent: `ungoogled-chromium`, `falkon`, `surf`,
`qutebrowser` — and **`wpewebkit` and `cog`**, with only `libwpe` and
`wpebackend-fdo` 1.12.0 present. That last absence kills the most attractive
option: embedding WPE WebKit under Aqua chrome would mean porting WebKit to
FreeBSD ourselves.

Ruled out by thesis: luakit, vimb and nyxt are keyboard-first (thesis 2); netsurf
and dillo have no meaningful JS (thesis 5); midori 9.0 is 2019-era.

**Recommendation: Epiphany as the default, Chromium available but not default.**
Epiphany is GTK4, so §8's generated theme reaches it; its chrome is the least
un-Aqua of any real browser; it speaks xdg-desktop-portal by default, the path
P8.4 proved; and `--application-mode` with a `.desktop` file is exactly §6.1's
generator input, so web apps become `.app` bundles with no special case.
Chromium's `--app=` is the same mechanism for sites that demand Blink.

**What would flip it:** `webkit2-gtk_*` is at 2.46.6 and `epiphany` at 47.7 —
late-2024 — while `gtk4` is 4.20.4 and `mesa-dri` 26.1.3. The toolkit is current;
the GNOME apps and the engine are about two years behind. A lagging browser engine
is a security liability, and for a system promising "it just works" that outweighs
chrome fidelity. Check the WebKitGTK port's update cadence before committing; if it
has not improved, **Firefox ESR 153** is the better default — an independent engine
with a real security-support model.

*Availability and linkage are verified; nothing was run.* No browser here has been
shown to render a page under `undertow`, which is the test that matters and which
`abyss/tests/live-gtk.sh` is the pattern for (§2.43).

### 5.2 XWayland — decided: no ([PHASE9 §6.3](PHASE9.md))

There is none in the tree, and **§5.1 narrows the question: the browser does not
force it.** Both `gtk3` and `gtk4` link `libwayland-client`, so GTK browsers run
Wayland-native under `GDK_BACKEND=wayland`, and Chromium's port depends on
`wayland` outright — the `libX11` dependency is the other backend being present,
not a runtime requirement.

What remains is the long tail: Wayland-native coverage in ports is real but
partial, and without XWayland some of what a user installs will not run, which
thesis 5 forbids. Against: X clients cannot be given Aqua decorations as cleanly
— they arrive as `wlr_xwayland_surface`, not `xdg_toplevel`, so the decoration
path needs a second branch — and it widens the attack surface.

**Cost is no longer part of the argument, because it was measured.** wlroots is
built with `WLR_HAS_XWAYLAND` on Linux *and* in the FreeBSD VM, `Xwayland` is in
ports, and the live medium grows by **≈6 MiB** once you subtract the packages
`undertow`'s own `ldd` closure already pulls in — on a three-gigabyte image
(PHASE9 §4.4). **Decide it explicitly and write the reason down**, the way the
D-Bus bridge decision was — we took a broker we did not like, scoped it to the
legacy path, and said so. **It was decided, and the other way: no XWayland**
([PHASE9 §6.3](PHASE9.md), which keeps the reasoning, and `live-session.sh`
asserts `undertow` names none of wlroots' XWayland symbols). PHASE9 had
recommended taking it, off by default; this paragraph said so until 2026-09-28,
after the decision. The long tail above is the price, and it is four of the
study corpus's projects ([API-STUDY.md](API-STUDY.md) §2).

### 5.3 What foreign applications look like

`PortalSettings` reported `color-scheme: prefer light` precisely so a GTK dialog
was not dark on a Jaguar desktop — the right instinct, one key wide. It is wider
now: the portal reports the **active theme's** scheme, accent and contrast, plus
the full palette as `org.abyssbsd.palette`, and follows a theme switch live
(P11.10, P14.2); foreign applications get **our cursors** as an XCursor theme
(U.7b); and every foreign window gets the **Aqua frame** (P9.5). What remains is
the widgets inside that frame: a *generated* GTK theme rather than a
hand-written Aqua one, emitted from whatever tokens are active, so a user's own
theme re-skins foreign apps too (§8).

### 5.4 A security model for ordinary applications

The portal protects *our* apps; a `pkg`-installed GTK app runs with the user's
full authority. Jails (§4.4) answer both, which argues for building that substrate
earlier than the agent motivating it.

---

### 5.5 The menu protocol is also the automation surface

**Built, as argued (Phase 10).** The protocol publishes vocabulary, the menu bar
is its first consumer, and `abyssmenu` — something that cannot draw a menu —
describes the Finder, is refused with reasons, and invokes verbs whose results are
checked on disk (`live-vocabulary.sh`). The argument is kept because it is still
the reason for §10's "no second automation surface".

**It was the cheapest decision in this document, and it would have expired.**
Phase 10 was to build a `CurrentIPC` channel over which an application publishes its menu tree and the
bar routes activation back (§4.2). A menu tree is an application's vocabulary in
machine-readable form — which is the same object AppleScript called a
*dictionary*, and 10.2 shipped both the dictionary and the global menu bar
because they are two consumers of one thing.

`GHOST` states the rule as a rejection: **an application has one automation
surface, and the person and the agent use the same one.** What it refuses is a
plugin API per application — COM, AppleEvents as most programs actually shipped
it, editor extension APIs — because each grows a second surface beside the human
one and the two drift.

The consequence for us is an ordering claim §4.4 could not make on its own:

> **Phase 10 is on thesis 4's critical path.** Designed as menus-only — titles,
> items, activation, void — it satisfies thesis 2 and leaves Phase 18 to build a
> second automation surface, which is the thing above that we would be refusing.
> Designed as *published vocabulary, of which the menu bar is the first
> consumer*, the agent's tool list comes for free.

The delta was small and it was only cheap **then**: a verb carries argument types
and a sentence of description; activation returns a result rather than nothing;
and the channel answers a query — *what can you do* — rather than only pushing.
Phase 10's text already said it must land before Phase 15 because every
application built without it has to be retrofitted. This was that same argument
carried one phase further, and it cost a design constraint written down rather
than any code.

Two things fall out, both free:

- **`Aqua` serves the contract.** Every application already builds a menu
  definition to hand the bar; publishing it makes every Aqua application
  scriptable the day it links, with nothing written per application. `GHOST`'s
  version of this — the toolkit's named gadgets *are* the vocabulary — is the
  same observation about a different toolkit.
- **`abyss-dbus` serves it for foreign applications too.** §4.2 already has us
  translating `org.gtk.Menus`/`org.gtk.Actions` into our bar (P10.6–P10.9).
  That is a vocabulary for every GTK application on
  the machine, through the bridge the bar already uses. **One bridge, two consumers** — the
  menu bar and the agent — which is a better return than either justifies alone.

And it is the reason §4.4's pixel fallback stays a fallback: an application that
can describe itself is never driven by screenshot.

## 6. Four proposals

### 6.1 Synthesize `.app` bundles from `.desktop` files

**Best ratio of payoff to lines in this document.**

The Finder already reads `.app` bundles — `Contents/MacOS/Foo`, icons from
`Contents/Resources`, including PNGs extracted from `.icns` (P2.11). Ports install
`.desktop` entries and icons under `/usr/local/share`. A generator that walks them
and writes bundles into `/Applications` gives us, for a few hundred lines: every
installed port appearing as a Mac-shaped application in the Finder; Dock tiles
with real icons and names; something for Recent Items to contain; and **web apps
as first-class applications for free**, since Omarchy's Chromium `--app=` trick is
just another generated bundle.

Run it as a `pkg` post-install hook and the desktop stays current by itself.

### 6.2 `abyss update` should be a boot environment

We install to `zroot/ROOT/default` and set `bootfs` (`de/install/Steps.swift`), so
**boot environments already work on every machine we install**, and `bectl` is in
base.

The update story follows, and beats `omarchy-update`: clone the BE, update into
the clone, activate, reboot. If it does not come up, the previous environment is
still in the loader menu. An opinionated OS that changes its defaults after
release needs migrations to be safe, and ZFS makes ours atomic and reversible in a
way a rolling config merge cannot be.

The GUI is Software Update — a sheet, a progress bar, a Restart button. The
privileged half is `abyss-install`'s exact shape, already built and shipped once.

### 6.3 A FreeBSD fork, FreeBSD's ports, and an Abyss overlay

**Decided, and revised on 2026-09-30: AbyssBSD is a fork of FreeBSD, and will
likely always be one.** Upstreaming is worth doing and we do it
([UPSTREAMING.md](../../docs/UPSTREAMING.md)), but review moves at FreeBSD's pace
and we move faster. The fork is where our work ships first; upstream gets it when
review allows, and every change that lands there is one we stop carrying. The
base is FreeBSD `main` (16-CURRENT), in the monorepo as `src/`.

This section used to say the opposite — *"we are a desktop on FreeBSD, not a
derivative that has to answer for `openssl`"* — and listed what would move us to
owning the OS: base built differently, and patches we carry indefinitely. Both
fired: the board's new drivers and LinuxKPI changes are in `src/` now, with the
kernel's `allow.rtprio` and thesis 4's jail work planned behind them. So the question stopped being *whether* to own the base and became
**how to keep owning it cheap**. The answer is the same discipline this section
always had, applied one level down: **the fork carries what we wrote, plus the
minimum change to FreeBSD needed to make it work, and it tracks `main` rather
than diverging from it.** A fork that rebases is a patch set; a fork that drifts
is a second operating system, and we are not staffed for one.

**Packages still come from FreeBSD's ports**, and that is still where thesis 5
gets its breadth for nothing: tens of thousands of ports, a security-advisory
pipeline, mirrors we do not run. The **overlay** (`ports/` in the monorepo,
`poudriere bulk -O abyss`) carries what is ours — the desktop itself (`undertow`,
`anchor`, `abyss-portal`, `abyss-dbus`, `abyss-settings`, the Aqua applications,
the installer), the generated GTK theme (§5.3, §8), the `.desktop` → `.app`
generator and its `pkg` hook (§6.1), and `Fathom` (§6.4).

**The overlay's discipline is unchanged: what we wrote, plus the minimum patched
upstream needed to make what we wrote work.** Every rebuilt upstream port is a
maintenance obligation that does not end — rebuild WebKit and we own WebKit's
security response. Its first contents are that obligation made visible: Mesa,
libdrm, drm-kmod and GPU firmware, patched for the Q8B's GPU. Each is accepted
because the board cannot work without it and each has an upstreaming path; none
is a precedent for carrying a port because we would like it newer. §5.1's
WebKitGTK is where that rule gets tested next.

**What the fork costs, stated so it gets paid on purpose** (MIGRATION §5):

- **A release pipeline is ours.** `buildworld` and `buildkernel` from `src/`, a
  poudriere jail made from that world, the overlay's bulk build, and images for
  amd64 and arm64. FreeBSD's release engineering no longer does this for us.
- **CURRENT has no quarterly branch.** On `main`, FreeBSD's packages are the
  *latest* branch only, so a port can move under us any day. §6.2 is what makes
  that survivable, and it is why the update mechanism and the base decision
  belong together.
- **The toolchain follows the base.** The build VM still runs 15.0-RELEASE, and
  `lang/swift6` has not been checked on 16-CURRENT; both are MIGRATION §5.

### 6.4 `Fathom` — the medium tells you whether this machine works

**Built as Phase 12**, all but its Aqua view (P12.3): the medium runs it, it
writes its report to the ESP, and `docs/reports/` holds the first row, from the
12700KF. What follows is the design it was built from.

Today the live medium is a delivery mechanism, not a live CD: it boots into the
Installer, and if `amdgpu` does not bind the user gets a headless session or a
black screen with no explanation. A live medium's first job is to answer "will
this work here?" before anyone commits an NVMe.

**The spec is already written.** [PHASE4 §5](PHASE4.md) is a six-step ordered
checklist — stick boots, multi-user reached, `amdgpu` attaches, `undertow` finds an
output, the installer is on screen, then the numbers — where each step's failure is
a different problem. It exists because a person works down it by hand on the one
machine we own. Fathom is that checklist as a program, which is what lets it run on
the machines we do not own.

| Probe | Source | Status |
|---|---|---|
| Boot path — UEFI vs BIOS, ESP found | loader environment | new |
| Modules bound — `amdgpu`/`i915kms`/`drm` | `kldstat`, `dmesg` | new, string parsing |
| GPU and display — `/dev/dri/card*`, connector, mode, refresh, EDID | `undertow` logs the backend and mode it chose | mostly exists |
| **C1 measured against the real vblank** | metronome + flight recorder | exists, unused for this |
| Input — keyboard, pointer, touchpad | `Seat` / libinput | exists |
| Disks — controllers, NVMe, what is installable | `probeMachine()` / `inventory()` | built and tested |
| Network — interfaces, link, DHCP, wifi recognised | — | new, and thesis 5's weak point |
| Audio — OSS device present and settable | `Vents.Volume` | exists |
| Power — battery, ACPI, suspend | `Vents.Battery` | partly exists |
| CPU, memory, machine identity | `Vents.Sysctl` | exists |

**The differentiator is measurement, not detection.** Every live CD can say the
GPU bound. Ours has a metronome and a flight recorder, so it can run C1 against the
real vblank for a few seconds and report that this machine holds the frame contract
— or misses by how much. No other installer tells you your frame budget before you
install.

**It must be readable on a machine too broken to draw it.** P4.3 already decides
where the live session runs by whether `/dev/dri` exists; Fathom uses the same test
at two fidelities — an Aqua window when there is a display, a text report on the
console when there is not. A report that cannot survive the failure it reports is
not a report.

Two consequences. **It gates the install:** as a spoke in the hub it can refuse in
P5.4's attention styling before Install is reachable — no GPU, no installable disk,
no network device — and `DiskInventory` already does the disk half. **And its
output populates §4.5's hardware matrix:** we cannot buy every machine, so the
medium is the instrument, and a report the user can save to the stick and send back
turns everyone who tries AbyssBSD into a data point.

**The trap to design against (§2.37): a probe with no positive control measures
nothing.** A Fathom reporting "GPU: ok" on a machine with no GPU is worse than
none, because it converts an obvious failure into a confident lie. Every probe
needs its negative case exercised — and the build VM, with no `/dev/dri`, no
battery and no AMD GPU, is an excellent place to check that the checks can fail.

One program, three uses: the spoke that gates the install, a standalone app for the
user who wants to try before committing, and — once installed — the System Profiler
this desktop lacks. To *fathom* is to measure a depth and to understand it; it does
not collide with the Sound pane the way *Sounding* would.

**Cost: M.** Most probes are pure functions over command output, `Probe.swift`'s
pattern, testable with no hardware. The Aqua view is a list, the console view is
text, and the C1 run is a bench we own.

---

## 7. Islands, Shoals and Ebb — how thesis 3 beats tiling

**Islands** are Spaces, **Shoals** are the Stage Manager idea done properly, and
**Ebb** is Exposé. §7.6 is the naming.

### 7.1 The argument

A tiling window manager solves two problems at once:

- **(a) Many windows, none lost** — where did that thing go, and how do I get
  back to it without hunting.
- **(b) Separate task contexts** — the four windows for this job should not be
  interleaved with the six for that one.

Tiling answers both with *automatic layout*, which is a bad answer to (a) and an
accidental one to (b). Bad for (a) because it solves "I cannot find my window" by
continuously moving your windows — taking away the position you would have used
to remember it. Accidental for (b) because workspaces in a tiler are a bolted-on
numbered list, not a model of what you were doing.

**Islands answer (b) directly, Shoals answer (a) directly, Ebb answers the
momentary form of (a), and none of them imposes layout.** All three leave
placement with the user, which is thesis 3's whole content.

So they are not exceptions to thesis 3 — **they are how it wins.** Traditional
window management *plus recall and grouping* is strictly more than a tiler offers
and never moves a window you placed. Without them, thesis 3 is only true for
people who keep six windows open, and concedes every heavy user to the tilers.

### 7.2 The objection is transition speed, which is an implementation complaint

What people dislike about Spaces and Mission Control is not the model. It is that
a switch is a several-hundred-millisecond animated slide you cannot outrun,
interrupt or re-target — input reaches the new space only once the animation has
finished having its opinion. Stage Manager compounds it by rearranging windows on
arrival.

That is a latency bug wearing a design's clothes, and it is the class of bug this
project is equipped to refuse. We have a metronome, a flight recorder and five
contract numbers that gate the build, so the answer is a **sixth**:

> **C6 — an island switch is committed within 2 frames of the input that asked
> for it, and any animation is decoration that can be skipped, interrupted and
> re-targeted without delaying the commit.**

Four rules follow, and they are the whole design:

1. **Commit first, animate second.** Active island, focused window and keyboard
   focus all change on the frame the request arrives; animation is a transform
   applied to state that has already changed. Never gate input on an animation.
2. **Interruptible and re-targetable.** Asking for island 3 mid-slide to island 2
   re-targets. It never queues.
3. **Budgeted and measured.** Animation ≤ ~150 ms, skippable by config, commit
   path on the flight recorder. `undertow bench-islands` joins the C5 gating lane.
4. **Free when idle.** The island predicate must not cost a measurable frame when
   nobody is switching — see §7.4.

### 7.3 What each one is

**Islands** — named workspaces, per display. A `Toplevel` carries an island tag;
the scene latches only tags belonging to the display's active island. Layer
surfaces (menu bar, Dock) are furniture and do not travel. Wallpaper is per-island
and free, since `Wallpaper` is already config-driven. Per-display rather than
global, because that matches a physical desk and because Apple's toggle between
the two is the most confusing switch in the OS — pick one, ship one.

**Shoals** — a group of windows recalled together. Apple's Stage Manager is
disliked for four fixable reasons:

| Stage Manager | Shoals |
|---|---|
| Groups by heuristic, guesses wrong | **Sets are explicit.** Nothing joins by itself |
| Moves and resizes windows on recall | **Recall restores the positions `WindowPlaces` already remembers.** Placement is never taken |
| The strip steals space and auto-hides unpredictably | Summoned or pinned, the user's choice, remembered |
| Fights Spaces | A shoal lives *on* an island. Islands separate contexts; shoals recall a working set within one |

**Ebb** — every window on the island, scaled down and laid out so none overlaps,
one click to pick. Three scopes: this island, the whole archipelago, this
application. Nothing is moved — the layout is a *view*, and dismissing it puts
everything back, the way the tide comes in.

**The Dock is the fourth member of this set.** Once a window can be somewhere you
are not, running-app indicators must reach across islands — click an app running
on island 3 and you go there. That is the property that beats tiling: a window is
never lost, because something on screen always knows where it is.

### 7.4 What it costs, which is little

A dividend of a decision made for another reason. `undertow` does not use
`wlr_scene`; it has its own structure-of-arrays scene, built that way so C1 and C2
were affordable (`de/undertow/Scene.swift`). That structure is exactly right here:

- The scene is parallel arrays of `x`, `y`, `w`, `h` plus a texture handle,
  latched from `Compositor.mappedToplevels` and walked linearly. **An island is a
  tag on `Toplevel` and a predicate in the latch** — no new data structure, and
  stacking order is already paint order (`raise` is a move-to-end).
- **`SurfaceScene.render` already builds a `dst_box` with arbitrary width and
  height**, so scaling a window to a thumbnail is *already implemented*. **Ebb and
  the Shoals strip need no new rendering path.**
- **A slide is an x-offset added during the latch** — one number per frame applied
  to a loop that exists. No animation framework.
- **The one genuine addition is alpha**, for cross-fades and for dimming behind an
  Ebb. `wlr_render_texture_options` carries a member we never set; the SoA gains
  one array.

| Piece | Where | Size |
|---|---|---|
| Island tag, predicate, per-display active island | `Compositor` | **S** |
| Transition offset, alpha array, the C6 bench | `Scene`, `Metronome`, `FlightRecorder` | **S–M** |
| Ebb layout (non-overlapping, stable, animated) | new | **M** |
| Shoals model — sets, membership, recall via `WindowPlaces` | `Compositor` + `PoolConfig` | **M** |
| Aqua surfaces: the strip, the island switcher, the Ebb chrome | `Aqua` + a layer surface | **M** |
| Dock and menu-bar integration across islands | `Dock`, `MenuBar` | **S–M** |
| Key bindings to drive it | §4.2's missing table | **S** |

**The honest blocker:** none of this is reachable without the global keybind
table. An island switcher with no keyboard route is a toy, which is why §4.2's
small missing piece stops being optional.

**One caveat from the code:** `Compositor.sendFrameDone` walks every *mapped*
toplevel, so windows on an inactive island would keep drawing. For the Shoals
strip and a live Ebb that is wanted; for an island nobody can see it is waste. The
rule should be explicit — frame callbacks follow *visibility*, not mapping — and
it wants a test, because getting it wrong is invisible until something is slow.
*Half of it exists:* a minimised window gets a 1 Hz clock and xdg-shell's
`suspended` state, and an Aqua window that is told it is suspended draws nothing
(U.2, T.3, `live-hidden.sh`, `live-suspend.sh`). A window on an inactive island is
the same case, and should get the same treatment.

### 7.5 Fidelity

10.2 had none of their ancestors: Exposé arrived in 10.3, Spaces in 10.5, Stage
Manager in 13. PLAN.md decision 2 settles what that means:

> **The goal of 10.2 is aesthetic, not functional.** The version number names a
> visual language we are cloning, not a feature set we are frozen at.

A capability 10.2 never had is in scope; drawing it in somebody else's vocabulary
is not. An Ebb in pinstripe, gel and Aqua shadows is faithful in the way that
matters.

**The boundary is a rejection, which is what makes it useful:** brushed metal is
out, and every successor texture with it — Leopard's dark unified title bars,
Lion-era skeuomorphism, the flattening from Yosemite on — **because they are
ugly.** The pinstriped/white Aqua window is the only window we ship, and `Theme`
is the one place allowed to have an opinion about it.

### 7.6 The names

The engineering vocabulary is a water column — `abyss`, `undertow`, `tide`,
`current`, `pool`, `vents`, `anchor`, `reef`, `shmring` — and these three take
names from it rather than Apple's, since Exposé and Stage Manager are somebody
else's feature names and what we are building differs from both.

**Islands** — separate places, each with your things on it, and you travel between
them. The most legible metaphor for a workspace, which matters because this name
is user-facing.

**Shoals** — a shoal is a group that moves and is recalled together, which is
exactly the object. (`WindowSet` in the model.) *Flotilla* says the same and is
longer.

**Ebb** — the tide goes out, leaves everything that was covered in plain sight,
and comes back. Momentary, revealing, self-undoing. Runner-up *Muster* captured
the action better and the return worse; *Chart* fit best semantically and lost
because Activity Monitor will be full of charts.

---

## 8. The theme system — ship an opinion, do not compile it in

**The principle is bigger than theming:** *an opinionated OS ships a strong
default; it does not enforce it.* Omarchy is opinionated **and** easy to re-skin,
which is part of why people adopt it. A desktop that cannot be re-skinned is not
more opinionated, just less finished, and "we are a faithful clone" is a reason to
make Jaguar the **default**, not the only thing the code can express.

**10.2 is the default we ship. Nothing in the architecture may prevent someone
building a mid-90s retro-cyberpunk theme or a modern GPU-effects extravaganza.**

**And we ship one of those ourselves, because otherwise the claim is untested.**
See §8.7: `Trench` is the second theme, and it exists as the format's positive
control rather than as the start of a catalogue.

**Built as Phase 11** (2026-09-25; [PHASE11.md](PHASE11.md)): layers 1–3 — tokens
in `theme.ini`, widgets and chrome as draw lists, type roles, icons and cursors as
data — with Jaguar re-expressed byte-identical under the golden gate, `Trench`
drawn by the same interpreter, and the legibility floor enforced at load. A theme
switches while the desktop runs (P14.2). **Still open:** layer 4 (effects, which
wait on a real vblank — Phase 4), layer 5 (the shell presenting menus another way),
and the generated GTK widget theme (§5.3). The rest of this section is the
argument it was built from; its numbers are the ones that justified doing it
early.

### 8.1 The tree was already the right shape

- **`de/aqua/Theme.swift` — 141 lines of `public static let`.** Colours, metrics,
  two font properties. A token table already; just compile-time and
  non-overridable. **192 call sites across 14 files.** *(Re-measured
  2026-09-25: `Theme` lives in `de/aquadraw`, with 253 call sites across 16
  files. Around it are 83 hard-coded colours, 710 cairo calls that bypass
  `Draw`, eight metrics enums, and icons written as Swift — PHASE11 §1.)*
- **`de/aqua/Drawing.swift` — `Draw`, 26 static functions:** rounded rects and
  their top/bottom variants, gradients, pinstripe, focus ring, traffic lights, gel
  button, text field, checkbox, radio, slider, pop-up, progress bar, scroll
  track/thumb/arrow, segmented control, tabs, group box, text.

**`Draw` is a theme engine with exactly one implementation compiled into it**, and
those 26 primitives are the whole of Aqua. We do not have to invent a drawing
grammar — we have to notice we already wrote one.

### 8.2 Four layers, because "theme" means four things

| Layer | Controls | Lives in | Third party? |
|---|---|---|---|
| **1 — Tokens** | colours, metrics, radii, fonts | `Theme` as an instance loaded through `PoolConfig` | Yes, trivially |
| **2 — Widget drawing** | *how* a button is painted — gel vs. flat vs. bevelled bitmap | a declarative draw description, interpreted by `Draw` | Yes — §8.3 |
| **3 — Chrome & layout** | title-bar height, control placement, geometry | same format, plus metrics | Yes, within §8.4 |
| **4 — Compositor effects** | blur, transparency, shadows, transition animation | `undertow`, **not** the toolkit | Yes, but budgeted — §8.5 |
| **5 — Shell layout** *(added 2026-09-25)* | how menus are presented (global bar, NeXT docked menu and pop-up at the pointer, tear-offs), which edge the Dock takes, what the top bar shows | the shell's components, presenting Phase 10's menu vocabulary | Yes, within §8.4 — its own phase after 13 |

**Layer 5 exists because the first real second theme needed it.** The Plan Neo
chrome study (PHASE11) has no global menu bar. Its menus are NeXT's: docked,
popped up at the pointer, and torn off. Phase 10 made menus data, so that is a
second *presenter* of one vocabulary, not a second menu system, and it is what
lets the rule in §8.4 be about reachability rather than about one bar.

Layer 1 alone gets "Aqua in different colours", which is not what was asked for.
**A 90s cyberpunk theme needs layer 2** — bevelled bitmap chrome is not gel with
the hue rotated. **"GPU effects nonsense" is entirely layer 4** and does not touch
the toolkit.

### 8.3 A theme is data, not code

The obvious layer-2 implementation is a Swift protocol with a dylib per theme.
**Reject it.** That loads third-party code into every application process, in a
project whose thesis 4 is about confining code and handing out descriptors instead
of authority. A desktop where installing a theme can keylog every window is not
one we get to ship after writing PHASE7.

Instead, **a declarative draw description** in the vocabulary `Draw` already has:
filled and stroked rounded rects, gradients, 9-slice images, text runs, insets and
offsets — parameterised by layer-1 tokens and widget state
(normal/hover/pressed/disabled/focused). It can produce bevelled 90s chrome from
9-slice PNGs, and it cannot execute anything.

**The check that keeps the format honest (§2.43, §2.45): the shipped Aqua theme
must itself be expressed in the theme format.** If Jaguar needs a back door no
other theme can use, the format is wrong and we find out immediately. `AquaDemo`
already renders scenes to PNG, so the regression gate is a golden-image diff —
pixel fidelity as a *test*, not a hope.

**That check is necessary and not sufficient**, which is what §8.7 is for: the
format was written by someone looking at Aqua, so Aqua fitting it proves less
than it appears to.

A theme that genuinely needs code is then a **port**, trusted like any other
package, not a file you download and double-click.

### 8.4 What a theme may not break

Permissiveness is safe only if the floor is explicit. A theme changes how things
*look*; it may not change whether they are *reachable*.

- **The interaction grammar (thesis 2).** Every command stays mouse-reachable
  **from one persistent, discoverable place**. No hiding a close control or
  deleting focus rings. Every control stays focusable. *(Amended 2026-09-25,
  PHASE11 §6.1: this read "no removing the menu bar", which forbids NeXT's
  docked menus — a design that keeps every command one click from where you
  are. The property is reachability, not one particular bar, and layer 5 may
  present it differently. A theme that leaves some command with no menu at all
  still fails.)*
- **The frame contract (C1–C6).** §8.5.
- **A legibility floor** — minimum contrast and hit-target size, checked at load,
  refused with a reason. We had **no accessibility story at all**; this is the
  cheapest down payment on one. *(Shipped in P11.10, as scoped in PHASE11 §6.2:
  body text that fails its surface is refused; secondary roles are warned about
  with the pair and the ratio. The Plan Neo study flagged two failing pairs of its
  own, so the floor's first case was a real design.)*
- **No code.** §8.3.

### 8.5 Effects are a budget, not a boolean

Layer 4 collides with the one thing this project has that others do not: a frame
contract with a meter. **A theme *asks* for effects; the compositor grants what
fits.** Blur, transparency and transition animation are declared with a cost;
`undertow` enables them while C1's miss budget holds, degrades them when it does
not, and the flight recorder records that it did. Preferences shows a line saying
what got turned down and why.

Every other desktop makes effects a checkbox and lets you discover the frame drops
yourself. This lets us say yes to the extravagant theme without lying about
performance or refusing on principle — and it inherits §7.2's rule: **an effect
may never delay a commit.**

### 8.6 Cost, risk, timing

*Status: every row below is done except layer 4 and the generated GTK theme.*

| Piece | Size |
|---|---|
| `Theme` statics → an instance, 192 call sites (needs an ambient current-theme, not a threaded parameter) | **M**, mechanical, large diff |
| Declarative format + loader over `PoolConfig` | **M** |
| `Draw`'s 26 primitives → interpreters of it | **M** |
| Re-express Aqua *in* the format, gated by golden-image diff | **M** — the pass that proves the design |
| Generated GTK theme + settings-portal wiring (§5) | **S–M**, and it deletes work we would do by hand |
| Layer 4: effect declarations, budget arbitration, the recorder line | **M**, waits for Phase 4's real vblank |

**Risks.** *Fidelity* — a tokenised, interpreted Aqua must stay pixel-identical;
the golden-image gate makes that a test rather than an argument, which is the only
reason it is safe to attempt. *Performance* — interpreting a draw list costs more
than straight-line cairo; the toolkit is not on C1's path but is on
input-to-photon, so bench it. *Scope creep* — this kind of system grows a scripting
language if nobody stops it; layer 1 first and ship it, layer 2 second, layer 4
after Phase 4.

**Timing: before the application layer grows.** There are 192 `Theme.` call sites
today, and every app in §4.1 adds more. Doing this at 192 is far cheaper than at
six hundred — enough to move it ahead of most of §4.1.

### 8.7 `Trench` — the second theme, and why there has to be one

**A theme engine with one theme in it is §2.37's probe with no positive control.**
Re-expressing Aqua in the format (§8.3) cannot fail in the way that matters,
because the format was written by someone looking at Aqua. The only test that can
fail is a theme that shares none of Aqua's assumptions and still comes out of the
same interpreter with no code path of its own.

So we ship a second one. **`Trench`** — 90s skeuomorphic cyberpunk, drawn from
**AmigaOS MUI**, the **SGI IRIX Interactive Desktop** and **NeXTSTEP**. The three
sources are not a mood board; each breaks a *different* Aqua assumption, which is
the whole reason for picking three:

| Source | What it contributes | The assumption it breaks |
|---|---|---|
| **AmigaOS / MUI** | hard bevelled chrome, chunky 3D frames, widget geometry configurable to a fault | that a control is a rounded rect with a gradient. MUI's are bevels and 9-slices, and **layer 2** has to express both or it is not a format |
| **SGI IRIX / Motif** | the industrial register: deep insets, scheme-driven colour, the engineering workstation | that a theme is a *palette*. IRIX schemes move geometry and shading together, which is what stops **layer 1** from being mistaken for the whole job |
| **NeXTSTEP** | dark, heavy, monochrome with one accent; scroll knobs and title bars that are nothing like Aqua's | that chrome *layout* is fixed. This is what makes **layer 3** real rather than decorative |

**Jaguar stays the default and stays the product.** `Trench` is the proof the
engine is an engine — and it is also the cheapest way to find out that layer 4's
effects and §8.4's legibility floor mean something, since a dark high-contrast
theme exercises both differently.

**Two themes is not a catalogue**, and §10's refusal is unchanged: what we will
not do is curate a *pack* of looks and carry the churn of keeping it current. Two
is the number that makes the format testable. The name is from the same water
column as everything else here; runner-up was *Hadal*.

---

## 9. What this does to the roadmap

**Phase 4 stops being the last phase.** Under thesis 5 it is the *first hardware
bring-up*, and its deliverable grows a second half: not only "one machine works"
but "here is the probe and the matrix that says what else does".

**That argument was taken literally on 2026-09-05.** Bring-up moved off the Mac
Pro onto an i7-12700KF / RX 6750 XT that already runs FreeBSD 15.0, and the Mac
Pro became the matrix's second row rather than the phase's gate (PHASE4 §1.1).
The unanswered `si_support` question did not get answered — it stopped being able
to stall the project, which is what a matrix is *for*. The retarget also bought a
**positive control**: on a machine where every layer below ours demonstrably
works, a black screen means us (PHASE4 §1.2).

**It holds as of 2026-09-30.** The distribution moved into a monorepo on a FreeBSD
`main` fork (§6.3), and that monorepo also carries the Radxa Dragon Q8B's board
work — a second architecture, done on another machine. **The desktop's metal
target stays the 12700KF / RX 6750 XT**; the Q8B becomes a row when it can run
Swift and drive a display, and not before (§4.5).

**Everything in this document is now on [PLAN.md](PLAN.md) as Phases 9–18,
ordered by dependency**, and that document is the roadmap — this section says
what changed, not what order to work in. Two orderings of the same work in two
files is how they drift.

| PLAN phase | What it is | Where it comes from here | State (2026-09-30) |
|---|---|---|---|
| **9** — the interaction substrate | clipboard, drag-and-drop, a keybind table, the window requests we ignore, server-side decorations, the XWayland decision | §4.2, §4.3, §5.2 | ✅ |
| **10** — the menu protocol | ours over `CurrentIPC`, foreign through `abyss-dbus` — **as published vocabulary, not menus only** | §4.2, §5.5 | ✅ |
| **11** — the theme system, layers 1–3 | tokens, declarative widget drawing, chrome — plus `Trench` as the format's positive control | §8, §8.7, §5.3 | ✅ |
| **12** — `Fathom` | PHASE4 §5 as a program; the hardware matrix | §6.4, §4.5 | ✅ but its Aqua view |
| **13** — Islands, Shoals and Ebb | workspaces, window sets, Exposé — and C6 | §7 | not started |
| **14** — preferences that write | Network, Sound, Displays, Energy over `PoolConfig`/`Vents`/`rc.conf` | §4.5 | ✅ |
| **15** — the application layer | `.desktop` → `.app`, the browser, Terminal, TextEdit, Grab, Activity Monitor, Disk Utility | §6.1, §5.1, §4.1 | **next** |
| **16** — the session | login window, lock, idle, suspend, first run | §4.5 | idle done (U.9) |
| **17** — delivery | the Abyss overlay, a release pipeline for the fork, and `abyss update` over boot environments | §6.2, §6.3 | the overlay exists, for the board |
| **18** — confinement, then agents | jails first (they are not only for agents), classes as data, the four requesters, the budget, the off switch, the crash task — and a local model as the default backend | §4.4, §5.4 | not started |

Between Phases 14 and 15, [BACKLOG.md](BACKLOG.md) closed what Phase 15's
applications would need from the compositor (U.1–U.10, U.3b, U.7b), the
installer's keyboard items (T.1–T.3) and the toolchain passes (S.0–S.3).

**What the dependency ordering changed about this document's own instincts**, in
both directions:

- **The theme system moved earlier** than "ahead of most of §4.1" — it is Phase
  11, ahead of *all* of the application layer, because 192 `Theme.` call sites is
  the cheapest this will ever be.
- **`Fathom` moved later** than "belongs early", and the reason is honest: it
  needs a person to have walked PHASE4 §5 before its probes can be right. It is
  Phase 4's second half and it cannot precede Phase 4's first.
- **Jails moved out of last place.** §5.4's point — that a `pkg`-installed GTK app
  runs with the user's full authority — makes confinement worth building before
  the agent that motivated it, so Phase 18 is explicitly "jails, then agents"
  rather than "agents, which need jails".
- **The Terminal stopped being its own step.** It is one item in Phase 15, because
  what actually gated it was the clipboard, the menus and the theme — not its own
  difficulty.
- **Phase 10 acquired a second reason to exist**, on 2026-09-05, and it is the
  only change here that must be made *inside another phase's design* rather than
  by reordering. The menu protocol is the agent's vocabulary (§5.5); designing it
  as menus-only is free today and costs a whole second automation surface in
  Phase 18. Nothing moves in the order — a constraint gets written down eight
  phases early, which is the cheapest kind of dependency there is.
- **Thesis 4's popup went away.** §4.4 asked for Allow / Deny / Always on every
  file and now asks for four named requesters, because confinement *is* the
  grant. That is a smaller Phase 18, not a larger one — as is not writing a TLS
  stack or an inference engine.

---

## 10. What we explicitly will not do

- **Tiling as a layout policy.** Drag-to-edge snapping is the one affordance worth
  offering; §7 is why that is not a concession.
- **A theme *catalogue*.** Curating a pack of looks and carrying the churn of
  keeping it current. We ship **two** — Jaguar as the product and `Trench` as the
  format's positive control (§8.7) — because the theme *system* is required (§8)
  and a system with one theme in it is unproven. Two is a test; twenty is a
  product line we are not in.
- **A browser.** Adopt one — §5.1 says which, and why the choice is an engine
  rather than a chrome.
- **An IDE, a git client, an office suite.** Ports has them; our job is making them
  look and behave like they belong.
- **A TUI for anything.** The one exception is the terminal itself, which is not a
  TUI — it is the escape hatch that lets us ship a GUI without having shipped every
  GUI yet.
- **An inference engine.** A model is a program we run, from ports, behind one
  wire format (§4.4). The same argument as the browser: we adopt engines, we do
  not write them. And the one we adopt runs **here by default**; a remote
  provider is the person's choice to make, never the one made for them.
- **An agent that cannot be removed.** Off is one file, and with it absent there
  is no menu item, no chord, no spend indicator and no process parked on a crash.
  A person who wants none of it gets none of it, and the rest of the desktop does
  not know the difference.
- **A second automation surface.** An application publishes its vocabulary once
  and the menu bar, a script and an agent are all consumers of it (§5.5). No
  plugin API per application, and no agent-only tool interface bolted beside the
  human one.
- **Driving programs by screenshot.** Pixels are the documented fallback for an
  application that cannot describe itself, and they stop being used the day it
  can (§4.4).
