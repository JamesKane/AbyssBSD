//! Carries steps out, as root (Performer.swift, PHASE18 P18.2).
//!
//! It decides nothing: the steps are `steps`', and the first one that fails
//! stops the run with its reason. The service undoes a half-built root with
//! the same teardown as a whole one.

use crate::steps::{JailCommands, JailStep};
use spawn::{ErrorOutput, Options};
use std::fmt;
use std::fs::{self, DirBuilder, OpenOptions, Permissions};
use std::io::{ErrorKind, Write};
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt, PermissionsExt};

/// A step that failed, and why.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Failure {
    pub step: JailStep,
    pub why: String,
}

impl fmt::Display for Failure {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}: {}", self.step, self.why)
    }
}

#[derive(Clone, Debug, Default)]
pub struct Performer {
    pub commands: JailCommands,
}

fn words(e: &std::io::Error) -> String {
    let s = e.to_string();
    s.rfind(" (os error ").map_or(s.clone(), |i| s[..i].to_owned())
}

impl Performer {
    /// Perform `steps` in order; stop at the first that fails.
    pub fn perform(&self, steps: &[JailStep]) -> Result<(), Failure> {
        for s in steps {
            if let Err(why) = self.one(s) {
                return Err(Failure { step: s.clone(), why });
            }
        }
        Ok(())
    }

    /// Perform every step, failures and all, and return the failures:
    /// teardown, which must get as far as it can.
    pub fn perform_all(&self, steps: &[JailStep]) -> Vec<Failure> {
        steps.iter().filter_map(|s| self.one(s).err().map(|why| Failure { step: s.clone(), why })).collect()
    }

    /// One step: Ok, or the reason not.
    pub fn one(&self, step: &JailStep) -> Result<(), String> {
        match step {
            JailStep::Mkdir { path, uid, gid, mode } => {
                mkdirs(path)?;
                std::os::unix::fs::chown(path, Some(*uid), Some(*gid)).map_err(|e| format!("chown: {}", words(&e)))?;
                fs::set_permissions(path, Permissions::from_mode(u32::from(*mode))).map_err(|e| format!("chmod: {}", words(&e)))
            }
            JailStep::Dataset { name, mountpoint } => {
                if run_with(&[&self.commands.zfs, "list", "-H", "-o", "name", name]).succeeded() {
                    return Ok(());
                }
                self.run(&[&self.commands.zfs, "create", "-p", "-o", &format!("mountpoint={mountpoint}"), name])
            }
            JailStep::Run(argv) => self.run(&argv.iter().map(String::as_str).collect::<Vec<_>>()),
            JailStep::Write { path, contents, mode } => write(path, contents.as_bytes(), *mode),
            JailStep::CopyIfPresent { source, target } => match fs::read(source) {
                Ok(bytes) => write(target, &bytes, 0o644),
                Err(e) if e.kind() == ErrorKind::NotFound => Ok(()),
                Err(e) => Err(format!("{source}: {}", words(&e))),
            },
            JailStep::Remove(path) => match fs::remove_file(path) {
                Err(e) if e.kind() != ErrorKind::NotFound => Err(format!("unlink: {}", words(&e))),
                _ => Ok(()),
            },
            JailStep::Rmdir(path) => match fs::remove_dir(path) {
                Err(e) if e.kind() != ErrorKind::NotFound => Err(format!("rmdir: {}", words(&e))),
                _ => Ok(()),
            },
        }
    }

    fn run(&self, argv: &[&str]) -> Result<(), String> {
        let r = run_with(argv);
        if r.succeeded() {
            return Ok(());
        }
        let text = r.stdout_text();
        let said = text.lines().rfind(|l| !l.is_empty()).unwrap_or("");
        Err(format!("{} exited {}{}", argv.join(" "), r.code(), if said.is_empty() { String::new() } else { format!(": {said}") }))
    }
}

fn run_with(argv: &[&str]) -> spawn::Output {
    spawn::run_with(argv, Options { stderr: ErrorOutput::Merge, limit: 4096, ..Options::default() })
}

/// `mkdir -p`, each new directory 0755 until its step sets the last one.
fn mkdirs(path: &str) -> Result<(), String> {
    let mut made = String::new();
    for part in path.split('/').filter(|p| !p.is_empty()) {
        made.push('/');
        made.push_str(part);
        match DirBuilder::new().mode(0o755).create(&made) {
            Err(e) if e.kind() != ErrorKind::AlreadyExists => return Err(format!("mkdir {made}: {}", words(&e))),
            _ => {}
        }
    }
    Ok(())
}

/// Write `bytes` with exactly `mode`, never through a link: a root
/// writing into a tree a person can reach must not be steered elsewhere.
fn write(path: &str, bytes: &[u8], mode: u16) -> Result<(), String> {
    let mode = u32::from(mode);
    let err = |e: std::io::Error| format!("{path}: {}", words(&e));
    let mut f = OpenOptions::new().write(true).create(true).truncate(true).mode(mode).custom_flags(libc::O_NOFOLLOW).open(path).map_err(err)?;
    f.write_all(bytes).map_err(err)?;
    f.set_permissions(Permissions::from_mode(mode)).map_err(err)
}
