//! llama.cpp's `llama-server`, run by `abyss-model` (Local.swift, PHASE18
//! P18.7b).
//!
//! The local backend is not ours to write ("we do not write an inference
//! engine"); running it is. `abyss-model` starts `llama-server` as its own
//! supervised child, outside any jail:
//!
//!   - it listens on **a unix socket** in a 0700 directory of abyss-model's,
//!     never on a TCP port, so nothing else on the machine can reach the
//!     model except through abyss-model, its budget and its transcript;
//!   - abyss-model is ready only once the server answers /health with 200
//!     (loading a model takes seconds to minutes), and gives up, with the
//!     server's own last words, if it exits first;
//!   - the child dies with abyss-model: on FreeBSD it is a process
//!     descriptor without PD_DAEMON, so the kernel kills it however
//!     abyss-model goes.

use crate::http::{self, Call, Endpoint, Failure};
use crate::json::Json;
use crate::session::{Backend, HttpBackend};
use abyss_sys::proc::{self, Child};
use std::fs::OpenOptions;
use std::os::fd::AsFd;
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::time::{Duration, Instant};

pub struct LocalServer {
    pub socket: String,
    pub log: String,
    child: Child,
    exited: Option<i32>,
}

/// The argv for `llama-server`: the model, the socket, tool calling
/// (`--jinja`, the model's own chat template), no web UI, every layer on the
/// GPU that will take it (`-ngl 999`; with no GPU, none are), and **one
/// slot** (`-np 1`): a session is one client asking one thing at a time,
/// and the default four slots cost VRAM the desktop needs.
pub fn argv(server: &str, model: &str, socket: &str, context: u32, extra: &[String]) -> Vec<String> {
    let mut a: Vec<String> = [server, "-m", model, "--host", socket, "--jinja", "--no-webui", "-ngl", "999", "-c", &context.to_string(), "-np", "1", "--offline"]
        .iter()
        .map(|s| (*s).to_owned())
        .collect();
    a.extend(extra.iter().cloned());
    a
}

impl LocalServer {
    /// Start it and wait until it is healthy, or say why not.
    pub fn start(server: &str, model: &str, dir: &str, context: u32, wait: Duration) -> Result<LocalServer, Failure> {
        if std::fs::File::open(model).is_err() {
            return Err(Failure(format!("cannot read the model {model}")));
        }
        if !server.starts_with('/') || !abyss_sys::spawn::executable(server) {
            return Err(Failure(format!("cannot run {server}")));
        }
        match std::fs::create_dir(dir) {
            Err(e) if e.kind() != std::io::ErrorKind::AlreadyExists => return Err(Failure(format!("mkdir {dir}: {e}"))),
            _ => {}
        }
        let _ = std::fs::set_permissions(dir, std::fs::Permissions::from_mode(0o700));
        let (socket, log) = (format!("{dir}/llama.sock"), format!("{dir}/llama-server.log"));
        let _ = std::fs::remove_file(&socket);
        let out = OpenOptions::new().write(true).create(true).truncate(true).mode(0o600).open(&log).map_err(|e| Failure(format!("open {log}: {e}")))?;
        let env: Vec<String> = std::env::vars().map(|(k, v)| format!("{k}={v}")).collect();
        let child = Child::spawn(&argv(server, model, &socket, context, &[]), &env, Some(out.as_fd())).map_err(|e| Failure(format!("cannot start {server}: {e}")))?;
        let mut l = LocalServer { socket, log, child, exited: None };
        let deadline = Instant::now() + wait;
        loop {
            if let Some(why) = l.check_exited() {
                return Err(Failure(format!("llama-server {why} before it was ready: {}", l.tail(3))));
            }
            let health = Call { timeout: Duration::from_secs(5), ..Call::new("GET", "/health") };
            if http::call(&Endpoint::Unix(l.socket.clone()), &health).is_ok_and(|r| r.status == 200) {
                return Ok(l);
            }
            if Instant::now() > deadline {
                l.stop();
                return Err(Failure(format!("llama-server was not ready in {}s: {}", wait.as_secs(), l.tail(3))));
            }
            std::thread::sleep(Duration::from_millis(200));
        }
    }

    pub fn pid(&self) -> i32 {
        self.child.pid()
    }

    /// None while it runs; once it has exited, how.
    pub fn check_exited(&mut self) -> Option<String> {
        if self.exited.is_none() {
            let mut p = [proc::poll_fd(self.child.fd(), proc::child_exit_events())];
            if proc::poll(&mut p, 0).unwrap_or(0) == 0 {
                return None;
            }
            self.exited = Some(self.child.reap().unwrap_or(0));
        }
        let s = self.exited.unwrap_or(0);
        Some(if s & 0x7f != 0 { format!("was killed by signal {}", s & 0x7f) } else { format!("exited {}", (s >> 8) & 0xff) })
    }

    /// The server's last lines, for a failure that should say what it said.
    pub fn tail(&self, n: usize) -> String {
        let text = std::fs::read(&self.log).map(|b| String::from_utf8_lossy(&b[b.len().saturating_sub(1 << 19)..]).into_owned()).unwrap_or_default();
        let lines: Vec<&str> = text.split('\n').filter(|l| !l.is_empty()).collect();
        lines[lines.len().saturating_sub(n)..].join(" / ")
    }

    pub fn stop(&mut self) {
        if self.exited.is_some() {
            return;
        }
        let _ = self.child.signal(libc::SIGTERM);
        for _ in 0..50 {
            if self.check_exited().is_some() {
                break;
            }
            std::thread::sleep(Duration::from_millis(100));
        }
        if self.exited.is_none() {
            let _ = self.child.signal(libc::SIGKILL);
            self.exited = Some(self.child.reap().unwrap_or(0));
        }
        let _ = std::fs::remove_file(&self.socket);
    }
}

/// `llama-server` behind abyss-model: a backend that says so when the
/// server has gone, rather than failing to connect.
pub struct LocalBackend {
    pub server: LocalServer,
    http: HttpBackend,
}

impl LocalBackend {
    pub fn new(server: LocalServer, model: &str) -> LocalBackend {
        let name = format!("local:{}", model.rsplit('/').next().unwrap_or(model));
        let http = HttpBackend::unix(&server.socket, &name);
        LocalBackend { server, http }
    }
}

impl Backend for LocalBackend {
    fn name(&self) -> String {
        self.http.name.clone()
    }

    fn complete(&mut self, request: &Json) -> Result<Json, Failure> {
        if let Some(why) = self.server.check_exited() {
            return Err(Failure(format!("llama-server {why}: {}", self.server.tail(3))));
        }
        self.http.complete(request)
    }
}
