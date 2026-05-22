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
//! - [`Responder`] — a handler's one-shot reply handle for a request.
//! - [`block_on`] — drive a future on a non-looper thread (tests, `main`).
//! - [`EventSource`] — the seam a looper blocks on: the in-process backend
//!   parks the thread; the FreeBSD IPC backend waits on a `kqueue`.
//!
//! The executor and ring carry the in-process backend (`ROADMAP.md` Phase
//! 2); the inter-process ring plugs a `kqueue` event source into the same
//! looper (Gate D, `broker-and-transport.md` §2.3).

#![forbid(unsafe_code)]

mod block;
mod channel;
mod error;
mod event_source;
mod handler;
mod looper;
mod responder;

pub use block::block_on;
pub use channel::{Receiver, Sender, channel};
pub use error::{RingClosed, TryRecvError, TrySendError};
pub use event_source::EventSource;
pub use handler::{Ctx, Delivery, Handler};
pub use looper::Looper;
pub use responder::{Responder, responder};
