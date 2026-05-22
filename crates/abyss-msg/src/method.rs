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
    /// The interface's **rights classes** (`docs/design/broker-and-transport.md`
    /// §3.3): each a name, and the bitmask of the method ordinals it
    /// covers. A manifest's `rights` tokens name classes; the broker
    /// resolves them against this table to mint a connection's
    /// object-rights mask, and the service checks an inbound `method_id`
    /// against that mask. Empty for an interface whose message enum tags
    /// no variant `#[rights(...)]`.
    const RIGHTS_CLASSES: &'static [(&'static str, u32)];

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
    /// The reply this request is answered with. `Send + 'static` so it can
    /// ride a reply ring; `Wire` so it can cross a process.
    type Reply: Wire + Send + 'static;
}
