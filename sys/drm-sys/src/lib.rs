// SPDX-License-Identifier: BSD-2-Clause

//! FreeBSD DRM/KMS bindings — the M1 ioctl surface for the
//! CPU/dumb-buffer scanout path.
//!
//! Binds the eleven ioctls `docs/design/drm-kms-bringup.md` §3 lists for
//! the M1 compositor: discovery (`getresources`, `getconnector`,
//! `getencoder`, `getcrtc`), dumb-buffer allocation (`create_dumb`,
//! `map_dumb`), framebuffer attachment (`addfb2`), modeset (`setcrtc`),
//! frame submission (`page_flip`), and teardown (`rmfb`,
//! `destroy_dumb`). Plus the `ioctl(2)` wrapper itself.
//!
//! The DRM_IOCTL_MODE_* kernel macros (libdrm headers) expand to BSD's
//! `_IOWR(...)` — not reachable from Rust FFI — so the binding goes
//! through `c/drm_shim.c`, which evaluates each macro at C-compile time
//! and exposes the result as a callable symbol. See
//! `drm-kms-bringup.md` §6 and the project's C-shim FFI convention.
//!
//! Struct types for the ioctl payloads (`drm_mode_card_res`,
//! `drm_mode_get_connector`, `drm_mode_create_dumb`, …) are a follow-up
//! increment — the compositor will add them as it starts to call each
//! ioctl. This first cut establishes the FFI's bones.
//!
//! **FreeBSD only.** Empty on every other host — see
//! `freebsd-capsicum-sys`.

// An FFI crate: `unsafe` is its purpose, and is confined to `freebsd`.
#![allow(unsafe_code)]

#[cfg(target_os = "freebsd")]
mod freebsd;

#[cfg(target_os = "freebsd")]
pub use freebsd::{
    abyss_drm_ioctl, abyss_drm_ioctl_mode_addfb2, abyss_drm_ioctl_mode_create_dumb,
    abyss_drm_ioctl_mode_destroy_dumb, abyss_drm_ioctl_mode_getconnector,
    abyss_drm_ioctl_mode_getcrtc, abyss_drm_ioctl_mode_getencoder,
    abyss_drm_ioctl_mode_getresources, abyss_drm_ioctl_mode_map_dumb,
    abyss_drm_ioctl_mode_page_flip, abyss_drm_ioctl_mode_rmfb, abyss_drm_ioctl_mode_setcrtc,
};
