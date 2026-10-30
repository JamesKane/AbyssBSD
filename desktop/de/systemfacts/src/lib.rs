//! SystemFacts in Rust (RUST.md R2): what this computer is, as fastfetch
//! reports it, for System Profiler; ported from SystemFacts.swift beside it.
//!
//! fastfetch's list, in Aqua: the OS, kernel, uptime, packages, shell,
//! desktop, theme and terminal; the machine, CPU, GPU, memory, swap, disk,
//! displays, address and battery. **Pure**: every function takes text or
//! numbers the gatherer captured, so each is tested on a machine that has
//! none of the hardware (the Fathom rule, PHASE12 §1).
//!
//! **A fact the machine would not give is shown as unknown, never
//! guessed.** And every reading has a fallback that works where the first
//! does not: SMBIOS for a PC's maker, the device tree's `model` for a
//! board; `pciconf` for a PC's GPU, the bound DRM driver for an SoC's.

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Section {
    Software,
    Hardware,
}

impl Section {
    pub fn as_str(self) -> &'static str {
        match self {
            Section::Software => "Software",
            Section::Hardware => "Hardware",
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Fact {
    pub section: Section,
    pub label: String,
    /// None: the machine would not say.
    pub value: Option<String>,
}

impl Fact {
    pub fn new(section: Section, label: &str, value: Option<&str>) -> Fact {
        Fact { section, label: label.to_owned(), value: value.map(str::to_owned) }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SystemFacts {
    /// `user@host`, fastfetch's title.
    pub title: String,
    pub facts: Vec<Fact>,
}

impl SystemFacts {
    pub fn value(&self, label: &str) -> Option<&str> {
        self.facts.iter().find(|f| f.label == label).and_then(|f| f.value.as_deref())
    }

    /// The report as text, fastfetch's shape: the title, a rule, and one
    /// `Label: value` per line: what Copy puts on the clipboard.
    pub fn text(&self) -> String {
        let mut out = format!("{}\n{}\n", self.title, "-".repeat(self.title.chars().count()));
        for f in &self.facts {
            out += &format!("{}: {}\n", f.label, f.value.as_deref().unwrap_or("unknown"));
        }
        out
    }

    /// For a golden and the live test's fallback: a fixed machine.
    pub fn sample() -> SystemFacts {
        use Section::{Hardware, Software};
        let f = |s, l, v| Fact::new(s, l, Some(v));
        SystemFacts {
            title: "ada@jaguar".into(),
            facts: vec![
                f(Software, "OS", "AbyssBSD on FreeBSD 16.0-CURRENT aarch64"),
                f(Software, "Kernel", "FreeBSD 16.0-CURRENT"),
                f(Software, "Uptime", "2 days, 3 hours, 14 mins"),
                f(Software, "Packages", "412 (pkg)"),
                f(Software, "Shell", "sh"),
                f(Software, "Desktop", "AbyssBSD Aqua"),
                f(Software, "Window Manager", "undertow"),
                f(Software, "Theme", "Jaguar"),
                f(Software, "Terminal", "Terminal"),
                f(Software, "Locale", "en_US.UTF-8"),
                // The Radxa Dragon Q8B, as its own fathom report reads it.
                f(Hardware, "Host", "Radxa Computer Co., Ltd. Radxa Dragon Q8B"),
                f(Hardware, "CPU", "ARM Cortex-A78C r0p0 (8)"),
                f(Hardware, "GPU", "Qualcomm Adreno (msm)"),
                f(Hardware, "Memory", "3.12 GiB / 15.47 GiB (20%)"),
                f(Hardware, "Swap", "0 B / 2.00 GiB (0%)"),
                f(Hardware, "Disk (/)", "18.40 GiB / 112.30 GiB (16%) - zfs"),
                f(Hardware, "Display", "DP-1 1920×1080 @ 60 Hz"),
                f(Hardware, "Local IP", "192.168.1.40/24 (tcx0)"),
                Fact::new(Hardware, "Battery", None),
            ],
        }
    }
}

// MARK: formatting

pub mod format {
    /// fastfetch's binary units: "3.12 GiB", "512.00 MiB", "0 B".
    pub fn bytes(b: u64) -> String {
        const UNITS: [&str; 5] = ["B", "KiB", "MiB", "GiB", "TiB"];
        let (mut v, mut i) = (b as f64, 0);
        while v >= 1024.0 && i < UNITS.len() - 1 {
            v /= 1024.0;
            i += 1;
        }
        if i == 0 {
            return format!("{b} B");
        }
        format!("{} {}", two_places(v), UNITS[i])
    }

    pub(crate) fn two_places(v: f64) -> String {
        let hundredths = (v * 100.0).round() as i64;
        format!("{}.{:02}", hundredths / 100, hundredths % 100)
    }

    /// "used / total (pct%)", fastfetch's usage line.
    pub fn usage(used: u64, total: u64) -> String {
        let pct = if total == 0 { 0 } else { (used as f64 * 100.0 / total as f64).round() as i64 };
        format!("{} / {} ({pct}%)", bytes(used), bytes(total))
    }

    /// "2 days, 3 hours, 14 mins" from seconds: fastfetch's uptime.
    pub fn uptime(seconds: i64) -> String {
        if seconds < 0 {
            return "0 mins".into();
        }
        let (d, h, m) = (seconds / 86400, seconds % 86400 / 3600, seconds % 3600 / 60);
        let unit = |n: i64, what: &str| format!("{n} {what}{}", if n == 1 { "" } else { "s" });
        let mut parts = vec![];
        if d > 0 {
            parts.push(unit(d, "day"));
        }
        if h > 0 {
            parts.push(unit(h, "hour"));
        }
        if m > 0 || parts.is_empty() {
            parts.push(unit(m, "min"));
        }
        parts.join(", ")
    }

    /// "2.71 GHz" from MHz; under a GHz, "800 MHz".
    pub fn frequency(mhz: i64) -> String {
        if mhz >= 1000 { format!("{} GHz", two_places(mhz as f64 / 1000.0)) } else { format!("{mhz} MHz") }
    }
}

// MARK: parsers (each takes what a command or sysctl said)

pub mod parse {
    use crate::trimmed;

    /// The display devices in `pciconf -lv`: each display device's `vendor`
    /// and `device` strings ("AMD Navi 22 [Radeon RX 6750 XT]"), or, for one
    /// the database does not know (QEMU's VGA), its ids rather than nothing.
    pub fn pci_displays(text: &str) -> Vec<String> {
        let mut out = vec![];
        let (mut vendor, mut device, mut is_display, mut ids): (Option<String>, Option<String>, bool, String) = (None, None, false, String::new());
        let mut flush = |vendor: &mut Option<String>, device: &mut Option<String>, is_display: &mut bool, ids: &mut String| {
            if *is_display {
                if let Some(d) = device.as_deref() {
                    let v = vendor.as_deref().map(short_vendor).unwrap_or_default();
                    out.push(if v.is_empty() { d.to_owned() } else { format!("{v} {d}") });
                } else if !ids.is_empty() {
                    out.push(format!("PCI display {ids}"));
                }
            }
            (*vendor, *device, *is_display) = (None, None, false);
            ids.clear();
        };
        for raw in text.split('\n') {
            let line = raw.strip_suffix('\r').unwrap_or(raw);
            if !line.starts_with([' ', '\t']) && line.contains("@pci") {
                flush(&mut vendor, &mut device, &mut is_display, &mut ids);
                is_display = line.starts_with("vgapci");
                let field = |name: &str| line.split([' ', '\t']).find_map(|w| w.strip_prefix(name));
                if let (Some(v), Some(d)) = (field("vendor="), field("device=")) {
                    ids = format!("{v}:{d}");
                }
                continue;
            }
            let t = trimmed(line);
            if t.starts_with("vendor") {
                vendor = quoted(t).map(str::to_owned);
            } else if t.starts_with("device") {
                device = quoted(t).map(str::to_owned);
            } else if t.starts_with("class") && t.contains("display") {
                is_display = true;
            }
        }
        flush(&mut vendor, &mut device, &mut is_display, &mut ids);
        out
    }

    /// "Advanced Micro Devices, Inc. [AMD/ATI]" is "AMD"; "Intel
    /// Corporation" is "Intel".
    pub(crate) fn short_vendor(v: &str) -> String {
        if v.contains("AMD") || v.contains("Advanced Micro") {
            "AMD"
        } else if v.starts_with("Intel") {
            "Intel"
        } else if v.starts_with("NVIDIA") {
            "NVIDIA"
        } else if v.contains("Red Hat") || v.contains("QEMU") {
            "QEMU"
        } else {
            v.split(' ').find(|w| !w.is_empty()).unwrap_or(v)
        }
        .to_owned()
    }

    /// The text between the first and last `'`.
    pub(crate) fn quoted(s: &str) -> Option<&str> {
        let (a, b) = (s.find('\'')?, s.rfind('\'')?);
        (a < b).then(|| &s[a + 1..b])
    }

    /// The bound DRM driver, for a machine whose GPU is not a PCI device
    /// (an SoC's): from `kldstat`'s module names.
    pub fn drm_driver(kldstat: &str) -> Option<&'static str> {
        [
            ("msm.ko", "Qualcomm Adreno (msm)"),
            ("amdgpu.ko", "AMD Radeon (amdgpu)"),
            ("i915kms.ko", "Intel (i915)"),
            ("radeonkms.ko", "AMD Radeon (radeon)"),
            ("panfrost.ko", "Arm Mali (panfrost)"),
        ]
        .into_iter()
        .find(|(k, _)| kldstat.contains(k))
        .map(|(_, n)| n)
    }

    /// `swapinfo -k`: used and total, in bytes: the `Total` line when there
    /// are several devices, else the one; None with no swap configured, or
    /// a count too big to be bytes (where Swift traps).
    pub fn swap(swapinfo: &str) -> Option<(u64, u64)> {
        let lines: Vec<&str> = swapinfo.split('\n').filter(|l| !l.is_empty() && !l.starts_with("Device")).collect();
        let line = lines.iter().find(|l| l.starts_with("Total")).or((lines.len() == 1).then(|| &lines[0]))?;
        let f: Vec<&str> = line.split([' ', '\t']).filter(|w| !w.is_empty()).collect();
        let (total, used): (u64, u64) = (f.get(1)?.parse().ok()?, f.get(2)?.parse().ok()?);
        Some((used.checked_mul(1024)?, total.checked_mul(1024)?))
    }

    /// A device tree's `model`, from `ofwdump -P model -R /`: the board's
    /// name where there is no SMBIOS.
    pub fn ofw_model(text: &str) -> Option<&str> {
        text.split('\n').filter_map(|l| quoted(trimmed(l))).find(|q| !q.is_empty())
    }

    /// `kern.boottime` as the bytes of a `struct timeval`: its seconds.
    pub fn boot_seconds(timeval: &[u8]) -> Option<i64> {
        Some(i64::from_ne_bytes(timeval.get(..8)?.try_into().ok()?))
    }

    /// Memory in use the way fastfetch counts it on FreeBSD: every page that
    /// is neither free nor inactive (nor in the laundry). Saturating, where
    /// Swift's sums trap.
    pub fn memory_used(page_size: u64, pages: u64, free: u64, inactive: u64, laundry: u64) -> u64 {
        let idle = free.saturating_add(inactive).saturating_add(laundry);
        if idle >= pages { 0 } else { (pages - idle).saturating_mul(page_size) }
    }
}

/// Spaces and tabs off the front; spaces, tabs and CRs off the end.
pub fn trimmed(s: &str) -> &str {
    s.trim_start_matches([' ', '\t']).trim_end_matches([' ', '\t', '\r'])
}

#[cfg(test)]
mod tests;
