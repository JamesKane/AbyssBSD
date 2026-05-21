// SPDX-License-Identifier: BSD-2-Clause

//! The async IPC channel — compiled only on FreeBSD.
//!
//! [`AsyncChannel`] drives a [`FramedChannel`] on a [`ReactorSource`]: its
//! `recv` and `send` suspend the *calling task* — never the looper thread
//! — when the socket would block (`docs/design/broker-and-transport.md`
//! §2.3). The request/reply layer (§2.7) builds on it.

use std::future::poll_fn;
use std::io;
use std::os::fd::{AsFd, BorrowedFd, OwnedFd};
use std::sync::Arc;
use std::task::Poll;

use abyss_msg::Envelope;

use super::{FramedChannel, Interest, ReactorSource};
use crate::frame::RingFrame;

/// A [`FramedChannel`] driven asynchronously on a [`ReactorSource`].
///
/// When the socket would block, the calling task parks on the reactor
/// until the descriptor is ready, and the looper runs its other tasks
/// meanwhile. The socket is held in non-blocking mode.
pub struct AsyncChannel {
    framed: FramedChannel,
    source: Arc<ReactorSource>,
}

impl AsyncChannel {
    /// Drive `framed` asynchronously on `source`; puts the socket into
    /// non-blocking mode. `source` must be the event source of the looper
    /// this channel is used from.
    pub fn new(framed: FramedChannel, source: Arc<ReactorSource>) -> io::Result<AsyncChannel> {
        framed.set_nonblocking()?;
        Ok(AsyncChannel { framed, source })
    }

    /// Receive one ring datagram, suspending the task until one arrives.
    pub async fn recv(&self) -> io::Result<(RingFrame, Envelope, Vec<OwnedFd>)> {
        poll_fn(|cx| match self.framed.recv() {
            Err(err) if err.kind() == io::ErrorKind::WouldBlock => {
                match self.source.register(
                    self.framed.as_fd(),
                    Interest::Readable,
                    cx.waker().clone(),
                ) {
                    Ok(()) => Poll::Pending,
                    Err(err) => Poll::Ready(Err(err)),
                }
            }
            other => Poll::Ready(other),
        })
        .await
    }

    /// Send one ring datagram, suspending the task if the socket's send
    /// buffer is momentarily full.
    pub async fn send(
        &self,
        frame: RingFrame,
        envelope: &Envelope,
        fds: &[BorrowedFd<'_>],
    ) -> io::Result<()> {
        poll_fn(|cx| match self.framed.send(frame, envelope, fds) {
            Err(err) if err.kind() == io::ErrorKind::WouldBlock => {
                match self.source.register(
                    self.framed.as_fd(),
                    Interest::Writable,
                    cx.waker().clone(),
                ) {
                    Ok(()) => Poll::Pending,
                    Err(err) => Poll::Ready(Err(err)),
                }
            }
            other => Poll::Ready(other),
        })
        .await
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
    use std::time::Duration;

    fn envelope(kind: MessageKind, value: i64) -> Envelope {
        Envelope {
            header: Header {
                kind,
                interface_id: 1,
                method_id: 1,
            },
            payload: Value::Int(value),
            handles: Vec::new(),
        }
    }

    #[test]
    fn async_request_and_reply_over_a_looper() {
        let request = envelope(MessageKind::Request, 10);
        let reply = envelope(MessageKind::Event, 20);

        let (server_framed, client_framed) = FramedChannel::pair().expect("socketpair");
        let source = Arc::new(ReactorSource::new().expect("kqueue source"));
        let server = AsyncChannel::new(server_framed, Arc::clone(&source)).expect("async channel");

        // The peer is a plain blocking channel on another thread: it sends
        // a request, then waits for the reply.
        let peer_request = request.clone();
        let peer = thread::spawn(move || {
            // Let the looper park on its first `recv` before sending.
            thread::sleep(Duration::from_millis(50));
            client_framed
                .send(
                    RingFrame {
                        kind: FrameKind::Message,
                        correlation: 99,
                    },
                    &peer_request,
                    &[],
                )
                .expect("peer send");
            let (frame, env, _) = client_framed.recv().expect("peer recv");
            (frame, env)
        });

        // The looper, on the reactor source: one task — async-recv the
        // request, then async-send a reply that echoes the correlation.
        let seen = Arc::new(Mutex::new(None));
        let task_seen = Arc::clone(&seen);
        let task_reply = reply.clone();
        let mut looper = Looper::with_event_source(source);
        looper.spawn(async move {
            let (frame, env, _) = server.recv().await.expect("server recv");
            *task_seen.lock().unwrap() = Some((frame, env));
            server
                .send(
                    RingFrame {
                        kind: FrameKind::Reply,
                        correlation: frame.correlation,
                    },
                    &task_reply,
                    &[],
                )
                .await
                .expect("server send");
        });
        looper.run();

        let (peer_frame, peer_env) = peer.join().expect("peer thread");

        // The looper saw the request, framed and intact.
        let (req_frame, req_env) = seen.lock().unwrap().take().expect("server saw a request");
        assert_eq!(req_frame.kind, FrameKind::Message);
        assert_eq!(req_frame.correlation, 99);
        assert_eq!(req_env, request);

        // The peer got the reply, with the correlation echoed.
        assert_eq!(peer_frame.kind, FrameKind::Reply);
        assert_eq!(peer_frame.correlation, 99);
        assert_eq!(peer_env, reply);
    }
}
