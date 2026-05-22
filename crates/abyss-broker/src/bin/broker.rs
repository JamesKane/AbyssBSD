// SPDX-License-Identifier: BSD-2-Clause

//! The AbyssBSD broker — the desktop's root process.
//!
//! `rc` execs this as root (`docs/design/broker-and-transport.md` §5.1).
//! It reads the manifest set and the interface catalogue, builds the
//! authority graph, launches every component into its jail, and supervises
//! them for the life of the session: a component that exits is re-wired
//! and restarted (§5.5).
//!
//! Usage: `abyss-broker <manifest-dir> <catalogue-file> <bin-dir>`.
//!
//! **FreeBSD only.** On every other host it is a stub, so the macOS dev
//! bed still builds.

#[cfg(target_os = "freebsd")]
fn main() -> std::process::ExitCode {
    use std::path::Path;
    use std::process::ExitCode;

    let args: Vec<String> = std::env::args().collect();
    let [_, manifest_dir, catalogue, bin_dir] = args.as_slice() else {
        abyss_log::error!("usage: abyss-broker <manifest-dir> <catalogue-file> <bin-dir>");
        return ExitCode::from(2);
    };

    // Bring the session up from disk. A boot fault — a malformed manifest
    // set, an invalid authority graph, a bad catalogue — is fatal (§5.1).
    let mut session = match abyss_broker::boot(
        Path::new(manifest_dir),
        Path::new(catalogue),
        Path::new(bin_dir),
    ) {
        Ok(session) => session,
        Err(err) => {
            abyss_log::error!("{err}");
            return ExitCode::FAILURE;
        }
    };
    abyss_log::info!(
        "broker up — {} components wired and supervised",
        session.components().count(),
    );

    // The session's main loop: wait for a component to exit, re-wire and
    // restart it (§5.5). The broker runs this for the life of the session.
    loop {
        match session.step() {
            Ok(restarted) => {
                for name in restarted {
                    abyss_log::warn!("component `{name}` exited — re-wired and restarted");
                }
            }
            Err(err) => {
                abyss_log::error!("supervision failed: {err}");
                return ExitCode::FAILURE;
            }
        }
    }
}

#[cfg(not(target_os = "freebsd"))]
fn main() {
    // The broker creates jails and `pdfork`s components — FreeBSD
    // facilities; elsewhere it is a stub so the workspace still builds.
}
