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
//! piece. [`Channel`] is the raw primitive — bytes and descriptors;
//! [`MessageChannel`] frames a bare envelope over it; [`FramedChannel`]
//! adds the [`RingFrame`] the IPC ring needs (§2.6); and [`Reactor`] is
//! the `kqueue` event source the looper waits on (§2.3).
//!
//! **Mostly FreeBSD.** `SOCK_SEQPACKET` Unix-domain sockets do not exist
//! on macOS, so the channels and the reactor are FreeBSD-only; on every
//! other host just the platform-independent [`RingFrame`] is present, and
//! the workspace still builds on the development bed. The FreeBSD parts
//! are built and tested in the VM (`tools/vm`).

// An FFI crate: `unsafe` is its purpose, and is confined to `freebsd`.
#![allow(unsafe_code)]

mod frame;
pub use frame::{FrameError, FrameKind, RING_FRAME_LEN, RingFrame};

#[cfg(target_os = "freebsd")]
mod freebsd;

#[cfg(target_os = "freebsd")]
pub use freebsd::{
    AsyncChannel, CallOutcome, Channel, Connection, Event, FramedChannel, Inbound, Inbox, Interest,
    MessageChannel, Reactor, ReactorSource, Responder,
};
