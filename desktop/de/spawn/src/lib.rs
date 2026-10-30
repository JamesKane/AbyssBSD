//! Spawn in Rust (RUST.md R3): start programs safely, detached or run to
//! completion with their output (BACKLOG S.2 and S.3), ported from
//! Spawn.swift beside it.
//!
//! **After `fork` a child may only make async-signal-safe calls** until it
//! execs (HANDOFF §2.25). `detached` is the double fork, in abyss-sys, with
//! everything built before it; `run` is std's `Command`, whose child is
//! std's and which forks nothing in our code. The executable is always
//! resolved here, in the parent, so no child ever searches `PATH`.
//!
//! `run`'s three rules, which each cost a bug in Swift: stdin is `/dev/null`
//! unless input is given (a program that asks a question must not hang its
//! caller); stdout and stderr are read at once (`fathom` read stdout to the
//! end before stderr, and deadlocked); and past `limit` the rest is read and
//! dropped, so a chatty program runs to its real end rather than dying of
//! SIGPIPE (the installer closed the pipe at 8 KiB).

use std::collections::BTreeMap;
use std::fs;
use std::io::{self, Read, Write};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::process::ExitStatusExt;
use std::process::{Command, Stdio};
use std::thread;

/// A command as an absolute executable: as given when it holds a slash,
/// otherwise searched along `path` (default `$PATH`, else `/usr/bin:/bin`).
/// None when nothing executable is found.
pub fn resolve_executable(command: &str, path: Option<&str>) -> Option<String> {
    if command.is_empty() {
        return None;
    }
    if command.contains('/') {
        return is_executable_file(command).then(|| command.to_owned());
    }
    let from_env = std::env::var("PATH").ok();
    let search = path.or(from_env.as_deref()).unwrap_or("/usr/bin:/bin");
    search
        .split(':')
        .filter(|d| !d.is_empty())
        .map(|d| if d.ends_with('/') { format!("{d}{command}") } else { format!("{d}/{command}") })
        .find(|c| is_executable_file(c))
}

/// A regular file this process may execute: a directory is "executable"
/// and not a program.
fn is_executable_file(p: &str) -> bool {
    fs::metadata(p).is_ok_and(|m| m.is_file()) && abyss_sys::spawn::executable(p)
}

/// This process's environment as `KEY=VALUE`, with `extra` added or
/// overriding.
pub fn environment_block(extra: &BTreeMap<String, String>) -> Vec<Vec<u8>> {
    let mut out: Vec<Vec<u8>> = std::env::vars_os()
        .filter(|(k, _)| k.to_str().is_none_or(|k| !extra.contains_key(k)))
        .map(|(k, v)| [k.as_bytes(), b"=", v.as_bytes()].concat())
        .collect();
    out.extend(extra.iter().map(|(k, v)| format!("{k}={v}").into_bytes()));
    out
}

/// Run `argv` detached: in a new session, reparented to init, never ours
/// to reap. False when the program cannot be found or the fork fails.
/// `environment` is added to (and overrides) ours.
pub fn detached(argv: &[&str], environment: &BTreeMap<String, String>) -> bool {
    let Some(exe) = argv.first().and_then(|c| resolve_executable(c, None)) else { return false };
    let args: Vec<Vec<u8>> = argv.iter().map(|a| a.as_bytes().to_vec()).collect();
    abyss_sys::spawn::detached(exe.as_bytes(), &args, &environment_block(environment))
}

/// Where a child's stderr goes.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ErrorOutput {
    /// Captured on its own, in `Output::stderr`: to quote, never to parse.
    Capture,
    /// Into stdout's pipe, in order.
    Merge,
    /// Left as ours.
    Inherit,
}

/// What a finished program left behind.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Output {
    /// The raw wait status, or None when it never ran.
    pub raw_status: Option<i32>,
    pub stdout: Vec<u8>,
    pub stderr: Vec<u8>,
    /// Why it never ran, when it did not.
    pub failure: Option<String>,
}

impl Output {
    fn never(why: String) -> Output {
        Output { raw_status: None, stdout: vec![], stderr: vec![], failure: Some(why) }
    }

    /// Its exit code, if it exited rather than being killed.
    pub fn exit_code(&self) -> Option<i32> {
        self.raw_status.filter(|s| s & 0x7f == 0).map(|s| (s >> 8) & 0xff)
    }

    /// The signal that killed it, if one did.
    pub fn signal(&self) -> Option<i32> {
        self.raw_status.filter(|s| s & 0x7f != 0).map(|s| s & 0x7f)
    }

    /// One number, the shell's: the exit code, 128 + a signal, 127 when the
    /// program was not found, -1 when it could not be started at all.
    pub fn code(&self) -> i32 {
        if let Some(e) = self.exit_code() {
            e
        } else if let Some(g) = self.signal() {
            128 + g
        } else if self.failure.as_deref().is_some_and(|f| f.ends_with(": not found")) {
            127
        } else {
            -1
        }
    }

    pub fn succeeded(&self) -> bool {
        self.exit_code() == Some(0)
    }

    pub fn stdout_text(&self) -> String {
        String::from_utf8_lossy(&self.stdout).into_owned()
    }

    pub fn stderr_text(&self) -> String {
        String::from_utf8_lossy(&self.stderr).into_owned()
    }
}

/// How to run a program: its input, where stderr goes, what it adds to
/// the environment, and how much of each stream to keep.
#[derive(Clone, Debug)]
pub struct Options {
    pub input: Option<Vec<u8>>,
    pub stderr: ErrorOutput,
    pub environment: BTreeMap<String, String>,
    pub limit: usize,
}

impl Default for Options {
    fn default() -> Options {
        Options { input: None, stderr: ErrorOutput::Capture, environment: BTreeMap::new(), limit: 1 << 20 }
    }
}

/// Run `argv` to completion with the defaults, and collect what it printed.
pub fn run(argv: &[&str]) -> Output {
    run_with(argv, Options::default())
}

/// The first `limit` bytes of `r`, reading (and dropping) the rest to EOF.
fn read_kept(mut r: impl Read, limit: usize) -> Vec<u8> {
    let mut kept = vec![];
    let mut chunk = [0u8; 16384];
    loop {
        match r.read(&mut chunk) {
            Ok(0) => return kept,
            Ok(n) => {
                let keep = n.min(limit.saturating_sub(kept.len()));
                kept.extend_from_slice(&chunk[..keep]);
            }
            Err(e) if e.kind() == io::ErrorKind::Interrupted => {}
            Err(_) => return kept,
        }
    }
}

/// io::Error's words, without std's " (os error N)", as strerror says them.
fn words(e: &io::Error) -> String {
    let s = e.to_string();
    match s.rfind(" (os error ") {
        Some(i) => s[..i].to_owned(),
        None => s,
    }
}

/// Run `argv` to completion and collect what it printed. Each stream is
/// read on a thread of its own, and the input written on another, so none
/// can block the rest; a child that exits without reading its input is
/// EPIPE to the writer, never a signal (Rust ignores SIGPIPE).
pub fn run_with(argv: &[&str], o: Options) -> Output {
    let Some(first) = argv.first() else { return Output::never("empty command".into()) };
    let Some(exe) = resolve_executable(first, None) else { return Output::never(format!("{first}: not found")) };
    let mut cmd = Command::new(&exe);
    cmd.args(&argv[1..]).envs(&o.environment).stdin(if o.input.is_some() { Stdio::piped() } else { Stdio::null() });
    let merged = match o.stderr {
        ErrorOutput::Merge => match io::pipe() {
            Ok((reader, writer)) => {
                let Ok(w2) = writer.try_clone() else { return Output::never(format!("pipe: {}", words(&io::Error::last_os_error()))) };
                cmd.stdout(writer).stderr(w2);
                Some(reader)
            }
            Err(e) => return Output::never(format!("pipe: {}", words(&e))),
        },
        ErrorOutput::Capture => {
            cmd.stdout(Stdio::piped()).stderr(Stdio::piped());
            None
        }
        ErrorOutput::Inherit => {
            cmd.stdout(Stdio::piped()).stderr(Stdio::inherit());
            None
        }
    };
    let mut child = match cmd.spawn() {
        Ok(c) => c,
        Err(e) => return Output::never(format!("{exe}: {}", words(&e))),
    };
    // The command (and with it the parent's copies of a merged pipe's write
    // ends) must go, or the reader never sees EOF.
    drop(cmd);
    let limit = o.limit;
    let writer = child.stdin.take().zip(o.input).map(|(mut w, input)| {
        thread::spawn(move || {
            let _ = w.write_all(&input);
        })
    });
    let out = match merged {
        Some(r) => thread::spawn(move || read_kept(r, limit)),
        None => {
            let r = child.stdout.take().unwrap();
            thread::spawn(move || read_kept(r, limit))
        }
    };
    let err = child.stderr.take().map(|r| thread::spawn(move || read_kept(r, limit)));
    let stdout = out.join().unwrap_or_default();
    let stderr = err.map(|t| t.join().unwrap_or_default()).unwrap_or_default();
    if let Some(w) = writer {
        let _ = w.join();
    }
    match child.wait() {
        Ok(status) => Output { raw_status: Some(status.into_raw()), stdout, stderr, failure: None },
        Err(e) => Output { raw_status: None, stdout, stderr, failure: Some(format!("wait: {}", words(&e))) },
    }
}

#[cfg(test)]
mod tests;
