// SPDX-License-Identifier: BSD-2-Clause

//! Ring and looper basics — exercised with `block_on` and one helper
//! thread (`docs/design/looper-framework.md` §11).

use std::future::Future;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::task::{Context, Wake, Waker};
use std::thread;

use abyss_looper::{
    Ctx, Delivery, Handler, Looper, RingClosed, Sender, TryRecvError, TrySendError, block_on,
    channel, responder,
};

#[test]
fn channel_send_then_recv() {
    let (tx, mut rx) = channel::<i32>(2);
    block_on(async {
        tx.send(7).await.unwrap();
        assert_eq!(rx.recv().await.unwrap(), 7);
    });
}

#[test]
fn channel_is_fifo() {
    let (tx, mut rx) = channel::<i32>(8);
    block_on(async {
        for i in 0..8 {
            tx.send(i).await.unwrap();
        }
        for i in 0..8 {
            assert_eq!(rx.recv().await.unwrap(), i);
        }
    });
}

#[test]
fn recv_reports_closed_when_all_senders_drop() {
    let (tx, mut rx) = channel::<i32>(2);
    drop(tx);
    assert_eq!(block_on(rx.recv()), Err(RingClosed));
}

#[test]
fn buffered_messages_drain_before_closed() {
    let (tx, mut rx) = channel::<i32>(4);
    block_on(tx.send(1)).unwrap();
    block_on(tx.send(2)).unwrap();
    drop(tx);
    block_on(async {
        assert_eq!(rx.recv().await.unwrap(), 1);
        assert_eq!(rx.recv().await.unwrap(), 2);
        assert_eq!(rx.recv().await, Err(RingClosed));
    });
}

#[test]
fn send_reports_closed_when_receiver_drops() {
    let (tx, rx) = channel::<i32>(2);
    drop(rx);
    assert_eq!(block_on(tx.send(1)), Err(RingClosed));
}

#[test]
fn try_send_and_try_recv() {
    let (tx, mut rx) = channel::<i32>(1);
    assert!(tx.try_send(1).is_ok());
    assert!(matches!(tx.try_send(2), Err(TrySendError::Full(2))));
    assert_eq!(rx.try_recv(), Ok(1));
    assert_eq!(rx.try_recv(), Err(TryRecvError::Empty));
    drop(tx);
    assert_eq!(rx.try_recv(), Err(TryRecvError::Closed));
}

#[test]
fn looper_runs_every_task_to_completion() {
    let done = Arc::new(Mutex::new(Vec::new()));
    let mut looper = Looper::new();
    for n in 0..3 {
        let done = Arc::clone(&done);
        looper.spawn(async move {
            done.lock().unwrap().push(n);
        });
    }
    looper.run();
    let mut got = Arc::try_unwrap(done).unwrap().into_inner().unwrap();
    got.sort_unstable();
    assert_eq!(got, [0, 1, 2]);
}

#[test]
fn looper_drains_a_ring_under_backpressure() {
    // A capacity-4 ring and 200 messages: the sender on this thread
    // backpressures against the looper draining on another. Exercises
    // the ring, the executor, cross-thread wakeups, and shutdown on
    // ring close — all at once.
    let (tx, mut rx) = channel::<i32>(4);
    let log = Arc::new(Mutex::new(Vec::new()));
    let log_task = Arc::clone(&log);

    let mut looper = Looper::new();
    looper.spawn(async move {
        while let Ok(value) = rx.recv().await {
            log_task.lock().unwrap().push(value);
        }
    });
    let handle = thread::spawn(move || looper.run());

    for i in 0..200 {
        block_on(tx.send(i)).unwrap();
    }
    drop(tx); // ring closes → recv yields RingClosed → task ends → run returns
    handle.join().unwrap();

    assert_eq!(*log.lock().unwrap(), (0..200).collect::<Vec<_>>());
}

// --- regression tests: ring and handler correctness ------------------------

/// A waker that records, in a shared flag, that it was woken.
struct RecordingWaker(Arc<AtomicBool>);

impl Wake for RecordingWaker {
    fn wake(self: Arc<Self>) {
        self.wake_by_ref();
    }
    fn wake_by_ref(self: &Arc<Self>) {
        self.0.store(true, Ordering::SeqCst);
    }
}

/// A waker paired with the flag it raises when woken.
fn recording_waker() -> (Waker, Arc<AtomicBool>) {
    let woken = Arc::new(AtomicBool::new(false));
    let waker = Waker::from(Arc::new(RecordingWaker(Arc::clone(&woken))));
    (waker, woken)
}

#[test]
fn a_cancelled_send_does_not_strand_a_later_sender() {
    // A capacity-1 ring, filled. Two senders then block on it; the first
    // is cancelled — its future dropped — while still pending. Draining
    // the one slot must wake the *second*, still-live sender: a cancelled
    // send must not leave a stale waker queued ahead of a live one.
    let (tx, mut rx) = channel::<i32>(1);
    tx.try_send(1).expect("the empty ring has room");

    let mut cancelled = Box::pin(tx.send(2));
    assert!(
        cancelled
            .as_mut()
            .poll(&mut Context::from_waker(Waker::noop()))
            .is_pending(),
        "the first sender blocks on the full ring",
    );

    let (live_waker, live_woken) = recording_waker();
    let mut waiting = Box::pin(tx.send(3));
    assert!(
        waiting
            .as_mut()
            .poll(&mut Context::from_waker(&live_waker))
            .is_pending(),
        "the second sender blocks on the full ring too",
    );

    // The first sender's future is dropped — a cancelled send.
    drop(cancelled);

    // Draining one message frees a slot; the still-waiting sender is the
    // one that must be woken for it.
    assert_eq!(rx.try_recv(), Ok(1));
    assert!(
        live_woken.load(Ordering::SeqCst),
        "the live sender was woken when the ring drained",
    );
}

#[test]
fn an_ignored_request_drops_its_responder() {
    // A handler that ignores its request entirely: it never takes the
    // responder, it only signals that it has run.
    struct Ignores {
        ran: Sender<()>,
    }
    impl Handler for Ignores {
        type Message = i32;
        async fn handle(&mut self, _msg: i32, _ctx: &Ctx) {
            let _ = self.ran.send(()).await;
        }
    }

    let (inbox_tx, inbox_rx) = channel::<Delivery<i32>>(1);
    let (reply_handle, mut reply_rx) = responder::<i32>();
    let (ran_tx, mut ran_rx) = channel::<()>(1);

    let queued = inbox_tx.try_send(Delivery {
        message: 1,
        responder: Some(Box::new(reply_handle)),
    });
    assert!(queued.is_ok(), "the request queues onto the empty inbox");

    let mut looper = Looper::new();
    looper.attach_service(Ignores { ran: ran_tx }, inbox_rx);

    // Once the handler has run — but while the looper is still live — the
    // responder it ignored must already be dropped. A dropped responder
    // closes the reply channel, so `try_recv` reports `Closed`, not the
    // `Empty` of a responder still held.
    let outcome = Arc::new(Mutex::new(None));
    let outcome_task = Arc::clone(&outcome);
    looper.spawn(async move {
        ran_rx.recv().await.expect("the handler ran");
        *outcome_task.lock().unwrap() = Some(reply_rx.try_recv());
        drop(inbox_tx); // close the inbox so the looper winds down
    });
    looper.run();

    assert_eq!(
        outcome.lock().unwrap().take(),
        Some(Err(TryRecvError::Closed)),
        "the unanswered request's responder was dropped when the handler returned",
    );
}
