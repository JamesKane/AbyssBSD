// SPDX-License-Identifier: BSD-2-Clause

//! The reply handle — the framework's answer path for a request
//! (`docs/design/broker-and-transport.md` §2.7).
//!
//! A handler processing a request is given a [`Responder`] and answers it
//! exactly once. In-process a responder is the send end of a one-message
//! reply ring, and the caller awaits the matching [`Receiver`]. The reply
//! handle is the same shape over IPC (a frame echoing the correlation), so
//! a handler never names a backend.

use crate::channel::{Receiver, Sender, channel};
use crate::error::RingClosed;

/// A one-shot handle for answering a request (§2.7).
///
/// `send` consumes it — a request is answered once. The reply type `Rep`
/// is the request's, so a handler cannot answer with the wrong type.
pub struct Responder<Rep> {
    reply: Sender<Rep>,
}

impl<Rep> Responder<Rep> {
    /// Answer the request with `reply`. `Err(RingClosed)` if the caller is
    /// already gone.
    pub fn send(self, reply: Rep) -> Result<(), RingClosed> {
        // The reply ring holds one message and is freshly made, so this
        // never blocks; it fails only if the caller has dropped.
        match self.reply.try_send(reply) {
            Ok(()) => Ok(()),
            Err(_) => Err(RingClosed),
        }
    }
}

/// Create a [`Responder`] paired with the [`Receiver`] its reply arrives
/// on. The caller of a request holds the receiver and awaits it; the
/// responder travels to the handler that answers.
pub fn responder<Rep>() -> (Responder<Rep>, Receiver<Rep>) {
    let (reply, receiver) = channel::<Rep>(1);
    (Responder { reply }, receiver)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_reply_reaches_the_caller() {
        let (responder, mut receiver) = responder::<i32>();
        responder.send(42).expect("the caller is waiting");
        assert_eq!(receiver.try_recv(), Ok(42));
    }

    #[test]
    fn answering_a_gone_caller_is_ring_closed() {
        let (responder, receiver) = responder::<i32>();
        drop(receiver);
        assert_eq!(responder.send(1), Err(RingClosed));
    }
}
