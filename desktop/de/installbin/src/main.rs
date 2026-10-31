//! abyss-install: the installer's privileged half, ported from main.swift
//! beside it.
//!
//!   abyss-install [--uid N] [--dry-run] [--once] [--service NAME]
//!
//! It runs as root, it is commanded by an unprivileged GUI, and it is the
//! only program in this tree whose job is to destroy data. Everything about
//! it is arranged around that: no toolkit, no display, no network, no event
//! loop, and it decides nothing. It is handed a plan, refuses it or compiles
//! it, and runs the list (PHASE5 §1).
//!
//! `--uid` is who may command it. `anchor` knows the session's user and says
//! so; on its own it admits only the uid it runs as, which for a root
//! installer means root alone. It is never inferred from the socket's
//! permissions (PHASE5 §4.4). A client that hangs up mid-install cannot kill
//! it: Rust ignores SIGPIPE, and the disk is half-rewritten by then.

use current_ipc::Server;
use install_run::{Authority, InstallService};
use std::process::exit;

fn main() {
    let (mut allowed, mut dry_run, mut once, mut service_name) = (None, false, false, "install".to_owned());
    let mut args = std::env::args().skip(1);
    while let Some(a) = args.next() {
        match a.as_str() {
            "--uid" => {
                allowed = Some(args.next().and_then(|n| n.parse::<u32>().ok()).unwrap_or_else(|| {
                    eprintln!("abyss-install: --uid needs a number");
                    exit(2)
                }))
            }
            "--dry-run" => dry_run = true,
            "--once" => once = true,
            "--service" => {
                service_name = args.next().unwrap_or_else(|| {
                    eprintln!("abyss-install: --service needs a name");
                    exit(2)
                })
            }
            "-h" | "--help" => {
                println!("usage: abyss-install [--uid N] [--dry-run] [--once] [--service NAME]");
                exit(0)
            }
            other => {
                eprintln!("abyss-install: unknown option '{other}'");
                exit(2)
            }
        }
    }

    let authority = allowed.map_or_else(Authority::own, Authority::new);
    let service = InstallService::new(authority, dry_run);
    let mut server = Server::new(&service_name).unwrap_or_else(|e| {
        eprintln!("abyss-install: cannot bind the install service: {e}");
        exit(1)
    });

    // **Being allowed to command it has to mean being able to reach it.**
    // The peer check answers "is this caller the one I was started for"; it
    // does not get the caller through a root-owned 0600 socket. So the socket
    // is opened to exactly the uid named: permissions alone are defeated by
    // anything running as root, and the peer check alone grants nobody access.
    let euid = abyss_sys::platform::euid();
    if authority.allowed != euid
        && let Err(e) = std::os::unix::fs::chown(&server.path, Some(authority.allowed), None)
    {
        eprintln!("abyss-install: cannot hand {} to uid {}: {e}", server.path, authority.allowed);
        exit(1)
    }
    eprintln!(
        "install: serving {} for uid {}{}{}",
        server.path,
        authority.allowed,
        if dry_run { " (dry run — nothing will be written)" } else { "" },
        if euid == 0 { "" } else { " — NOT running as root, so every step will fail" }
    );

    // Strictly one connection at a time. There is no version of this program
    // where two installs at once is a thing somebody wanted.
    loop {
        let Ok(client) = server.accept() else { continue };
        let note = service.serve(&client, &mut |s| eprintln!("install: {s}"));
        eprintln!("install: {note}");
        drop(client);
        if once {
            break;
        }
    }
    server.shutdown_and_unlink();
}
