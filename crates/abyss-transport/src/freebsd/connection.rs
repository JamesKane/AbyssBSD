// SPDX-License-Identifier: BSD-2-Clause

//! The IPC ring connection — compiled only on FreeBSD.
//!
//! [`Connection`] is the request/reply protocol over an [`AsyncChannel`]
//! (`docs/design/broker-and-transport.md` §2.7): `call` sends a request
//! and awaits its reply, correlated by id, and the `serve` receive loop
//! routes each reply to the call awaiting it.
//!
//! This is the client side. The service side — `accept` and the
//! `Responder` that answers a request — is the next increment; until it
//! lands, `serve` drops inbound message frames.

use std::collections::HashMap;
use std::io;
use std::os::fd::{BorrowedFd, OwnedFd};
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::{Arc, Mutex};

use abyss_looper::{Sender, channel};
use abyss_msg::Envelope;

use super::AsyncChannel;
use crate::frame::{FrameKind, RingFrame};

/// A reply: the envelope, and any descriptors that rode with it.
type Reply = (Envelope, Vec<OwnedFd>);

/// One end of an IPC ring's request/reply protocol over an
/// [`AsyncChannel`].
///
/// `Connection` is cheaply cloneable: the task that issues `call`s and the
/// [`serve`](Self::serve) receive loop hold clones of one shared state.
#[derive(Clone)]
pub struct Connection {
    inner: Arc<Inner>,
}

struct Inner {
    channel: AsyncChannel,
    next_correlation: AtomicU32,
    /// The reply slot for each call still awaiting an answer, by id.
    pending: Mutex<HashMap<u32, Sender<Reply>>>,
}

impl Connection {
    /// Open a request/reply connection over `channel`.
    pub fn new(channel: AsyncChannel) -> Connection {
        Connection {
            inner: Arc::new(Inner {
                channel,
                // 0 is reserved for non-correlated frames (§2.6); calls
                // count from 1.
                next_correlation: AtomicU32::new(1),
                pending: Mutex::new(HashMap::new()),
            }),
        }
    }

    /// Send `request` and suspend the task until its reply arrives.
    ///
    /// The request goes out as a message frame with a fresh correlation
    /// id; the [`serve`](Self::serve) loop matches the reply by that id.
    pub async fn call(&self, request: &Envelope, fds: &[BorrowedFd<'_>]) -> io::Result<Reply> {
        let correlation = self.inner.next_correlation.fetch_add(1, Ordering::Relaxed);
        let (reply_tx, mut reply_rx) = channel::<Reply>(1);
        self.inner
            .pending
            .lock()
            .unwrap()
            .insert(correlation, reply_tx);

        let frame = RingFrame {
            kind: FrameKind::Message,
            correlation,
        };
        if let Err(err) = self.inner.channel.send(frame, request, fds).await {
            self.inner.pending.lock().unwrap().remove(&correlation);
            return Err(err);
        }

        reply_rx
            .recv()
            .await
            .map_err(|_| io::Error::other("connection closed before the reply"))
    }

    /// The receive loop — drive this as a task on the looper. It reads
    /// each datagram and routes a reply frame to the `call` awaiting it.
    /// It ends when the connection closes, failing every pending call.
    ///
    /// Message frames — inbound requests and events — are dropped for now;
    /// the service side that handles them is the next increment.
    pub async fn serve(self) {
        loop {
            match self.inner.channel.recv().await {
                Ok((frame, envelope, fds)) => {
                    if frame.kind == FrameKind::Reply
                        && let Some(reply_tx) = self
                            .inner
                            .pending
                            .lock()
                            .unwrap()
                            .remove(&frame.correlation)
                    {
                        // The slot holds exactly this one reply.
                        let _ = reply_tx.try_send((envelope, fds));
                    }
                }
                Err(_) => {
                    // The connection is gone: drop every pending slot, so
                    // each awaiting `call` resolves to an error.
                    self.inner.pending.lock().unwrap().clear();
                    return;
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::frame::FrameKind;
    use abyss_looper::Looper;
    use abyss_msg::{Header, MessageKind, Value};
    use std::sync::Mutex;
    use std::thread;

    use super::super::{FramedChannel, ReactorSource};

    fn envelope(kind: MessageKind, value: i64) -> Envelope {
        Envelope {
            header: Header {
                kind,
                interface_id: 2,
                method_id: 3,
            },
            payload: Value::Int(value),
            handles: Vec::new(),
        }
    }

    #[test]
    fn call_correlates_a_request_with_its_reply() {
        let request = envelope(MessageKind::Request, 100);
        let reply = envelope(MessageKind::Event, 200);

        let (client_framed, server_framed) = FramedChannel::pair().expect("socketpair");
        let source = Arc::new(ReactorSource::new().expect("kqueue source"));
        let client = AsyncChannel::new(client_framed, Arc::clone(&source)).expect("async channel");
        let connection = Connection::new(client);

        // The peer is a plain blocking channel: receive the request, then
        // reply with the same correlation id.
        let peer_reply = reply.clone();
        let expect_request = request.clone();
        let peer = thread::spawn(move || {
            let (frame, got_request, _) = server_framed.recv().expect("peer recv");
            assert_eq!(frame.kind, FrameKind::Message);
            assert_eq!(got_request, expect_request);
            server_framed
                .send(
                    RingFrame {
                        kind: FrameKind::Reply,
                        correlation: frame.correlation,
                    },
                    &peer_reply,
                    &[],
                )
                .expect("peer reply");
        });

        // The looper: the receive loop, plus a task that calls.
        let answer = Arc::new(Mutex::new(None));
        let task_answer = Arc::clone(&answer);
        let task_connection = connection.clone();
        let mut looper = Looper::with_event_source(source);
        looper.spawn(connection.serve());
        looper.spawn(async move {
            let (reply_env, _) = task_connection
                .call(&request, &[])
                .await
                .expect("call returns a reply");
            *task_answer.lock().unwrap() = Some(reply_env);
        });
        looper.run();

        peer.join().expect("peer thread");
        assert_eq!(answer.lock().unwrap().take(), Some(reply));
    }
}
