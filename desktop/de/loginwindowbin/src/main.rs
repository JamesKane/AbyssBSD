//! abyss-loginwindow: the session's privileged half (PHASE16 P16.1), ported
//! from main.swift beside it.
//!
//!   abyss-loginwindow [--socket PATH] [--pam-service NAME] [--once]
//!                     [--acpiconf PATH] [--shutdown PATH]
//!                     [--greeter [--session-command PATH] [--session-log-dir DIR]
//!                                [--runtime-root DIR] [--vt-command PATH]]
//!
//! Root. Answers one question, for whoever asks, about themselves: *is
//! this my password?* The caller is who the kernel says; a request names
//! nobody. A run of wrong answers makes the next one wait. The password is
//! never logged. And sleep, power and the login window's sessions. Linux has
//! no PAM here, and it says so rather than answering.

use current_ipc::Server;
use login::{Authenticator, LoginService, PowerCommands, SessionConfig, SessionManager};
use std::process::exit;

fn main() {
    let (mut socket, mut service, mut once, mut greeter) = (login::DEFAULT_SOCKET.to_owned(), login::DEFAULT_SERVICE.to_owned(), false, false);
    let mut commands = PowerCommands::default();
    let mut sessions = SessionConfig::default();
    let mut args = std::env::args().skip(1);
    while let Some(a) = args.next() {
        let mut value = || {
            args.next().unwrap_or_else(|| {
                eprintln!("abyss-loginwindow: {a} needs a value");
                exit(2)
            })
        };
        match a.as_str() {
            "--socket" => socket = value(),
            "--pam-service" => service = value(),
            "--once" => once = true,
            // Stand-ins that record what was asked, for a test (PHASE16 §6.3).
            "--acpiconf" => commands.acpiconf = value(),
            "--shutdown" => commands.shutdown = value(),
            // The login window's sessions (P16.5b).
            "--greeter" => greeter = true,
            "--session-command" => sessions.command = value(),
            "--session-log-dir" => sessions.log_directory = value(),
            "--runtime-root" => sessions.runtime_root = value(),
            // A stand-in for the console's VT switch, for a test (P16.6b).
            "--vt-command" => sessions.vt_command = Some(value()),
            "-h" | "--help" => {
                println!(
                    "usage: abyss-loginwindow [--socket PATH] [--pam-service NAME] [--once] [--acpiconf PATH] [--shutdown PATH]\n                         [--greeter [--session-command PATH] [--session-log-dir DIR] [--runtime-root DIR]]"
                );
                exit(0)
            }
            other => {
                eprintln!("abyss-loginwindow: unknown option '{other}'");
                exit(2)
            }
        }
    }

    // The PAM this is written against is OpenPAM, in FreeBSD's base; the
    // Linux dev box has none. Refuse in words rather than answer "no" to
    // every password.
    if !cfg!(target_os = "freebsd") {
        eprintln!("abyss-loginwindow: this platform has no PAM to ask — the authenticator is FreeBSD's");
        exit(1);
    }
    // Only root can read master.passwd, so only root can answer (§4.2).
    if abyss_sys::platform::euid() != 0 {
        eprintln!("abyss-loginwindow: not running as root — PAM can check no password but root's own");
    }

    // 0666: every user may ask. What they may ask is limited by who the
    // kernel says they are, not by this.
    let server = Server::bind(&socket, 0o666).unwrap_or_else(|e| {
        eprintln!("abyss-loginwindow: cannot bind {socket}: {e}");
        exit(1)
    });
    eprintln!("loginwindow: answering at {socket}, PAM service {service}");
    let mut daemon = LoginService::new(server, Authenticator::system(&service), commands, |s| eprintln!("{s}"));
    daemon.greeter_uid = abyss_sys::users::by_name(login::GREETER_USER).map(|a| a.uid);
    if let Some(uid) = daemon.greeter_uid {
        eprintln!("loginwindow: the login window's account is {} (uid {uid})", login::GREETER_USER);
    }
    if greeter {
        // Without its account the login window cannot run and nobody could
        // log in: say so, and answer the rest (the lock screen still asks).
        if daemon.greeter_uid.is_none() {
            eprintln!("loginwindow: --greeter, but there is no {} account — no login window", login::GREETER_USER);
        } else {
            daemon.sessions = Some(SessionManager::new(sessions, |s| eprintln!("{s}")));
        }
    }
    daemon.run(once);
}
