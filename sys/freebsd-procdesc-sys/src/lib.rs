// SPDX-License-Identifier: BSD-2-Clause

//! FreeBSD process-descriptor bindings — `pdfork`, `pdkill`, `pdgetpid`.
//!
//! Binds the supervision primitive the broker uses for every component
//! (`docs/design/broker-and-transport.md` §5.5): `pdfork` returns the
//! child as a *file descriptor*, which can be `kqueue`-monitored for the
//! child's exit and which kills the child when closed — no `SIGCHLD` race,
//! no pid reuse.
//!
//! The process-descriptor calls are ordinary libc functions, so this is a
//! direct `extern` block — no C shim (§6).
//!
//! **FreeBSD only.** Empty on every other host — see `freebsd-capsicum-sys`.

// An FFI crate: `unsafe` is its purpose, and is confined to `freebsd`.
#![allow(unsafe_code)]

#[cfg(target_os = "freebsd")]
mod freebsd;

#[cfg(target_os = "freebsd")]
pub use freebsd::{Fork, fork, kill, pid_of};
