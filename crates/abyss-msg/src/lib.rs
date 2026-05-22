// SPDX-License-Identifier: BSD-2-Clause

//! AbyssBSD message primitive.
//!
//! The self-describing value vocabulary, the cross-process envelope, and
//! the [`Wire`] typed-view layer. This crate implements
//! `docs/design/wire-format.md` — see that document for the byte layout
//! and the rationale behind every decision here.
//!
//! Three layers:
//!
//! - [`Value`] — the nine-kind self-describing value, with [`Value::encode`]
//!   and [`Value::decode`].
//! - [`Envelope`] — the cross-process unit: header, payload, handle table.
//! - [`Wire`] — typed views over [`Value`], the layer AbyssBSD's own code
//!   programs against. [`Envelope::from_message`] / [`Envelope::into_message`]
//!   bridge a typed message and an envelope.
//! - [`Method`] / [`Request`] — a message's routing identity (the method
//!   ordinal and kind that, with the interface id, name an envelope's
//!   [`Header`]), and the reply type a request is answered with
//!   (`docs/design/broker-and-transport.md` §2.9, §2.10).
//!
//! Decoding is total: malformed input is always a [`WireError`], never a
//! panic.

#![forbid(unsafe_code)]

mod cursor;
mod envelope;
mod error;
mod method;
mod value;
mod wire;

pub use envelope::{Envelope, Header, MessageKind, RawHandle, WIRE_VERSION};
pub use error::WireError;
pub use method::{Method, Request};
pub use value::{MAX_DEPTH, Value};
pub use wire::{Bytes, HandleSink, HandleStore, Wire};
