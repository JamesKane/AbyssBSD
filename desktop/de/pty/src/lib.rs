//! A program on a pseudo-terminal (Pty.swift, P15.4a): the shell under
//! Terminal, started on the slave side as its controlling terminal and
//! talked to through the master. The fork is abyss-sys's; this is the argv
//! and environment built before it, reads and writes on the master, the
//! window size, and reaping the child.

use std::collections::BTreeMap;
use std::fs::File;
use std::io::{self, Read, Write};
use std::os::fd::{AsFd, AsRawFd, BorrowedFd};

/// What a terminal says it is (PHASE15 §6.4): `xterm`, which claims less
/// than `xterm-256color`, until the parser is measured against vttest.
pub const TERM: &str = "xterm";

pub struct Pty {
    /// The master side: non-blocking, close-on-exec.
    master: File,
    pid: i32,
    exit_status: Option<i32>,
}

impl Pty {
    /// Start `argv` on a new terminal of `rows` × `cols`; `environment` is
    /// added to this process's, after `TERM`, and `directory` is where it
    /// starts.
    pub fn spawn(argv: &[&str], rows: usize, cols: usize, environment: &BTreeMap<String, String>, directory: Option<&str>) -> Option<Pty> {
        let exe = spawn::resolve_executable(argv.first()?, None)?;
        let mut env: BTreeMap<String, String> = [("TERM", TERM.to_string()), ("COLUMNS", cols.to_string()), ("LINES", rows.to_string())].into_iter().map(|(k, v)| (k.to_string(), v)).collect();
        env.extend(environment.iter().map(|(k, v)| (k.clone(), v.clone())));
        let args: Vec<Vec<u8>> = argv.iter().map(|a| a.as_bytes().to_vec()).collect();
        let size = |n: usize| n.min(u16::MAX as usize) as u16;
        let (fd, pid) = abyss_sys::pty::spawn(exe.as_bytes(), &args, &spawn::environment_block(&env), directory, size(rows), size(cols)).ok()?;
        Some(Pty { master: File::from(fd), pid, exit_status: None })
    }

    pub fn fd(&self) -> BorrowedFd<'_> {
        self.master.as_fd()
    }
    pub fn pid(&self) -> i32 {
        self.pid
    }
    pub fn exit_status(&self) -> Option<i32> {
        self.exit_status
    }

    /// Everything readable now; empty when there is nothing, None at end of
    /// file (the program and all it started have closed the terminal).
    pub fn read(&mut self) -> Option<Vec<u8>> {
        let mut out = vec![];
        let mut buf = [0u8; 16384];
        loop {
            match self.master.read(&mut buf) {
                Ok(0) => return (!out.is_empty()).then_some(out),
                Ok(n) => out.extend_from_slice(&buf[..n]),
                Err(e) if e.kind() == io::ErrorKind::Interrupted => {}
                // EIO: Linux's end of file on a master whose slave has
                // closed. EAGAIN: nothing more now.
                Err(e) if e.raw_os_error() == Some(libc::EIO) && out.is_empty() => return None,
                Err(_) => return Some(out),
            }
        }
    }

    /// Write all of `bytes`, waiting for room if the program is slow to read.
    pub fn write(&mut self, bytes: &[u8]) -> bool {
        let mut off = 0;
        while off < bytes.len() {
            match self.master.write(&bytes[off..]) {
                Ok(n) if n > 0 => off += n,
                Err(e) if e.kind() == io::ErrorKind::Interrupted => {}
                Err(e) if e.kind() == io::ErrorKind::WouldBlock => {
                    let mut p = [abyss_sys::proc::poll_fd(self.master.as_raw_fd(), libc::POLLOUT)];
                    let _ = abyss_sys::proc::poll(&mut p, 100);
                }
                _ => return false,
            }
        }
        true
    }

    pub fn resize(&self, rows: usize, cols: usize) {
        let size = |n: usize| n.min(u16::MAX as usize) as u16;
        abyss_sys::pty::resize(self.master.as_raw_fd(), size(rows), size(cols));
    }

    /// Wait up to `timeout_ms` for output.
    pub fn wait(&self, timeout_ms: i32) -> bool {
        abyss_sys::vents::poll_readable(self.master.as_fd(), timeout_ms)
    }

    /// Reap the child if it has exited; its wait status, once it has.
    pub fn reap(&mut self) -> Option<i32> {
        if self.exit_status.is_none() {
            self.exit_status = abyss_sys::pty::try_wait(self.pid)
        }
        self.exit_status
    }
}

impl Drop for Pty {
    /// What closing a terminal window says: SIGHUP, and reap if it went.
    fn drop(&mut self) {
        if self.exit_status.is_none() {
            let _ = abyss_sys::proc::kill_pid(self.pid, libc::SIGHUP);
            let _ = abyss_sys::pty::try_wait(self.pid);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_program_on_a_terminal_is_read_written_and_reaped() {
        let mut p = Pty::spawn(&["/bin/sh", "-c", "read x; echo \"got $x\"; stty size"], 7, 33, &BTreeMap::new(), None).unwrap();
        assert!(p.write(b"hi\r"));
        let mut out = vec![];
        for _ in 0..50 {
            p.wait(100);
            match p.read() {
                Some(b) => out.extend(b),
                None => break,
            }
            if p.reap().is_some() && String::from_utf8_lossy(&out).contains("7 33") {
                break;
            }
        }
        let text = String::from_utf8_lossy(&out);
        assert!(text.contains("got hi") && text.contains("7 33"), "{text:?}");
    }
}
