//! The config directory watch of de/cpoolwatch (inotify on Linux, kqueue on
//! FreeBSD), as Pool.Watcher uses it from Swift, behind an owning handle.
//!
//! The kqueue half keeps a process-wide table (the watched directory and
//! each of its files, per watch) with no lock of its own, which Swift never
//! needed: nothing there waits on two watchers from two threads. Rust's
//! tests do, so every call that touches the table runs under one mutex
//! here. The blocking part of a wait is a `poll(2)` on the watch's
//! descriptor, outside the lock; only the drain that follows, a wait of
//! zero, takes it. The answers are `awc_watch_wait`'s.

use libc::{c_char, c_int};
use std::ffi::CString;
use std::io;
use std::os::fd::{AsFd, AsRawFd, BorrowedFd, RawFd};
use std::sync::Mutex;

unsafe extern "C" {
    fn awc_watch_open(dir: *const c_char) -> c_int;
    fn awc_watch_wait(fd: c_int, timeout_ms: c_int) -> c_int;
    fn awc_watch_close(fd: c_int);
}

static TABLE: Mutex<()> = Mutex::new(());

fn locked<T>(f: impl FnOnce() -> T) -> T {
    let _g = TABLE.lock().unwrap_or_else(|e| e.into_inner());
    f()
}

/// A watch on one directory: its descriptor becomes readable when a file in
/// it changes. Closed (with the C side's state) on drop.
#[derive(Debug)]
pub struct DirWatch(c_int);

impl DirWatch {
    /// `awc_watch_open(dir)`.
    pub fn open(dir: &str) -> io::Result<DirWatch> {
        let c = CString::new(dir).map_err(|_| io::Error::from_raw_os_error(libc::EINVAL))?;
        let fd = locked(|| unsafe { awc_watch_open(c.as_ptr()) });
        if fd < 0 { Err(io::Error::last_os_error()) } else { Ok(DirWatch(fd)) }
    }

    /// `awc_watch_wait(fd, timeout_ms)`: block up to `timeout_ms` (negative
    /// is forever) for a change, then drain. `Ok(true)` if the directory
    /// changed, `Ok(false)` on a timeout or an interrupted wait.
    pub fn wait(&self, timeout_ms: i32) -> io::Result<bool> {
        if timeout_ms != 0 {
            let mut p = libc::pollfd { fd: self.0, events: libc::POLLIN, revents: 0 };
            let r = unsafe { libc::poll(&mut p, 1, timeout_ms) };
            if r < 0 {
                let e = io::Error::last_os_error();
                return if e.raw_os_error() == Some(libc::EINTR) { Ok(false) } else { Err(e) };
            }
            if r == 0 {
                return Ok(false);
            }
        }
        match locked(|| unsafe { awc_watch_wait(self.0, 0) }) {
            r if r < 0 => Err(io::Error::last_os_error()),
            r => Ok(r == 1),
        }
    }
}

impl Drop for DirWatch {
    fn drop(&mut self) {
        locked(|| unsafe { awc_watch_close(self.0) })
    }
}

impl AsRawFd for DirWatch {
    fn as_raw_fd(&self) -> RawFd {
        self.0
    }
}

impl AsFd for DirWatch {
    fn as_fd(&self) -> BorrowedFd<'_> {
        // Open for as long as `self` is: only drop closes it.
        unsafe { BorrowedFd::borrow_raw(self.0) }
    }
}
