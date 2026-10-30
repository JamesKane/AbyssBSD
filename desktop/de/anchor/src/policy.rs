//! The parts of session supervision that are decisions rather than
//! syscalls (Policy.swift), pure, so they are tested without spawning.

use std::collections::BTreeMap;
use std::sync::OnceLock;
use std::time::Instant;

/// What to do when a supervised component exits: `abyss/session.sh`'s rule.
/// A component that dies comes back, but one that dies *immediately*, over
/// and over, is a broken build. A run that lasted a while clears the streak.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct RestartPolicy {
    /// Give up after this many failures **in a row**.
    pub max_consecutive_failures: u32,
    /// A run at least this long counts as healthy and resets the streak.
    pub healthy_run_seconds: f64,
}

impl Default for RestartPolicy {
    fn default() -> RestartPolicy {
        RestartPolicy { max_consecutive_failures: 5, healthy_run_seconds: 5.0 }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Decision {
    /// Start it again; the streak including this exit.
    Restart(u32),
    /// Stop trying, and tear the session down.
    GiveUp(u32),
}

impl RestartPolicy {
    /// Decide, given how long this run lasted and how many failures preceded it.
    pub fn decide(&self, ran_for: f64, previous_failures: u32) -> Decision {
        // A healthy run wipes the slate; this exit then starts a new streak.
        let failures = if ran_for >= self.healthy_run_seconds { 1 } else { previous_failures + 1 };
        if failures > self.max_consecutive_failures { Decision::GiveUp(failures) } else { Decision::Restart(failures) }
    }
}

/// Monotonic seconds, so a wall-clock change can't make a component look
/// like it ran for -3 seconds.
pub fn monotonic_seconds() -> f64 {
    static START: OnceLock<Instant> = OnceLock::new();
    START.get_or_init(Instant::now).elapsed().as_secs_f64()
}

/// One thing the supervisor starts and keeps alive.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ComponentSpec {
    /// Short name, for logs and the control service's status reply.
    pub name: String,
    /// argv, already resolved: argv[0] absolute, because the child after
    /// fork may not search `$PATH`.
    pub argv: Vec<String>,
    /// Environment entries layered over the session's.
    pub env: BTreeMap<String, String>,
    /// Unix sockets that must **accept a connection** before this starts:
    /// its dependencies, as the one thing about them that can be checked.
    /// Waited on at every start, a restart included.
    pub requires: Vec<String>,
}

impl ComponentSpec {
    pub fn new(name: &str, argv: Vec<String>) -> ComponentSpec {
        ComponentSpec { name: name.to_owned(), argv, env: BTreeMap::new(), requires: vec![] }
    }
}

/// Overrides over a base, as the sorted `KEY=VALUE` list execve takes, so
/// a child's environment is reproducible.
pub fn environment_block(base: &BTreeMap<String, String>, overrides: &BTreeMap<String, String>) -> Vec<String> {
    let mut merged = base.clone();
    merged.extend(overrides.iter().map(|(k, v)| (k.clone(), v.clone())));
    merged.iter().map(|(k, v)| format!("{k}={v}")).collect()
}

/// This process's environment, as a map.
pub fn current_environment() -> BTreeMap<String, String> {
    std::env::vars_os().map(|(k, v)| (k.to_string_lossy().into_owned(), v.to_string_lossy().into_owned())).collect()
}

/// A command split at whitespace, and nothing else interpreted: a command
/// with a space inside one argument needs the argv form (HANDOFF §2.25).
pub fn split_command(s: &str) -> Vec<String> {
    s.split([' ', '\t']).filter(|w| !w.is_empty()).map(str::to_owned).collect()
}
