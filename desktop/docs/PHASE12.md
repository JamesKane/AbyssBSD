# Phase 12 — `Fathom`: the medium measures the machine (scope)

The phase that was ordered behind Phase 4 and got pulled in front of it. Read
[PLAN.md](PLAN.md) for the dependency order, [PHASE4.md](PHASE4.md) §5 for the
checklist this turns into a program and §5.1 for the constraint that moved it,
[PHASE5.md](PHASE5.md) for the medium and the hub it becomes a spoke of, and
[HANDOFF.md](HANDOFF.md) for the traps — §2.37 is this phase's whole discipline.

Last updated: 2026-09-05. **Scoped. Four risks spiked first, on both platforms,
before any of this was written** (§4). The most useful result is the dullest:
**the build VM answers "no" to every probe here**, which makes it the positive
control this phase cannot be written without.

---

## 1. What this phase is

The live medium is a delivery mechanism. It boots, it runs the installer, and if
something is wrong it says almost nothing — a black screen, or a console that
scrolls past. A live medium's *first* job is to answer "will this work here?"
before anyone commits a disk.

> `Fathom` is [PHASE4 §5](PHASE4.md) written down as a program: the ordered
> bring-up checklist a person works by hand on the one machine we own, running by
> itself on the machines we do not.

**And it is now Phase 4's only way forward.** The bring-up machine has one disk,
holding the working FreeBSD install that Phase 4's positive control is made of,
so the install is deferred (PHASE4 §5.1). Every question only real hardware can
answer needs no disk write — but the medium has to *say* what it found, and today
it barely does.

*To fathom* is to measure a depth and to understand it. It does not collide with
the Sound pane the way *Sounding* would.

### What is genuinely different about this phase

**The deliverable is not a feature, it is evidence.** Everything else in this
tree is judged by whether it works; this is judged by whether its answers are
*true on a machine nobody here has seen*. That inverts the usual test question
from "does the check pass" to "can the check fail", and it is why §4.1 spent its
effort finding the negative case for every probe before proposing any of them.

**It has three uses and one implementation:** the spoke that gates an install,
a standalone report for someone deciding whether to try, and — once installed —
the System Profiler this desktop does not have.

---

## 2. What we already have vs. what's new

The honest summary is that **most of this exists and none of it is collected.**

| Probe | Where the answer already lives | New in Phase 12 |
|---|---|---|
| Boot path — UEFI or BIOS | `machdep.bootmethod` (§4.1) | reading it; the medium never has |
| Machine identity — maker, product | **`kenv`, not sysctl** (§4.2) | a `kenv` bridge in `Vents` — the one genuinely missing mechanism |
| Modules bound — `amdgpu`, `i915kms`, `drm` | `kldstat`, `dmesg` | string parsing, pure |
| GPU and display — `/dev/dri`, connector, mode, refresh | `undertow` picks and knows the mode; wlroots reports mHz | reporting it rather than only using it |
| **C1 against the real vblank** | **`undertow bench-metronome` already prints all of it** (§4.3) | collecting it into a report instead of a console line |
| Input — keyboard, pointer, touchpad | `Seat`, libinput | enumeration |
| Disks — what is installable, **and what is occupied** | `probeMachine()`, `DiskInventory`, `existingPools` | already built — P4/P12's disk refusal shipped ahead of this phase |
| Network — interfaces, link, DHCP, wifi recognised | `ifconfig -l`, `net.wlan.devices` | new, and thesis 5's weak point |
| Audio — a device at all | `/dev/sndstat` | parsing a **negative that is a sentence**, not a missing file |
| Power — battery, ACPI | `Vents.Battery` | partly exists |
| CPU, memory | `Vents.Sysctl` | exists |

---

## 3. Ordered passes

**P12.1 — the probes, negative case first. ✅ done.**
A new `de/fathom` target: pure functions from captured text to values, the
`Probe.swift` pattern that P5.1 established and that `DiskInventory` proved.
Nothing here runs a command; a caller gathers, these interpret.

**The order within the pass is the discipline: for each probe, write the test
that says "absent" before the one that says "present".** The build VM answers
*no* to GPU, wifi, battery and audio (§4.1), so every negative assertion runs in
the harness on every build, on a machine that genuinely lacks the hardware —
which is the only way to know the check can fail. A `Fathom` that reports
"GPU: ok" on a machine with no GPU is worse than no `Fathom`, because it converts
an obvious failure into a confident lie.

**P12.2 — machine identity, and the tunable that has been unconditional. ✅ done.**
`smbios.system.maker` and `smbios.system.product` are in the **kernel
environment, not the sysctl tree** (§4.2), and `Vents` has no way to read it. Add
`av_kenv` to `de/cvents` on the exact `av_sysctl_read` pattern, and `Vents.Kenv`
over it — a few lines, and the only new mechanism in the phase.

Then spend it immediately: **`hw.pci.enable_pcie_hp="0"` stops being written to
every machine.** It is a MacPro6,1 accommodation that both loader.conf writers
currently give to everybody, and both of them say in a comment that Phase 12 is
where that ends. This is the pass that keeps that promise, and it is the first
time a probe *changes* what the medium does rather than only reporting it.

**What P12.1 and P12.2 actually landed**, and one thing they found:

- `de/fathom` — nine probes as pure functions over captured text, no
  dependencies, `ProbeStatus` carrying **three** answers so `unknown` cannot be
  spelled `absent`.
- `Vents.Kenv` over a new `av_kenv_read`, proven on FreeBSD: it reads
  `smbios.system.maker`/`product`, and a missing key returns nil rather than an
  empty string. `ventsctl kenv` exposes it by hand, exiting 2 when the machine
  does not identify itself.
- `needsPCIeHotplugDisabled(maker:product:)` — the rule that ends the
  unconditional tunable, pure so it is testable **without a Mac Pro**, which is
  the only way it could be tested at all now that we do not bring up on one.
- `MachineIdentity` on `DiskInventory`, filled by the privileged half from
  `Vents.Kenv`. It rides on the inventory rather than the plan because it is a
  fact about the machine and not a choice the user made — the same reason the
  disks are there — **and so it never crosses the wire**: the unprivileged half
  sends intent, and the half that is allowed to look at the machine supplies
  this.
- `loaderConf(_:machine:)` writes `hw.pci.enable_pcie_hp="0"` **only for a Mac
  Pro**. A machine that does not identify itself does not get it, which is the
  deliberate direction to fail in: omitting it costs a Mac Pro a scrolling
  console — visible, and recoverable by reinstalling from a medium that still
  sets it — while adding it everywhere costs a silent, permanent change to
  machines nobody examined.

**One tunable, two answers, and the difference is whether the machine can be
asked.** The *medium* keeps it unconditionally and that is not an oversight:
loader.conf is read by the loader, so there is no earlier moment at which a probe
could run, and the medium is built before it ever meets a machine. The *installed*
system is written by a program already running on the target. Both halves now say
so where somebody changing them will read it.

**And breaking the code found a hole in the tests, which is the whole reason for
doing it.** Deleting the `maker` check from that rule left the entire suite green:
no fixture paired a non-Apple maker with a Mac-shaped product, so the conjunction
was never exercised and half the check was decoration. The case is not
hypothetical — smbios strings are settable, and people do set them to Apple's
models. `testTheMakerAndTheModelBothHaveToMatch` exists because of that, and now
the break fails two assertions.

**P12.3 — the report, as a value and at two fidelities.** *(The value and the
console rendering are done; the Aqua view is what remains.)*
`FathomReport` is a struct, rendered rather than printed — the same shape as
`InstallPlan`, and for the same reason: a value can be asserted on, diffed and
sent, and a printed one cannot.

Two renderings, chosen by the rule P4.3 already uses — **`/dev/dri` present means
a person is watching, absent means a console is all there is**:

- an **Aqua view**, which is a list;
- a **console text form**, which must be legible on a machine too broken to draw
  anything.

**A report that cannot survive the failure it reports is not a report**, so the
console form is written first and the Aqua one is the addition.

**What the console half landed, and two bugs that only running it found:**

- `FathomReport` + `renderText`, and a `fathom` binary that gathers. The
  gathering is in the binary and nowhere else, so `Fathom` stays pure — the
  `Install`/`InstallRun` split again, for the same payoff.
- **The field list is decided on the way in** (§6.2): kinds of hardware go in,
  identity stays out. No serials, MACs, IPs, hostname, pool names or mount
  points. `DiskFact` exists rather than reusing `Install.Disk` precisely because
  that type carries `mountedAt` and `existingPools`, which a refusal needs and a
  file e-mailed to a stranger does not.
- Exit status follows **completeness, not suitability**. A machine with no
  battery and no wifi is a complete report and a fine desktop.

*Running it on Linux immediately produced `Network [ok] ifconfig:, option, '-l',
not, recognised.` — a command that ran and **failed** being read as data, with
the error message as its evidence. stderr now goes to /dev/null and a non-zero
exit is nil. The same run said "no battery, mains only" about a platform it
cannot ask at all; `canAsk` separates those. Both are the §6.1 failure mode
arriving by the back door, in a tool built to prevent it.*

*And the ASCII test caught the author: the first rendering had an em dash in its
own title and three more in probe details, written out of habit from the prose
two lines above them. `asciiOnly` now folds rather than trusts — the console this
is for belongs to a machine too broken to draw anything else.*

**P12.4 — the measurement, collected.**
The differentiator, and it is mostly already built (§4.3): `undertow
bench-metronome` prints period estimate, latch margin, composite cost p50/p99/p99.9,
missed flips per mille, degraded frames and a verdict, and `FlightRecorder`
carries all of it per frame. This pass gives those numbers a machine-readable
form and puts them in the report.

**Every live CD can say the GPU bound. Ours can say whether this machine holds
the frame contract, and by how much it misses.** No other installer tells you
your frame budget before you install. On metal that runs with a hardware clock
for the first time in the project's history (P4.5) — and the report must record
*which* clock it measured against, because a number from a nominal grid and a
number from a real vblank are not the same measurement (§2.48).

**P12.5 — the report leaves the machine.**
The matrix is populated by people who are not us, so the report has to be
retrievable by someone with one computer and no network.

**It goes on the ESP.** The medium's own EFI partition is FAT16 with ~41 MB free,
`msdosfs.ko` is on the medium, and the fstab mounts only the UFS root — so it is
a mount away (§4.4). FAT is the one filesystem Windows, macOS and Linux all read:
pull the stick out, plug it into anything, and the report is a file. Writing it
to the UFS root instead would make it readable only by the system that could not
be installed.

**P12.6 — the spoke, and the gate.**
`Fathom` becomes a spoke in P5.4's hub, and can refuse in the attention styling
before Install is reachable — no GPU, no installable disk, no network device. The
disk half of that gate **already shipped ahead of this phase**: `existingPools`
and `diskHoldsExistingSystem` came out of checking whether the medium was safe to
boot at all (PHASE4 §5.2), which is the shape of everything here.

---

## 4. The spikes — four, and the dullest one matters most

Measured on both platforms, before any of the above was written.

### 4.1 Can these probes fail? — **Yes, and the build VM fails all of them.**

The question §2.37 forces, and the reason it is asked first: a probe suite
written against a machine that answers *yes* to everything has no evidence it can
say *no*. Asked of the build VM:

| Probe | What the VM answers | Usable as a negative control |
|---|---|---|
| GPU | no `/dev/dri` at all | ✅ |
| Wifi | `net.wlan.devices:` — **empty, not missing** | ✅ |
| Battery | `hw.acpi.battery.life` → *unknown oid* | ✅ |
| Audio | `/dev/sndstat` → `No devices installed.` | ✅ and better than absent: a **parseable sentence**, so the parser is exercised rather than skipped |
| Machine identity | `smbios.system.maker="QEMU"` | ✅ distinguishable from `Apple Inc.` |
| Boot path | `machdep.bootmethod: BIOS` | ✅ — **and the harness has both cases**, because the nested bhyve boot in `live-medium.sh` is UEFI |

**So every probe in this phase has its failing case exercised on every build, on
a machine that really is missing the hardware.** That is a stronger position than
this project usually gets to start from, and it is the reason the phase is
scoped as "write the negative test first" rather than as a list of features.

### 4.2 Where does machine identity live? — **`kenv`, and we cannot read it.**

`kenv smbios.system.product` answers; `sysctl -aN | grep smbios` returns only
`dev.smbios.*`, which are device-tree nodes and not the system's maker and model.
So identity is in the **kernel environment**, and `Vents` has `Sysctl`, `Volume`,
`Battery` and `Devd` — and nothing for `kenv`.

That is the phase's one genuinely missing mechanism, and it is small: `kenv(2)`
is declared in `<sys/kenv.h>`, and `de/cvents` already carries `av_sysctl_read`
as the pattern to copy.

**It is also the pass with a debt attached.** Both loader.conf writers hand
`hw.pci.enable_pcie_hp="0"` to every machine we build or install, and both say in
a comment that this is a Mac Pro accommodation waiting on Phase 12 to become
conditional. This spike is what makes that possible, so P12.2 pays it rather than
deferring it again.

### 4.3 How much of the measurement is left to build? — **Less than the pitch implies.**

PRODUCT §6.4 sells measurement as the differentiator, so it is worth being honest
about how much of it exists. `undertow bench-metronome` already prints:

```
  period estimate   …
  latch margin      …
  composite cost    p50 …   p99 …   p99.9 …
  missed flips      … of …  (… per mille)
  degraded frames   …
  verdict           ok
```

and `FrameRecord` carries `predictedVblank`, `actualVblank`, `marginNs`,
`costNs`, `wakeLateNs`, `damageArea`, `surfaces`, `missed` and `degraded` for
every frame.

**The measurement is built. What is missing is that it is human text on a console
and nowhere else.** So P12.4 is a serialisation pass, not a benchmarking one —
which moves effort out of the hard-sounding part of this phase and into the
reporting, where it actually is.

### 4.4 Can a report get off the machine? — **Yes, on the ESP, and that is the point.**

The matrix depends on strangers sending reports back, which means the retrieval
path cannot assume a network — thesis 5's weakest area is exactly the machines
where the network does not come up.

Checked on the built medium: `/etc/fstab` mounts only `/dev/ufs/ABYSSLIVE`, so
the ESP is **not** mounted at runtime — but `msdosfs.ko` is on the medium, and the
ESP is FAT16 with about 41 MB free after `BOOTX64.EFI`. Mounting it on demand and
writing a file there costs nothing we do not already carry.

**FAT is the one filesystem every desktop OS reads.** A person boots the stick on
a machine that will not network, saves a report, pulls the stick, and opens it on
whatever computer they do have. The alternative — the UFS root — produces a file
readable only by the operating system that could not be installed on that machine.

---

## 5. Verification

Unchanged where it can be: `abyss/tests/run.sh --vm --live` on both platforms,
and **nothing here may make an existing live mode depend on hardware.**

**Pure, and the negative first:**

- Every probe parser against **captured** output, never invented — the rule
  `InstallRunTests` already keeps, and the reason the `zpool import` parser was
  tested against a machine carrying three vdev shapes at once.
- For each probe, an **absent** case and a **present** case, with the absent one
  written first. §4.1 is the list, and the build VM supplies six of them for
  free.
- `Vents.Kenv` against a key that exists and a key that does not.

**Live:**

| Script | What it proves |
|---|---|
| `live-fathom.sh` | the report is produced in the build VM and **says "no" to GPU, wifi, battery and audio** — the whole suite's positive control |
| `live-fathom-console.sh` | the console rendering with `undertow` refusing to start, because that is the machine that most needs a report |
| `live-medium.sh` (extended) | the medium carries `fathom`, and the ESP is mountable and writable from the booted system |

**And the check that keeps the phase honest**, in the §2.37 tradition and stated
as an obligation rather than a hope: **before this phase closes, take a probe,
make it report success unconditionally, and confirm the suite goes red.** A
confinement test that has never failed is a comment; so is a hardware probe.

---

## 6. Risks / open decisions

**6.1 A probe suite is a place where "unknown" gets rounded to "fine".**
Every probe has three answers — yes, no, and *could not tell* — and the third is
the one that decays. A machine where `kldstat` was not readable must report
exactly that, and it must be visually distinct from a machine where the module
was checked and absent. The type should make the third case unavoidable rather
than a default, because the failure mode is not a wrong answer, it is a
confident one.

**6.2 What the report is allowed to contain.**
It is meant to be sent to us, so it is a privacy surface before it is anything
else. Serial numbers, hostname, MAC addresses, disk labels and pool names are all
things a probe naturally reaches. **Decide the field list on the way in, not by
redacting on the way out**, and have the report show a person exactly what they
are about to send — the same argument thesis 4 makes about a descriptor rather
than a path.

**6.3 The matrix is a product, not a file, and this phase does not build it.**
P12.5 gets a report onto a stick. Turning returned reports into a published
support matrix needs somewhere to send them, a format that survives version
skew, and someone to curate it — which is Phase 17's infrastructure and a
maintenance obligation of the same kind (PLAN risk 8). **Scope this phase to
producing the evidence** and say plainly that consuming it is not in it.

**6.4 One machine's numbers again.** The C1 figures this phase reports will come
first from a 20-thread 5 GHz machine driving 60 Hz (PHASE4 §6.7). A report format
that encourages comparing machines is good; a *verdict* that says "this machine
is fine" calibrated on one fast one is not. Report the numbers and the budget
they were measured against, and be slow to add a pass/fail.

**6.5 It must not become a second installer.** Fathom reads, and the one thing it
writes is its own report. It does not import a pool to find out what is on one
(the disk probe already established that a **scan** answers that — PHASE4 §5.2),
it does not load modules to see whether they would bind, and it does not mount a
filesystem it found. Every one of those is a plausible next probe and every one
of them changes the machine it is describing.
