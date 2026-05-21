// SPDX-License-Identifier: BSD-2-Clause

//! The FreeBSD process-descriptor binding — compiled only on FreeBSD.
//!
//! [`spawn`] calls `abyss_pdspawn` in `c/procdesc_shim.c`, which does the
//! `pdfork`-then-`execve` in C — no Rust runs in the forked child. `pdkill`
//! is an ordinary libc function and is bound directly. The signatures are
//! verified against `<sys/procdesc.h>` when the crate is first built on
//! FreeBSD.

use std::ffi::{CString, NulError, c_char, c_int};
use std::io;
use std::os::fd::{AsFd, AsRawFd, BorrowedFd, FromRawFd, OwnedFd};
use std::path::Path;
use std::ptr;

unsafe extern "C" {
    fn abyss_pdspawn(path: *const c_char, argv: *const *const c_char, pd_out: *mut c_int) -> c_int;
    fn abyss_pd_wait(pd: c_int) -> c_int;
    fn pdkill(fd: c_int, signum: c_int) -> c_int;
}

/// A spawned child process, held by its process descriptor.
///
/// The descriptor is `kqueue`-monitorable and terminates the child when
/// dropped — no `SIGCHLD` race, no pid reuse
/// (`broker-and-transport.md` §5.5).
pub struct Child {
    pid: i32,
    descriptor: OwnedFd,
}

impl Child {
    /// The child's process id.
    pub fn pid(&self) -> i32 {
        self.pid
    }

    /// The child's process descriptor, borrowed — for `kqueue` supervision.
    pub fn descriptor(&self) -> BorrowedFd<'_> {
        self.descriptor.as_fd()
    }

    /// Block until the child exits.
    pub fn wait(&self) -> io::Result<()> {
        // SAFETY: `descriptor` is a live process descriptor.
        if unsafe { abyss_pd_wait(self.descriptor.as_raw_fd()) } < 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(())
    }

    /// Send signal `signum` to the child. Wraps `pdkill(2)`.
    pub fn kill(&self, signum: c_int) -> io::Result<()> {
        // SAFETY: `descriptor` is a live process descriptor.
        if unsafe { pdkill(self.descriptor.as_raw_fd(), signum) } < 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(())
    }
}

/// `pdfork` a child that immediately execs `program` with `args`.
///
/// `args` is the argument vector *after* `argv[0]`; the shim passes
/// `program` itself as `argv[0]`. The `pdfork`-then-`execve` runs entirely
/// inside the C shim — no Rust code executes in the forked child
/// (`broker-and-transport.md` §5.3).
pub fn spawn(program: &Path, args: &[&str]) -> io::Result<Child> {
    let path = cstring(program.as_os_str().as_encoded_bytes())?;
    // argv: `program` as argv[0], then `args`, then a NULL terminator.
    let mut owned = Vec::with_capacity(args.len() + 1);
    owned.push(path.clone());
    for arg in args {
        owned.push(cstring(arg.as_bytes())?);
    }
    let mut argv: Vec<*const c_char> = owned.iter().map(|c| c.as_ptr()).collect();
    argv.push(ptr::null());

    let mut pd: c_int = -1;
    // SAFETY: `path` and every `argv` entry are NUL-terminated `CString`s
    // that outlive the call; `argv` is NULL-terminated; `pd` is a valid
    // out-pointer the shim writes only in the parent.
    let pid = unsafe { abyss_pdspawn(path.as_ptr(), argv.as_ptr(), &mut pd) };
    if pid < 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(Child {
        pid,
        // SAFETY: `abyss_pdspawn` produced `pd` as a fresh owned descriptor.
        descriptor: unsafe { OwnedFd::from_raw_fd(pd) },
    })
}

/// A `CString` from bytes, mapping an interior NUL to an `io` error.
fn cstring(bytes: &[u8]) -> io::Result<CString> {
    CString::new(bytes).map_err(|_: NulError| {
        io::Error::new(
            io::ErrorKind::InvalidInput,
            "a spawn argument contains a NUL byte",
        )
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    #[test]
    fn spawn_runs_a_program_to_completion() {
        // A unique marker so concurrent test runs do not collide.
        let marker = format!("/tmp/abyss-procdesc-spawn-{}", std::process::id());
        let _ = fs::remove_file(&marker);

        let script = format!("echo abyss-spawned > {marker}");
        let child = spawn(Path::new("/bin/sh"), &["-c", &script]).expect("spawn /bin/sh");
        assert!(child.pid() > 0);
        child.wait().expect("wait for the child to exit");

        let written = fs::read_to_string(&marker).expect("the child wrote the marker file");
        assert_eq!(written.trim(), "abyss-spawned");
        let _ = fs::remove_file(&marker);
    }

    #[test]
    fn spawn_reports_a_missing_program() {
        let err = spawn(Path::new("/nonexistent/abyss/program"), &[]);
        // The shim still forks and returns a pid; the child's failed
        // execve is its own exit, not a spawn error — so spawn succeeds
        // and the child exits 127. The wait simply completes.
        let child = err.expect("pdfork itself succeeds");
        child.wait().expect("the child exits after the failed exec");
    }
}
