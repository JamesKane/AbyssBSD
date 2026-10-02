# Phase 18 — confinement, then agents (scope)

**Status: scoped 2026-10-02; §6 adopted as recommended the same day.** PLAN.md's Phase 18 is the goal; this is the
order. Phase 18 needs Phases 7, 10 and 14, and all three are complete.

## 1. What this phase is

Two halves, gated separately, because the first is worth having on its own:

- **18a, applications in jails.** A `pkg`-installed GTK application runs
  today with your full authority over your home directory (PRODUCT §5.4).
  After 18a it runs in a jail. That jail has a read-only system, a private
  home of its own, no network unless its class says so, and **no path to
  your files**. A file reaches it only when you choose one in an Open panel,
  and then only that file.
- **18b, agents.** The same jails, plus a model behind one wire format
  (local by default), the four requesters, a transcript, and a budget. The
  first task is a crash handed to a `debug` session.

18a is designed, and its mechanisms are proven by §4's spikes. 18b is listed
in order here, and is re-scoped when 18a's gate is green: 18a will change what
18b needs.

## 2. What we have vs. what's new

| Need | Have | New |
|---|---|---|
| Hand a file over without a path | `abyss-portal`: a descriptor over SCM_RIGHTS (Phase 7) | the D-Bus FileChooser answers with a URI, so a jailed app gets a single-file mount (§4.4) |
| Know who is calling a root service | `installrun/Peer.swift`: `getpeereid` and an authority | — |
| Hide globals from some clients | `menus.c`'s `wl_display_set_global_filter` and the privileged-client list | the jailed-client rule: a class of client, not a list of them |
| Supervise processes | Anchor: restart policy, kqueue | process descriptors and jail descriptors in the same `kevent` |
| Declare things in files | PoolConfig, Pool.Watcher | `jails.ini`: the classes |
| Launch applications | `abyssopen`, `appbundles`, the Dock, Finder | a launch that names a class |
| Create jails, mount, attach | nothing: **nothing in `de/` calls `jail(2)`** | `abyss-jaild`, a root daemon |

## 3. Ordered passes

### 18a — applications in jails

**P18.1 — a class is data (S). — DONE 2026-10-02.** `de/jails` (`JailClass`, `JailPlan`), 17 tests (every check fault-injected), green on Linux and in the guest; the plan was performed by hand in the guest (§4.5).
`jails.ini` in PoolConfig. A class names:
- the system it sees (read-only nullfs of `/bin /lib /libexec /usr`, and a
  generated `/etc` with `passwd`/`group`/`pwd.db` and no `master.passwd`);
- its private home (a ZFS dataset per user and class, or a directory where
  there is no ZFS);
- its devices (a devfs ruleset: `4` by default; `/dev/dri` for a GL class;
  `/dev/dsp` for a sound class);
- its network (`none` or `host`; `vnet` is 18b's);
- whether it gets a Wayland socket.

The pure part is a `JailPlan`: class plus user gives the mount list, the jail
parameters, and the environment. It has unit tests on both platforms, with
fault injections (a writable system mount, a home outside the dataset, an
`/etc` with `master.passwd`). The shipped classes are `app` (no network,
Wayland, ruleset 4), `app-gl`, and `app-net` (host network: a browser).

**P18.2 — `abyss-jaild`, the root half (M). — DONE 2026-10-02.** `de/cjail`
(jail and process descriptors in C, ENOSYS off FreeBSD), `de/jaild` (pure
build and teardown steps, the performer, the service, the client),
`abyss-jaild`, `abyss-jail` (a person's client), and `abyss/etc/rc.d/abyss_jaild`
(enabled on the medium and on installs, with the root's ZFS pool for homes).
11 unit tests; `live-jaild.sh`'s six claims are green in the guest, three runs
running. Nine faults were injected into the daemon, and each failed the test.
Run from its rc.d script in the guest, jaild kept a home as the dataset
`zroot/abyss/jails/build/app` (HANDOFF §2.121).
A root daemon, started from rc.d like `abyss_loginwindow`. Its socket is
private, and it asks the kernel who is calling (`Peer.swift`). It does
three things, all for the caller's own uid:
- **open(class):** builds the root (a tmpfs, with P18.1's mounts in it) and
  creates the jail with `JAIL_OWN_DESC`. It hands **the owning descriptor**
  to the caller over SCM_RIGHTS. The jail lives exactly as long as the
  session holds that descriptor (§4.2). Jails are pooled: one per user and
  class, not one per launch (PLAN's cost note).
- **spawn(jail, argv, env, fds):** `pdfork`, `jail_attach_jd`,
  `setgroups`/`setgid`/`setuid` to the caller, `exec`. It returns the
  **process descriptor**.
- **teardown:** it watches every jail it made with `EVFILT_JAILDESC`. On
  `NOTE_JAIL_REMOVE` it unmounts and removes the root.

FreeBSD only: the Linux build is a stub that refuses, and says so. Its live
test runs in the guest (the build user has sudo) and skips on Linux.
Claims:
- a jailed `id` is the caller's uid;
- `/home` is absent, and so is `master.passwd`;
- a second uid cannot use the first one's jail;
- closing the descriptor removes the jail and every mount;
- killing the daemon leaves no mounts behind on its next start.

**P18.3 — the Wayland boundary (M). — DONE 2026-10-02.** An allowlist of 24
interfaces in `menus.c`'s global filter, checked before every other rule, with
undertow creating `wlr_security_context_manager_v1`, and a `window-jail` report
line. `live-jail-wayland.sh` has five claims, green on Linux and in the guest.
Five faults were injected, and each failed the test. Combined with P18.2 in the guest,
zenity ran in a jaild jail on a socket in the jail's runtime directory, and
undertow named it as the jail's (§4.6).
undertow gains `wp_security_context_v1` (wlroots 0.20 has it on both
platforms, §4.3). The session binds a listening socket **inside the jail's
root** and registers it, with engine `org.abyssbsd.jail`, the app id, and the
jid as instance. So the jail never sees undertow's runtime directory, which
holds every service socket (the spike mounted all of it; that is what this
pass removes).

A client that came in through such a socket is **jailed**, and the global
filter hides from it:
- screencopy and the menu bar's privileged globals;
- virtual pointer and virtual keyboard;
- session lock and layer shell;
- foreign-toplevel, data-control (it could read every copy), gamma, and
  output management;
- the security-context manager itself.

It keeps `xdg_wm_base`, `wl_seat`, `wl_shm`, `linux-dmabuf`, and
presentation-time. Fault injection: an unjailed client gets the same list and
fails the test.

**P18.4 — files go in through the Open panel (M). — DONE 2026-10-02.** It
works differently from the sketch below, and better: the proof is
**`abyss-portal`'s own descriptor** of the chosen file. Until now `abyss-dbus`
closed it, and now it hands it to jaild's `grant`. jaild checks that the path
is resolved and names the descriptor's inode, mounts that one file read-only
unless the descriptor was writable, and checks the inode again through the
mount. Each jail has **its own D-Bus**, at `/run/user/bus` in the plan's
environment (with `GTK_USE_PORTAL=1`), served by an `abyss-dbus --jail`. So a
jailed caller is known by the bus it is on, with no pid-to-jid lookup.
*(2026-10-02: that bus is a `dbus-daemon` per jail, which repeats Phase 8's
mistake. The design stands, a socket per jail with the portal on it, but the
socket should be the Swift bridge itself, not a bus with the bridge as a client
(PRODUCT §5.6, BACKLOG D.1). **Done with D.1:** each jail's bus is an
`abyss-dbus --endpoint`, its portal on a services socket outside the jail,
and `live-jail-files.sh` asks from inside with a GLib caller.)*
`live-jail-files.sh`'s five claims pass in the guest, with gdbus and dbus-monitor
running inside the jail. Seven faults were injected, and each failed the test.
P18.5 starts the bus and its bridge for each jail (HANDOFF §2.122).
The D-Bus FileChooser (Phase 8) answers with a URI, so a jailed application
needs the file **at a path inside its jail**. When the caller is jailed
(LOCAL_PEERCRED's pid, then its jid), the portal asks `abyss-jaild` to
nullfs-mount the chosen file at `/run/granted/<n>/<name>` (§4.4), and
answers with that path. A Save panel mounts the chosen file, or a
directory for a new one.

The grants are listed per jail, and revoking one unmounts it. This is
PLAN's "revocable list", and it arrives in 18a.

Claims:
- an app in a jail opens a chosen file and saves back to it;
- a sibling of the file is invisible;
- after a revoke, the file is gone;
- an unjailed caller still gets its own path (no regression).

**P18.5 — launching confined (S–M). — DONE 2026-10-02.** The session's half
is `abyss-jail serve`, the desktop session's `jails` component. It holds a jail
per class for the session's life, with the jail's own Wayland socket
(`aw_jail_listen`, security-context), its own bus and its `abyss-dbus --jail`,
all as its children by descriptor. `abyss-jail launch CLASS -- cmd args` asks
it, and an argument that names one of the person's files is granted (read-write
where they may write it) and rewritten. A bundle is confined by
`X-Abyss-Jail=` in its entry or by `jails.ini`'s `[apps]` (the person's, or
the machine's at /usr/local/etc/abyss when run as root); `none` keeps one out.
`abyss-appgen` writes `exec abyss-jail launch …` into its launcher.
`live-jail-launch.sh` has six claims, green three runs in a row in the guest.
Six faults were injected, and each failed the test. **Not done here:** the
"Confined" line in About (it needs the menu protocol to carry a window's
jail), and regenerating bundles when `[apps]` changes (run `abyss-appgen`).
Both move to P18.6. Found and fixed: jaild never reaped its programs, so every
jail stayed dying (HANDOFF §2.123).
An application's bundle or `.desktop` file declares its class with
`X-Abyss-Jail=`. `abyssopen`, the Dock and the Finder launch through Anchor,
which holds the jail and process descriptors in its `kevent`. Confinement is
**opt-in per application** in 18a (§6.1). The application menu shows
"Confined (app)" in About, so it is visible, not assumed.

Live test in the guest:
- galculator by its bundle runs with a non-zero jid;
- quitting it leaves the jail pooled;
- logging out removes the jail.

**P18.6 — the gate for 18a (S). — DONE 2026-10-02, in the guest and on the
12700KF. 18a is complete.** On the box, after D.1, with screenshots:
- the session ran ADE's bridge (9 components, no `dbus-daemon`), and
  `abyss_jaild` ran as an rc.d service on UFS;
- `[apps]` remade Firefox's bundle confined, and the bundle launched it through
  the keeper into `abyss-1001-app-net` (with `/dev/dri`);
- confined Firefox rendered a page served over the LAN, drawn on the 6750 XT;
- its file input opened the Finder as "Choose a File" through the jail's
  portal, on the person's real home (the jail's folder hint ignored);
- the file double-clicked came in as a read-only grant, and the page showed
  what it read through it ("chosen on the 12700KF");
- the bar's application menu said "Confined (app-net)", disabled.

The first attempt used `--kiosk`, which on the DRM output leaves a 1×1 window
whether confined or not. I first wrote that up as "Firefox is 1×1 on metal",
which was wrong. It is the narrower BACKLOG F.1, and not 18a's. `live-jail-gate.sh` has seven claims, green three runs in a row,
and four faults were injected, each failing the test. Firefox ESR, confined in
`app-net` by its bundle, renders a page served over the network. Its file input
opens the Finder through the jail's portal, and the chosen file comes in as a
read-only grant that the page reads. Also new: menu bar protocol v5 sends
`jail(class)` before each `focused`, and the application menu's first row says
"Confined (class)", disabled. That stands in for the About line, since a
foreign app's About box is its own. The keeper also remakes the bundles when
`[apps]` changes. Found on the way (HANDOFF §2.124): FreeBSD's config watcher
missed in-place edits, and a jail's folder hints named host paths. **Menus for jailed apps — done 2026-10-02:** a confined GTK application's
own menus are on its jail's bus, so each jail has its own menu bridge
(`abyss-dbus --menus --class CLASS`, started by the keeper beside the jail's
portal), serving `menus-dbus-CLASS`. The bar asks that service when focus
says the window is confined (v5's `jail`). The gate's claim 9 has gtkmenu,
confined: its menus are shown from `menus-dbus-app`, its application menu
starts with "Confined (app)", and File ▸ Open… reaches GTK in the jail. **On the 12700KF too**
(same day): gtkmenu confined in `app`, with its menus shown from
`menus-dbus-app (GTK, confined)`, "Confined (app)" in its application menu
(screenshot), and File ▸ Open… → ok.
The stack proof in the guest: galculator and zenity confined, Firefox in
`app-net`. Then the same on the 12700KF.
- a confined zenity cannot `ls ~`;
- Firefox renders a page and cannot read `~/.ssh`;
- a file opened from the Finder edits in place.

Every 18a live test is in `run.sh`, and its Linux leg skips cleanly.

### 18b — agents (re-scoped 2026-10-02, after 18a)

**What 18a settled, and 18b builds on.**
- **A class is data, and jails are pooled:** an agent class is one more row.
- **Grants are how files get in:** an agent sees a file only because the
  person handed it over.
- **A jail's channels out are bridges the keeper runs, outside the jail, on
  sockets inside it:** Wayland (security context), D-Bus (the portal, the
  menus). An agent's two channels out, to a **model** and to the **vocabulary**,
  are built the same way. The agent jail itself then needs **no network at
  all** for a local model, which is the strongest form of "egress through the
  thing that holds the credential".
- **The keeper sees a confined program exit, with its status.** A crash of a
  confined application is already observed, and its core lands in the jail's
  own home (§4.7).

**The passes, in order:**

- **P18.7 — `abyss-model`, the only way to a model (M).** A session service
  speaking one wire format, OpenAI-compatible chat completions with tool calls,
  over a unix socket. The keeper puts that socket into an agent's jail.
  Backends:
  - **stub**: canned replies and tool calls, for every test;
  - **local**: ports' `llama-server`, from `llama-cpp` on `ggml` with Vulkan
    (§4.7), run outside any jail, CPU in the guest and the 6750 XT on the box;
  - **remote**: a provider and its key, which stay in this process.

  It counts tokens against a per-session **budget**. A call over budget is
  refused with its reason (requester 4's raw material). It appends every
  request and reply to the session's **transcript**: JSON lines, append-only,
  outliving the process. We do not write an inference engine.

  **P18.7a — the service — DONE 2026-10-02.** `de/model` (JSON and minimal
  HTTP/1.1 with no Foundation; `ModelSession`'s budget and transcript; stub
  and HTTP backends; `MachineMemory`/`ModelTier`) and `abyss-model`
  (`serve`, `tier`). The budget stops the *next* call: a reply that crosses it
  is delivered (it is already spent), and the call after is a 429 with its
  reason that reaches no backend. The transcript is `DIR/transcript.jsonl`,
  O_APPEND, 0600 in a 0700 directory. Streaming is refused in words, not
  half-served. 14 unit tests and `live-model.sh` (claims 1–5: curl as the
  OpenAI client over the unix socket, an `nc` canned server as the backend so
  neither end is ours), green on Linux and in the guest; 15 faults injected,
  all caught. On the 12700KF, `abyss-model tier` reads
  `vram=12272M ram=130893M tier=gpu12` from amdgpu's boot report.

  **P18.7b — the local backend — DONE 2026-10-02.** `serve --local MODEL`
  runs ports' `llama-server` as a supervised child on a unix socket in a 0700
  directory (no TCP port), with `--jinja` and one slot (`-np 1`). It is ready
  only once `/health` answers. A model that fails to load fails abyss-model
  with the server's words; a server that dies is a 502 that says so. Stopping
  abyss-model stops the server, and on FreeBSD killing it outright does too.
  `live-model.sh` claims 6–9 (a stand-in server made of `nc`), green on Linux
  and in the guest, 6 faults injected and caught; claim 10 and
  `measure-model.sh` run a real model, and the §6b.1 candidates were measured
  on the 12700KF (the table there).

  **Still to do in P18.7:** (c) the remote backend, which needs TLS the tree
  does not have; (d) the keeper putting the socket in an agent's jail, which
  lands with P18.8.
- **P18.8 — the agent runtime, in its jail (M).** `abyss-agent` runs the loop,
  model to tool to model, **inside** the agent's jail. It reaches the model
  only through `abyss-model`'s socket, and is started by the keeper like any
  confined program. The **chat window** is ours, outside the jail, and talks
  to it over the session's socket. Classes are new rows:
  - `agent`: no network, no devices, the model socket;
  - `debug`: the same, plus `lldb`.

  Tested hermetically against the stub.

  **P18.8a — the runtime, in its jail — DONE 2026-10-02.** The classes
  `agent` and `debug` are shipped rows: `wayland = no` (so no socket, bus,
  portal or menus), no devices, no network. They gain `budget` (tokens per
  session) and `model` (`local:`, `stub:` or `http://`), which the keeper
  reads from the person's `jails.ini`; what a jail can reach stays jaild's.
  `abyss-jail agent CLASS` asks the keeper for a session: `abyss-model`
  started outside the jail for that session alone (transcript and log in
  `~/Library/Logs/Agents/ID/`), its socket in the jail's runtime directory,
  and `abyss-agent serve` started in the jail on it. A dev build is handed in
  as a read-only grant. When the agent ends, the keeper stops its model.
  `abyss-agent` (`de/agent`) runs the loop: thinking off; 12 steps at most;
  a 429 from abyss-model ends the question with its words; a bad tool call is
  the model's to see. Its tools for now are `list_directory` and `read_file`,
  bounded by the jail rather than by checks of their own. 9 AgentTests, 3
  more JailsTests, and `live-agent.sh` (claims 1–6) green in the guest; 10
  faults injected, all caught.

  **On the 12700KF, with a real model (same day).** `[agent] model =
  local:…/granite-4.2-8b-Q4_K_M.gguf` in the person's `jails.ini`, llama-server
  on the 6750 XT. Asked to find a notes file in its home and say what was due
  on Monday, the agent listed `/home`, then `/home/abyss`, read `notes.txt`,
  and answered correctly: 4 steps in 2.8 s. Asked to read the person's real
  `~/.config/abyss/jails.ini`, it looked, found no such file (the jail's
  `/home/abyss` is its own), and said so. `bye` stopped abyss-model and
  llama-server, and the VRAM came back. The run found two deployment bugs
  (HANDOFF §2.129): `metal.sh push` left the new binaries out and gave every
  pushed file to the person, root daemons included.

  **P18.8b — the chat window — DONE 2026-10-02.** `AQUA_SCENE=agent`, an
  AquaDemo mode like Grab (`de/aqua/AgentApp.swift`). It asks the keeper for
  a session in `agent` (or `$ABYSS_AGENT_CLASS`), then talks to the agent's
  socket. The conversation shows each tool call as a line before the answer.
  The status line says where the agent runs, and why it stopped in the words
  of what stopped it. Nothing waits: the keeper's answer and every reply come
  through the display's poll loop. Ask is a menu verb (Conversation ▸ Ask)
  whose enablement says why not ("the field is empty", "the agent is
  answering", "there is no agent"). Closing or ⌘Q says `bye`. 3
  AgentWindowTests, an `agent` golden on both platforms, and
  `live-agent-window.sh` (claims 1–5: typed with a virtual keyboard, sent with
  Return and with the button, the budget, ⌘Q, a class with no model), green
  in the guest; 6 faults injected, all caught.

  **On the 12700KF (same day):** the window on the desktop, with Granite 8B
  Q4 behind it, asked through the vocabulary (`abyssmenu run agent
  agent.question text=…`; a declared argument is required, so it is its own
  verb beside Ask, as Finder's Go to Folder… is). It answered from the notes
  file. Told only "your own home", Granite searched `/home/agent`, `/abyss`
  and `/` first: 7 calls. With its home and the grants' place in the system
  prompt it took 2. `⌘Q`/Quit said bye, and the model and llama-server
  stopped.

  **P18.8 is complete.** Its loose ends, closed the same day:
  - **Tool calls as they happen.** `AgentLoop.onCall` tells each call as it
    starts; `abyss-agent serve` sends it as an `event=call` message before the
    reply on the same connection; the window writes "You: …" at once, each
    "› call" as it comes, then the answer, and its status counts the calls so
    far. `live-agent-window.sh` proves it with a slowed stub
    (`ABYSS_MODEL_STUB_DELAY`, tests only): a call is on the screen while the
    answer does not exist yet. Without the delay the test cannot tell
    streaming from batching, and a fault that removes it fails the test.
  - **The Dock.** `agent` in `dock.ini` pins Agent, as `terminal` pins
    Terminal, with an icon of its own in Aqua's `dock.dl` (a speech bubble and
    a padlock); a theme without one shows the generic icon. A running
    built-in that is not pinned (Agent, or Terminal opened by a file) now
    wears its own tile rather than the generic one.

  **Still open:** Agent is not in the default Dock (that is a choice of what
  the desktop puts in front of everyone), and Trench has no Agent art.

  **The desktop's own tiles (same day, asked for).** `Dock.builtins` is one
  table of the desktop's own applications (token, label, app ID, scene,
  icon), read by both the pinned tiles and the running ones. TextEdit, Grab,
  Activity Monitor, Disk Utility and System Profiler joined it, with Aqua
  icons of their own, so each can be pinned in `dock.ini` and wears its own
  tile when it runs. Grab, Activity Monitor and Disk Utility had no way in
  from the UI before. Trench draws the compiled Aqua icons until its art has
  them. **Found on the way:** System Preferences' tile said
  `org.abyssbsd.prefs`, but its window says `org.abyssbsd.preferences`, so a
  running Preferences never lit its pinned tile and got a second, generic
  one. `live-dock-apps.sh` claim 12 checks both, with 2 faults caught.
  There is still no Applications folder entry for them.
- **P18.9 — the crash, first (M).** jaild gives a spawned program the person's
  login-class limits (`setusercontext`), not jaild's own: a jailed process now
  inherits a core limit of 0 (§4.7). When a confined application dies of a
  signal, the keeper tells the desktop. "Application quit unexpectedly" gets
  an **Ask the agent** button. That starts a `debug` session: its core and its
  binary come in as read-only grants, the agent's tool is `lldb --batch` on
  them, and it writes only a report into the transcript. No network, no
  vocabulary. This is 18b's first visible deliverable.

  **P18.9a — the plumbing — DONE 2026-10-02.**
  - **jaild gives a spawned program the person's login-class limits**
    (`ap_class_limits`, applied with `setrlimit` before it gives up root).
  - **The keeper keeps a crash** when a program it launched dies of a signal:
    the program, the signal, whether a core was written, and where the core
    and binary are, named by the home's source (jaild reports it now).
    `abyss-jail crashes` lists them.
  - **`abyss-jail debug N`** starts a session in `debug` with that crash's
    core and binary granted read-only. A home binary is linked at its recorded
    path, because lldb needs it there.
  - **The `debug` class's tool is `lldb`**: `--batch` on that core and binary,
    fixed by the session; the model chooses only the command.
  - Tests: 5 JailsTests on `Crash`; the lldb tool's tests (the target cannot
    be moved by the model); `live-crash.sh` claims 1–5 in the guest, with jaild
    at a core size of 0; the earlier jail and agent live tests stay green. 7
    faults injected, all caught (one after the test learned to send the
    argument the fault listened to).

  **P18.9b — what a person sees — DONE 2026-10-02 (in the guest).**
  - **Crash Reporter** (`AQUA_SCENE=crashreport`, `de/aqua/CrashReport.swift`):
    "The application X has unexpectedly quit. It ran confined, so nothing else
    was affected. It was killed by SIGSEGV…". The keeper starts it on a crash
    when it has a display (`crashDialog`).
  - **Ask the Agent…** is the default when there is a core. It asks the
    keeper for `debug N` through the poll loop, then opens the Agent window on
    that session (`ABYSS_AGENT_SOCKET`) asking "Why did X crash?"
    (`ABYSS_AGENT_ASK`), and closes. A crash without a core gets an OK and
    says it left nothing to read. Its verbs (`crash.ask`, `crash.close`) are a
    menu, so a script can answer it.
  - Tests: 3 CrashReportTests, a `crashreport` golden on both platforms, and
    `live-crash-dialog.sh` claims 1–5 in the guest. The report is clicked
    with a virtual pointer; the Agent window, started by the report and not
    the test, runs lldb and answers. 6 faults injected, all caught. The whole
    Aqua suite (285) is green on both platforms.
  - Found on the way: P18.8b's Dock icon had not regenerated
    `JaguarLists.swift`, which ThemeTests checks byte for byte. Only filtered
    suites had been run. It is regenerated, and Trench's icon sheet shows the
    compiled Aqua Agent icon, as it does for any list Trench lacks.

  **On the 12700KF with Granite 8B Q4 (same day).** A crasher built on the
  box, launched confined in `app`, put up Crash Reporter on the desktop
  (screenshot). Ask the Agent… (`crash.ask`) started `debug` with the core
  and a link to the binary at its recorded path, and opened the Agent window
  asking "Why did crasher crash?". Granite ran `bt` once and answered: SIGSEGV
  at crasher.c:6:12 in `kaboom(p=0x0)`, a null pointer dereferenced. The
  window said "Confined in debug: one crash, read-only; no network", and the
  Dock wore the Agent tile. Quit stopped the model; the test files were
  removed. **P18.9 is complete.**
- **P18.10 — tools are the vocabulary (M).** A vocabulary bridge per agent
  jail, beside the model socket: Phase 10's `describe`/`validate`/`activate`
  over `CurrentIPC`, for **the applications this session was given** (§6b.2)
  and no others. An agent drives an application exactly as the menu bar and a
  script do. Pixels only for an application that cannot describe itself, and
  not in this phase.

  **P18.10a — the bridge — DONE 2026-10-02 (in the guest).**
  - **`abyss-vocab`, one per agent session**, started by the keeper beside
    abyss-model when the class has `vocabulary` (`agent` does; `debug` does
    not). It answers `apps`, `describe` and `activate` on a socket in the
    jail, relaying each to the application's own menu service, the same one
    the bar and `abyssmenu` use.
  - **Gives** come only on a control socket beside the transcript, outside
    the jail: the agent cannot give itself anything. A give is one running
    application, by its menu service (pid and all).
  - **`abyss-jail give SESSION APP`** is the keeper's give; P18.10b puts it in
    the Agent window.
  - **Logged and stopped with the agent:** every give, activation and refusal
    is a line in the session's transcript, and the bridge stops with the
    agent.
  - **The agent's tools** are `apps`, `describe_app` (the verbs with titles,
    arguments, enablement and summaries) and `activate`. Asking about an
    application not given is refused by name and never forwarded.
  - Tests: 5 VocabularyTests and a JailsTests check; `live-agent-vocab.sh`
    claims 1–6 in the guest. A real TextEdit, given, saves when the agent
    activates `file.save`; a real Grab, running but not given, captures
    nothing. The agent, crash and launch live tests stay green. 7 faults
    injected, all caught.

  **P18.10b — giving, from the Agent window — DONE 2026-10-02 (in the guest).**
  - **Conversation ▸ Give Application…** lists the other running applications
    that publish a vocabulary, by their own names, over the conversation; a
    click gives one. Escape, or a click elsewhere, closes the list.
  - **Give** (`app=`) is a script's way.
  - **What the person sees:** the status line names what was given ("given
    TextEdit"), and the conversation notes each give. A refusal is shown in
    the keeper's words.
  - **Some windows cannot give.** A window opened on a session it was handed
    (Crash Reporter's debug session) has Give disabled ("this session cannot
    be given applications"), as does a class without a vocabulary.
  - The list never includes the Agent window: asked while answering a menu
    request of its own, the window would wait on itself until the timeout, as
    a fault showed.
  - Tests: a picker layout test; an `agent-give` golden on both platforms (95
    scenes); the whole Aqua suite (287) green on both; `live-agent-give.sh`
    claims 1–5 in the guest (a virtual pointer clicks TextEdit's row; the
    agent then saves through TextEdit's menu). 5 faults injected, all caught.

  **On the 12700KF with Granite 8B Q4 (same day).** TextEdit open on a note,
  the Agent window beside it. Give Application… listed Finder and TextEdit
  on the desktop (screenshot), and TextEdit was given. Asked "Please save the
  document I have open in TextEdit", Granite called `apps`, `describe_app`
  and `activate file.save`, and TextEdit wrote the note. The conversation
  shows the give, the three calls and the answer, and the status read "given
  TextEdit". Quit stopped the model and the bridge. **P18.10 is complete.**

- **P18.11 — the four requesters, the transcript viewer, revocation (M).**
  1. The first write in a session to a file that exists. This is a writable
     grant's first open for writing, which jaild can see.
  2. Anything in the `admin` class.
  3. Egress to a host not already granted (P18.12).
  4. A spend over the budget (P18.7).

  A sheet for each, and no others. The grants list (P18.4) and the
  transcript are shown in a Preferences pane.

  **P18.11a — requester 4, and taking a give back — DONE 2026-10-02 (in the guest).**
  - **Requester 4 (budget):** when the budget stops a question, the Agent
    window puts up a requester over the conversation: "The agent has used its
    budget", abyss-model's words, and "Let it use another N tokens and carry
    on?" with **Stop** and **Allow More** (the default, Return).
  - **Allow More** has the keeper raise the session's budget through
    abyss-model's control socket (outside the jail; logged as `raised`). The
    agent then carries on with the same question (`continue`,
    `AgentLoop.resume`), never asking it again.
  - **Stop** ends it, saying why.
  - **Take Back Application…** (and `agent.take app=`) has the keeper tell the
    session's bridge, which refuses that application from then on as if never
    given; the transcript says `taken`.
  - CLI: `abyss-jail raise SESSION TOKENS`, `abyss-jail take SESSION APP`.
  - Tests: resume, raise and take unit tests; an `agent-budget` golden on both
    platforms (96 scenes); the Aqua, Model and Jails suites (390 in the guest);
    `live-agent-requester.sh` claims 1–5, in which Allow More is clicked with a
    virtual pointer. `live-agent-window.sh` now answers the requester with
    Stop. 6 faults injected, all caught.

  **P18.11b — the Agents pane — DONE 2026-10-02 (in the guest).**
  - **System Preferences ▸ Agents** (System section; `view.pane.agents`) lists
    the agent sessions from their transcripts on disk, newest first.
  - **The selected session in sentences** (`Transcript.digest`, in Model):
    "You asked…", "The agent called…", "You gave the agent TextEdit", "The
    agent asked to write with TextEdit (Save)", "You allowed…", "Stopped:
    the session's budget…". The last lines that fit are shown.
  - **The files given to confined applications**, from the keeper (`grants`),
    each with **Revoke** (`revoke`, through the keeper to jaild).
  - **The keeper's own grants are not offered**, a developer's `abyss-agent`
    handed into an agent jail for instance: they are not the person's files,
    and revoking one would break the agent. Found when the first live run
    listed it.
  - Tests: TranscriptTests and AgentsPaneTests; the Preferences grid and icon
    sheets re-goldened on both platforms, plus a `sysprefs-agents` golden (98
    scenes); the Aqua suite (292) green on both; `live-agents-pane.sh` claims
    1–3 in the guest, with clicks on a session and on the second of two
    grants' Revoke. 6 faults injected, all caught (one after the test gained
    a second grant).
  - **On the 12700KF (same day).** The pane listed the day's seven real
    sessions (the agent's, and the 16:29 crash's `debug` session), the newest
    one's digest, and a document given to a program confined in `app`.
    Revoke, clicked with a virtual pointer (built in the guest; the medium
    carries no Wayland headers), took it back, and the jail's grants were
    unmounted. **Found there:** an agent's answer with line breaks drew a
    missing-glyph box for each, because the word wrapper splits on spaces;
    each line of the digest is now split into paragraphs first
    (`agentsDigestParagraphs`).

  **Still in P18.11:**
  - (c) requester 1, the first write to an existing file. PHASE18 assumed
    jaild "can see" a writable grant's first open for writing. It cannot ask
    before one: FreeBSD tells a watcher about a write after it happens
    (kqueue `NOTE_WRITE`), not before. **Decided 2026-10-02: ask at the
    menu.** Applications mark the verbs that write a file (Save, Save As…,
    Move to Trash). The first time in a session an agent activates one of an
    application's, the Agent window asks before it runs; the bridge holds the
    answer, outside the jail. A person saving is the person, so a confined
    application acting for a person is not asked. Rejected: read-only grants
    until asked (a program that does not retry a failed write loses the save),
    and telling after the write (it informs; it does not ask).
  - Requesters 2 and 3 wait for the `admin` class and P18.12.

  **Requester 1 — the first write — DONE 2026-10-02 (in the guest).**
  - **`Command.writes`** (on the menu wire as `writes`) marks the verbs that
    write or remove a person's file: TextEdit's Save and Save As…, the
    Finder's Move to Trash and Empty Trash.
  - **The bridge holds the line.** It does not run such a verb for an
    application not yet allowed this session: it answers `permission`, and
    logs `asked`.
  - **The agent passes it on** as an event on the question's connection, and
    waits.
  - **The window asks:** "Allow the agent to write with TextEdit?", with
    Don't Allow and **Allow**.
  - **The answer goes keeper → bridge first** (`permit`, logged as `permitted`
    or `denied`, outside the jail). Only then does the window tell the agent
    to try once more. An agent that answers itself yes is still refused by
    the bridge.
  - Don't Allow is not remembered: the next write asks again. Allow lasts the
    session.
  - `abyss-agent ask` on a command line answers no, because a script is not
    the person. `abyss-jail permit SESSION APP yes|no` is the keeper's form.
  - Tests: unit tests for the bridge's flow, the wire, the marked verbs and
    the wording; an `agent-write` golden (97 scenes on both platforms); every
    unit test (907) green on both; `live-agent-vocab.sh` (refused unasked,
    saves once permitted), `live-agent-give.sh` (Don't Allow writes nothing
    and asks again; Allow saves) and `live-agent-requester.sh` in the guest. 6
    faults injected, all caught (four after the harness's arguments were put
    in order).
  - **On the 12700KF with Granite (same day).** The first run found that the
    agent did not wait: a 2 s receive timeout on its connection
    (HANDOFF §2.131). After the fix, Granite called `activate file.save`, the
    requester stayed up 10 s with the agent waiting, Allow was answered, and
    TextEdit wrote the note. The transcript reads `given`, `asked`,
    `permitted`.

- **P18.12 — network for agents, when a class needs it (M).** A `vnet` jail
  (§4.7) whose only route out is an egress proxy outside it, which asks
  (requester 3) before a new host. A remote model never needs this: it goes
  through `abyss-model`.

  **Decided 2026-10-02: a fetch tool through a bridge, not a `vnet` jail.**
  The agent jail keeps no network at all. Its `fetch` tool asks a bridge
  outside the jail, which asks the person before each new host
  (requester 3) and makes the request itself, as abyss-model does for a model
  and abyss-vocab does for applications. It needs TLS: a small wrapper over
  base OpenSSL, shared with the remote model (P18.7c).

  Rejected: a `vnet` jail with an epair whose only route out is a proxy. The
  jail could also reach any host service bound to all addresses (sshd) unless
  pf or ipfw confined the epair, which means loading a firewall and jaild
  managing epairs and rules as root. The cost of the choice: only the agent's
  own tool reaches the network, not programs run in its jail.

  **P18.12a — TLS — DONE 2026-10-02.**
  - **`de/ctls`** wraps base OpenSSL: verify or fail with why. The peer must
    chain to a trusted CA (the system's, or a test's file) and name the host;
    TLS 1.2 at least; SNI sent; no switch to skip verification.
  - **`HTTP.Endpoint.tls`** and `WebURL` (http/https, no userinfo, host
    compared without case, redirects resolved). A fetch is HTTP/1.0, so the
    body ends at close and is never chunked.
  - **`abyss-model fetch URL [--ca FILE]`**.
  - Tests: `live-tls.sh` (claims 1–4: a server that is not ours, `openssl
    s_server`, with certificates the test makes — trusted, untrusted CA,
    another name — and plain http against `nc`), green on Linux and in the
    guest; 3 faults injected, all caught. Real `https://example.com` fetched
    with each system's own CAs.

  **P18.12b — the fetch bridge and requester 3 — DONE 2026-10-02 (in the guest).**
  - **`abyss-fetch`, one per agent session**, started by the keeper beside
    the vocabulary bridge when the class has `fetch` (`agent` does; `debug`
    does not). It answers `fetch URL` on a socket in the jail.
  - **Requester 3:** a host not yet allowed this session is answered
    `permission`, and the agent passes the question to the window
    ("Allow the agent to reach example.org?"). The answer goes keeper →
    bridge (`permit-host`, outside the jail), and only then is the agent told
    to try again. Don't Allow is not remembered.
  - **Never this computer's own services**, nor a private network's
    (loopback, RFC 1918, link-local, CGNAT): refused before any request
    (`ABYSS_FETCH_ALLOW_LOCAL` opens this for tests only).
  - **A redirect is followed only to a host that is allowed too**, three at
    most.
  - **Pages come back as their words** (markup, scripts and styles removed;
    16 KB).
  - **The transcript says it all** (`asked`, `permitted`, `denied`,
    `fetched`, `redirected`, `refused`), and the Agents pane's digest reads
    it.
  - **DNS rebinding — closed the same day.** The bridge once checked a host's
    addresses and then connected by name, which resolved again, so a DNS
    answer that changed between the two could slip a local address through.
    It now resolves once, checks every address, and connects to the first
    one it checked (`HTTP.call(address:)`), keeping the name for TLS and
    `Host:`. FetchTests has a rebinding resolver; `live-tls.sh` claim 5
    proves a given address is still verified against the name; a fault that
    connects by name again is caught.
  - Tests: FetchTests (asking, local refusals, redirects, page text, what is
    local, the digest), the class flag, the requester's words;
    `live-agent-fetch.sh` claims 1–4 in the guest (no network in the jail;
    the requester before the server hears anything; Don't Allow; Allow after
    a person's pause, the page's words to the model). Every unit test (925)
    green on both platforms; every agent, crash and TLS live test green in
    the guest; 7 faults injected, all caught.
  - **On the 12700KF with Granite (same day).** Asked what `https://example.com`
    says, Granite called `fetch`. The window asked "Allow the agent to reach
    example.com?" (screenshot); 10 s later it was allowed. The bridge fetched
    it over verified TLS (200, 577 bytes), and Granite summed it up in a
    sentence. The transcript reads `asked`, `permitted`, `fetched`. Quit
    stopped the model and every bridge. **P18.12 is complete.**
- **P18.13 — presence and off (S).** Agent state (working, waiting, idle) on
  the Dock tile, the menu bar and the island switcher. `agents.ini` absent
  means no menu item, no chord, no spend indicator, and no process.
- **P18.14 — the gate (S).** PLAN's verify list:
  - an agent in a jail with exactly one descriptor (the model socket);
  - the transcript showing what it was granted;
  - a revocation taking effect;
  - a budget stop with its reason on screen;
  - the crash notice starting a `debug` session that sees one process and not
    a second.

  In the guest with the stub and with `llama-server` on the CPU; on the
  12700KF with a local model on the GPU.

## 4. The spikes (2026-10-02, in the FreeBSD 16 guest)

### 4.1 A GTK application in a read-only jail — **runs, with nothing special.**

The jail was built from read-only nullfs mounts of `/bin /lib /libexec /usr`.
It also had a copied `/etc` (`passwd`, `group`, `pwd.db`, `nsswitch.conf`,
`libmap.conf`), `ld-elf.so.hints`, devfs ruleset 4, `ip4=disable`, and
undertow's runtime directory nullfs-mounted in. Then:

```
jexec -U build spike18 env -i HOME=/tmp XDG_RUNTIME_DIR=/run/wl \
    WAYLAND_DISPLAY=wayland-0 zenity --info --text "from a jail"
```

- undertow reported `window zenity/Information`, and galculator mapped too
  (jid 1).
- Inside, `/home` does not exist, `/etc` holds five files, and `/dev` is
  ruleset 4's.
- The uid is the user's own.

With no `/dev/dri`, GTK drew in software and said nothing; `app-gl` exists
for that reason.

### 4.2 Jail descriptors — **an owning handle, and kevent hears it.**

- `jail_set(JAIL_CREATE | JAIL_OWN_DESC)` returned a descriptor.
- `EVFILT_JAILDESC` delivered `NOTE_JAIL_ATTACH` when a child called
  `jail_attach_jd`.
- **Closing the descriptor removed the jail**: `jail_getid` gave −1.

So the session's lifetime *is* the jail's, and there is no reaper to write.

### 4.3 `security-context-v1` — **in wlroots 0.20, on both platforms.**

`wlr_security_context_v1.h` exists in the guest's wlroots 0.20 and on Fedora.
The protocol is in wayland-protocols `staging/`. undertow already filters
globals per client (`menus.c`), so this is a new rule, not a new mechanism.

### 4.4 A single file into a running jail — **nullfs mounts files.**

```
mount -t nullfs ~/granted.txt <jail root>/docs/granted.txt   # jail already running
```

- From inside, the file read back.
- An append from inside appeared in the real file.
- `/docs` listed only the granted file, and its sibling was outside the root.

**This is the document portal without FUSE.** It is how a URI-only
FileChooser can still grant one file and no more.

### 4.5 The plan, performed by hand — **it holds; two corrections.**

P18.1's plan for `build` in `app`, done step by step as root in the guest: a
tmpfs root, the four read-only nullfs mounts, the accounts compiled with
`pwd_mkdb -p -d <root>/etc`, then `master.passwd` and `spwd.db` deleted, then
`jail -c … enforce_statfs=2 devfs_ruleset=4 mount.devfs ip4=disable ip6=disable`.
Inside:
- `id` is `uid=1001(build) gid=1001(build) groups=1001(build)`: the person,
  without the wheel membership they have outside;
- `~` is `/home/build` and is writable, and `/usr` is read-only;
- there is no `master.passwd`.

The two corrections, now in the plan:
- `pwd_mkdb` reads `master.passwd(5)` form, so the plan carries the accounts in
  that form, and a passwd *file* is not part of it;
- the guest has no `/etc/localtime`, so a missing copy source is skipped.

### 4.6 P18.2 and P18.3 together — **GTK on the allowlist, from a real jail.**

In the guest: `abyss-jail hold app` (jaild as root, temporary roots). Then
`secctx` (the test's stand-in for the session), as the person, bound
`<root>/run/user/wayland-0` from outside the jail and registered it, with engine
`org.abyssbsd.jail`. Then `abyss-jail run app -- zenity --info`. undertow
reported:

```
window zenity/Information 224,195 352x209
window-jail zenity/Information engine=org.abyssbsd.jail app=org.gnome.Zenity instance=1
```

So GTK draws and maps with only the allowlist's 24 interfaces. The jail
never saw undertow's runtime directory: its socket is the jail's own, made
from outside. P18.5 is the same three steps, done by Anchor.

### 4.7 What 18b stands on — **all there.** (2026-10-02, in the guest)

- **Local inference is packaged.** Ports have `llama-cpp` (build 10975) on
  `ggml` 0.23.0 **with `VULKAN=on`** (it depends on `vulkan-loader`), and
  `ollama` 0.34.3. A local model on the 6750 XT is a packaging question, not a
  build. The live medium carries no `pkg` and none of these yet; the desktop
  set would carry them as it carries Firefox (§6b.1).
- **A crash can be read inside a jail.** A program killed with SIGSEGV in an
  `app` jail left `sh.core` in the jail's home. `lldb -c sh.core /bin/sh
  --batch -o "bt 3"`, *also inside the jail*, printed the stop reason and
  frames with source lines (`kill.c:127`). `lldb` 21 is in base.
- **But jailed programs inherit a core limit of 0.** They inherit jaild's
  limits, which the spike got from `sudo`; an rc.d daemon's may differ. Raising
  it inside the jail is refused. jaild should apply the person's login class
  (P18.9).
- **`vnet` jails work.** An `epair` end moved into a `vnet` jail took an
  address, and pinged the host's end across it.
- **No resource limits yet.** `kern.racct.enable=0` on GENERIC (§6.4 stands).

## 5. Verification

- Unit: `JailPlan`'s mounts, parameters and environment per class, with fault
  injections, on Linux and in the guest.
- Live: each pass's claims run on FreeBSD (the guest, using sudo) and skip on
  Linux. The Wayland filter (P18.3) runs on both: a security context needs no
  jail to test. A socket registered by the test is enough.
- 18a's gate on the 12700KF: screenshots of a confined Firefox and galculator,
  and the About line.

## 6. Risks and open decisions

1. **Opt-in or default?** *Recommendation: opt-in per application in 18a;*
   default-on once Firefox, galculator and zenity have run confined for a while.
   Default-on with an exceptions list is the end state, but the first broken
   application should not be the one a person needs today.
2. **A new root daemon.** *Recommendation: `abyss-jaild`, separate from
   `abyss-loginwindow`*: one job each, and the authenticator stays small. It
   reuses `Peer.swift` and the rc.d pattern.
3. **Where a jail's private home lives.** *Recommendation: a ZFS dataset per
   user and class (`zroot/abyss/jails/<user>/<class>`), and a plain
   directory on UFS.* The installer already creates ZFS. A home is kept
   between runs: an app's settings are its own, and not yours.
4. **Resource limits.** rctl needs `kern.racct.enable=1`, and GENERIC ships
   RACCT disabled by default. *Recommendation: defer limits to 18b*, where a
   runaway agent is the case. When that comes, decide between a loader tunable
   and our fork's kernel config.
5. **Network for `app-net`.** *Recommendation: host networking in 18a*. It is
   honest about what it is: a browser can reach the network and nothing of
   yours. Real per-jail `vnet` with an egress gate is 18b's.
6. **Sound and the GPU in a jail.** `app-gl` exposes `/dev/dri`. Sound is
   `/dev/dsp` in a ruleset now; PLAN's `virtual_oss` node per jail can come
   later. *Recommendation: ruleset-level in 18a.*
7. **What 18a does not do.** It does not confine the desktop's own components,
   the terminal or the shell. Those are you, acting as you.

### 6b. Decisions for 18b

1. **The model on the machine.** *Recommendation:*
   - the desktop set carries `llama-cpp`, `ggml` and `vulkan-loader` (with
     Mesa's RADV) as it carries Firefox;
   - **no model ships**: turning agents on downloads one, with the size and
     licence shown first;
   - a small open-weights instruct model by default (the choice of which is
     yours).

   Local stays the default; a remote provider is opt-in, through
   `abyss-model`.

   **Candidates, surveyed 2026-10-02** (released 2026-07-01 or later, open
   licence, native tool calling, GGUF for llama.cpp). The model is chosen by
   **the memory the machine has** when agents are turned on:

   | Tier | Machine | Default | Why |
   |---|---|---|---|
   | 0 | no usable GPU, or under 6 GB VRAM (CPU inference) | **MiniCPM5-2B**, Q4_K_M, 8K context (OpenBMB, 2026-09-07, 2.52B dense, Apache 2.0, 128K context) | official GGUF; passes multi-call tool tests at 4-bit through llama.cpp's server |
   | 1 | 8 GB VRAM | **Granite 4.2 8B**, Q4_K_M, **8K context** (IBM, 2026-08-25, ~9B dense, Apache 2.0, 128K) | native tool calling, a thinking switch, GGUF made with llama.cpp's own converter; 6.1 GB measured |
   | 2 | 12–16 GB VRAM (**the 6750 XT**) | **Granite 4.2 8B Q4_K_M, 16K context**; a 3B-active MoE as a step up, unmeasured (below) | 5/5 at 63 tok/s in 7.7 GB. Q8 was proposed first and **measured out**: it left the desktop 775 MiB |
   | 3 | 24 GB+ VRAM | **Granite 4.2 30B**, Q4_K_M (29B dense, Apache 2.0) | the same family's large size |

   **One family across tiers 1–3**, so the tool-call format, chat template and
   behaviour are the same whatever the machine; MiniCPM5-2B only where an 8B
   cannot run. The **MoE step up for tier 2**: a ~30–35B model with ~3B
   active, its experts in system RAM (`llama-server --n-cpu-moe`), which on
   12 GB cards runs at roughly 40–60 tokens/s in community reports. Candidates
   are Xing4.0-29B-A4B (China Telecom AI, 2026-09-22, Apache 2.0) and
   Nex-N2.5-Mini 35B-A3B (Nex AGI, 2026-09-08, Apache 2.0). Nemotron 3.5
   Lightning (NVIDIA, 2026-08-11) is held back: it is under the OpenMDW
   licence, and its hybrid architecture's early GGUFs had reported problems.

   **Measured 2026-10-02** on the 12700KF (RX 6750 XT, RADV, ports'
   `llama-cpp` build 10975), through `abyss-model`, with `measure-model.sh`:
   five desktop tool-calling prompts, one to be answered without a tool;
   thinking off; the focused application named in the system prompt.

   | Model | Where | Right | Speed | Memory | Verdict |
   |---|---|---|---|---|---|
   | Granite 4.2 8B Q4_K_M, 16K | 6750 XT | 5/5 | 63 tok/s | 7.7 GB VRAM (4.5 GB left) | **gpu12 default** |
   | Granite 4.2 8B Q4_K_M, 8K | 6750 XT | (same model) | | 6.1 GB VRAM | **gpu8 default** (16K is 7.7 GB: no room on 8 GB) |
   | Granite 4.2 8B Q8_0, 16K | 6750 XT | 5/5 | 40 tok/s | 11.4 GB VRAM (775 MiB left) | **not a default**: starves the desktop |
   | Granite 4.2 3B Q4_K_M | 6750 XT | 4/5 | | 3.2 GB VRAM | below the 8B |
   | MiniCPM5-2B Q4_K_M, CPU | i7-12700KF | 4/5 | 12 tok/s | 2.6 GB RAM | **cpu default**, the weak tier |
   | Granite 4.2 3B Q4_K_M, CPU | i7-12700KF | 4/5 | 8 tok/s | 3.8 GB RAM | slower than MiniCPM, same score |

   - **The context, not the slots, sets the VRAM**: about 0.2 MB per token for
     Granite 8B. `-np 1` saves little, but a session never needs more.
   - **Both small models miss the same case.** Asked to save, they explain
     the shortcut instead of calling `menu_activate`. Granite 3B misses it on
     the GPU too, so the CPU tier is weaker by its size, not its speed.
   - **On a CPU the first request is slow** (27–55 s): it is reading the tool
     definitions. Later ones take 2–6 s. P18.8 should keep the tool list
     short and fixed so the cache holds it.
   - **Thinking stays off for tool calls.** With it on, MiniCPM spent a
     256-token reply thinking and called nothing; Granite 8B Q8 was 5/5 but
     took 2–27 s. Without the focused application named, Granite 8B asked
     which one; that is the agent runtime's to supply.
   - Five prompts is a smoke test, not a benchmark. The 24 GB tier (Granite
     30B) and the MoE step-up are not measured: no machine here has 24 GB.

   **Before any of this was a default, it was to be measured here.** None of these
   has run on this project's machines. They must load under ports'
   `llama-cpp` (build 10975) and `ggml` 0.23.0 with Vulkan on RADV on the
   6750 XT, drive `abyss-model`'s tool-call path, and fit beside the desktop's
   own VRAM use. Vendor benchmarks are not evidence. Detecting the VRAM on
   FreeBSD (Vulkan's heap sizes, or amdgpu's own report) is part of P18.7.

   Sources: [LLM Releases tracker](https://www.llm-releases.com/);
   [Granite 4.2](https://huggingface.co/blog/ibm-granite/granite-4-2),
   [its GGUF](https://huggingface.co/ibm-granite/granite-4.2-30b-GGUF);
   [MiniCPM5-2B](https://github.com/openbmb/minicpm),
   [its tool-calling tests](https://betterstack.com/community/guides/ai/minicpm5-2b/);
   [Nemotron 3.5 Lightning sizes](https://runaihome.com/blog/nemotron-35-lightning-consumer-gpu-hardware-guide-2026/);
   [`--n-cpu-moe`](https://openclawdc.com/blog/llama-cpp-moe-offload-flags-explained/);
   [weight classes, September 2026](https://dev.to/klukyanov/the-local-llm-weight-classes-september-2026-what-actually-fits-on-your-machine-128d).
2. **What an agent may drive.** *Recommendation: only the applications a
   session was given*, by dragging an application onto the agent's window or
   picking it from a list. It is the same capability rule as files. "Every
   published vocabulary" would make the agent the person, which is what
   thesis 4 argues against.
3. **Where the loop runs.** *Recommendation: inside the agent's jail.* The
   loop is the part that acts on a model's output, so it is the part to
   confine. The window and `abyss-model` stay outside.
4. **The transcript.** *Recommendation: JSON lines under
   `~/.local/state/abyss/agents/<session>/`, append-only, kept until deleted
   from the Preferences pane.*
5. **The crash path for unconfined applications.** The keeper sees only
   confined programs exit. *Recommendation: confined first (P18.9); an
   unconfined application's crash comes later*, through `undertow` (its client
   gone) and the kernel's core, which is a separate pass.

