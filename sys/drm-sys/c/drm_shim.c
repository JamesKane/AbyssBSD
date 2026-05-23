/* SPDX-License-Identifier: BSD-2-Clause */
/*
 * DRM/KMS C shim for drm-sys.
 *
 * The DRM_IOCTL_MODE_* macros (libdrm — /usr/local/include/libdrm/drm.h)
 * expand to BSD's _IOWR(...), which cannot be evaluated from Rust FFI.
 * This shim evaluates each ioctl number at C-compile time and exposes
 * it as a callable C symbol. The closed M1 set is exactly the eleven
 * ioctls of docs/design/drm-kms-bringup.md §3.
 *
 * abyss_drm_ioctl wraps ioctl(2) so Rust never needs libc bindings of
 * its own — the entire syscall surface goes through one shim function.
 *
 * Compiled by build.rs on FreeBSD only.
 */
#include <sys/ioctl.h>

#include <libdrm/drm.h>
#include <libdrm/drm_mode.h>

/* The eleven M1 ioctls — drm-kms-bringup.md §3, in startup order. */

const unsigned long abyss_drm_ioctl_mode_getresources = DRM_IOCTL_MODE_GETRESOURCES;
const unsigned long abyss_drm_ioctl_mode_getconnector = DRM_IOCTL_MODE_GETCONNECTOR;
const unsigned long abyss_drm_ioctl_mode_getencoder  = DRM_IOCTL_MODE_GETENCODER;
const unsigned long abyss_drm_ioctl_mode_getcrtc     = DRM_IOCTL_MODE_GETCRTC;

const unsigned long abyss_drm_ioctl_mode_create_dumb  = DRM_IOCTL_MODE_CREATE_DUMB;
const unsigned long abyss_drm_ioctl_mode_map_dumb     = DRM_IOCTL_MODE_MAP_DUMB;

const unsigned long abyss_drm_ioctl_mode_addfb2       = DRM_IOCTL_MODE_ADDFB2;
const unsigned long abyss_drm_ioctl_mode_setcrtc      = DRM_IOCTL_MODE_SETCRTC;
const unsigned long abyss_drm_ioctl_mode_page_flip    = DRM_IOCTL_MODE_PAGE_FLIP;

const unsigned long abyss_drm_ioctl_mode_rmfb         = DRM_IOCTL_MODE_RMFB;
const unsigned long abyss_drm_ioctl_mode_destroy_dumb = DRM_IOCTL_MODE_DESTROY_DUMB;

/*
 * Issue the DRM ioctl. Returns 0 on success, -1 on failure with errno set,
 * matching the kernel's ioctl(2) contract; the caller decides whether to
 * retry on EINTR or fail.
 */
int
abyss_drm_ioctl(int fd, unsigned long req, void *arg)
{
	return ioctl(fd, req, arg);
}
