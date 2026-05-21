// SPDX-License-Identifier: BSD-2-Clause

//! AbyssBSD build & CI harness.
//!
//! Run via the `cargo xtask` alias (see `.cargo/config.toml`). This is the
//! single source of truth for the CI lane (docs/ROADMAP.md, Phase 0): a
//! future Forgejo workflow invokes `cargo xtask ci` and nothing more.

use std::process::{Command, ExitCode};

fn main() -> ExitCode {
    match std::env::args().nth(1).as_deref() {
        Some("ci") => run_ci(),
        _ => {
            eprintln!(
                "usage: cargo xtask <task>\n\ntasks:\n  ci    fmt-check, clippy, build, test"
            );
            ExitCode::FAILURE
        }
    }
}

/// The CI lane: every step the host build must pass, in order.
fn run_ci() -> ExitCode {
    let steps: &[(&str, &[&str])] = &[
        ("format", &["fmt", "--all", "--check"]),
        (
            "clippy",
            &[
                "clippy",
                "--workspace",
                "--all-targets",
                "--",
                "-D",
                "warnings",
            ],
        ),
        ("build", &["build", "--workspace", "--all-targets"]),
        ("test", &["test", "--workspace"]),
    ];
    for (name, args) in steps {
        eprintln!("\n=== xtask ci: {name} ===");
        if !cargo(args) {
            eprintln!("\nxtask ci: `{name}` failed");
            return ExitCode::FAILURE;
        }
    }
    eprintln!("\nxtask ci: all steps passed");
    ExitCode::SUCCESS
}

/// Run a `cargo` subcommand, inheriting stdio. Uses `$CARGO` (set by cargo
/// when it spawns this task) so it works without `cargo` on `PATH`.
fn cargo(args: &[&str]) -> bool {
    let cargo = std::env::var("CARGO").unwrap_or_else(|_| "cargo".to_owned());
    Command::new(cargo)
        .args(args)
        .status()
        .is_ok_and(|status| status.success())
}
