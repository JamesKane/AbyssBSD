//! abyssnotify: post a desktop notification, the brokerless `notify-send`,
//! ported from main.swift beside it.
//!
//!     abyssnotify "Build finished"                      # summary only
//!     abyssnotify "Build finished" "all tests green"     # summary + body
//!     abyssnotify -t 8 "Slow job" "took a while"         # 8-second timeout
//!
//! It asks the **portal**, which relays to the shell's notification centre:
//! the same path a jailed app takes. A sandboxed process never holds the
//! notify service's socket, so it can post a toast without being able to
//! reach the shell or impersonate it. `--direct` talks to the notify service
//! instead, which is what the desktop's own components do.

use current_ipc::{Error, Msg};
use std::process::exit;

const USAGE: &str = "usage: abyssnotify [-t SECONDS] [--direct] <summary> [body]";

fn fail(why: impl std::fmt::Display) -> ! {
    eprintln!("abyssnotify: {why}");
    exit(1)
}

fn main() {
    let (mut timeout, mut direct, mut positional) = (None, false, vec![]);
    let mut args = std::env::args().skip(1);
    while let Some(a) = args.next() {
        match a.as_str() {
            "-t" | "--timeout" => match args.next().and_then(|n| n.parse::<u64>().ok()).filter(|n| *n > 0) {
                Some(n) => timeout = Some(n),
                None => fail("-t wants a number of seconds"),
            },
            "--direct" => direct = true,
            "-h" | "--help" => {
                println!("{USAGE}");
                exit(0)
            }
            _ => positional.push(a),
        }
    }
    let Some(summary) = positional.first().filter(|s| !s.is_empty()) else {
        eprintln!("{USAGE}");
        exit(2)
    };
    let mut request = Msg::new();
    request.set_string("method", "notify");
    request.set_string("summary", summary);
    if let Some(body) = positional.get(1) {
        request.set_string("body", body);
    }
    if let Some(t) = timeout {
        request.set_u64("timeout", t);
    }
    let service = if direct {
        std::env::var("ABYSS_NOTIFY_SERVICE").unwrap_or_else(|_| "notify".into())
    } else {
        std::env::var("ABYSS_PORTAL_SERVICE").unwrap_or_else(|_| "portal".into())
    };
    match current_ipc::call(&service, &request) {
        Ok(r) if r.bool("ok") == Some(true) => match r.u64("id") {
            Some(id) => println!("posted #{id}"),
            None => println!("posted"),
        },
        Ok(r) => fail(r.string("error").unwrap_or("the desktop declined the notification")),
        Err(Error::System(e, _)) if e == libc::ENOENT || e == libc::ECONNREFUSED => fail(format!("no '{service}' service — is the desktop running?")),
        Err(e) => fail(e),
    }
}

