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

## Plug orientation (src `9ded7b873f`)

SuperSpeed works with the plug either way round, on both USB-C ports,
hot-plugged or present at boot: 116 MB/s reading a USB 3 drive.

- **What was wrong.** UEFI puts each USB-C PHY's lanes under software
  control (`DP_COM_TYPEC_CTRL` = `SW_PORTSELECT_MUX`, 0x02) and selects
  them once at boot, for whatever is plugged in then. A plug turned over
  later came up at USB 2 only. The PHYs are QMP USB43DP combo PHYs: port 0
  at `0x88eb000`, port 1 at `0x8903000` (the common block at +0, the USB3
  PCS at +0x1400).
- **Where orientation comes from.** The ADSP runs the Type-C and PD state
  machines and reports each port over GLINK, channel `PMIC_RTR_ADSP_APPS`
  (Linux's pmic_glink). `qcom_pmic_glink` sends `USBC_CMD_WRITE_REQ`
  (0x15) with `ALTMODE_PAN_EN` (owner `USBC_PAN`, 32780). After the
  acknowledgement, each change arrives as `USBC_NOTIFY_IND` (0x16, with
  the SVID in the opcode's top half): the port, the orientation (0 normal,
  1 reversed, 2 nothing in it) and the mux state (1 = USB3 only). The
  message is **32 bytes**: Linux's struct ends with a reserved word.
- **The fix.** On a notification, set `SW_PORTSELECT_VAL` for reversed
  (0x03) or clear it (0x02), and pulse the USB3 PCS `SW_RESET`. Linux
  reinitializes the whole PHY on an orientation change; the lane tables
  are the same for both lane pairs, so restarting the PCS is enough. The
  DSP's port numbers match the PHYs above.
- **State:** `sysctl hw.qcom_pmic_glink.port0` (and `port1`), for example
  `reversed, usb3`; with `debug.bootverbose=1` each notification and lane
  switch is logged.
- **Gotcha:** built into the kernel, the driver loads before ACPI is up,
  so `\_SB.SOID` can't be read at load; it is looked up when the channel
  opens.

## Open

- Device/OTG mode and power delivery aren't supported. DisplayPort
  alternate mode over USB-C would use the same notifications (mux states
  2 and 3, HPD in the extended data); not done.
