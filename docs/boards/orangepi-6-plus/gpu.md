# GPU: Mali-G720 Immortalis with panthor

Plan and findings (2026-10-02). The approach is the Q8B's for msm
([../radxa-dragon-q8b/](../radxa-dragon-q8b/)): Linux's DRM driver ported
through LinuxKPI on drm-kmod's DRM core, in a repository of its own
(`drm-panthor-kmod`, GPL, out of tree), with FreeBSD glue (BSD-2-Clause)
for what Linux gets from devicetree, genpd and SCMI.

## The hardware, as Linux on the board sees it

- Mali-G720-Immortalis, GPU_ID `0xc870` (architecture 12.8), 10 shader
  cores (`shader_present 0x550555`), one L2, a CSF GPU: Arm's firmware
  (`arm/mali/arch12.8/mali_csffw.bin`, linux-firmware, interface v3.13)
  runs the command stream scheduler.
- ACPI `\_SB.GPU` (`CIXH5000`): registers at `0x15000000` (64 KB) and
  `0x15010000` (4.5 MB); three level interrupts, GSIV `0x10D`-`0x10F`
  (job, MMU, GPU); `_CCA` 1; `_DSD` names an SCMI performance domain for
  DVFS. No SMMU in front of it: the GPU has its own MMU.
- Power: TF-A powers the GPU domain (SCMI power domain 21) and opens the
  interconnect to non-secure access when asked through SCMI
  POWER_STATE_SET over SMC: function `0xc2000001`, shared memory at
  `0x84380000`. Nothing answers at the GPU's registers before that.
- Coherency: the DSDT says coherent, but CIX's kernel treats the GPU as
  non-coherent (the display controller reads DRAM without snooping) and
  maps shared buffers non-cacheable, with the GPU on ACE-Lite.

Linux (CIX's and the Sky1-Linux kernels) runs it with upstream `panthor`
plus patches: ACPI probe, the SCMI-over-SMC power-on, SCMI performance
domain DVFS, ACE-Lite coherency with non-cacheable buffers, and the
`_CCA` override.

## Bring-up sequence (phase 1, done 2026-10-02)

Found by a test module, against CIX's Linux patches, the DSDT and a dump of
Linux running it. In this order; a GPU register read before all five hangs
or faults the bus (SError), and the board then needs a power cycle:

1. **Power domain:** SCMI POWER_STATE_SET, domain 21, over TF-A's SMC
   (function `0xc2000001`, shared memory `0x84380000`).
2. **Clocks:** SCMI CLOCK_CONFIG_SET enable for `gpu_top` (`0x1F`) and
   `gpu_core` (`0x20`), both off at boot. Not through the firmware's AML
   (`\_SB.PMMX.CLK*`): that SCMI agent answers NOT_FOUND for every clock.
   Through the agent Linux uses, ACPI `CIXHA006`: shared memory at the start
   of CIX mailbox 6 (`0x06590000`, `CIXHA004`), doorbell at `+0x80`
   (`DB_ACK`), polled on the channel-free bit; mailbox 7 (`0x065a0000`)
   carries the platform's messages. CLOCK_ATTRIBUTES confirms the names and
   the enabled bit. (SCMI v2.0 `cix:cix`: protocols 0x13 perf, 0x14 clock.)
3. **Power resource:** `\_SB.GPUP.PPRS._ON` (AML): RCSU `0x218` gets
   `0x1000 | 0xFFC` (bit 12 is what `_STA` reads as on), and the GPU's
   memories are repaired (`DMRP`).
4. **Reset:** reset controller `0x16000000`, active low: `0x400` bit 6
   (GPU) pulsed low, `0x800` bit 28 (GPU RCSU) already high.
5. **Q-channel clock gating:** RCSU `0x218` bit 0.

ACPI resource 0 (`0x15000000`) is CIX's RCSU, not the GPU: only `0x218` and
`0x304` (harvested cores; `0xf` here: none) may be read. The GPU is
resource 1 (`0x15010000`). Read then: GPU_ID `0xc8700008`, L2 `0x8130306`,
tiler `0x809`, mem `0x301`, MMU `0x2830`, AS `0xff`, CSF `0x4200412`,
shader_present `0x550555`: as Linux reports.

## Versions

panthor comes from Linux 7.0 (since 2026-10-02; 6.13's rendered single GL
clients but faulted under sway, predating the G720 and many fixes). Its GPU
scheduler and `drm_gpuvm` are newer than drm-kmod's (Linux 6.13), so the
module builds Linux 7.0's own, their symbols prefixed `panthor_`; it also
brings the GEM shmem helper, which drm-kmod lacks, and io-pgtable-arm, which
LinuxKPI lacks.

Coherency is as CIX's Linux has it (their patch "add ACE-Lite coherency and
NC memattr fallback"): ACE-Lite on the bus, the GPU's memory mappings
non-cacheable (it has no IOMMU), the CPU's write-combined. The load-time
switches `hw.panthor.sky1_ace_lite` and `hw.panthor.sky1_gpu_nc` turn them
off, for comparison; with the GPU's memory cacheable, jellyfish runs no
faster.

Userspace: the board's Mesa 26.2 package already has `panthor_dri.so`
(Gallium panfrost on the panthor kernel driver); Vulkan (panvk) would
need the mesa ports' driver list extended, as turnip was for the Q8B.

## Phases

1. **Power and probe.** A test module powers domain 21 through SCMI over
   SMC and reads GPU_ID, the features and the present masks, to compare
   with Linux's.
2. **The port** (done 2026-10-02: the CSF firmware boots, interface v3.13
   and the same build as Linux's, `/dev/dri/renderD128` appears; repository
   `drm-panthor-kmod`). `drm-panthor-kmod`: panthor from Linux 6.13 (+ G720
   name and firmware), the shmem helper, io-pgtable-arm; glue attaching to
   `CIXH5000`, powering the GPU, interrupts, firmware loading, runtime PM
   and DVFS stubs (a fixed clock first). Goal: the firmware boots and a
   render node appears.
3. **Mesa** (GL done 2026-10-02: GLES 3.1, Mali-G720 MC10). GL through
   `panthor_dri.so`; then panvk.
4. **Desktop** (sway on the GPU, 2026-10-02). sway rendering on the GPU and
   scanning out through `sysfbdrm` (as msm with `sysfbdrm` on the Q8B); then
   DVFS through SCMI performance. It took two LinuxKPI fixes: fault handlers
   were given a `pgoff` of 0 (Linux 7.0's shmem helper finds the page by it),
   and every interrupt ran in the network epoch, so a threaded handler that
   slept (panthor's MMU fault handler) panicked.
5. **DVFS** (done 2026-10-08). The GPU's `_DSD` names SCMI performance
   domain 0 (`gpu_core`: 72, 216, 350, 600, 800, 1000 MHz; the firmware
   leaves it at 1000). panthor's devfreq is redone without Linux's devfreq
   and OPP cores, the same policy (`simple_ondemand`, 45/5, every 50 ms)
   over `sky1_scmi`'s performance protocol. Idle, the GPU drops to 72 MHz;
   glmark2 takes it to 1000. `dev.panthor.0.freq_fixed` pins a level.

## Performance

glmark2 jellyfish, 800x600 under sway, as on the Q8B: 711 FPS as FreeBSD
places the work, 2,600 with glmark2 and sway on the big cores. FreeBSD's
scheduler does not tell the Cortex-A720s (CPUs 0-1, 6-11) from the A520s
(2-5) and ran both on small cores. Until it does, `/usr/local/bin/bigcores`
lists the big cores from the boot messages and the desktop runs under
`cpuset -l "$(bigcores)"` (an alias for `sway` in the user's `.profile`).
The Q8B managed about 5,800: even pinned, glmark2 keeps a big core 64% busy,
so the rest is per-frame CPU work, not yet profiled.
