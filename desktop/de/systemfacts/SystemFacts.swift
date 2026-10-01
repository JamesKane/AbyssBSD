// SystemFacts — what this computer is, as fastfetch reports it (System
// Profiler).
//
// fastfetch's list, in Aqua: the OS, kernel, uptime, packages, shell,
// desktop, theme and terminal; the machine, CPU, GPU, memory, swap, disk,
// displays, address and battery. **Pure**: every function here takes text or
// numbers the gatherer captured, so each is tested on a machine that has
// none of the hardware — the Fathom rule (PHASE12 §1).
//
// **A fact the machine would not give is shown as unknown, never guessed.** A
// row whose value is nil says so; it is not left out, and it is not filled
// with something plausible (PHASE12's rule, one level up).
//
// Architecture-neutral by construction: every reading has a fallback that
// works where the first does not — SMBIOS for a PC's maker, the device tree's
// `model` for a board booted with one; `pciconf` for a PC's GPU, the bound DRM
// driver for an SoC's, which has no PCI display device at all.

public struct Fact: Equatable, Sendable {
    public enum Section: String, Sendable, CaseIterable { case software = "Software", hardware = "Hardware" }
    public let section: Section
    public let label: String
    /// Nil: the machine would not say.
    public let value: String?
    public init(_ section: Section, _ label: String, _ value: String?) {
        self.section = section; self.label = label; self.value = value
    }
}

public struct SystemFacts: Equatable, Sendable {
    /// `user@host`, fastfetch's title.
    public var title: String
    public var facts: [Fact]
    public init(title: String, facts: [Fact]) { self.title = title; self.facts = facts }

    public func value(_ label: String) -> String? { facts.first { $0.label == label }?.value }

    /// The report as text, fastfetch's shape: the title, a rule, and one
    /// `Label: value` per line — what Copy puts on the clipboard.
    public var text: String {
        var out = title + "\n" + String(repeating: "-", count: title.count) + "\n"
        for f in facts { out += "\(f.label): \(f.value ?? "unknown")\n" }
        return out
    }

    /// For a golden and the live test's fallback: a fixed machine.
    public static let sample = SystemFacts(title: "ada@jaguar", facts: [
        Fact(.software, "OS", "AbyssBSD on FreeBSD 16.0-CURRENT aarch64"),
        Fact(.software, "Kernel", "FreeBSD 16.0-CURRENT"),
        Fact(.software, "Uptime", "2 days, 3 hours, 14 mins"),
        Fact(.software, "Packages", "412 (pkg)"),
        Fact(.software, "Shell", "sh"),
        Fact(.software, "Desktop", "AbyssBSD Aqua"),
        Fact(.software, "Window Manager", "undertow"),
        Fact(.software, "Theme", "Jaguar"),
        Fact(.software, "Terminal", "Terminal"),
        Fact(.software, "Locale", "en_US.UTF-8"),
        // The Radxa Dragon Q8B, as its own fathom report reads it (2026-10-01).
        Fact(.hardware, "Host", "Radxa Computer Co., Ltd. Radxa Dragon Q8B"),
        Fact(.hardware, "CPU", "ARM Cortex-A78C r0p0 (8)"),
        Fact(.hardware, "GPU", "Qualcomm Adreno (msm)"),
        Fact(.hardware, "Memory", "3.12 GiB / 15.47 GiB (20%)"),
        Fact(.hardware, "Swap", "0 B / 2.00 GiB (0%)"),
        Fact(.hardware, "Disk (/)", "18.40 GiB / 112.30 GiB (16%) - zfs"),
        Fact(.hardware, "Display", "DP-1 1920×1080 @ 60 Hz"),
        Fact(.hardware, "Local IP", "192.168.1.40/24 (tcx0)"),
        Fact(.hardware, "Battery", nil),
    ])
}

// MARK: - Formatting

public enum FactFormat {
    /// fastfetch's binary units: "3.12 GiB", "512.00 MiB", "0 B".
    public static func bytes(_ b: UInt64) -> String {
        if b == 0 { return "0 B" }
        let units = ["B", "KiB", "MiB", "GiB", "TiB"]
        var v = Double(b), i = 0
        while v >= 1024, i < units.count - 1 { v /= 1024; i += 1 }
        if i == 0 { return "\(b) B" }
        return twoPlaces(v) + " " + units[i]
    }

    static func twoPlaces(_ v: Double) -> String {
        let hundredths = Int((v * 100).rounded())
        let frac = hundredths % 100
        return "\(hundredths / 100)." + (frac < 10 ? "0" : "") + "\(frac)"
    }

    /// "used / total (pct%)", fastfetch's usage line.
    public static func usage(used: UInt64, total: UInt64) -> String {
        let pct = total == 0 ? 0 : Int((Double(used) * 100 / Double(total)).rounded())
        return "\(bytes(used)) / \(bytes(total)) (\(pct)%)"
    }

    /// "2 days, 3 hours, 14 mins" from seconds — fastfetch's uptime.
    public static func uptime(seconds s: Int64) -> String {
        guard s >= 0 else { return "0 mins" }
        let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
        var parts: [String] = []
        if d > 0 { parts.append("\(d) day" + (d == 1 ? "" : "s")) }
        if h > 0 { parts.append("\(h) hour" + (h == 1 ? "" : "s")) }
        if m > 0 || parts.isEmpty { parts.append("\(m) min" + (m == 1 ? "" : "s")) }
        return parts.joined(separator: ", ")
    }

    /// "2.71 GHz" from MHz; under a GHz, "800 MHz".
    public static func frequency(mhz: Int64) -> String {
        mhz >= 1000 ? twoPlaces(Double(mhz) / 1000) + " GHz" : "\(mhz) MHz"
    }
}

// MARK: - Parsers (each takes what a command or sysctl said)

public enum FactParse {
    /// The display devices in `pciconf -lv`: each `vgapci…` (class display)
    /// device's `vendor` and `device` strings — "AMD Navi 22 [Radeon RX 6750 XT]".
    public static func pciDisplays(_ text: String) -> [String] {
        var out: [String] = []
        var vendor: String?, device: String?, isDisplay = false, ids = ""
        func flush() {
            if isDisplay {
                if let d = device {
                    let v = vendor.map { shortVendor($0) } ?? ""
                    out.append(v.isEmpty ? d : v + " " + d)
                } else if !ids.isEmpty {
                    // A device pciids does not know (QEMU's VGA): its ids, not nothing.
                    out.append("PCI display " + ids)
                }
            }
            vendor = nil; device = nil; isDisplay = false; ids = ""
        }
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if !line.hasPrefix(" ") && !line.hasPrefix("\t") && line.contains("@pci") {
                flush()
                isDisplay = line.hasPrefix("vgapci")
                let w = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
                let v = w.first { $0.hasPrefix("vendor=") }.map { String($0.dropFirst(7)) }
                let d = w.first { $0.hasPrefix("device=") }.map { String($0.dropFirst(7)) }
                if let v, let d { ids = v + ":" + d }
                continue
            }
            let t = line.trimmed
            if t.hasPrefix("vendor") { vendor = quoted(t) }
            else if t.hasPrefix("device") { device = quoted(t) }
            else if t.hasPrefix("class") && t.contains("display") { isDisplay = true }
        }
        flush()
        return out
    }

    /// "Advanced Micro Devices, Inc. [AMD/ATI]" → "AMD"; "Intel Corporation" → "Intel".
    static func shortVendor(_ v: String) -> String {
        if v.contains("AMD") || v.contains("Advanced Micro") { return "AMD" }
        if v.hasPrefix("Intel") { return "Intel" }
        if v.hasPrefix("NVIDIA") { return "NVIDIA" }
        if v.contains("Red Hat") || v.contains("QEMU") { return "QEMU" }
        return v.split(separator: " ").first.map(String.init) ?? v
    }

    static func quoted(_ s: String) -> String? {
        guard let a = s.firstIndex(of: "'"), let b = s.lastIndex(of: "'"), a < b else { return nil }
        return String(s[s.index(after: a)..<b])
    }

    /// The bound DRM driver, for a machine whose GPU is not a PCI device (an
    /// SoC's): from `kldstat`'s module names.
    public static func drmDriver(kldstat: String) -> String? {
        let names: [(String, String)] = [("msm.ko", "Qualcomm Adreno (msm)"), ("amdgpu.ko", "AMD Radeon (amdgpu)"),
                                         ("i915kms.ko", "Intel (i915)"), ("radeonkms.ko", "AMD Radeon (radeon)"),
                                         ("panfrost.ko", "Arm Mali (panfrost)")]
        for (k, n) in names where kldstat.contains(k) { return n }
        return nil
    }

    /// `swapinfo -k`: used and total, in bytes — the `Total` line when there
    /// are several devices, else the one device; nil with no swap configured.
    public static func swap(swapinfo text: String) -> (used: UInt64, total: UInt64)? {
        let lines = text.split(separator: "\n").map(String.init).filter { !$0.hasPrefix("Device") }
        guard !lines.isEmpty else { return nil }
        let pick = lines.first { $0.hasPrefix("Total") } ?? (lines.count == 1 ? lines[0] : nil)
        guard let line = pick else { return nil }
        let f = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard f.count >= 3, let total = UInt64(f[1]), let used = UInt64(f[2]) else { return nil }
        return (used * 1024, total * 1024)
    }

    /// A device tree's `model`, from `ofwdump -P model -R /` — the board's
    /// name where there is no SMBIOS (an SoC booted with a device tree).
    public static func ofwModel(_ text: String) -> String? {
        for line in text.split(separator: "\n") {
            let t = String(line).trimmed
            if let q = quoted(t), !q.isEmpty { return q }
        }
        return nil
    }

    /// `kern.boottime` as the bytes of a `struct timeval`: its seconds.
    public static func bootSeconds(timeval bytes: [UInt8]) -> Int64? {
        guard bytes.count >= 8 else { return nil }
        return bytes.withUnsafeBytes { $0.loadUnaligned(as: Int64.self) }
    }

    /// Memory in use the way fastfetch counts it on FreeBSD: every page that
    /// is neither free nor inactive (nor in the laundry).
    public static func memoryUsed(pageSize: UInt64, pages: UInt64, free: UInt64, inactive: UInt64,
                                  laundry: UInt64 = 0) -> UInt64 {
        let idle = free + inactive + laundry
        return idle >= pages ? 0 : (pages - idle) * pageSize
    }
}

extension String {
    public var trimmed: String {
        var s = Substring(self)
        while let f = s.first, f == " " || f == "\t" { s.removeFirst() }
        while let l = s.last, l == " " || l == "\t" || l == "\r" { s.removeLast() }
        return String(s)
    }
}
