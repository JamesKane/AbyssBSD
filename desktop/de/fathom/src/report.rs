//! The report, as a value (Report.swift, PHASE12 P12.3).
//!
//! **Rendered, never printed**: a value can be asserted on, diffed, saved
//! and sent. **And what is in it is a decision** (§6.2): the report is meant
//! to be sent to us, so every probe reports a *kind* of hardware and none
//! reports *which* machine. In: maker and model, CPU, memory, GPU nodes,
//! modules, interface names, audio devices, battery presence, disk models
//! and sizes. Out: serials, MAC and IP addresses, hostname, pool names,
//! mount points, user names.

use crate::probe::{trimmed, ProbeResult, ProbeStatus};
use std::collections::HashMap;

/// One disk, as much of it as a *hardware* report may say. Deliberately not
/// `install::Disk`, which carries mounts and pool names because a refusal
/// needs them; neither belongs in a file that gets e-mailed to strangers.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DiskFact {
    pub name: String,
    pub bytes: u64,
    pub model: String,
}

/// What this machine is, and whether the desktop can run on it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct FathomReport {
    pub results: Vec<ProbeResult>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Counts {
    pub present: usize,
    pub absent: usize,
    pub unknown: usize,
}

impl FathomReport {
    pub fn new(results: Vec<ProbeResult>) -> FathomReport {
        FathomReport { results }
    }

    pub fn counts(&self) -> Counts {
        let n = |s| self.results.iter().filter(|r| r.status == s).count();
        Counts { present: n(ProbeStatus::Present), absent: n(ProbeStatus::Absent), unknown: n(ProbeStatus::Unknown) }
    }

    /// True when nothing could not be asked. **Not "this machine is fine"**:
    /// a report full of honest absences is complete and still describes a
    /// machine that cannot show a desktop (§6.4).
    pub fn is_complete(&self) -> bool {
        self.counts().unknown == 0
    }
}

/// Bytes as whole GiB with one decimal, for a person.
pub(crate) fn gib(bytes: u64) -> String {
    let tenths = u128::from(bytes) * 10 / (1 << 30);
    format!("{}.{} GiB", tenths / 10, tenths % 10)
}

/// The disks, as hardware rather than as somewhere to install.
pub fn probe_disks(disks: &[DiskFact]) -> ProbeResult {
    if disks.is_empty() {
        return ProbeResult::new("Disks", ProbeStatus::Absent, "no disks found: there is nowhere to install");
    }
    let parts: Vec<String> = disks
        .iter()
        .map(|d| if d.model.is_empty() { format!("{} {}", d.name, gib(d.bytes)) } else { format!("{} {} ({})", d.name, gib(d.bytes), d.model) })
        .collect();
    ProbeResult::new("Disks", ProbeStatus::Present, parts.join("; "))
}

// MARK: the console rendering

/// The report as plain text, for a console: **the machine that most needs
/// it is the one that cannot draw one.** ASCII only, no colour, one line per
/// probe, nothing wider than 80 columns. `unknown` is spelt differently from
/// `absent` on purpose, and named in the summary (§6.1).
pub fn render_text(report: &FathomReport, title: &str) -> String {
    let mut out = format!("{}: what this machine is\n{}\n", ascii_only(title), "=".repeat(40));
    let width = report.results.iter().map(|r| r.name.chars().count()).max().unwrap_or(0);
    for r in &report.results {
        let pad = " ".repeat(width - r.name.chars().count());
        out += &format!("{}{pad}  {}  {}\n", r.name, mark(r.status), ascii_only(&r.detail));
    }
    let c = report.counts();
    out += &format!("{}\n{} present, {} absent", "-".repeat(40), c.present, c.absent);
    if c.unknown > 0 {
        out += &format!(", {} COULD NOT BE ASKED", c.unknown);
    }
    out + "\n"
}

/// Fold a string to ASCII, so a console renders it rather than mangling it:
/// folded where there is an obvious equivalent, dropped where there is not.
/// By character, so a combining accent goes and its letter stays (Swift
/// drops the whole grapheme).
pub fn ascii_only(s: &str) -> String {
    let mut out = String::new();
    for c in s.chars() {
        match c {
            '\u{2014}' | '\u{2013}' => out.push('-'),
            '\u{2018}' | '\u{2019}' => out.push('\''),
            '\u{201C}' | '\u{201D}' => out.push('"'),
            '\u{2026}' => out.push_str("..."),
            c if c.is_ascii() => out.push(c),
            _ => {}
        }
    }
    out
}

/// The mark for a status, all one width, so a column reads as a shape.
pub(crate) fn mark(s: ProbeStatus) -> &'static str {
    match s {
        ProbeStatus::Present => "[ok]",
        ProbeStatus::Absent => "[--]",
        ProbeStatus::Unknown => "[??]",
    }
}

// MARK: the measurement

/// The frame contract, from `undertow run`'s own key=value output.
///
/// **It reports numbers and refuses a verdict** (§6.4): a pass/fail would be
/// calibrated on whatever machine was convenient. **And it carries the
/// clock**: a duration against a synthetic grid or somebody else's vblank is
/// not a hardware measurement, and says so in the same breath (§2.48).
pub fn probe_frame_contract(run_output: Option<&str>) -> ProbeResult {
    const NAME: &str = "Frame contract";
    let Some(text) = run_output.filter(|t| !t.is_empty()) else {
        return ProbeResult::new(NAME, ProbeStatus::Unknown, "undertow did not report");
    };
    let mut fields: HashMap<&str, &str> = HashMap::new();
    for line in text.lines() {
        if let Some((k, v)) = line.split_once('=')
            && !k.is_empty()
            && !v.is_empty()
        {
            fields.insert(trimmed(k), trimmed(v));
        }
    }
    // `missed=45 of 300`
    let Some(missed_raw) = fields.get("missed") else {
        return ProbeResult::new(NAME, ProbeStatus::Unknown, "undertow reported no frame counts");
    };
    let bits: Vec<&str> = missed_raw.split(' ').filter(|b| !b.is_empty()).collect();
    let (Some(missed), Some(total)) = (bits.first().and_then(|b| b.parse::<i64>().ok()), bits.get(2).and_then(|b| b.parse::<i64>().ok()))
    else {
        return ProbeResult::new(NAME, ProbeStatus::Unknown, format!("could not read a frame count from \"{missed_raw}\""));
    };
    if total <= 0 {
        // The compositor ran and presented nothing: an answer about the
        // machine, and every rate below would be a division by zero.
        return ProbeResult::new(NAME, ProbeStatus::Absent, "no frames were presented");
    }
    let permille = i128::from(missed) * 1000 / i128::from(total);
    let mut detail = format!("{missed} of {total} missed ({permille} per mille)");
    if let Some(cost) = fields.get("composite-p99-us") {
        detail += &format!(", composite p99 {cost}us");
    }
    if let Some(period) = fields.get("period-us") {
        detail += &format!(", period {period}us");
    }
    // **When frames are being missed, say which term is eating them**, and
    // whether the control loop has hit its ceiling.
    if missed > 0 {
        let terms = [
            ("waking late", "margin-wake-us"),
            ("compositing", "margin-cost-us"),
            ("display commit", "margin-commit-us"),
            ("vblank prediction", "margin-vblank-us"),
            ("unattributed", "margin-safety-us"),
        ];
        // The first of equal largest, as Swift's `max(by:)` keeps it.
        let worst = terms
            .iter()
            .filter_map(|(name, key)| Some((*name, fields.get(key)?.parse::<i64>().ok()?)))
            .fold(None, |best: Option<(&str, i64)>, t| match best {
                Some(b) if b.1 >= t.1 => Some(b),
                _ => Some(t),
            });
        if let Some((name, us)) = worst
            && us > 0
        {
            detail += &format!("; margin dominated by {name} ({us}us)");
        }
        if fields.get("margin-pinned") == Some(&"yes") {
            detail += "; MARGIN PINNED AT ITS CEILING, the loop cannot compensate further";
        }
    }
    // **Whose clock, and not merely whether one was seen**: a nested
    // compositor passes its host's real timestamps through.
    let hardware = fields.get("vblank-source") == Some(&"hardware");
    detail += match fields.get("backend").copied() {
        Some("drm") if hardware => " [hardware clock, DRM]",
        Some("drm") => " [DRM but NO hardware clock: treat as provisional]",
        Some("nested-wayland" | "nested-x11") => " [NESTED: measured against the host's clock, NOT APPLICABLE]",
        Some("headless") => " [HEADLESS: a synthetic grid, not a hardware measurement]",
        // A build that predates the label: saying nothing would let it read
        // as a hardware measurement.
        _ if hardware => " [clock hardware, backend unstated]",
        _ => " [clock and backend unstated]",
    };
    ProbeResult::new(NAME, ProbeStatus::Present, detail)
}

// MARK: getting it off the machine

/// The filename a report is saved under on the medium's ESP (FAT, which
/// everything reads). **It names the machine and not the person**: maker
/// and model, lowercase ASCII, digits and hyphens.
pub fn report_filename(maker: Option<&str>, product: Option<&str>) -> String {
    fn slug(s: Option<&str>) -> String {
        let mut out = String::new();
        for c in s.unwrap_or("").to_lowercase().chars() {
            if c.is_ascii_alphanumeric() {
                out.push(c);
            } else if !out.is_empty() && !out.ends_with('-') {
                out.push('-');
            }
        }
        out.trim_end_matches('-').to_owned()
    }
    let parts: Vec<String> = [slug(maker), slug(product)].into_iter().filter(|p| !p.is_empty()).collect();
    if parts.is_empty() {
        return "fathom-unknown.txt".to_owned();
    }
    let name = parts.join("-");
    format!("fathom-{}.txt", &name[..name.len().min(48)])
}
