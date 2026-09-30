# USB

Three xHCI controllers, all left in host mode by UEFI with GDSCs and clocks
on:

| Controller | ACPI | Base | Notes |
|---|---|---|---|
| USB-C port 0 | `URS0` `QCOM068B`, `_CID PNP0CA1` | `0xA600000` | DWC3 3.10a, IRQ from child `USB0` (`_ADR 0`), GSIV `0x343` |
| USB-C port 1 | `URS1` `QCOM068C`, `_CID PNP0CA1` | `0xA800000` | same shape |
| Multiport (USB-A) | plain xHCI | `0xA400000` | worked from the start |

## What we changed (`generic_xhci_acpi.c`)

- **Match `PNP0CA1`** (a USB role-switch device) and take the IRQ from its
  `_ADR 0` host child. They attach as `xhci0`/`xhci1`, and the multiport
  controller becomes `xhci2`.
- **The DWC3 RX threshold fix.** USB-C ran at 35 MB/s, against 110 MB/s for
  the same disk on USB-A, whichever port or speed was used. UEFI enables the
  DWC_usb31 RX packet threshold (GRXTHRCFG bit 26 PKTCNTSEL, value
  `0x04f30000`). Clearing it gives 112 MB/s, the same as Linux. The driver
  detects the core from GSNPSID and clears bit 26 on usb31/32 or bit 29 on
  usb3.

We found this by diffing Linux's dwc3 debugfs regdump against UEFI's
registers. The Linux values that differ but *weren't* needed:
- GUSB3PIPECTL `0x030e1002` vs `0x0b081402`;
- GUCTL1 bits 21–22;
- GUSB2PHYCFG SUSPHY/ENBLSLPM;
- GCTL bits 0/2.

Hypotheses ruled out on the way:
- deep idle and cpufreq;
- link errors (PORTLI 0);
- `_CCA` (all 0);
- RPMh interconnect votes (UEFI votes `aggre_usb`);
- master clocks (all 200 MHz).

## Open

- **Plug orientation.** SuperSpeed works in one orientation and falls back
  to USB 2 in the other. UEFI sets the lane mux for one orientation only.
  Fixing it needs Type-C orientation from `pmic_glink`, which is a big job.
- Device/OTG mode and power delivery aren't supported.
