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
    fn abyss_pdspawn(
        path: *const c_char,
        argv: *const *const c_char,
        jid: c_int,
        bootstrap_fd: c_int,
        pd_out: *mut c_int,
    ) -> c_int;
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

/// How a [`spawn`]ed child is set up between the `pdfork` and the exec.
#[derive(Default)]
pub struct SpawnOptions<'fd> {
    /// Attach the child to this jail before the exec, so it lands confined
    /// (`broker-and-transport.md` §5.3).
    pub jail: Option<i32>,
    /// Hand the child this descriptor as fd 3 — its bootstrap socket, over
    /// which the broker sends the bootstrap bundle (§5.3).
    pub bootstrap_fd: Option<BorrowedFd<'fd>>,
}

/// `pdfork` a child that immediately execs `program` with `args`.
///
/// `args` is the argument vector *after* `argv[0]`; the shim passes
/// `program` itself as `argv[0]`. [`SpawnOptions`] place the child in a
/// jail and hand it a bootstrap socket as fd 3 before the exec. The
/// `pdfork`-then-`execve` runs entirely inside the C shim — no Rust code
/// executes in the forked child (`broker-and-transport.md` §5.3).
pub fn spawn(program: &Path, args: &[&str], options: &SpawnOptions<'_>) -> io::Result<Child> {
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
    // A negative jid spawns the child unjailed; a negative bootstrap fd
    // hands it no bootstrap socket.
    let jid = options.jail.unwrap_or(-1);
    let bootstrap_fd = options.bootstrap_fd.map_or(-1, |fd| fd.as_raw_fd());
    // SAFETY: `path` and every `argv` entry are NUL-terminated `CString`s
    // that outlive the call; `argv` is NULL-terminated; the bootstrap fd,
    // if any, is borrowed for the call; `pd` is a valid out-pointer the
    // shim writes only in the parent.
    let pid = unsafe { abyss_pdspawn(path.as_ptr(), argv.as_ptr(), jid, bootstrap_fd, &mut pd) };
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
    use std::io::Write;

    #[test]
    fn spawn_runs_a_program_to_completion() {
        // A unique marker so concurrent test runs do not collide.
        let marker = format!("/tmp/abyss-procdesc-spawn-{}", std::process::id());
        let _ = fs::remove_file(&marker);

        let script = format!("echo abyss-spawned > {marker}");
        let child = spawn(
            Path::new("/bin/sh"),
            &["-c", &script],
            &SpawnOptions::default(),
        )
        .expect("spawn /bin/sh");
        assert!(child.pid() > 0);
        child.wait().expect("wait for the child to exit");

        let written = fs::read_to_string(&marker).expect("the child wrote the marker file");
        assert_eq!(written.trim(), "abyss-spawned");
        let _ = fs::remove_file(&marker);
    }

    #[test]
    fn spawn_reports_a_missing_program() {
        let err = spawn(
            Path::new("/nonexistent/abyss/program"),
            &[],
            &SpawnOptions::default(),
        );
        // The shim still forks and returns a pid; the child's failed
        // execve is its own exit, not a spawn error — so spawn succeeds
        // and the child exits 127. The wait simply completes.
        let child = err.expect("pdfork itself succeeds");
        child.wait().expect("the child exits after the failed exec");
    }

    #[test]
    fn spawn_attaches_the_child_to_a_jail() {
        let marker = format!("/tmp/abyss-procdesc-jail-{}", std::process::id());
        let _ = fs::remove_file(&marker);

        // A `path = "/"` jail — no filesystem isolation, but the child is
        // still jailed, which `security.jail.jailed` reports as 1.
        let name = format!("abyss-spawn-test-{}", std::process::id());
        let spec = freebsd_jail_sys::JailSpec::new(Path::new("/"), &name).expect("jail spec");
        let jid = spec.create().expect("create the jail");

        let script = format!("sysctl -n security.jail.jailed > {marker}");
        let child = spawn(
            Path::new("/bin/sh"),
            &["-c", &script],
            &SpawnOptions {
                jail: Some(jid),
                ..SpawnOptions::default()
            },
        )
        .expect("spawn into the jail");
        child.wait().expect("wait for the child to exit");
        let _ = freebsd_jail_sys::remove(jid);

        let jailed = fs::read_to_string(&marker).expect("the child wrote the marker file");
        assert_eq!(jailed.trim(), "1", "the spawned child should be jailed");
        let _ = fs::remove_file(&marker);
    }

    #[test]
    fn spawn_hands_the_child_a_bootstrap_fd() {
        let marker = format!("/tmp/abyss-procdesc-boot-{}", std::process::id());
        let _ = fs::remove_file(&marker);

        // A pipe stands in for the bootstrap socket: the parent writes the
        // bundle bytes, the child reads them from fd 3.
        let (reader, mut writer) = std::io::pipe().expect("pipe");
        let bundle: &[u8] = b"abyss-bootstrap-bundle";

        // `head -c N <&3` reads exactly the bundle off fd 3, no EOF needed.
        let script = format!("head -c {} <&3 > {marker}", bundle.len());
        let child = spawn(
            Path::new("/bin/sh"),
            &["-c", &script],
            &SpawnOptions {
                bootstrap_fd: Some(reader.as_fd()),
                ..SpawnOptions::default()
            },
        )
        .expect("spawn with a bootstrap fd");

        writer.write_all(bundle).expect("send the bundle");
        child.wait().expect("wait for the child to exit");

        let got = fs::read(&marker).expect("the child read its bootstrap fd");
        assert_eq!(
            got.as_slice(),
            bundle,
            "the child receives the bundle on fd 3"
        );
        let _ = fs::remove_file(&marker);
    }
}
