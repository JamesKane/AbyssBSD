// SPDX-License-Identifier: BSD-2-Clause

//! AbyssBSD IPC transport — the `SOCK_SEQPACKET` ring with `SCM_RIGHTS`.
//!
//! The inter-process transport of `docs/design/broker-and-transport.md`
//! §2: a connected pair of `SOCK_SEQPACKET` Unix-domain sockets. Each
//! `send` is one datagram, ordered and reliable, with message boundaries
//! preserved — and file descriptors travel alongside the bytes via
//! `SCM_RIGHTS`, which is how a capability crosses a process boundary
//! (§3.1).
//!
//! As built, this is its own crate rather than a module of `abyss-looper`
//! (which §7 of the design doc anticipated): the raw, FFI-bearing
//! primitive is kept separate so `abyss-looper` stays host-clean, and the
//! `kqueue` event loop that will drive these sockets is a later, separate
//! piece. This crate is the primitive; the envelope framing, the ring
//! API, and the event loop build on it.
//!
//! **FreeBSD only.** `SOCK_SEQPACKET` Unix-domain sockets do not exist on
//! macOS; on every non-FreeBSD host this crate is empty, so the workspace
//! still builds on the development bed. The transport is built and tested
//! in the FreeBSD VM (`tools/vm`).

// An FFI crate: `unsafe` is its purpose, and is confined to `freebsd`.
#![allow(unsafe_code)]

#[cfg(target_os = "freebsd")]
mod freebsd;

#[cfg(target_os = "freebsd")]
pub use freebsd::Channel;
