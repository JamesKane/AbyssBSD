// SPDX-License-Identifier: BSD-2-Clause

//! AbyssBSD component bootstrap — the startup shim every component runs.
//!
//! A component is spawned by the broker holding one descriptor: its
//! bootstrap socket, at fd 3 (`docs/design/broker-and-transport.md` §5.3).
//! [`enter`] is the first thing a component does — it receives the
//! bootstrap bundle off that socket and then enters Capsicum capability
//! mode, after which the process can name nothing it does not already
//! hold (§5.4). Everything the component is allowed to do, it does with
//! what the bundle handed it.
//!
//! **FreeBSD only.** Empty on every other host — the IPC transport and
//! Capsicum are FreeBSD facilities — so the macOS dev bed still builds.

// The shim adopts the bootstrap descriptor by raw number; `unsafe` is
// confined to `freebsd`.
#![allow(unsafe_code)]

#[cfg(target_os = "freebsd")]
mod freebsd;

#[cfg(target_os = "freebsd")]
pub use freebsd::{Startup, enter};
