# CPU frequency, thermal and deep idle

ACPI gives none of this (no `_CPC`, `_PSS` or `_TMP`), so all three are
native drivers with SoC tables, keyed on PEP0's `_HID QCOM0617`. The
addresses come from the firmware DT and were verified by reading registers
on the board.

## CPU frequency: EPSS (`sys/dev/qcom_epss`)

Two domains:

| Domain | Base | CPUs | Levels |
|---|---|---|---|
| 0 | `0x18591000` | 0–3 (A78C) | 21 steps, 300–2438.4 MHz, 572–952 mV |
| 1 | `0x18592000` | 4–7 (X1C) | 21 steps, 825.6–2995.2 MHz, 568–1084 mV |

- Registers:
  - enable `0x0`;
  - `domain_state` `0x20` (bits 7:0 = current lval, which drops by itself
    when idle or throttled);
  - `dcvs_ctrl` `0xb0` (bit 0 = per-core);
  - frequency LUT `0x100+4i`, voltage LUT `0x200+4i`;
  - `perf_state` `0x320` (+4·core when per-core); write a LUT index.
- LUT entries:
  - source bits 31:30: 0 = 300 MHz (GPLL0/2), otherwise lval × 19.2 MHz;
  - `core_count` 18:16;
  - the table ends with a repeated entry.
- The firmware leaves every core at the top index. Without this driver the
  CPUs run at 2.44/3.0 GHz all the time.
- The driver attaches one instance per domain under the domain's first
  core: `dev.cpu.0.freq` and `dev.cpu.4.freq`.
- **Gotcha that panicked the board:** `cpu_get_pcpu(dev)` reads the ivar
  from dev's *parent*. For the cpu device itself, match `pcpu->pc_device`
  instead.
- `CPUFREQ_FLAG_DOMAIN` (`sys/cpu.h`): `kern_cpu.c` used to set *every*
  cpufreq device when one was set, so setting cpu0 moved cpu4. Flagged
  drivers are now independent.
- **powerd per domain** (`usr.sbin/powerd`):
  - the domain heads are the CPUs that have `dev.cpu.N.freq`, and load is
    summed per domain;
  - behaviour with one domain is unchanged;
  - at idle the domains sit at 300/825 MHz, and busy big cores move only
    cpu4's domain.

## Thermal: TSENS v2 (`sys/dev/qcom_tsens`)

Four controllers:

| TM base | SROT base | Sensors |
|---|---|---|
| `0xc263000` | `0xc222000` | 14 |
| `0xc265000` | `0xc223000` | 16 |
| `0xc251000` | `0xc224000` | 11 |
| `0xc252000` | `0xc225000` | 5 |

- SROT ctrl `0x4`: EN, SENSOR_EN (18:3), temperature mode (21). The
  firmware sets all of them.
- `Sn_STATUS` `0xa0+4n`: bits 11:0 are signed deci-°C, bit 21 is VALID.
  Thresholds are unprogrammed and interrupts are off.
- Zone names from the DT (controller.channel):
  - CPU: cpu0-0 = 0.1 … cpu7-0 = 0.8, cluster0 = 0.9, cpu0-1..cpu6-1 = 1.1–1.7,
    cluster1 = 1.9;
  - GPU: gpuss-0..2 = 2.1–2.3, gpuss-4/6/7 = 3.1/3.3/3.4;
  - memory: mem-0 = 1.15, mem-1 = 2.6;
  - other: pcie-0 = 1.14, aoss = 1.0/3.0, audio 2.7, video 2.8, nsp, smss,
    camss.
- DT trip points: CPU/SoC 110 °C, GPU 85 °C, memory 90 °C. The driver's
  critical poweroff is `hw.qcom_tsens.crit_temp` (default 110). It's
  **untested**: testing it powers the board off.
- Measured:
  - idle 29–35 °C;
  - four big cores at 3 GHz go from 31 to 80 °C in 30 s;
  - with all 8 cores loaded, the hottest sensor levels off near 95 °C and
    the hardware (LMh) clips the big cores to 2.80–2.90 GHz on its own, so
    the silicon protects itself.

## Deep idle: ACPI `_LPI` on arm64

Before this work, FreeBSD/arm64 only ever executed WFI.

**Firmware states:**
- Per-CPU `_LPI`:
  - C1 WFI;
  - C2 retention `0x2` (disabled);
  - C3 `0x40000003` and C4 `0x40000004`: power-down with core context lost,
    minimum residency about 4 ms.
- Cluster D4 `0x40` and system DRIPS `0xC300` compose with them into
  C4 = `0x40000044` and C5 = `0x4000C344`.

**Implementation:**
- `acpi_cpu.c` parses `_LPI` (and composes parent states).
- An arm64 `cpu_idle_hook` enters PSCI `CPU_SUSPEND` through
  `cpu_suspend.c` and `locore.S`. The save/resume path restores:
  - TCR, MAIR, TTBRs, SCTLR, VBAR, `tpidr`, `sp_el0`, the APIA key;
  - CPACR, CNTKCTL, debug registers, ICC registers, PAN.

  It refuses VHE/SVE, and refuses power-down on EL2-booted kernels.
- **The per-core timers stop in power-down** (GTDT: not always-on).
  `generic_timer` now sets `ET_FLAGS_C3STOP`, and the new
  `generic_timer_mem.c` provides the always-on MMIO timer as a global
  one-shot event timer.
- **Lost wakeups:** the MMIO timer's SPI doesn't wake a powered-down core.
  The fix has two parts: bind its IRQ to CPU 0 (in `generic_timer_mem.c`),
  and never give CPU 0 a C3-type state (in `acpi_cpu.c`).
  An experiment suggests the binding alone may be enough: with it, CPU 0
  was allowed to power down and there were 0 stalls in 280 logins. The
  shipped code still keeps CPU 0 awake.

**Enabling it** (both sysctls; it's off by default):

```
kern.eventtimer.timer="ARM MMIO Timer"
hw.acpi.cpu.cx_lowest=C3
```

**Results:**
- Idle cores spend 85–99% of their time in C3.
- Ping latency goes from 0.55 to 2.4 ms. Network throughput is unchanged.
- The composite states C4/C5 work but gave no measurable benefit (there's
  no power meter, so we used thermal A/B runs: WFI 19.04 °C, C3 18.58,
  C5 18.80). The default stays C3.

**Gotchas:**
- x18 is the kernel's pcpu pointer. The resume path must restore it
  (`mov x18, tpidr`) before any C code runs.
- On the ACPI bus, `bus_set_resource(SYS_RES_IRQ)` takes the **raw GSIV**.
  Mapping it yourself first double-maps it to the wrong SPI.
- `cpuset -x` takes INTRNG's `ie_irq`, not dmesg's "irq N", so rebinding
  interrupts from the shell is awkward.

**Ideas raised for later:** energy-aware scheduling (ULE has none), and a
machine-independent "stay awake" CPU mask in `kern_clocksource` to replace
the CPU 0 rule.
