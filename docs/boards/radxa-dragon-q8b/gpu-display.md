# GPU and display

The goal is an accelerated Wayland desktop. The stack as it stands:

```
Mesa freedreno (GL ES 3.2) / Turnip (Vulkan 1.3)
        │  libdrm (patched: platform devices on FreeBSD)
        ▼
msm.ko: the GPU (Linux msm, ported) ──► card1, renderD128
        msmfb (display KMS, ours)  ──► card0
        │ LinuxKPI + drm-kmod core
        ▼
qcom_gpucc  qcom_scm  qcom_cmd_db  qcom_smmu   (BSD libraries in src/sys/dev)
```

wlroots/sway uses msmfb as the display device and msm's GPU as the render
device (Mesa's kmsro). GBM buffers are msmfb dumb buffers that the GPU
renders into through PRIME, and the display scans them out directly. Plain
`sway` with no environment variables picks this set-up by itself. msm.ko
autoloads through devmatch. sysfbdrm (below) is the fallback when msm isn't
loaded.

## Display: msmfb (`kmod/drm-msm/freebsd/msm_freebsd_fb.c`)

A native (BSD-2) KMS driver inside msm.ko, on a glue platform device. It
takes over the pipeline UEFI leaves running, rather than porting Linux's
DPU and DP drivers, which would need the common clock and PHY frameworks
in LinuxKPI first.

**The pipeline and its registers** (offsets from MDSS `0xae00000`; ACPI
`GPU0` memory resource 0 covers it all, 2 MB):

- MDP `+0x1000`; from it: SSPP VIG2 `+0x8000`, LM2 `+0x46000`, CTL2
  `+0x17000`, INTF6 `+0x3a000`. DP2 controller `+0x9a000` (AHB `+0`, AUX
  `+0x200`, link `+0x400`, P0 `+0x1000`); its PHY's TX blocks `+0xc2200`
  and `+0xc2600`; the DPTX2 pixel clock RCG in dispcc0 `+0x102208`.
- The MDSS interrupt is ACPI irq resource 0 (GSIV 115). `MDSS_HW_INTR_STATUS`
  bit 14 is DP2 (hotplug); the MDP interrupt's bit 17 is INTF6's vsync.
- The display's SMMU streams are in bypass, and SSPP address registers are
  32-bit. So scan-out buffers are physically contiguous, below 4 GB
  (`alloc_pages(GFP_DMA32)`), and write-combining.

**What it does**, stage by stage:

- **A, flips.** A flip writes `SSPP_SRC0_ADDR`/`YSTRIDE0` and `CTL_FLUSH`
  bit 2. It takes effect at vsync, which is when the flush bit clears.
  Vsync drives vblank. With no client, or when the DRM master goes, the pipe
  shows the UEFI framebuffer (`0xc6200000`) and the console again. vt(4) is
  frozen while a master holds the display, as with sysfbdrm.
- **B1, the sink.** Polled AUX transfers (msm's `dp_aux.c` sequence, with
  the controller's AUX interrupts left masked) read the DPCD and the
  monitor's EDID. A failed transfer resets the AUX block and is retried, as
  msm and the DRM helpers do.
- **B3a, hotplug.** HPD events (mask `0xf` at AUX `+0x0c`) run a task that
  reads the DPCD sink count and the EDID and sends a DRM hotplug event. The
  CH7218A keeps HPD high while it is there, and reports its HDMI monitor
  coming and going with IRQ_HPD pulses and the sink count.
- **B3b, link training on reconnect**, as msm does on every plug: TPS1 clock
  recovery, then TPS4/3/2 equalization, adjusting swing and pre-emphasis
  from Linux's `phy-qcom-edp.c` DP tables (PHY `DRV_LVL` `+0x14`,
  `EMP_POST1` `+0x04`). After a replug the bridge shows the picture again
  without it, but its DPCD lane status stays 0 until trained. It settles at
  swing 2, pre-emphasis 1, which is what UEFI's training reached.
- **B3c, modes.** The connector offers the EDID's modes that one layer mixer
  (≤ 2560 wide) and the link carry. Interlaced and odd horizontal timings
  are rejected, because the INTF's wide bus carries 2 pixels per clock. A
  mode change follows msm's disable-then-enable order:
  1. push the idle pattern and wait for `IDLE_PATTERN_SENT`, which needs
     the stream still running;
  2. stop the INTF's timing engine and wait out its vsync;
  3. turn the main link off;
  4. program the pixel RCG's M/N/D, the DP stream timing, MSA and transfer
     unit, the SSPP and LM sizes, and the INTF timing, all computed with
     Linux's own code (`msm_freebsd_dp_calc.c`, GPL);
  5. reset and enable the main link, train it, and send video;
  6. flush the CTL (active-CTL scheme: `CTL_INTF_FLUSH` bit 6 plus
     `CTL_FLUSH` bits 2, 8, 17 and 31) and restart the INTF.

  The PHY and the link's rate and lanes stay as UEFI set them. The DP
  controller is not software-reset as Linux does, because that would wipe
  UEFI's AUX, HPD and lane setup, which msmfb doesn't reprogram. UEFI's
  registers are saved at probe and written back when the master goes and at
  detach, so the console returns in UEFI's own mode. That mode, read back
  from those registers, is identical to the monitor's preferred EDID mode,
  so a client asking for it causes no mode change at all.
- **DPMS** (`42228ff`). An inactive CRTC stops the stream the same way:
  push idle, INTF off, link off. The monitor then goes to sleep. Going
  active again resets the link, trains it and restarts the INTF. A mode
  set while the output is off only loads the timing. The console restore
  (master gone, detach) always turns the output back on. So does a client
  exiting, since DRM's framebuffer removal disables the CRTC: about a
  second of blank, as on Linux. Tested with the DPMS property: the monitor
  sleeps and comes back.

**UEFI's link and mode:**
- 4 lanes at **HBR3 (8.1 Gb/s)**, enhanced framing, 8 bpc RGB, CEA 1080p60,
  wide bus on.
- The CH7218A's DPCD (1.2) advertises only 5.4 Gb/s, yet it locks at HBR3.
  msmfb keeps UEFI's rate, while Linux would train at the advertised
  maximum. Every mode tried works at HBR3, down to 640×480 (under 3% of the
  link).
- UEFI's transfer-unit values differ from Linux's algorithm (1080p: TU 33,
  valid 5, against Linux's TU 41, valid 6 with moderation); both work.
  UEFI's MSA Mvid/Nvid differ from msm's too, with the same ratio.
- The pixel RCG runs at half the pixel clock (wide bus) from the PHY's
  1350 MHz (8.1 GHz / 6): 1080p is M/N 11/200. Linux's
  `clk_rcg2_dp_set_rate` reproduces UEFI's M, N and D exactly.

**Monitor under test:** Dell ST2421L behind the CH7218A. All 20 of its EDID
modes are offered. Tested at 1920×1080 60/59.94/50 Hz, 1280×1024@75, 1280×720,
1024×768, 800×600 and 640×480 at 60 Hz, plus custom timings.

**Not done:**
- PHY and link-rate changes (Linux's `phy-qcom-edp` PLL programming). They'd
  only matter for a sink UEFI trained differently, or one that needs more
  than HBR3×4.
- Cursor and overlay planes, scaling, DSC, YUV 4:2:0, and other DP outputs.
- Taking over when UEFI left the display off: msmfb then declines to probe.
- MDP clock or bandwidth votes for modes beyond UEFI's.

## Display fallback: sysfbdrm (`kmod/drm/sysfbdrm`)

- UEFI scans out the EFI framebuffer at `0xc6200000` (1920×1080 XRGB,
  stride 7680) through MDSS:
  SSPP VIG2 (`0xae01000+0x8000`) → LM2 → CTL2 → INTF6 → DP2 (`0xae9a000`)
  → Chrontel CH7218A → HDMI. The CH7218A has no I²C control from our side.
- sysfbdrm is a BSD-2 native newbus driver on the drm-kmod core:
  - dumb buffers come from `alloc_page`;
  - damaged regions are copied to the framebuffer;
  - a callout stands in for vblank, with absolute deadlines;
  - 60.0 Hz page flips, PRIME import/export;
  - freezes vt(4) while a DRM master holds it: `master_set` →
    `vt_freeze_main_vd`.
- **Stray pixels:** a GPU that doesn't snoop left stale cache lines in the
  copy. Making dumb buffers write-combining in *both* the kernel vmap and
  the user mmap fixed it. LinuxKPI's fault path takes the page memattr from
  `vm_page_prot`, so the two must match. There's an uncommitted experiment
  using cacheable buffers plus a clean before the copy: see MIGRATION.md §3.
- msmfb (above) replaces it whenever msm is loaded. OpenBSD's `qcdrm(4)`
  does display only, on FDT.

## GPU: Adreno 690

- GPU `0x3D00000` (`qcom,adreno-690.0`), chip ID `0xffff06090000`, 4 MB GMEM.
- The GMU is at `0x3D6A000`. GMU register physical address =
  `0x3d00000 + xmloffset*4`.
- Firmware:
  - `qcom/a660_sqe.fw` and `qcom/a660_gmu.bin`;
  - the zap shader `qcom/sc8280xp/LENOVO/21BX/qcdxkmsuc8280.mbn`, loaded
    into `gpu-mem` at `0x8bf00000`;
  - packaged as kmods from `firmware/` (msmkmsfw; module names are
    `qcom_<path with / . - as _>`).
- **ACPI `GPU0` (`QCOM0636`)** holds all the MMIO and IRQs, but clocks and
  power go through PEP.
  - Memory resource IDs: 0 MDSS `AE00000`, 2 GPU `3D00000`, 3 GMU `3D60000`
    (**contains** 6), 4 GMU PDC `B290000`, 6 GPU CC `3D90000`, 7 RSCC
    `3DE0000`.
  - Resource 6 overlaps resource 3, so it can't be allocated; use resource 3
    plus an offset.
  - IRQs 102–107.
- **The GPU is fully off at boot:** CX and GX GDSCs collapsed, PLLs off.

### Clocks and power: `qcom_gpucc`

A library: `qcom_gpucc_create(dev, res, offset)`, `cx_enable`/`cx_disable`.
The SC8280XP sequence:
1. GCC `0x52000` bits 15 and 16 (GPLL0 and GPLL0/2 to the GPU CC), plus
   `gpu_cfg_ahb` `0x71004` and `ddrss_gpu_axi` `0x7115c`.
2. The CX GDSC `0x106c`: clear SW_COLLAPSE, poll hw_ctrl `0x1540` bit 31,
   then set RETAIN_FF (bit 11).
3. RCGs: gmu `0x1120` cfg `0x602` (200 MHz), hub `0x117c` cfg `0x505`.
4. Branch clocks. `gcc_gpu_memnoc_gfx` `0x71010` goes **only after** the
   GDSC is up; otherwise CLK_OFF sticks.
5. The GPU SMMU also needs `gcc_gpu_snoc_dvm` (`0x171020` bit 0).

GX is collapsed through the GMU, as Linux does. CX stays on while the driver
is loaded, so `a6xx_recover` waits 1 s for a CX collapse that never comes.
A real CX collapse would need the SMMU state restored after power-up,
because the SMMU is in CX.

### Secure world: `qcom_scm`

- ACPI `QCOM04DD`, SMC64 calls, the interrupted/resume protocol, EBUSY
  retry, and an extended-arguments page below 4 GB.
- `PAS_IS_SUPPORTED` answers 0 for every ID, so don't rely on it (Linux
  doesn't check it for zap).
- Zap authentication works. `set_gpu_smmu_aperture` is used for per-process
  page tables.

### RPMh command DB: `qcom_cmd_db`

- Under ACPI, the AOP message RAM dictionary at `0xc3f000c` gives
  `{0x80860000, 0x13f0}`; there are 160 entries.
- `gfx.lvl` is `0x30050`, with levels 0 64 128 192 224 256 320 384 416.

### IOMMU: `qcom_smmu` (MMU-500)

- It attaches passively to ACPI `QCOM0609` and only maps the registers,
  because the SMMU may be unpowered. The GPU driver calls
  `qcom_smmu_claim()`, which finds the SMMU dedicated to the consumer
  through IORT (`acpi_iort_named_smmu`).
- The GPU SMMU at `0x3DA0000`: 4K pages, 9 SMRs, 7 context banks,
  NUMS2CB=0 (the hypervisor owns stage 2).
- The apps SMMU at `0x15000000`: UEFI set 9 SMRs (display, USB, PCIe) to
  identity context banks. **Leave them alone.**
- **Stream IDs:** use Linux's DT pairs exactly: GPU `(0, 0xc00)` and
  `(1, 0xc00)`, GMU `(5, 0xc00)`. See [lessons.md](lessons.md) for what
  happens otherwise.
- The GMU's page table entries need `IOMMU_PRIV` (`QCOM_SMMU_PRIV`). Pages
  writable from EL0 are implicitly PXN, and the GMU fetches as a
  privileged instruction fetch (FSR `0x8` at `0x4000`).
- Per-process page tables: context bank 0 is split, TTBR1 for the kernel's
  upper half and TTBR0 per process, switched by `CP_SMMU_TABLE_UPDATE`. The
  hypervisor accepts the TTBR1/TCR writes.
- Faults: context-bank IRQ n is bank n in IORT order (GSIV
  `0x2C8-0x2D0`, `0x2DF`, edge-triggered). The handler reports, clears FSR,
  and terminates (no stall).

**Verified:**
- one process's GPU writes to another's buffer take a TRANSLATION fault,
  and the other buffer is untouched;
- a hung submit is detected and recovered, and queued work replays (about
  2.4 s).

## The msm port (`kmod/drm-msm`)

Linux v6.13's msm, built against drm-kmod. See
[kmod/drm-msm/README.md](../../../kmod/drm-msm/README.md) for the glue files.

Bring-up fixes that went into LinuxKPI (all in `src/`):
- `devm_ioremap` was a NULL stub.
- `memcpy_toio`/`memcpy_fromio`/`memset_io` were plain `memcpy`, which
  alignment-faults on Device memory on arm64.
- `vmap` ignored `prot`.
- `pgprot_writecombine` on arm64 was write-through; it's now NC.
- `dma_map_sg` used one dmamap for the whole list, which fails on arm64. It
  now uses one map per entry.
- The platform bus, component framework and runtime PM moved out of the
  glue into LinuxKPI (Phase C).
- Hrtimers were drained under a spinlock (`hrtimer_cancel`), which cost
  about 60 ms per frame under WITNESS.

Also needed:
- `CONFIG_ARCH_QCOM` must be defined, or zap loading returns `-EINVAL`.
- The msm platform device is parented under adreno, so `msm_use_mmu()` is
  true.

## Mesa and libdrm

- **libdrm** (`ports/graphics/libdrm/files/patch-xf86drm.c`):
  - FreeBSD `drmGetMinorNameForFD` must not return nodes that don't exist.
    Without that, wlroots skips its pixman fallback.
  - Platform devices (`platform:<name>` bus IDs) need
    `drmGetDevice2`, or `eglInitialize` fails.
  - A node's bus ID is read from `dev.drm.N.busid` (a drm-kmod sysctl).
- **Mesa 26.2.2** (`ports/graphics/mesa-{dri,libs}`):
  - freedreno goes into mesa-libs' gallium drivers on aarch64, and Turnip
    into mesa-dri's Vulkan drivers;
  - two patches: `ENODATA`→`ENOATTR` in freedreno's `msm_bo.c`, and
    `fd_gettid()`.
- Test programs in `kmod/drm-msm/tools`: `msmtest`, `msmfault`, `egltest`,
  `vktest`.
- `vulkaninfo` aborts on `VK_KHR_display`: the msm GPU node has no KMS
  (msmfb is a separate DRM device).

## Performance (2026-09-29)

| Test | FreeBSD | Linux 7.0 (same board) |
|---|---|---|
| glmark2-es2 offscreen 800×600 | 6963 | — |
| vkmark headless 800×600 | 12025 | — |
| vkmark 1080p | 5446 | 4716 |
| glmark2 "heavy" 1080p | 2473 | not comparable |

- The GPU's frequency follows its load (devfreq; see
  [power-thermal-idle.md](power-thermal-idle.md#gpu-frequency-devfreq)).
  Scenes that saturate it get 690 MHz and score the same as with the clock
  pinned there.
- DDR bandwidth voting doesn't limit performance: the a690 has no GMU
  bandwidth votes even in Linux 7.2. So RPMh interconnect work is deferred.
- Two early bottlenecks, both fixed:
  - 33 fps came from the hrtimer drain above;
  - runtime PM had no autosuspend, so the GPU suspended every frame.

## Known issues

- `recover_worker` skips `gpu->funcs->recover` when the hung submit was the
  only one (an upstream Linux bug). CP spins until autosuspend.
- Unload leaks: 240 B in drm debugfs, 64 B in qcom_smmu.
- One boot with `kld_list="sysfbdrm"` froze the console and sshd never
  started; the cause is unknown. Three later boots were fine. The board
  doesn't set it at present.
- libdrm assumed `cardN` ↔ `renderD(128+N)`, which is wrong with the display
  as card0 and msm as card1/renderD128. Our libdrm patch matches nodes by
  `dev.drm.N.busid` instead.
- Upstream Linux fixes to send: hangcheck `timer_delete_sync` on cleanup,
  freeing `pwrup_reglist`, and the `recover_worker` skip.
