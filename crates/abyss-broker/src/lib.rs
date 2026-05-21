// SPDX-License-Identifier: BSD-2-Clause

//! AbyssBSD broker — the root of authority.
//!
//! The broker is `rc`'s child and the desktop's root: it reads the system
//! manifests, computes the static authority graph, and (on FreeBSD) spawns
//! every component into a jail holding exactly its declared bundle. This
//! crate implements `docs/design/broker-and-transport.md` §4–§5.
//!
//! Host slice — the parts that depend on no FreeBSD facility and so build
//! and test on any host:
//!
//! - [`manifest`] — the component manifest: the schema and its parser (§4).
//! - [`graph`] — the static authority graph: components and the connections
//!   between them, computed and validated from a manifest set (§5.2).
//!
//! The FreeBSD-only parts — the `SOCK_SEQPACKET` transport, jailed `pdfork`
//! spawn, the bootstrap bundle, `cap_enter`, and supervision (§5.3–§5.7) —
//! arrive with the FreeBSD work; see `STATUS.md`.
//!
//! The broker itself holds no `unsafe`: every kernel call is a safe API
//! exported by a `sys/*` crate (`broker-and-transport.md` §6).

#![forbid(unsafe_code)]

pub mod manifest;
