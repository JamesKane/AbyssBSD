//! abyss-jail: ask abyss-jaild for a jail, by hand (PHASE18 P18.2), and the
//! session's keeper; ported from main.swift beside it.
//!
//!   abyss-jail run CLASS -- PROGRAM [ARG...]
//!       open the class's jail, run PROGRAM in it with this terminal, wait
//!       for it, and let go of the jail (if this was its only holder, it
//!       goes). Exits with PROGRAM's status (128 + N if a signal N killed
//!       it), so a test can ask a jail a yes-or-no question.
//!   abyss-jail hold CLASS [-- PROGRAM [ARG...]]
//!       open it, print "held NAME jid=N root=… runtime=…", start PROGRAM in
//!       it detached if given, and keep the jail until stdin reaches EOF.
//!   abyss-jail grants NAME          the files granted into a jail (P18.4)
//!   abyss-jail revoke NAME N        take grant N back
//!   abyss-jail grant NAME PATH [--fd-of FILE] [--write]
//!       grant PATH, proven by a descriptor of PATH (or, as a test's forgery,
//!       of FILE), opened read-only (or read-write with --write).
//!   abyss-jail spawn-by-name NAME -- PROGRAM [ARG...]
//!       a test's probe: ask to run in a jail named by NAME rather than held;
//!       jaild must refuse it unless the jail is the caller's own.
//!
//!   abyss-jail serve
//!       the session's half (P18.5): holds a jail per class, with its
//!       Wayland socket, bus and portal, and launches into it, on the
//!       session's `jails` socket.
//!   abyss-jail launch CLASS -- PROGRAM [ARG...]
//!       ask the session to start PROGRAM confined; an ARG that names one of
//!       your files is granted into the jail and rewritten.
//!   abyss-jail agent CLASS | debug N
//!       an agent session (P18.8), or a `debug` one for crash N (P18.9):
//!       prints "agent SESSION socket=… transcript=… pid=…".
//!   abyss-jail give SESSION APP | take SESSION APP | raise SESSION TOKENS
//!   abyss-jail permit SESSION APP yes|no | permit-host SESSION HOST yes|no
//!       what the Agent window sends (P18.10–P18.12b).
//!   abyss-jail crashes
//!       the confined programs that died of a signal this session (P18.9).
//!
//! [--socket PATH] before the command talks to another jaild (a test's).

use abyss_sys::wl::Display;
use current_ipc::{Msg, Server};
use jaild::client::{self, Start};
use jaild::wire;
use jailkeeper::JailKeeper;
use jails::JailClass;
use std::fs::{File, OpenOptions};
use std::io::Read;
use std::os::fd::AsFd;
use std::process::exit;

fn die(why: impl std::fmt::Display) -> ! {
    eprintln!("abyss-jail: {why}");
    exit(1)
}

/// One request to the session's keeper; its yes, or out with its words.
fn ask(m: Msg) -> Msg {
    match current_ipc::call(jailkeeper::SERVICE, &m) {
        Ok(r) if r.bool("ok") == Some(true) => r,
        Ok(r) => die(r.string("error").unwrap_or("refused")),
        Err(e) => die(format!("the session's jails are not running ({e})")),
    }
}

fn request(method: &str) -> Msg {
    let mut m = Msg::new();
    m.set_string("method", method);
    m
}

fn agent_line(r: &Msg) {
    let s = |k: &str| r.string(k).unwrap_or("").to_owned();
    println!("agent {} socket={} transcript={} pid={}", s("session"), s("socket"), s("transcript"), r.u64("pid").unwrap_or(0));
}

fn serve(socket: String) -> ! {
    let runtime = current_ipc::runtime_dir().unwrap_or_else(|e| die(format!("no runtime directory: {e}")));
    let me = abyss_sys::proc::self_executable().unwrap_or_default();
    let bin_dir = me.rsplit_once('/').map_or("/usr/local/bin".to_owned(), |(d, _)| d.to_owned());
    let display = Display::connect();
    if display.is_none() {
        eprintln!("abyss-jail: no compositor to register jails with — launched programs get no display");
    }
    let has_display = display.is_some();
    let server = Server::new(jailkeeper::SERVICE).unwrap_or_else(|e| die(format!("cannot serve {}: {e}", jailkeeper::SERVICE)));
    // The person's jails.ini: an agent class's model and budget are theirs
    // to set (P18.8). What a jail can reach is jaild's, from the system's.
    let mut keeper = JailKeeper::new(server, display, &runtime, &bin_dir, JailClass::load(None), |s| println!("{s}"));
    keeper.jaild_socket = socket;
    // A crash is shown to the person (P18.9b), when there is a display.
    let demo = format!("{bin_dir}/AquaDemo");
    if has_display && abyss_sys::spawn::executable(&demo) {
        keeper.crash_dialog = Some(vec![demo]);
    }
    // The bundles follow [apps] (P18.6): the same appgen anchor runs at login.
    let appgen = format!("{bin_dir}/abyss-appgen");
    if abyss_sys::spawn::executable(&appgen)
        && let Ok(home) = std::env::var("HOME")
    {
        keeper.appgen = Some(vec![appgen, "--to".into(), format!("{home}/Applications")]);
    }
    println!("jails: ready");
    keeper.run();
    exit(0)
}

fn main() {
    let mut args: Vec<String> = std::env::args().skip(1).collect();
    let mut socket = wire::DEFAULT_SOCKET.to_owned();
    if args.len() > 1 && args[0] == "--socket" {
        socket = args[1].clone();
        args.drain(..2);
    }
    match args.first().map(String::as_str) {
        Some("serve") => serve(socket),
        Some("crashes") => {
            let r = ask(request("crashes"));
            for c in wire::unlist(r.bytes("crashes").unwrap_or(&[])) {
                println!("{c}");
            }
            exit(0)
        }
        _ => {}
    }
    if args.len() < 2 {
        eprintln!("usage: abyss-jail [--socket PATH] run|hold CLASS [-- PROGRAM ARG...] | spawn-by-name NAME -- PROGRAM ARG...");
        exit(2)
    }
    let (command, subject) = (args[0].as_str(), args[1].as_str());
    let program: Vec<String> = args.iter().position(|a| a == "--").map(|i| args[i + 1..].to_vec()).unwrap_or_default();
    let third = || args.get(2).cloned();

    match command {
        "run" => {
            if program.is_empty() {
                die("run needs a program after --")
            }
            let j = client::open(subject, &socket).unwrap_or_else(|e| die(e));
            let start = Start { argv: &program, stdin: Some(0), stdout: Some(1), stderr: Some(2), ..Start::default() };
            let (_, proc) = client::spawn(j.jail.as_fd(), &start, &socket).unwrap_or_else(|e| die(e));
            let status = abyss_sys::jail::wait(proc.as_fd());
            drop(proc);
            drop(j);
            let Ok(s) = status else { die(format!("lost track of {}", program[0])) };
            exit(if s & 0x7f == 0 { (s >> 8) & 0xff } else { 128 + (s & 0x7f) })
        }
        "hold" => {
            let j = client::open(subject, &socket).unwrap_or_else(|e| die(e));
            println!("held {} jid={} root={} runtime={} shared={}", j.name, j.jid, j.root, j.runtime, j.shared);
            if !program.is_empty() {
                let start = Start { argv: &program, stdout: Some(2), stderr: Some(2), daemon: true, ..Start::default() };
                let (pid, _proc) = client::spawn(j.jail.as_fd(), &start, &socket).unwrap_or_else(|e| die(e));
                println!("started {} pid={pid}", program[0]);
            }
            let mut sink = Vec::new();
            let _ = std::io::stdin().read_to_end(&mut sink);
            drop(j.jail);
            println!("released {}", j.name);
        }
        "launch" => {
            if program.is_empty() {
                die("launch needs a program after --")
            }
            let mut m = request("launch");
            m.set_string("class", subject);
            m.set_bytes("argv", &wire::list(&program));
            let r = ask(m);
            println!("launched {} pid={} confined in {subject}", program[0], r.u64("pid").unwrap_or(0));
        }
        "agent" => {
            let mut m = request("agent");
            m.set_string("class", subject);
            agent_line(&ask(m));
        }
        "debug" => {
            let mut m = request("debug");
            m.set_u64("crash", subject.parse().unwrap_or(0));
            agent_line(&ask(m));
        }
        "give" => {
            let Some(app) = third() else { die("give needs a session and an application") };
            let mut m = request("give");
            m.set_string("session", subject);
            m.set_string("app", &app);
            let r = ask(m);
            println!("gave {} to {subject}", r.string("app").unwrap_or(&app));
        }
        "raise" | "take" | "permit" | "permit-host" => {
            let Some(value) = third() else {
                die(format!("{command} needs a session and {}", if command == "raise" { "tokens" } else { "an application" }))
            };
            let mut m = request(command);
            m.set_string("session", subject);
            match command {
                "raise" => m.set_u64("tokens", value.parse().unwrap_or(0)),
                "permit-host" => m.set_string("host", &value),
                _ => m.set_string("app", &value),
            }
            let yes = args.get(3).is_some_and(|a| a == "yes");
            if command.starts_with("permit") {
                m.set_bool("allow", yes);
            }
            let r = ask(m);
            match command {
                "raise" => println!("budget {}", r.u64("budget").unwrap_or(0)),
                "take" => println!("took {value} back"),
                _ => println!("{} {value}", if yes { "allowed" } else { "did not allow" }),
            }
        }
        "grants" => {
            for g in client::grants(subject, &socket).unwrap_or_else(|e| die(e)) {
                println!("{g}");
            }
        }
        "revoke" => {
            let Some(n) = third().and_then(|n| n.parse().ok()) else { die("revoke needs a jail and a grant number") };
            client::revoke(subject, n, &socket).unwrap_or_else(|e| die(e));
            println!("revoked {n}");
        }
        "grant" => {
            let Some(path) = third() else { die("grant needs a jail and a path") };
            let proof = args.iter().position(|a| a == "--fd-of").and_then(|i| args.get(i + 1)).cloned().unwrap_or_else(|| path.clone());
            let write = args.iter().any(|a| a == "--write");
            let f = if write { OpenOptions::new().read(true).write(true).open(&proof) } else { File::open(&proof) };
            let f = f.unwrap_or_else(|e| die(format!("cannot open {proof}: {e}")));
            let (inside, n) = client::grant(subject, &path, f.as_fd(), &socket).unwrap_or_else(|e| die(e));
            println!("granted {n} at {inside}");
        }
        "spawn-by-name" => {
            let desc = abyss_sys::jail::desc_by_name(subject).unwrap_or_else(|_| die(format!("no jail named {subject} that this user may see")));
            let argv = if program.is_empty() { vec!["true".to_owned()] } else { program };
            let (pid, proc) = client::spawn(desc.as_fd(), &Start { argv: &argv, ..Start::default() }, &socket).unwrap_or_else(|e| die(e));
            println!("spawned pid={pid}");
            let mut p = [abyss_sys::proc::poll_fd(std::os::fd::AsRawFd::as_raw_fd(&proc), abyss_sys::proc::POLLHUP)];
            while abyss_sys::proc::poll(&mut p, -1).is_err_and(|e| e.kind() == std::io::ErrorKind::Interrupted) {}
        }
        other => die(format!("unknown command '{other}'")),
    }
}
