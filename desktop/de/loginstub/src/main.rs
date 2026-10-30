//! abyss-loginstub: a stand-in authenticator, for tests only (PHASE16
//! P16.2b), ported from main.swift beside it.
//!
//!   abyss-loginstub --socket PATH --password-file FILE [--acpiconf PATH] [--shutdown PATH] ...
//!
//! The lock screen's test needs an authenticator that answers on Linux,
//! where there is no PAM, and in the guest without a throwaway account. This
//! serves the **real** `Authenticator` and `LoginService` (the uid from the
//! kernel, the limiter, the log lines, the sessions) with PAM's check
//! replaced by "is it the bytes in FILE". Like `ipcprobe` it is a probe:
//! nothing ships it.

use current_ipc::Server;
use login::{Authenticator, Check, LoginService, PowerCommands, SessionConfig, SessionManager};
use std::process::exit;

fn usage() -> ! {
    eprintln!("usage: abyss-loginstub --socket PATH --password-file FILE");
    exit(2)
}

fn main() {
    let (mut socket, mut password_file) = (String::new(), String::new());
    // By default, commands that fail, so nothing is asked of this machine
    // by accident.
    let mut commands = PowerCommands { acpiconf: "/nonexistent/acpiconf".into(), shutdown: "/nonexistent/shutdown".into() };
    let (mut lock_timeout, mut system_uid, mut greeter_uid, mut greeter) = (8.0, 0u32, None, false);
    let mut sessions = SessionConfig::default();
    let mut args = std::env::args().skip(1);
    while let Some(a) = args.next() {
        let mut value = || args.next().unwrap_or_default();
        match a.as_str() {
            "--socket" => socket = value(),
            "--password-file" => password_file = value(),
            "--acpiconf" => commands.acpiconf = value(),
            "--shutdown" => commands.shutdown = value(),
            "--lock-timeout" => lock_timeout = value().parse().unwrap_or(8.0),
            // Whose word counts as devd's: a test cannot be root.
            "--system-uid" => system_uid = value().parse().unwrap_or(0),
            // Whose word counts as the login window's: a test's own account.
            "--greeter-uid" => greeter_uid = value().parse().ok(),
            // Sessions, as the real daemon's --greeter (P16.5b), with this
            // test's own account standing in for _loginwindow and everyone.
            "--greeter" => greeter = true,
            "--greeter-user" => sessions.greeter_user = value(),
            "--session-command" => sessions.command = value(),
            "--session-log-dir" => sessions.log_directory = value(),
            "--runtime-root" => sessions.runtime_root = value(),
            "--session-path" => sessions.path = value(),
            "--vt-command" => sessions.vt_command = Some(value()),
            // Two named users, both this account, each in its own runtime
            // directory (P16.6b).
            "--sessions-as-self" => sessions.sessions_as_self = true,
            "--session-env" => {
                if let Some((k, v)) = value().split_once('=') {
                    sessions.extra_environment.insert(k.into(), v.into());
                }
            }
            other => {
                eprintln!("abyss-loginstub: unknown option '{other}'");
                exit(2)
            }
        }
    }
    if socket.is_empty() || password_file.is_empty() {
        usage();
    }
    let Ok(text) = std::fs::read(&password_file) else { usage() };
    let secret: Vec<u8> = text.split(|&b| b == b'\n').next().unwrap_or(&[]).to_vec();

    let server = Server::bind(&socket, 0o600).unwrap_or_else(|e| {
        eprintln!("abyss-loginstub: cannot bind {socket}: {e}");
        exit(1)
    });
    eprintln!("loginstub: answering at {socket}");
    let auth = Authenticator::new(|uid| abyss_sys::users::by_uid(uid).map(|a| a.name), move |_, pw| if pw == secret { Check::Yes } else { Check::No("not the stub's password".into()) });
    let mut service = LoginService::new(server, auth, commands, |s| eprintln!("{s}"));
    service.lock_timeout = lock_timeout;
    service.system_uid = system_uid;
    service.greeter_uid = greeter_uid;
    if greeter {
        sessions.extra_environment.insert("ABYSS_LOGIN_SOCKET".into(), socket.clone());
        if sessions.sessions_as_self {
            let me = abyss_sys::platform::euid();
            service.uid_of = Box::new(move |_| Some(me));
        }
        service.sessions = Some(SessionManager::new(sessions, |s| eprintln!("{s}")));
    }
    service.run(false);
}
