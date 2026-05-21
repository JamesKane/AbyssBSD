// SPDX-License-Identifier: BSD-2-Clause

//! A bounded, ordered MPSC ring — the in-process ring backend
//! (`docs/design/looper-framework.md` §3).
//!
//! All ring state lives behind one `Mutex`, so a poll either makes
//! progress or registers a waker atomically — there is no lost-wakeup
//! window.

use std::collections::VecDeque;
use std::future::Future;
use std::pin::Pin;
use std::sync::{Arc, Mutex};
use std::task::{Context, Poll, Waker};

use crate::error::{RingClosed, TryRecvError, TrySendError};

struct Chan<M> {
    capacity: usize,
    inner: Mutex<Inner<M>>,
}

struct Inner<M> {
    queue: VecDeque<M>,
    senders: usize,
    recv_open: bool,
    recv_waker: Option<Waker>,
    send_wakers: VecDeque<Waker>,
}

/// Create a bounded ring with room for `capacity` messages.
///
/// # Panics
///
/// Panics if `capacity` is zero — a ring must hold at least one message.
pub fn channel<M>(capacity: usize) -> (Sender<M>, Receiver<M>) {
    assert!(capacity >= 1, "ring capacity must be at least 1");
    let chan = Arc::new(Chan {
        capacity,
        inner: Mutex::new(Inner {
            queue: VecDeque::new(),
            senders: 1,
            recv_open: true,
            recv_waker: None,
            send_wakers: VecDeque::new(),
        }),
    });
    (Sender { chan: chan.clone() }, Receiver { chan })
}

/// The send endpoint of a ring. Clonable — a ring is MPSC.
pub struct Sender<M> {
    chan: Arc<Chan<M>>,
}

/// The receive endpoint of a ring. There is exactly one.
pub struct Receiver<M> {
    chan: Arc<Chan<M>>,
}

impl<M> Sender<M> {
    /// Send a message, awaiting space on a full ring. Suspends the calling
    /// handler — never the looper thread.
    pub async fn send(&self, msg: M) -> Result<(), RingClosed> {
        SendFut {
            chan: &self.chan,
            msg: Some(msg),
        }
        .await
    }

    /// Send without waiting. On a full ring the message is returned.
    pub fn try_send(&self, msg: M) -> Result<(), TrySendError<M>> {
        let mut inner = self.chan.inner.lock().unwrap();
        if !inner.recv_open {
            return Err(TrySendError::Closed(msg));
        }
        if inner.queue.len() >= self.chan.capacity {
            return Err(TrySendError::Full(msg));
        }
        inner.queue.push_back(msg);
        let waker = inner.recv_waker.take();
        drop(inner);
        if let Some(waker) = waker {
            waker.wake();
        }
        Ok(())
    }
}

impl<M> Clone for Sender<M> {
    fn clone(&self) -> Self {
        self.chan.inner.lock().unwrap().senders += 1;
        Sender {
            chan: self.chan.clone(),
        }
    }
}

impl<M> Drop for Sender<M> {
    fn drop(&mut self) {
        let mut inner = self.chan.inner.lock().unwrap();
        inner.senders -= 1;
        if inner.senders == 0 {
            // Last sender gone — wake the receiver so it observes closure.
            let waker = inner.recv_waker.take();
            drop(inner);
            if let Some(waker) = waker {
                waker.wake();
            }
        }
    }
}

impl<M> Receiver<M> {
    /// Receive the next message, awaiting an empty ring. Returns
    /// [`RingClosed`] once the ring is empty and every sender is gone.
    pub async fn recv(&mut self) -> Result<M, RingClosed> {
        RecvFut { chan: &self.chan }.await
    }

    /// Receive without waiting.
    pub fn try_recv(&mut self) -> Result<M, TryRecvError> {
        let mut inner = self.chan.inner.lock().unwrap();
        if let Some(msg) = inner.queue.pop_front() {
            let waker = inner.send_wakers.pop_front();
            drop(inner);
            if let Some(waker) = waker {
                waker.wake();
            }
            return Ok(msg);
        }
        if inner.senders == 0 {
            Err(TryRecvError::Closed)
        } else {
            Err(TryRecvError::Empty)
        }
    }
}

impl<M> Drop for Receiver<M> {
    fn drop(&mut self) {
        let mut inner = self.chan.inner.lock().unwrap();
        inner.recv_open = false;
        // Wake every blocked sender so each observes closure.
        let wakers: Vec<Waker> = inner.send_wakers.drain(..).collect();
        drop(inner);
        for waker in wakers {
            waker.wake();
        }
    }
}

// --- the leaf futures ------------------------------------------------------
//
// Both are leaf futures with no internal self-reference, so both are
// soundly `Unpin` regardless of `M`. A `SendFut` dropped while pending
// leaves a stale waker in `send_wakers`; waking it later is a harmless
// no-op.

struct SendFut<'a, M> {
    chan: &'a Chan<M>,
    msg: Option<M>,
}

impl<M> Unpin for SendFut<'_, M> {}

impl<M> Future for SendFut<'_, M> {
    type Output = Result<(), RingClosed>;

    fn poll(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Self::Output> {
        let this = self.get_mut();
        let mut inner = this.chan.inner.lock().unwrap();
        if !inner.recv_open {
            return Poll::Ready(Err(RingClosed));
        }
        if inner.queue.len() < this.chan.capacity {
            let msg = this.msg.take().expect("SendFut polled after completion");
            inner.queue.push_back(msg);
            let waker = inner.recv_waker.take();
            drop(inner);
            if let Some(waker) = waker {
                waker.wake();
            }
            Poll::Ready(Ok(()))
        } else {
            inner.send_wakers.push_back(cx.waker().clone());
            Poll::Pending
        }
    }
}

struct RecvFut<'a, M> {
    chan: &'a Chan<M>,
}

impl<M> Future for RecvFut<'_, M> {
    type Output = Result<M, RingClosed>;

    fn poll(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Self::Output> {
        let mut inner = self.chan.inner.lock().unwrap();
        if let Some(msg) = inner.queue.pop_front() {
            let waker = inner.send_wakers.pop_front();
            drop(inner);
            if let Some(waker) = waker {
                waker.wake();
            }
            Poll::Ready(Ok(msg))
        } else if inner.senders == 0 {
            Poll::Ready(Err(RingClosed))
        } else {
            inner.recv_waker = Some(cx.waker().clone());
            Poll::Pending
        }
    }
}
