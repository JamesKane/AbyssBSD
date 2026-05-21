// SPDX-License-Identifier: BSD-2-Clause

//! The looper's event-source seam (`docs/design/looper-framework.md` §3.3,
//! `docs/design/broker-and-transport.md` §2.3).
//!
//! A [`Looper`](crate::Looper) blocks when idle and is woken when a task
//! becomes runnable. *How* it blocks is pluggable behind [`EventSource`]:
//! the in-process backend ([`ThreadPark`]) parks the looper's thread; the
//! FreeBSD IPC backend waits on a `kqueue`. The looper is written against
//! this trait, so either backend drives it unchanged.

use std::sync::Mutex;
use std::thread::{self, Thread};

/// What a looper blocks on when idle, and what wakes it.
pub trait EventSource: Send + Sync + 'static {
    /// Called once, on the looper's own thread, before its run loop. The
    /// in-process source records that thread here so [`wake`](Self::wake)
    /// can reach it; an fd-driven source can ignore it.
    fn bind(&self) {}

    /// Block the calling (looper) thread until [`wake`](Self::wake) is
    /// called — or, for an fd-driven source, until watched readiness
    /// arrives. A spurious return is allowed: the looper simply re-checks
    /// its ready set and blocks again.
    fn wait(&self);

    /// Wake a [`wait`](Self::wait) in progress, or the next one. Called
    /// from any thread, including another looper's.
    fn wake(&self);
}

/// The in-process [`EventSource`]: it parks the looper's thread, and
/// `wake` unparks it. The Phase-2 backend, and the looper's default.
pub(crate) struct ThreadPark {
    /// The looper thread, recorded by [`bind`](EventSource::bind). `wake`
    /// may run on any thread, so it reaches the looper through this.
    thread: Mutex<Option<Thread>>,
}

impl ThreadPark {
    pub(crate) fn new() -> ThreadPark {
        ThreadPark {
            thread: Mutex::new(None),
        }
    }
}

impl EventSource for ThreadPark {
    fn bind(&self) {
        *self.thread.lock().unwrap() = Some(thread::current());
    }

    fn wait(&self) {
        // park/unpark carries a token, so a `wake` between the looper's
        // ready-set check and this call is not lost.
        thread::park();
    }

    fn wake(&self) {
        if let Some(thread) = self.thread.lock().unwrap().as_ref() {
            thread.unpark();
        }
    }
}
