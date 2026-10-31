//! A program on a pseudo-terminal (Pty.swift's C half, cplatform's
//! `ap_pty_spawn`): started on the slave side as its controlling terminal,
//! talked to through the master. The fork-and-exec is C, so the child makes
//! only async-signal-safe calls (HANDOFF §2.25); everything it needs is
//! built here, before the fork.

use std::ffi::CString;
use std::io;
use std::os::fd::{FromRawFd, OwnedFd, RawFd};
use std::os::raw::{c_char, c_int, c_ushort};

unsafe extern "C" {
    fn ap_pty_spawn(path: *const c_char, argv: *const *const c_char, envp: *const *const c_char, cwd: *const c_char, rows: c_ushort, cols: c_ushort, master_out: *mut c_int) -> c_int;
    fn ap_pty_resize(master: c_int, rows: c_ushort, cols: c_ushort) -> c_int;
}

/// Start `exe` (absolute) with `argv` and `env` (`KEY=VALUE`) on a new
/// terminal of `rows` × `cols`, in `cwd` if given: the master side
/// (non-blocking, close-on-exec) and the child's pid.
pub fn spawn(exe: &[u8], argv: &[Vec<u8>], env: &[Vec<u8>], cwd: Option<&str>, rows: u16, cols: u16) -> io::Result<(OwnedFd, i32)> {
    let c = |s: &[u8]| CString::new(s).map_err(|_| io::Error::from(io::ErrorKind::InvalidInput));
    let path = c(exe)?;
    let args = argv.iter().map(|a| c(a)).collect::<io::Result<Vec<_>>>()?;
    let envs = env.iter().map(|e| c(e)).collect::<io::Result<Vec<_>>>()?;
    let dir = cwd.map(|d| c(d.as_bytes())).transpose()?;
    let mut argp: Vec<*const c_char> = args.iter().map(|a| a.as_ptr()).collect();
    argp.push(std::ptr::null());
    let mut envp: Vec<*const c_char> = envs.iter().map(|e| e.as_ptr()).collect();
    envp.push(std::ptr::null());
    let mut master: c_int = -1;
    let pid = unsafe { ap_pty_spawn(path.as_ptr(), argp.as_ptr(), envp.as_ptr(), dir.as_ref().map_or(std::ptr::null(), |d| d.as_ptr()), rows, cols, &mut master) };
    if pid <= 0 || master < 0 {
        return Err(io::Error::last_os_error());
    }
    Ok((unsafe { OwnedFd::from_raw_fd(master) }, pid))
}

/// Tell the terminal its size (TIOCSWINSZ); the kernel sends the
/// foreground process group SIGWINCH.
pub fn resize(master: RawFd, rows: u16, cols: u16) -> bool {
    unsafe { ap_pty_resize(master, rows, cols) == 0 }
}

/// Reap `pid` if it has exited: its wait status, once it has.
pub fn try_wait(pid: i32) -> Option<i32> {
    let mut status = 0;
    (unsafe { libc::waitpid(pid, &mut status, libc::WNOHANG) } == pid).then_some(status)
}
