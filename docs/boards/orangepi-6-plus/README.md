# Orange Pi 6 Plus (CIX P1 / Sky1)

The Orange Pi 6 Plus, CIX Technology's "Phecda" reference design for its P1
SoC (CD8180, "Sky1"), as its firmware still names it (DMI: "CIX Phecda
Board"; the HDA card calls itself "CIX SKY1 ORAPI 6P"): 12 Armv9.2
cores (4 Cortex-A720 at up to 2.6 GHz, 4 A720 at 2.5 GHz, 4 A520), 32 GB, an
Arm Immortalis-G720 MC10 GPU (Panthor, CSF), Arm China Linlon display
controllers, a Zhouyi NPU, two RTL8126 5 GbE, NVMe. The same SoC is in the
Radxa Orion O6. Work starts 2026-10-02: this is the
strategy, from a read-only survey of the board under its stock Ubuntu
(26.04, CIX kernel 7.0.0-41-cix, ACPI boot). The survey's raw output is not
in the tree yet (`dmidecode` carries serials to redact first).

**Status (2026-10-08):** FreeBSD 16-CURRENT runs the board from its NVMe
with everything above marked as working: the desktop (sway) on the GPU and
the HDMI port, sound, both 5 GbE ports, deep CPU idle and frequency
scaling, the SMMUs translating, the NPU, and the video codec. The kernel
side is on freebsd-src's `orangepi-6-plus` branch, which this tree's `src`
follows; the out-of-tree drivers (panthor, komeda, the NPU's and the
codec's) are their own repositories. The board still needs `loader.conf`
settings. What's missing: USB-C display and device mode, the other
display outputs, I2S and the audio DSP, a serial console without
settings. Hardware notes: [gpu.md](gpu.md), [npu.md](npu.md),
[vpu.md](vpu.md).

Board access: Ubuntu at 192.168.0.27, user `jkane`, key login; root needs
`sudo` (the user's password), so root steps go through a script the user
runs once (`sky1-collect.sh`).

## What the survey says

**A SystemReady ACPI platform written for Linux.** UEFI 1.3 (2025-11-13)
hands over ACPI only (no devicetree in Linux), with APIC, GTDT, IORT, MCFG,
PCCT, PPTT, SDEI, DBG2, CSRT, a DSDT and two SSDTs. Unlike the Q8B's tables,
which route power and clocks through Windows' PEP, these describe them for
an OS: power domains are ACPI power resources (`_PR0`/`_PR3`), clocks are
AML methods that call the power-management firmware over SCMI, CPU
performance is `_CPC`, idle is `_LPI`. CIX's private devices (`CIXHxxxx`)
carry devicetree-style properties in `_DSD`. No vendor hypervisor: Linux
runs KVM, so EL2 is the OS's, and nothing polices SMMU writes as the Q8B's
did.

| Area | Hardware and how ACPI describes it | Linux driver | FreeBSD (2026-10-08) |
|---|---|---|---|
| CPUs | 12 cores, PSCI 1.1 (SMC), PPTT; 6 frequency domains of 2 cores | — | **works**; big.LITTLE placement through the hmp(4) review stack (`hmp-sky1`) |
| Interrupts | GICv3 + ITS (GICv4.1), 512 SPIs; Linux applies the workaround for Arm erratum 2941627 | gic-v3 | `gic_v3`, `its`; erratum 2941627 still unexamined |
| Timers | GTDT; CIX GPT wake-up timer `CIXH1007` | sky1_timer | generic timer; **`sky1_gpt`** as the global event timer for deep idle |
| CPU idle | `_LPI`: LPI-0 standby, LPI-1 core power-down (360 µs), LPI-2 cluster power-down (500 µs) | acpi_idle | **works**: all three states (`acpi_cpu` `_LPI`, from the Q8B) |
| CPU frequency | `_CPC`: desired performance a 32-bit SystemMemory register (the SCMI fastchannel, e.g. `0x659009c`), delivered/reference counters FFixedHW (AMU), perf 2520–8192 for 800–2600 MHz | cppc_cpufreq | **works**: **`acpi_cppc`**, 800–2600 MHz per `_PSD` domain, `powerd` per domain |
| Thermal | 13 ACPI thermal zones (`_TMP`), processor cooling | acpi-thermal | **works**: `acpi_thermal`, each CPU domain cooled from its zones; critical shutdown untested |
| Watchdog | GTDT SBSA generic watchdog | sbsa_gwdt | **works**: **`sbsa_gwdt`** (refreshes through `WOR`: Sky1's refresh frame doesn't) |
| IOMMU | SMMUv3 at `0xb010000` (PCIe), `0xb1b0000` (DPU0/1, NPU, AEU0, …); IORT RMRs | arm-smmu-v3 | **works, translating by default**: PCIe and named components (display, NPU), RMR identity maps, DMA mapped as Normal memory ([`sky1-iommu`](#branches-and-repositories)) |
| PCIe | ECAM (MCFG), 3 `PNP0A08` root ports (CIX `1f6c:0001`) | pci host generic + sky1-pcie | **works**: `pci_host_generic_acpi` |
| NVMe | Micron 2550 (`1344:5416`) | nvme | **works**: `nvme`, host memory buffer, behind the SMMU (relaxed ordering off) |
| Ethernet ×2 | RTL8126 5 GbE (`10ec:8126`) on PCIe | r8169 | **works**: `rge(4)` |
| USB | 10 xHCI hosts (`XHC0`–`XHC5`, `USB0`–`USB3`), which the firmware puts in host mode and describes as standard `PNP0D10`; the Cadence dual-role devices (`CIXH2030`/`2031`, PHYs `CIXH2033`) behind them | cdnsp-sky1, xhci-hcd | **works** (host): `xhci` ×10 on ACPI; no device mode |
| USB-C / PD | RTS5453H PD controllers on I²C (`CIXH200D`); DP alt mode through `CIXH2033` | rts5453h | `rts5453` reports the ports' state; no DP alt mode |
| UART | 4 SBSA UARTs `ARMH0011` (`0x40b0000`…`0x40d0000`); DBG2 names COM2 at `0x40d0000`; **no SPCR** | sbsa-uart | `uart_pl011` attaches; no automatic serial console |
| GPIO, I²C, pins | Cadence GPIO (`CIXH1002`/`1003`), Cadence I²C ×7 (`CIXH200B`), pinctrl (`CIXHA016`/`017`) | cdns-* | **works**: `cdnc_i2c` on ACPI (Linux's receive state machine), `cdns_gpio`; the RX8900 RTC (`rx8803`); writes beyond the FIFO untested; no pinctrl |
| Clocks, resets, power | SCMI over a mailbox (`CIXHA006`, `CIXHA001` ×6, PCCT type 2 at `0x83bf1280`), clock controller `CIXHA010`, resets `CIXHA020`/`021`, PDC `CIXHA019` | scmi, clk-sky1-acpi | **`cix_mbox`** + **`sky1_scmi`**: clocks, power domains (TF-A), performance domains (DVFS); resets by the reset registers |
| Display | Linlon DP ×5 (`CIXH5010`) + Trilinear DP TX (`CIXH502F`), eDP panel; monitor on DP-4; UEFI GOP framebuffer handed over | linlondp, simpledrm | **works on DP-4 (HDMI)**: komeda + CIX's DP transmitter through LinuxKPI ([`drm-komeda-kmod`](https://github.com/JamesKane/drm-komeda-kmod)), translated by the SMMU; no EDID behind the PS185 (Linux neither); other outputs and eDP untried |
| GPU | Immortalis-G720 MC10 (`CIXH5000`), devfreq | panthor | **works**: panthor from Linux 7.0 through LinuxKPI ([`drm-panthor-kmod`](https://github.com/JamesKane/drm-panthor-kmod)), GLES 3.1 in Mesa, sway; DVFS 72–1000 MHz ([gpu.md](gpu.md)) |
| Audio | HDA controller `CIXH6020` at `0x70c0000` with a Realtek **ALC269VC** codec; I2S ×4, an audio DSP `CIXH6000` | cix-ipbloq-hda | **plays**: `hdac`/`snd_hda` on ACPI; recording and jack sense untested; some boots lose the codec (not understood); no I2S or DSP |
| Video codec | `CIXH3010`, Arm Mali-V (Linlon v5276), four cores | amvx_dev | **decodes and encodes**: [vpu-kmod](https://github.com/JamesKane/vpu-kmod) (CIX's driver and Linux's V4L2 core through LinuxKPI), loaded at boot; FFmpeg's `*_v4l2m2m` decode H.264, HEVC, VP9 bit-exactly and encode H.264, HEVC ([vpu.md](vpu.md)) |
| NPU | Zhouyi X2 (`CIXH4000`, `CIXH4010` ×3), 30 TOPS | (vendor) | **works**: CIX's driver through LinuxKPI ([`aipu-kmod`](https://github.com/JamesKane/aipu-kmod)), Arm China's user driver ([`aipu-umd`](https://github.com/JamesKane/aipu-umd)), CIX's binary stack and ONNX Runtime under the Linuxulator, DVFS ([npu.md](npu.md)) |
| Other | TPM (`MSFT0101`), OP-TEE (`CIXHA022`), DMA-350 (`CIXH1006`, `CIXHA014`), PWM, battery/AC objects | — | none |

Firmware bugs seen: the DSDT names `I2C0.UXC0`–`UXC3` (USB-C controllers)
that don't exist (`AE_NOT_FOUND` at load, harmless on Linux).

## Branches and repositories

Kernel: freebsd-src branch **`orangepi-6-plus`**, FreeBSD `main` of
2026-09-07 plus the Q8B's `radxa-dragon-q8b` and the Sky1 work on top, in
one line (it holds what the topic branches `hmp-sky1`, `sky1-audio`,
`sky1-i2c`, `sky1-gpio`, `sky1-usbc`, `sky1-log`, `sky1-probe` and
`sky1-iommu` did). Kernel config `GENERIC-HMP-IOMMU` (GENERIC, the hmp(4)
scheduler stack, `options IOMMU`).

Out of tree, through LinuxKPI (GPL, BSD glue):
[`drm-komeda-kmod`](https://github.com/JamesKane/drm-komeda-kmod) (display),
[`drm-panthor-kmod`](https://github.com/JamesKane/drm-panthor-kmod) (GPU),
[`aipu-kmod`](https://github.com/JamesKane/aipu-kmod) (NPU), on drm-kmod's
`sysfbdrm`; NPU user space in
[`aipu-umd`](https://github.com/JamesKane/aipu-umd).

The board's default kernel is `GENERIC-HMP-IOMMU` built from the pushed
branch (`d513e50da5`, 2026-10-10), with the out-of-tree modules built
against it in `/boot/kernel`.  It still runs with settings: `loader.conf`
`kern.eventtimer.timer="Sky1 GPT"`, `hw.iommu.dma="1"`,
`hw.smmu.bypass_named="0"`, `drm.debug="0"`; `rc.conf` C3 idle and the
branch's `powerd`. Each is a default still to make.

## The strategy

Others have been here on Linux, and are worth reading first: an SMMUv3
event-queue interrupt storm fix for this board
(github.com/ErcinDedeoglu/orangepi-6plus-cix-sky1-smmu-fix), and a GPU
bring-up through SCMI and Panthor (github.com/visorcraft/orange-pi-6-plus-gpu).

The Q8B's lessons ([../radxa-dragon-q8b/lessons.md](../radxa-dragon-q8b/lessons.md))
apply as they are; the ones that shape this plan:

- **Read before experimenting; Linux on the board is ground truth.** Every
  phase starts from the survey and, where it helps, a register diff
  against Linux (debugfs, `/dev/mem`).
- **"Nothing special."** Stock GENERIC and an empty `loader.conf` are the
  goal from the first boot; a board setting is a driver bug.
- **Stream the logs; no console means no record.** Until a serial
  console works, test over ssh with the logs streamed.
- **Generic code first.** Where the platform is standard (ACPI CPPC, `_LPI`,
  HDA, xHCI, SMMUv3), the work is a FreeBSD driver any SystemReady board
  uses, which goes upstream; CIX-specific code only where the hardware is.
- **It's all ours, and Linux code is reference only.** BSD rewrites; GPL
  stays in `kmod/` as with msm.

### Phase 0: ground truth (done 2026-10-02)

The survey above: ACPI tables (raw and disassembled), dmesg, `/proc/iomem`,
interrupts, PCI, USB, CPPC/cpufreq, idle, thermal, clocks, SCMI, DRM,
sound. To do: redact and commit it under `dumps/`, and record the GOP
mode and the UART header's pinout and voltage (a console is worth having
before any risky test).

### Phase 1: boot stock FreeBSD from USB (booted 2026-10-02)

The 16-CURRENT snapshot memstick (`36d3e711bc62`, 2026-09-28) boots to its
installer from USB with nothing added, and attaches:

- 12 CPUs (A720 ×8, A520 ×4), GICv3 + ITS, PSCI, SMCCC 1.2, the generic
  timer (1 GHz) as timecounter and event timer;
- `efifb` console at 1920×1080, and **`efirtc`**: UEFI's clock works;
- the four PL011 UARTs (`uart2` is DBG2's COM2 at `0x40d0000`);
- 13 ACPI thermal zones;
- three generic ECAM hosts: **`nvme0`/`nda0`** and **`rge0`/`rge1`** (RTL8126
  rev 2, `if_rge` autoloaded by devmatch), `rge0` getting an address by DHCP;
- **`xhci` ×10** (see USB above): keyboard, mouse and the stick work.

Not attached, as expected: HDA (`CIXH6020`), display (`CIXH5010`), GPU,
I²C, GPIO, the CIX USB dual-role devices, SCMI/mailboxes, NPU, VPU. No
`_LPI` idle and no cpufreq. Messages: only the DSDT's missing `UXC*`
objects and "Could not update all GPEs". The SMMUs aren't used.

What was planned here:

16-CURRENT GENERIC on a USB stick, booted from UEFI's menu; Ubuntu's NVMe
untouched. Expect: GIC/ITS, PSCI SMP, generic timer, ACPI, PCIe ECAM,
NVMe, `rge` ×2, `efifb` console, `uart` ×4, ACPI thermal. Record what
attaches and what doesn't (a verbose boot, `devinfo -rv`, `pciconf -lv`),
and settle a serial console (DBG2's COM2, with `hw.uart.console` only as a
bring-up crutch; or SPCR from firmware). Check whether the GIC erratum
needs FreeBSD's attention (Linux enables a workaround; FreeBSD has none).

Then root on NVMe in its own partition (a second disk, or shrinking
Ubuntu's: the user's call), so that kernel tests use `nextboot -k` as on
the Q8B.

### Phase 2: the platform

- **USB:** nothing to do for host mode (phase 1); the USB-C ports'
  dual-role and DP side come with USB-C.
- **Ethernet:** `rge` on both 5 GbE ports; measure as for `tcx`.
- **SMMUv3:** decide bypass or translation for PCIe; watch for the
  event-queue interrupt storm reported on Linux.
- **GPIO, I²C, pinctrl:** `cdnc_i2c` on ACPI, Cadence GPIO, when something
  needs them (USB-C PD, sensors).

### Phase 3: power, the generic parts first (in progress)

Branch `orangepi-6-plus` of freebsd-src, from `radxa-dragon-q8b` (local
until the Q8B is regression-tested; 2026-10-02):

- **CPU idle: works.** All three `_LPI` states: WFI, core power-down
  (PSCI `0x10000`, 3 ms/360 µs) and cluster power-down (`0x1010000`,
  10 ms/500 µs). Three things beyond the Q8B's code:
  - the firmware leaves `_LPI`'s context-lost flag clear on its power-down
    states, so `acpi_cpu` also reads the PSCI state's type bit, as Linux;
  - UEFI enters the kernel at EL2 and it runs with VHE, and the cores have
    SVE: the power-down path now restores the SVE vector length and
    vmm(4)'s `VTCR_EL2`, and allows VHE;
  - the cores' generic timers stop in both states and the GTDT has no
    memory-mapped timer: **`sky1_gpt`** drives CIX's general purpose timer
    (`CIXH1007`, 25 MHz, the one Linux broadcasts with) as a global event
    timer, its interrupt on CPU 0, which stays in WFI.

  Opt-in, as on the Q8B: `kern.eventtimer.timer="Sky1 GPT"` and
  `hw.acpi.cpu.cx_lowest=C3`. Idle cores then spend 83-100% powered down.
  Soaked: mixed CPU, NVMe and network load, 140 logins without a stall, SVE
  registers intact across 8000 idle sleeps.
- **CPU frequency: works.** **`acpi_cppc`**, a generic cpufreq(4) driver for
  `_CPC` (SystemMemory registers, arm64 AMU counters), one per `_PSD` domain:
  CPUs 0-1, 2-5, 6-7, 8-9, 10-11, as Linux's policies, 800 MHz to
  1.8-2.6 GHz in 100 MHz levels. `dev.acpi_cppc.N.delivered_mhz` measures
  the real clock; the firmware rounds a request up to its operating points:

  | Domain | Operating points (MHz) |
  |---|---|
  | 0-1 (A720) | 800, 1200, 1500, 1900, 2000, 2100, 2200, 2500, 2600 |
  | 10-11 (A720) | 800, 1200, 1500, 1900, 2000, 2100, 2200, 2400, 2500 |
  | 2-5 (A520) | 800, 1800 |

  The branch's `powerd` runs each domain on its own; base `powerd` only
  drives CPU 0's.
- **Thermal: works.** All 13 zones report (about 42 °C idle), critical at
  98 °C, passive from 85 °C. `acpi_thermal` now cools each domain from the
  zones whose `_PSL` names it: `TZB1` CPUs 0-1, `TZM0` 6-7, `TZM1` 8-9,
  `TZB0` 10-11 (the little cluster has no zone); zones naming no CPU, such
  as the video unit's, slow nothing. Tested by lowering `TZB1`'s `_PSV`
  (`hw.acpi.thermal.user_override=1`). To do: the critical shutdown test.
- **Watchdog: works.** **`sbsa_gwdt`**, a generic driver for the GTDT's
  SBSA watchdog (here architecture version 1). On Sky1 a write to the
  refresh frame does not refresh it, and Linux's driver, which refreshes
  that way, would reset the board if armed; the driver checks at attach
  and refreshes through `WOR` instead. `watchdogd -t 8` keeps the board up;
  left unrefreshed it resets it.
- **Device power:** ACPI power resources and the AML clock methods, as
  devices need them.
- Also: the Qualcomm GLINK clients built into the branch's GENERIC no
  longer wait for a DSP on this board.

### Phase 4: display and desktop, early (sway runs, 2026-10-02)

On the branch kernel, `drm-kmod`'s `sysfbdrm` (from the Q8B, unchanged)
drives the UEFI framebuffer (1920x1080 at `0x84800000`), and sway 1.12 from
packages runs on it with Mesa's llvmpipe (`WLR_RENDERER=pixman` until the
libdrm fix for boards without a render node is in the package). `fastfetch`
has no FreeBSD 16 aarch64 package; built from its release source it runs.

Also found: the installer's `/etc/resolv.conf` has no `resolvconf`
signature, so DHCP never updated it and DNS failed; `resolvconf -u` fixes
that.


`efifb` and our `sysfbdrm` (from the Q8B) give KMS on the GOP framebuffer
with no display driver, which is enough to run the AbyssBSD desktop with
software rendering, as it did on the Q8B before msm. The Linlon DP KMS
driver (`linlondp`, 5 controllers, Trilinear DP PHYs) comes later, ported
through LinuxKPI if its licence allows, or written.

### Phase 5: audio

HDA with an ALC269VC: an ACPI attachment for `hdac` (`CIXH6020`) and
whatever the controller's power resource and clocks need. The codec is one
`snd_hda` knows.

### Phase 6: GPU

Panthor (CSF Malis, the G720) through LinuxKPI in `kmod/`, as msm was:
the largest item. Its ACPI identity is `CIXH5000`; Linux upstream's panthor
has no ACPI match table, so CIX's kernel is the reference. Mesa's panvk
and panfrost (CSF) for the userland.

### Later

The NPU (Zhouyi), the video codec, USB-C PD and DP alt mode, the eDP
panel, the audio DSP, Wi-Fi (no module fitted: nothing on PCIe or USB).

## Decisions (2026-10-02)

- **ACPI**, as for the Q8B: it is what the firmware gives, it is complete,
  and Linux uses it. (Mainline Linux goes DT-first for Sky1, with
  `acpi=off`; that path needs a DTB the firmware doesn't provide.)
- **FreeBSD shares the NVMe.** Ubuntu's root (`nvme0n1p2`, ext4) shrinks to
  about 100 GiB from a live USB stick (ext4 can't shrink mounted), leaving
  ~360 GB unallocated for FreeBSD's installer, its swap big enough for
  crash dumps; the ESP (`nvme0n1p1`, 1 GB) is shared. Ubuntu stays as the
  Linux reference. Done 2026-10-02: `nvme0n1p2` is 97.7 GiB (sectors
  2203648–207003647, 17 GB used), and ~367 GiB from sector 207003648 to the
  end is unallocated.
- **Serial console:** the 10-pin debug header is 3.3 V, so a common USB-TTL
  adapter works (unlike the Q8B's 1.8 V pads). UART2, the BIOS and kernel
  log, is pin 1 TX, pin 3 RX, pin 5 GND, and is the DBG2 table's `COM2` at
  `0x40d0000`; UART4 (power-management firmware log), UART5 (secure
  element) and UART6 (POST codes) share the header.
- **A watchdog:** the GTDT describes an SBSA generic watchdog (refresh frame
  `0x16008000`, control `0x16003000`) that FreeBSD has no driver for. A
  small generic one turns hangs into resets instead of power cycles, and
  goes upstream with the CPPC driver.
