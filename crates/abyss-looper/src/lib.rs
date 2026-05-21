// SPDX-License-Identifier: BSD-2-Clause

//! AbyssBSD looper & service framework.
//!
//! The cooperative executor, the typed ring, and the handler model.
//! Implements `docs/design/looper-framework.md` — see that document for
//! the model and its rationale.
//!
//! - [`channel`] — a bounded, ordered ring; [`Sender`] / [`Receiver`].
//! - [`Looper`] — a thread that hosts handlers and drives their futures.
//! - [`Handler`] — `async fn handle`, attached to a looper.
//! - [`block_on`] — drive a future on a non-looper thread (tests, `main`).
//!
//! This crate is the in-process backend (`ROADMAP.md` Phase 2). The
//! inter-process ring and the broker are Gate D.

#![forbid(unsafe_code)]

mod block;
mod channel;
mod error;
mod handler;
mod looper;

pub use block::block_on;
pub use channel::{Receiver, Sender, channel};
pub use error::{RingClosed, TryRecvError, TrySendError};
pub use handler::{Ctx, Handler};
pub use looper::Looper;
