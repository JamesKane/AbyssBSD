# Moving development to the Linux workstation

An audit taken on 2026-09-30, before development moved from the Mac. Each item
is either something the monorepo lacks or something that exists only on the
Mac. Tick items off, and delete this file once they're all done.

## 1. Submodule and import pins are behind

The monorepo was assembled from a Phase B snapshot, before Phase C (the
LinuxKPI platform bus, the component framework, runtime PM and platform IRQs).

- [ ] `src` → freebsd-src `radxa-dragon-q8b` **`85f6f47c54`** (pinned: `9fbc25e3a1`).
      Kernel `__FreeBSD_version` 1600032 (arm64 write-combining), plus the
      C3 event-timer handoff, rc power profiles, `qcom_adsp`, and
      `qcom_geni_i2c` + `ds13rtc` for the RTC, and SD in `sdhci_acpi`.
- [ ] `firmware` → drm-kmod-firmware `qcom` **`79f48aa`** (adds `qcomfw`,
      the Q8B's ADSP firmware).
- [ ] `kmod/drm-msm` → drm-msm-kmod **`fcb7371`** (imported up to `02f48c0`;
      missing everything since: Phase C, the msmfb display driver
      `fc3e136`..`349d5ea` DPMS `42228ff`, GPU devfreq `412bc43`, and the scan-out fixes `1e190da`..`0f23f29`). The msm code at `02f48c0` won't run against the
      Phase C kernel.
- [ ] `ports/` → freebsd-ports `freedreno` **`2e2e095be`** (copied from
      `d80cb373e`): drm-msm-kmod at `fcb7371`, PORTREVISION 17 (with the
      power_profile hook), and the new `sysutils/qcom-dsp-firmware-kmod`.
- [ ] Decide which copy of msm is canonical: `kmod/drm-msm`, or the
      standalone `JamesKane/drm-msm-kmod` repo that the port still fetches.
      Retire the other copy.

## 2. The ports overlay doesn't build what was tested

Board testing used local tarball overrides, which hid these problems:

- [ ] `graphics/drm-latest-kmod` is upstream's port unchanged:
  - it fetches `freebsd/drm-kmod` `drm_v6.12.85_3`, so no sysfbdrm and none
    of our busid or `dev_is_pci` fixes;
  - it has `ONLY_FOR_ARCHS=amd64`, so it's IGNOREd on aarch64 and
    `drm-msm-kmod`'s RUN_DEPENDS can't be met.

  Point it at the `kmod/drm` fork (`JamesKane/drm-kmod` `sysfbdrm`) and allow
  aarch64.
- [ ] `graphics/drm-msm-kmod`'s `GH_TUPLE` builds against upstream drm-kmod
      too. It should use the fork.
- [ ] `graphics/gpu-firmware-qcom-kmod` fetches `freebsd/drm-kmod-firmware`
      tag `20260929`, which doesn't exist: the fork's latest tag is
      `20260519`. Point it at `JamesKane/drm-kmod-firmware` `qcom` (`3c49873`)
      or tag the fork.
- [ ] Is the desktop packaged at all? Nothing in `ports/` builds it yet.

## 3. Work that exists only on the Mac

**freebsd-src (`~/Projects/OS/freebsd-src`):**
- [ ] Uncommitted Phase D work: `linux/delay.h` (`usleep_range` as a high
      resolution sleep with slack) and `linux/iopoll.h` (`(us>>2)+1 .. us`
      polling). Commit it or drop it.
- [ ] Local-only branch `q8b-upstream`: 15 commits on upstream/main, the
      series for Phabricator. Push it or `git bundle` it.
- [ ] Local-only branch `radxa-dragon-q8b-dt`: the parked DT work (a DTS
      build path, qcom_geni FDT).
- [ ] `submission/` (ignored): the Phabricator drafts, `NN-*.diff` + `NN-*.md`.

**drm-kmod (`~/Projects/OS/drm-kmod`):**
- [ ] Uncommitted `sysfbdrm/sysfbdrm_drv.c`: cacheable dumb buffers plus a
      cache clean/invalidate before the copy. This **reverses** `b8eccf55f8`
      (write-combining dumb BOs, which fixed stray pixels). Benchmark it and
      check for stray pixels before keeping it.

**libdrm (`~/Projects/OS/libdrm`, branch `freebsd-missing-node`):**
- [ ] 5 commits (`c228a1ab`, `21a37694`, `9f58d38e`, `b75122fe`, `9f89f9c5`),
      never pushed anywhere. `ports/graphics/libdrm/files/patch-xf86drm.c`
      carries their content (it matches), but upstreaming needs the branch.
      See [UPSTREAMING.md](UPSTREAMING.md).

**Mesa:**
- [ ] The two freedreno patches (ENODATA→ENOATTR in `msm_bo.c`,
      `fd_gettid()`) exist only as port files. There's no Mesa branch. Make
      one for upstreaming.

**Scripts (`~/Projects/OS/build/scripts`):**
- [ ] Import the build, image and test tooling as `tools/`, rewritten for
      Linux paths:
  - `mkimage.sh`, `build-full.sh`, `build-drm.sh`, `build-msm.sh`,
    `build-fw.sh`, `mkimage-amd64.sh`, `build-x86.sh`, `build-drm-amd64.sh`;
  - deploy and reload: `reload.sh`, `msmload.sh`, `bootdiag.sh`;
  - board tests: `heavy.sh`, `soak.sh`, `tcx-bench.sh`, `shot.sh`, the
    `sway-*.conf` files;
  - `local.lua` (the stick → NVMe root handoff).

  The test programs (`msmtest.c`, `msmfault.c`, `egltest.c`) are already in
  `kmod/drm-msm/tools/`.
- [ ] **Do not import** the Linux GPL reference copies in that directory:
      `stmmac_*.c`, `dwxgmac2_*.c`, `hwif.c`, `pcs-xpcs.c`, `qca808x.c`,
      `pinctrl-sc8280xp.c`, `mmc_core.c`, `qcdrm.c` (OpenBSD).

**Board artifacts (Claude scratchpad under `/private/tmp`, session `0ae0fc29…`;
macOS deletes old files in /tmp):**
- [x] ACPI tables, the firmware DT, Ubuntu's system info and FreeBSD's
      register dumps: copied (with serials redacted) to
      [boards/radxa-dragon-q8b/dumps/](boards/radxa-dragon-q8b/dumps/README.md).
- [ ] `series/` (`build_series.py`, `mkdrafts.py`, `bisect_build.sh`,
      `NN.msg`): the tooling that builds the upstream series.
- [ ] `img2/files/`: the image's extra files (`authorized_keys`, and a
      `powerd` built from the branch).
- [ ] `bench/`, `shots/`: benchmark results and screenshots (optional).

**Claude memory:**
- [ ] The project knowledge in Claude's memory is keyed to the Mac's
      freebsd-src path. Its durable content is now in `docs/` and `CLAUDE.md`.
      The ssh known_hosts files for the board live in the scratchpad; set up
      new ones.

## 4. Monorepo fixes made necessary by the move

- [x] The desktop VM harness defaults `ABYSS_VM_HOME` to inside the monorepo
      (`desktop/..`), and `live-image.sh` defaults its output there too. The
      root `.gitignore` catches them, but change the defaults. *Done: the VM
      home is `../abyss-swift-vm` beside the monorepo, and a guest-built
      medium defaults to `~/abyss-live.img`, where `live-medium.sh` reads it.*
- [x] `desktop/README.md` and `desktop/docs/STATUS.md` still call
      "`../AbyssBSD` (a Rust DE)" the design source. That path is now the
      monorepo; the Rust sibling needs a new name or path. *Done: it is
      checked out as `AbyssBSD-old` beside the monorepo.*
- [x] `desktop/docs/STATUS.md` says both "Phase 14 is complete" and "Phase 14
      is next". The U.x and T.x work is recorded only in `API-STUDY.md`.
      *Done: STATUS points at `desktop/docs/BACKLOG.md`, where U.x and T.x
      are recorded, and at §5 here.*

## 5. Not yet started, needed to ship

- [x] **Base version: FreeBSD `main`** (16.0-CURRENT), decided 2026-09-30.
      `src/` and the Q8B image already use it. What's left:
  - [x] The desktop VM harness (`desktop/abyss/vm/config.sh`) boots a
        15.0-RELEASE amd64 cloud image. Move it to a 16.0-CURRENT snapshot
        VM image, or to one built from `src/`. *Done 2026-09-30: a pinned
        upstream snapshot (20260928, `main-n289650`), its sets fetched and
        checksummed, the base held there; `--vm --live --full` green on it.
        An image built from `src/` is Phase 17's pipeline.*
  - [x] `desktop/docs/PLAN.md` still says "a FreeBSD `releng/15.0` fork".
  - [ ] Check that `lang/swift6` builds and runs on 16-CURRENT, on both
        amd64 and aarch64. *amd64 done: ports' `swift6` 6.3.3 builds and tests
        the desktop on the 16 guest. aarch64 built and tested on the Q8B
        2026-10-01 with the port extended in our ports fork (board README,
        "Swift 6.3.3 on aarch64"). Left: commit the port change, and host
        the aarch64 bootstrap or make our own.*
- [x] **wlroots.** The desktop binds `wlroots-0.19` (`desktop/Package.swift`,
      `de/cwlrootssys/module.modulemap`, the VM seed's `wlroots019`). Ports
      and the Q8B are on wlroots 0.20 (sway 1.12). Upgrade `undertow` to
      0.20, check the 0.19 → 0.20 API changes, and update the Linux dev
      host to match. *Done 2026-09-30: 0.20.2 on both platforms; the one
      change the compiler could not see is desktop HANDOFF §2.94.*
- [ ] A release pipeline: `buildworld` + `buildkernel` from `src/`, a
      poudriere jail made from that world, the bulk build of the overlay,
      and images for arm64 (Q8B) and amd64. Today's Q8B image uses a stock
      snapshot userland.
- [ ] The desktop on the Q8B. So far it has been tested only on amd64 (VMs
      and the i7/RX 6750 XT). Check that `lang/swift6` builds for aarch64,
      then run the desktop on the Q8B. *2026-10-01: builds and tests on the
      Q8B, and runs on the display (msmfb + GLES on the Adreno), started by
      hand. Left: start it at boot, and package it.*
