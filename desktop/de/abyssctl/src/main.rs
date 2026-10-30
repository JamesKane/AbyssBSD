//! abyssctl: drive a running session over the control plane (Rust; the
//! Swift is main.swift beside it). Brokerless: no bus, no daemon to ask,
//! straight to the service's socket in the session's runtime directory.
//!
//! ```text
//! abyssctl status              is the session up, and what is it running?
//! abyssctl quit                tear the session down
//! abyssctl lock                lock the screen (PHASE16 P16.2c)
//! abyssctl --service NAME ...  talk to some other service (default: anchor)
//! ```

use current_ipc::{Error, Msg};
use std::io::ErrorKind;
use std::process::exit;

const USAGE: &str = "usage: abyssctl [--service NAME] status|quit|lock";

fn fail(msg: &str) -> ! {
    eprintln!("abyssctl: {msg}");
    exit(1)
}

fn main() {
    let mut service = "anchor".to_owned();
    let mut method: Option<String> = None;
    let mut args = std::env::args().skip(1);
    while let Some(a) = args.next() {
        match a.as_str() {
            "--service" => service = args.next().unwrap_or_else(|| fail("--service needs a name")),
            "-h" | "--help" => {
                println!("{USAGE}");
                exit(0);
            }
            _ if method.is_some() => fail(&format!("one method at a time (got '{a}' too)")),
            _ => method = Some(a),
        }
    }
    let Some(method) = method else {
        eprintln!("{USAGE}");
        exit(2)
    };
    let mut request = Msg::new();
    request.set_string("method", &method);
    let reply = match current_ipc::call(&service, &request) {
        Ok(r) => r,
        // By far the commonest: nothing is running. Say that, not an errno.
        Err(Error::System(e, _)) if matches!(std::io::Error::from_raw_os_error(e).kind(), ErrorKind::NotFound | ErrorKind::ConnectionRefused) => {
            let dir = current_ipc::runtime_dir().unwrap_or_else(|_| "?".into());
            fail(&format!("no '{service}' service — is the session running? (runtime dir: {dir})"))
        }
        Err(e) => fail(&e.to_string()),
    };
    if reply.bool("ok") != Some(true) {
        fail(reply.string("error").unwrap_or("the service said no"));
    }
    match method.as_str() {
        "status" => {
            println!("session: running");
            println!("components: {}", reply.u64("components").unwrap_or(0));
            // "locked" only once the compositor said so (P16.2c, P16.3).
            let lock = if reply.bool("locked") == Some(true) {
                "locked"
            } else if reply.bool("locking") == Some(true) {
                "locking"
            } else {
                "no"
            };
            println!("lock: {lock}");
            for part in reply.string("detail").unwrap_or("").split(',').filter(|p| !p.is_empty()) {
                println!("  {part}");
            }
            if let Some(bus) = reply.string("bus").filter(|b| !b.is_empty()) {
                println!("bus: {bus}");
            }
        }
        "quit" | "shutdown" => println!("session: shutting down"),
        "lock" => println!("{}", if reply.bool("already") == Some(true) { "session: already locked" } else { "session: locking" }),
        _ => println!("ok"),
    }
}
