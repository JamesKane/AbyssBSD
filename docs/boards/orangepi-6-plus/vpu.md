# Video codec: Arm Mali-V ("Linlon VPU", mvx) (scope)

Scope (2026-10-08) for running the Sky1's video codec on FreeBSD: hardware
decode and encode for FFmpeg, mpv and GStreamer. The approach is the NPU's
and the GPU's: Linux's driver through LinuxKPI, out of tree (GPL), with
FreeBSD glue for ACPI power, clocks and resets. What is new here is V4L2:
Linux codecs are V4L2 memory-to-memory devices, and FreeBSD's kernel has
no V4L2.

**Phases 1-3 done, and encode (2026-10-08):**
[`vpu-kmod`](https://github.com/JamesKane/vpu-kmod) builds two modules:
`lkpi_v4l2.ko`, Linux v7.0's V4L2 core and videobuf2 through LinuxKPI,
and `amvx.ko`, CIX's driver (release 1.0.2) with FreeBSD glue. The codec
probes (Linlon v5276, four cores, four LSIDs) and registers four mem2mem
devices: `/dev/video0` decodes (H.263, H.264, HEVC, MPEG-2, MPEG-4, VP8,
VP9, AV1), `/dev/video1` encodes (H.264, HEVC, VP8, VP9), `/dev/video2`
and `/dev/video3` do JPEG. Stock FFmpeg (the 9.0.1 package) drives them
with its `*_v4l2m2m` codecs:

- H.264 and HEVC 1080p and VP9 720p decode **bit-exactly** against
  FFmpeg's software decoders, timestamps included, about 120 1080p frames
  a second (with the copy back to system memory);
- H.264 and HEVC encode from NV12, NV21 or YUV420: H.264 720p
  53.6/52.1/52.2 dB PSNR (Y/U/V), 1080p 45.8/44.2/44.6; HEVC 1080p
  46.2/44.9/45.3.

`tools/decode-test.sh` and `tools/encode-test.sh` in vpu-kmod repeat
these. The board loads the modules at boot (`kld_list`), and a devfs rule
gives `/dev/video*` to the `video` group (0660).

What it took, besides building V4L2 for LinuxKPI:

- **LinuxKPI** (freebsd-src `orangepi-6-plus`): a kobject added without
  a parent panicked (Linux puts it at sysfs's top; `kernel_kobj` added);
  platform devices had no sysfs node, so a kset under one failed;
  `dma_sync_single_*()` synced only a mapping looked up by its exact
  start, and nothing for the 1:1 mappings LinuxKPI does not track: on a
  device that does not snoop the caches (`_CCA` 0, no SMMU) the firmware
  never saw its message queues or page tables. And a file's poll could
  wait on one queue only, and `selrecord()`ed each time: V4L2 m2m polls
  three, and the third panicked `select`. All four affect any LinuxKPI
  driver; amdgpu was checked on amd64.
- **V4L2 core**: LinuxKPI names a cdev's `/dev` node after the cdev,
  Linux after the device: the V4L2 core names its cdev too.
- **The driver**: on resume each core's memories are repaired (its
  `REPR` method, as its power resource's `_ON`). The cores' `_PR3`
  keeps their power resources on in D3, so switching the cores' power
  would not repeat it. CIX's driver gave NV12, NV21, YUV420 and P010 a
  V4L2 plane per colour plane, where V4L2 defines one plane with the
  chroma after the luma (their `M` variants have a plane each). FFmpeg
  fills them as V4L2 defines, so the encoder read no chroma, and YUV420
  crashed FFmpeg. On FreeBSD the driver presents them as one plane.
- Raw `.h264` input gives FFmpeg no timestamps, and it sends 0: use a
  container. Linux behaves the same.

## The hardware, from the board's ACPI tables

- `\_SB.VPU0` (`CIXH3010`): two 64 KB register windows, `0x14230000` (the
  RCSU, the block's power, clock and reset controls) and `0x14240000` (the
  codec), one interrupt (GSIV `0x166`); `_CCA` 0 (not coherent).
- Power: ACPI power resources, `PPRS` for the block and `PRS0`-`PRS3` for
  four cores (`CRE0`-`CRE3`), each `_ON` releasing its core through the
  firmware's `DMRP` (masks 2, 4, 8, `0x10` at `0x14230000`). Each core
  also has `REPR` (the same memory repair); its `_PR3` lists the same
  resource as `_PR0`, and the resource's `_STA` is always 0.
- The hardware's SVN revision is `0xe0c1afe1` (the driver's
  `MVE_SVN_ENPWOFF`): the cores power off when the codec's reset is
  asserted, and need memory repair after each power-up.
- `CLKT`: `vpu_clk` (SCMI clock `0x43`). `RSTL`: `vpu_reset` (RST0 `0x0E`)
  and `vpu_rcsu_reset` (RST0 `0x8E`).
- `_DSD` `power-domains`: SCMI performance domain 9 (`vpu_dfs`: 150, 300,
  480, 600, 800, 1200 MHz), as the NPU's 8, through `sky1_scmi`.
- **Not behind an SMMU**: no IORT named component (the display, NPU and
  ISP have one). The codec has its own MMU (the driver's `mvx_mmu.c`) and
  takes physical addresses, 40 bits.

## The software

| Layer | What | Licence | Source |
|---|---|---|---|
| Kernel driver | `amvx.ko`, Arm China's "mvx" for Mali-V (Linlon): the device, a scheduler over the cores, firmware loading, the codec's MMU, sessions (about 30,000 lines); and a V4L2 m2m interface, `/dev/video*`, decoder and encoder (about 6,000) | GPL-2.0-only (SPDX; the files also carry Arm China's "confidential" boilerplate) | [cix_opensource__vpu_driver](https://github.com/cixtech/cix_opensource__vpu_driver) (2026Q3 RC2.3; also in Armbian's and deepin's kernels) |
| Firmware | One blob per codec, loaded per session, 5.4 MB: decode AV1, HEVC, H.264, VP9, VP8, MPEG-2/4, VC-1, AVS, AVS2, JPEG; encode H.264, HEVC, VP8, VP9, JPEG | binary, no licence file | `cix-vpu-driver` (radxa-pkg/cix-prebuilt), `/lib/firmware/*.fwb` |
| Test tools | `mvx_decoder`, `mvx_encoder`, `mvx_info` (V4L2, Linux, glibc) | binary | `cix-vpu-test` |
| Applications | FFmpeg's `*_v4l2m2m`, GStreamer's `v4l2` plugin, mpv `--hwdec=v4l2m2m` | open | FreeBSD ports, already built with V4L2 (`ffmpeg` `V4L=on`, `gstreamer1-plugins-v4l2`, `v4l_compat`) |

FreeBSD already has the user side of V4L2: the ports' applications speak
it (to webcamd's devices), and the Linuxulator translates Linux programs'
V4L2 ioctls (`linux_ioctl_v4l2`). The kernel side is missing: V4L2's core
(device registration, the ioctl dispatcher, controls, events, file
handles) and videobuf2 (buffer queues, mmap, scatter-gather DMA,
dma-buf), which the driver's V4L2 layer is written against.

## Approaches to V4L2

1. **Port Linux's V4L2 core and videobuf2** (GPL, about 15,000-17,000
   lines: `v4l2-dev`, `-ioctl`, `-device`, `-fh`, `-event`, `-ctrls-*`,
   `videobuf2-core`, `-v4l2`, `-dma-sg`, `-memops`) into a LinuxKPI module
   of its own, as drm-kmod carries DRM's core. The driver's V4L2 layer
   then builds unchanged. Reusable for other SoCs' codecs (Hantro, Rockchip,
   Amlogic) and cameras.
2. **Rewrite the driver's V4L2 layer natively**: a FreeBSD character device
   implementing the V4L2 m2m ioctls over the driver's core. Smaller
   (about 6,000 lines replaced), but bespoke, and every V4L2 subtlety the
   applications rely on is ours to get right.

**Chosen (2026-10-08): 1**, Linux's V4L2 core and videobuf2 through LinuxKPI.

## Plan

1. **The core** (done) (`vpu-kmod`, GPL, out of tree): ACPI glue (power
   resources for the block and four cores, `vpu_clk`, both resets through
   RST0), the driver's core without its V4L2 layer, firmware from
   `/boot/firmware`. Goal: the codec's ID registers, cores counted, a
   firmware blob loaded.
2. **V4L2 for LinuxKPI** (done): the V4L2 core and videobuf2 ported, `/dev/video*`
   registered, the driver's V4L2 layer on top. Goal: `VIDIOC_QUERYCAP`
   and the format lists from a native tool (vpu-kmod's `tools/v4l2info`;
   `v4l2-ctl` does not recognise the device).
3. **First decode** (done, with FFmpeg's `h264_v4l2m2m`; Arm's
   `mvx_decoder` under the Linuxulator not tried): H.264 to NV12, the
   output checked against FFmpeg's software decoder.
4. **Integration**: done: HEVC, VP9, H.264 and HEVC encode, loading at
   boot. To do: mpv and GStreamer; the other codecs (AV1, VP8, MPEG,
   JPEG); dma-buf export to the display (no copies); DVFS (domain 9;
   the driver's devfreq is stubbed); several sessions on the four cores;
   USERPTR buffers (`frame_vector` is stubbed); secure video.

## Open questions

- What the V4L2 layer needs from videobuf2 beyond scatter-gather: dma-buf
  import (for zero-copy display) and the request API.
- ~~Whether FFmpeg's FreeBSD build enables `v4l2_m2m`~~: it does. The
  `ffmpeg` package (9.0.1, `--enable-libv4l2`) has the `*_v4l2m2m`
  decoders for H.264, HEVC, VP8, VP9, MPEG-1/2/4, H.263 and VC-1, and
  encoders for H.264, HEVC, VP8, MPEG-4 and H.263: with a V4L2 device in
  the kernel, stock FFmpeg and mpv need no rebuild.
- Why `v4l2-ctl` (v4l-utils 1.23) reports "Unable to detect what device
  /dev/video0 is": it probably looks for the device in sysfs.
- The firmware's terms (CIX publishes it in its packages; there is no
  licence file).
