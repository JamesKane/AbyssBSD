// SPDX-License-Identifier: BSD-2-Clause

//! Ring and looper basics — exercised with `block_on` and one helper
//! thread (`docs/design/looper-framework.md` §11).

use std::sync::{Arc, Mutex};
use std::thread;

use abyss_looper::{Looper, RingClosed, TryRecvError, TrySendError, block_on, channel};

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
