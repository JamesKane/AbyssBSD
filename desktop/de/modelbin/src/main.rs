//! abyss-model: the only way to a model (PHASE18 P18.7), ported from
//! main.swift beside it.
//!
//!   abyss-model serve --listen PATH --session ID --budget TOKENS --transcript DIR
//!                     (--stub FILE | --backend http://HOST:PORT[/path] |
//!                      --local MODEL.gguf [--llama-server PATH] [--context N])
//!                     [--control PATH]
//!       OpenAI-compatible chat completions over the unix socket at PATH, for
//!       one agent session: its budget, its append-only transcript in DIR,
//!       and its backend: canned replies from FILE (a JSON array), a server
//!       speaking the same wire, or llama-server, run here on a private unix
//!       socket (P18.7b) and stopped when this goes. --control (P18.11): a
//!       second socket, outside the jail, on which the keeper raises the
//!       budget when the person allows more (`raise tokens=N`).
//!   abyss-model fetch URL [--ca FILE] [--address IP]
//!       GET an http(s) URL as the fetch bridge does (P18.12a), and print
//!       the status and body: TLS verified against the system's CAs, or FILE's.
//!   abyss-model tier
//!       this machine's VRAM and RAM, its tier, and the model proposed for
//!       it (PHASE18 §6b.1).

use abyss_sys::proc;
use current_ipc::{Msg, Server};
use model::http::{self, Call, Endpoint, WebUrl};
use model::local::{LocalBackend, LocalServer};
use model::{open_transcript, Backend, HttpBackend, Json, ModelSession, StubBackend, Tier};
use std::process::exit;
use std::time::Duration;

fn die(why: impl std::fmt::Display) -> ! {
    eprintln!("abyss-model: {why}");
    exit(1)
}

fn tier() {
    let boot = std::fs::read("/var/run/dmesg.boot").map(|b| String::from_utf8_lossy(&b).into_owned()).unwrap_or_default();
    let physmem = spawn::run(&["sysctl", "-n", "hw.physmem"]);
    let ram = if physmem.succeeded() {
        physmem.stdout_text().lines().next().and_then(|l| l.trim().parse::<i64>().ok()).map_or(0, |b| b >> 20)
    } else {
        let meminfo = std::fs::read_to_string("/proc/meminfo").unwrap_or_default();
        meminfo.lines().find_map(|l| l.strip_prefix("MemTotal:")).and_then(|r| r.split_whitespace().next()?.parse::<i64>().ok()).map_or(0, |kb| kb >> 10)
    };
    let vram = model::session::vram_from_boot_messages(&boot);
    let t = Tier::choose(vram);
    let (m, q, c) = t.proposed();
    println!("vram={} ram={ram}M tier={} proposed={m} {q} context={c}", vram.map_or("none".into(), |v| format!("{v}M")), t.name());
}

fn fetch(args: &[String], opt: &dyn Fn(&str) -> Option<String>) {
    let Some(url) = args.get(1).and_then(|u| WebUrl::parse(u)) else { die("fetch needs an http:// or https:// URL") };
    let mut to = url.endpoint();
    if let (Endpoint::Tls { cafile, .. }, Some(ca)) = (&mut to, opt("--ca")) {
        *cafile = Some(ca);
    }
    // --address IP: connect there, the name kept for TLS and Host: what the
    // fetch bridge does with the address it checked (P18.12b).
    let address = opt("--address");
    let headers = [("User-Agent", "AbyssBSD")];
    let c = Call { headers: &headers, version: "1.0", timeout: Duration::from_secs(20), address: address.as_deref(), ..Call::new("GET", &url.path) };
    match http::call(&to, &c) {
        Ok(r) => {
            println!("status {}", r.status);
            println!("{}", String::from_utf8_lossy(&r.body[..r.body.len().min(4096)]));
        }
        Err(e) => die(format!("{}: {e}", url.text())),
    }
}

fn serve<B: Backend>(mut s: ModelSession<B>, listen: &str, control: Option<String>) -> ! {
    let server = Server::bind(listen, 0o600).unwrap_or_else(|e| die(format!("cannot listen at {listen}: {e}")));
    let control = control.map(|c| Server::bind(&c, 0o600).unwrap_or_else(|e| die(format!("cannot listen at {c}: {e}"))));
    println!("ready (session {}, budget {} tokens, backend {})", s.id, s.budget(), s.backend.name());
    loop {
        let mut fds = [proc::poll_fd(server.fd(), proc::POLLIN), proc::poll_fd(control.as_ref().map_or(-1, |c| c.fd()), proc::POLLIN)];
        match proc::poll(&mut fds, -1) {
            Err(e) if e.kind() == std::io::ErrorKind::Interrupted => continue,
            Err(e) => die(format!("poll: {e}")),
            Ok(_) => {}
        }
        // The keeper's side: the person allowed more.
        if fds[1].revents != 0
            && let Some(c) = control.as_ref().and_then(|c| c.accept().ok())
            && let Ok(req) = current_ipc::receive(&c)
        {
            let mut r = Msg::new();
            match req.u64("tokens").filter(|n| *n > 0 && req.string("method") == Some("raise")) {
                Some(n) => {
                    s.raise(n.min(i64::MAX as u64) as i64);
                    r.set_bool("ok", true);
                    r.set_u64("budget", s.budget().max(0) as u64);
                    r.set_u64("used", s.used().max(0) as u64);
                    println!("raised by {n} to {}", s.budget());
                }
                None => {
                    r.set_bool("ok", false);
                    r.set_string("error", "the control socket answers raise tokens=N");
                }
            }
            let _ = current_ipc::send(&r, &c);
        }
        if fds[0].revents == 0 {
            continue;
        }
        let Ok(mut c) = server.accept() else { continue };
        // A slow reply is the model's, not the client's: a timeout on
        // reading the request (the server's), none on the answer.
        if let Ok(Some(req)) = http::read_request(&mut c) {
            let r = s.handle(&req);
            let _ = http::send(&r, &mut c);
            if r.status == 429 {
                println!("refused: budget ({} of {})", s.used(), s.budget());
            }
        }
    }
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let opt = |name: &str| args.iter().position(|a| a == name).and_then(|i| args.get(i + 1)).cloned();
    match args.first().map(String::as_str) {
        Some("tier") => tier(),
        Some("fetch") => fetch(&args, &opt),
        Some("serve") => {
            let (Some(listen), Some(session), Some(dir), Some(budget)) =
                (opt("--listen"), opt("--session"), opt("--transcript"), opt("--budget").and_then(|b| b.parse::<i64>().ok()).filter(|b| *b > 0))
            else {
                die("serve needs --listen PATH --session ID --budget TOKENS --transcript DIR")
            };
            // The session's directory first: the transcript, and
            // llama-server's private socket directory inside it.
            let file = open_transcript(&dir).unwrap_or_else(|e| die(e));
            let control = opt("--control");
            if let Some(c) = &control {
                let _ = std::fs::remove_file(c);
            }
            let _ = std::fs::remove_file(&listen);
            if let Some(stub) = opt("--stub") {
                let replies = std::fs::read(&stub).ok().and_then(|b| Json::parse(&b).ok()).and_then(|j| j.as_array().map(<[Json]>::to_vec));
                let Some(replies) = replies else { die(format!("--stub {stub} is not a JSON array of chat completions")) };
                let mut b = StubBackend::new(replies);
                // A test's slow model: $ABYSS_MODEL_STUB_DELAY milliseconds a reply.
                b.delay_ms = std::env::var("ABYSS_MODEL_STUB_DELAY").ok().and_then(|d| d.parse().ok()).unwrap_or(0);
                serve(ModelSession::new(&session, budget, b, file), &listen, control)
            } else if let Some(url) = opt("--backend") {
                let Some(b) = HttpBackend::url(&url) else { die("--backend must be http://HOST:PORT[/path]") };
                serve(ModelSession::new(&session, budget, b, file), &listen, control)
            } else if let Some(m) = opt("--local") {
                let server = opt("--llama-server").or_else(|| spawn::resolve_executable("llama-server", None)).unwrap_or_else(|| "/usr/local/bin/llama-server".into());
                let context = opt("--context").and_then(|c| c.parse().ok()).unwrap_or(16384);
                println!("starting llama-server with {m}");
                let local = LocalServer::start(&server, &m, &format!("{dir}/llama"), context, Duration::from_secs(600)).unwrap_or_else(|e| die(e));
                // Stop it on the way out, even mid-completion. On FreeBSD
                // the kernel would anyway (a process descriptor without
                // PD_DAEMON), but with SIGKILL; on Linux this is what does.
                proc::stop_child_on_signals(local.pid());
                serve(ModelSession::new(&session, budget, LocalBackend::new(local, &m), file), &listen, control)
            } else {
                die("serve needs --stub FILE, --backend URL or --local MODEL")
            }
        }
        _ => {
            eprintln!("usage: abyss-model serve --listen PATH --session ID --budget N --transcript DIR (--stub FILE | --backend URL) | tier");
            exit(2)
        }
    }
}
