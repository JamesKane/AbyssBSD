//! Running a step list (Runner.swift).
//!
//! `install` decides; this runs. By the time a list gets here every question
//! has been answered, so the runner has no judgement of its own to exercise
//! and no plan to second-guess. It executes, reports, and stops at the first
//! thing that goes wrong.
//!
//! **It stops.** An installer that carries on past a failed `gpart add`
//! finishes with a confident summary and a machine that will not boot. The
//! one exception is a step the plan marked `may_fail`, and the plan says why
//! each of those is allowed to.

use crate::probe::trimmed;
use install::{Action, Step};
use install_wire::RunEvent;
use spawn::{ErrorOutput, Options};
use std::fs::{OpenOptions, Permissions};
use std::io::Write;
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};

/// Execute a step list. Returns None on success, or the failure to report.
///
/// `dry_run` does everything except run the commands and write the files.
/// The events are identical, which is what makes it useful: a caller can
/// drive the whole flow, confirmations included, against a machine it is not
/// touching.
pub fn execute(steps: &[Step], dry_run: bool, report: &mut dyn FnMut(RunEvent)) -> Option<String> {
    let total = steps.len() as u64;
    for (i, step) in steps.iter().enumerate() {
        let index = i as u64;
        report(RunEvent::Starting { index, total, what: step.what.clone(), destructive: step.destructive });
        if dry_run {
            report(RunEvent::Ok { index });
            continue;
        }
        let failure = match &step.action {
            Action::Run { argv, stdin } => run_command(argv, stdin.as_deref()),
            Action::Write { path, contents, mode } => write_file(path, contents, *mode),
            Action::Append { path, contents } => append_file(path, contents),
        };
        let Err(why) = failure else {
            report(RunEvent::Ok { index });
            continue;
        };
        report(RunEvent::Failed { index, what: step.what.clone(), why: why.clone(), ignored: step.may_fail });
        if !step.may_fail {
            // The plan wrote this sentence when it was thinking clearly about
            // what this step is for; the kernel's words are the detail
            // underneath it.
            let error = format!("{} ({why})", step.on_failure);
            report(RunEvent::Finished { ok: false, error: error.clone() });
            return Some(error);
        }
    }
    report(RunEvent::Finished { ok: true, error: String::new() });
    None
}

/// Run a command, feeding it `stdin` if it has any. stdout follows stderr,
/// so a chatty command cannot interleave with the service's own output; and
/// without `stdin` the child reads /dev/null, never the installer's stdin,
/// since a command that decided to ask a question would otherwise hang the
/// install for ever.
fn run_command(argv: &[String], stdin: Option<&str>) -> Result<(), String> {
    let input = stdin.map(|s| if s.ends_with('\n') { s.as_bytes().to_vec() } else { format!("{s}\n").into_bytes() });
    let argv: Vec<&str> = argv.iter().map(String::as_str).collect();
    let r = spawn::run_with(&argv, Options { input, stderr: ErrorOutput::Merge, limit: 8192, ..Options::default() });
    if r.raw_status.is_none() {
        return Err(r.failure.unwrap_or_else(|| "it could not be started".into()));
    }
    if r.succeeded() {
        return Ok(());
    }
    let said = trimmed(&r.stdout_text()).to_owned();
    Err(if said.is_empty() { format!("exited {}", r.code()) } else { said })
}

fn words(e: &std::io::Error) -> String {
    let s = e.to_string();
    s.rfind(" (os error ").map_or(s.clone(), |i| s[..i].to_owned())
}

/// Write `contents` with exactly `mode`: `open` honours the umask, and the
/// plan said what the mode should be.
fn write_file(path: &str, contents: &str, mode: u16) -> Result<(), String> {
    let mode = u32::from(mode);
    let mut f = OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .mode(mode)
        .open(path)
        .map_err(|e| format!("open {path}: {}", words(&e)))?;
    f.write_all(contents.as_bytes()).map_err(|e| format!("write {path}: {}", words(&e)))?;
    f.set_permissions(Permissions::from_mode(mode)).map_err(|e| format!("chmod {path}: {}", words(&e)))
}

/// Append to a file that must already be there: the plan makes its files.
fn append_file(path: &str, contents: &str) -> Result<(), String> {
    let mut f = OpenOptions::new().append(true).open(path).map_err(|e| format!("open {path}: {}", words(&e)))?;
    f.write_all(contents.as_bytes()).map_err(|e| format!("write {path}: {}", words(&e)))
}

