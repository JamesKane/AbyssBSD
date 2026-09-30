# Radxa Dragon Q8B

Qualcomm SC8280XP (Snapdragon 8cx Gen 3): 4× Cortex-A78C (up to 2.44 GHz) and
4× Cortex-X1C (up to 3.0 GHz), an Adreno 690 GPU, and two 2.5 GbE ports on a
Toshiba TC956x behind a TC9563 PCIe switch. Work started 2026-09-25. This
directory records what we found, so nobody has to find it again.

| Document | Covers |
|---|---|
| [firmware-acpi-boot.md](firmware-acpi-boot.md) | UEFI, ACPI tables, boot media, root on NVMe, console, recovery |
| [ethernet-tc956x.md](ethernet-tc956x.md) | the `tcx(4)` driver and the chip |
| [usb.md](usb.md) | xHCI on ACPI, USB-C role-switch devices, the DWC3 throughput fix |
| [power-thermal-idle.md](power-thermal-idle.md) | EPSS cpufreq, TSENS, per-domain powerd, GPU devfreq, `_LPI` deep idle |
| [gpu-display.md](gpu-display.md) | msmfb (display KMS), sysfbdrm, the Adreno 690 via msm, SMMU, SCM, Mesa, performance |
| [lessons.md](lessons.md) | **read first**: things that reset the SoC, debugging method, gotchas |

## Decisions

- **ACPI, not DT** (2026-09-27). The firmware provides both. FreeBSD's
  Snapdragon laptop work is ACPI, and a stock GENERIC kernel boots fully
  under ACPI. The DT work is parked on branch `radxa-dragon-q8b-dt` until
  Radxa's DTS is upstream.
- **"Nothing special."** The image is the normal FreeBSD process: stock
  GENERIC, an empty `loader.conf`. Anything board-specific in configuration
  is a bug to fix in a driver.
- **Licensing.** Linux drivers are reference only; new FreeBSD code is a BSD
  rewrite. The only GPL code is what is adapted from Linux (msm), kept out of
  `src/` in `kmod/drm-msm`, as FreeBSD already does for drm-kmod.
- **GPU power and clocks are libraries** (`qcom_gpucc`, `qcom_scm`,
  `qcom_cmd_db`, `qcom_smmu`) that the GPU driver calls. They aren't drivers
  attached to the ACPI GPU device, because ACPI routes clocks and power
  through PEP, which is Windows-only.

## Status (2026-09-30)

| Area | State | Where |
|---|---|---|
| Boot, ACPI, SMP, NVMe (`nda0`), GIC ITS | Works, stock GENERIC | — |
| Serial console | Driver works; header pins unread (1.8 V pads) | `uart_dev_qcom_geni.c` |
| Ethernet ×2, 2.5G/1G/100M/10M | Works: ~2.2 Gbit/s each way, TSO, checksum offload, jumbo, hardware multicast filter | `sys/dev/tcx` |
| USB-A (multiport) | Works | `generic_xhci_acpi.c` |
| USB-C ×2 (host) | Works at 112 MB/s; SuperSpeed only in one plug orientation | `generic_xhci_acpi.c` |
| Thermal sensors (46) | Works; critical-temperature shutdown untested | `sys/dev/qcom_tsens` |
| CPU frequency, 2 domains | Works; per-domain powerd | `sys/dev/qcom_epss`, `usr.sbin/powerd` |
| Deep idle (PSCI power-down, C3) | Works, enabled by 2 sysctls | `acpi_cpu.c`, `cpu_suspend.c`, `generic_timer_mem.c` |
| Display KMS (DPU/DP) | Works (`msmfb`): page flips on vsync, EDID, hotplug with link training, the monitor's modes (1080p to 640×480); sway on HDMI | `kmod/drm-msm/freebsd/msm_freebsd_fb.c` |
| Firmware framebuffer KMS | Works (`sysfbdrm`); the fallback when msm isn't loaded | `kmod/drm/sysfbdrm` |
| GPU: GL ES 3.2, Vulkan 1.3 | Works: freedreno/Turnip, per-process page tables, fault isolation, hang recovery, frequency scaling with load | `kmod/drm-msm`, `sys/dev/qcom_*` |
| SD card | No ACPI SDHC driver | — |
| RTC | None (no driver; ntpd sets the clock) | — |
| I²C (EEPROM MACs, TC9563 setup) | No ACPI GENI I²C driver; not needed yet | — |
| USB-C orientation, PD | Needs pmic_glink | — |
| Audio, Wi-Fi/BT, camera, NPU | Not investigated | — |
| The AbyssBSD desktop on this board | Not tried | — |

## Kernel changes (freebsd-src branch `radxa-dragon-q8b`)

- New drivers:
  - `sys/dev/uart/uart_dev_qcom_geni.c` (+ `sys/dev/qcom_geni/qcom_geni_reg.h`)
  - `sys/dev/tcx/` (+ `tcx.4`)
  - `sys/dev/qcom_tsens/`
  - `sys/dev/qcom_epss/`
  - `sys/dev/qcom_scm/`
  - `sys/dev/qcom_cmd_db/`
  - `sys/dev/qcom_gpucc/`
  - `sys/dev/qcom_smmu/`
  - `sys/arm/arm/generic_timer_mem.c`
- arm64 and ACPI:
  - `cpu_suspend.c` and `locore.S` (PSCI suspend/resume)
  - `acpi_cpu.c` (`_LPI`)
  - `acpi_iort.c` (named-component SMMU lookup)
  - `acpi_thermal.c` (ignores zones without `_TMP`)
  - `uart_cpu_acpi.c` (invalid SPCR access width)
  - `generic_xhci_acpi.c` (PNP0CA1, DWC3 threshold)
  - `kern_cpu.c` / `sys/cpu.h` (`CPUFREQ_FLAG_DOMAIN`)
  - `usr.sbin/powerd` (per-domain)
- LinuxKPI:
  - platform bus, component framework, runtime PM, platform IRQs with
    Linux's IRQF values, devres groups;
  - `struct device` `of_node`/`platform_data`, absolute hrtimers, correct
    `SZ_2G`+;
  - arm64 write-combining, `vmap` prot, `memcpy_toio`, per-entry
    `dma_map_sg`.

  All were validated on amd64 with amdgpu.

The upstream series (15 commits, branch `q8b-upstream`) covers everything
except the GPU work: see [../../UPSTREAMING.md](../../UPSTREAMING.md).
