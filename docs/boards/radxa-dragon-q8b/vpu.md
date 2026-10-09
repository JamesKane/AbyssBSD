# Video codec: Qualcomm Iris (VPU 2.0)

**Status (2026-10-09):** H.264, HEVC and VP9 decode on FreeBSD, bit-exact
(phase 4, below), on `GENERIC-IOMMU` with vpu-kmod's `qcom_iris.ko`.

Scoped 2026-10-08, for hardware video decoding on the Q8B. The SC8280XP
has Qualcomm's video codec ("Venus", now "Iris", VPU 2.0). It was missing
from this board's open items: Windows' ACPI hides it inside the GPU's device,
because the Windows graphics driver runs it too.

The approach is the Orange Pi 6 Plus's
([../orangepi-6-plus/vpu.md](../orangepi-6-plus/vpu.md)): Linux's driver
through LinuxKPI, out of tree (GPL), on `lkpi_v4l2.ko` (Linux's V4L2 core
and videobuf2, already ported in
[vpu-kmod](https://github.com/JamesKane/vpu-kmod)), with FreeBSD glue for
what Linux gets from its devicetree. FFmpeg's `*_v4l2m2m` codecs, mpv and
GStreamer then use it as on the Orange Pi.

## The hardware

From the DSDT, `\_SB.GPU0` (`QCOM0636`, which msm attaches to): its `RESI`
method names each `_CRS` entry, and the last two are the codec's.

- `VIDEO_REGS`: 2 MB at `0x0AA00000` (Linux maps the first 1 MB).
- `VIDC_INTERRUPT`: GSIV 206 (SPI 174), level-high.

Nothing else is in ACPI: clocks, power domains and votes are the Windows
power engine plug-in's, as they are for the GPU. From Linux (`sc8280xp.dtsi`,
Radxa's `sc8280xp-radxa-dragon-q8b.dtb`):

- **Clocks**: `GCC_VIDEO_AXI0_CLK` (GCC `0x28010`; its reset is bit 2 of
  the same register), and the video clock controller (`videocc`, at
  `0x0ABF0000`, laid out as SM8350's with SC8280XP offsets: Linux's
  `videocc-sm8350.c`): `VIDEO_CC_MVS0C_CLK` (`0xc34`, reset bit 2) and
  `VIDEO_CC_MVS0_CLK` (`0xd34`), from `video_pll0` (Lucid 5LPE, `0x42c`).
  Core clock levels: 240, 338, 366, 444, 533, 560 MHz.
- **Power domains**: the videocc's `MVS0C_GDSC` (`0xbf8`) and `MVS0_GDSC`
  (`0xd18`); the RPMh rails `MX` and `MMCX` at the level each clock needs
  (SVS to Turbo L1). The videocc itself is in `MMCX`.
- **Interconnect**: `cpu-cfg` (CPU to `SLAVE_VENUS_CFG`) and `video-mem`
  (`MASTER_VIDEO_P0` to DDR), as RPMh bandwidth votes.
- **SMMU**: the apps SMMU (MMU-500), streams `0x2a00` and `0x2a07`, mask
  `0x400`. Radxa marks the codec `dma-coherent`.
- **Firmware memory**: `video-region@8c600000`, 7 MB, `no-map`. UEFI
  already keeps it from FreeBSD: it falls in the hole between FreeBSD's
  memory segments `0x80c00000-0x82700000` and `0x8e400000-...`.
- **Device addresses**: TrustZone protects IOVA `0`-`0x25800000` (the
  driver's `tz_cp_config`, Radxa's `iris-iova` reservation); the driver's DMA
  mask ends at `0xe0000000`. Its buffers must therefore be translated by the
  SMMU into `0x25800000`-`0xe0000000`.
- **Firmware**: authenticated by TrustZone as PAS 9.

## The software

| Layer | What | Source |
|---|---|---|
| Driver | `qcom-iris`, about 17,800 lines (GPL-2.0): the HFI interface (gen1 and gen2), the VPU 2.0/3.x hardware, firmware loading, V4L2 stateful decoder (and encoder on newer chips), on `videobuf2-dma-contig` | Radxa's kernel, [radxa/kernel](https://github.com/radxa/kernel) branch `linux-7.0.11` (the Q8B's Ubuntu kernel, 7.0.11-7-qcom), which adds `sc8280xp_data` and two decoder fixes; Armbian's `sc8280xp-edge` patches carry the same. Upstream Linux 7.3 has no SC8280XP data: it binds the chip as an SM8250 (`qcom,sm8250-venus`), with gen1 firmware |
| Firmware | `qcom/vpu/vpu20_p4_gen2_s6.mbn` (2.0 MB, gen2 HFI), what Radxa's devicetree names; also `qcom/sc8280xp/qcvss8280.mbn`, identical to Lenovo's X13s image | Radxa's `radxa-firmware` package (on the board's Ubuntu partition) |
| Applications | FFmpeg `*_v4l2m2m`, GStreamer `v4l2`, mpv | FreeBSD packages, as on the Orange Pi |

On this chip Iris decodes H.264, HEVC and VP9 (no AV1 on VPU 2.0).
Radxa's kernel also registers an encoder (H.264, HEVC), although its
`sc8280xp_data` lists decoder formats only (phase 0, below); FFmpeg's
encoder crashed against it, so encoding is unproven. The older `venus`
driver (gen1 firmware, HFI 6xx) is the other route to encoding; upstream
builds it only without Iris.

Armbian's patch notes that driving the Q8B's gen2 firmware with gen1 HFI
fails at `SYS_INIT` ("bad packet size (64 should be 20)"): the firmware and
the driver's platform data must match.

## What FreeBSD has, and what it lacks

| Need | Have | To do |
|---|---|---|
| V4L2 core, videobuf2 | `lkpi_v4l2.ko` (vpu-kmod): dma-sg | **videobuf2-dma-contig** (Iris's allocator): `dma_alloc_attrs` with `WRITE_COMBINE` and `NO_KERNEL_MAPPING`, `dma_mmap_attrs`, `dma_get_sgtable` for dma-buf export |
| Firmware authentication | `qcom_scm`: PAS init, memory setup, auth-and-reset, shutdown | `qcom_scm_mem_protect_video_var()` (the `tz_cp_config` call) |
| SMMU | `qcom_apps_smmu`: a context bank and page table for a stream, explicit `map`/`map_pages` (FastRPC's DSP streams) | Done (phase 2): `qcom_apps_iommu`, busdma tags that translate for a claimed device, so LinuxKPI's DMA needs no change; the IOVA window `0x25800000`-`0xe0000000`. Needs `GENERIC-IOMMU` |
| RPMh votes | `qcom_rpmh_arc_vote()` (rails), `qcom_rpmh_bcm_vote()` (bandwidth) | MX/MMCX levels per clock; the video-mem and cpu-cfg BCMs |
| Clocks, power domains | `qcom_gpucc` (the GPU's clock controller, fixed rates), `qcom_clk` building blocks | **`qcom_videocc`**: MVS0C/MVS0 GDSCs, the MVS0 clocks, `video_pll0` (Lucid 5LPE, unless UEFI left it configured), the GCC video AXI clock and reset |
| A device to attach | msm owns `\_SB.GPU0` | The codec as its own device: a child added from the SoC table (`\_SB.SOID`), as `qcom_apps_smmu` finds its SMMU, with the registers and interrupt above |

## Phase 0: Linux on the board (done, 2026-10-08)

Radxa's Ubuntu (7.0.11-7-qcom, FFmpeg 8.0.1), booted once from FreeBSD's
loader ([firmware-acpi-boot.md](firmware-acpi-boot.md)):

- **Decode works, bit-exactly**: FFmpeg's `h264_v4l2m2m` (1080p, B-frames),
  `hevc_v4l2m2m` (1080p) and `vp9_v4l2m2m` (720p), frame MD5s against
  FFmpeg's software decoders: all match; 120 frames in 0.89, 0.95 and
  0.47 s. `/dev/video0` (`Iris Decoder`): H.264, HEVC, VP9 to NV12, P010
  and Qualcomm's compressed `Q08C`/`Q10C`.
- **An encoder registers too** (`/dev/video1`, `Iris Encoder`: H.264 and
  HEVC from NV12 or `Q08C`), against what this scope first said. FFmpeg's
  `h264_v4l2m2m` encoder segfaulted at once, writing nothing; whether
  FFmpeg or the driver is at fault is not known.
- **Clocks while running**: `video_pll0` 1599 MHz; `video_cc_mvs0c_clk`
  799.5 MHz (PLL / 2); `video_cc_mvs0_clk` 533 MHz (PLL / 3, the 533 MHz
  OPP); `gcc_video_axi0_clk` on. Linux configures `video_pll0` itself at
  probe (`clk_lucid_pll_configure`), so FreeBSD must too, whatever UEFI
  leaves.
- **Power domains**: `mvs0c_gdsc` on (software-controlled), `mvs0_gdsc` on
  (hardware-controlled, `HW`); RPMh `mx` at level 256 (nominal) and `mmcx`
  at 384 (turbo), as the 533 MHz OPP requires. The video clock controller
  is itself in MMCX: **reading its registers with MMCX off resets the SoC**
  ([lessons.md](lessons.md)).
- **Bandwidth**: `cpu-cfg` and `video-mem` paths voted (1000 kB/s average
  when idle).
- **SMMU**: the apps SMMU (`15000000`, MMU-500, 110 context banks, 36-bit
  VA), IOMMU group 9.
- Interrupt 206 (`iris`) counted 835 for the three decodes. The firmware
  logs no version string.

## Plan

0. **Linux check**: done, above.
1. **Power and clocks** (done, 2026-10-08: `qcom_videocc`, freebsd-src
   `3dafe231c2`, with `qcom_rpmh_arc_vote_level()`): MX nominal and MMCX
   turbo (only ever raised: nothing aggregates the APPS votes, and the
   display runs on UEFI's), the always-on clocks, `video_pll0` at 1599 MHz,
   the core clock source, MVS0C and its clocks with the resets pulsed, then
   MVS0 and its clock. `hw.qcom_videocc.test` reads the codec's wrapper
   version: **`0x60100608` (6.16)**, the same over six power cycles, the
   display undisturbed. UEFI leaves the PLL unconfigured and both power
   domains off.
2. **DMA through the apps SMMU** (done, 2026-10-08, freebsd-src
   `1464aadaf7`..`5cf2c7fd99`): `qcom_apps_iommu`, the apps SMMU as an
   iommu(4) unit for devices whose drivers claim it (their stream ID/mask
   pairs and an I/O window); `qcom_smmu` page tables that map without
   sleeping, for busdma; `qcom_apps_smmu` routing several streams to a
   bank and letting it go. **The codec needs a kernel with `options
   IOMMU`**: `GENERIC-IOMMU` (GENERIC plus that option; nothing unclaimed
   is translated). On the board: the hypervisor accepts the codec's
   streams (`0x2a00` and `0x2a07`, mask `0x400`, bank 7); a 256 KB buffer
   loads through the claimed tag as one segment at `0x25801000`, all 64
   pages translating right, nothing left after unload; the regression test
   and the NPU (FastRPC, 79/100) as before. Found on the way: iommu(4)
   looped forever reserving a region from 0 (fixed in `1464aadaf7`).
3. **Firmware boot** (done, 2026-10-08): Radxa's Iris as `qcom_iris.ko` in
   vpu-kmod (`9edbcae`), on `lkpi_v4l2.ko` with `v4l2-mem2mem` and
   `videobuf2-dma-contig` added (`60fbfde`). FreeBSD glue in
   `freebsd/iris_freebsd*.c`: the device is found from the SoC ID (449),
   with the registers and GSIV 206 above; it claims the codec's SMMU streams
   (coherent), drives `qcom_videocc`, votes MM1 bandwidth once, stands in
   for the power domains, fixes the clock at 533 MHz, and loads the firmware
   through PAS 9 into the carve-out. Opening `/dev/video0` boots the
   firmware: **`video-firmware.2.4.2-39cc47c1… PROD`**, and the decoder's
   formats (H.264, HEVC, VP9 to NV12, P010, `Q08C`, `Q10C`). freebsd-src
   fixes on the way:
   - LinuxKPI coherent DMA addresses aligned as Linux's behind an IOMMU
     (`e736b55c79`): the firmware refused an unaligned queue table
     ("invalid setting for uc_region").
   - LinuxKPI `disable_irq_nosync()` from an interrupt handler
     (`fc6956c2ce`): it slept, panicking at the firmware's first interrupt.
   - `qcom_scm_mem_protect_video_var()` (`d5eea743f4`); hardware control
     of the core's power domain (`1417e27c58`); context bank fault reports,
     `dev.qcom_apps_iommu.0.faults` (`8139e5c234`).
4. **First decode** (done, 2026-10-09): FFmpeg's `*_v4l2m2m` decoders on
   FreeBSD, frame MD5s against FFmpeg's software decoders, 120 frames each:

   | Clip | Result | FreeBSD | Linux (phase 0) |
   |---|---|---|---|
   | H.264 1080p, B-frames | match | 0.90 s | 0.89 s |
   | HEVC 1080p | match | 0.76 s | 0.95 s |
   | VP9 720p | match | 0.46 s | 0.47 s |
   | H.264 2160p | match | 3.22 s | |

   Five more H.264 runs matched too, with no SMMU faults. Two more fixes:
   - LinuxKPI runtime PM status queries without the device's lock
     (freebsd-src `d1c352d56f`): Iris marks itself busy from its resume
     callback, and recursed on the lock.
   - `dma_mmap_attrs()` records the range for LinuxKPI's device pager
     (vpu-kmod `7889fb1`): it called `remap_pfn_range()`, which needs the
     VM object LinuxKPI makes only after the driver's mmap, and every
     buffer mmap panicked.

   Unloading `qcom_iris.ko` deadlocked: Iris powers off with
   `disable_irq_nosync()` holding the lock its threaded handler takes, and
   LinuxKPI's tore the handler down, waiting for that thread. Fixed in
   freebsd-src `cca7efd203`: it only marks the interrupt disabled, as Linux
   doesn't wait either. Load, decode, unload, reload, decode and unload
   (with `lkpi_v4l2.ko`) all work.
5. **Integration** (in progress):
   - **DVFS** (done, 2026-10-09; freebsd-src `90554e208c`, vpu-kmod
     `60d4f77`): `qcom_videocc` knows Linux's six levels (240, 338, 366,
     444, 533, 560 MHz), each a `video_pll0` rate (the core clock is the
     PLL / 3: L `0x25`/`0x34`/`0x39`/`0x45`/`0x53`/`0x57`) with its MX and
     MMCX levels; Iris's OPP calls pick one, rails raised before the clock
     and lowered after it. The codec runs at 560 MHz decoding (366 MHz in
     between), 240 MHz when it suspends (1.5 s idle), and its rails then
     drop to floors. Nothing aggregates APPS RPMh votes, so the floors keep
     what other users need: **MMCX nominal** covers the display UEFI set up
     (DP2; its MDP clock runs at 300 MHz from `disp0_cc_pll1` at 600 MHz,
     read from `0xaf00000`; nominal covers MDP to 500 MHz and any DP link
     rate), MX SVS. Tunables `hw.qcom_videocc.mmcx_floor`/`mx_floor`;
     `dev.qcom_iris.0.core_hz` shows the rate. Bit-exact as before. The
     MM1 bandwidth vote is still only raised.
   - **Loading at boot** (done, 2026-10-09): the board's default kernel
     is `GENERIC-IOMMU` (`/boot/kernel`; GENERIC #138 kept as
     `/boot/kernel.138`); `lkpi_v4l2.ko` and `qcom_iris.ko` in
     `/boot/modules`, `kld_list="qcom_iris"` (its dependencies load with
     it); `/etc/devfs.rules` gives the `video` group `/dev/video*`:

         [localrules=10]
         add path 'video*' mode 0660 group video

     with `devfs_system_ruleset="localrules"`. A user in `video` decodes
     right after boot: the glue loads the firmware at attach (vpu-kmod
     `bb83e6a`), since firmware(9) loads images only for privileged
     callers and Iris loads its own at the first open. The regression
     snapshot (`q8b-regress.sh`) matches GENERIC #138's but for the
     codec's modules; glmark2 equal.
   - **The firmware in a package** (done, 2026-10-09): the ports overlay's
     `multimedia/qcom-iris-firmware` installs
     `/boot/firmware/qcom/vpu/vpu20_p4_gen2_s6.mbn` from Radxa's
     `radxa-firmware` 0.2.42 (the distfile `misc/linux-fastrpc` uses).
     Radxa states no terms for the image, so the port builds packages for
     local use and allows no mirroring (`LICENSE_PERMS=auto-accept`).
   - **The encoder** (works, 2026-10-09; no changes needed): FFmpeg's
     `h264_v4l2m2m` and `hevc_v4l2m2m` encode NV12 at 720p, 1080p and 4K
     (1080p H.264 at 8 Mbit/s: 7.3x real time). Software decodes the
     streams cleanly (H.264 High, level 5.0); PSNR against the source
     43-47 dB (1080p H.264 at 8 Mbit/s: 45.4 dB; HEVC 46.6; 4K at 20 Mbit/s
     43.2 and 43.6). Two things to know:
     - **Write raw streams** (`-f h264`, `-f hevc`): FFmpeg's V4L2
       encoder has no codec headers before the first packet, so Matroska
       or MP4 output fails to write its header ("Could not write header"),
       and FFmpeg then hangs stopping the encoder. Remux the raw stream
       afterwards. This may be what crashed FFmpeg on Linux (phase 0).
     - **FFmpeg loses the last frame** (29 of 30, 59 of 60, 89 of 90).
       Not the firmware or the port: a V4L2 test program that drains as
       v4l2-ctl does (`STOP`, then capture until `V4L2_BUF_FLAG_LAST`) gets
       30 of 30 on FreeBSD, the end marked by an empty `LAST` buffer, and
       v4l2-ctl gets 30 of 30 on Linux. Iris also returns empty capture
       buffers flagged `ERROR` (the firmware's empty outputs) along the
       way; FFmpeg 8.0 (`libavcodec/v4l2_context.c`) ends a drain at the
       first capture buffer with no bytes, LAST or not, so it stops at one
       of those while the last frame is still being encoded.
     - On Linux (Radxa's 7.0.11 kernel, Ubuntu's FFmpeg 8.0.1) FFmpeg's
       encoder segfaults at once, raw output too, so phase 0's crash isn't
       about Matroska; v4l2-ctl 1.32 encodes there.

   VP9 to FFmpeg's `null` output logs `driver decode error` for 9 of 120
   frames of the test clip: Iris returns VP9's hidden frames (not to be
   shown) as `V4L2_BUF_FLAG_ERROR` buffers by design
   (`HFI_GEN2_PICTURE_NOSHOW`), and FFmpeg logs each. Harmless: the shown
   frames match.

## Open questions

- Whether the hypervisor allows the codec's streams through a stage 1
  context bank with no changes (the DSPs' did), and what stream `0x2a07` is
  for (Radxa adds it; upstream's devicetree has only `0x2a00`).
- Whether `qcom_scm_mem_protect_video_var` works on this TrustZone as on
  Linux's targets.
- The firmware's terms: `vpu20_p4_gen2_s6.mbn` comes from Radxa's package,
  not linux-firmware.
- Whether FFmpeg's v4l2m2m decoders need anything from Iris that CIX's
  driver didn't (Iris follows the stateful decoder specification closely:
  source-change events, resolution changes, `V4L2_DEC_CMD_STOP`).
