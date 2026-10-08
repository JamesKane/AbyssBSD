# Firmware, ACPI and booting

## Firmware

- Qualcomm UEFI `BOOT.MXF.1.1` (2026-08-18). It provides **both** a DTB and
  ACPI; FreeBSD uses ACPI. The HDMI boot menu works.
- "Synchronous Debug UART in UEFI" is off by default.
- It boots `EFI/BOOT/BOOTAA64.EFI` from a USB stick's ESP, and can also boot
  from SD. The FreeBSD kernel can't see the SD card (there's no ACPI SDHC
  driver), so the root can't live there.
- There's **no RTC** under FreeBSD (efirtc fails with error 78). Use `ntpd`
  with `ntpd_sync_on_start`. OpenBSD's `qcscm` gets an RTC offset through
  `uefisecapp`; that's a possible fix later.
- The EL1 kernel runs under Qualcomm's hypervisor, which owns stage 2 and
  polices SMMU programming. See [lessons.md](lessons.md).

## ACPI facts

- RSDP at `0xffffd000`. FADT is hardware-reduced. GIC with an ITS.
- **SPCR/DBG2:** type 0x13 at `0x884000`. The access width is invalid, which
  `uart_cpu_acpi.c` now tolerates. The SPCR IRQ is wrong; the DSDT's `UARD`
  (`QCOM0616`, `_UID` 18) has GSIV 615.
- **MCFG:** 7 segments. Only PCI2 (the NVMe) and PCI4 (TC9563 switch + 2×
  TC956x) are enabled.
- **IORT:**
  - PCIe goes through a firmware-reserved SMMUv3 at `0x14f80000`.
  - Two SMMUv2 nodes (model 3 = MMU-500): apps at `0x15000000` and GPU at
    `0x3DA0000`.
  - Named components include `\_SB.GPU0`, `URS0`/`URS1`, `UFS0`, `SDC2`,
    `ADSP`, `IPA` and others.
- **PEP0** (`_HID QCOM0617`, `_CID PNP0D80`) is Windows' power engine. Every
  device `_DEP`s on it, and clocks, regulators and temperatures go through
  it. We key SoC-specific tables on the presence of `QCOM0617`.
- **No** `_CPC`, `_PSS` or `_TMP`. The 32 thermal zones (`QCOM04C0` etc.)
  have `_PSV`/`_CRT` but read temperature through PEP, so `acpi_thermal`
  ignores zones without `_TMP`. That replaced the old
  `debug.acpi.disabled="thermal"`.
- **`_LPI`:** per-CPU, cluster and system states. See
  [power-thermal-idle.md](power-thermal-idle.md).
- **GTDT:** the per-core timers are **not** always-on. The MMIO timer block
  (CNTCTLBase `0x17C20000`, frame 0 at `0x17C21000`, GSIV 40) is.
- Harmless boot noise:
  - 48× "buggy BIOS ACPI_TYPE_INTEGER" (acpi_spmc `_DSM`);
  - `_SB._OSC AE_AML_BUFFER_LIMIT`;
  - an ADC1 resource error.
- **Dumping ACPI from Linux:** `/dev/mem` is blocked, but `/proc/kcore`
  isn't. Read the tables from RSDP `0xffffd000` via kcore, then `iasl -d`.

The dumps are in [dumps/](dumps/README.md).

## Boot layouts

**1. Everything on the USB stick.** This is what `mkimage.sh` builds (see
[BUILDING.md](../../BUILDING.md) §6):
- GPT with a 64 MB FAT16 ESP and a UFS root labelled `rootfs`;
- growfs on first boot;
- the stick writes at about 3.4 MB/s, so keep big files off it.

**2. Stick ESP, NVMe root.** This is the development board's setup since
2026-09-28:
- `loader.efi` always prefers a root on its own boot disk. The stick's
  `/boot/lua/local.lua` scans `disk0-7p1-8` for the marker file
  `/boot/NVROOT`, sets `currdev` and
  `vfs.root.mountfrom=ufs:/dev/gpt/nvroot`, then calls `config.reload()`.
  It has to `require("config")`: `config` isn't a global.
- NVMe layout: `nda0p4 gpt/nvroot` (UFS SU+J, TRIM) and
  `nda0p5 gpt/nvswap` (the dump device). The Ubuntu partitions p1–p3 are
  untouched.
- To boot the stick's own root, set `q8b_nvroot="NO"` in the stick's
  `loader.conf`, or at the `OK` prompt:
  `set currdev=diskNp2: ; set vfs.root.mountfrom=ufs:/dev/gpt/rootfs ; unload ; boot`.

## Console

- SPCR makes the loader choose a **serial-only** console, because it doesn't
  recognise the ConOut video path. Boot messages don't appear on HDMI, but
  getty on `ttyv0` still gives an HDMI login. Leave it that way.
- With `boot_serial` set, rc, fsck and single-user output go to serial only.
  To recover at the loader prompt:
  `unset boot_serial; unset boot_multicons; boot -s`.
- **The serial console's pinmux is correct.** TLMM (`QCOM060C`, `0x0F100000`)
  gpio63/64 are FUNC_SEL=1 (qup17), and sampling the TX pad showed the UART
  driving it.
- The 40-pin header has pin 6 GND, pin 8 = gpio63 (UART17 TX) and pin 10 =
  gpio64 (UART17 RX). Pins 2 and 4 are 5 V.
- The 3-pin header near USB-C is **12–20 V power in**. Never connect serial
  to it.
- A 3.3 V FT232R cable reads garbage. The pads are almost certainly 1.8 V,
  so use a 1.8 V-capable adapter or a level shifter.

## Linux as ground truth

Radxa's Ubuntu image (kernel 7.0.11-qcom) on the NVMe's p1–p3 runs Linux's
msm, stmmac and dwc3. It's the baseline for register diffs and benchmarks:
- the DWC3 threshold bug was found by diffing its debugfs regdump against
  UEFI's values;
- the GPU/SMMU register state was dumped with `/dev/mem` there (no
  STRICT_DEVMEM).

Its reference sources:
- Radxa kernel `github.com/radxa/kernel`, branch `linux-7.0.11`;
- the firmware DT (`live.dts`) from `/proc/device-tree`.

**Booting Ubuntu once from FreeBSD** (no keyboard needed). The UEFI boot
variables live in TrustZone (Linux reaches them through `qcom_uefisecapp`),
so `efibootmgr -n` gets "Function not implemented". Instead FreeBSD's
loader chain-loads Ubuntu's systemd-boot (`EFI/BOOT/BOOTAA64.EFI` on the
NVMe's ESP, loader device `disk2p2`), once:
- `/boot/loader.conf.local` on the NVMe root runs
  `exec="include /boot/chain-once.lua"`;
- `/boot/chain-once` is `once="YES"` and then the loader command;
- `chain-once.lua` overwrites the first line with `once="NO" ` in place (as
  nextboot does) and only then runs the command, so whatever happens the
  next boot is FreeBSD's. `once="TEST"` checks the in-place write without
  chaining; the result is in `kenv chain_once`.

To arm it:
`printf 'once="YES"\nchain disk2p2:/EFI/BOOT/BOOTAA64.EFI\n' > /boot/chain-once`,
then reboot. From Ubuntu, `sudo reboot` comes back to FreeBSD.

What doesn't work:
- `/boot/lua/local.lua` on the NVMe root: the loader runs Lua from the
  stick's root (whose own `local.lua` finds the NVMe root, above).
- `exec=` in `nextboot.conf`: the loader runs it before it marks the file
  used, so every later boot would chain too. (`rc` deletes the file with
  `nextboot -D`, which hides whether the loader's rewrite worked.)

FreeBSD's `ext2fs` refuses an ext4 that `needs_recovery` (after a crash);
e2fsprogs' `debugfs` reads it, but not files whose directory entries are
still only in the journal. Booting Ubuntu replays it.
