// Fathom — what this machine is, as a value (PHASE12.md P12.1).
//
// [PHASE4 §5](../docs/PHASE4.md) is a six-step bring-up checklist that exists
// because a person works down it by hand on the one machine we own. This is that
// checklist as a program, which is what lets it run on the machines we do not.
//
// **Everything here is a pure function over captured text.** Nothing in this file
// runs a command, opens a device or reads a sysctl: a caller gathers, these
// interpret. That is `Probe.swift`'s pattern from the installer and it earns the
// same thing — every probe is testable on a machine that has none of the
// hardware, which is most of them.
//
// **And the discipline is §2.37, stated as a rule about the type below:** a probe
// with no positive control measures nothing, and a probe suite that cannot say
// "no" is a suite that says "fine". Every parser here is written against the
// build VM's *absent* case first — no `/dev/dri`, an empty `net.wlan.devices`, an
// unknown battery oid, a `/dev/sndstat` that says so in a sentence.

/// What a probe found. **Three answers, and the third is the point.**
///
/// `unknown` is not a failure of the probe and it is not "no" — it is "this
/// machine did not let me ask", and it must never be rendered as if it were
/// `absent`. The failure mode this guards against is not a wrong answer, it is a
/// confident one: a report that quietly turns "could not tell" into "fine" is
/// worse than no report, because it converts an obvious gap into a claim
/// (PHASE12 §6.1).
public enum ProbeStatus: String, Sendable, Equatable, CaseIterable {
    /// Checked, and it is there.
    case present
    /// Checked, and it is genuinely not there. An answer, not an error.
    case absent
    /// Could not be checked. Never a synonym for `absent`.
    case unknown
}

/// One line of a report: what was asked, what came back, and what it means.
public struct ProbeResult: Equatable, Sendable {
    /// What was probed, for a person reading a list: "GPU", "Network".
    public let name: String
    public let status: ProbeStatus
    /// The evidence, in a person's words — a mode, a device name, a reason.
    /// Never empty: a result with nothing to show is one nobody can check.
    public let detail: String

    public init(_ name: String, _ status: ProbeStatus, _ detail: String) {
        self.name = name
        self.status = status
        self.detail = detail
    }
}

// MARK: - Small helpers, kept here so the parsers stay one idea each

/// Trim ASCII whitespace. `Foundation` is not a dependency of this target and
/// two calls do not justify making it one.
func trimmed(_ s: some StringProtocol) -> String {
    var v = Substring(String(s))
    while let c = v.first, c == " " || c == "\t" || c == "\n" || c == "\r" { v = v.dropFirst() }
    while let c = v.last, c == " " || c == "\t" || c == "\n" || c == "\r" { v = v.dropLast() }
    return String(v)
}

// MARK: - The probes

/// How the machine was started. `machdep.bootmethod` is `UEFI` or `BIOS`.
///
/// **Both cases are exercised by the harness**, which is unusual and worth
/// keeping: the build VM boots BIOS, and the nested bhyve run in
/// `live-medium.sh` boots UEFI off `edk2-bhyve`.
public func probeBootMethod(_ sysctlValue: String?) -> ProbeResult {
    guard let raw = sysctlValue.map(trimmed), !raw.isEmpty else {
        return ProbeResult("Boot", .unknown, "machdep.bootmethod could not be read")
    }
    switch raw.uppercased() {
    case "UEFI": return ProbeResult("Boot", .present, "UEFI")
    // BIOS is not a failure — it is a machine that booted the other way, and an
    // installer that called it `absent` would be calling a working machine
    // broken.
    case "BIOS": return ProbeResult("Boot", .present, "BIOS (legacy)")
    default:     return ProbeResult("Boot", .unknown, "machdep.bootmethod is \"\(raw)\"")
    }
}

/// Whether the kernel gave us a GPU to draw on.
///
/// `entries` is the contents of `/dev/dri`. A **card** node is what a compositor
/// needs; a render node alone is not a display. The distinction matters because
/// the first metal boot had both and still could not render (PHASE4 §5.3).
public func probeGPU(driEntries: [String]?) -> ProbeResult {
    guard let entries = driEntries else {
        return ProbeResult("GPU", .unknown, "/dev/dri could not be listed")
    }
    let cards = entries.filter { $0.hasPrefix("card") }.sorted()
    let render = entries.filter { $0.hasPrefix("renderD") }.sorted()
    guard !cards.isEmpty else {
        return ProbeResult("GPU", .absent,
                           render.isEmpty ? "no /dev/dri/card*: nothing to display on"
                                          : "only \(render.joined(separator: ", ")): a render node is not a display")
    }
    let extra = render.isEmpty ? "" : " (+ \(render.joined(separator: ", ")))"
    return ProbeResult("GPU", .present, cards.joined(separator: ", ") + extra)
}

/// Which of the graphics modules the kernel actually bound, from `kldstat`.
///
/// Loaded is not bound — `amdgpu` loads harmlessly on a machine it cannot drive,
/// which P4.3 measured deliberately — so this reports what is *loaded* and says
/// so, and `probeGPU` is what says whether anything came of it.
public func probeModules(kldstat: String?) -> ProbeResult {
    guard let text = kldstat, !trimmed(text).isEmpty else {
        return ProbeResult("Modules", .unknown, "kldstat could not be read")
    }
    let wanted = ["amdgpu", "i915kms", "radeonkms", "drm"]
    var found: [String] = []
    for line in text.split(separator: "\n") {
        guard let last = line.split(separator: " ").last else { continue }
        let mod = String(last)
        guard mod.hasSuffix(".ko") else { continue }
        let base = String(mod.dropLast(3))
        if wanted.contains(base) { found.append(base) }
    }
    guard !found.isEmpty else {
        return ProbeResult("Modules", .absent, "no drm driver loaded")
    }
    return ProbeResult("Modules", .present, found.sorted().joined(separator: ", ") + " loaded")
}

/// Network interfaces that are not the loopback.
///
/// `ifconfig -l` is a single line of names. Thesis 5's hardest promise, and the
/// probe most likely to say `absent` on a laptop.
public func probeNetwork(interfaceList: String?) -> ProbeResult {
    guard let raw = interfaceList else {
        return ProbeResult("Network", .unknown, "ifconfig -l could not be read")
    }
    let all = trimmed(raw).split(separator: " ").map(String.init)
    let real = all.filter { $0 != "lo0" && !$0.hasPrefix("lo") }
    guard !real.isEmpty else {
        return ProbeResult("Network", .absent, "only loopback: no network device was recognised")
    }
    return ProbeResult("Network", .present, real.joined(separator: ", "))
}

/// Whether any wireless device was recognised.
///
/// `net.wlan.devices` is **an empty string, not a missing sysctl**, on a machine
/// with no wifi — so the absent case is a value to parse rather than a lookup
/// that fails, and the parser is exercised rather than skipped.
public func probeWifi(wlanDevices: String?) -> ProbeResult {
    guard let raw = wlanDevices else {
        return ProbeResult("Wi-Fi", .unknown, "net.wlan.devices could not be read")
    }
    let devs = trimmed(raw).split(separator: " ").map(String.init).filter { !$0.isEmpty }
    guard !devs.isEmpty else {
        return ProbeResult("Wi-Fi", .absent, "no wireless device recognised")
    }
    return ProbeResult("Wi-Fi", .present, devs.joined(separator: ", "))
}

/// Whether there is a sound device.
///
/// `/dev/sndstat` answers in prose. On a machine with no audio it says
/// "No devices installed." — which is a **sentence the parser has to read**, not
/// a file that is missing, so this probe's negative case exercises real code.
public func probeAudio(sndstat: String?) -> ProbeResult {
    guard let text = sndstat else {
        return ProbeResult("Audio", .unknown, "/dev/sndstat could not be read")
    }
    var devices: [String] = []
    for line in text.split(separator: "\n") {
        let l = trimmed(line)
        if l.isEmpty { continue }
        if l.hasPrefix("No devices installed") { continue }
        if l.hasPrefix("Installed devices") { continue }
        if l.hasPrefix("Default audio device") { continue }
        // A device line looks like `pcm0: <driver> (play/rec)`.
        if l.hasPrefix("pcm") { devices.append(String(l.prefix(while: { $0 != ":" }))) }
    }
    guard !devices.isEmpty else {
        return ProbeResult("Audio", .absent, "no sound device installed")
    }
    return ProbeResult("Audio", .present, devices.joined(separator: ", "))
}

/// Battery, from `hw.acpi.battery.life`.
///
/// A desktop has none, and that is `absent` rather than a fault: this probe
/// distinguishes "no battery in this machine" from "could not ask".
public func probeBattery(life: Int64?, present: Bool, canAsk: Bool = true) -> ProbeResult {
    // **"No battery" and "cannot ask about batteries" are different machines**,
    // and only one of them is a fact about hardware. A platform with no sysctl
    // answers nil to everything; calling that "mains only" would be the report
    // inventing something it never looked at.
    guard canAsk else {
        return ProbeResult("Power", .unknown, "no way to ask this platform about power")
    }
    guard present else {
        return ProbeResult("Power", .absent, "no battery, mains only")
    }
    guard let pct = life, pct >= 0, pct <= 100 else {
        return ProbeResult("Power", .unknown, "hw.acpi.battery.life did not answer a percentage")
    }
    return ProbeResult("Power", .present, "battery at \(pct)%")
}

/// What the machine calls itself, from the kernel environment.
///
/// The probe that lets a Mac Pro's loader tunable stop being written to every
/// machine (PHASE4 §5.2).
public func probeMachine(maker: String?, product: String?) -> ProbeResult {
    let mk = maker.map(trimmed) ?? ""
    let pr = product.map(trimmed) ?? ""
    guard !mk.isEmpty || !pr.isEmpty else {
        return ProbeResult("Machine", .unknown, "smbios.system.* is not in the kernel environment")
    }
    guard !mk.isEmpty, !pr.isEmpty else {
        // Half an identity is not an identity — say which half is missing rather
        // than reporting the other as though it were the answer.
        return ProbeResult("Machine", .unknown,
                           mk.isEmpty ? "product \"\(pr)\" with no maker" : "maker \"\(mk)\" with no product")
    }
    return ProbeResult("Machine", .present, "\(mk) \(pr)")
}

/// CPU and memory, which every machine answers.
public func probeCPU(model: String?, cores: Int64?) -> ProbeResult {
    guard let m = model.map(trimmed), !m.isEmpty else {
        return ProbeResult("CPU", .unknown, "hw.model could not be read")
    }
    guard let n = cores, n > 0 else { return ProbeResult("CPU", .present, m) }
    return ProbeResult("CPU", .present, "\(m) (\(n) cores)")
}

public func probeMemory(physBytes: Int64?) -> ProbeResult {
    guard let b = physBytes, b > 0 else {
        return ProbeResult("Memory", .unknown, "hw.physmem could not be read")
    }
    // Whole GiB with one decimal, because the number is for a person.
    let tenths = (b * 10) / (1024 * 1024 * 1024)
    return ProbeResult("Memory", .present, "\(tenths / 10).\(tenths % 10) GiB")
}

/// **Is this machine one that needs a MacPro6,1 accommodation?**
///
/// `hw.pci.enable_pcie_hp="0"` is written to every medium and every installed
/// system today, because nothing could ask what machine it was on. Its PCIe
/// bridges report a power fault that never clears; on anything else the tunable
/// is inert but it is still somebody else's workaround in your loader.conf.
///
/// Pure, so the rule is testable without a Mac Pro — which is the only way it
/// could be tested at all, since we no longer bring up on one.
public func needsPCIeHotplugDisabled(maker: String?, product: String?) -> Bool {
    let mk = (maker.map(trimmed) ?? "").lowercased()
    let pr = (product.map(trimmed) ?? "").lowercased()
    // Apple's own machines of that era. Matched on the model prefix rather than
    // the exact string, because MacPro6,1 is the one we know and the bridges are
    // Apple's, not that model's alone.
    guard mk.contains("apple") else { return false }
    return pr.hasPrefix("macpro")
}
