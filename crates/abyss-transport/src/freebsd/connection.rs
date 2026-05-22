// SPDX-License-Identifier: BSD-2-Clause

//! The IPC ring connection — compiled only on FreeBSD.
//!
//! [`Connection`] is the request/reply protocol over an [`AsyncChannel`]
//! (`docs/design/broker-and-transport.md` §2.7). `call` sends a request
//! and awaits its reply, correlated by id; `serve` is the receive loop
//! that routes each datagram — a reply to the `call` awaiting it, an
//! inbound message to the [`Inbox`]; and a [`Responder`] answers a
//! request the framework, not the message, supplies.

use std::collections::HashMap;
use std::io;
use std::os::fd::{AsFd, BorrowedFd, OwnedFd};
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::{Arc, Mutex};

use abyss_looper::{Receiver, Sender, channel};
use abyss_msg::Envelope;

use super::AsyncChannel;
use crate::frame::{FrameKind, RingFrame};

/// A reply: the envelope, and any descriptors that rode with it.
type Reply = (Envelope, Vec<OwnedFd>);

/// How many inbound messages the [`Inbox`] buffers before the receive
/// loop has to drop the overflow. Backpressure is a later refinement.
const INBOX_CAPACITY: usize = 64;

/// An inbound message lifted off the connection by [`Inbox::accept`].
pub struct Inbound {
    /// The message envelope.
    pub envelope: Envelope,
    /// Any descriptors that rode with it.
    pub fds: Vec<OwnedFd>,
    /// The reply handle — `Some` for a request that expects an answer,
    /// `None` for a one-way command or event.
    pub responder: Option<Responder>,
}

/// One end of an IPC ring's request/reply protocol over an
/// [`AsyncChannel`].
///
/// `Connection` is cheaply cloneable: the task that issues `call`s, the
/// [`serve`](Self::serve) receive loop, and each [`Responder`] hold
/// clones of one shared state.
#[derive(Clone)]
pub struct Connection {
    inner: Arc<Inner>,
}

struct Inner {
    channel: AsyncChannel,
    next_correlation: AtomicU32,
    /// The reply slot for each call still awaiting an answer, by id.
    pending: Mutex<HashMap<u32, Sender<Reply>>>,
    /// Where the receive loop posts inbound messages; taken (dropped) when
    /// the loop ends, which closes the [`Inbox`].
    inbox: Mutex<Option<Sender<Inbound>>>,
}

impl Connection {
    /// Open a request/reply connection over `channel`, returning it paired
    /// with the [`Inbox`] of messages inbound to this end.
    pub fn open(async_channel: AsyncChannel) -> (Connection, Inbox) {
        let (inbox_tx, inbox_rx) = channel::<Inbound>(INBOX_CAPACITY);
        let connection = Connection {
            inner: Arc::new(Inner {
                channel: async_channel,
                // 0 is reserved for non-correlated frames (§2.6); calls
                // count from 1.
                next_correlation: AtomicU32::new(1),
                pending: Mutex::new(HashMap::new()),
                inbox: Mutex::new(Some(inbox_tx)),
            }),
        };
        (connection, Inbox { rx: inbox_rx })
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

    /// Send a one-way message — a Command or an Event — over the
    /// connection.
    ///
    /// Unlike [`call`](Self::call) it awaits no reply: the message frame
    /// carries correlation `0`, the id reserved for a frame that expects
    /// no answer (`broker-and-transport.md` §2.6).
    pub async fn send(&self, message: &Envelope, fds: &[BorrowedFd<'_>]) -> io::Result<()> {
        let frame = RingFrame {
            kind: FrameKind::Message,
            correlation: 0,
        };
        self.inner.channel.send(frame, message, fds).await
    }

    /// Send a one-way message without suspending — the non-blocking
    /// counterpart of [`send`](Self::send). On a momentarily full send
    /// buffer the socket's `WouldBlock` is surfaced rather than awaited.
    /// A `SOCK_SEQPACKET` datagram is sent whole or not at all, so a
    /// rejected send leaves no partial frame on the ring.
    pub fn try_send(&self, message: &Envelope, fds: &[BorrowedFd<'_>]) -> io::Result<()> {
        let frame = RingFrame {
            kind: FrameKind::Message,
            correlation: 0,
        };
        self.inner.channel.try_send(frame, message, fds)
    }

    /// The receive loop — drive this as a task on the looper. It reads
    /// each datagram and routes it: a reply frame to the `call` awaiting
    /// its id, a message frame to the [`Inbox`]. It ends when the
    /// connection closes, failing every pending call and closing the inbox.
    pub async fn serve(self) {
        loop {
            match self.inner.channel.recv().await {
                Ok((frame, envelope, fds)) => match frame.kind {
                    FrameKind::Reply => {
                        if let Some(reply_tx) = self
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
                    FrameKind::Message => {
                        // A non-zero correlation marks a request expecting
                        // a reply; zero is a one-way command or event.
                        let responder = (frame.correlation != 0).then(|| Responder {
                            connection: self.clone(),
                            correlation: frame.correlation,
                        });
                        let inbound = Inbound {
                            envelope,
                            fds,
                            responder,
                        };
                        if let Some(inbox_tx) = self.inner.inbox.lock().unwrap().as_ref() {
                            let _ = inbox_tx.try_send(inbound);
                        }
                    }
                },
                Err(_) => {
                    // The connection is gone: fail every pending call, and
                    // drop the inbox sender so `accept` reports the close.
                    self.inner.pending.lock().unwrap().clear();
                    self.inner.inbox.lock().unwrap().take();
                    return;
                }
            }
        }
    }
}

impl AsFd for Connection {
    /// The ring socket underneath the connection — what `Cap::to_wire`
    /// duplicates onto `SCM_RIGHTS` to pass the capability on (§3.5).
    fn as_fd(&self) -> BorrowedFd<'_> {
        self.inner.channel.as_fd()
    }
}

/// The reply handle for one received request (`broker-and-transport.md`
/// §2.7). The framework supplies it; it is not a field of the message.
pub struct Responder {
    connection: Connection,
    correlation: u32,
}

impl Responder {
    /// Answer the request: send `reply` back as a reply frame echoing the
    /// request's correlation id. A responder answers once.
    pub async fn respond(self, reply: &Envelope, fds: &[BorrowedFd<'_>]) -> io::Result<()> {
        let frame = RingFrame {
            kind: FrameKind::Reply,
            correlation: self.correlation,
        };
        self.connection.inner.channel.send(frame, reply, fds).await
    }
}

/// The stream of messages inbound to one end of a [`Connection`]. Held by
/// the service's accept loop; one consumer.
pub struct Inbox {
    rx: Receiver<Inbound>,
}

impl Inbox {
    /// Receive the next inbound request, command, or event, suspending the
    /// task until one arrives. `None` once the connection has closed.
    pub async fn accept(&mut self) -> Option<Inbound> {
        self.rx.recv().await.ok()
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
        let (connection, _inbox) = Connection::open(client);

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

    #[test]
    fn send_delivers_a_one_way_message() {
        let message = envelope(MessageKind::Command, 77);

        let (client_framed, server_framed) = FramedChannel::pair().expect("socketpair");
        let source = Arc::new(ReactorSource::new().expect("kqueue source"));
        let client = AsyncChannel::new(client_framed, Arc::clone(&source)).expect("async channel");
        let (connection, _inbox) = Connection::open(client);

        // The peer receives the one-way message — a message frame with no
        // correlation, since it expects no reply.
        let expect = message.clone();
        let peer = thread::spawn(move || {
            let (frame, got, _) = server_framed.recv().expect("peer recv");
            assert_eq!(frame.kind, FrameKind::Message);
            assert_eq!(frame.correlation, 0);
            assert_eq!(got, expect);
        });

        let mut looper = Looper::with_event_source(source);
        looper.spawn(async move {
            connection
                .send(&message, &[])
                .await
                .expect("send the one-way message");
        });
        looper.run();

        peer.join().expect("peer thread");
    }

    #[test]
    fn try_send_delivers_a_one_way_message_without_suspending() {
        let message = envelope(MessageKind::Command, 99);

        let (client_framed, server_framed) = FramedChannel::pair().expect("socketpair");
        let source = Arc::new(ReactorSource::new().expect("kqueue source"));
        let client = AsyncChannel::new(client_framed, source).expect("async channel");
        let (connection, _inbox) = Connection::open(client);

        // The send buffer is empty, so the datagram goes through at once —
        // no looper, no await.
        connection
            .try_send(&message, &[])
            .expect("try_send onto an idle ring");

        let (frame, got, _) = server_framed.recv().expect("peer recv");
        assert_eq!(frame.kind, FrameKind::Message);
        assert_eq!(frame.correlation, 0);
        assert_eq!(got, message);
    }

    #[test]
    fn accept_yields_a_request_and_its_responder() {
        let request = envelope(MessageKind::Request, 7);
        let reply = envelope(MessageKind::Event, 8);

        let (service_framed, peer_framed) = FramedChannel::pair().expect("socketpair");
        let source = Arc::new(ReactorSource::new().expect("kqueue source"));
        let service =
            AsyncChannel::new(service_framed, Arc::clone(&source)).expect("async channel");
        let (connection, inbox) = Connection::open(service);

        // The peer sends a request, then waits for the reply.
        let peer_request = request.clone();
        let peer = thread::spawn(move || {
            peer_framed
                .send(
                    RingFrame {
                        kind: FrameKind::Message,
                        correlation: 55,
                    },
                    &peer_request,
                    &[],
                )
                .expect("peer request");
            let (frame, reply_env, _) = peer_framed.recv().expect("peer recv");
            (frame, reply_env)
        });

        // The service: the receive loop, plus a task that accepts one
        // request and answers it through the responder.
        let seen = Arc::new(Mutex::new(None));
        let task_seen = Arc::clone(&seen);
        let task_reply = reply.clone();
        let mut looper = Looper::with_event_source(source);
        looper.spawn(connection.serve());
        looper.spawn(async move {
            let mut inbox = inbox;
            let inbound = inbox.accept().await.expect("a request arrives");
            let responder = inbound.responder.expect("a request has a responder");
            *task_seen.lock().unwrap() = Some(inbound.envelope);
            responder.respond(&task_reply, &[]).await.expect("respond");
        });
        looper.run();

        let (peer_frame, peer_reply) = peer.join().expect("peer thread");

        assert_eq!(seen.lock().unwrap().take(), Some(request));
        assert_eq!(peer_frame.kind, FrameKind::Reply);
        assert_eq!(peer_frame.correlation, 55);
        assert_eq!(peer_reply, reply);
    }
}
