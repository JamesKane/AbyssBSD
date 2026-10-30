//! abyss-loginctl: ask the authenticator, from a shell (PHASE16 P16.1),
//! ported from main.swift beside it.
//!
//!   abyss-loginctl [--socket PATH] verify        the password on stdin, one line
//!   abyss-loginctl [--socket PATH] power sleep|restart|shut-down   (P16.4a)
//!   abyss-loginctl [--socket PATH] login USER    the password on stdin (P16.5a;
//!                                                the login window's account only)
//!   abyss-loginctl [--socket PATH] switch-user   lock this session, show the window
//!
//! Prints `accepted`, `refused`, `wait <ms>` or `unavailable: <why>`, and
//! exits 0 only for `accepted`.

use current_ipc::Msg;
use login::{client, PowerAction, Verdict};
use std::io::Read;
use std::process::exit;

/// One line from stdin, without its newline, as bytes.
fn password_line() -> Vec<u8> {
    let mut out = vec![];
    for b in std::io::stdin().lock().bytes() {
        match b {
            Ok(b'\n') | Err(_) => break,
            Ok(b) => out.push(b),
        }
    }
    out
}

fn verdict(v: Result<Verdict, login::LoginError>) -> ! {
    match v {
        Ok(Verdict::Accepted) => {
            println!("accepted");
            exit(0)
        }
        Ok(Verdict::Refused) => println!("refused"),
        Ok(Verdict::Wait(ms)) => println!("wait {ms}"),
        Ok(Verdict::Unavailable(why)) => println!("unavailable: {why}"),
        Err(e) => println!("error: {e}"),
    }
    exit(1)
}

/// `ok`, or the refusal's words.
fn answered(r: Result<Msg, login::LoginError>) -> ! {
    match r {
        Ok(r) if r.bool("ok") == Some(true) => {
            println!("ok");
            exit(0)
        }
        Ok(r) => println!("refused: {}", r.string("error").unwrap_or("?")),
        Err(e) => println!("error: {e}"),
    }
    exit(1)
}

fn main() {
    let mut args: Vec<String> = std::env::args().skip(1).collect();
    let mut socket = login::DEFAULT_SOCKET.to_owned();
    if args.len() >= 2 && args[0] == "--socket" {
        socket = args[1].clone();
        args.drain(..2);
    }
    let a: Vec<&str> = args.iter().map(String::as_str).collect();
    match a[..] {
        ["power", action] => {
            let Some(action) = PowerAction::from_name(action) else {
                println!("no such action: {action}");
                exit(2)
            };
            answered(client::power(action, &socket))
        }
        // Fast user switching (P16.6b): lock this session, show the window.
        ["switch-user"] => {
            let mut m = Msg::new();
            m.set_string("method", "switch-user");
            answered(client::call(m, &socket))
        }
        ["login", user] => {
            let mut pw = password_line();
            let r = client::login(user, &pw, &socket).and_then(|s| client::finish(&s));
            abyss_sys::pam::wipe(&mut pw);
            verdict(r)
        }
        ["verify"] => {
            let mut pw = password_line();
            let r = client::verify(&pw, &socket);
            abyss_sys::pam::wipe(&mut pw);
            verdict(r)
        }
        _ => {
            println!("usage: abyss-loginctl [--socket PATH] verify | login USER | power sleep|restart|shut-down");
            exit(2)
        }
    }
}
