# Upstreaming

AbyssBSD ships the board and GPU work first. Everything that isn't
AbyssBSD-specific is meant to go upstream over time: working, clean
solutions first, then submission.

| Change | Upstream | State | Carried here as |
|---|---|---|---|
| Q8B board support (15 commits, below) | FreeBSD src, via Phabricator | Series built; drafts written; not submitted | `src` branch `radxa-dragon-q8b` |
| LinuxKPI: platform bus, component, runtime PM, platform IRQs/IRQF, devres groups, `of_node`/`platform_data`, hrtimer ABS, WC memattr, io copies, `dma_map_sg`, `SZ_*G`, lindebugfs leak | FreeBSD src (LinuxKPI maintainers want shims upstreamed via Phabricator) | Committed and validated on arm64 and amd64; not submitted | `src` |
| GPU libraries: `qcom_gpucc`, `qcom_scm`, `qcom_cmd_db`, `qcom_smmu`, `acpi_iort_named_smmu` | FreeBSD src | Committed; not in the series yet | `src` |
| drm-kmod: sysfbdrm, non-PCI bus IDs, `dev.drm.N.busid`, minor alias/sysctl release, `DRM_DEV_ERROR`/`INFO` on FreeBSD, `dev_is_pci` guard | freebsd/drm-kmod (GitHub PRs) | Pushed to the fork; no PRs opened | `kmod/drm` (branch `sysfbdrm`) |
| msm firmware kmods (`msmkmsfw`) | freebsd/drm-kmod-firmware | Pushed to the fork; no PR | `firmware` (branch `qcom`) |
| msm driver | A "drm-kmod-gpl"-style repository, if one appears (drm-kmod PR #499 discussion); otherwise a port | Ours | `kmod/drm-msm` |
| libdrm: FreeBSD platform devices, missing nodes, `dev.drm.N.busid` | mesa/drm on gitlab.freedesktop.org | **Blocked:** new accounts can't fork | `ports/graphics/libdrm` patch |
| Mesa: freedreno on FreeBSD (`ENOATTR`, `fd_gettid`) | mesa/mesa | Not started; no branch exists | `ports/graphics/mesa-dri` patches |
| Ports: freedreno/Turnip on aarch64, `drm-msm-kmod`, `gpu-firmware-qcom-kmod` | freebsd-ports | Waits on the above | `ports/` |
| Linux msm: hangcheck `timer_delete_sync`, free `pwrup_reglist`, `recover_worker` skip | Linux (dri-devel) | Not started | `kmod/drm-msm` |

## The FreeBSD series (`q8b-upstream`, 15 commits)

1. uart access width
2. GENI UART
3. tcx (and GENERIC)
4. acpi_thermal
5. qcom_tsens
6. cpufreq DOMAIN flag
7. qcom_epss
8. powerd
9. `psci_cpu_suspend`
10. `start_mmu` local TLBI
11. C3STOP + gt_mem
12. `cpu_suspend`
13. acpi_cpu `_LPI`
14. xhci URS
15. DWC3 threshold

Every commit builds for arm64 with modules; commits 4, 6 and 13 also build
for amd64, and commit 8 passes an x86 syntax check of powerd. Every commit
is clean under checkstyle9, apart from `__asm __volatile(` false positives.
The branch and the drafts (`submission/`) are on the Mac only: see
MIGRATION.md §3.

## Before sending anything

- **Sign-off.** A `Signed-off-by` (DCO) is the author's personal
  certification. Never add one on their behalf.
- **AI assistance.** Commits carry a `Co-Authored-By: Claude` trailer.
  dri-devel, Mesa and FreeBSD each have their own policies on AI-assisted
  contributions. Check the current policy and decide how to present it
  before each submission.
- **libdrm routes:**
  1. File freedesktop's "User verification" issue to unlock forking, then
     open a merge request on mesa/drm.
  2. Or send it to dri-devel@lists.freedesktop.org with
     `git send-email`, subject prefix `PATCH libdrm`. It needs a
     Reviewed-by before merge.
