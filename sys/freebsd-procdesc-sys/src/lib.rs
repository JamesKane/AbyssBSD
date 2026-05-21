// SPDX-License-Identifier: BSD-2-Clause

//! FreeBSD process-descriptor bindings — a `pdfork`-based [`spawn`].
//!
//! Binds the supervision primitive the broker uses for every component
//! (`docs/design/broker-and-transport.md` §5.3, §5.5): `pdfork` returns the
//! child as a *file descriptor*, which can be `kqueue`-monitored for the
//! child's exit and which kills the child when closed — no `SIGCHLD` race,
//! no pid reuse.
//!
//! [`spawn`] does the `pdfork`-then-`execve` inside a C shim, so no Rust
//! ever runs in the forked child (§6); the parent receives a [`Child`]
//! holding the process descriptor.
//!
//! **FreeBSD only.** Empty on every other host — see `freebsd-capsicum-sys`.

// An FFI crate: `unsafe` is its purpose, and is confined to `freebsd`.
#![allow(unsafe_code)]

#[cfg(target_os = "freebsd")]
mod freebsd;

#[cfg(target_os = "freebsd")]
pub use freebsd::{Child, SpawnOptions, spawn};
