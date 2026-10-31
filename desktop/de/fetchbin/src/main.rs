//! abyss-fetch: an agent session's fetch bridge (PHASE18 P18.12b), ported
//! from main.swift beside it.
//!
//!   abyss-fetch serve --listen INSIDE --control OUTSIDE --session ID --transcript DIR
//!       answers the agent at INSIDE (a socket in its jail): `fetch url=URL`,
//!       for hosts the person allowed this session and no others; a new host
//!       is answered `permission host=…`. The person's answer comes from the
//!       keeper at OUTSIDE (0600, beside the transcript): `permit host=H
//!       allow=BOOL`. Every request, permission and refusal is a line of
//!       DIR/transcript.jsonl. $ABYSS_FETCH_ALLOW_LOCAL (tests only) lets it
//!       reach this computer's own addresses, which it otherwise refuses.

use abyss_sys::proc;
use current_ipc::{Msg, Server};
use fetch::{Answer, FetchBridge};
use model::session::{now, transcript_line};
use model::{open_transcript, Json};
use std::io::Write;
use std::process::exit;

fn die(why: impl std::fmt::Display) -> ! {
    eprintln!("abyss-fetch: {why}");
    exit(1)
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let opt = |name: &str| args.iter().position(|a| a == name).and_then(|i| args.get(i + 1)).cloned();
    let (Some("serve"), Some(inside), Some(outside), Some(session), Some(dir)) = (args.first().map(String::as_str), opt("--listen"), opt("--control"), opt("--session"), opt("--transcript")) else {
        eprintln!("usage: abyss-fetch serve --listen INSIDE --control OUTSIDE --session ID --transcript DIR");
        exit(2)
    };
    let mut file = open_transcript(&dir).unwrap_or_else(|e| die(e));
    let sid = session.clone();
    let log = Box::new(move |event: &str, fields: Vec<(String, Json)>| {
        let head = vec![("kind".to_owned(), Json::String("fetch".into())), ("event".to_owned(), Json::String(event.into()))];
        let _ = file.write_all(transcript_line(now(), &sid, head, fields).as_bytes());
    });
    let allow_local = std::env::var_os("ABYSS_FETCH_ALLOW_LOCAL").is_some();
    let mut bridge = FetchBridge::new(allow_local, fetch::resolve, fetch::web_get(), log);
    let agent_side = Server::bind(&inside, 0o600).unwrap_or_else(|e| die(format!("cannot listen: {e}")));
    let keeper_side = Server::bind(&outside, 0o600).unwrap_or_else(|e| die(format!("cannot listen: {e}")));
    println!("ready (session {session}{})", if allow_local { ", local addresses allowed: a test" } else { "" });
    loop {
        let mut fds = [proc::poll_fd(agent_side.fd(), proc::POLLIN), proc::poll_fd(keeper_side.fd(), proc::POLLIN)];
        match proc::poll(&mut fds, -1) {
            Err(e) if e.kind() == std::io::ErrorKind::Interrupted => continue,
            Err(e) => die(format!("poll: {e}")),
            Ok(_) => {}
        }
        for (i, server) in [&agent_side, &keeper_side].into_iter().enumerate() {
            if fds[i].revents == 0 {
                continue;
            }
            let Ok(c) = server.accept() else { continue };
            let Ok(req) = current_ipc::receive(&c) else { continue };
            let mut r = Msg::new();
            if i == 1 {
                // The keeper's side: the person's answers, and nothing else.
                match (req.string("method"), req.string("host")) {
                    (Some("permit"), Some(h)) => {
                        let allow = req.bool("allow") == Some(true);
                        bridge.permit(h, allow);
                        r.set_bool("ok", true);
                        println!("{} {h}", if allow { "permitted" } else { "denied" });
                    }
                    _ => {
                        r.set_bool("ok", false);
                        r.set_string("error", "the control socket answers permit");
                    }
                }
            } else if req.string("method") == Some("fetch") {
                let url = req.string("url").unwrap_or("");
                let said = match bridge.fetch(url) {
                    Answer::Page { url, status, text } => {
                        r.set_bool("ok", true);
                        r.set_string("url", &url);
                        r.set_u64("status", u64::from(status));
                        r.set_string("text", &text);
                        "ok"
                    }
                    Answer::Ask { host, url } => {
                        r.set_bool("ok", false);
                        r.set_bool("permission", true);
                        r.set_string("host", &host);
                        r.set_string("url", &url);
                        r.set_string("error", &format!("the person has not allowed {host} yet; they are being asked"));
                        "ask"
                    }
                    Answer::Refused(why) => {
                        r.set_bool("ok", false);
                        r.set_string("error", &why);
                        "refused"
                    }
                };
                println!("fetch {url} → {said}");
            } else {
                r.set_bool("ok", false);
                r.set_string("error", "the fetch bridge answers fetch");
            }
            let _ = current_ipc::send(&r, &c);
        }
    }
}
