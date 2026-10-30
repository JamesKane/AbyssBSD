//! The one spawn std cannot do safely: detached (Spawn.swift's `detached`).
//! A program started in a new session and reparented to init, never ours to
//! reap: fork, fork again and leave, setsid, execve.
//!
//! **After `fork` a child may only make async-signal-safe calls** until it
//! execs (HANDOFF §2.25): the parent may have held the allocator's lock at
//! the instant of the fork. So everything is built here, before the fork:
//! the path, argv and the environment as C strings and pointer arrays. The
//! children call only `fork`, `setsid`, `execve` and `_exit`.

use std::ffi::CString;

/// Run `exe` (an absolute path, resolved by the caller) with `argv` and
/// `env` (`KEY=VALUE`), detached. False when a string holds a NUL or the
/// first fork fails; an exec that fails in the grandchild exits 127, unseen.
pub fn detached(exe: &[u8], argv: &[Vec<u8>], env: &[Vec<u8>]) -> bool {
    let c = |s: &[u8]| CString::new(s).ok();
    let Some(path) = c(exe) else { return false };
    let Some(args) = argv.iter().map(|a| c(a)).collect::<Option<Vec<_>>>() else { return false };
    let Some(envs) = env.iter().map(|e| c(e)).collect::<Option<Vec<_>>>() else { return false };
    let mut argp: Vec<*const libc::c_char> = args.iter().map(|a| a.as_ptr()).collect();
    argp.push(std::ptr::null());
    let mut envp: Vec<*const libc::c_char> = envs.iter().map(|e| e.as_ptr()).collect();
    envp.push(std::ptr::null());
    let (path, argp, envp) = (path.as_ptr(), argp.as_ptr(), envp.as_ptr());

    let middle = unsafe { libc::fork() };
    if middle < 0 {
        return false;
    }
    if middle == 0 {
        // The middle child forks again and leaves, so the grandchild is
        // reparented to init and nobody here waits for it.
        unsafe {
            if libc::fork() == 0 {
                libc::setsid();
                libc::execve(path, argp, envp);
                libc::_exit(127);
            }
            libc::_exit(0);
        }
    }
    let mut status = 0;
    while unsafe { libc::waitpid(middle, &mut status, 0) } < 0 && std::io::Error::last_os_error().raw_os_error() == Some(libc::EINTR) {}
    true
}

/// Whether a child of this process is waiting to be reaped, or running:
/// `waitpid(-1, WNOHANG)` finding one. For tests that a spawn left nothing.
pub fn has_children() -> bool {
    let mut status = 0;
    let rc = unsafe { libc::waitpid(-1, &mut status, libc::WNOHANG) };
    rc != -1 || std::io::Error::last_os_error().raw_os_error() != Some(libc::ECHILD)
}

/// This process's session.
pub fn session_id() -> i32 {
    unsafe { libc::getsid(0) }
}

/// access(2) with X_OK: whether this process may execute `path`.
pub fn executable(path: &str) -> bool {
    let Ok(p) = CString::new(path) else { return false };
    unsafe { libc::access(p.as_ptr(), libc::X_OK) == 0 }
}
