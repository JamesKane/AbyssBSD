# AbyssBSD: notes for agents

AbyssBSD is a FreeBSD distribution: a fork of FreeBSD `main` (16.0-CURRENT)
with new hardware support (starting with the Radxa Dragon Q8B), and a Mac OS X 10.2-style
desktop written in Swift 6 on Wayland. See [README.md](README.md).

## Where things are

| Need | Read |
|---|---|
| Build anything on Linux | [docs/BUILDING.md](docs/BUILDING.md) |
| What's still missing after leaving the Mac | [docs/MIGRATION.md](docs/MIGRATION.md) |
| Q8B hardware facts, status, hazards | [docs/boards/radxa-dragon-q8b/](docs/boards/radxa-dragon-q8b/README.md), **[lessons.md](docs/boards/radxa-dragon-q8b/lessons.md) first** |
| Orange Pi 6 Plus (CIX Sky1) survey and bring-up strategy | [docs/boards/orangepi-6-plus/](docs/boards/orangepi-6-plus/README.md) |
| What goes upstream, and the rules for sending it | [docs/UPSTREAMING.md](docs/UPSTREAMING.md) |
| Desktop design, roadmap, status, traps | `desktop/docs/`: PRODUCT, PLAN, STATUS, HANDOFF |
| The GPU driver's glue | `kmod/drm-msm/README.md` |

## Repositories

- `src/` is a submodule: `JamesKane/freebsd-src`, branch `radxa-dragon-q8b`.
- `kmod/drm/` is `JamesKane/drm-kmod`, branch `sysfbdrm`.
- `firmware/` is `JamesKane/drm-kmod-firmware`, branch `qcom`.

Commit in the submodule, push it, then bump the pin here. In those
repositories `origin` is the fork and `upstream` is FreeBSD; in drm-kmod
and firmware the fork remote is named `fork`.

## Rules

- **Ask before pushing** any repository, and before force-pushing ever.
- **Linux code is reference only.** New FreeBSD code is a BSD-licensed
  rewrite. GPL code (adapted from Linux) lives only in `kmod/drm-msm`, which
  records its licences in `LICENSES/`. Never copy Linux reference sources
  into the tree.
- **No message bus.** ADE's IPC is `CurrentIPC`. Foreign applications that
  speak D-Bus get a **bridge** in Swift that answers only for ADE's own
  services, never a bus, and never `dbus-daemon`
  ([PRODUCT §5.6](desktop/docs/PRODUCT.md)).
- **"Nothing special"** on the board: stock GENERIC and an empty
  `loader.conf`. A board-specific setting is a driver bug.
- **Bumping `__FreeBSD_version`** (LinuxKPI KBI changes) means deploying the
  full kernel with all its modules, and rebuilding drm-kmod and msm.
- **LinuxKPI changes are checked on amd64 with amdgpu** as well as on the
  Q8B.
- **On the board, read before experimenting.** Hangs cost power cycles.
  Several SMMU writes reset the SoC outright; they're listed in
  `lessons.md`.
- Keep build trees, images and VM disks outside the monorepo.
- Commit messages follow FreeBSD style: `area: Imperative summary`, then a
  wrapped body. The desktop uses its own phase-tagged style (`P14.3a: …`).
