// SPDX-License-Identifier: BSD-2-Clause

//! The `kqueue` readiness reactor — compiled only on FreeBSD.
//!
//! [`Reactor`] is the FreeBSD event source the looper waits on
//! (`docs/design/broker-and-transport.md` §2.3): it watches descriptors
//! for readiness and carries a wakeup channel for cross-thread nudges. The
//! `extern` declarations match `c/kqueue_shim.c`.

use std::collections::HashMap;
use std::ffi::c_int;
use std::io;
use std::os::fd::{AsRawFd, BorrowedFd, FromRawFd, OwnedFd, RawFd};
use std::sync::Mutex;
use std::task::Waker;
use std::time::Duration;

use abyss_looper::EventSource;

/// The most events one [`Reactor::wait`] reports — matches
/// `ABYSS_MAX_EVENTS` in `c/kqueue_shim.c`.
const MAX_EVENTS: usize = 64;

/// A flat readiness event from the shim. The layout must match
/// `struct abyss_event` in `c/kqueue_shim.c`.
#[repr(C)]
#[derive(Clone, Copy)]
struct AbyssEvent {
    ident: i64,
    /// The kevent data word — for a process-exit event, the exit status.
    data: i64,
    kind: c_int,
}

unsafe extern "C" {
    fn abyss_kqueue() -> c_int;
    fn abyss_kqueue_ctl(kq: c_int, fd: c_int, interest: c_int, add: c_int) -> c_int;
    fn abyss_kqueue_arm_wake(kq: c_int) -> c_int;
    fn abyss_kqueue_wake(kq: c_int) -> c_int;
    fn abyss_kqueue_wait(kq: c_int, out: *mut AbyssEvent, max: c_int, timeout_ms: c_int) -> c_int;
}

/// What a registered descriptor is watched for.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Interest {
    /// Readable — a `recv` would not block.
    Readable,
    /// Writable — a `send` would not block.
    Writable,
    /// The process behind a process descriptor has exited — `EVFILT_PROCDESC`
    /// with `NOTE_EXIT`, the broker's supervision signal (§5.5).
    ProcessExit,
}

impl Interest {
    fn as_raw(self) -> c_int {
        match self {
            Interest::Readable => 0,
            Interest::Writable => 1,
            Interest::ProcessExit => 2,
        }
    }
}

/// One readiness notification from [`Reactor::wait`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Event {
    /// A registered descriptor became readable.
    Readable(RawFd),
    /// A registered descriptor became writable.
    Writable(RawFd),
    /// The process behind a registered process descriptor exited, with the
    /// exit status as from `wait(2)` — zero is a clean exit (§5.5).
    ProcessExited { fd: RawFd, status: i32 },
    /// [`Reactor::wake`] was called — a cross-thread or in-process nudge.
    Woken,
}

/// A `kqueue`-based readiness reactor.
///
/// The FreeBSD looper waits on one of these: it watches the descriptors of
/// the IPC rings it serves, and `wake` lets another thread (or an
/// in-process task) interrupt a `wait` in progress.
pub struct Reactor {
    kq: OwnedFd,
}

impl Reactor {
    /// Create a reactor, with its wakeup channel armed.
    pub fn new() -> io::Result<Reactor> {
        // SAFETY: `abyss_kqueue` wraps `kqueue()`, which takes no arguments.
        let raw = unsafe { abyss_kqueue() };
        if raw < 0 {
            return Err(io::Error::last_os_error());
        }
        // SAFETY: `kqueue()` just produced `raw` as a fresh owned descriptor.
        let kq = unsafe { OwnedFd::from_raw_fd(raw) };
        // SAFETY: `kq` is a live kqueue descriptor.
        if unsafe { abyss_kqueue_arm_wake(kq.as_raw_fd()) } < 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(Reactor { kq })
    }

    /// Watch `fd` for `interest`.
    pub fn register(&self, fd: BorrowedFd<'_>, interest: Interest) -> io::Result<()> {
        self.ctl(fd, interest, true)
    }

    /// Stop watching `fd` for `interest`.
    pub fn deregister(&self, fd: BorrowedFd<'_>, interest: Interest) -> io::Result<()> {
        self.ctl(fd, interest, false)
    }

    fn ctl(&self, fd: BorrowedFd<'_>, interest: Interest, add: bool) -> io::Result<()> {
        // SAFETY: the kqueue and `fd` are live; the shim issues one kevent.
        let rc = unsafe {
            abyss_kqueue_ctl(
                self.kq.as_raw_fd(),
                fd.as_raw_fd(),
                interest.as_raw(),
                c_int::from(add),
            )
        };
        if rc < 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(())
    }

    /// Wake a [`wait`](Self::wait) in progress — or the next one — from any
    /// thread. The waiting reactor returns an [`Event::Woken`].
    pub fn wake(&self) -> io::Result<()> {
        // SAFETY: `kq` is a live kqueue with the wake channel armed.
        if unsafe { abyss_kqueue_wake(self.kq.as_raw_fd()) } < 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(())
    }

    /// Block until a registered descriptor is ready, the reactor is woken,
    /// or `timeout` elapses. `None` blocks indefinitely.
    pub fn wait(&self, timeout: Option<Duration>) -> io::Result<Vec<Event>> {
        let mut raw = [AbyssEvent {
            ident: 0,
            data: 0,
            kind: 0,
        }; MAX_EVENTS];
        let timeout_ms = match timeout {
            None => -1,
            Some(d) => c_int::try_from(d.as_millis()).unwrap_or(c_int::MAX),
        };
        // SAFETY: `raw` is `MAX_EVENTS` long; the shim writes at most that
        // many events, and never more than the `max` passed.
        let n = unsafe {
            abyss_kqueue_wait(
                self.kq.as_raw_fd(),
                raw.as_mut_ptr(),
                MAX_EVENTS as c_int,
                timeout_ms,
            )
        };
        if n < 0 {
            return Err(io::Error::last_os_error());
        }
        let events = raw[..n as usize]
            .iter()
            .map(|e| match e.kind {
                1 => Event::Writable(e.ident as RawFd),
                2 => Event::Woken,
                3 => Event::ProcessExited {
                    fd: e.ident as RawFd,
                    status: e.data as i32,
                },
                _ => Event::Readable(e.ident as RawFd),
            })
            .collect();
        Ok(events)
    }
}

impl AsRawFd for Reactor {
    fn as_raw_fd(&self) -> RawFd {
        self.kq.as_raw_fd()
    }
}

/// A [`Reactor`] presented as a looper [`EventSource`]
/// (`docs/design/broker-and-transport.md` §2.3).
///
/// The looper blocks in `wait`; a registered descriptor's readiness — or a
/// `wake` from any thread — releases it and wakes the task parked on that
/// descriptor. This is what makes an IPC ring's `recv` and `send` suspend
/// the calling task rather than the looper thread.
pub struct ReactorSource {
    reactor: Reactor,
    /// The waker of each task parked on a descriptor, keyed by the
    /// descriptor and what it waits for.
    waiters: Mutex<HashMap<(RawFd, Interest), Waker>>,
}

impl ReactorSource {
    /// Create a reactor-backed event source. It is shared — between the
    /// looper that waits on it and the channels that register with it —
    /// so callers wrap it in an `Arc`.
    pub fn new() -> io::Result<ReactorSource> {
        Ok(ReactorSource {
            reactor: Reactor::new()?,
            waiters: Mutex::new(HashMap::new()),
        })
    }

    /// Park `waker` until `fd` reaches `interest`. The reactor registration
    /// is one-shot; a task re-registers on its next would-block poll.
    pub fn register(&self, fd: BorrowedFd<'_>, interest: Interest, waker: Waker) -> io::Result<()> {
        self.reactor.register(fd, interest)?;
        self.waiters
            .lock()
            .unwrap()
            .insert((fd.as_raw_fd(), interest), waker);
        Ok(())
    }
}

impl EventSource for ReactorSource {
    fn wait(&self) {
        // A failed wait reports as no events; the looper re-checks its
        // ready set and waits again.
        let Ok(events) = self.reactor.wait(None) else {
            return;
        };
        let mut waiters = self.waiters.lock().unwrap();
        for event in events {
            let key = match event {
                Event::Readable(fd) => (fd, Interest::Readable),
                Event::Writable(fd) => (fd, Interest::Writable),
                Event::ProcessExited { fd, .. } => (fd, Interest::ProcessExit),
                Event::Woken => continue,
            };
            if let Some(waker) = waiters.remove(&key) {
                waker.wake();
            }
        }
    }

    fn wake(&self) {
        let _ = self.reactor.wake();
    }
}

#[cfg(test)]
mod tests {
    use super::super::Channel;
    use super::*;
    use std::os::fd::AsFd;
    use std::sync::Arc;
    use std::thread;

    #[test]
    fn reports_a_readable_descriptor() {
        let (a, b) = Channel::pair().expect("socketpair");
        let reactor = Reactor::new().expect("kqueue");
        reactor
            .register(a.as_fd(), Interest::Readable)
            .expect("register");

        // Nothing sent yet — a short wait reports nothing.
        let idle = reactor
            .wait(Some(Duration::from_millis(50)))
            .expect("wait idle");
        assert!(idle.is_empty());

        // A send on the peer makes `a` readable.
        b.send(b"ping", &[]).expect("send");
        let ready = reactor
            .wait(Some(Duration::from_secs(1)))
            .expect("wait ready");
        assert_eq!(ready, vec![Event::Readable(a.as_raw_fd())]);
    }

    #[test]
    fn wake_unblocks_a_waiter() {
        let reactor = Arc::new(Reactor::new().expect("kqueue"));
        let waiter = Arc::clone(&reactor);

        // A wait with no timeout — only `wake` can release it.
        let handle = thread::spawn(move || waiter.wait(None).expect("wait"));
        thread::sleep(Duration::from_millis(100));
        reactor.wake().expect("wake");

        assert_eq!(handle.join().expect("join"), vec![Event::Woken]);
    }

    #[test]
    fn reports_a_process_descriptor_exit() {
        use freebsd_procdesc_sys::{SpawnOptions, spawn};
        use std::path::Path;

        // A child that lives just long enough for its descriptor to be
        // registered before it exits — non-zero, so the reported status is
        // distinguishable from a clean exit.
        let child = spawn(
            Path::new("/bin/sh"),
            &["-c", "sleep 0.3; exit 7"],
            &SpawnOptions::default(),
        )
        .expect("spawn a child");
        let pd = child.descriptor();

        let reactor = Reactor::new().expect("kqueue");
        reactor
            .register(pd, Interest::ProcessExit)
            .expect("register the process descriptor");

        let ready = reactor
            .wait(Some(Duration::from_secs(5)))
            .expect("wait for the child to exit");
        assert_eq!(ready.len(), 1, "exactly one event — the child's exit");
        match ready[0] {
            Event::ProcessExited { fd, status } => {
                assert_eq!(fd, pd.as_raw_fd());
                assert_ne!(status, 0, "a non-zero exit reports a non-zero status");
            }
            other => panic!("expected a process-exit event, got {other:?}"),
        }
    }
}
