// SPDX-License-Identifier: BSD-2-Clause

//! The FreeBSD process-descriptor binding — compiled only on FreeBSD.
//!
//! The `extern` declarations match `<sys/procdesc.h>`; the safe wrappers
//! are what the broker programs against. Verified when the crate is first
//! built on FreeBSD.

use std::ffi::c_int;
use std::io;
use std::os::fd::{FromRawFd, OwnedFd, RawFd};

unsafe extern "C" {
    // `pid_t` is `i32` on FreeBSD.
    fn pdfork(fdp: *mut c_int, flags: c_int) -> i32;
    fn pdkill(fd: c_int, signum: c_int) -> c_int;
    fn pdgetpid(fd: c_int, pidp: *mut i32) -> c_int;
}

/// The outcome of [`fork`] in the calling process.
pub enum Fork {
    /// The parent — it holds the child's process descriptor.
    Parent {
        /// The child's process id.
        pid: i32,
        /// The child's process descriptor: `kqueue`-monitorable, and
        /// closing it terminates the child (`broker-and-transport.md` §5.5).
        descriptor: OwnedFd,
    },
    /// The freshly-forked child.
    Child,
}

/// Fork, taking the child as a process descriptor rather than a bare pid.
///
/// Wraps `pdfork(2)` with no flags — the broker wants the child reaped
/// when it drops the descriptor, which is the default behaviour.
pub fn fork() -> io::Result<Fork> {
    let mut fd: c_int = -1;
    // SAFETY: `fd` is a valid out-pointer; `pdfork` writes the descriptor
    // there in the parent and leaves it untouched in the child.
    let pid = unsafe { pdfork(&mut fd, 0) };
    match pid {
        -1 => Err(io::Error::last_os_error()),
        0 => Ok(Fork::Child),
        pid => Ok(Fork::Parent {
            pid,
            // SAFETY: `pdfork` just produced `fd` as a fresh owned
            // descriptor in the parent.
            descriptor: unsafe { OwnedFd::from_raw_fd(fd) },
        }),
    }
}

/// Send signal `signum` to the process behind a descriptor. Wraps `pdkill(2)`.
pub fn kill(descriptor: RawFd, signum: c_int) -> io::Result<()> {
    // SAFETY: `pdkill` takes a descriptor fd and a signal number.
    if unsafe { pdkill(descriptor, signum) } < 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

/// The process id behind a process descriptor. Wraps `pdgetpid(2)`.
pub fn pid_of(descriptor: RawFd) -> io::Result<i32> {
    let mut pid: i32 = 0;
    // SAFETY: `pid` is a valid out-pointer for the `pid_t` result.
    if unsafe { pdgetpid(descriptor, &mut pid) } < 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(pid)
}
