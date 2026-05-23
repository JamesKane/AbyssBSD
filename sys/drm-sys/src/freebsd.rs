// SPDX-License-Identifier: BSD-2-Clause

//! FreeBSD-only DRM/KMS FFI surface.
//!
//! Eleven `extern const unsigned long` ioctl numbers (one per
//! `drm-kms-bringup.md` §3 ioctl), plus `abyss_drm_ioctl` — the wrapper
//! around `ioctl(2)` the C shim exposes so Rust never needs libc
//! bindings of its own.

use core::ffi::{c_int, c_ulong, c_void};

unsafe extern "C" {
    /// `DRM_IOCTL_MODE_GETRESOURCES` — enumerate CRTCs, connectors,
    /// encoders, fbs.
    pub static abyss_drm_ioctl_mode_getresources: c_ulong;
    /// `DRM_IOCTL_MODE_GETCONNECTOR` — per connector, modes and
    /// connection state.
    pub static abyss_drm_ioctl_mode_getconnector: c_ulong;
    /// `DRM_IOCTL_MODE_GETENCODER` — encoder ↔ CRTC compatibility.
    pub static abyss_drm_ioctl_mode_getencoder: c_ulong;
    /// `DRM_IOCTL_MODE_GETCRTC` — current CRTC state.
    pub static abyss_drm_ioctl_mode_getcrtc: c_ulong;

    /// `DRM_IOCTL_MODE_CREATE_DUMB` — a CPU-mappable buffer.
    pub static abyss_drm_ioctl_mode_create_dumb: c_ulong;
    /// `DRM_IOCTL_MODE_MAP_DUMB` — get an `mmap` offset for a dumb
    /// buffer.
    pub static abyss_drm_ioctl_mode_map_dumb: c_ulong;

    /// `DRM_IOCTL_MODE_ADDFB2` — wrap a dumb buffer (or dmabuf, M2) in
    /// a framebuffer object.
    pub static abyss_drm_ioctl_mode_addfb2: c_ulong;
    /// `DRM_IOCTL_MODE_SETCRTC` — bind a framebuffer to a CRTC at a
    /// chosen mode.
    pub static abyss_drm_ioctl_mode_setcrtc: c_ulong;
    /// `DRM_IOCTL_MODE_PAGE_FLIP` — atomic page-flip; the kernel
    /// queues a completion event on the fd.
    pub static abyss_drm_ioctl_mode_page_flip: c_ulong;

    /// `DRM_IOCTL_MODE_RMFB` — release a framebuffer.
    pub static abyss_drm_ioctl_mode_rmfb: c_ulong;
    /// `DRM_IOCTL_MODE_DESTROY_DUMB` — release a dumb buffer.
    pub static abyss_drm_ioctl_mode_destroy_dumb: c_ulong;

    /// Issue a DRM ioctl. Returns `0` on success, `-1` with `errno` set
    /// on failure — the kernel's `ioctl(2)` contract.
    ///
    /// # Safety
    ///
    /// `arg` must point at a struct of the type the kernel expects for
    /// `req` (see the per-ioctl struct types — added in a follow-up
    /// increment), and `fd` must be an open DRM device.
    pub fn abyss_drm_ioctl(fd: c_int, req: c_ulong, arg: *mut c_void) -> c_int;
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Smoke test: the eleven ioctl constants link and are non-zero.
    /// `_IOWR(...)` always packs the direction and a non-zero command,
    /// so a zero here would mean the shim didn't compile against the
    /// real DRM headers — a clear signal of a broken FFI bootstrap.
    #[test]
    fn ioctl_constants_link_and_are_nonzero() {
        // SAFETY: reading a shim-defined `const unsigned long` whose
        // address is resolved at link time. The values are immutable.
        unsafe {
            assert_ne!(abyss_drm_ioctl_mode_getresources, 0);
            assert_ne!(abyss_drm_ioctl_mode_getconnector, 0);
            assert_ne!(abyss_drm_ioctl_mode_getencoder, 0);
            assert_ne!(abyss_drm_ioctl_mode_getcrtc, 0);
            assert_ne!(abyss_drm_ioctl_mode_create_dumb, 0);
            assert_ne!(abyss_drm_ioctl_mode_map_dumb, 0);
            assert_ne!(abyss_drm_ioctl_mode_addfb2, 0);
            assert_ne!(abyss_drm_ioctl_mode_setcrtc, 0);
            assert_ne!(abyss_drm_ioctl_mode_page_flip, 0);
            assert_ne!(abyss_drm_ioctl_mode_rmfb, 0);
            assert_ne!(abyss_drm_ioctl_mode_destroy_dumb, 0);
        }
    }

    /// Smoke test: the eleven ioctl numbers are distinct.
    /// `_IOWR(group, nr, type)` packs `nr` into a sub-field; two
    /// different `nr`s must yield two different ioctl numbers.
    #[test]
    fn ioctl_constants_are_distinct() {
        let all = unsafe {
            [
                abyss_drm_ioctl_mode_getresources,
                abyss_drm_ioctl_mode_getconnector,
                abyss_drm_ioctl_mode_getencoder,
                abyss_drm_ioctl_mode_getcrtc,
                abyss_drm_ioctl_mode_create_dumb,
                abyss_drm_ioctl_mode_map_dumb,
                abyss_drm_ioctl_mode_addfb2,
                abyss_drm_ioctl_mode_setcrtc,
                abyss_drm_ioctl_mode_page_flip,
                abyss_drm_ioctl_mode_rmfb,
                abyss_drm_ioctl_mode_destroy_dumb,
            ]
        };
        for i in 0..all.len() {
            for j in (i + 1)..all.len() {
                assert_ne!(
                    all[i], all[j],
                    "ioctl numbers at indices {i} and {j} collide ({:#x})",
                    all[i]
                );
            }
        }
    }
}
