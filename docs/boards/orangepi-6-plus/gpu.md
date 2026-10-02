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

## Versions

drm-kmod's DRM core is Linux 6.13; it has `drm_gpuvm`, `drm_exec` and the
GPU scheduler panthor needs. Linux added the G720 to panthor in 6.18, but
only as a model name and a firmware path: the CSF code it runs is 6.13's.
So panthor comes from Linux 6.13, as msm did, with that addition.

drm-kmod lacks the GEM shmem helper (`drm_gem_shmem_helper.c`), which
panthor's GEM is built on, and LinuxKPI has no io-pgtable (Arm LPAE page
tables, which panthor's MMU code uses): both come with the port, as
msm's glue provided io-pgtable on the Q8B.

Userspace: the board's Mesa 26.2 package already has `panthor_dri.so`
(Gallium panfrost on the panthor kernel driver); Vulkan (panvk) would
need the mesa ports' driver list extended, as turnip was for the Q8B.

## Phases

1. **Power and probe.** A test module powers domain 21 through SCMI over
   SMC and reads GPU_ID, the features and the present masks, to compare
   with Linux's.
2. **The port.** `drm-panthor-kmod`: panthor from Linux 6.13 (+ G720
   name and firmware), the shmem helper, io-pgtable-arm; glue attaching to
   `CIXH5000`, powering the GPU, interrupts, firmware loading, runtime PM
   and DVFS stubs (a fixed clock first). Goal: the firmware boots and a
   render node appears.
3. **Mesa.** GL through `panthor_dri.so`; then panvk.
4. **Desktop.** sway rendering on the GPU and scanning out through
   `sysfbdrm` (as msm with `sysfbdrm` on the Q8B); then DVFS through SCMI
   performance.
