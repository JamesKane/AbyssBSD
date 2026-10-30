//! What is running, for Activity Monitor (Processes.swift, PHASE15 P15.7).
//!
//! One `sample` reads every process (`kern.proc.proc`, no kvm; /proc on
//! Linux) and the machine's memory; `ProcessTable`, pure, turns two samples
//! into rows (%CPU is CPU time between them over the time between them) and
//! sorts and filters them. A process is the same across two samples only if
//! its pid **and** its start time agree: a pid reused in between is a new
//! process, not an old one that suddenly used a lot of CPU.

use abyss_sys::vents as sys;
use std::collections::HashMap;
use std::time::Instant;

#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct Info {
    pub pid: i32,
    pub ppid: i32,
    pub uid: u32,
    pub threads: i32,
    pub resident_bytes: u64,
    pub virtual_bytes: u64,
    pub cpu_microseconds: u64,
    pub started: i64,
    pub state: char,
    /// A kernel process or thread: shown, never signalled.
    pub system: bool,
    pub name: String,
}

impl Info {
    /// Who this process is across samples: its pid at its start.
    pub fn identity(&self) -> (i32, i64) {
        (self.pid, self.started)
    }
}

#[derive(Clone, Debug)]
pub struct Sample {
    pub processes: Vec<Info>,
    /// Monotonic microseconds when it was taken.
    pub at: u64,
    pub memory_total: u64,
    pub memory_available: u64,
}

/// A fixed origin for `Sample::at`.
fn monotonic_micros() -> u64 {
    static START: std::sync::OnceLock<Instant> = std::sync::OnceLock::new();
    START.get_or_init(Instant::now).elapsed().as_micros() as u64
}

/// Every process now, or None if the system would not say.
pub fn sample() -> Option<Sample> {
    let mut cap = 1024;
    let list = loop {
        let l = sys::proc_list(cap).ok()?;
        if l.len() == cap && cap < 1 << 20 {
            cap *= 4; // more than fitted: again, bigger
            continue;
        }
        break l;
    };
    let (memory_total, memory_available) = sys::memory();
    let processes = list
        .into_iter()
        .map(|p| Info {
            pid: p.pid,
            ppid: p.ppid,
            uid: p.uid,
            threads: p.threads,
            resident_bytes: p.rss_bytes,
            virtual_bytes: p.vsize_bytes,
            cpu_microseconds: p.cpu_usec,
            started: p.start_sec,
            state: p.state as char,
            system: p.system,
            name: p.name,
        })
        .collect();
    Some(Sample { processes, at: monotonic_micros(), memory_total, memory_available })
}

/// The name an account goes by, for the User column; its number if none.
pub fn user_name(uid: u32) -> String {
    sys::user_name(uid).unwrap_or_else(|| uid.to_string())
}

#[derive(Clone, Debug, PartialEq)]
pub struct Row {
    pub info: Info,
    /// Percent of one CPU, as `top` shows it.
    pub cpu_percent: f64,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Column {
    Pid,
    Name,
    User,
    Cpu,
    Threads,
    Memory,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Filter {
    All,
    Mine(u32),
}

/// The rows Activity Monitor shows, from two samples.
#[derive(Clone, Debug, Default)]
pub struct ProcessTable {
    pub rows: Vec<Row>,
}

impl ProcessTable {
    /// The rows for `now`, %CPU measured against `before` (None: zero,
    /// there being nothing yet to measure against).
    pub fn new(now: &Sample, before: Option<&Sample>) -> ProcessTable {
        let previous: HashMap<(i32, i64), u64> = before.map(|b| b.processes.iter().map(|p| (p.identity(), p.cpu_microseconds)).collect()).unwrap_or_default();
        let elapsed = before.map_or(0.0, |b| if now.at > b.at { (now.at - b.at) as f64 } else { 0.0 });
        let rows = now
            .processes
            .iter()
            .map(|p| {
                let cpu = match previous.get(&p.identity()) {
                    Some(&was) if elapsed > 0.0 && p.cpu_microseconds >= was => (p.cpu_microseconds - was) as f64 / elapsed * 100.0,
                    _ => 0.0,
                };
                Row { info: p.clone(), cpu_percent: cpu }
            })
            .collect();
        ProcessTable { rows }
    }

    /// Filtered, then sorted by `column`; ties broken by pid, so the order
    /// does not shuffle between refreshes.
    pub fn view(&self, filter: Filter, column: Column, ascending: bool, user_name: &dyn Fn(u32) -> String) -> Vec<Row> {
        let mut r: Vec<Row> = self.rows.iter().filter(|row| !matches!(filter, Filter::Mine(uid) if row.info.uid != uid)).cloned().collect();
        let key_cmp = |a: &Row, b: &Row| -> std::cmp::Ordering {
            match column {
                Column::Pid => a.info.pid.cmp(&b.info.pid),
                Column::Name => a.info.name.to_lowercase().cmp(&b.info.name.to_lowercase()),
                Column::User => user_name(a.info.uid).cmp(&user_name(b.info.uid)),
                Column::Cpu => a.cpu_percent.partial_cmp(&b.cpu_percent).unwrap_or(std::cmp::Ordering::Equal),
                Column::Threads => a.info.threads.cmp(&b.info.threads),
                Column::Memory => a.info.resident_bytes.cmp(&b.info.resident_bytes),
            }
        };
        r.sort_by(|a, b| {
            let o = key_cmp(a, b);
            let o = if ascending { o } else { o.reverse() };
            o.then(a.info.pid.cmp(&b.info.pid))
        });
        r
    }

    /// "12.5 MB", "1.20 GB", "512 KB": as Activity Monitor writes memory.
    pub fn format_bytes(b: u64) -> String {
        let (k, v) = (1024.0, b as f64);
        if v >= k * k * k {
            format!("{} GB", two_digits(v / (k * k * k)))
        } else if v >= k * k {
            format!("{} MB", one_digit(v / (k * k)))
        } else {
            format!("{} KB", (v / k).round() as i64)
        }
    }

    pub fn format_percent(p: f64) -> String {
        one_digit(p)
    }
}

fn one_digit(v: f64) -> String {
    let t = (v * 10.0).round() as i64;
    format!("{}.{}", t / 10, (t % 10).abs())
}

fn two_digits(v: f64) -> String {
    let t = (v * 100.0).round() as i64;
    format!("{}.{:02}", t / 100, (t % 100).abs())
}
