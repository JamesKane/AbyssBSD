# AbyssBSD

**A FreeBSD for people who want a Mac-style desktop, not a handbook.**

AbyssBSD is FreeBSD with a complete desktop on top: a faithful clone of
Mac OS X 10.2 "Jaguar" Aqua, written in Swift 6 and running on Wayland on our
own compositor. It comes with a graphical installer and runs on a range of
machines, including Arm boards. The pinstripes, gel buttons, global menu bar
and magnifying Dock are all there, but the target is the look, not 10.2's
feature set. Underneath it's still FreeBSD: its ports, ZFS, jails and
Capsicum.

What it stands for:

- **GUI over TUI.** Every "how do I do X" has a graphical answer: files,
  network, sound, displays, updates. You shouldn't have to edit `rc.conf`
  to use the machine.
- **WIMP first, keyboard second.** Applications publish their menus to one
  global menu bar, so every command can be found with a mouse and then bound
  to a key. GTK and Qt applications take part too.
- **Windows stay where you put them.** No tiling. Instead of automatic layout
  there are workspaces (Islands), window sets (Shoals) and an Exposé
  equivalent (Ebb).
- **Capabilities, not permissions.** Portals give applications file
  descriptors, not paths. Agents run in jails and can reach only what a
  person gave them, with no stream of Allow/Deny pop-ups.
- **It just works.** The installer turns a blank disk into a running desktop
  on a range of hardware, not on one lucky machine. AbyssBSD tracks FreeBSD's
  package repositories and adds only what it wrote plus the minimum patched
  upstream code. The system and its configuration are updated with one
  command, and boot environments make that safe.

**New hardware, upstream-bound.** Board support starts with the Radxa Dragon
Q8B (Qualcomm SC8280XP): the serial console, Ethernet, USB, thermal sensors,
CPU frequency scaling and deep idle, plus an accelerated GPU and a native
display driver with the monitor's modes and hotplug. The GPU uses Linux's
msm DRM driver ported to FreeBSD, with Mesa's freedreno for OpenGL ES and
Turnip for Vulkan. The board work goes to FreeBSD, drm-kmod, libdrm and
Mesa over time. This fork is where it gets shipped first.

The work is in progress. The design is argued in
[desktop/docs/PRODUCT.md](desktop/docs/PRODUCT.md), the roadmap is
[desktop/docs/PLAN.md](desktop/docs/PLAN.md), and the current state is
[desktop/docs/STATUS.md](desktop/docs/STATUS.md).

## Layout

| Path | What |
|------|------|
| `docs/` | [building on Linux](docs/BUILDING.md), [board notes](docs/boards/radxa-dragon-q8b/README.md), [upstreaming](docs/UPSTREAMING.md) |
| `desktop/` | the Swift desktop, its session, and its build/test VM harness |
| `kmod/drm-msm/` | the DRM driver for Qualcomm Adreno GPUs |
| `ports/` | a poudriere overlay: `poudriere bulk -O abyss ...` |
| `src/` | submodule: the FreeBSD fork |
| `kmod/drm/` | submodule: the drm-kmod fork |
| `firmware/` | submodule: the drm-kmod-firmware fork |

`git submodule update --init src kmod/drm firmware` fetches the source trees.
Develop on a case-sensitive filesystem: `firmware/` holds files whose names
differ only by case. See [docs/BUILDING.md](docs/BUILDING.md).
