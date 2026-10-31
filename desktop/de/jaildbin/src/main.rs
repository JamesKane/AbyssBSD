//! abyss-jaild: the root half of confinement (PHASE18 P18.2), ported from
//! main.swift beside it.
//!
//!   abyss-jaild [--socket PATH] [--classes FILE] [--pool NAME]
//!               [--root-base DIR] [--home-base DIR] [--once]
//!
//! Root. Builds a person's jail of a class and hands them the owning
//! descriptor; starts programs in it as them; removes the root when they
//! let go. `--root-base` and `--home-base` move the jails somewhere a test
//! can see and remove; `--pool` keeps private homes in ZFS datasets (§6.3).
//! FreeBSD only: Linux has no jails, and it says so.

use current_ipc::Server;
use jaild::{wire, JailCommands, JailService};
use jails::{JailClass, JailLayout};
use std::os::unix::fs::MetadataExt;
use std::process::exit;

fn main() {
    let (mut socket, mut classes_file, mut pool, mut once) = (wire::DEFAULT_SOCKET.to_owned(), None, None, false);
    let mut layout = JailLayout::default();
    let mut args = std::env::args().skip(1);
    while let Some(a) = args.next() {
        let mut value = || {
            args.next().unwrap_or_else(|| {
                eprintln!("abyss-jaild: {a} needs a value");
                exit(2)
            })
        };
        match a.as_str() {
            "--socket" => socket = value(),
            "--classes" => classes_file = Some(value()),
            "--pool" => pool = Some(value()),
            "--root-base" => layout.root_base = value(),
            "--home-base" => layout.home_base = value(),
            "--once" => once = true,
            "-h" | "--help" => {
                println!("usage: abyss-jaild [--socket PATH] [--classes FILE] [--pool NAME] [--root-base DIR] [--home-base DIR] [--once]");
                exit(0)
            }
            other => {
                eprintln!("abyss-jaild: unknown option '{other}'");
                exit(2)
            }
        }
    }
    if !cfg!(target_os = "freebsd") {
        eprintln!("abyss-jaild: this platform has no jails — confinement is FreeBSD's");
        exit(1)
    }
    if abyss_sys::platform::euid() != 0 {
        eprintln!("abyss-jaild: must run as root: it mounts and creates jails");
        exit(1)
    }
    // The classes: the shipped ones, with a root-owned file's over them. A
    // file anyone else could write is not read: what root mounts is not a
    // user's call.
    let mut classes = JailClass::shipped();
    if let Some(f) = classes_file
        && let Ok(st) = std::fs::metadata(&f)
    {
        if st.uid() != 0 || st.mode() & 0o022 != 0 {
            eprintln!("abyss-jaild: {f} is not root's alone (owner {}, mode {:o}) — ignored", st.uid(), st.mode() & 0o777);
        } else if let Ok(text) = std::fs::read(&f) {
            classes = JailClass::table(Some(&pool_config::Config::parse_bytes(&text)));
        }
    }
    // 0666: anyone may ask, for themselves; the kernel says who they are.
    let server = Server::bind(&socket, 0o666).unwrap_or_else(|e| {
        eprintln!("abyss-jaild: cannot bind {socket}: {e}");
        exit(1)
    });
    let names: Vec<&str> = classes.iter().map(|c| c.name.as_str()).collect();
    let homes = pool.as_ref().map_or(layout.home_base.clone(), |p| format!("{p}/abyss/jails"));
    eprintln!("jaild: answering at {socket}; classes {}; roots in {}, homes in {homes}", names.join(", "), layout.root_base);
    let mut daemon = JailService::new(server, layout, classes, pool, JailCommands::default(), |s| eprintln!("{s}"));
    daemon.sweep();
    daemon.run(once);
}
