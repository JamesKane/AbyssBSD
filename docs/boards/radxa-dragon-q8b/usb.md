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

- **Acknowledgements** (src `24723bef3a`): each notification is answered
  with `ALTMODE_PAN_ACK` (0x11, the port as argument) once handled, as
  Linux does, sent from the driver's task queue (not GLINK's receive
  callback, where a send could wait on buffers announced on that thread).

## DisplayPort over USB-C (planned)

Not working yet: no USB-C display has been tried. What is known:

- **Wiring** (Radxa's devicetree, `dumps/dt/live.dts`): USB-C port 0 is
  MDSS0's DP0 (`0xae90000`) through the combo PHY at `0x88eb000`; port 1
  is DP1 (`0xae98000`) through `0x8903000`, the PHYs whose USB lanes
  `qcom_pmic_glink` already switches. DP2 (`0xae9a000`) is the HDMI port,
  through the CH7218A ([gpu-display.md](gpu-display.md)).
- **The ADSP** negotiates the alternate mode itself. Its notification then
  says mux 2 (DP, four lanes) or 3 (USB3 + DP, two lanes), SVID `0xff01`,
  and, in the first byte of the extended data, the pin assignment (bits
  0-5: 1 = A ... 6 = F), HPD (bit 6) and an HPD IRQ (bit 7).
  `hw.qcom_pmic_glink.portN` shows them (`usb3+dp, dp pin D, hpd high`).

Still to do, each needing a USB-C display or adapter to try it with:

1. **The PHY's lanes** for DP: four lanes (pin C/E) or two plus USB3
   (pin D/F), set in the combo PHY's common block as Linux's typec mux
   does.
2. **The PHY's DisplayPort side**: its PLL and transmit setup for each
   link rate (RBR to HBR3), and the AUX PHY. UEFI leaves it unset unless a
   display was there at boot (Linux: the QMP combo PHY's DP tables for
   SC8280XP).
3. **Clocks**: DP0's and DP1's link and pixel clocks in the display clock
   controller, fed by the PHY's PLL. UEFI set up only DP2's.
4. **A second output**: msmfb takes over the pipeline UEFI left for HDMI
   and keeps its PHY, clocks and link; a USB-C display needs its own
   pipe, mixer, control path and interface, the controller brought up
   from reset, the sink's capabilities read and the link trained, and
   hotplug from the notifications above. Or bring up msm's own DP driver,
   which would want the same PHY and clock support and would drive HDMI
   the same way.

## Open

- Device/OTG mode isn't supported. Power delivery is the ADSP's: it powers
  devices on both ports (a bus-powered USB 3 drive runs); there is nothing
  for the host to do unless the board is to take its power over USB-C or
  swap roles.
- DisplayPort alternate mode: above.
