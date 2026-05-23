// SPDX-License-Identifier: BSD-2-Clause

//! FreeBSD `libcasper` FFI — the broker's Casper bindings
//! (`docs/design/broker-and-transport.md` §5.7, §6).
//!
//! The broker opens the root channel to `casperd` with `cap_init`, opens a
//! per-service channel with `cap_service_open`, takes the channel's
//! underlying fd with `cap_sock`, and passes it to a child via
//! `SCM_RIGHTS` in the bootstrap bundle. [`CapChannel`] is the safe
//! wrapper: drop calls `cap_close` (which closes the channel's fd) — the
//! broker's reference is released after the bundle's send has duplicated
//! the fd to the child.
//!
//! Per-service client functions (`cap_getaddrinfo`, `cap_getpwnam`, …)
//! are *not* bound here: they are used by *components*, which link
//! libcasper directly (§5.7).
//!
//! **FreeBSD only.** Empty on every other host — `libcasper` is a FreeBSD
//! facility — so the workspace still builds on the macOS dev bed.

// An FFI crate: `unsafe` is its purpose, and is confined to `freebsd`.
#![allow(unsafe_code)]

#[cfg(target_os = "freebsd")]
mod freebsd;

#[cfg(target_os = "freebsd")]
pub use freebsd::CapChannel;
