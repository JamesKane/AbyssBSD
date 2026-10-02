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

**P18.5 — launching confined (S–M).**
An application's bundle or `.desktop` file declares its class with
`X-Abyss-Jail=`. `abyssopen`, the Dock and the Finder launch through Anchor,
which holds the jail and process descriptors in its `kevent`. Confinement is
**opt-in per application** in 18a (§6.1). The application menu shows
"Confined (app)" in About, so it is visible, not assumed.

Live test in the guest:
- galculator by its bundle runs with a non-zero jid;
- quitting it leaves the jail pooled;
- logging out removes the jail.

**P18.6 — the gate for 18a (S).**
The stack proof in the guest: galculator and zenity confined, Firefox in
`app-net`. Then the same on the 12700KF.
- a confined zenity cannot `ls ~`;
- Firefox renders a page and cannot read `~/.ssh`;
- a file opened from the Finder edits in place.

Every 18a live test is in `run.sh`, and its Linux leg skips cleanly.

### 18b — agents (listed; re-scoped after P18.6)

- **P18.7 — the stub model and the wire format.** One wire format,
  OpenAI-compatible chat completions with tool calls. llama.cpp's server and
  ollama both speak it, and so does every provider. A stub backend with canned
  replies and tool calls makes every 18b test hermetic. **We do not write an
  inference engine.**
- **P18.8 — the agent's tools are the vocabulary.** Phase 10's published menu
  vocabulary, consumed exactly as `abyssmenu` and a script consume it. Pixels
  only for an application that cannot describe itself.
- **P18.9 — the crash, first.** "Application quit unexpectedly" gets a button.
  It opens a `debug`-class session that sees one process (its core and its
  binary) and nothing else, reads and reports, and writes nothing. No network
  and no vocabulary, so it can land first.
- **P18.10 — the four requesters, the transcript, the budget.** A sheet for
  each of the four (PRODUCT §4.4), and no others. An append-only transcript that
  outlives the process. A budget line that stops at the next tool call and shows
  why.
- **P18.11 — network for agents.** `vnet` per class, with egress through the
  process that holds the credential (outside the jail), and egress to a new host
  as requester 3. Local models first: on the 12700KF, ggml's Vulkan backend
  under RADV (PLAN: checked available, never run).
- **P18.12 — the agent application, state on the Dock, the menu bar and the
  island switcher, and off as one file.**
- **P18.13 — the gate.** PLAN's verify list.

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
