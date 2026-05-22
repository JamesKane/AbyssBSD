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
//! - [`catalogue`] — the interface catalogue: resolving a manifest's rights
//!   tokens to an object-rights mask (§3.3).
//!
//! FreeBSD-only:
//!
//! - `spawn` — component spawn: the component's jail, its bootstrap
//!   channel, the `pdfork` into the jail, and the bootstrap bundle (§5.3).
//! - `session` — the session runtime: wiring a manifest set, spawning every
//!   component, and supervising it — a component that exits is re-wired and
//!   spawned again, its peers told over their control channels (§5.2, §5.5).
//!
//! The broker's full event loop (§5.6–§5.7) arrives with the rest of the
//! FreeBSD work; see `STATUS.md`.
//!
//! The broker itself holds no `unsafe`: every kernel call is a safe API
//! exported by a `sys/*` crate (`broker-and-transport.md` §6).

#![forbid(unsafe_code)]

pub mod catalogue;
pub mod graph;
pub mod manifest;

#[cfg(target_os = "freebsd")]
pub mod spawn;

#[cfg(target_os = "freebsd")]
pub mod session;
