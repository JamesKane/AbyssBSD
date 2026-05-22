// SPDX-License-Identifier: BSD-2-Clause

//! [`Method`] and [`Request`] — a message's routing identity, and the
//! reply type a request is answered with.
//!
//! [`Wire`](crate::Wire) says how a message's payload encodes; `Method`
//! says how it routes. An interface's message type — an enum of the
//! interface's requests, commands, and events — implements `Method`: each
//! variant has a `method_id` (its ordinal, by declaration order) and a
//! [`MessageKind`]. With the interface id, those are an envelope
//! [`Header`](crate::Header) (`docs/design/broker-and-transport.md` §2.9).
//!
//! `Request` is the typed request layer above that (§2.10): the payload
//! type of each `#[request]` variant carries the type of its reply, so a
//! caller of `Cap::call` is handed back exactly that type.
//!
//! `#[derive(Method)]` and `#[derive(Request)]` write the two impls.

use crate::envelope::MessageKind;
use crate::wire::Wire;

/// A message that knows which interface method it invokes.
pub trait Method {
    /// This message's method ordinal — its variant's declaration index.
    fn method_id(&self) -> u16;

    /// Whether this message is a Request, a Command, or an Event.
    fn kind(&self) -> MessageKind;
}

/// A request message, paired with the type of the reply it is answered
/// with (`docs/design/broker-and-transport.md` §2.10).
///
/// Implemented for the payload type of each `#[request]` variant of an
/// interface's message enum — `#[derive(Request)]` writes it. `Cap::call`
/// sends a request and hands the caller back exactly this `Reply`.
pub trait Request {
    /// The reply this request is answered with.
    type Reply: Wire;
}
