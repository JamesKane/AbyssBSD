//! abyss-vocab: an agent session's vocabulary bridge (PHASE18 P18.10),
//! ported from main.swift beside it.
//!
//!   abyss-vocab serve --listen INSIDE --control OUTSIDE --session ID --transcript DIR
//!       answers the agent at INSIDE (a socket in its jail): apps, describe,
//!       activate, for the applications given to this session and no others.
//!       Gives come from the keeper at OUTSIDE (a socket outside the jail,
//!       0600): `give service=menus.APP.PID`, `take app=NAME`, and `permit
//!       app=NAME allow=BOOL` (the person's answer to requester 1; P18.11).
//!       Every give, activation and refusal is a line of
//!       DIR/transcript.jsonl. The keeper starts it beside abyss-model and
//!       stops it with the agent.

use abyss_sys::proc;
use current_ipc::{Msg, Server};
use model::session::{now, transcript_line};
use model::{open_transcript, Json};
use std::io::Write;
use std::process::exit;
use vocabulary::{LiveMenus, VocabularyBridge};

fn die(why: impl std::fmt::Display) -> ! {
    eprintln!("abyss-vocab: {why}");
    exit(1)
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let opt = |name: &str| args.iter().position(|a| a == name).and_then(|i| args.get(i + 1)).cloned();
    let (Some("serve"), Some(inside), Some(outside), Some(session), Some(dir)) = (args.first().map(String::as_str), opt("--listen"), opt("--control"), opt("--session"), opt("--transcript")) else {
        eprintln!("usage: abyss-vocab serve --listen INSIDE --control OUTSIDE --session ID --transcript DIR");
        exit(2)
    };
    let mut file = open_transcript(&dir).unwrap_or_else(|e| die(e));
    let sid = session.clone();
    let log = Box::new(move |event: &str, fields: Vec<(String, Json)>| {
        let head = vec![("kind".to_owned(), Json::String("vocabulary".into())), ("event".to_owned(), Json::String(event.into()))];
        let _ = file.write_all(transcript_line(now(), &sid, head, fields).as_bytes());
    });
    let mut bridge = VocabularyBridge::new(LiveMenus, log);
    let agent_side = Server::bind(&inside, 0o600).unwrap_or_else(|e| die(format!("cannot listen: {e}")));
    let keeper_side = Server::bind(&outside, 0o600).unwrap_or_else(|e| die(format!("cannot listen: {e}")));
    println!("ready (session {session})");
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
            let reply = if i == 1 {
                // The keeper's side: gives, takes and the person's answers.
                let mut r = Msg::new();
                let refuse = |r: &mut Msg, why: &str| {
                    r.set_bool("ok", false);
                    r.set_string("error", why);
                };
                match req.string("method").unwrap_or("") {
                    "give" if req.string("service").is_some() => {
                        let s = req.string("service").unwrap_or("");
                        match bridge.give(s) {
                            Ok(name) => {
                                r.set_bool("ok", true);
                                r.set_string("app", &name);
                                println!("given {name} ({s})");
                            }
                            Err(e) => refuse(&mut r, &format!("{s} did not answer: {e}")),
                        }
                    }
                    // Requester 1 (P18.11): the person's answer, from outside.
                    "permit" if req.string("app").is_some() => {
                        let (app, allow) = (req.string("app").unwrap_or(""), req.bool("allow") == Some(true));
                        bridge.permit(app, allow);
                        r.set_bool("ok", true);
                        println!("{} {app}", if allow { "permitted" } else { "denied" });
                    }
                    // Taken back (P18.11): refused from now on, as never given.
                    "take" if req.string("app").is_some() => {
                        let app = req.string("app").unwrap_or("");
                        if bridge.take(app) {
                            r.set_bool("ok", true);
                            println!("taken {app}");
                        } else {
                            refuse(&mut r, &format!("{app} was not given to this session"));
                        }
                    }
                    _ => refuse(&mut r, "the control socket answers give and take"),
                }
                r
            } else {
                let r = bridge.handle(&req);
                let verb = req.string("verb").map_or(String::new(), |v| format!(" {v}"));
                println!("{} {}{verb} → {}", req.string("method").unwrap_or("?"), req.string("app").unwrap_or(""), if r.bool("ok") == Some(true) { "ok" } else { "refused" });
                r
            };
            let _ = current_ipc::send(&reply, &c);
        }
    }
}
