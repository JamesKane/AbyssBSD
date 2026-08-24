# Phase 5 — the installer: a machine with an empty disk (scope)

The last phase that depends on nothing. Read [PLAN.md](PLAN.md) for the locked
decisions, [PHASE8.md](PHASE8.md) for the session this installs, and
[HANDOFF.md](HANDOFF.md) for the interop traps.

Last updated: 2026-08-24. **P5.1–P5.3 are done; P5.4 is next.** Four risks were spiked first,
on the target (§4), because the phase's shape depended on the answers — and two
of them were the phase's whole feasibility question. The passes below are written
knowing that a program we wrote can install a bootable FreeBSD, and that the
harness can prove it booted without a human, a disk or a second machine.

---

## 1. What this phase is

Every phase so far has been verified by running a program. This one is verified
by **a machine that boots**.

The claim in one line:

> A machine with an empty disk boots our medium, someone clicks through an Aqua
> installer, and it reboots into the Jaguar desktop.

Nothing above this line is new capability — the desktop exists, and P8.4 boots it
with one command. What is new is **getting it onto a disk that had nothing on
it**, which is the one thing standing between "a desktop that runs" and "an
operating system somebody can install".

### The decision the phase turns on: the GUI does not touch the disk

```
  Installer      (Aqua, an ordinary unprivileged Wayland client)
      │   CurrentIPC — a plan goes in, progress comes back
      ▼
  abyss-install  (root; no toolkit, no display, no network)
      │   gpart / zpool / tar
      ▼
  the disk
```

Four reasons, in ascending order of how much they matter:

1. **It is `abyss-portal`'s shape exactly** — an unprivileged asker, a privileged
   doer, and a socket between them. Phase 7 already argued this case.
2. **The GUI half develops on Linux**, where `gpart` does not exist and never
   will. The both-platforms rule stays payable.
3. **The dangerous half has no GUI**, so *the harness can drive it*. This is the
   difference between an installer that is tested and one that is demonstrated:
   §5's live test installs a real system and boots it, on every run, with nobody
   watching.
4. **An installer is the one program in a desktop that is supposed to destroy
   data.** Every other component in this tree is written so that its worst bug
   loses a frame. This one's worst bug loses somebody's disk. Keeping the
   destructive verbs in a program with no event loop, no toolkit, no fonts and no
   network is worth more than any elegance we would gain by merging the two.

**The executor checks who is calling.** `CurrentIPC` makes its runtime directory
0700 and its sockets 0600, which is the right default and is exactly wrong here:
a root-owned socket at 0600 is unreachable by the very GUI that must command it
(§4.4). The answer is not to loosen the mode until it works — it is for
`abyss-install` to ask the kernel who is on the other end (`getpeereid` on
FreeBSD, `SO_PEERCRED` on Linux) and refuse anyone who is not the session user it
was started for.

### Explicitly NOT in this phase

- **No metal.** PLAN.md's verify says "onto the Mac Pro (and the VM)". The VM
  half is this phase; **the Mac Pro half is Phase 4's**, because installing onto
  that machine first requires that machine to boot FreeBSD with a working GPU.
  Saying so now is cheaper than discovering it in P5.5.
- **No dual-boot, no preserving an existing layout.** v1 takes a whole disk and
  writes a GPT over it. "Install alongside" is a partition-shrinking problem and
  a separate piece of work.
- **No network install.** The medium carries everything it installs — see §6.2,
  where this is an argument about the target hardware, not about effort.
- **No mirrors or RAID-Z.** One pool, one disk. The plan is a value (P5.1) and
  gains a `vdevs` list later without changing anything else.
- **No upgrade path.** Installing over an existing AbyssBSD is an install.

---

## 2. What we already have vs. what's new

| Need | Have | New in Phase 5 |
|---|---|---|
| A desktop to boot into | the whole tree, Phases 0–3 and 6–8 | nothing |
| A session that starts with one command | `anchor` + `SessionPlan` (P8.4) | the live session variant: autologin, one app, no Dock |
| A plan as a testable value | `SessionPlan` (P8.4) is the pattern | `InstallPlan` + its step list |
| An unprivileged asker / privileged doer | `abyss-portal` (P7.1) | the peer-credential check (§4.4) |
| Aqua widgets for a wizard | buttons, fields, lists, sheets, progress (Phase 1–2) | the hub-and-spoke shell, a disk picker |
| Disk machinery | — | `gpart`/`zpool`/`tar`, driven from Swift |
| A bootable medium | — | `makefs` + `mkimg` (§4.3) |
| Somewhere to test it | the build VM | a file-backed disk + nested bhyve (§4.2) |

---

## 3. Ordered passes

**P5.1 — `de/install`: the install as a value. ✅ done.**
`InstallPlan` — disk, scheme, pool name, dataset layout, swap size, which sets to
extract, hostname, users, timezone, keymap — and the **step list** it compiles
to: the exact `gpart`, `newfs_msdos`, `zpool`, `zfs` and `tar` invocations, in
order, each with what it means if it fails. Pure, in `SessionPlan`'s image: it
resolves nothing, spawns nothing and reads no environment, so **the whole thing
is unit-testable on Linux**, where not one of those commands exists.

The safety predicate lives here too, and it is the reason this pass is first: a
plan that names a disk which is mounted, or which holds the running root, or
which is not a whole disk, is **rejected before a step list is compiled at all**.

"Is it mounted" is not a pure question, so the purity is bought the same way
`defaultSession` buys it — **the machine is an argument**. A `DiskInventory`
value (what disks exist, their sizes, what is mounted from them, which one holds
the running root) is gathered by the caller and handed in; the predicate is a
function of plan-and-inventory and nothing else. That is what lets a Linux unit
test construct the exact machine where the refusal must fire and prove that it
does — this being the one predicate in this tree whose failure mode is somebody's
data.

*Verify:* unit tests on both platforms, including the refusals; and a golden
step list, so a change to what we run at somebody's disk shows up as a diff.

**✅ done.** 28 unit tests (261 total), all of them passing on Linux, where none
of the commands in the list exists. Four faults were injected to prove the suite
can fail — the running-root refusal deleted, `canmount=noauto` dropped, the
password hash moved into argv, the GPT label prefix removed — and each was caught
by the named test that claims it.

**And then the list was run.** The golden output was mechanically turned into a
shell script and executed against a 12 GB file-backed disk in the build VM, and
the result booted under nested bhyve. That found **four defects that no unit test
would have**, each now a test of its own:

1. `zpool create -o cachefile=X` sets the property and **does not write X**. The
   copy into `/boot/zfs` failed with ENOENT against a pool whose `cachefile` was
   set correctly. Ask for the write explicitly.
2. `zfs mount -a` and `zfs umount -a` act on **every pool on the machine**,
   including the running installer's own root. The first run said so out loud:
   *"cannot unmount '/var/log': pool or dataset is busy"*, about the live system.
3. **`zfs create` mounts what it creates.** Creating `pool/home` before
   `pool/ROOT/default` is mounted puts it at `/mnt/home` on the *live*
   filesystem, which the root mount then hides — an install that completes,
   extracts, and yields a machine whose `/home` is empty. The boot environment
   is now created and mounted before any other dataset exists.
4. The machine **booted without swap.** `fstab` named `/dev/gpt/<pool>swap` and
   there was no `/dev/gpt` at all: GEOM's disk-ident class had consumed the disk,
   so the GPT sat under `diskid/DISK-BHYVE-…` and no label provider was created.
   `gpart show -l` still listed the labels, which is what makes it convincing to
   look at and wrong. Measured both ways — with
   `kern.geom.label.disk_ident.enable="0"` in `loader.conf`, `/dev/gpt` appears
   and `swapinfo` shows the partition; without it, neither.

None of those is a mistake a reviewer would have caught reading the list, and
every one of them ships a broken machine. **That is the argument for P5.2's live
test in one paragraph**: this list is not verified until something boots.

**P5.2 — `abyss-install`: the executor, and the pass where the claim comes true. ✅ done.**
Runs a step list as root and streams progress back over `CurrentIPC`. Checks its
peer. Tears down idempotently — export the pool, unmount the ESP, detach the md —
so a failed install leaves nothing mounted and the next attempt is not a
different problem.

*Verify:* **`abyss/tests/live-install.sh` — install onto a scratch disk in the
build VM, then boot the result under nested bhyve and wait for `login:`.** That
is the whole phase's claim, made by the harness, on every run, with no GUI in it
yet. Everything after this pass is the face on the front.

**✅ done.** 25 more unit tests (287 total) and a live test that installs a real
system and boots it. Six things are worth recording.

**The scratch disk is a real disk, and had to be.** P5.1 installed onto a
file-backed `md(4)` device, which works — but **`geom disk list` does not show
`md` devices**, and neither does `sysctl kern.disks`, so the installer's own
machine probe cannot see the disk P5.1 installed onto. Teaching the product
about memory disks to satisfy a test would be testing a code path the product
does not have, so the build VM gets a **12 GB virtio scratch disk** instead
(`abyss/vm/run.sh`). The test then picks its target by the product's own
signals — not the root disk, nothing mounted from it, big enough to be a target
— and stops unless that is exactly one disk.

**"Allowed to command it" had to be made to mean "able to reach it".** §4.4
found that a root-owned 0600 socket is unreachable by the GUI that must command
it; the peer check answers a different question and does not fix that. So
`abyss-install --uid N` **hands the socket to that uid** and *then* asks the
kernel who called. The two are not redundant: permissions alone are defeated by
anything running as root, and a peer check alone grants nobody access.

**The definition of "it worked" earned its keep on the first injection.** With
the `bootfs` step replaced by `true`, every step reported success — the install
said *"39 steps, ok"* — and the loader dropped to its `OK` prompt. Nothing but
the boot check knew. That is P5.1's §2.43 lesson arriving one level up: **an
install that reports success is not an install that worked.**

**The disk you booted from is refused twice.** Deleting the running-root refusal
did not make the machine installable — "something is mounted from it at /,
/boot/efi, /home, …" still stopped it, and the live test failed because it was
refused for the *wrong reason*. Two independent signals, and the test knows
which one it is asking about.

**`check` and `install` are asked about the same plan**, and the test asserts
they compile to the same number of steps. Otherwise "check said yes" is a promise
about a plan nobody is going to run.

*One test-quality finding worth carrying:* an injected fault reported the wrong
test, because a force-unwrap in an XCTest **kills the process** and hides every
test after it. `XCTUnwrap` fails the one test and lets the rest speak. A suite
that dies on the first failure tells you less than one that fails.

**P5.3 — the live medium. ✅ done.**
`abyss/mk/live-image.sh`: extract the sets into a staging root, add the DE and
the Swift runtime it needs, configure a session that autologs in and runs one
application, then `makefs` + `mkimg`. No `make release`, no source tree, no world
build (§4.3).

*Verify:* boot the medium (nested) and check that our desktop came up on it —
pixel by pixel, on the frame the medium itself captured.

*(The scope as first written said "screenshot the Aqua installer on its first
screen". That was an ordering mistake in this plan: the installer is P5.4, so
there is nothing of it to photograph yet. What P5.3 can prove — and does — is
that **the medium runs our desktop**.)*

**✅ done.** `abyss/mk/live-image.sh` builds a **327 MB** image in **15 seconds**,
and `abyss/tests/live-medium.sh` boots it nested and checks what it drew.

![the desktop, from our own medium](screenshots/live-medium.png)

**The package manager was the wrong tool, by a factor of seventeen.** The obvious
build asks `pkg -r $stage install wlroots019 cairo harfbuzz dejavu …` and it
produced a **5.66 GB** staging root in 224 seconds: wlroots pulls Xwayland, mesa
pulls LLVM, something pulls avahi, and `/usr/local/bin` ends up with **409
binaries** including `2to3` — on a medium whose job is to partition a disk.

`ldd` over the twelve binaries we ship answers the question exactly: **67 shared
objects, 17 MB**, transitively closed, and it cannot drift from the product
because it *is* the product. The stated cost: **the medium has no package
database**, so nothing on it can `pkg install` anything. For a live installer
that is fine; it runs one desktop and writes one disk.

**§6.3 is answered by measurement.** The swift6 package is 2.70 GiB of toolchain;
the FreeBSD runtime directory is 144 MB; the libraries our binaries actually load
are **80 MB**. And `-static-stdlib`, the alternative that section named, took the
*smallest* binary in the tree from **296 KB to 9.1 MB** — call it +8.8 MB each,
which across twelve binaries is worse than one shared copy. So: carry the
closure.

**Base libraries come from the sets, not from the builder.** `ldd` also names
`/lib/libc.so.7`, and copying that would make the medium a mixture of two
systems. It fails loudly — base.txz marks those `schg` — which is how it was
found rather than shipped.

**And the assertion that had to be invented.** A medium built with **no fonts at
all** passed every check: three layers composited, menu bar pale at the top,
wallpaper underneath, Dock over it. `Aqua.Text` falls back to toy text *silently*
— right for a missing italic, wrong for a machine that has lost every glyph — and
the pixels cannot tell them apart (25 dark pixels in the menu bar versus 15;
measured, and far too close to assert on). The fix is not a cleverer probe: the
desktop now **says** what its text stack got, and the medium reports it. Absence
has to be reported, not merely survived.

*Known gap, stated rather than papered over:* removing the keyboard layouts also
leaves this test green, because a headless session with no input device never
compiles a keymap. They are carried because the installer is typed into, and
**P5.4 is the pass that will exercise them**.

*One v1 choice with a cost:* the medium's root is mounted **read-write**. A real
USB stick wants read-only plus tmpfs, because a stick can be pulled out
mid-write. This is a disk image in a VM, and read-write is also what makes the
captured frame available afterwards — but it is the thing to fix before anyone
puts this on a stick.

*One trap the spike walked into, free of charge:* an extracted base system
carries `schg` on a good deal of `/var` and `/usr/bin`, so a staging root cannot
be `rm -rf`'d — `rm` reports "Directory not empty" and tells you nothing about
why. A rebuild script that does not `chflags -R noschg` first will fail on its
*second* run, which is the run nobody tests.

**P5.4 — `Installer`: the Aqua application.**
The hub-and-spoke, which is the part that is Anaconda's idea rather than
`bsdinstall`'s: a summary page whose spokes — keyboard, disk, timezone, network,
account — are entered and returned from in any order, with the Install button
inert until every required spoke is complete and each spoke carrying its own
"not done yet" line. `bsdinstall` marches you through a fixed sequence; the hub
is why this is worth building rather than wrapping.

The disk spoke is the one with teeth: it lists what it found, it says what is on
each disk today, and the destructive confirmation names the disk in the sentence.

*Verify:* live, on `undertow`, driven by the harness's pointer and keyboard; the
plan the GUI produces is compared against the plan a unit test builds by hand.

**P5.5 — install, reboot, desktop.**
The end-to-end: boot the medium, click through, install, reboot, and land in the
Jaguar desktop with the account that was created in the account spoke.

*Verify:* one script, nested, no human — and a screenshot of the desktop taken on
the installed machine, which is the only evidence that means anything.

---

## 4. The spikes — four risks, retired before planning

Two of these were the phase's feasibility question, and they were answered on the
target before a line of the plan above was written.

### 4.1 Can we install a bootable FreeBSD from a program? — **Yes, and no `bsdinstall`.**

`bsdinstall`'s components are shell scripts driving `bsddialog`; `zfsboot` in
particular is a dialog program with an install inside it. Wrapping it means
driving a dialog from a GUI, which is a worse job than doing the install.

So the spike did the install directly — `gpart` for the GPT, an ESP with
`loader.efi` as `EFI/BOOT/BOOTX64.efi`, a swap partition, `zpool create` with
`altroot=/mnt`, `zroot/ROOT/default`, `bootfs`, `tar -xpf base.txz kernel.txz`,
and a hand-written `loader.conf`/`rc.conf`/`fstab`. On a **6 GB file-backed
`md(4)` vnode disk**, so the "disk" is an ordinary file:

```
=>      40  12582832  md0  GPT  (6.0G)
      2048    532480    1  efi  (260M)
    534528   2097152    2  freebsd-swap  (1.0G)
   2631680   9949184    3  freebsd-zfs  (4.7G)
```

That image — 402 MB of actual blocks — was then booted under qemu/OVMF:

```
FreeBSD/amd64 (abyss-spike) (ttyu0)

login:
```

**Nothing in the install path needs a dialog, a terminal or a human**, and every
tool it needs is in FreeBSD base. This is the pass-P5.2 claim, proven before it
was promised.

### 4.2 Can the harness prove it booted, without leaving the build VM? — **Yes: nested bhyve.**

An installer that is only verified by a person watching a screen is verified once
and then never again. The build VM runs on `-cpu host` on a Ryzen 9700X, so the
guest sees `SVM`, `vmm.ko` loads inside it, and `bhyve` is in FreeBSD base —
`edk2-bhyve` from ports supplies the UEFI firmware.

The spike booted §4.1's image that way — a guest, inside a guest, from a disk
that is a file inside the first one:

```
FreeBSD/amd64 (abyss-spike) (ttyu0)

login:
...
Uptime: 2m16s
```

So `abyss/tests/run.sh --vm --live` can install a system and **boot what it
installed**, in the lane that already exists, with no hardware and no second
machine. That is what makes P5.2 a test rather than a demo.

*The cost is one package.* `edk2-bhyve` belongs in the cloud-init list in
`abyss/vm/make-seed.sh`, so a VM provisioned from scratch can run the phase's
tests — the same way Phase 0 added Swift's dependencies there.

### 4.3 Can we build a live medium without `make release`? — **Yes, with base tools.**

The route everybody documents is `make release` from a source tree: `src.txz` is
118 MB, and a world build is hours and gigabytes for an image whose contents we
did not compile anyway.

The spike built the medium **out of the same dist sets the installer extracts** —
`makefs -t msdos` for the ESP, `makefs -t ffs` for the root, `mkimg -s gpt` to
assemble — and booted it:

```
/home/build/live.ufs: 1101.7MB (2256320 sectors) ...
Image `/home/build/live.img' complete
FreeBSD/amd64 (abyss-live) (ttyu0)

login:
```

**One artifact, two uses**: what the medium carries is what the installer
installs, so there is no second source of truth about what AbyssBSD *is*.

### 4.4 How does an unprivileged GUI command a privileged executor? — **By being asked for its credentials.**

The spike found the thing worth finding: `CurrentIPC` creates its runtime
directory 0700 and every service socket 0600 (`Current.swift`). That is the right
default for a desktop — and it means a root-run `abyss-install` binds a
root-owned socket that **the GUI cannot open**. The tempting fix is a wider mode,
which would hand the installer to every process on the machine.

The peer-credential route works on both platforms, and needs the same one-line
`#if` `CurrentIPC` already carries for `SOCK_STREAM` (HANDOFF §2.32):

```
SO_PEERCRED: pid=70596 uid=1000 gid=1000     # Linux, needs _GNU_SOURCE
getpeereid: uid=1001 gid=1001                # FreeBSD
```

glibc has **no `getpeereid`** and FreeBSD has no `SO_PEERCRED`, so it is a real
fork, not a portability nicety. The executor is told at startup which uid may
command it, and asks the kernel — not the filesystem — whether the caller is it.

---

## 5. Verification

The standing discipline holds: pure logic in unit tests, the real thing live,
green on **both** platforms, `abyss/tests/run.sh --vm --live` as the gate.

Two things are specific to this phase.

**The definition of "it worked" is `login:`.** Not "the script exited 0", not
"the pool imported" — a kernel we installed, on a disk we partitioned, reaching
multi-user. Every intermediate check is a diagnostic; that line is the assertion.

**On Linux, the live install test is a positive control, not a skip.** There is
no `gpart` on Linux and there never will be, so `live-install.sh` there asserts
that the planner **refuses, and says which command it could not find** — the
`live-vents.sh` pattern, where the Linux lane proves the stubs report themselves
absent rather than quietly passing. A test that skips silently on the platform
you develop on is a test you will discover is broken on the platform you ship on.

And the rule that earned its place applies with more force here than anywhere
else in the tree: **a test that has never failed has not been shown to test
anything.** For P5.2 that means deliberately corrupting a step — a wrong
`bootfs`, a missing `loader.efi`, an unset `vfs.root.mountfrom` — and confirming
the boot check notices. An install test that passes because it never really
installed is the worst possible false green.

---

## 6. Risks / open decisions

**6.1 Tarballs or pkgbase?** FreeBSD 15 ships both: `bsdinstall pkgbase` exists
and the `FreeBSD-base` pkg repo is real (disabled by default). For a *fork* with
its own desktop, pkgbase is the better long-term answer — one repository carries
base and the DE, updates are incremental, and "AbyssBSD" becomes a package set
rather than a tarball. **v1 uses the tarballs anyway**, because they are the
proven path, because they are what §4.3's medium already carries, and because
§6.2 rules out needing a network. The plan is a value; the sets it names are a
field in it.

**6.2 Offline is a requirement, not a preference.** PLAN.md risk 5 is Broadcom
Wi-Fi on FreeBSD, on the machine this project targets. An installer that needs a
network to install is an installer that does not work on a Mac Pro 6,1 out of the
box. So the medium carries what it installs, and any fetching is an optional
extra after the machine is up.

**6.3 The Swift runtime has to ride along.** *Closed in P5.3, by measurement.*
Three numbers settled it: the `swift6` package is **2.70 GiB** of toolchain, the
FreeBSD runtime directory is **144 MB**, and the libraries our binaries actually
load are **80 MB**. The alternative this section named — `-static-stdlib` — took
the *smallest* binary in the tree from **296 KB to 9.1 MB**, so twelve of them
would carry more duplicated runtime than one shared copy costs.

So the medium carries the closure `ldd` reports, and the same reasoning threw out
the package manager entirely (§2.45 in HANDOFF): **67 shared objects, 17 MB**, of
which the Swift part is the bulk. This was indeed the first time the project had
to care what its runtime weighs, and the answer was to stop asking what it *has*
and start asking what it *loads*.

**6.4 The destructive confirmation is a design problem, not a dialog.** Every
installer gets this wrong in the same way: a warning nobody reads, then a
progress bar past the point of no return. The Aqua answer is the sheet — modal to
the window, naming the disk and what is on it in the sentence, with the
destructive verb on the button rather than "OK". This is worth doing well; it is
the only irreversible thing this desktop does.

**6.5 GELI.** `bsdinstall` offers encrypted ZFS-on-root as a checkbox and it is
close to expected now. It is deliberately out of the pass list: it adds a
passphrase prompt at boot, which is a piece of pre-desktop UI this project does
not have. Worth doing; worth doing after a machine installs at all.

**6.6 The nested-boot check will be slow, and slow tests get skipped.**
*Measured after P5.3, and still inside the budget.* `run.sh --vm --live` takes
**9m03s**, of which the two new tests are roughly four minutes: `live-install.sh`
extracts a whole base system and boots it (~3 min), `live-medium.sh` builds an
image and boots that (~50 s, of which the build is 15). It was about five minutes
before this phase.

That is tolerable and it is worth watching. The failure mode that matters is not
the minutes but the habit: a gate people stop running is a gate. If it grows
much past this, the boot checks belong behind their own flag — said out loud in
`run.sh`, never quietly dropped. Both already skip loudly without the
distribution sets or bhyve's UEFI firmware, which keeps a fresh machine fast and
honest rather than fast and silent.

**6.7 There is no rollback.** `abyss-install` can tear down its own mess (export,
unmount, detach), but once `gpart` has written a new GPT over somebody's disk,
the previous contents are gone. This is inherent, and the honest response is
§6.4's confirmation and §1's safety predicate — not a promise the executor cannot
keep.
