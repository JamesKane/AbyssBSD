# Q8B dumps

Raw ground truth from the board, taken 2026-09-27 to 2026-09-29. The
documents one level up cite these files.

Disk and USB-stick serial numbers and the root filesystem UUID have been
redacted: the UUID is zeroed in place, including in `live.dtb`.

| Path | What | How it was taken |
|---|---|---|
| `acpi/*.dat`, `acpi/*.dsl` | Every ACPI table (DSDT, IORT, GTDT, MCFG, SPCR, DBG2, PPTT, CSRT, …), raw and disassembled | Under Ubuntu: read from RSDP `0xffffd000` via `/proc/kcore` (`/dev/mem` is blocked), then `iasl -d` |
| `dt/live.dts`, `dt/live.dtb` | The DT the firmware hands Linux | `/proc/device-tree` under Ubuntu, decompiled with `dtc` |
| `linux/` | Radxa Ubuntu (kernel 7.0.11-qcom): dmesg, `/proc/interrupts`, `/proc/iomem`, `clk_summary`, lspci, lsusb, modules, cpuinfo, EFI info | A collection script run as root |
| `freebsd/q8b-dmesg.txt` | FreeBSD's first verbose ACPI boot on the board | Saved to the ESP from the HDMI console |
| `freebsd/tc956x-p0.txt` | TC956x state as UEFI leaves it (clocks, resets, TAMAP, EMACCTL, XGMAC, MDIO) | Read-only probe driver |
| `freebsd/qcpeek-out.txt` | EPSS LUTs and TSENS registers | Physical-memory peek module |
| `freebsd/rsc-dump.txt` | RPMh RSC / BCM votes (the USB-C bandwidth investigation) | Peek module |
| `freebsd/gfxpeek-out.txt` | MDSS/DPU scan-out path as UEFI leaves it; GPU CC/GDSC state | Peek module |
| `freebsd/gpupwr-out.txt`, `gputest-out.txt` | GPU CX power-up steps and results | Test driver on ACPI `QCOM0636` |
| `freebsd/smmu-out.txt` | GPU SMMU ID registers, SMR/S2CR/context-bank state, programming steps | Test driver; each access logged and synced |
| `freebsd/scm-out.txt` | SCM calls available, and PAS support answers | `qcom_scm` test module |
| `freebsd/cmddb-out.txt` | RPMh Command DB entries | `qcom_cmd_db` test |
