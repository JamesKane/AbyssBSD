//! The runner: steps, run in order, with every file written whole or not
//! at all.

use settings::{edit_file, ConfFile, SettingsStep};
use settings_wire::SettingsEvent;
use spawn::{ErrorOutput, Options, Output};
use std::fs::{self, OpenOptions, Permissions};
use std::io::Write;
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};

/// How the steps are run.
#[derive(Clone, Debug)]
pub struct How {
    /// Report every step and run none: identical events, nothing written.
    pub dry_run: bool,
    /// Write the files for real, but run no service and no tool: for a test
    /// on a machine whose network is how the test reaches it (PHASE14 §6.3).
    /// Each step it does not run is reported as skipped, never as done.
    pub write_only: bool,
    /// Where `pw` makes and deletes accounts: `/`, or a test's scratch root.
    pub pw_root: String,
}

impl Default for How {
    fn default() -> How {
        How { dry_run: false, write_only: false, pw_root: "/".into() }
    }
}

/// Run the steps, reporting each. File writes go into a **staged copy** of
/// each file, and the copies replace the real files only once every write
/// to every file succeeded, so a plan that fails half-way leaves rc.conf and
/// resolvconf.conf exactly as they were, rather than half-changed with
/// nobody knowing which half. Services and tools act after that, on the
/// files now in place.
pub fn apply(steps: &[SettingsStep], path: &dyn Fn(ConfFile) -> String, how: &How, emit: &mut dyn FnMut(SettingsEvent)) -> bool {
    let last_write = steps.iter().rposition(|s| !s.acts());
    let mut staged: Vec<(ConfFile, String)> = vec![];
    let total = steps.len() as u64;

    for (i, step) in steps.iter().enumerate() {
        let what = step.to_string();
        let index = i as u64;
        emit(SettingsEvent::Starting { index, total, what: what.clone() });
        if how.dry_run {
            emit(SettingsEvent::Ok { index });
            continue;
        }
        if let SettingsStep::SetVar { file, key, value } = step {
            let copy = match staged.iter().find(|(f, _)| f == file) {
                Some((_, c)) => c.clone(),
                None => {
                    let copy = format!("{}.abyss-staged", path(*file));
                    if let Err(why) = copy_file(&path(*file), &copy, file.new_file_mode()) {
                        return fail(&mut staged, emit, i, &what, why);
                    }
                    staged.push((*file, copy.clone()));
                    copy
                }
            };
            if !file.is_shell_variables() {
                // sysctl.conf and wpa_supplicant.conf are not sh; sysrc
                // refuses them. Edited here.
                let text = edit_file(*file, &read_text(&copy).unwrap_or_default(), key, value.as_deref());
                if let Err(why) = write_text(&text, &copy) {
                    return fail(&mut staged, emit, i, &what, why);
                }
            } else {
                let lookup = |f: ConfFile| staged.iter().find(|(g, _)| *g == f).map_or_else(|| path(f), |(_, c)| c.clone());
                let r = run(&step.command_in(&lookup, &how.pw_root), None);
                if !r.succeeded() {
                    return fail(&mut staged, emit, i, &what, reason(&r));
                }
            }
            if Some(i) == last_write {
                // Every write succeeded: now, and only now, the real files.
                staged.sort_by_key(|(f, _)| f.name());
                while let Some((f, copy)) = staged.first().cloned() {
                    if let Err(e) = fs::rename(&copy, path(f)) {
                        return fail(&mut staged, emit, i, &what, format!("could not put the new {} in place: {}", f.name(), words(&e)));
                    }
                    staged.remove(0);
                }
            }
            emit(SettingsEvent::Ok { index });
            continue;
        }
        if how.write_only {
            emit(SettingsEvent::Skipped { index, why: "write-only: the machine is left as it is".into() });
            continue;
        }
        let (may_fail, input) = match step {
            SettingsStep::Service { may_fail, .. } | SettingsStep::Tool { may_fail, .. } => (*may_fail, None),
            SettingsStep::Pw { input, .. } => (false, input.as_ref().map(|s| format!("{s}\n").into_bytes())),
            SettingsStep::SetVar { .. } => (false, None),
        };
        let r = run(&step.command_in(path, &how.pw_root), input);
        if r.succeeded() {
            emit(SettingsEvent::Ok { index });
        } else if may_fail {
            emit(SettingsEvent::Failed { index, what, why: reason(&r), ignored: true });
        } else {
            return fail(&mut staged, emit, i, &what, reason(&r));
        }
    }
    emit(SettingsEvent::Finished { ok: true, error: String::new() });
    true
}

/// Discard the staged copies and report the plan failed at step `i`.
fn fail(staged: &mut Vec<(ConfFile, String)>, emit: &mut dyn FnMut(SettingsEvent), i: usize, what: &str, why: String) -> bool {
    for (_, copy) in staged.drain(..) {
        let _ = fs::remove_file(copy);
    }
    emit(SettingsEvent::Failed { index: i as u64, what: what.into(), why: why.clone(), ignored: false });
    emit(SettingsEvent::Finished { ok: false, error: format!("{what}: {why}") });
    false
}

/// The single-file form the energy plan and its tests use: rc.conf at
/// `rc_conf`, the rest in /etc.
pub fn apply_rc_conf(steps: &[SettingsStep], rc_conf: &str, dry_run: bool, emit: &mut dyn FnMut(SettingsEvent)) -> bool {
    let path = |f: ConfFile| if f == ConfFile::RcConf { rc_conf.to_owned() } else { f.etc_path() };
    apply(steps, &path, &How { dry_run, ..How::default() }, emit)
}

/// A command, stderr merged into what it says.
pub(crate) fn run(argv: &[String], input: Option<Vec<u8>>) -> Output {
    let argv: Vec<&str> = argv.iter().map(String::as_str).collect();
    spawn::run_with(&argv, Options { input, stderr: ErrorOutput::Merge, limit: 65536, ..Options::default() })
}

/// What went wrong, as the command said it.
pub(crate) fn reason(r: &Output) -> String {
    if let Some(f) = &r.failure {
        return f.clone();
    }
    let said = trimmed(&r.stdout_text()).to_owned();
    if said.is_empty() { format!("exited {} and said nothing", r.code()) } else { said }
}

pub(crate) fn trimmed(s: &str) -> &str {
    s.trim_matches([' ', '\n', '\t'])
}

/// io::Error's words, as strerror says them.
fn words(e: &std::io::Error) -> String {
    let s = e.to_string();
    s.rfind(" (os error ").map_or(s.clone(), |i| s[..i].to_owned())
}

/// A whole (small) file, or None when it cannot be read.
pub(crate) fn read_text(path: &str) -> Option<String> {
    fs::read(path).ok().map(|b| String::from_utf8_lossy(&b).into_owned())
}

/// Replace a staged file's contents (its mode kept: it is truncated, not
/// recreated).
fn write_text(text: &str, path: &str) -> Result<(), String> {
    let mut f = OpenOptions::new().write(true).truncate(true).open(path).map_err(|e| format!("could not write {path}: {}", words(&e)))?;
    f.write_all(text.as_bytes()).map_err(|e| format!("could not write {path}: {}", words(&e)))
}

/// Copy `from` to `to` with `from`'s mode, or, when `from` does not exist,
/// make an empty file with `new_mode`: a machine with no rc.conf yet gets
/// its first one. The mode is set as well as asked for, so a copy a crash
/// left behind does not keep a looser one.
fn copy_file(from: &str, to: &str, new_mode: u32) -> Result<(), String> {
    let source = fs::metadata(from).ok();
    let mode = source.as_ref().map_or(new_mode, |m| m.permissions().mode() & 0o7777);
    let stage = |e: std::io::Error| format!("could not stage {to}: {}", words(&e));
    let mut out = OpenOptions::new().write(true).create(true).truncate(true).mode(mode).open(to).map_err(stage)?;
    out.set_permissions(Permissions::from_mode(mode)).map_err(stage)?;
    if source.is_none() {
        return Ok(());
    }
    let bytes = fs::read(from).map_err(|e| format!("could not read {from}: {}", words(&e)))?;
    out.write_all(&bytes).map_err(stage)
}
