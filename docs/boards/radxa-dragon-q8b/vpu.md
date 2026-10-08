# Video codec: Qualcomm Iris (VPU 2.0) (scope)

Scope (2026-10-08) for hardware video decoding on the Q8B. The SC8280XP
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
| SMMU | `qcom_apps_smmu`: a context bank and page table for a stream, explicit `map`/`map_pages` (FastRPC's DSP streams) | **DMA through it for a LinuxKPI driver**: Iris uses the DMA API throughout. Best as an iommu(4) backend for the MMU-500 (busdma tags that translate, as busdma_iommu does for SMMUv3), so LinuxKPI's DMA needs no change; the IOVA window `0x25800000`-`0xe0000000` |
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
2. **DMA through the apps SMMU** (freebsd-src): an iommu(4) backend for the
   MMU-500 on top of `qcom_smmu`'s page tables, giving the codec a
   translating busdma tag with the IOVA window above. Goal: a test
   module's DMA buffers map into the codec's context bank.
3. **Firmware boot**: the Iris core through LinuxKPI (in vpu-kmod beside
   `amvx`, sharing `lkpi_v4l2`), PAS 9 into the carve-out, the video memory
   protection call, HFI queues. Goal: `SYS_INIT` answered, the firmware's
   version string.
4. **First decode**: `videobuf2-dma-contig` for LinuxKPI, `/dev/video*`,
   FFmpeg's `h264_v4l2m2m` checked bit-exactly against software, then HEVC
   and VP9, 4K.
5. **Integration**: DVFS (the six core-clock levels, rails and bandwidth
   per level), loading at boot, the firmware in a package; the encoder
   (first why FFmpeg's crashes on Linux).

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
