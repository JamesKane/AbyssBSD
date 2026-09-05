# Proposal — a shell on the medium, from this side of the room

A development tool for Phase 4's bring-up loop: `sshd` on the live medium,
reachable from the local network only, off unless the image is built for it.
Read [PHASE4.md](PHASE4.md) §6.4 for the problem it answers, [PHASE5.md](PHASE5.md)
§4.3 for the live session it has to sit beside, [PHASE12.md](PHASE12.md) §4.4 for
the retrieval path it must **not** become, and [HANDOFF.md](HANDOFF.md) §2.47 for
what the console does when `getty` arrives.

Last updated: 2026-09-05. **Proposed, not implemented.** Everything in §2 was
measured against the distribution sets and the rc scripts on the build VM on that
date, not remembered; §5's live half cannot be measured anywhere but on metal, and
says so.

---

## 1. What this is

> The medium can already **say** things. It cannot be **asked** anything.

`abyss-live-session` reports on itself to the console because on a headless
medium the console is the only channel there is. On metal that is still true, and
now it is a 2560x1440 panel in another room: every number is photographed,
every log is read by eye, every experiment costs a rebuild, a `write-stick.sh`,
a walk and a reboot. PHASE4 §6.4 states the cost — *"a person is in the loop, and
people are slow"* — and proposes the only mitigation available at the time: make
the medium say more per boot.

This is the other half. One shell on the machine turns a boot into a session.

**The claim, in one sentence:** the medium gains a key-only `sshd` that answers
on the local network and nowhere else, carries no new byte the medium did not
already carry, is absent from any image not built with `--ssh`, and is never the
way a report gets off a stranger's machine.

---

## 2. Why it is nearly free, measured

The medium is assembled out of `base.txz` and `kernel.txz`
(`abyss/mk/live-image.sh`), both extracted whole. **OpenSSH is in base**, so the
entire mechanism is already inside `$stage` before the first line of our own
configuration runs:

| Wanted | Where it already is |
|---|---|
| `sshd`, `sshd-session`, `sshd-auth` | `base.txz` — `./usr/sbin/sshd`, `./usr/libexec/sshd-{session,auth}` |
| the client, for the other direction | `./usr/bin/ssh`, `./usr/bin/scp`, `./usr/bin/ssh-keyscan` |
| **`scp` in OpenSSH 9+ speaks SFTP** | `./usr/libexec/sftp-server` — so pulling a log or a `.ppm` off works |
| key generation | `./usr/bin/ssh-keygen` |
| the service | `./etc/rc.d/sshd` (`PROVIDE: sshd`, `REQUIRE: LOGIN FILESYSTEMS`) |
| the privsep account | `master.passwd`: `sshd:*:22:22::0:0:...:/var/empty:/usr/sbin/nologin` |
| the firewall | `kernel.txz` — `./boot/kernel/pf.ko`; `base.txz` — `./etc/rc.d/pf` |

OpenSSH **10.0p2** on 15.0-RELEASE-p11.

**This is the part that matters for this build script in particular.** Every
expensive lesson in `live-image.sh` is about things that are *not* in the sets —
`pkg` closures that came out at 5.66 GB (PHASE5 §4.3), `ldd` closures that missed
what something `dlopen`s (PHASE4 §5.3), a driver chain three links deep where
missing the middle one names none of it (§5.5). **None of that machinery is
touched here.** No `pkg fetch`, no root set, no closure. The image grows by a host
key — about 4 KB.

The one thing to add to the medium that is *not* already there is our own
configuration: five lines of `sshd_config`, a `pf.conf`, an rc script that seeds
one table, two `authorized_keys`, and two lines of `rc.conf`.

---

## 3. What it buys, in work that is already queued

- **P4.5 — C1 against a real vblank.** `undertow bench-metronome` prints period
  estimate, latch margin, composite cost p50/p99/p99.9, missed flips per mille
  and the clock it measured against. Today those numbers leave the machine as a
  photograph. `scp` instead — and `fathom --measure`'s report with them. (Note
  `fathom` is **not** in `BINARIES` in `live-image.sh` yet; P12.5 puts it there,
  and this proposal is worth much more after it does.)
- **The PHASE4 §5.6 class of bug.** *"The installer came up, then exited after
  about thirty seconds and `anchor` restarted it"* took a full rebuild → stick →
  walk → reboot cycle per hypothesis. With a shell: `tail -f
  /var/log/abyss-live.log`, re-run `undertow` by hand with different flags, and —
  because the medium's root is mounted **rw** — `scp` a freshly built binary onto
  the running machine and try it **without rebuilding the image at all.** That is
  the single largest win here.
- **Driving the installer remotely, which is the ask this began as.**
  `abyss-install` accepts commands from exactly one uid, checked with
  `getpeereid` on its unix socket (`de/installrun/Peer.swift`). A shell that
  arrived over the network is still uid 1001, and `~abyss/.profile` already
  exports `ABYSS_RUNTIME_DIR`. So **`abyss-installctl` over ssh works today with
  no code change** — a complete CLI install path on a machine whose GUI installer
  is still being brought up.
- **The second row of the matrix** (PHASE4 §6.7, PLAN thesis 5). Bring-up on a
  machine we do not own is a machine we cannot walk to.

---

## 4. Design

Six pieces. Three of them exist only because of things this medium does that an
ordinary FreeBSD system does not.

### 4.1 A build flag, default off

`abyss/mk/live-image.sh --ssh [PUBKEY]`, or `ABYSS_LIVE_SSH=1`, alongside the
existing `--stay` / `ABYSS_LIVE_TRACE` pattern — both of which are already
"decided when the image is built, with nowhere to live at boot time on a medium
that has no configuration of its own".

Default **off**, and the absent case is the one the test writes first (§5).
The failure this prevents is `P12.2`'s in a new costume: **a debug medium that
quietly becomes the medium.** A published image must not carry a listening socket
and a key somebody's laptop also has. The image drops `/etc/abyss-live-ssh` as a
marker so the boot banner, and a test, can both tell which kind of medium this is.

Default key: `$ABYSS_SSH_KEY.pub` from `abyss/vm/config.sh` — the same key that
already reaches the build VM, so there is nothing new to manage.

### 4.2 Key only — and on this medium that is load-bearing, not stylistic

`live-image.sh` gives **root an empty password** and appends
`abyss::1001:...`, both deliberately: *"the console IS the machine on a live
medium, and one you cannot log into is one you can neither rescue nor drive."*
That argument is exactly right for a console and exactly wrong for a network.

The pristine `/etc/ssh/sshd_config` in `base.txz` is **entirely commented out**,
so what governs is OpenSSH's compiled-in defaults. FreeBSD's own comments in that
file record them: `#PermitRootLogin no`, `#PasswordAuthentication no`,
`#PermitEmptyPasswords no` — but `#KbdInteractiveAuthentication yes`. The
defaults are on our side today. **Depending on that is one PAM path away from an
unauthenticated root shell on the LAN**, so pin all of it, in a file a test can
grep:

```
# The live medium's sshd. Both live accounts have EMPTY passwords, so every
# password path is off by construction rather than by default (§4.2).
PermitRootLogin prohibit-password
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitEmptyPasswords no
UsePAM no
AuthorizedKeysFile .ssh/authorized_keys
Subsystem sftp /usr/libexec/sftp-server
```

**Two accounts, two keys, two jobs** — and the split is not optional, because of
a third thing this medium does not have:

- `abyss` (uid 1001) — the session's own user, and therefore the only uid the
  installer will take orders from. This is the `abyss-installctl` path.
- `root` — troubleshooting: `kldstat`, `dmesg -a`, restarting the session,
  dropping a rebuilt binary into `/usr/local/bin`.

There is **no path from one to the other**: `base.txz`'s `/etc/group` has
`wheel:*:0:root`, `live-image.sh` adds `abyss` to `video` and nothing else, and
FreeBSD base has no `sudo`. So `su` from the session's user fails, and if the
proposal only installed one key it would deliver the wrong half of what it is
for.

### 4.3 Local network only — asked of the machine, not baked in

`ListenAddress` is out: the medium is `ifconfig_DEFAULT="DHCP"` and has no idea
what address it will have. So `pf`, with a **fail-closed rule and no default
block**:

```
# /etc/pf.conf — the live medium.
table <lan> persist
set skip on lo0
block drop in quick proto tcp to port 22 from ! <lan>
```

Two properties, both deliberate:

- **An empty table blocks ssh from everywhere**, including the LAN — because
  every source is then "not in `<lan>`". The failure direction is closed.
- **Nothing else is filtered.** A default-block ruleset on a machine whose only
  other channel is a monitor in another room is a way to lose DHCP and the
  desktop at once. This rule can only ever cost us the thing it guards.

`<lan>` is seeded at boot from **what the machine actually has** — each
interface's own CIDR out of `ifconfig -f inet:cidr`, plus `fe80::/10` — rather
than from a baked-in RFC1918 list that is wrong on a `100.64/10` LAN:

```sh
# /etc/rc.d/abyss_lan — PROVIDE: abyss_lan / REQUIRE: pf netif / after DHCP.
for net in $(ifconfig -f inet:cidr | awk '/inet /{print $2}' | \
             grep -v '^127\.' ); do
    pfctl -t lan -T add "$(printf '%s' "$net" | \
        sed 's|\.[0-9]*/|.0/|')"      # host address -> its network
done
pfctl -t lan -T add fe80::/10
```

Same rule as the backend choice and the foreground/background choice already in
this tree: **ask the machine, do not take a flag.** `Match Address` in
`sshd_config` is available as belt to this brace and costs nothing.

**IPv6 link-local is a real fallback, not a footnote.** `fe80::/10` in the table
means a crossover cable and `ssh abyss@fe80::…%igc0` works with no DHCP server
anywhere — which is precisely the machine that most needs troubleshooting.

### 4.4 Ordering, which currently works by luck

`abyss_live` is `REQUIRE: LOGIN`. `sshd` is `REQUIRE: LOGIN FILESYSTEMS`. That is
a **tie**, and rcorder resolves it incidentally. Measured over the real
`/etc/rc.d` with `abyss_live` added:

```
 74: pf
160: LOGIN
162: sshd
163: abyss_live
```

One slot apart, in the order we want, for no reason we wrote down. It matters
because in the **headless** path `abyss_live_start` runs the session in rc's
**foreground and blocks** (PHASE5 §4.3 — and it must, because a backgrounded
session goes silent the moment `getty` revokes the console, §2.47). If that
tie ever flipped, sshd would never start — on exactly the machine that could not
be reached to find out why. One word fixes it, and it is an ordering rather than
an enabling, so it is harmless when ssh is off:

```
# REQUIRE: LOGIN sshd
```

### 4.5 The host key is generated at build time

`/etc/rc.d/sshd` will generate one at first boot — the root is `rw`, so it works.
Do it in `live-image.sh` anyway:

- the fingerprint is then **stable across boots**, so `known_hosts` does not
  churn and the console banner can print a fingerprint worth comparing;
- the boot does not spend time on it;
- it survives the change `live-image.sh` already owes: *"a medium on a real USB
  stick wants a read-only root … it is the thing to fix before anyone puts this
  on a stick."* A key generated at boot does not survive that; one baked in does.

Ed25519 only. The private half lives in an image built with `--ssh`, which is
the whole reason `--ssh` images are never published (§4.1).

### 4.6 The medium says where it is

`dhclient` is asynchronous — `netif` returns before a lease arrives — so there is
no address at the moment sshd binds (harmless: it binds the wildcard). But the
person at the console needs one. `abyss-live-session`'s `run()` already prints
the backend it chose and the state of the installer socket; it gains a line in
the same voice, after a short wait for a lease:

```
abyss-live: ssh is ON — abyss@192.168.1.57  (also fe80::…%igc0)
abyss-live: host key SHA256:… — local network only
```

This is PHASE4 §6.4's instinct followed to its end: **one boot answers several
questions**, and the first of them is now "how do I ask it anything else".

---

## 5. Verification

**What the VM can check, it checks** — the rule P4.3 already works by.

`live-medium.sh`, extended, with the **absent case written first** (the discipline
PHASE12 §5 states and `InstallRunTests` keeps):

| Built | Assertion |
|---|---|
| default | no `/etc/abyss-live-ssh`, no `sshd_enable` in `rc.conf`, no host key, no `pf.conf`, no `authorized_keys` — **the shipped shape is the tested shape** |
| `--ssh` | the marker exists; `sshd_enable="YES"`; an ed25519 host key with mode 600; `sshd_config` carries all five pinned keywords; `pf.conf` carries the fail-closed rule; `~root/.ssh/authorized_keys` and `~abyss/.ssh/authorized_keys` exist, mode 600, owned by 0 and 1001 |
| `--ssh` | `rcorder` over the medium's own `/etc/rc.d` puts `sshd` before `abyss_live` — an assertion on the ordering, since §4.4 is why the declaration was added |

**What the VM cannot check: whether it answers on a wire.** The nested boot in
`live-medium.sh` has no network device at all —
`-s 0,hostbridge -s 31,lpc -s 4,virtio-blk` — and giving it one means a tap, a
bridge and a DHCP server inside the build VM to serve a nested guest. That is a
disproportionate amount of new apparatus for a development tool, and it is the
same shape as `si_support`: *what a VM can check, it checks; what it cannot is
whether the thing binds on real hardware.*

So reachability is **step 7 of the PHASE4 §5 checklist**, on metal, once. The
network side of it is already a recorded positive result rather than a hope:
`igc0: link state changed to UP` and a DHCP address, PHASE4 §3 (P4.6) and §5.

---

## 6. What this must not become

PHASE12 §4.4 chose the ESP as the way a report leaves a machine, for a stated
reason: *"the matrix depends on strangers sending reports back, which means the
retrieval path cannot assume a network — thesis 5's weakest area is exactly the
machines where the network does not come up."*

**Nothing here changes that, and this proposal is not a step toward changing it.**
`sshd` on the medium is a tool for **us**, on **our** LAN, during bring-up. It is
useless on the machines P12.5 exists to serve, since those are the ones whose
network is the problem. Two rules follow, and they are the price of the feature:

1. **No published medium carries it.** Default off, marker file, and the VM test
   asserts the default build is clean.
2. **No product feature may come to depend on it.** If a report, an install, or a
   probe ever needs a network to be retrievable, that is a regression against
   thesis 5 no matter how convenient this made it.

---

## 7. Risks and open decisions

**7.1 It is a second way in, and it is the good one.** The console on a live
medium is already an unauthenticated root shell for anyone standing at the
machine. This adds a *key-gated* path from one room away. The exposure it adds is
real but bounded: one TCP port, one algorithm, no passwords, one subnet, on a
transient artifact, in an image nobody else has.

**7.2 It assumes the bring-up machine and the dev box share a LAN.** They do
today. If the 12700KF ever moves, §4.3's `fe80::/10` and a cable are the
fallback, and that is why it is in the table.

**7.3 The medium under test stops being the medium that ships**, whenever
`--ssh` is passed. Mitigated by §4.1 and by the first row of §5's table, and
worth restating because this project has already been bitten by a workaround that
was carried unconditionally (P12.2).

**7.4 Ethernet only.** No wifi firmware, no `wpa_supplicant` configuration, and
none proposed. A machine that can only be reached over wireless cannot be reached.

**7.5 A cheaper adjunct, if two-way is not wanted.** One line in
`/etc/syslog.conf` (`*.* @<dev box>`) streams the console log off the machine with
**no listening socket at all** — no auth surface, no `pf`, nothing to gate. It
answers "what did it say" and not "what would it say if I asked", so it is not a
substitute for this; it is the thing to do instead if §7.1 is ever judged not
worth it.

**7.6 Open: does `--ssh` imply `--stay`?** A medium built for remote
troubleshooting that powers itself off two seconds after the session ends is a
medium you cannot ssh into. `--stay` already exists for exactly this reason
("never power off a machine somebody is looking at"), and somebody at the other
end of an ssh session is looking at it. Probably yes; not decided here.

---

## 8. Cost, and where it goes

| Piece | Size |
|---|---|
| `live-image.sh` — flag, key, `sshd_config`, `pf.conf`, `rc.conf`, `authorized_keys` | ~70 lines |
| `/etc/rc.d/abyss_lan` — seed the table | ~15 lines |
| `abyss-live-session` — the banner (§4.6) | ~10 lines |
| `abyss_live` — `REQUIRE: LOGIN sshd` | 1 word |
| `live-medium.sh` — both cases | ~25 lines |
| Image size | one host key, ~4 KB |

**Half a day, and one boot to prove it.**

**Where in the order:** it is a *tool*, so it earns its place only by paying for
itself in the passes that follow it. Best placed **before P4.5** — the pass that
produces numbers somebody currently photographs — and it is worth more after
P12.5 puts `fathom` on the medium. It is not a phase, it does not gate anything,
and if bring-up finishes without it that is the correct outcome, not a debt.
