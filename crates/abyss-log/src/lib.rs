// SPDX-License-Identifier: BSD-2-Clause

//! AbyssBSD logging — small, consistent, dependency-free.
//!
//! One logging vocabulary for the whole AbyssBSD layer, so component code
//! does not drift into a dozen private styles. Five levels, five macros,
//! one line format. There is no pluggable backend and nothing to
//! initialise: a log line is written to **stderr** the moment it is made.
//!
//! ```
//! abyss_log::info!("authority graph built ({} components)", 3);
//! abyss_log::warn!("peer `{}` restarted", "input");
//! ```
//!
//! Each macro tags the line with `module_path!()` automatically, so the
//! source of a line is consistent and cannot be mistyped.
//!
//! # Levels
//!
//! [`Level::Error`] down to [`Level::Trace`]. The active maximum defaults
//! to [`Level::Info`], is overridden by the `ABYSS_LOG` environment
//! variable (`error` / `warn` / `info` / `debug` / `trace`), and can be
//! set directly with [`set_level`]. Setting the maximum to `Debug` emits
//! `Error` through `Debug` and silences `Trace`.
//!
//! # Many processes
//!
//! AbyssBSD is many processes. Each writes its own log lines to its own
//! stderr; the broker, which spawned each component and holds the read end
//! of its stderr, is what aggregates them (`docs/design/broker-and-transport.md`
//! §5). This crate stays deliberately ignorant of that — stderr is the
//! seam, and a not-yet-redirected process simply logs to the console.
//!
//! Keeping logging first-party (rather than `log` or `tracing`) is the
//! same discipline that keeps the dependency list short — `DESIGN.md`
//! §3.2, `docs/dependency-allowlist.md`.

#![forbid(unsafe_code)]

use std::fmt::Arguments;
use std::io::Write;
use std::sync::OnceLock;
use std::sync::atomic::{AtomicU8, Ordering};
use std::time::{Duration, Instant};

/// A log level — [`Error`](Level::Error) is the most severe,
/// [`Trace`](Level::Trace) the least.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
#[repr(u8)]
pub enum Level {
    /// A fault that broke the operation in hand.
    Error = 0,
    /// Something wrong, but the operation carried on.
    Warn = 1,
    /// A normal, noteworthy event.
    Info = 2,
    /// Detail useful when diagnosing a problem.
    Debug = 3,
    /// The finest-grained tracing.
    Trace = 4,
}

impl Level {
    /// The fixed, uppercase label this level wears in a log line.
    pub const fn label(self) -> &'static str {
        match self {
            Self::Error => "ERROR",
            Self::Warn => "WARN",
            Self::Info => "INFO",
            Self::Debug => "DEBUG",
            Self::Trace => "TRACE",
        }
    }

    /// Parse a level name, case-insensitively — the form `ABYSS_LOG` takes.
    pub fn parse(name: &str) -> Option<Self> {
        match name.trim().to_ascii_lowercase().as_str() {
            "error" => Some(Self::Error),
            "warn" => Some(Self::Warn),
            "info" => Some(Self::Info),
            "debug" => Some(Self::Debug),
            "trace" => Some(Self::Trace),
            _ => None,
        }
    }
}

/// The active maximum level as a `Level as u8`, or [`UNSET`] until first
/// resolved from the environment.
static MAX_LEVEL: AtomicU8 = AtomicU8::new(UNSET);

/// `MAX_LEVEL` sentinel: the level has not yet been resolved.
const UNSET: u8 = u8::MAX;

/// The process-start instant, for per-line uptimes — set on first use.
static START: OnceLock<Instant> = OnceLock::new();

/// The active maximum level as a `u8`, resolved from `ABYSS_LOG` (default
/// [`Level::Info`]) the first time it is needed.
fn max_level() -> u8 {
    let current = MAX_LEVEL.load(Ordering::Relaxed);
    if current != UNSET {
        return current;
    }
    // Resolve once from the environment. A race here is benign: every
    // racing caller computes and stores the identical value.
    let resolved = std::env::var("ABYSS_LOG")
        .ok()
        .and_then(|name| Level::parse(&name))
        .unwrap_or(Level::Info) as u8;
    MAX_LEVEL.store(resolved, Ordering::Relaxed);
    resolved
}

/// Set the active maximum level, overriding `ABYSS_LOG` and the default.
pub fn set_level(level: Level) {
    MAX_LEVEL.store(level as u8, Ordering::Relaxed);
}

/// The active maximum level.
pub fn level() -> Level {
    match max_level() {
        0 => Level::Error,
        1 => Level::Warn,
        2 => Level::Info,
        3 => Level::Debug,
        _ => Level::Trace,
    }
}

/// Whether a line at `level` would currently be emitted.
///
/// The logging macros call this before evaluating their arguments, so a
/// silenced `debug!` or `trace!` costs only one atomic load.
pub fn enabled(level: Level) -> bool {
    (level as u8) <= max_level()
}

/// Format one log line — the single, canonical line shape.
fn render(level: Level, target: &str, uptime: Duration, args: Arguments<'_>) -> String {
    format!(
        "[{:>9.3}] {:<5} {target}: {args}",
        uptime.as_secs_f64(),
        level.label(),
    )
}

/// Emit a log line. The level-named macros are the intended interface;
/// this is the shared body they expand into.
#[doc(hidden)]
pub fn log(level: Level, target: &str, args: Arguments<'_>) {
    if !enabled(level) {
        return;
    }
    let uptime = START.get_or_init(Instant::now).elapsed();
    let line = render(level, target, uptime, args);
    // One locked write per line, so concurrent loggers never interleave.
    let mut stderr = std::io::stderr().lock();
    let _ = writeln!(stderr, "{line}");
}

// The five macros are spelled out rather than generated: five near-copies
// of four lines is plainer than a macro that writes macros, and never at
// the mercy of an unstable nested-metavariable feature. Each guards on
// `enabled` *before* `format_args!`, so a silenced call evaluates none of
// its arguments. The line is tagged with the caller's `module_path!()`.

/// Log at [`Level::Error`]. Takes `println!`-style arguments.
#[macro_export]
macro_rules! error {
    ($($arg:tt)*) => {
        if $crate::enabled($crate::Level::Error) {
            $crate::log($crate::Level::Error, module_path!(), format_args!($($arg)*));
        }
    };
}

/// Log at [`Level::Warn`]. Takes `println!`-style arguments.
#[macro_export]
macro_rules! warn {
    ($($arg:tt)*) => {
        if $crate::enabled($crate::Level::Warn) {
            $crate::log($crate::Level::Warn, module_path!(), format_args!($($arg)*));
        }
    };
}

/// Log at [`Level::Info`]. Takes `println!`-style arguments.
#[macro_export]
macro_rules! info {
    ($($arg:tt)*) => {
        if $crate::enabled($crate::Level::Info) {
            $crate::log($crate::Level::Info, module_path!(), format_args!($($arg)*));
        }
    };
}

/// Log at [`Level::Debug`]. Takes `println!`-style arguments.
#[macro_export]
macro_rules! debug {
    ($($arg:tt)*) => {
        if $crate::enabled($crate::Level::Debug) {
            $crate::log($crate::Level::Debug, module_path!(), format_args!($($arg)*));
        }
    };
}

/// Log at [`Level::Trace`]. Takes `println!`-style arguments.
#[macro_export]
macro_rules! trace {
    ($($arg:tt)*) => {
        if $crate::enabled($crate::Level::Trace) {
            $crate::log($crate::Level::Trace, module_path!(), format_args!($($arg)*));
        }
    };
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn levels_are_ordered_by_severity() {
        assert!(Level::Error < Level::Warn);
        assert!(Level::Warn < Level::Info);
        assert!(Level::Info < Level::Debug);
        assert!(Level::Debug < Level::Trace);
    }

    #[test]
    fn parse_is_case_insensitive_and_total() {
        assert_eq!(Level::parse("INFO"), Some(Level::Info));
        assert_eq!(Level::parse(" debug "), Some(Level::Debug));
        assert_eq!(Level::parse("Trace"), Some(Level::Trace));
        assert_eq!(Level::parse("loud"), None);
        assert_eq!(Level::parse(""), None);
    }

    #[test]
    fn labels_are_the_uppercase_names() {
        assert_eq!(Level::Error.label(), "ERROR");
        assert_eq!(Level::Info.label(), "INFO");
        assert_eq!(Level::Trace.label(), "TRACE");
    }

    #[test]
    fn a_rendered_line_has_the_canonical_shape() {
        let line = render(
            Level::Info,
            "abyss_broker::graph",
            Duration::from_millis(1234),
            format_args!("built ({} components)", 3),
        );
        assert_eq!(
            line,
            "[    1.234] INFO  abyss_broker::graph: built (3 components)"
        );

        // ERROR is already five wide, so the column still aligns.
        let err = render(
            Level::Error,
            "abyss_broker",
            Duration::from_secs(0),
            format_args!("no manifest"),
        );
        assert_eq!(err, "[    0.000] ERROR abyss_broker: no manifest");
    }

    /// The level filter and the macros both touch the one global, so they
    /// are exercised in a single test — `cargo test` runs tests in
    /// parallel, and only this test mutates `MAX_LEVEL`.
    #[test]
    fn the_level_filter_and_the_macros() {
        set_level(Level::Warn);
        assert!(enabled(Level::Error));
        assert!(enabled(Level::Warn));
        assert!(!enabled(Level::Info));
        assert!(!enabled(Level::Trace));

        set_level(Level::Trace);
        assert_eq!(level(), Level::Trace);
        assert!(enabled(Level::Trace));

        // The macros expand, evaluate their arguments, and emit without
        // panicking; reaching the end is the assertion.
        error!("an error: {}", 1);
        warn!("a warning");
        info!("info {}", "here");
        debug!("debug");
        trace!("trace");
    }
}
