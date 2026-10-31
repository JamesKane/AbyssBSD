//! abyss-settings: System Preferences' privileged half (PHASE14 P14.3),
//! ported from main.swift beside it.
//!
//!   abyss-settings --uid N [--dry-run] [--once] [--service NAME]
//!                  [--rc-conf PATH] [--resolvconf PATH] [--sysctl-conf PATH] [--journal PATH]
//!                  [--admin-group NAME] [--write-only]
//!
//! Root, commanded by an unprivileged pane, as `abyss-install` is, and for
//! the same reasons arranged the same way: no toolkit, no display, no event
//! loop, one connection at a time, and nothing decided here that a plan did
//! not say.
//!
//! `--uid` is the session's user; the socket is handed to that uid alone and
//! the service asks the kernel who called, then whether they are an
//! administrator (§6.1). `--rc-conf` and `--journal` are for tests that must
//! not change the machine they run on; on an installed system they are the
//! defaults.

use current_ipc::Server;
use settings_run::{Authority, SettingsService};
use std::process::exit;

const USAGE: &str = "usage: abyss-settings --uid N [--dry-run] [--once] [--service NAME] [--rc-conf PATH] [--resolvconf PATH] [--sysctl-conf PATH] [--wpa-conf PATH] [--journal PATH] [--admin-group NAME] [--write-only]";

fn main() {
    let mut allowed: Option<u32> = None;
    let (mut once, mut service_name, mut admin_group) = (false, "settings".to_owned(), "wheel".to_owned());
    let mut service = SettingsService::new(Authority::new(0));
    let mut args = std::env::args().skip(1);
    while let Some(a) = args.next() {
        let mut value = || {
            args.next().unwrap_or_else(|| {
                eprintln!("abyss-settings: {a} needs a value");
                exit(2)
            })
        };
        match a.as_str() {
            "--uid" => {
                allowed = Some(value().parse().unwrap_or_else(|_| {
                    eprintln!("abyss-settings: --uid needs a number");
                    exit(2)
                }))
            }
            "--dry-run" => service.how.dry_run = true,
            "--once" => once = true,
            "--service" => service_name = value(),
            "--rc-conf" => service.rc_conf = value(),
            "--resolvconf" => service.resolvconf = value(),
            "--sysctl-conf" => service.sysctl_conf = value(),
            "--wpa-conf" => service.wpa_conf = value(),
            "--write-only" => service.how.write_only = true,
            "--journal" => service.journal = value(),
            // Accounts in a scratch root, for a test (P16.6a).
            "--pw-root" => service.how.pw_root = value(),
            "--admin-group" => admin_group = value(),
            "-h" | "--help" => {
                println!("{USAGE}");
                exit(0)
            }
            other => {
                eprintln!("abyss-settings: unknown option '{other}'");
                exit(2)
            }
        }
    }
    // **Nobody by default.** The installer admits its own uid when told
    // nothing; this helper has no reason to exist except for a person's
    // session, so it says whose, or it does not start.
    let Some(uid) = allowed else {
        eprintln!("abyss-settings: --uid is required — whose session may change the machine?");
        exit(2)
    };
    service.authority = Authority { allowed: uid, admin_group };

    let mut server = Server::new(&service_name).unwrap_or_else(|e| {
        eprintln!("abyss-settings: cannot bind the settings service: {e}");
        exit(1)
    });
    // The socket opens to exactly that uid; the peer check then confirms the
    // caller is it, and an administrator (the installer's two locks, PHASE5
    // §4.4).
    if uid != abyss_sys::platform::euid()
        && let Err(e) = std::os::unix::fs::chown(&server.path, Some(uid), None)
    {
        eprintln!("abyss-settings: cannot hand {} to uid {uid}: {e}", server.path);
        exit(1)
    }
    let mut note = format!("settings: serving {} for uid {uid}, administrators in {}", server.path, service.authority.admin_group);
    if service.how.dry_run {
        note += " (dry run — nothing will be written)";
    }
    if service.how.write_only {
        note += " (write only — files are written, the machine is left as it is)";
    }
    if let Some(why) = service.platform_refusal() {
        note += &format!(" — {why}");
    }
    if abyss_sys::platform::euid() != 0 && !service.how.dry_run && service.rc_conf == "/etc/rc.conf" {
        note += " — NOT running as root";
    }
    eprintln!("{note}");

    loop {
        let Ok(client) = server.accept() else { continue };
        let note = service.serve(&client, &mut |s| eprintln!("settings: {s}"));
        eprintln!("settings: {note}");
        drop(client);
        if once {
            break;
        }
    }
    server.shutdown_and_unlink();
}
