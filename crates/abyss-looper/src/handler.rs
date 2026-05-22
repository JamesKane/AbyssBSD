// SPDX-License-Identifier: BSD-2-Clause

//! Handlers — the `async fn handle` API over a looper
//! (`docs/design/looper-framework.md` §5).

use std::any::Any;
use std::future::Future;
use std::sync::Mutex;

use crate::channel::Receiver;
use crate::looper::Looper;
use crate::responder::Responder;

/// A message delivered to a handler, with the reply handle that answers it
/// when it is a request (`docs/design/broker-and-transport.md` §2.7). A
/// command or event carries no responder.
pub struct Delivery<M> {
    /// The message to handle.
    pub message: M,
    /// The reply handle, type-erased — `Some` for a request. A handler
    /// recovers a typed [`Responder`] from it via [`Ctx::responder`].
    pub responder: Option<Box<dyn Any + Send>>,
}

/// Per-handler context for the message being processed.
///
/// It carries the current request's reply handle, which
/// [`responder`](Self::responder) takes. Reserved, too, for the timers and
/// spawning the framework doc anticipates (§10) — passed by reference so
/// the [`Handler`] signature is stable as it grows.
#[derive(Default)]
pub struct Ctx {
    // A `Mutex`, not a `Cell`: a handler's task future holds `&Ctx` across
    // an `.await`, which requires `Ctx: Sync`. There is no real contention
    // — one looper thread — so the lock is always uncontended.
    responder: Mutex<Option<Box<dyn Any + Send>>>,
}

impl Ctx {
    /// The typed reply handle for the current request — `Some` once, for a
    /// request; `None` for a command or event, or once already taken.
    ///
    /// `Rep` must be the request's reply type; a mismatch yields `None`
    /// and leaves the handle in place.
    pub fn responder<Rep: Send + 'static>(&self) -> Option<Responder<Rep>> {
        let erased = self.responder.lock().unwrap().take()?;
        match erased.downcast::<Responder<Rep>>() {
            Ok(typed) => Some(*typed),
            Err(returned) => {
                *self.responder.lock().unwrap() = Some(returned);
                None
            }
        }
    }

    /// Place the responder for the message about to be handled.
    fn set_responder(&self, responder: Option<Box<dyn Any + Send>>) {
        *self.responder.lock().unwrap() = responder;
    }
}

/// An object that processes one interface's messages, one at a time.
///
/// `handle` may `.await`. While it is suspended, this handler receives no
/// further message — per-handler serialization. [`Looper::attach`]
/// enforces it by being a sequential loop: the next message is not taken
/// until the current `handle` future resolves.
///
/// The trait method returns `impl Future` rather than using `async fn`, so
/// the build stays clear of the `async_fn_in_trait` lint; an `impl` may
/// still write `async fn handle`.
pub trait Handler: Send + 'static {
    /// The message type this handler processes.
    type Message: Send + 'static;

    /// Process one message. The returned future must be `Send`: a looper —
    /// and so its tasks — moves to its own thread once (`DESIGN.md` §6.7).
    fn handle(&mut self, msg: Self::Message, ctx: &Ctx) -> impl Future<Output = ()> + Send;
}

impl Looper {
    /// Attach `handler`, fed by `inbox`. The handler's serve loop runs
    /// until `inbox` closes — every sender dropped — then the task ends.
    ///
    /// The serve loop owns the handler, so `handle`'s `&mut self` borrow
    /// is an ordinary local borrow inside one task future — there is no
    /// self-referential storage to manage.
    pub fn attach<H: Handler>(&mut self, mut handler: H, mut inbox: Receiver<H::Message>) {
        self.spawn(async move {
            let ctx = Ctx::default();
            while let Ok(msg) = inbox.recv().await {
                handler.handle(msg, &ctx).await;
            }
        });
    }

    /// Attach `handler`, fed by an inbox of [`Delivery`] — each message
    /// possibly carrying a [`Responder`]. The responder is placed in the
    /// [`Ctx`] before `handle` runs, so the handler answers a request with
    /// `ctx.responder()` (`broker-and-transport.md` §2.7).
    ///
    /// A responder the handler does not take is dropped as soon as `handle`
    /// returns: a caller awaiting a reply then learns at once, through
    /// [`RingClosed`](crate::RingClosed), that its request went unanswered,
    /// rather than hanging until the next delivery or the loop's end.
    pub fn attach_service<H: Handler>(
        &mut self,
        mut handler: H,
        mut inbox: Receiver<Delivery<H::Message>>,
    ) {
        self.spawn(async move {
            let ctx = Ctx::default();
            while let Ok(delivery) = inbox.recv().await {
                ctx.set_responder(delivery.responder);
                handler.handle(delivery.message, &ctx).await;
                // Drop a responder the handler never took — promptly, not
                // at the next delivery.
                ctx.set_responder(None);
            }
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::channel::channel;
    use crate::responder::responder;

    /// Doubles each request and answers it through its responder.
    struct Doubler;
    impl Handler for Doubler {
        type Message = i32;
        async fn handle(&mut self, n: i32, ctx: &Ctx) {
            if let Some(reply) = ctx.responder::<i32>() {
                let _ = reply.send(n * 2);
            }
        }
    }

    #[test]
    fn a_service_handler_answers_through_the_delivered_responder() {
        let (inbox_tx, inbox_rx) = channel::<Delivery<i32>>(8);
        let (reply_handle, mut reply_rx) = responder::<i32>();

        let queued = inbox_tx.try_send(Delivery {
            message: 21,
            responder: Some(Box::new(reply_handle)),
        });
        assert!(queued.is_ok(), "the request is queued");
        drop(inbox_tx); // close the inbox so the serve loop ends

        let mut looper = Looper::new();
        looper.attach_service(Doubler, inbox_rx);
        looper.run();

        assert_eq!(reply_rx.try_recv(), Ok(42));
    }
}
