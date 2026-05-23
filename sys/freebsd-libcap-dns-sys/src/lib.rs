// SPDX-License-Identifier: BSD-2-Clause

//! FreeBSD `libcap_dns` FFI — the Casper DNS service's client API
//! (`docs/design/broker-and-transport.md` §5.7, §6).
//!
//! Component-side use: receive a [`CapChannel`](freebsd_libcasper_sys::CapChannel)
//! for the `system.dns` service from the bootstrap bundle, and call
//! [`lookup`] on it to resolve a hostname.
//!
//! Broker-side use: call [`ensure_loaded`] anywhere reachable to keep the
//! linker from pruning `libcap_dns.so` as `DT_NEEDED`. Loading the
//! library runs its global constructor — the macro `CREATE_SERVICE`
//! expands to one — which registers `system.dns` with `libcasper`. The
//! broker's `cap_init` then forks a `casperd` that inherits the
//! registration; `cap_service_open(root, "system.dns")` resolves to it.
//!
//! **FreeBSD only.** Empty on every other host so the workspace still
//! builds on the macOS dev bed.

// An FFI crate: `unsafe` is its purpose, and is confined to `freebsd`.
#![allow(unsafe_code)]

#[cfg(target_os = "freebsd")]
mod freebsd;

#[cfg(target_os = "freebsd")]
pub use freebsd::{ensure_loaded, lookup};
