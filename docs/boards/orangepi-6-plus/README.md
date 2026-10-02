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

| Area | Hardware and how ACPI describes it | Linux driver | FreeBSD today |
|---|---|---|---|
| CPUs | 12 cores, PSCI 1.1 (SMC), PPTT; 6 frequency domains of 2 cores | — | boots (FreeBSD 15 is reported to on the Orion O6) |
| Interrupts | GICv3 + ITS (GICv4.1), 512 SPIs; Linux applies the workaround for Arm erratum 2941627 | gic-v3 | `gic_v3`, `its`; FreeBSD has no workaround for 2941627: find what it needs |
| Timers | GTDT; CIX GPT wake-up timer `CIXH1007` | sky1_timer | generic timer; GPT as `generic_timer_mem`-like broadcast later |
| CPU idle | `_LPI`: LPI-0 standby, LPI-1 core power-down (360 µs), LPI-2 cluster power-down (500 µs) | acpi_idle | **ours from the Q8B** (`acpi_cpu.c` `_LPI`, `cpu_suspend.c`) |
| CPU frequency | `_CPC`: desired performance a 32-bit SystemMemory register (the SCMI fastchannel, e.g. `0x659009c`), delivered/reference counters FFixedHW (AMU), perf 2520–8192 for 800–2600 MHz | cppc_cpufreq | **none**: the reported "stuck at 1 GHz"; an ACPI CPPC driver is the gap |
| Thermal | 13 ACPI thermal zones (`_TMP`), processor cooling | acpi-thermal | `acpi_thermal` |
| IOMMU | SMMUv3 at `0xb010000` (PCIe), `0xb1b0000` (DPU0/1, AEU0, …) | arm-smmu-v3 | `smmu(4)`; a known Sky1 event-queue interrupt storm on Linux |
| PCIe | ECAM (MCFG), 3 `PNP0A08` root ports (CIX `1f6c:0001`) | pci host generic + sky1-pcie | `pci_host_generic_acpi` |
| NVMe | Micron 2550 (`1344:5416`) | nvme | `nvme` |
| Ethernet ×2 | RTL8126 5 GbE (`10ec:8126`) on PCIe | r8169 | **`rge(4)`, which knows the 8126** |
| USB | 10 xHCI hosts (`XHC0`–`XHC5`, `USB0`–`USB3`), which the firmware puts in host mode and describes as standard `PNP0D10`; the Cadence dual-role devices (`CIXH2030`/`2031`, PHYs `CIXH2033`) behind them | cdnsp-sky1, xhci-hcd | **works**: `xhci` ×10 on ACPI |
| USB-C / PD | RTS5453H PD controllers on I²C (`CIXH200D`); DP alt mode through `CIXH2033` | rts5453h | later |
| UART | 4 SBSA UARTs `ARMH0011` (`0x40b0000`…`0x40d0000`); DBG2 names COM2 at `0x40d0000`; **no SPCR** | sbsa-uart | `uart_pl011` attaches; no automatic serial console |
| GPIO, I²C, pins | Cadence GPIO (`CIXH1002`/`1003`), Cadence I²C ×7 (`CIXH200B`), pinctrl (`CIXHA016`/`017`) | cdns-* | `cdnc_i2c` (devicetree only: needs an ACPI attachment); GPIO and pinctrl to write |
| Clocks, resets, power | SCMI over a mailbox (`CIXHA006`, `CIXHA001` ×6, PCCT type 2 at `0x83bf1280`), clock controller `CIXHA010`, resets `CIXHA020`/`021`, PDC `CIXHA019` | scmi, clk-sky1-acpi | none; most of it is reached through AML |
| Display | Linlon DP ×5 (`CIXH5010`) + Trilinear DP TX (`CIXH502F`), eDP panel; monitor on DP-4; UEFI GOP framebuffer handed over | linlondp, simpledrm | **`efifb` + our `sysfbdrm`** now; Linlon KMS later |
| GPU | Immortalis-G720 MC10 (`CIXH5000`), devfreq | panthor | none (FreeBSD's panfrost is for older Malis) |
| Audio | HDA controller `CIXH6020` at `0x70c0000` with a Realtek **ALC269VC** codec; I2S ×4, an audio DSP `CIXH6000` | cix-ipbloq-hda | **`hdac`/`snd_hda` with an ACPI attachment** |
| Video codec | `CIXH3010` (Arm Mali-V?, "amvx") | amvx_dev | later |
| NPU | Zhouyi (`CIXH4000`, `CIXH4010` ×3), 30 TOPS | (vendor) | later |
| Other | TPM (`MSFT0101`), OP-TEE (`CIXHA022`), DMA-350 (`CIXH1006`, `CIXHA014`), PWM, battery/AC objects | — | — |

Firmware bugs seen: the DSDT names `I2C0.UXC0`–`UXC3` (USB-C controllers)
that don't exist (`AE_NOT_FOUND` at load, harmless on Linux).

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

### Phase 3: power, the generic parts first

- **CPU idle:** our `_LPI` support from the Q8B should take the three
  states as they are (check the cluster state's coordination).
- **CPU frequency: an ACPI CPPC driver** (`acpi_cppc`, a cpufreq(4) driver):
  `_CPC` with SystemMemory and FFixedHW (AMU) registers, per-domain as our
  Q8B powerd already handles. Generic FreeBSD code: it fixes every
  CPPC-only arm64 server and SBC, and goes upstream.
- **Thermal:** `acpi_thermal`'s 13 zones, and critical shutdown tested as on
  the Q8B.
- **Device power:** ACPI power resources and the AML clock methods, as
  devices need them.

### Phase 4: display and desktop, early

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
