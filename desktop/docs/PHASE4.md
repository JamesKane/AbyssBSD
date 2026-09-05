# Phase 4 — the Mac Pro: real graphics, real input, real numbers (scope)

The first phase whose verification needs a machine that is not in this loop —
and, since [PRODUCT.md](PRODUCT.md), no longer the last phase: PLAN.md now runs
to Phase 18, and **Phase 12 is §5 below turned into a program** so the checklist
runs on machines nobody here owns. Read [PLAN.md](PLAN.md) for the locked decisions, [PHASE6.md](PHASE6.md)
for the frame contract this has to meet on metal, and [PHASE5.md](PHASE5.md) for
the installer that is how anything gets onto that machine at all.

Last updated: 2026-09-05. **Retargeted.** The bring-up machine is now an
**Intel i7-12700KF with an AMD Radeon RX 6750 XT** (§1.1); the 2013 Mac Pro is
demoted to a second row of the matrix and keeps every accommodation already
written for it. P4.1 and P4.3 are done, and P4.0 got a medium onto the Mac Pro's
firmware — work that survives the retarget because none of it was about the GPU.

**The retarget retires this phase's largest risk by evidence rather than by
argument**, and buys something the Mac Pro could never offer: a positive control
(§1.2).

---

## 1. What this phase is

Everything above this line was proven on a machine with no display. `undertow`
had one backend, `wlr_headless_backend_create`; every click in this tree came
from `wlr-virtual-pointer`; and PHASE6's C1–C5 were measured against a synthetic
clock where a frame "presents" the instant it is committed.

That was the right scope and it is now spent. The claim this phase has to make:

> The Aqua desktop is interactive on real hardware: a real display at its own
> refresh rate, a real mouse and keyboard, and the frame contract holding against
> a vblank we did not invent.

**And the way it gets there is the installer.** That is not a convenience — it is
the delivery mechanism. To try anything on any machine, an image built by
`abyss/mk/live-image.sh` has to boot its firmware, bind a GPU, and put the
installer on the screen. Every pass below is therefore shaped by "can it be put
on a USB stick and booted", not by "does it work in the VM".

### 1.1 The machine, and why it changed

The target was a Mac Pro 2013 because that is the machine this project was
started for. It has been fighting: Apple's EFI would not list a medium whose ESP
was legal everywhere else (P4.0), its PCIe bridges bury the installer under a
power fault that never clears (P4.0), and the question its GPU asks —
does `si_support` bind GCN 1.0? — has never been answered.

The bring-up machine is now this, and it is the machine that runs the harness's
own workloads:

| | |
|---|---|
| Board | MSI MS-7D25 (LGA 1700), ordinary AMI UEFI |
| CPU | Intel Core i7-12700KF — 20 threads, 5.00 GHz. **KF: no integrated graphics** |
| GPU | **AMD Radeon RX 6750 XT** — Navi 22, RDNA 2, `amdgpu` codename `navy_flounder` |
| Memory | 128 GiB |
| Display | AOC AG271QG4, **2560x1440 @ 60 Hz**, 27" — ~109 DPI, so **scale 1** |
| Network | `igc0` (Intel I225/I226 2.5 GbE), DHCP, working |
| Storage | ZFS root, ~900 GB |
| Today | **FreeBSD 15.0-RELEASE-p12, running MATE 1.28.2 on X11** |

**What retires immediately, and by evidence:**

- **`si_support` and GCN 1.0** — the biggest open risk in the project (§6.2).
  Navi 22 is claimed by `amdgpu` with no tunable at all, and this machine is
  rendering a desktop on FreeBSD 15.0 today. The risk does not get argued down;
  it stops applying.
- **Apple's EFI.** An ordinary UEFI reads an ordinary ESP. P4.0's FAT16 fix stays
  because FAT16 is legal for a removable ESP everywhere and costs nothing.
- **The dual GPU** (§6.3). One card, one display.
- **Apple NVMe quirks and Thunderbolt 2** (P4.6). Gone, and replaced by hardware
  FreeBSD already drives.
- **Broadcom Wi-Fi** (PLAN risk 5) leaves this phase's critical path. `igc0` has
  an address.

**What is new, and is a cost:** this machine is *fast*. Twenty threads at 5 GHz
means C2's eleven hostile clients are less hostile here than on a 2013 Xeon, and
60 Hz is a 16.67 ms budget rather than a tighter one. **A contract measured only
on the fast machine is a contract measured once.** The Mac Pro stays in the
matrix precisely because it is the slow row.

### 1.2 The retarget's real prize: a positive control

The Mac Pro's failure mode was ambiguity. A black screen there could be Apple's
EFI, the medium's layout, `si_support` refusing GCN 1.0, `drm-kmod` against the
15.0 ABI, `undertow`'s DRM backend, or our own scene — six candidates and no way
to separate them, which is why PHASE4 §5 had to be an ordered checklist in the
first place.

This machine **already draws a desktop on FreeBSD 15.0**. The GPU binds, the
display modesets, libinput sees the keyboard and mouse, ZFS roots, and the
network is up — all of it demonstrated by somebody else's window manager.

> **So on this machine a black screen means us.** Every layer under our own is a
> known-good control, which is §2.37's principle applied to hardware bring-up:
> a probe with no positive control measures nothing, and until now this phase
> had none.

That is worth more than any single risk it retires, and it is the reason the
retarget is an improvement rather than a retreat.

### What is genuinely different about this phase

**The feedback loop has a person in it.** Everything since Phase 0 could be
checked by `abyss/tests/run.sh`. The metal half cannot: it is boot the stick,
read the screen, report back. So this phase's deliverable is split — code that is
provable here, and a **bring-up checklist** (§5) that says exactly what to look
at and what each answer means. A checklist that just says "try it" would be an
admission that the phase was not scoped.

---

## 2. What we already have vs. what's new

| Need | Have | New in Phase 4 |
|---|---|---|
| A compositor | `undertow`, headless only | the backend it runs on becomes a choice (P4.1) |
| A frame contract and its meter | the metronome + flight recorder (P6.1) | a **real vblank** to measure against |
| Input plumbing | `Seat`, driven by virtual devices (P6.4) | libinput, and devices that are physically there |
| A way onto the machine | the live medium (P5.3) | `drm-kmod`, **RDNA 2 + Southern Islands** firmware, and a session that is not headless |
| Refusals that know the machine | `DiskInventory` (P5.1) | NVMe, and disks that are not `vtbd0` — on a box whose other disk is the reason it is useful (§6.6) |
| A supervisor | `anchor` (P3.6, P8.4) | `rtprio` for the present thread |

---

## 3. Ordered passes

**P4.0 — the medium reaches the machine. ✅ done, and its own caveat came true.**
Two Apple-firmware findings, both measured on the target: the ESP had to be
FAT16 with media descriptor 0xf8 before a Mac Pro would list the stick at all,
and `hw.pci.enable_pcie_hp="0"` before the installer could be seen under a power
fault the machine re-logs forever.

That pass said in writing that the fix had been proven **on a stick reformatted
in place**, and that `live-image.sh`'s own run of it was still unexercised. It
was, and it was broken in two places at once — found the first time it ran, as
part of the retarget:

- **`makefs` parses `media_descriptor` in decimal only.** `0xf8` fails with
  "Media descriptor \`f8': illegal number"; `248` builds and writes 0xf8. So the
  medium had not been buildable at all since P4.0. **"makefs accepts the option
  name" is not "makefs accepts the value"** — the earlier pass checked the
  former and reported it as the latter.
- **The assertion that would have caught it could not run, and died silently.**
  `dd bs=1` on `/dev/mdNp1` is "Invalid argument" — a FreeBSD character device
  does whole-sector transfers only — and because that `dd` sat inside a command
  substitution in an assignment, `set -e` killed the script with no FAIL line and
  no indication which check had gone. It now reads the boot sector once and
  slices the file.

The medium itself was right all along: FAT16, 0xf8, and `live-medium.sh` is
green on it. **A test that cannot fail out loud is worth less than no test**, and
this one managed to be an unrunnable check on an unbuildable artifact.

**P4.1 — `undertow` chooses its backend. ✅ done.**
`wlr_backend_autocreate` behind `--backend auto`: DRM/KMS on metal, a nested
Wayland window inside another compositor, X11 under one — the same decision every
wlroots compositor makes, and not one worth making differently. Headless stays
the default, because it is the only thing the build VM can do and the only thing
that makes C1–C5 reproducible.

Two things fell out of the first nested run, and both are the phase in miniature:

- **The display's size is the truth, not ours.** Headless invents an output at
  whatever size it was asked for; a monitor arrives with a mode already. Given
  `--width 900 --height 700` on a 1280x720 output, the compositor laid the
  desktop out for a screen that was not there — `usable=0,0,900x700` — and the
  menu bar's exclusive zone was computed for the wrong width. On a real backend
  the output's mode wins.
- **The frame contract's metric does not survive nesting**, and that is not a bug
  to fix. See §6.1.

**P4.2 — real input.** The autocreated backend brings a libinput seat with it;
`Seat` (P6.4) already handles `wlr_input_device` arrivals and departures, and
P6.7's §2.41 lesson means it survives them leaving. What is untested is a device
that is *physically there*: real evdev codes, real modifiers, a real pointer with
acceleration. Nested gives most of that for free — the events come from the
host's actual mouse and keyboard — which is why nested is worth having even
though it can never answer C1.

**P4.3 — the medium goes metal-ready. ✅ done, and retargeted.** The image
carries `drm-66-kmod`'s six modules (amdgpu, radeonkms, i915kms, drm, ttm,
dmabuf), `seatd`, and **two families of GPU firmware**: RDNA 2 for the primary
target — `navy_flounder` (Navi 22, the RX 6750 XT) with `sienna_cichlid`,
`dimgrey_cavefish` and `beige_goby` riding along for the rest of the RX 6000
line, 12.4 MB — and the five Southern Islands blobs for the Mac Pro, 2.3 MB.

**The Navi 22 → `navy_flounder` mapping was read, not remembered**: the firmware
name came out of `amdgpu.ko`'s own strings (`amdgpu/navy_flounder_dmcub.bin`) and
the package's file list, which is the same discipline that measured the
`si_support` sysctl namespace rather than inferring it from the driver's message.
`live-medium.sh` asserts on the blob being on the stick, because the failure it
prevents — a machine that comes up with no display and no error worth reading —
is indistinguishable from every other way this phase can fail.

**Packages, not an `ldd` closure**, and the distinction is the point: nothing we
build links a kernel module, so `ldd` will never mention one. P5.3's lesson was
"a package manager's closure is not your program's closure"; the converse is
that some things are *only* obtainable as packages, and the answer is to name
them precisely and take `/boot/modules` and `/usr/local` out of each rather than
resolving a dependency graph.

**The `si_support` knob was measured, not guessed.** `amdgpu` prints the fix in
Linux's spelling — *"Use radeon.si_support=0 amdgpu.si_support=1 to override"* —
and FreeBSD's linuxkpi mangles module parameters into a sysctl namespace. Rather
than reason about which, the module was loaded in the build VM (which has no AMD
GPU at all) and `sysctl -aN` read back: **both** `hw.amdgpu.si_support` and
`compat.linuxkpi.amdgpu_si_support` are registered. `loader.conf` sets both, and
turns the `radeon` side off. That load also established something the medium
depends on: **amdgpu loads harmlessly on a machine it cannot drive**, so
`kld_list="amdgpu"` is safe to ask for unconditionally.

**The backend is chosen from what the machine has.** One rule, in the live
session: if `/dev/dri/card*` exists, `--backend auto`; otherwise headless. The
build VM has no `/dev/dri`, so the harness's live modes are untouched — and
on a Mac Pro the same medium asks for the display. It says which it chose, which
on metal is the first line worth reading.

**Where the session runs depends on whether anybody can see it**, and it is the
same rule as the backend: ask the machine. With no display a harness is watching
and the console is its only channel, so the session runs in rc's foreground and
reports there. With a display a *person* is watching, and what they need is a
console they can switch to **while** the installer is up — so the session goes to
the background, rc finishes, the virtual terminals arrive, and its log goes to
`/var/log/abyss-live.log` rather than a terminal `getty` is about to revoke
(§2.47). One machine cannot have both, and which it wants is not a matter of
taste.

*What a VM can check, it checks:* the medium carries `amdgpu.ko`, carries the
Pitcairn firmware (the D300), carries `seatd`, asks for `si_support`, loads the
driver at boot, starts `seatd`, and picks headless where there is no display.
*What it cannot:* whether `si_support` binds a real FirePro. That is §5, step 3,
and it is the question this whole pass exists to let somebody ask.

**P4.4 — first light.** Boot the stick on the 12700KF and work the checklist in
§5. **The interesting failures have moved.** They used to be early — will the
firmware boot this, will the GPU bind — and on this machine both of those are
answered before we arrive (§1.1). What is left is steps 4 and 5: does
`undertow --backend auto` find the output, and is the installer on the screen.
Those are the two steps that are about *our* code, and they are now the only ones
without a control underneath them.

The output of this pass is still *findings*, and the plan below it will be
rewritten by them — which is the honest thing to say about a pass nobody has run
yet.

**P4.5 — C1 against a real vblank.** Every number in PHASE6.md came off a
synthetic clock. Re-measure here: the metronome's EWMA prediction finally has a
hardware timestamp to learn from (`WLR_OUTPUT_PRESENT_HW_CLOCK`, which the code
already distinguishes and which has never once been set in this project's
history). Plus `allow.rtprio` for the present thread. **The C1–C5 numbers in
PHASE6.md should be treated as provisional until this pass replaces them.**

**The budget is 16.67 ms**, because the panel is 2560x1440 at 60 Hz — and the
scale is **1**, since 109 DPI is not HiDPI, so the toolkit's 2x path is *not*
exercised by this machine and must not be assumed proven by it.

**And a number measured only here is measured once (§1.1).** Twenty threads at
5 GHz is a generous machine to hold a frame contract on; the contract's claim is
that it holds on ordinary hardware. Either the Mac Pro or a deliberately
constrained run (fewer cores pinned, C2's adversaries turned up) has to supply
the second row, and P4.5 is not finished with one.

**P4.6 — the rest of the machine.** Much smaller than it was. Apple NVMe quirks
and Thunderbolt 2 are gone with the Mac Pro; `igc0` already has a DHCP address,
so the network is a *positive* result to record rather than a problem to solve.
What remains is **audio** — the volume status item has reported "no mixer" since
P3.7 and would finally have a mixer to report — and whatever the checklist turns
up.

The installer stays offline-first regardless (PHASE5 §6.2). That was never really
about Broadcom; it is about a medium that carries what it installs.

---

## 4. The spikes — and what the retarget did to them

### 4.1 Can `undertow` run on anything but headless? — **Yes, and it already does.**

`wlroots` 0.19 ships `wlr_backend_autocreate`, `wlr_session_create` (libseat),
and DRM, libinput, Wayland and X11 backends; the C shim needed one more `#include`
and nothing else. Run nested on the dev box:

```
undertow: WL-1 1280x720 @ 60Hz on abyss-nested2
usable=0,0,1280x720
composite-p99-us=18
```

A real output, a real mode, real buffers, and input from an actual mouse. That is
the whole non-headless path exercised without a Mac Pro in the room.

### 4.2 Is the GPU packaged? — **Both of them are, and the new one needs no knob.**

*Originally:* `drm-61-kmod` and `drm-66-kmod` are built for the 15.0 kernel ABI
(`1500068`), and all five Southern Islands firmware packages exist —
`gpu-firmware-amd-kmod-{tahiti,pitcairn,verde,oland,hainan}`. The Mac Pro's D300
is Pitcairn; the D500 and D700 are Tahiti. That retired the version of the risk
that would have ended the phase ("the firmware is not distributed for this OS at
all") and left the real one open: does `si_support` actually bind GCN 1.0?

*After the retarget,* re-run against the same repo:

| | |
|---|---|
| The chip | RX 6750 XT = Navi 22 = RDNA 2 |
| `amdgpu`'s name for it | **`navy_flounder`** — read out of `amdgpu.ko`'s strings (`amdgpu/navy_flounder_dmcub.bin`), not recalled |
| The package | `gpu-firmware-amd-kmod-navy-flounder`, 3.0 MB, 12 firmware modules (ce, dmcub, me, mec, mec2, pfp, rlc, sdma, smc, sos, ta, vcn) |
| The rest of the family | `sienna-cichlid` (Navi 21), `dimgrey-cavefish` (Navi 23), `beige-goby` (Navi 24) — 12.4 MB for all four |
| A tunable to enable it | **None.** RDNA 2 is claimed by default; `si_support` exists because Southern Islands is *not* |

**And the strongest evidence is not in the ports tree at all:** the machine is
running FreeBSD 15.0-RELEASE-p12 with a MATE desktop on it right now. `amdgpu`
binding this card is not a prediction.

Southern Islands stays on the medium anyway. It is 2.3 MB, it is written and
tested, and deleting a working row of the matrix to make a retarget look tidier
would be throwing away the only thing P4.3 bought.

### 4.3 Does the frame contract hold on a real display? — **Unanswerable here, and the attempt was informative.**

Nested, `missed=107 of 180`. That is not a regression and it is not fixable: a
compositor inside another compositor presents when its *host* presents, so
"missed" measures our latency against a clock we do not own. §6.1 says what that
means for the phase.

The DRM path — where the vblank really is ours — **cannot be exercised on the dev
box**, which is running a Wayland session that holds DRM master. Taking a VT to
try it would blank the screen of the machine this work is being done on. So the
DRM backend ships **written and unproven**, and P4.4 is where it is first run.
Saying that plainly is better than a spike that proves the easy half and implies
the hard one.

---

## 5. Verification

Unchanged for everything that can be: unit tests, live tests, both platforms,
`abyss/tests/run.sh --vm --live` as the gate. Headless remains the default
everywhere, so **nothing in this phase is allowed to make the existing live
modes depend on hardware.**

What is new is the half a script cannot do. The bring-up checklist, in the order
the answers matter:

0. **Build it, then write it.** `abyss/mk/live-image.sh --stay --frames 0` is
   the metal build: it does not power itself off, and the installer stays up
   rather than running out a frame budget meant for a test. Then
   `abyss/mk/write-stick.sh /dev/sdX` puts it on the stick — **the whole disk,
   never a partition.** The image is a whole-disk GPT and UEFI reads the table
   at LBA 1 of the *disk*; written to `/dev/sdX4` its ESP is buried inside a
   filesystem no firmware will ever parse, and the machine silently boots what
   it booted before — which reads as step 1 failing and is not. `--dry-run`
   rehearses every check without root.
1. **Does the stick boot?** UEFI boot menu, `\EFI\BOOT\BOOTX64.EFI`, the loader
   menu. *If not:* the medium's GPT/ESP layout, before anything about graphics.
   On the MSI board this is an ordinary AMI UEFI and P4.0's FAT16 ESP is
   comfortably inside what it reads; on the Mac Pro it was the whole problem.
2. **Does it reach multi-user?** `Setting hostname: abyss-live` on the console.
   *If not:* it is a driver or a root-mount problem and the screen is irrelevant.
3. **Does `amdgpu` attach?** `kldstat`, `dmesg | grep -i amdgpu`, `/dev/dri/card0`.
   **This step has a control now** — the machine's own FreeBSD install binds this
   card daily, so a failure here is the *medium's* (a missing `navy_flounder`
   blob, a `kld_list` that did not run) and not the driver's. On the Mac Pro this
   was the step that could end the phase; here it is a step that can only find our
   own packaging bug. §6.2 keeps the Southern Islands fallbacks for that row.
4. **Does `undertow --backend auto` find an output?** Its own log names the
   connector and the mode; expect `2560x1440 @ 60Hz`, scale 1. **This is now the
   first step without a control under it** — nothing else in the stack has ever
   driven DRM for us.
5. **Is the installer on the screen?** The phase's first real deliverable, and
   the first time any of this has been *seen*.
6. **Then, and only then, the numbers.** C1 with a hardware clock, under load,
   with and without `rtprio` — and see P4.5 on why one machine's numbers are not
   the contract.

Each step's failure is a different phase, which is why they are ordered — and on
this machine steps 1–3 are the ones somebody else's software has already passed,
which is what §1.2 buys.

### 5.1 There is no second disk, so the install is not part of this

**The bring-up machine has one disk, and it holds the working FreeBSD install
that §1.2's entire argument rests on.** So the install is deferred until there is
somewhere to put it, and the checklist above stops after step 6.

That costs less than it sounds, because **the install was never what the metal
was for.** Steps 0–6 are every question only real hardware can answer — does it
boot, does `amdgpu` bind, does `undertow` find the output, does the desktop draw,
does the frame contract hold against a vblank we did not invent — and **not one
of them writes to a disk.** What the install would add is "does an installed
system boot", which the harness already proves on every `--vm --live` run,
nested twice over, on an empty disk it made itself (P5.5). Metal adds a real GPU
and a real clock to that; it does not add a more real `zpool create`.

| Answered without installing | Needs an install |
|---|---|
| UEFI boots the medium; loader menu | an installed system boots on its own |
| multi-user reached | `bectl` and the boot-environment story (Phase 17) |
| `amdgpu` binds Navi 22, `/dev/dri/card0` | |
| connector, mode, EDID, refresh rate | |
| `undertow --backend auto` finds the output | |
| the Aqua desktop drawn on real hardware | |
| real keyboard, real mouse, libinput | |
| **C1–C5 against a real vblank**, with and without `rtprio` | |
| network device, DHCP, audio device | |
| disks enumerated — read-only | |

**So the medium has to become an instrument, not only a delivery mechanism**, and
that is `Fathom` (§6.4 of PRODUCT.md). It was Phase 12 on the dependency order
with Phase 4 in front of it; the constraint inverts that, and PLAN.md now runs it
next. The reasoning it was ordered on — *a person must walk the checklist before
its probes can be encoded* — assumed the person could finish. They cannot: steps
0–6 are reachable and the rest is not, so the probe stops being a record of the
walk and becomes the instrument for it.

### 5.2 The refusal that a live medium needs and nothing else does

Checking whether the medium was safe to boot turned up something worse than the
hazard it was checking for.

The medium does **not** set `zfs_enable`, so it imports no pools — which is why
booting it is safe. But it is also why `DiskInventory` could not see that a disk
was occupied. Every refusal in `Safety.swift` describes the **running** system:

- `diskHoldsRunningRoot` — on a medium, that is the USB stick;
- `diskIsMounted` — the machine's own disk is not mounted, because nothing
  imported its pool;
- `poolNameInUse` — checks *imported* pools, and there are none.

> **So a disk carrying a whole working FreeBSD install was presented by the
> installer as a clean, choosable target, with nothing said about it.** On a
> machine with one disk, that is the entire machine offered for erasure by a
> picker with no objection to raise.

The fix is a probe, and it is the first `Fathom` probe in everything but name:
**`zpool import` with no arguments *scans* and lists pools available to import,
and imports nothing.** Verified both ways in the build VM before the code existed
— the scan found a pool on a disk, and `zpool list` afterwards was unchanged.
`Disk.existingPools` carries the result, and `diskHoldsExistingSystem` refuses
by default, naming the pool it would destroy.

Two details that matter more than the refusal:

- **It is not permanent.** `InstallPlan.eraseExistingData` lifts it, because an
  installer that can never reinstall is broken. The guard is that it is off by
  default and the sentence that turns it on names what is lost — `write-stick.sh`'s
  `--allow-fixed` in the other half of the product.
- **The GUI silently ignored it at first**, because `InstallerModel.objection(to:)`
  matched a *whitelist* of refusals with a `default: continue`. The model refused
  and the picker offered the disk anyway. That is §2.46 for the second time in
  this installer, and the fix is structural rather than a test: the switch is now
  exhaustive, so the next refusal added to `Safety.swift` is a **compile error**
  here instead of a silent omission.

### 5.3 The first metal boot: steps 1–3 pass, and step 4 was ours

Run on the RX 6750 XT, 2026-09-05. **The checklist got to step 4 on the first
attempt**, which on the Mac Pro it never did.

| Step | Result | Evidence |
|---|---|---|
| 1. Does the stick boot? | ✅ | MSI's UEFI read the FAT16 ESP — P4.0's Apple fix works on ordinary firmware too |
| 2. Multi-user? | ✅ | `FreeBSD/amd64 (abyss-live) (ttyv0)` — our medium's own hostname |
| 3. Does `amdgpu` attach? | ✅ | `name=drmn0 id=amdgpudrmfb`, framebuffer `2560x1440x32 stride=10240`. The panel's **native mode**, driven by our driver: `navy_flounder` loaded |
| 4. Does `undertow` find an output? | ❌ | `abyss-session: auto backend (card0 render128)` — both nodes present, the right branch taken — then `undertow: could not create a wlroots renderer` |
| 5. Installer on screen? | — | not reached |

Two things came free with step 3: `igc0: link state changed to UP`, so the
network works on this box and thesis 5's weakest area answers positively; and
`ichsmb0: <Intel Alder Lake SMBus controller>`, confirming the platform.

**And the failure was ours, which is exactly what §1.2 bought.** On the Mac Pro
this screen would have had six candidate causes. Here every layer below us was
demonstrably working — the GPU bound, the mode was set, the render node existed,
the session picked `--backend auto` correctly — so the only remaining suspect was
the compositor, and it was.

**The cause: `ldd` is not a closure when something `dlopen`s** (HANDOFF §2.52).
The medium carries what our binaries link. `libEGL` and `libgbm` are dispatch
stubs; the driver is `libgallium` reached through `radeonsi_dri.so` and opened by
name, wanting `libLLVM` behind it. None of the three is named by anything we
build, so none was on the stick and there was nothing to make a GLES2 renderer
from. **The build VM cannot reach this path at all** — with no `/dev/dri` it takes
the pixman software renderer, so the GLES2 path had never run in this project's
history.

Fixed by adding the dlopened objects as **roots of the same `ldd` closure**, so
`libgallium` pulls `libLLVM` transitively the way everything else arrives; the
medium grows about 170 MB and carries `iris` and `swrast` alongside `radeonsi`
for nothing, since the 51 `dri/` entries are symlinks to one loader. *Naming them
as packages instead — the first attempt — put a 5 GB staging root behind a 3 GB
image, which is P5.3's lesson from the other side.*

**What is asserted and what is not.** `live-medium.sh` now checks the files are on
the stick, which is the half that was wrong. It cannot check that a renderer is
*created*, because that needs a render node the build VM does not have. **Step 4
is still unproven and only the machine can prove it** — which is this phase's
whole shape, and worth saying rather than implying the fix is verified.

---

## 6. Risks / open decisions

**6.1 The frame contract's metric is headless-or-DRM, and nesting is neither.**
The nested run missed 107 of 180 frames while compositing in 18 µs. Nothing is
slow; the schedule is simply not ours. `snapToGrid` already draws exactly this
distinction — it passes a hardware timestamp through untouched and snaps a
synthetic one to the nominal grid — and a nested backend is a **third** case it
does not model: a real timestamp from somebody else's clock.

The decision: **do not make nested pass C1.** It is a development convenience for
input and drawing, and the honest reading of its miss count is "not applicable".
What must happen instead is P4.5, on hardware, where `WLR_OUTPUT_PRESENT_HW_CLOCK`
is set for the first time in this project's life. The alternative — tuning until
the nested number looks good — would be optimising against a clock we do not own,
which is the same error as §2.37's probe with no positive control.

**6.2 `amdgpu` and GCN 1.0 — no longer this phase's risk, and still the Mac
Pro's.** It was the biggest risk in the project and the only one that could end a
phase. **The retarget retires it for the primary target by evidence:** Navi 22
needs no tunable and the machine renders a desktop on FreeBSD 15.0 today.

It survives as a *matrix* question rather than a *phase* question. Southern
Islands support in `amdgpu` is off by default and behind `si_support`;
`radeonkms` is the older alternative and does not do atomic modesetting, which
the present path wants. Fallbacks, in order, when the Mac Pro row is attempted:
`amdgpu` with `si_support=1`; `radeonkms`; and if neither binds, that machine
installs and runs headless — one empty cell in the matrix rather than a stalled
project. **That reframing is the whole value of the retarget:** the same unanswered
question now costs a row instead of a phase.

**6.3 Multi-GPU — deferred with the Mac Pro, not solved.** The Mac Pro has two
FirePros with a display on one, and wlroots' multi-GPU handling is the least
travelled path in it; `WLR_DRM_DEVICES` pins a primary. The 12700KF is a **KF**,
so it has no integrated graphics and exactly one GPU — which means **`undertow`
will never have been run on a machine with two, and the first laptop with an
Intel iGPU plus a discrete card will find that out.** Worth writing down as an
untested path rather than a fixed one; `i915kms` stays on the medium for the row
that will need it.

**6.4 A person is in the loop, and people are slow.** Every pass from P4.4 on has
a human boot cycle in it. The way to keep that cheap is to make the medium say as
much as possible on its own console — which it already does (PHASE5 §4.3's live
session reports on itself) — so that one boot answers several questions instead
of one.

**6.5 There is still no login window** (PHASE5 §6.8), and on a real machine that
somebody else uses, it starts to matter.

**6.6 The control is destructible — resolved by not installing.** §1.2's whole
argument rests on the target machine having a working FreeBSD install underneath
our medium, and there is no second disk to install onto (§5.1). So the install is
deferred rather than risked, the checklist stops at step 6, and `Fathom` moves in
front of it so the machine can be measured without being spent. The refusal in
§5.2 is the belt to that brace: even if somebody clicks through, the disk holding
the control is not choosable.

**6.7 One machine's numbers are not a contract.** P4.5 will produce C1–C5 against
a real vblank for the first time, on 20 threads at 5 GHz driving 60 Hz. That is a
generous machine, and a contract that only holds there is not the contract this
project claims. The second row is either the Mac Pro or a deliberately
constrained run on this one; **either is fine and neither is optional.**
