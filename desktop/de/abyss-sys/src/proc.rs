//! de/cproc: every child a pollable descriptor (pdfork on FreeBSD, fork +
//! pidfd_open on Linux), the signal self-pipe, and poll(2) itself; with
//! cplatform's `ap_self_executable`. In C because the two mechanisms differ
//! and a post-fork child may only make async-signal-safe calls: argv and
//! envp are built here, before the fork.

use libc::{c_char, c_int};
use std::ffi::CString;
use std::io;
use std::os::fd::{AsRawFd, BorrowedFd, FromRawFd, OwnedFd, RawFd};

pub use libc::{pollfd as PollFd, POLLERR, POLLHUP, POLLIN};

#[repr(C)]
#[derive(Clone, Copy)]
struct ApChild {
    fd: c_int,
    pid: c_int,
}

unsafe extern "C" {
    fn ap_child_exit_events() -> c_int;
    fn ap_child_spawn(argv: *const *const c_char, envp: *const *const c_char, stdout_fd: c_int, out: *mut ApChild) -> c_int;
    fn ap_child_spawn_as(user: *const c_char, argv: *const *const c_char, envp: *const *const c_char, stdout_fd: c_int, out: *mut ApChild) -> c_int;
    fn ap_vt_activate(vt: c_int) -> c_int;
    fn ap_child_signal(c: *const ApChild, sig: c_int) -> c_int;
    fn ap_child_reap(c: *mut ApChild, status: *mut c_int) -> c_int;
    fn ap_signal_pipe(sigs: *const c_int, count: c_int) -> c_int;
    fn ap_self_executable(buf: *mut c_char, len: usize) -> libc::c_long;
}

/// The poll(2) events that mean a child exited (POLLHUP for a process
/// descriptor, POLLIN for a pidfd), with POLLERR and POLLHUP besides.
pub fn child_exit_events() -> i16 {
    (unsafe { ap_child_exit_events() } as i16) | POLLERR | POLLHUP | POLLIN
}

/// A supervised child: a descriptor that becomes ready when it exits, and
/// its pid. Reap it with [`Child::reap`]; one dropped unreaped keeps its
/// descriptor until this process exits (nothing here waits behind your back).
pub struct Child {
    raw: ApChild,
}

impl Child {
    /// fork (pdfork) and execve `argv` (argv[0] absolute; nothing searches
    /// PATH) with `envp` (`KEY=VALUE`), stdout and stderr onto `stdout` when
    /// given.
    pub fn spawn(argv: &[String], envp: &[String], stdout: Option<BorrowedFd<'_>>) -> io::Result<Child> {
        Child::start(None, argv, envp, stdout)
    }

    /// `spawn`, as `user` (P16.5b): the account's groups, limits and uid,
    /// in its home, before execve. Root may spawn as anyone, anyone else
    /// only as themselves; ENOENT for no such account, EPERM for another's.
    pub fn spawn_as(user: &str, argv: &[String], envp: &[String], stdout: Option<BorrowedFd<'_>>) -> io::Result<Child> {
        Child::start(Some(user), argv, envp, stdout)
    }

    fn start(user: Option<&str>, argv: &[String], envp: &[String], stdout: Option<BorrowedFd<'_>>) -> io::Result<Child> {
        let user = user.map(CString::new).transpose()?;
        let c = |v: &[String]| v.iter().map(|s| CString::new(s.as_bytes())).collect::<Result<Vec<_>, _>>();
        let (args, envs) = (c(argv)?, c(envp)?);
        if args.is_empty() {
            return Err(io::Error::from_raw_os_error(libc::EINVAL));
        }
        let mut ap: Vec<*const c_char> = args.iter().map(|a| a.as_ptr()).collect();
        ap.push(std::ptr::null());
        let mut ep: Vec<*const c_char> = envs.iter().map(|e| e.as_ptr()).collect();
        ep.push(std::ptr::null());
        let mut raw = ApChild { fd: -1, pid: -1 };
        let out = stdout.map_or(-1, |f| f.as_raw_fd());
        let rc = match &user {
            Some(u) => unsafe { ap_child_spawn_as(u.as_ptr(), ap.as_ptr(), ep.as_ptr(), out, &mut raw) },
            None => unsafe { ap_child_spawn(ap.as_ptr(), ep.as_ptr(), out, &mut raw) },
        };
        if rc != 0 { Err(io::Error::last_os_error()) } else { Ok(Child { raw }) }
    }

    /// Its exit descriptor, for poll; -1 once reaped.
    pub fn fd(&self) -> RawFd {
        self.raw.fd
    }

    pub fn pid(&self) -> i32 {
        self.raw.pid
    }

    pub fn is_live(&self) -> bool {
        self.raw.fd >= 0
    }

    pub fn signal(&self, sig: i32) -> io::Result<()> {
        if unsafe { ap_child_signal(&self.raw, sig) } == 0 { Ok(()) } else { Err(io::Error::last_os_error()) }
    }

    /// Reap it and release its descriptor: its wait status. Again is a no-op.
    pub fn reap(&mut self) -> Option<i32> {
        if self.raw.fd < 0 {
            return None;
        }
        let mut status = 0;
        (unsafe { ap_child_reap(&mut self.raw, &mut status) } == 0).then_some(status)
    }
}

/// Bring virtual terminal `vt` (1-based) to the front and wait for it.
pub fn vt_activate(vt: i32) -> io::Result<()> {
    if unsafe { ap_vt_activate(vt) } == 0 { Ok(()) } else { Err(io::Error::last_os_error()) }
}

/// A pipe carrying the number of each of `sigs` as one byte, from a handler
/// whose whole body is one write(2): how a poll loop hears SIGTERM.
pub fn signal_pipe(sigs: &[i32]) -> io::Result<OwnedFd> {
    let fd = unsafe { ap_signal_pipe(sigs.as_ptr(), sigs.len() as c_int) };
    if fd < 0 { Err(io::Error::last_os_error()) } else { Ok(unsafe { OwnedFd::from_raw_fd(fd) }) }
}

/// poll(2) over `fds`, `timeout_ms` (-1 for ever): how many are ready.
pub fn poll(fds: &mut [PollFd], timeout_ms: i32) -> io::Result<usize> {
    let n = unsafe { libc::poll(fds.as_mut_ptr(), fds.len() as libc::nfds_t, timeout_ms) };
    if n < 0 { Err(io::Error::last_os_error()) } else { Ok(n as usize) }
}

/// A pollfd for `fd`, wanting `events`.
pub fn poll_fd(fd: RawFd, events: i16) -> PollFd {
    PollFd { fd, events, revents: 0 }
}

/// This program's own path.
pub fn self_executable() -> Option<String> {
    let mut buf = vec![0u8; 4096];
    let n = unsafe { ap_self_executable(buf.as_mut_ptr().cast(), buf.len()) };
    (n > 0).then(|| String::from_utf8_lossy(&buf[..n as usize]).into_owned())
}
