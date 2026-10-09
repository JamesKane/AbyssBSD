# Radxa Dragon Q8B

Qualcomm SC8280XP (Snapdragon 8cx Gen 3): 4× Cortex-A78C (up to 2.44 GHz) and
4× Cortex-X1C (up to 3.0 GHz), an Adreno 690 GPU, and two 2.5 GbE ports on a
Toshiba TC956x behind a TC9563 PCIe switch. Work started 2026-09-25. This
directory records what we found, so nobody has to find it again.

| Document | Covers |
|---|---|
| [firmware-acpi-boot.md](firmware-acpi-boot.md) | UEFI, ACPI tables, boot media, root on NVMe, console, recovery |
| [ethernet-tc956x.md](ethernet-tc956x.md) | the `tcx(4)` driver and the chip |
| [usb.md](usb.md) | xHCI on ACPI, USB-C role-switch devices, the DWC3 throughput fix, plug orientation |
| [power-thermal-idle.md](power-thermal-idle.md) | EPSS cpufreq, TSENS, per-domain powerd, GPU devfreq, `_LPI` deep idle, power profiles |
| [gpu-display.md](gpu-display.md) | msmfb (display KMS), sysfbdrm, the Adreno 690 via msm, SMMU, SCM, Mesa, performance |
| [npu.md](npu.md) | the compute DSP and NPU: FastRPC, QNN under the Linux layer, model conversion, the two ports |
| [vpu.md](vpu.md) | the video codec (Qualcomm Iris, VPU 2.0): Linux's driver through LinuxKPI, clocks, SMMU, DVFS, FFmpeg |
| [lessons.md](lessons.md) | **read first**: things that reset the SoC, debugging method, gotchas |

## Final status (2026-10-02)

Everything we could test on this board works and has been verified on it;
what remains needs hardware we don't have, or is not started.

**Works, verified on the board** (src `24723bef3a` is its default kernel):

- Boots stock GENERIC under ACPI with an empty `loader.conf`; root on NVMe.
- Both 2.5 GbE ports (~2.2 Gbit/s each way), USB-A, both USB-C ports
  (SuperSpeed either way round), SD with hot-swap, the RTC, I²C.
- Power: per-domain cpufreq and powerd, deep idle on by default, 46 thermal
  sensors with critical shutdown, power profiles, the fan (the ADSP's).
- Display and GPU: KMS on HDMI with hotplug and DPMS, GL ES 3.2 and Vulkan
  1.3 on the Adreno 690, the AbyssBSD desktop started at boot.
- Audio: headphone playback and jack detection, reliable from boot (the
  intermittent no-sound boot is fixed: 12 of 12 boots, and every boot
  since).
- NPU: QNN runs on the compute DSP's HTP from FreeBSD, installed from the
  `misc/linux-fastrpc` and `misc/qairt` ports; MobileNetV2 converted and
  quantized on the board, 0.94 ms an image, 79/100 top-1.
- Warm reboots: none hung in about 20 since the GLINK fix (two before it).

**Open**, and why:

| Item | Blocked on |
|---|---|
| DisplayPort over USB-C | A USB-C display or adapter. Notifications are read and acknowledged; the PHY's DP side, DP0/DP1 clocks and a second output remain ([usb.md](usb.md)) |
| Microphone, headset buttons | A headset with a microphone |
| Wi-Fi/Bluetooth | A card for the M.2 E-key slot (`wlan-connector` in Radxa's devicetree: PCIe, USB and UART); the board has none: PCIe root ports 5 and 6 are empty on Linux and FreeBSD |
| Camera | A MIPI camera module; the camera subsystem is `camss@ac5a000` (Windows' ACPI has a camera driver) |
| Serial console | The header's pins are unread (1.8 V); a console would catch any hang that leaves nothing behind |
| Warm-boot hangs | None since the GLINK fix; not proven gone |
| One power-off on pulling the headset (2026-10-01) | Never seen again; unexplained |
| NPU details | QNN's harmless `GraphHtpSettings option 66` log; the DSP's own log (adspmsgd) is silent; quantization costs MobileNetV2 5 points |
| `lang/swift6` for aarch64 | Port changes in the ports fork, not yet committed; the bootstrap is a local distfile |
| Upstreaming | FreeBSD series ([../../UPSTREAMING.md](../../UPSTREAMING.md)); the fastrpc fork to quic/fastrpc; drm/msm and libdrm fixes |

## Decisions

- **ACPI, not DT** (2026-09-27). The firmware provides both. FreeBSD's
  Snapdragon laptop work is ACPI, and a stock GENERIC kernel boots fully
  under ACPI. The DT work is parked on branch `radxa-dragon-q8b-dt` until
  Radxa's DTS is upstream.
- **"Nothing special."** The image is the normal FreeBSD process: stock
  GENERIC, an empty `loader.conf`. (Exception: the video codec's DMA goes
  through iommu(4), so since 2026-10-09 the board's default kernel is
  `GENERIC-IOMMU`, GENERIC with `options IOMMU`, which translates only the
  devices that claim it; see [vpu.md](vpu.md).) Anything board-specific in
  configuration is a bug to fix in a driver.
- **Licensing.** Linux drivers are reference only; new FreeBSD code is a BSD
  rewrite. The only GPL code is what is adapted from Linux (msm), kept out of
  `src/` in `kmod/drm-msm`, as FreeBSD already does for drm-kmod.
- **GPU power and clocks are libraries** (`qcom_gpucc`, `qcom_scm`,
  `qcom_cmd_db`, `qcom_smmu`) that the GPU driver calls. They aren't drivers
  attached to the ACPI GPU device, because ACPI routes clocks and power
  through PEP, which is Windows-only.

## Status (2026-10-02)

| Area | State | Where |
|---|---|---|
| Boot, ACPI, SMP, NVMe (`nda0`), GIC ITS | Works, stock GENERIC | — |
| Serial console | Driver works; header pins unread (1.8 V pads) | `uart_dev_qcom_geni.c` |
| Ethernet ×2, 2.5G/1G/100M/10M | Works: ~2.2 Gbit/s each way, TSO, checksum offload, jumbo, hardware multicast filter | `sys/dev/tcx` |
| USB-A (multiport) | Works | `generic_xhci_acpi.c` |
| USB-C ×2 (host) | Works at 112 MB/s, SuperSpeed with the plug either way round (orientation from the ADSP over pmic_glink, each notification acknowledged) | `generic_xhci_acpi.c`, `sys/dev/qcom_pmic_glink` |
| Thermal sensors (46) | Works; critical-temperature shutdown tested (clean shutdown, PSCI power-off) | `sys/dev/qcom_tsens` |
| CPU frequency, 2 domains | Works; per-domain powerd | `sys/dev/qcom_epss`, `usr.sbin/powerd` |
| Deep idle (PSCI power-down, C3) | Works, on by default (`balanced` power profile; the kernel picks the always-on timer) | `acpi_cpu.c`, `cpu_suspend.c`, `generic_timer_mem.c`, `kern_clocksource.c` |
| Power profiles (power-saver/balanced/performance) | Works: CPU idle, powerd mode, GPU clock; live switch | `libexec/rc/rc.d/power_profile` |
| Display KMS (DPU/DP) | Works (`msmfb`): page flips on vsync, EDID, hotplug with link training, the monitor's modes (1080p to 640×480), DPMS; sway on HDMI | `kmod/drm-msm/freebsd/msm_freebsd_fb.c` |
| Firmware framebuffer KMS | Works (`sysfbdrm`); the fallback when msm isn't loaded | `kmod/drm/sysfbdrm` |
| GPU: GL ES 3.2, Vulkan 1.3 | Works: freedreno/Turnip, per-process page tables, fault isolation, hang recovery, frequency scaling with load | `kmod/drm-msm`, `sys/dev/qcom_*` |
| SD card | Works: 50 MHz, 4-bit, 24 MB/s, ADMA2 DMA; hot-swap by the TLMM card-detect GPIO's interrupt; no UHS | `sys/dev/sdhci/sdhci_acpi.c`, `sys/dev/qcom_tlmm/qcom_tlmm_acpi.c` |
| RTC | Works: ST M41T11 on I²C bus 12, as a DS1307; sets the clock at boot | `sys/dev/iicbus/rtc/ds13rtc.c` |
| I²C | Works: GENI I²C on ACPI (`\_SB.IC13`, the only engine UEFI set up for I²C); RTC and MAC EEPROM (`0x50`) readable | `sys/dev/qcom_geni/qcom_geni_i2c.c` |
| USB-C orientation | Works: `qcom_pmic_glink` switches each PHY's lanes to the plug ([usb.md](usb.md)) | `sys/dev/qcom_pmic_glink` |
| USB-C DisplayPort alt mode | Not done: notifications read and acknowledged; PHY, clocks and a second output to do ([usb.md](usb.md)). Power delivery is the ADSP's: devices on both ports are powered | `sys/dev/qcom_pmic_glink` |
| Video codec | Works ([vpu.md](vpu.md)): Qualcomm Iris through LinuxKPI (`qcom_iris.ko`, loaded at boot on the default `GENERIC-IOMMU` kernel); FFmpeg's `*_v4l2m2m` decode H.264, HEVC, VP9 bit-exactly up to 4K and encode H.264/HEVC (the ports overlay's patched FFmpeg keeps the last frame); DVFS with the rails | `sys/dev/qcom_videocc`, `sys/dev/qcom_smmu/qcom_apps_iommu.c`, vpu-kmod |
| Fan | Works: temperature-controlled by Radxa's ADSP service, which `qcom_adsp` starts | `sys/dev/qcom_adsp` |
| Audio | Headphone playback through `pcm0` and jack detection work, in GENERIC; microphone not yet. A boot-time failure (on 1 boot in 3 or 4 the ADSP stopped answering, so no sound until a reboot; a panic before src `c515bf20f4`) came from `qcom_pmic_glink` opening its channel over and over before the ADSP's service was up; fixed in src `657b6698d0` (open once the ADSP announces it), every boot good since | `sys/dev/qcom_audio`, `sys/dev/qcom_glink` |
| NPU (compute DSP, Hexagon v68) | **QNN runs on the NPU** ([npu.md](npu.md)), installed from the `misc/linux-fastrpc` and `misc/qairt` ports: QAIRT 2.51's Linux build on Rocky 9 under the Linux layer; MobileNetV2 converted and quantized on the board classifies in 0.94 ms an image vs 18.8 ms on QNN's CPU backend (79 vs 84 of 100 ImageNet samples right). Underneath: `qcom_rpmh` and `qcom_adsp` start the CDSP (its boot votes let go once it is up), `qcom_fastrpc` gives Linux's FastRPC interface (`fastrpc_test` passes natively too), `qcom_fastrpc_linux` takes it to Linux programs, `hw.soc` and `linsysfs` show them the SoC | `sys/dev/qcom_fastrpc`, `sys/dev/qcom_rpmh`, `sys/dev/qcom_adsp`, `sys/compat/linsysfs` |
| Wi-Fi/BT, camera | No hardware fitted: the M.2 E-key slot is empty, no camera module (see above) | — |
| The AbyssBSD desktop on this board | **Runs** (2026-10-01): `anchor` + `undertow` on DP-1 1920×1080@60 through msmfb, GLES on the Adreno, pointer tracking; started at boot by `abyss_desktop` (`abyss_desktop_user=jkane`; log `/var/log/abyss-desktop.log`; `abyssctl quit` returns to the console). Builds and tests (680 tests: 1 skipped, 1 installer-probe bug) | `lang/swift6` for aarch64 |

## Clock, I²C, SD and devices

- **RTC:** ACPI's Time and Alarm device (`\_SB.PRTC`, `ACPI000E`) is
  disabled (`_STA` 0) and works through Windows' PEP. UEFI's `GetTime` is
  unsupported (`efirtc` error 78). The real clock is an **ST M41T11 at
  `0x68` on QUP 1 SE 4** (`\_SB.IC13`, `0xa90000`), next to the MAC
  EEPROM at `0x50`. The M41T11 has the DS1307's registers (plus century
  bits, left 0), so `ds13rtc` drives it as a `dallas,ds1307`.
  `qcom_geni_i2c` declares it as iicbus hints for this board, since ACPI
  doesn't describe it. Both drivers are built into GENERIC (`std.qcom`),
  because `inittodr` runs at mountroot, before modules load.
- **I²C engine:** UEFI leaves its clocks on (GCC vote `0x52008`), the I²C
  protocol firmware loaded (`GENI_FW_REVISION_RO` `0x303`), and a 400 kHz
  bus (divider 2, SCL counters `0x00503018`). **I²C FIFO packing is MSB
  first** (`0xff` per byte). The UART's LSB-first `0x0f` bit-reverses every
  byte.
- **MAC EEPROM:** cells at `0x9e` and `0xa4` hold `88:12:4e:00:02:00` and
  `:01`, which `tcx` already reads from the TC956x.
- **SD (`\_SB.SDC2`, `QCOM2466`, `0x8804000`):** an SDHCI 3.00 core in an
  MSM v5 wrapper. ACPI gives the SDHCI block, the host IRQ, and the
  card-detect GPIOs, but not the wrapper's power IRQ. The wrapper posts
  bus-power and I/O-voltage requests in `PWRCTL_STATUS` (`+0x240`) after
  power-control, reset and host-control-2 writes, and stalls until they're
  cleared (`+0x248`) and acknowledged (`+0x24c`). `sdhci_acpi` polls for
  them after those writes. UEFI leaves the clocks (GCC `0x14004`,
  `0x14008`) and the card rails on at 3 V, so there's no regulator
  control, no 1.8 V and no UHS. Card detect is TLMM GPIO 131, active low
  (ACPI `GpioIo` 0x83, PullUp; Linux: `cd-gpios = <&tlmm 131
  GPIO_ACTIVE_LOW>`); `qcom_tlmm_acpi` reads it, and its interrupt (both
  edges) tells sdhci, so the card detaches when pulled and attaches when put
  back: two interrupts per swap (src `e64f72c767`; polled every 200 ms
  before, and still if the interrupt can't be had). One
  reinsertion of three attached the bus but found no card (probably a late
  contact bounce; sdhci debounces 0.5 s and doesn't retry);
  `devctl detach mmc0; devctl attach mmc0` recovers it. The controller's
  capabilities (`0x3629c8b2`) offer ADMA2 but not SDMA, which was the only
  mode FreeBSD's sdhci implemented; forcing SDMA (`hw.sdhci.quirk_set=2`)
  hangs the SoC at boot. sdhci now uses ADMA2 on controllers without SDMA
  (src `afe542b98a`): a `maxphys` bounce buffer below 4 GB and 32-bit
  descriptors, one interrupt per request. UEFI matches SD's apps-SMMU stream
  0x4e0 (SMR 2) to context bank 2 with translation off, so DMA addresses are
  physical. Reading 256 MB takes 256 interrupts (PIO: 524,288) at the same
  24 MB/s, the ceiling of 50 MHz × 4 bits.
- **Audio, as Linux drives it:** one card ("SC8280XP-Radxa-Dragon-Q8B"):
  the headset jack (WCD9380 on SoundWire, playback and mic) and three DP
  outputs; everything through the ADSP (LPASS macros, GPR and AudioReach on
  the DSP). The DSDT's audio devices (`ADSP` → `ADCM` QCOM06C1 → `AUCD`
  QCOM0629) are the reference design's Windows stack and say nothing
  useful. LinuxKPI has no ALSA, so it's native drivers.
- **Headphone playback works** (src `9492cc2943`…`3afeb7670d`, built into
  GENERIC through `std.qcom`): `pcm0` "Qualcomm audio DSP", the default
  device, 48 kHz 16-bit stereo with vchans for other rates; `mixer vol`
  is the DSP's gain (levels are 0–1: `mixer vol=0.5`), `pcm` is software.
  The path: sound(4) ring mapped into the DSP through apps-SMMU stream
  0xc01 (context bank 7) → APM graphs MultiMedia1 → RX_CODEC_DMA_RX_0 →
  RX macro (interpolators 0/1) → RX SoundWire → WCD9385 headphone amps.
  The codec is powered only while playing. Lessons:
  - Every address given to the DSP carries the stream ID's low 4 bits
    above bit 32 (`iova | 1 << 32`), as Linux's q6apm-dai does. Without
    them the DSP's first access to our memory hangs the whole SoC, with no
    SMMU fault.
  - The RX macro's interpolator paths must be on, or the DSP keeps every
    buffer until the graph stops.
  - The codec's registers are reached through the **TX** SoundWire link,
    which runs on the VA macro's SoundWire clock. The codec's reset is
    TLMM GPIO 106, active low; UEFI leaves it held in reset.
  - Blocks must be whole milliseconds (multiples of 192 bytes): sound(4)'s
    1024-byte blocks put a buzz at the block rate on a sine.
  - The codec and SoundWire sequences are Linux's, captured on Ubuntu with
    kprobes on `qcom_swrm_cpu_reg_write` (every SoundWire command goes
    through the FIFO register 0x300) and the `regmap_reg_write` event.
    Don't read the macros' regmaps in debugfs while they're unclocked: the
    bus hangs and the watchdog resets the board.
  - **Jack detection** (src `c81975a93b`): `dev.pcm.0.jack` (1 in use, 0
    empty) and devd events `system=SND subsystem=JACK type=INSERT|REMOVE
    cdev=dsp0`. Between uses the codec idles as Linux's does: both
    SoundWire links clock-stopped (`ClockStopNow`; the WCD938x has the
    simple clock-stop state machine), codec clocks released, the LPASS
    core and digital codec votes held. The codec's mechanical detection
    keeps running and wakes the TX link: wake-up interrupt GIC SPI 520
    (GSI 552), not in ACPI, taken on its edge because the codec holds it
    until the clock runs. While playing, the jack is read every second.
  - `ACPI_BUS_MAP_INTR` takes FreeBSD's `INTR_TRIGGER_*`/`INTR_POLARITY_*`,
    not ACPI's constants: `ACPI_ACTIVE_HIGH` is 0, which reads as
    "conform", and the GIC refuses it (EINVAL at setup).
  - Not yet: microphone, headset-vs-headphone detection and buttons, other
    rates in hardware.
- **GLINK to the ADSP** (src `bf6ce26ded`, in GENERIC since `3afeb7670d`): SMEM at `0x80900000` (2 MB, version 12, not
  in FreeBSD's physical segments), TCSR mutex lock 3 at `0x1f40000`; IPCC
  at `0x408000` (ACPI `IPCC` QCOM06C2 gives only its interrupts, SPI 229
  first); the edge's items in the APPS–ADSP partition (host 2): descriptor
  478, our ring 479, the DSP's 480, 16 KB each. The DSP announces GLINK v1
  (features 0x7) and waits; we agree on 0x1 (intent reuse), and it opens
  `glink_ssr`, `IPCRTR`, `adsp_apps` (GPR), `fastrpcglink-apps-dsp`,
  `LOOPBACK_CTL_LPASS`, `PMIC_RTR_ADSP_APPS`, `PMIC_LOGS_ADSP_APPS`,
  `RADXA_SVC_ADSP_APPS`. A QRTR HELLO on `IPCRTR` gets the DSP's (node 5)
  and eight services, among them 66 (service-registry notifier, which says
  when the audio protection domain is up) and 43 (subsystem control).
  `sysctl dev.qcom_glink.0.lpass` shows the edge and channels.
- **TLMM GPIOs (`\_SB.GIO0`, `QCOM060C`, `0xf100000`):** `qcom_tlmm_acpi`,
  228 pins, keyed on `\_SB.SOID` 449. The DSDT's GPIO consumers are
  Qualcomm's reference design (`PSUB` "QRD08280"): `acpi_gpiobus` would
  apply them all at attach, making outputs of USB-C pins 26/27/47/48/…,
  so the driver ignores configuration until its bus has attached. Pins
  74–79, 83–86, 125–126 and 128–129 belong to the secure world and are not
  offered. **Pin interrupts** (src `e64f72c767`) come through the summary
  interrupt, SPI 208 (`gpio0,N` in `vmstat -i`), for pins in the GPIO
  function only: the firmware leaves every pin's interrupt disabled and
  routed nowhere (`intr_cfg` 0xe2: target 7), and the DSDT's `_AEI` (pin 2,
  `Notify(GPU0, 0x92)`; and 0x2c0, past the pins) is the reference design's
  — pin 2 is in a peripheral function here, so it's refused. No PDC, so no
  wake from sleep. The boot card's GPT backup
  header isn't at the last LBA (an image smaller than the card); left
  alone.
- **`/dev/drm/0`–`255`:** all 256 nodes exist. LinuxKPI's
  `register_chrdev()` creates a whole Linux major's minors up front, on
  every FreeBSD running drm-kmod. Cosmetic; not ours.

## Swift 6.3.3 on aarch64 (for the desktop)

`lang/swift6` was amd64-only because its bootstrap (a prebuilt 6.3.2
toolchain from the port maintainer) exists only for amd64. Since 6.3, the
stdlib uses macros, so the build needs a host Swift (`--bootstrapping
hosttools`). The port's `BOOTSTRAP_MODE` can also self-bootstrap in six
stages (much longer).

What was done (2026-09-30/10-01, ports fork, not yet committed):
- **Seed:** the community's native swift-6.3.2 for FreeBSD/aarch64
  (github.com/networkextension/swift-freebsd, `v0.4.2-6.3.2`, sha256
  checked). It runs on 16-CURRENT with `libuuid` installed. Repackaged as
  `swift6-bootstrap-6.3.2-aarch64-unknown-freebsd.tar.xz`, 540 MB, sha256
  `42ff80b7…`. It's a local distfile for now; hosting it, or making our own
  bootstrap from the 6.3.3 package with `make-bootstrap-archive`, is open.
- **Port changes:**
  - `ONLY_FOR_ARCHS` adds aarch64; compat14x is amd64-only.
  - LLVM and Swift links run two at a time (16 GB of RAM).
  - **`bsd.cpu.mk` adds `-Wl,--fix-cortex-a53-843419` to `LDFLAGS` on
    aarch64. `swiftc` rejects `-Wl,`**, so the first Swift link failed. The
    port respells it `-Xlinker --fix-cortex-a53-843419`, which `clang` and
    `swiftc` both take.
  - The FreeBSD `Mutex` deadlock fix (upstream PR 90143: lock the umutex in
    userspace first, as libthr does) is carried as a patch, rewritten for
    6.3.3.
  - 18 file-list entries are amd64-only: i386 compiler-rt, and the
    stdlib's `.abi.json`, which needs a bootstrap with `swift-driver`.
    The community seed has only the legacy driver.
- **Build:** one run of about 5.5 h on the board (LLVM about 2 h). The
  package `swift6-6.3.3.pkg` is 583 MB.
- **Checks:** `Synchronization.Mutex` with 8 contending threads (4,000,000
  of 4,000,000, no hang); `Foundation.Process` (20 subprocesses); SwiftPM +
  XCTest (200 tests). swift-testing's `@Test` doesn't work: the port ships
  no `libTestingMacros.so`, on amd64 either. The desktop uses only XCTest.
- **The desktop** (`desktop/` at `f80b34b`, wlroots019/020 from pkg, our
  libdrm and Mesa locked): `swift build` 31 s, no errors; `swift test` 680
  tests, 1 skipped, 1 failure. The failure is the installer's disk probe:
  its `zpool list` fails on a UFS-root machine (ZFS not loaded, and the
  test runs as a normal user). See the desktop BACKLOG.
- **Running it** (as `jkane`, from the build tree; anchor finds `AquaDemo`
  beside itself):
  `ABYSS_RUNTIME_DIR=/var/run/abyss-jkane XDG_RUNTIME_DIR=… .build/debug/anchor
  --mode desktop --compositor ".build/debug/undertow run --hz 60 --frames 0
  --backend auto --width 1920 --height 1080 --socket abyss-0
  --privileged-socket abyss-0-bar" --display abyss-0 --menubar-display
  abyss-0-bar`. Root creates the runtime directory, as `rc.d/abyss_desktop`
  does. `undertow` picks GLES2 on the GPU; its buffers come from Mesa's GBM
  on msmfb (card0). A screenshot with `grim` (undertow's screencopy) shows
  the menu bar, the desktop with its disk, the pointer and the Dock.
- **Scan-out memory:** msmfb's buffers must be physically contiguous below
  4 GB. After the 5-hour Swift build, low memory was mostly wired (one free
  8 MB run), every `CREATE_DUMB` failed with ENOMEM, and the screen stayed
  blank. msmfb now reserves a pool when it attaches at boot
  (`hw.msm.fb_pool_mb`, 64 MB, 0 for none; dmesg "64 MB at 0x8f000000 for
  scan-out buffers"), sub-allocates with vmem(9), and otherwise falls back to
  an exact-size allocation with reclaim (drm-msm-kmod `0f23f29`, `1e190da`).
- **At boot:** the desktop's programs are installed as the image installs
  them (`/usr/local/bin`, `/usr/local/share/abyss`, `abyss-session`,
  `rc.d/abyss_desktop`). The service needed three fixes on metal (desktop
  `dc91002`): it ran the session in the foreground and held up the rest of
  the boot; started with `&`, the console's hangup at the end of rc killed it,
  so it uses daemon(8); and it kept rc's HOME and PATH, so there was no bus.
- **Exit:** removing the compositor's last framebuffer turned the output
  off after seatd had dropped master, so the monitor stayed black on exit.
  msmfb now shows the console then (`700b9ba`).
- **Lesson:** the community tarball, untarred over `/`, re-owned `/usr`
  and `/usr/local/lib` and dropped stray cmark-gfm files. Stage
  third-party archives with `--no-same-owner` (see
  [lessons.md](lessons.md)).

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
  - `sys/dev/qcom_adsp/` (+ `qcom_adsp.4`)
  - `sys/dev/qcom_geni/qcom_geni_i2c.c` (+ `qcom_geni_i2c.4`)
  - `sys/dev/qcom_tlmm/qcom_tlmm_acpi.c`
  - `sys/dev/qcom_glink/` (GLINK, SMEM, IPCC, AOSS, socinfo for `hw.soc`)
  - `sys/dev/qcom_audio/` (GPR, APM, PRM, LPASS macros, SoundWire,
    WCD938x, `pcm`)
  - `sys/dev/qcom_pmic_glink/` (USB-C)
  - `sys/dev/qcom_rpmh/`
  - `sys/dev/qcom_fastrpc/` (+ `qcom_fastrpc_linux`)
  - `sys/arm/arm/generic_timer_mem.c`
- arm64 and ACPI:
  - `cpu_suspend.c` and `locore.S` (PSCI suspend/resume)
  - `acpi_cpu.c` (`_LPI`)
  - `acpi_iort.c` (named-component SMMU lookup)
  - `acpi_thermal.c` (ignores zones without `_TMP`)
  - `uart_cpu_acpi.c` (invalid SPCR access width)
  - `generic_xhci_acpi.c` (PNP0CA1, DWC3 threshold)
  - `sdhci_acpi.c` and `sdhci.c` (the MSM wrapper's power requests, ADMA2
    without SDMA)
  - `linsysfs.c` (`/sys/devices/soc0`)
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
