// SPDX-License-Identifier: BSD-2-Clause

//! The [`Method`] trait — a message's routing identity.
//!
//! [`Wire`](crate::Wire) says how a message's payload encodes; `Method`
//! says how it routes. An interface's message type — an enum of the
//! interface's requests, commands, and events — implements `Method`: each
//! variant has a `method_id` (its ordinal, by declaration order) and a
//! [`MessageKind`]. With the interface id, those are an envelope
//! [`Header`](crate::Header) (`docs/design/broker-and-transport.md` §2.9).
//!
//! The interface id belongs to the ring, not the message (§2.9), so it is
//! not part of this trait. `#[derive(Method)]` writes the impl.

use crate::envelope::MessageKind;

/// A message that knows which interface method it invokes.
pub trait Method {
    /// This message's method ordinal — its variant's declaration index.
    fn method_id(&self) -> u16;

    /// Whether this message is a Request, a Command, or an Event.
    fn kind(&self) -> MessageKind;
}
