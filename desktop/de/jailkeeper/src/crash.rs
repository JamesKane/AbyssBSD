//! A confined program that died of a signal (P18.9), and which arguments of
//! a launch are the person's files (P18.5). Pure, given where things are.

use jails::under;

/// Which arguments of a launch are the person's files: an absolute path to
/// a regular file outside what the jail sees anyway. Never argv[0].
pub fn launch_files(argv: &[String], system: &[String], resolve: impl Fn(&str) -> Option<String>) -> Vec<(usize, String)> {
    argv.iter()
        .enumerate()
        .skip(1)
        .filter(|(_, a)| a.starts_with('/'))
        .filter_map(|(i, a)| resolve(a).map(|real| (i, real)))
        .filter(|(_, real)| !system.iter().any(|s| under(real, s)))
        .collect()
}

/// A path's resolved form if it is a regular file, else None.
pub fn regular_file(path: &str) -> Option<String> {
    let real = std::fs::canonicalize(path).ok()?;
    std::fs::metadata(&real).ok()?.is_file().then(|| real.to_string_lossy().into_owned())
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Crash {
    pub id: u64,
    pub program: String,
    pub jail: String,
    pub signal: i32,
    pub core_dumped: bool,
    /// The core, as the host sees it (it may not exist: a core size of 0).
    pub core: String,
    /// The binary inside the jail, and as the host sees it.
    pub binary_inside: String,
    pub binary: String,
}

impl Crash {
    /// The signal and whether a core was written, from a wait(2) status;
    /// None for a program that exited on its own, whatever its code, or one
    /// only stopped.
    pub fn signal_of(status: i32) -> Option<(i32, bool)> {
        let sig = status & 0x7f;
        (sig != 0 && sig != 0x7f).then_some((sig, status & 0x80 != 0))
    }

    /// The kernel's name for its core (`kern.corefile` = `%N.core`): the
    /// process's name, which is its file's, cut to MAXCOMLEN (19).
    pub fn core_name(program: &str) -> String {
        let base = program.rsplit('/').next().unwrap_or(program);
        let cut: String = base.chars().take(19).collect();
        format!("{cut}.core")
    }

    /// Where the binary is inside the jail: as given when absolute, else the
    /// first of the jail's PATH that has it (asked of the host, which sees
    /// the jail's root at `root`).
    pub fn binary_inside(program: &str, root: &str) -> Option<String> {
        if program.starts_with('/') {
            return Some(program.to_owned());
        }
        ["/bin", "/usr/bin", "/usr/local/bin"]
            .iter()
            .map(|d| format!("{d}/{program}"))
            .find(|p| abyss_sys::spawn::executable(&format!("{root}{p}")))
    }

    pub fn signal_name(s: i32) -> String {
        match s {
            libc::SIGSEGV => "SIGSEGV".into(),
            libc::SIGBUS => "SIGBUS".into(),
            libc::SIGABRT => "SIGABRT".into(),
            libc::SIGILL => "SIGILL".into(),
            libc::SIGFPE => "SIGFPE".into(),
            libc::SIGKILL => "SIGKILL".into(),
            libc::SIGTERM => "SIGTERM".into(),
            libc::SIGTRAP => "SIGTRAP".into(),
            _ => format!("signal {s}"),
        }
    }

    /// What happened, in a sentence: the debug agent's first line of
    /// context.
    pub fn summary(&self) -> String {
        format!(
            "{} was killed by {}{}",
            self.program,
            Crash::signal_name(self.signal),
            if self.core_dumped { " and left a core" } else { ", leaving no core" }
        )
    }
}
