//! Handlers — the `async fn handle` API over a looper
//! (`docs/design/looper-framework.md` §5).

use std::future::Future;

use crate::channel::Receiver;
use crate::looper::Looper;

/// Per-handler context. Reserved for timers and spawning (the framework
/// doc §10); empty in Phase 2, but passed by reference so the [`Handler`]
/// signature is stable as it grows.
#[derive(Debug, Default, Clone, Copy)]
pub struct Ctx;

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
            let ctx = Ctx;
            while let Ok(msg) = inbox.recv().await {
                handler.handle(msg, &ctx).await;
            }
        });
    }
}
