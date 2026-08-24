# Phase 4 — the Mac Pro: real graphics, real input, real numbers (scope)

The last phase, and the first one whose verification needs a machine that is not
in this loop. Read [PLAN.md](PLAN.md) for the locked decisions, [PHASE6.md](PHASE6.md)
for the frame contract this has to meet on metal, and [PHASE5.md](PHASE5.md) for
the installer that is how anything gets onto that machine at all.

Last updated: 2026-08-24. **Scoped, and P4.1 is done.** Three risks were spiked
first — two retired, one *deliberately left open* because only the hardware can
close it (§4).

---

## 1. What this phase is

Everything above this line was proven on a machine with no display. `undertow`
had one backend, `wlr_headless_backend_create`; every click in this tree came
from `wlr-virtual-pointer`; and PHASE6's C1–C5 were measured against a synthetic
clock where a frame "presents" the instant it is committed.

That was the right scope and it is now spent. The claim this phase has to make:

> The Aqua desktop is interactive on a Mac Pro: a real display at its own refresh
> rate, a real mouse and keyboard, and the frame contract holding against a
> vblank we did not invent.

**And the way it gets there is the installer.** That is not a convenience — it is
the delivery mechanism. To try anything on that machine, an image built by
`abyss/mk/live-image.sh` has to boot on Apple's EFI, bind a GPU, and put the
installer on the screen. Every pass below is therefore shaped by "can it be put
on a USB stick and booted", not by "does it work in the VM".

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
| A way onto the machine | the live medium (P5.3) | `drm-kmod`, GPU firmware, and a session that is not headless |
| Refusals that know the machine | `DiskInventory` (P5.1) | Apple NVMe, and disks that are not `vtbd0` |
| A supervisor | `anchor` (P3.6, P8.4) | `rtprio` for the present thread |

---

## 3. Ordered passes

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

**P4.3 — the medium goes metal-ready.** The image `abyss/mk/live-image.sh` builds
runs `undertow` headless and would come up on a Mac Pro with nothing on the
screen. It needs: `drm-kmod` and the Southern Islands firmware (§4.2), a
`loader.conf` that asks `amdgpu` for `si_support`, `seatd` or the equivalent so
the session can take DRM master, and a live session that says `--backend auto`.
This is the pass that produces the thing to put on a stick.

**P4.4 — first light.** Boot the stick on the Mac Pro and work the checklist in
§5. The interesting failures are all early: Apple's EFI is particular about what
it will boot, and `amdgpu` binding GCN 1.0 is the biggest open risk in the
project (§6.2). The output of this pass is *findings*, and the plan below it will
be rewritten by them — which is the honest thing to say about a pass nobody has
run yet.

**P4.5 — C1 against a real vblank.** Every number in PHASE6.md came off a
synthetic clock. Re-measure on the Mac Pro: the metronome's EWMA prediction now
has a hardware timestamp to learn from (`WLR_OUTPUT_PRESENT_HW_CLOCK`, which the
code already distinguishes and which has never once been set in this project's
history). Plus `allow.rtprio` for the present thread. **The C1–C5 numbers in
PHASE6.md should be treated as provisional until this pass replaces them.**

**P4.6 — the rest of the machine.** Apple NVMe quirks, Thunderbolt 2, audio (the
volume status item has reported "no mixer" since P3.7 and would finally have
one), and the network. Broadcom Wi-Fi is weak on FreeBSD and the answer is
probably a USB Ethernet adapter — which is also why the installer was built
offline-first (PHASE5 §6.2).

---

## 4. The spikes — two retired, one left open on purpose

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

### 4.2 Is the FirePro D-series even packaged? — **The pieces are, on FreeBSD 15.**

`drm-61-kmod` and `drm-66-kmod` are built for the 15.0 kernel ABI (`1500068`),
and **all five Southern Islands firmware packages exist**:
`gpu-firmware-amd-kmod-{tahiti,pitcairn,verde,oland,hainan}`. The Mac Pro's D300
is Pitcairn; the D500 and D700 are Tahiti.

This does not prove `si_support` binds — see §6.2 — but it retires the version of
the risk that would have ended the phase, which was "the firmware is not
distributed for this OS at all".

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
everywhere, so **nothing in this phase is allowed to make the existing 39 live
modes depend on hardware.**

What is new is the half a script cannot do. The bring-up checklist, in the order
the answers matter:

1. **Does the stick boot?** Apple EFI, `\EFI\BOOT\BOOTX64.EFI`, the loader menu.
   *If not:* the medium's GPT/ESP layout, before anything about graphics.
2. **Does it reach multi-user?** `Setting hostname: abyss-live` on the console.
   *If not:* it is a driver or a root-mount problem and the screen is irrelevant.
3. **Does `amdgpu` attach?** `kldstat`, `dmesg | grep -i amdgpu`, `/dev/dri/card0`.
   *This is the risk.* If SI does not bind, §6.2's fallbacks are the next move.
4. **Does `undertow --backend auto` find an output?** Its own log names the
   connector and the mode.
5. **Is the installer on the screen?** Which is the phase's first real
   deliverable, and the first time any of this has been *seen*.
6. **Then, and only then, the numbers.** C1 with a hardware clock, under load,
   with and without `rtprio`.

Each step's failure is a different phase, which is why they are ordered.

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

**6.2 `amdgpu` and GCN 1.0.** Unchanged as the biggest risk in the project, and
now the *only* one that can end a phase. Southern Islands support in `amdgpu` is
off by default and behind `si_support`; `radeonkms` is the older alternative and
does not do atomic modesetting, which the present path wants. Fallbacks in order:
`amdgpu` with `si_support=1`; `radeonkms`; and, if neither binds, the machine
still installs and runs headless — the desktop just cannot be seen, which is a
Phase 4 failure rather than a project one.

**6.3 The dual GPU.** The Mac Pro has two FirePros and a display connected to
one. wlroots' multi-GPU handling exists but is the least travelled path in it.
Expect to pin the primary with `WLR_DRM_DEVICES` before expecting anything
clever.

**6.4 A person is in the loop, and people are slow.** Every pass from P4.4 on has
a human boot cycle in it. The way to keep that cheap is to make the medium say as
much as possible on its own console — which it already does (PHASE5 §4.3's live
session reports on itself) — so that one boot answers several questions instead
of one.

**6.5 There is still no login window** (PHASE5 §6.8), and on a real machine that
somebody else uses, it starts to matter.
