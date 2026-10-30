//! The probes (Probe.swift).

/// What a probe found. **Three answers, and the third is the point.**
///
/// `Unknown` is not a failure of the probe and it is not "no": it is "this
/// machine did not let me ask", and it must never be rendered as if it were
/// `Absent`. A report that quietly turns "could not tell" into "fine" is
/// worse than no report (PHASE12 §6.1).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum ProbeStatus {
    /// Checked, and it is there.
    Present,
    /// Checked, and it is genuinely not there. An answer, not an error.
    Absent,
    /// Could not be checked. Never a synonym for `Absent`.
    Unknown,
}

impl ProbeStatus {
    pub const ALL: [ProbeStatus; 3] = [ProbeStatus::Present, ProbeStatus::Absent, ProbeStatus::Unknown];

    pub fn as_str(self) -> &'static str {
        match self {
            ProbeStatus::Present => "present",
            ProbeStatus::Absent => "absent",
            ProbeStatus::Unknown => "unknown",
        }
    }
}

/// One line of a report: what was asked, what came back, and what it means.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ProbeResult {
    /// What was probed, for a person reading a list: "GPU", "Network".
    pub name: String,
    pub status: ProbeStatus,
    /// The evidence, in a person's words. Never empty: a result with nothing
    /// to show is one nobody can check.
    pub detail: String,
}

impl ProbeResult {
    pub fn new(name: &str, status: ProbeStatus, detail: impl Into<String>) -> ProbeResult {
        ProbeResult { name: name.to_owned(), status, detail: detail.into() }
    }
}

use ProbeStatus::{Absent, Present, Unknown};

/// Trim ASCII whitespace. CR is whitespace here, so a CRLF capture trims
/// (to Swift, CRLF is one Character and trims as neither).
pub(crate) fn trimmed(s: &str) -> &str {
    s.trim_matches([' ', '\t', '\n', '\r'])
}

/// The words of `s` between single spaces, empty ones dropped.
fn words(s: &str) -> impl Iterator<Item = &str> {
    s.split(' ').filter(|w| !w.is_empty())
}

/// How the machine was started. `machdep.bootmethod` is `UEFI` or `BIOS`.
///
/// **`machdep.bootmethod` is x86's alone.** An arm64 kernel has no such
/// sysctl and FreeBSD/arm64 starts only through UEFI, so on arm64 its
/// absence *is* the answer, not an unknown.
pub fn probe_boot_method(sysctl_value: Option<&str>, arch: Option<&str>) -> ProbeResult {
    let raw = sysctl_value.map(trimmed).unwrap_or("");
    if raw.is_empty() {
        if matches!(arch, Some("aarch64" | "arm64")) {
            return ProbeResult::new("Boot", Present, "UEFI (arm64 starts only through UEFI)");
        }
        return ProbeResult::new("Boot", Unknown, "machdep.bootmethod could not be read");
    }
    match raw.to_uppercase().as_str() {
        "UEFI" => ProbeResult::new("Boot", Present, "UEFI"),
        // BIOS is not a failure: it is a machine that booted the other way.
        "BIOS" => ProbeResult::new("Boot", Present, "BIOS (legacy)"),
        _ => ProbeResult::new("Boot", Unknown, format!("machdep.bootmethod is \"{raw}\"")),
    }
}

/// Whether the kernel gave us a GPU to draw on, from the entries of
/// `/dev/dri`. A **card** node is what a compositor needs; a render node
/// alone is not a display (PHASE4 §5.3).
pub fn probe_gpu(dri_entries: Option<&[&str]>) -> ProbeResult {
    let Some(entries) = dri_entries else {
        return ProbeResult::new("GPU", Unknown, "/dev/dri could not be listed");
    };
    let sorted = |prefix: &str| {
        let mut v: Vec<&str> = entries.iter().copied().filter(|e| e.starts_with(prefix)).collect();
        v.sort_unstable();
        v
    };
    let (cards, render) = (sorted("card"), sorted("renderD"));
    if cards.is_empty() {
        return ProbeResult::new(
            "GPU",
            Absent,
            if render.is_empty() {
                "no /dev/dri/card*: nothing to display on".to_owned()
            } else {
                format!("only {}: a render node is not a display", render.join(", "))
            },
        );
    }
    let extra = if render.is_empty() { String::new() } else { format!(" (+ {})", render.join(", ")) };
    ProbeResult::new("GPU", Present, cards.join(", ") + &extra)
}

/// Which of the graphics modules the kernel loaded, from `kldstat`. Loaded
/// is not bound (`amdgpu` loads harmlessly on a machine it cannot drive), so
/// this says *loaded*, and `probe_gpu` says whether anything came of it.
pub fn probe_modules(kldstat: Option<&str>) -> ProbeResult {
    let Some(text) = kldstat.filter(|t| !trimmed(t).is_empty()) else {
        return ProbeResult::new("Modules", Unknown, "kldstat could not be read");
    };
    // msm: the Qualcomm Adreno's (the Radxa Dragon Q8B's, kmod/drm-msm).
    const WANTED: [&str; 5] = ["amdgpu", "i915kms", "radeonkms", "msm", "drm"];
    let mut found: Vec<&str> = text
        .lines()
        .filter_map(|line| words(line).last()?.strip_suffix(".ko"))
        .filter(|base| WANTED.contains(base))
        .collect();
    if found.is_empty() {
        return ProbeResult::new("Modules", Absent, "no drm driver loaded");
    }
    found.sort_unstable();
    ProbeResult::new("Modules", Present, found.join(", ") + " loaded")
}

/// Network interfaces that are not the loopback, from `ifconfig -l`.
pub fn probe_network(interface_list: Option<&str>) -> ProbeResult {
    let Some(raw) = interface_list else {
        return ProbeResult::new("Network", Unknown, "ifconfig -l could not be read");
    };
    let real: Vec<&str> = words(trimmed(raw)).filter(|i| !i.starts_with("lo")).collect();
    if real.is_empty() {
        return ProbeResult::new("Network", Absent, "only loopback: no network device was recognised");
    }
    ProbeResult::new("Network", Present, real.join(", "))
}

/// Whether any wireless device was recognised, from `net.wlan.devices`:
/// **an empty string, not a missing sysctl**, on a machine with no wifi.
///
/// The sysctl exists only once `wlan` is loaded, and every radio driver
/// needs `wlan`: with the sysctl missing *and* the module not loaded,
/// nothing wireless is attached (the Q8B).
pub fn probe_wifi(wlan_devices: Option<&str>, wlan_loaded: Option<bool>) -> ProbeResult {
    let Some(raw) = wlan_devices else {
        if wlan_loaded == Some(false) {
            return ProbeResult::new("Wi-Fi", Absent, "no wireless: the wlan module is not loaded, so no radio is attached");
        }
        return ProbeResult::new("Wi-Fi", Unknown, "net.wlan.devices could not be read");
    };
    let devs: Vec<&str> = words(trimmed(raw)).collect();
    if devs.is_empty() {
        return ProbeResult::new("Wi-Fi", Absent, "no wireless device recognised");
    }
    ProbeResult::new("Wi-Fi", Present, devs.join(", "))
}

/// Whether there is a sound device. `/dev/sndstat` answers in prose: "No
/// devices installed." is a **sentence the parser has to read**.
pub fn probe_audio(sndstat: Option<&str>) -> ProbeResult {
    let Some(text) = sndstat else {
        return ProbeResult::new("Audio", Unknown, "/dev/sndstat could not be read");
    };
    let devices: Vec<&str> = text
        .lines()
        .map(trimmed)
        // A device line looks like `pcm0: <driver> (play/rec)`.
        .filter(|l| l.starts_with("pcm"))
        .map(|l| l.split(':').next().unwrap_or(l))
        .collect();
    if devices.is_empty() {
        return ProbeResult::new("Audio", Absent, "no sound device installed");
    }
    ProbeResult::new("Audio", Present, devices.join(", "))
}

/// Battery, from `hw.acpi.battery.life`. A desktop has none, and that is
/// `Absent` rather than a fault; a platform that cannot be asked at all is
/// `Unknown`, because "mains only" would be the report inventing something.
pub fn probe_battery(life: Option<i64>, present: bool, can_ask: bool) -> ProbeResult {
    if !can_ask {
        return ProbeResult::new("Power", Unknown, "no way to ask this platform about power");
    }
    if !present {
        return ProbeResult::new("Power", Absent, "no battery, mains only");
    }
    match life {
        Some(pct @ 0..=100) => ProbeResult::new("Power", Present, format!("battery at {pct}%")),
        _ => ProbeResult::new("Power", Unknown, "hw.acpi.battery.life did not answer a percentage"),
    }
}

/// What the machine calls itself, from the kernel environment.
pub fn probe_machine(maker: Option<&str>, product: Option<&str>) -> ProbeResult {
    let mk = maker.map(trimmed).unwrap_or("");
    let pr = product.map(trimmed).unwrap_or("");
    match (mk.is_empty(), pr.is_empty()) {
        (true, true) => ProbeResult::new("Machine", Unknown, "smbios.system.* is not in the kernel environment"),
        // Half an identity is not an identity: say which half is missing.
        (true, false) => ProbeResult::new("Machine", Unknown, format!("product \"{pr}\" with no maker")),
        (false, true) => ProbeResult::new("Machine", Unknown, format!("maker \"{mk}\" with no product")),
        (false, false) => ProbeResult::new("Machine", Present, format!("{mk} {pr}")),
    }
}

/// CPU and memory, which every machine answers.
pub fn probe_cpu(model: Option<&str>, cores: Option<i64>) -> ProbeResult {
    let m = model.map(trimmed).unwrap_or("");
    if m.is_empty() {
        return ProbeResult::new("CPU", Unknown, "hw.model could not be read");
    }
    match cores {
        Some(n) if n > 0 => ProbeResult::new("CPU", Present, format!("{m} ({n} cores)")),
        _ => ProbeResult::new("CPU", Present, m),
    }
}

pub fn probe_memory(phys_bytes: Option<i64>) -> ProbeResult {
    match phys_bytes {
        Some(b) if b > 0 => ProbeResult::new("Memory", Present, crate::report::gib(b as u64)),
        _ => ProbeResult::new("Memory", Unknown, "hw.physmem could not be read"),
    }
}

/// **Is this machine one that needs a MacPro6,1 accommodation?** Its PCIe
/// bridges report a power fault that never clears; on anything else
/// `hw.pci.enable_pcie_hp="0"` is somebody else's workaround in your
/// loader.conf. Maker and model must both match: a VM's smbios strings are
/// settable, and people set them to Apple's models.
pub fn needs_pcie_hotplug_disabled(maker: Option<&str>, product: Option<&str>) -> bool {
    let mk = maker.map(trimmed).unwrap_or("").to_lowercase();
    let pr = product.map(trimmed).unwrap_or("").to_lowercase();
    mk.contains("apple") && pr.starts_with("macpro")
}
