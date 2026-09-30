# Ethernet: Toshiba TC956x, `tcx(4)`

Two 2.5 GbE ports. PCIe segment 4 holds a TC9563 switch (`1179:0623`, which
UEFI powers and configures), and behind its port 3 are two TC956x functions
(`1179:0220`, subsystem `1179:0001`) at `pci4:3:0:0` and `pci4:3:0:1`. Each
function is one Synopsys XGMAC2 (3.01a, SNPSVER 0x30, user ID 0x76) with an
XPCS, a PMA, and a Qualcomm QCA8081 PHY at MDIO `0x1c`.

The driver is `sys/dev/tcx/{if_tcx.c,if_tcxreg.h}` (an iflib driver) with the
man page `share/man/man4/man4.aarch64/tcx.4`. It's `device tcx` in arm64
`std.dev`.

## Results

- 2.5G, 1G, 100M and 10M all pass traffic (SGMII in-band autonegotiation
  below 2.5G).
- About 2.2 Gbit/s each way with 0 FIFO overflow. TX uses about 5% CPU with
  TSO; RX about 12%, or 6% at MTU 9000.
- Offloads:
  - IPv4/TCP/UDP checksums, both directions;
  - TSO;
  - jumbo frames up to 9000;
  - a hardware multicast hash;
  - interrupt moderation. RX went from 382k to 30.6k interrupts per test
    and TX from 460k to 27.3k, at the same throughput.
- Deferred:
  - miibus plus a qcaphy driver (needs 2.5G media and C45 in miibus);
  - multi-queue: there's **no RSS** (HW_FEATURE1 `0x01857a69`, RSSEN = 0),
    so only TX would gain;
  - reading the MAC addresses from the EEPROM (needs ACPI I²C);
  - suspend/resume.

## Chip facts

There's no public datasheet. The sources are GPL and were used as reference
only:
- Radxa's kernel (`drivers/misc/tc956x_pci.c`, `stmmac/dwmac-tc956x.c`,
  `pcs-xpcs-regmap.c`);
- RISCstar's upstream series (lore `20260605010022.968612-1-elder@riscstar.com`,
  being redone at `github.com/riscstar/linux` `tc956x/stmmac-next`);
- Toshiba's `github.com/TC956X/TC9564_Host_Driver`, which has full register
  names.

- **BARs per function:**
  - BAR0 16K: bridge config, with the TAMAP at +0x800 (fn0 programs it);
  - BAR2: M3 SRAM (unused);
  - BAR4 2M: SFR. Clock, reset and GPIO registers go through **fn0's**
    BAR4. Each MAC goes through its own function's BAR4.
- **SFR map:**
  - NCID `0x0`;
  - NCLKCTRL0 `0x1004`, NRSTCTRL0 `0x1008` (chip + MAC0);
  - NCLKCTRL1 `0x100C`, NRSTCTRL1 `0x1010` (MAC1);
  - NEMAC0CTL `0x1070`, NEMAC1CTL `0x1074`;
  - GPIO `0x1200-0x1214`;
  - MSIGEN `0xF000` (fn0) / `0xF100` (fn1);
  - XGMAC `0x40000` / `0x48000`;
  - XPCS = XGMAC+`0x3A00` (a 1K indirect window, viewport at `0xFF*4`);
  - PMA = XGMAC+`0x4000`.
- **DMA address offset:** TAMAP entry 0 is SRC_LO `0x47`, SRC_HI `0x10`,
  TRSL 0. The MAC sees host address *x* at `0x10_0000_0000 + x`, so **add
  `0x1000000000` to every DMA address** (descriptors, buffers, tails). The
  host DMA limit is 36 bits. Use a queue alignment of 16K so buffers don't
  cross 4 GB.
- **Interrupts:** one MSI per function, although it advertises 32, and
  iflib's MSI fallback only takes MSI when exactly 1 is offered. So
  `IFLIB_SKIP_MSIX` and our own `pci_alloc_msi(1)`.
  - MSIGEN: OUT_EN `0x0`, MASK_SET `0x8`, MASK_CLR `0xC` (per-vector),
    INT_STS `0x10`.
  - Sources: 0 LPI, 1 PMT, 2 MAC, 3–10 TX channels, 11–18 RX channels,
    19 XPCS, 20 PHY.
  - DMA_MODE INTM=1.
- **EMACxCTL SP_SEL[3:0]:** 4 = 2500BASE-X, 5 = SGMII 1G, 6 = 100M, 7 = 10M.
  It resets to 8 (invalid), so **set SP_SEL before the first PMA init**, or
  1G never links. Also PHY_INF_SEL=1 and LPIHWCLKEN (bit 8).
- **PMA init**, re-run on every speed change:
  1. assert the PMA reset;
  2. write 0 to +0x1B8;
  3. for i in 0..4: write 0 to +0x1080+i·0x14 and to +0x1090+i·0x14, and
     `0x1EF04` to +0x1888+i·8;
  4. deassert the reset;
  5. poll EMACxCTL bit 21 (INIT_DONE, up to 1 s).
- **XPCS:**
  - soft reset, then PCS_TYPE_SEL=4 (MMD3 reg 7) when STAT2 shows 10GBR;
  - SGMII: AN_CTRL mode 2 + MAC_AUTO_SW, AN on;
  - 2500BASE-X: 2G5_EN, AN off, SPEED1000.
- **MAC:** the 3.01a erratum needs RxDESC_RING_LEN OWRQ[25:24]=3. PBL 32×8,
  store-and-forward, SYSBUS `0x1f1f087f`. RX FIFO 32K on one queue; with 8K,
  RX was capped at 240 Mbit/s by overflow.
- **Flow control made RX line rate:**
  - MTL EHFC with RFA=14 and RFD=22;
  - TX pause TFE + PT `0xffff`, RX RFE;
  - resolved from ANAR/ANLPAR.
- **Moderation:** the RX watchdog (`DMA_CH_RX_WATCHDOG` `0x313c`) unit is 256
  cycles of the 125 MHz DMA clock, about 2 µs (inferred from interrupt
  rates). Default `rx_riwt` 64. TX sets IOC every `tx_coal_frames` (default
  128). Both are `dev.tcx.N.*` tunables.
- **PHY:**
  - QCA8081, ID `0x004dd101`;
  - reset is TC956x GPIO0 (port 0) / GPIO1 (port 1), active low: 11 ms
    asserted, then wait 70 ms;
  - the speed and link status register is `0x11` (e.g. `0x3e0c` = up,
    full duplex, 2.5G).
- **QCA8081 SerDes quirk:** on a port UEFI didn't bring up, the link comes
  up but no traffic flows until the PHY's SerDes FIFO is reset: MDIO `0x1d`,
  C45 MMD1 `0x9072` bit 11 (RSTN), toggled on each reported link change. This
  was port 0's bug.
- **MAC addresses:**
  - UEFI programs `88:12:4e:00:02:00`/`:01`;
  - the EEPROM is at I²C12 `0x50`, offsets `0x9E`/`0xA4`;
  - a MAC reset clears the address, so the driver reads it **before** the
    reset;
  - with `hw.tcx.cold_init=1` (the default) and no UEFI address, a random
    locally administered one is generated.

## Driver design notes

- One link state machine: `struct tcx_link` + `tcx_link_apply()`.
  `sc->link` is what iflib was last *told*, not the last poll. Comparing
  against the last poll made cold init look dead ("Network is down").
- The admin task polls PHY register `0x11` and reconfigures the SerDes when
  the speed changes. `ifconfig tcxN media 1000baseT` sets the advertisement.
- Any error from `pkt_get` makes iflib reset the interface. So frames with
  error status are passed up without checksum flags and counted, never
  returned as `EBADMSG`.
- For TSO, `isc_tso_maxsize` must include the VLAN header, or an iflib
  `MPASS` panics.
- Test setup for two ports on one board: put `tcx0` in a vnet jail
  (`jail -c name=p0 vnet persist vnet.interface=tcx0`) and address both. It
  disappears on driver reload.
