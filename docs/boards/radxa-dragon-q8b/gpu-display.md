# GPU and display

The goal is an accelerated Wayland desktop. The stack as it stands:

```
Mesa freedreno (GL ES 3.2) / Turnip (Vulkan 1.3)
        │  libdrm (patched: platform devices on FreeBSD)
        ▼
msm.ko (Linux msm, ported: kmod/drm-msm) ──► renderD128        sysfbdrm.ko ──► card0
        │ LinuxKPI + drm-kmod core                               (UEFI framebuffer KMS)
        ▼
qcom_gpucc  qcom_scm  qcom_cmd_db  qcom_smmu   (BSD libraries in src/sys/dev)
```

wlroots/sway uses sysfbdrm as the display device and msm as the render
device (Mesa's kmsro). GBM buffers are sysfbdrm dumb buffers that msm
renders into through PRIME. sysfbdrm copies the damaged parts to the UEFI
framebuffer. Plain `sway` with no environment variables picks this set-up
by itself.

## Display: sysfbdrm (`kmod/drm/sysfbdrm`)

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
- The real display driver (DPU/DP KMS) isn't started. Linux's DPU and DP
  code is the reference; OpenBSD's `qcdrm(4)` does display only, on FDT.

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
- `vulkaninfo` aborts on `VK_KHR_display`: the msm node has no KMS.

## Performance (2026-09-29)

| Test | FreeBSD | Linux 7.0 (same board) |
|---|---|---|
| glmark2-es2 offscreen 800×600 | 6963 | — |
| vkmark headless 800×600 | 12025 | — |
| vkmark 1080p | 5446 | 4716 |
| glmark2 "heavy" 1080p | 2473 | not comparable |

- The GPU runs at its top operating point all the time (690 MHz). devfreq
  would save only power.
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
- libdrm assumes `cardN` ↔ `renderD(128+N)`. With sysfbdrm as card0 and msm
  as card1/renderD128 the mapping is wrong, but Mesa still works.
- Upstream Linux fixes to send: hangcheck `timer_delete_sync` on cleanup,
  freeing `pwrup_reglist`, and the `recover_worker` skip.
