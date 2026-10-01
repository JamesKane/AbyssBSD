# Phase 16 — the session: login, lock, idle, power (scope)

A machine somebody else can use. Read [PLAN.md](PLAN.md) for where this sits
(it needs 6, 12 and 14, all done; it unblocks "a machine somebody else can
use"), [PHASE5.md §6.8](PHASE5.md) and [PHASE4.md §6.5](PHASE4.md) for the
login window that was never built, and [HANDOFF.md](HANDOFF.md) for the traps
that will bite here: §2.58 (a global with nothing behind it), §2.86 (idle is
the compositor's, and means one thing) and §2.97 (anchor's restart race when
the compositor exits).

Last updated: 2026-10-01. **Scoped, with the spikes run on the 16-CURRENT
guest** (§4), and **§6's recommendations adopted, all five**. What changed from PLAN before a line was written:

- **Idle is half done already.** BACKLOG U.9 gave `undertow` display sleep,
  idle-inhibit and ext-idle-notify (HANDOFF §2.86), so the lock screen's and
  system sleep's trigger exists; what is missing is the policy that listens.
- **Nothing unprivileged can check a password** (§4.2). OpenPAM's `pam_unix`
  needs root to read `master.passwd` — even a user checking their own
  password is refused. The lock screen and the login window both need a
  privileged authenticator, and it is the phase's first piece.
- **wlroots 0.20 has `wlr_session_lock_v1`** on both platforms (§4.1), so the
  lock is protocol plumbing in `undertow`, not a new design.

---

## 1. What this phase is

**Goal (PLAN):** a login window and multi-user sessions with `anchor` per
user; a screen lock over `ext-session-lock`, started by the idle clock; suspend,
lid and power; and a first-run assistant. **Verify:** lock and unlock live; a
suspend/resume cycle on the bring-up machine; two users, two sessions, one
machine.

**What it is not:** network accounts (LDAP, Kerberos), FileVault-style disk
encryption, parental controls, a screen saver beyond the lock, hibernation (S4)
and remote login. Not Phase 17's updates, and not a keychain — though the
authenticator is the shape a keychain's unlock would use later.

---

## 2. What we have vs. what's new

| Piece | Have | New |
|---|---|---|
| Starting a session | `rc.d/abyss_desktop` starts `anchor` as `abyss_desktop_user` — the account the installer made, **with no password asked** (PHASE5 §6.8) | a login window; automatic login only when chosen |
| Session supervisor | `anchor`: one session, its runtime dir, its components, Log Out (P10.8) | `anchor` per user, started by the login daemon with the user's credentials (`setusercontext`) |
| Privilege | `abyss-settings`, root, admits only `wheel` (P14.3) | an authenticator every user may ask about **their own** password (PAM, as root) |
| Idle | display sleep, idle-inhibit, ext-idle-notify in `undertow` (U.9) | the policy that listens: lock after N minutes, sleep the computer after `energy.ini`'s `system_sleep_minutes` |
| Lock | nothing | `ext-session-lock-v1` in `undertow`; an Aqua lock screen |
| Power | Energy Saver writes delays and powerd (P14.8); the system menu's Sleep, Restart and Shut Down are drawn disabled, "needs a privileged helper" | suspend (`acpiconf -s 3`), restart and shut down through the helper; the lid and the power button through `devd` |
| Accounts | the installer creates one (P5.4) | an Accounts pane: add and remove users, automatic login |
| First run | the installer's hub-and-spoke (P5.4) | a Setup Assistant on that shape |

---

## 3. Ordered passes

In the order that pays soonest, each with its own live test (§5).

**P16.1 — the authenticator (S–M).** A small root daemon, `abyss-loginwindow`
(§6.1), on a CurrentIPC socket every user may reach. One method now: *is this
my password?* The caller's uid comes from the socket (`SO_PEERCRED` /
`LOCAL_PEERCRED`), never from the request, so a user can only ask about
themselves; answers are rate-limited per uid (Jaguar's "shake" plus a growing
delay), and nothing is logged but the outcome. PAM service `abyss`
(`/etc/pam.d/abyss`, `include login`'s auth stack). Linux refuses, as the
settings helper does. *Verified (guest, with a throwaway account):* the right
password is accepted, a wrong one refused with the delay, another user's
password refused whatever it is, and the password never in a log.
✅ **Done 2026-10-01.** `Login` (pure: the `Limiter` — two typos free, then
2 s, 4 s, … five minutes per uid, refusing unasked while it runs; the wire; the
`Authenticator`'s decision; the client), `CPAM` (PAM's conversation in C,
wiping its copies), `abyss-loginwindow` (root, `/var/run/abyss-loginwindow.sock`
0666, the caller from `ap_peer_uid`) and `abyss-loginctl`. CurrentIPC can now
bind and connect an explicit path. The PAM stack ships from the tree
(`abyss/etc/pam.d/abyss`: `pam_unix` with `nullok`, **no `include login`** —
its `pam_self` would pass a root session on anything) with its rc.d script
(`abyss/etc/rc.d/abyss_loginwindow`); the medium carries both and enables it,
and an installed desktop enables it for every account. 8 unit tests;
`live-authenticator.sh` (guest, as root, two throwaway accounts asking as
themselves; Linux: the refusal in words). **Found:** the build VM's root has
no password, so `nullok` accepts it with anything — FreeBSD's rule for an
account with nothing to check, not a hole (HANDOFF §2.100). The medium's and
installed system's new checks (`live-medium.sh`, `live-desktop.sh`) are in the
`--full` lane and have not run yet.

**P16.2 — the screen lock (M–L).** `undertow` serves `ext-session-lock-v1`
(wlroots' helper): while locked, every output shows the lock client's surface
and nothing else, input goes only to it, and **if the lock client dies the
session stays locked** — a plain screen that says so, never the desktop
(wlroots' and sway's rule; the dangerous direction is the other one). The lock
client is an Aqua scene: the account's picture and name, a password field, the
"shake" on a refusal — asking P16.1. Locked from the system menu ("Lock
Screen", ⌃⌘Q as macOS has it) and by `abyss-lock`. *Verified:* locked, the
desktop's pixels are gone from the capture and a click on where a window was
reaches nothing; the right password unlocks; a wrong one shakes; killing the
lock client leaves the capture locked.

**P16.3 — the idle policy (M).** A session component (an ext-idle-notify
client `anchor` supervises) that turns idleness into what a person asked for:
lock after the Security pane's delay ("require a password after sleep or
screen saver begins", Jaguar's wording), and sleep the computer after
`energy.ini`'s `system_sleep_minutes` — which the Energy pane has written since
P14.8 and nothing has read. One idea of idle (§2.86): an inhibitor holds both.
*Verified:* with seconds for minutes, idleness locks; an inhibitor holds it off;
the system-sleep request reaches the helper (P16.4's stand-in).

**P16.4 — suspend, lid and power (M).** Sleep, Restart and Shut Down in the
system menu become real, through the daemon (root): `acpiconf -s 3`,
`shutdown -r now`, `shutdown -p now`. The session is locked *before* the
machine sleeps, so it wakes locked. `devd` turns the lid (`ACPI Lid 0`) and the
power button (`ACPI Button 0`) into requests to the same place, with a policy
(lid closes → sleep; power button → the Jaguar dialog: Restart, Sleep, Shut
Down). On resume `undertow` re-enables its outputs (it already knows how:
U.9's display sleep) — and amdgpu's own resume is the metal risk (§6.3).
*Verified in the harness* with a stand-in `acpiconf` that records the request
(§6.3); *on metal* a real suspend/resume cycle on the 12700KF, waking locked.

**P16.5 — the login window (L).** `abyss-loginwindow` grows its second job,
shaped like `greetd`: at boot `rc` starts it, it starts a **greeter session** —
`undertow` and the Aqua login window, as an unprivileged `_loginwindow` user —
and, when the greeter has authenticated someone (P16.1's PAM), ends the greeter
and starts that user's session: `setusercontext(LOGIN_SETALL)`, their runtime
directory, `anchor` as them. Log Out returns to the login window. Jaguar's list
of accounts with pictures, or name-and-password (a later preference).
Automatic login stays, as a choice (§6.2). *Verified:* in the guest, the login
window comes up, a wrong password shakes, the right one starts the session as
that user (its processes' uid, its runtime dir), Log Out brings the window back;
and `live-desktop.sh` — empty disk to desktop — logs in through it.

**P16.6 — two users (L).** The Accounts pane: add and delete a user (through the
settings helper, an administrator only), their picture, automatic login on or
off. Two sessions on one machine: fast user switching puts the second on its
own VT through seatd (§6.4), the first locked behind it. *Verified:* two users,
two sessions, one machine — in the harness headless, as two sessions side by
side with each user's processes and files their own; on metal, switching VTs.

**P16.7 — first run (M).** A Setup Assistant at an account's first login, on the
installer's hub-and-spoke shape (§6.5). *Verified:* a fresh account sees it
once, its choices are written where the panes read them, and the second login
goes straight to the desktop.

**P16.8 — the gate.** Both lanes, `--full`, and the metal checks the harness
cannot make: a real suspend/resume, a lid, a VT switch.

---

## 4. The spikes

### 4.1 Session lock in wlroots 0.20 — **there, on both platforms.**

`wlr/types/wlr_session_lock_v1.h` is installed on Linux and in the 16-CURRENT
guest, beside the idle-notify and idle-inhibit headers U.9 already uses.

### 4.2 Can a lock screen check a password itself? — **No. Nothing unprivileged can.**

A 30-line OpenPAM program (`pam_start` + `pam_authenticate`, service `other`),
in the guest, against a throwaway account `spike16` with a known password:

| Who asks | Password | Answer |
|---|---|---|
| `build` (uid 1001) | right | Authentication error |
| root | right | **Success** |
| root | wrong | Authentication error |
| **`spike16` itself** | right | **Authentication error** |

`pam_unix` reads `master.passwd`, which only root can — so **even a user
checking their own password is refused**. There is no `unix_chkpwd`-style setuid
helper in FreeBSD's base. Hence P16.1 first: a root authenticator every user may
ask about themselves. (The account was deleted afterwards.)

### 4.3 Sleep in the guest — **S3 offered; resume unknown.**

`hw.acpi.supported_sleep_state: S3 S4 S5`, `acpiconf` and `zzz` present, and
`devd.conf` already documents the `ACPI` `Lid` and `Button` notifies. But the
build VM is QEMU with `-monitor none`: a guest that suspends cannot be woken
without restarting it, so a suspend was **not** attempted on the shared build
box. Whether the harness can test a real suspend/resume is §6.3.

### 4.4 Seats and VTs — **seatd and vt(4) are present.**

`seatd` installed, `kern.vty=vt`, `/dev/ttyv0…`. A headless harness cannot
switch VTs; two sessions side by side is what it can show (P16.6), and a VT
switch is a metal check.

---

## 5. Verification

As every phase since 9: each piece driven live under `undertow`, clicked and
typed by the virtual pointer and keyboard, asserting on the thing — a
capture's pixels while locked, a process's uid, a file's owner, a request the
stand-in recorded — on Linux and the FreeBSD guest, with the root parts (PAM,
`setusercontext`, `acpiconf`) on the guest only and Linux refusing in words.
The pure parts (the rate limiter, the idle policy's arithmetic, the account
list) are unit-tested. And the PLAN's three metal checks on the 12700KF.

---

## 6. Risks and open decisions

**6.1 One privileged daemon, or several.** The authenticator (P16.1), the login
greeter (P16.5) and power (P16.4) all need root. Options: (a) **one daemon,
`abyss-loginwindow`**, that authenticates, starts sessions and carries out
power requests — like `greetd`, the smallest thing that owns a seat;
(b) extend `abyss-settings` — but it admits administrators only, and every user
must be able to unlock their own screen; (c) one daemon each. **Recommendation:
(a)** — one small root process with three verbs, the caller's uid always from
the socket; `abyss-settings` keeps the administrator's jobs (users, network,
energy). **Decided (user, 2026-10-01): (a).**

**6.2 Automatic login.** Today an installed machine logs its installer-made
account in with no password. Options: (a) **the login window by default, and
automatic login a choice in the Accounts pane** — Jaguar's own default for a
machine with one user was automatic login; (b) keep automatic login the
default for a one-account machine, as Jaguar did, and show the window once a
second account exists. **Recommendation: (a)** — a FreeBSD machine that starts
a desktop without a password, with `sudo` one keystroke away for an
administrator, is the wrong default in 2026. The live medium keeps its
automatic `abyss` session. **Decided (user, 2026-10-01): (a).**

**6.3 Testing suspend.** Options: (a) **a stand-in `acpiconf` in the harness**
(records the request; the lock-before-sleep order and the resume path through
`undertow`'s output re-enable are still exercised) **plus a real cycle on the
12700KF**, as PLAN says; (b) also try a real S3 suspend/resume in a QEMU guest
— a disposable VM with a QMP socket and `system_wakeup` — a spike of unknown
cost, since FreeBSD's resume under QEMU is not something this project has
seen work. **Recommendation: (a)**, with (b) as a later experiment if (a)'s
metal result is a surprise. amdgpu's resume on drm-kmod is the real risk, and
only metal answers it. **Decided (user, 2026-10-01): (a).**

**6.4 Two sessions: fast user switching, or one at a time.** Options: (a)
**fast user switching** — the second session on its own VT through seatd, the
first locked behind it (Jaguar 10.3 brought it; 10.2 logged out); (b) one
session at a time: Log Out, then the next person logs in — simpler, and 10.2's
own behaviour. **Recommendation: (b) first, (a) after** — P16.5 makes (b) work
end to end, and (a) adds a VT and a seat handover that only metal can test;
PLAN's "two users, two sessions" is met by (a) only, so it stays in the phase
as P16.6's second half. **Decided (user, 2026-10-01): (b) first, then (a).**

**6.5 First run.** The installer already asks for the keyboard, the time zone
and the account. Options: (a) **a short Setup Assistant at an account's first
login** — Welcome, Network (Wi-Fi), Appearance — skippable, once; (b) none:
the installer is the first run; (c) move account creation out of the installer
into a first-boot assistant, as macOS does — a rework of P5.4 and of the
nested install test. **Recommendation: (a)**, small. **Decided (user,
2026-10-01): (a).**

**6.6 The lock screen is the security boundary.** A bug in `undertow`'s lock —
a surface drawn over the lock, a key routed past it, an output added while
locked that shows the desktop — is a bypass. The test asserts the dangerous
directions explicitly (P16.2: a dead lock client stays locked; a capture shows
no desktop pixels; input reaches nothing behind), and each is fault-injected.
