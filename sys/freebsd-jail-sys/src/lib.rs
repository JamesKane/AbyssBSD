// SPDX-License-Identifier: BSD-2-Clause

//! FreeBSD jail bindings — `jail_set`, `jail_attach`, `jail_remove`.
//!
//! Binds the isolation primitive the broker puts every component inside
//! (`docs/design/broker-and-transport.md` §5.3). The jail syscalls are
//! ordinary libc functions, so this is a direct `extern` block — no C shim
//! is needed (§6: the shim is required only where the kernel API is built
//! from C macros, as Capsicum's is).
//!
//! **FreeBSD only.** Empty on every other host — see `freebsd-capsicum-sys`
//! for why the `sys/*` crates are shaped this way.

// An FFI crate: `unsafe` is its purpose, and is confined to `freebsd`.
#![allow(unsafe_code)]

#[cfg(target_os = "freebsd")]
mod freebsd;

#[cfg(target_os = "freebsd")]
pub use freebsd::{JailSpec, attach, remove};
