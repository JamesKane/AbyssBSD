# AbyssBSD

A FreeBSD distribution: a fork of FreeBSD with new hardware support, and a
desktop written in Swift.

| Path | What |
|------|------|
| `desktop/` | the Swift desktop, its session, and its build/test VM harness |
| `kmod/drm-msm/` | the DRM driver for Qualcomm Adreno GPUs |
| `ports/` | a poudriere overlay: `poudriere bulk -O abyss ...` |
| `src/` | submodule: the FreeBSD fork |
| `kmod/drm/` | submodule: the drm-kmod fork |
| `firmware/` | submodule: the drm-kmod-firmware fork |

`git submodule update --init src kmod/drm` fetches the source trees. Leave
`firmware/` out on a case-insensitive filesystem (macOS's default): it holds
files whose names differ only by case.
