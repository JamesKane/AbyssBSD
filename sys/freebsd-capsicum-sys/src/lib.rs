// SPDX-License-Identifier: BSD-2-Clause

//! FreeBSD Capsicum bindings — `cap_enter` and capability rights.
//!
//! Binds the kernel object-capability sandbox the broker depends on
//! (`docs/design/broker-and-transport.md` §3.3, §5.4). Capsicum's
//! capability-rights API (`cap_rights_init`, `cap_rights_set`) is built
//! from C macros that cannot be called over Rust's FFI, so the binding
//! goes through a small C shim (`c/capsicum_shim.c`) — see §6.
//!
//! **FreeBSD only.** On every other host this crate is empty. It exists so
//! the workspace layout is whole and the macOS development bed still
//! builds; the binding is compiled and verified on FreeBSD when Phase 4's
//! FreeBSD work begins (`STATUS.md`, `ROADMAP.md` §4).

// An FFI crate: `unsafe` is its purpose, and is confined to `freebsd`.
#![allow(unsafe_code)]

#[cfg(target_os = "freebsd")]
mod freebsd;

#[cfg(target_os = "freebsd")]
pub use freebsd::{CapRights, Rights, cap_enter};
