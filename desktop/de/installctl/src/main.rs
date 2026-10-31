//! abyss-installctl: the command-line face of the installer, ported from
//! main.swift beside it.
//!
//!   abyss-installctl disks
//!   abyss-installctl check   --disk NAME [plan options]
//!   abyss-installctl install --disk NAME [plan options]
//!
//! It links `install-wire` and **not** `install-run`: a client speaks the
//! protocol, it does not carry the code that runs `gpart`. The GUI is built
//! the same way. This exists because the harness needs a caller, and because
//! an installer whose privileged half only a graphical program can drive is
//! one you cannot debug on a machine with no graphics, which, for an
//! installer, is every machine it has not finished installing yet.

use current_ipc::Msg;
use install::{Account, InstallPlan};
use install_wire::RunEvent;
use std::process::exit;

fn usage() -> ! {
    println!(
        "usage: abyss-installctl <disks|check|install> [options]
  --disk NAME          the whole disk to take (required for check/install)
  --pool NAME          pool name (default abyss)
  --dist DIR           where the distribution sets are
  --sets a.txz,b.txz   which sets to extract (default base,kernel)
  --hostname NAME
  --timezone ZONE      e.g. America/Chicago
  --swap MiB           0 for none
  --root-hash HASH     already-hashed root password
  --user NAME:HASH[:GROUPS]
  --service NAME       the service to talk to (default install)
  --yes                do not ask before the first destructive step
  --autologin          start the owner's desktop at boot, no password
                       (default: the login window — PHASE16 §6.2)"
    );
    exit(0)
}

fn die(why: impl std::fmt::Display) -> ! {
    eprintln!("abyss-installctl: {why}");
    exit(2)
}

fn main() {
    let mut args = std::env::args().skip(1);
    let verb = args.next().unwrap_or_default();
    if !["disks", "check", "install"].contains(&verb.as_str()) {
        usage()
    }
    let mut plan = InstallPlan::new("");
    plan.root_password_hash = String::new();
    let (mut service_name, mut assume_yes) = ("install".to_owned(), false);
    while let Some(flag) = args.next() {
        let mut value = || args.next().unwrap_or_else(|| die(format!("{flag} needs a value")));
        match flag.as_str() {
            "--disk" => plan.disk = value(),
            "--pool" => plan.pool_name = value(),
            "--dist" => plan.dist_directory = value(),
            "--hostname" => plan.hostname = value(),
            "--timezone" => plan.timezone = value(),
            "--swap" => plan.swap_bytes = value().parse::<u64>().unwrap_or(0).saturating_mul(1 << 20),
            "--root-hash" => plan.root_password_hash = value(),
            "--sets" => plan.sets = value().split(',').filter(|s| !s.is_empty()).map(str::to_owned).collect(),
            "--service" => service_name = value(),
            "--yes" => assume_yes = true,
            "--user" => {
                let spec = value();
                let mut parts = spec.splitn(3, ':');
                let (Some(name), Some(hash)) = (parts.next(), parts.next()) else { die("--user wants NAME:HASH[:GROUPS]") };
                let mut a = Account::new(name, hash);
                a.groups = parts.next().map(|g| g.split(',').filter(|s| !s.is_empty()).map(str::to_owned).collect()).unwrap_or_default();
                plan.accounts.push(a);
            }
            // **The confirmation, spelled out.** A disk that is already full
            // is refused until somebody says this, and the flag is long and
            // unpleasant on purpose: it is the sentence that turns "refuse"
            // into "destroy what is there".
            "--erase-this-disk" => plan.erase_existing_data = true,
            "--autologin" => plan.auto_login = true,
            "-h" | "--help" => usage(),
            other => die(format!("unknown option '{other}'")),
        }
    }
    if plan.sets.is_empty() {
        plan.sets = InstallPlan::new("").sets;
    }
    if plan.root_password_hash.is_empty() {
        plan.root_password_hash = "*".into();
    }

    let mut request = Msg::new();
    request.set_string("method", &verb);
    if verb != "disks" {
        install_wire::encode_plan(&plan, &mut request);
    }
    let sock = current_ipc::connect(&service_name).unwrap_or_else(|e| {
        eprintln!("abyss-installctl: cannot reach the installer: {e}");
        exit(1)
    });
    if let Err(e) = current_ipc::send(&request, &sock) {
        eprintln!("abyss-installctl: cannot send the request: {e}");
        exit(1)
    }
    let reply = || {
        current_ipc::receive(&sock).unwrap_or_else(|_| {
            eprintln!("abyss-installctl: no reply");
            exit(1)
        })
    };

    match verb.as_str() {
        "disks" => {
            let r = reply();
            if r.bool("ok") != Some(true) {
                eprintln!("cannot look at this machine's disks: {}", r.string("error").unwrap_or("?"));
                exit(1)
            }
            let inv = install_wire::decode_inventory(&r);
            for d in &inv.disks {
                let mut notes = vec![];
                if d.holds_running_root {
                    notes.push("holds the running root".to_owned());
                }
                if !d.mounted_at.is_empty() {
                    notes.push(format!("mounted at {}", d.mounted_at.join(" ")));
                }
                let tenths = u128::from(d.bytes) * 10 / (1 << 30);
                let descr = if d.description.is_empty() { String::new() } else { format!("\t{}", d.description) };
                let notes = if notes.is_empty() { String::new() } else { format!("\t[{}]", notes.join("; ")) };
                println!("{}\t{}.{} GiB{descr}{notes}", d.name, tenths / 10, tenths % 10);
            }
            println!("pools: {}", if inv.imported_pools.is_empty() { "(none)".to_owned() } else { inv.imported_pools.join(" ") });
        }
        "check" => {
            let r = reply();
            let n = r.u64("problems.count").unwrap_or(0);
            if n > 0 {
                for k in 0..n {
                    eprintln!("refused: {}", r.string(&format!("problem.{k}")).unwrap_or("?"));
                }
                exit(1)
            }
            println!("{} steps:", r.u64("steps.count").unwrap_or(0));
            println!("{}", r.string("render").unwrap_or(""));
        }
        _ => {
            if !assume_yes {
                eprintln!("abyss-installctl: refusing to install without --yes. This rewrites {} and there is no undo.", plan.disk);
                exit(2)
            }
            let mut failed = false;
            while let Ok(m) = current_ipc::receive(&sock) {
                let Some(event) = install_wire::decode_event(&m) else {
                    // A refusal arrives as an ordinary reply rather than an event.
                    if m.bool("ok") == Some(false) {
                        eprintln!("refused: {}", m.string("error").unwrap_or("?"));
                        exit(1)
                    }
                    continue;
                };
                match event {
                    RunEvent::Starting { index, total, what, destructive } => {
                        println!("[{}/{total}] {what}{}", index + 1, if destructive { "  *" } else { "" })
                    }
                    RunEvent::Ok { .. } => {}
                    RunEvent::Failed { why, ignored, .. } => {
                        eprintln!("{}", if ignored { format!("    (allowed to fail: {why})") } else { format!("    FAILED: {why}") })
                    }
                    RunEvent::Finished { ok: true, .. } => println!("installed."),
                    RunEvent::Finished { ok: false, error } => {
                        eprintln!("install failed: {error}");
                        failed = true;
                    }
                }
            }
            exit(if failed { 1 } else { 0 })
        }
    }
}
