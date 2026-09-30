// Fathom — the report, as a value (PHASE12.md P12.3).
//
// **Rendered, never printed.** A value can be asserted on, diffed, saved and
// sent; a `print` can only be read once by whoever was standing there. That is
// the same reason `InstallPlan` is a value and the installer's step list is
// compiled rather than executed inline, and it is what makes P12.5 — getting the
// report off the machine — a rendering choice rather than a rewrite.
//
// **What is in it is a decision, not an accident** (PHASE12 §6.2). This report
// is meant to be sent to us, so it is a privacy surface before it is anything
// else, and the field list is settled *on the way in* rather than redacted on
// the way out. What every probe here reports is a **kind of hardware**; what
// none of them reports is *which* machine:
//
//   in   — maker and model, CPU model, memory size, GPU/card nodes, kernel
//          modules bound, interface *names*, audio device names, battery
//          presence, disk models and sizes
//   out  — serial numbers, MAC addresses, IP addresses, hostname, disk serials,
//          ZFS pool names, mount points, user names, anything under /home
//
// A pool name is somebody's word and a mount point is a layout; neither says
// anything about whether this machine can run a desktop, which is the only
// question the matrix asks.

/// One disk, as much of it as a *hardware* report may say.
///
/// Deliberately not `Install.Disk`: that carries `mountedAt` and `existingPools`
/// because a refusal needs them, and neither belongs in a file that gets
/// e-mailed to strangers.
public struct DiskFact: Equatable, Sendable {
    public let name: String
    public let bytes: UInt64
    public let model: String
    public init(name: String, bytes: UInt64, model: String) {
        self.name = name
        self.bytes = bytes
        self.model = model
    }
}

/// What this machine is, and whether the desktop can run on it.
public struct FathomReport: Equatable, Sendable {
    public let results: [ProbeResult]
    public init(_ results: [ProbeResult]) { self.results = results }

    public var counts: (present: Int, absent: Int, unknown: Int) {
        var p = 0, a = 0, u = 0
        for r in results {
            switch r.status {
            case .present: p += 1
            case .absent:  a += 1
            case .unknown: u += 1
            }
        }
        return (p, a, u)
    }

    /// True when nothing could not be asked.
    ///
    /// **Note what this is not:** it is not "this machine is fine". A report full
    /// of honest `absent` answers is complete and still describes a machine that
    /// cannot show a desktop. Completeness and suitability are different
    /// questions and the report must not blur them (§6.4 — be slow to add a
    /// verdict).
    public var isComplete: Bool { counts.unknown == 0 }
}

/// The disks, as hardware rather than as somewhere to install.
public func probeDisks(_ disks: [DiskFact]) -> ProbeResult {
    guard !disks.isEmpty else {
        return ProbeResult("Disks", .absent, "no disks found: there is nowhere to install")
    }
    let parts = disks.map { d -> String in
        let tenths = (d.bytes * 10) / (1024 * 1024 * 1024)
        let size = "\(tenths / 10).\(tenths % 10) GiB"
        return d.model.isEmpty ? "\(d.name) \(size)" : "\(d.name) \(size) (\(d.model))"
    }
    return ProbeResult("Disks", .present, parts.joined(separator: "; "))
}

// MARK: - The console rendering

/// The report as plain text, for a console.
///
/// **Written before the Aqua one and kept first**, because the machine that most
/// needs this report is the machine that cannot draw one: a report that does not
/// survive the failure it describes is not a report. So: ASCII only, no colour,
/// no box drawing, one line per probe, and nothing that needs a terminal wider
/// than 80 columns to stay aligned.
///
/// **`unknown` is spelled differently from `absent` on purpose.** They are two
/// characters apart in this output and a world apart in meaning, and the whole
/// point of the third status is lost if a reader's eye slides over it (§6.1).
///
/// **ASCII is enforced rather than intended.** The first version of this had an
/// em dash in its own title and three more in probe details — written out of
/// habit from the prose two lines above them — which is precisely the kind of
/// thing that renders as garbage on the console of a machine too broken to do
/// anything else. `asciiOnly` folds what it can and drops what it cannot, so a
/// detail string written carelessly later degrades instead of corrupting.
public func renderText(_ report: FathomReport, title: String = "Fathom") -> String {
    var out = asciiOnly(title) + ": what this machine is\n"
    out += String(repeating: "=", count: 40) + "\n"

    let width = report.results.map(\.name.count).max() ?? 0
    for r in report.results {
        let pad = String(repeating: " ", count: max(0, width - r.name.count))
        out += "\(r.name)\(pad)  \(mark(r.status))  \(asciiOnly(r.detail))\n"
    }

    let c = report.counts
    out += String(repeating: "-", count: 40) + "\n"
    out += "\(c.present) present, \(c.absent) absent"
    if c.unknown > 0 {
        // Named in the summary rather than left to be counted off the list: an
        // incomplete report that looks complete is the failure mode this whole
        // status exists to prevent.
        out += ", \(c.unknown) COULD NOT BE ASKED"
    }
    out += "\n"
    return out
}

/// Fold a string to ASCII, so a console renders it rather than mangling it.
///
/// The typographic characters this project's prose is full of are the ones that
/// break here: an em dash, a curly quote, an ellipsis. Folded where there is an
/// obvious equivalent and dropped where there is not — a missing character is a
/// smaller lie than a replacement glyph.
func asciiOnly(_ s: String) -> String {
    var out = ""
    for ch in s {
        switch ch {
        case "\u{2014}", "\u{2013}": out += "-"        // em dash, en dash
        case "\u{2018}", "\u{2019}": out += "'"        // curly single quotes
        case "\u{201C}", "\u{201D}": out += "\""       // curly double quotes
        case "\u{2026}": out += "..."                   // ellipsis
        default:
            if ch.unicodeScalars.allSatisfy(\.isASCII) { out.append(ch) }
        }
    }
    return out
}

/// The three-character mark for a status. Aligned, so a column of them reads as
/// a shape before it reads as words.
func mark(_ s: ProbeStatus) -> String {
    switch s {
    case .present: return "[ok]"
    case .absent:  return "[--]"
    case .unknown: return "[??]"
    }
}

// MARK: - The measurement

/// The frame contract, from `undertow run`'s own key=value output.
///
/// **This is the probe that makes Fathom different from every other live CD.**
/// Anything can say the GPU bound; this says whether the machine holds the frame
/// contract, and by how much it misses. The numbers already existed — the
/// metronome and the flight recorder have printed them since P6.1 — so this is a
/// serialisation pass and not a benchmarking one.
///
/// **It reports numbers and refuses to render a verdict** (PHASE12 §6.4). A
/// pass/fail here would be calibrated on whatever machine happened to be
/// convenient, and the first one is a 20-thread 5 GHz desktop. What a reader
/// needs is the miss rate, the cost, and the budget those were measured against;
/// what they must not be given is our opinion of their hardware.
///
/// **And it carries the clock.** A duration measured against a synthetic grid is
/// not the same quantity as one measured against a real vblank (§2.48), so a
/// nominal-clock result says so in the same breath as the number. Getting that
/// wrong is how a headless miss count gets quoted as a hardware result.
public func probeFrameContract(runOutput: String?) -> ProbeResult {
    guard let text = runOutput, !text.isEmpty else {
        return ProbeResult("Frame contract", .unknown, "undertow did not report")
    }
    var fields: [String: String] = [:]
    for line in text.split(separator: "\n") {
        let parts = line.split(separator: "=", maxSplits: 1)
        guard parts.count == 2 else { continue }
        fields[trimmed(parts[0])] = trimmed(parts[1])
    }

    // `missed=45 of 300`
    guard let missedRaw = fields["missed"] else {
        return ProbeResult("Frame contract", .unknown,
                           "undertow reported no frame counts")
    }
    let bits = missedRaw.split(separator: " ").map(String.init)
    guard bits.count >= 3, let missed = Int(bits[0]), let total = Int(bits[2]) else {
        return ProbeResult("Frame contract", .unknown,
                           "could not read a frame count from \"\(missedRaw)\"")
    }
    guard total > 0 else {
        // The compositor ran and presented nothing. An answer about the machine,
        // not a failure to ask — and one that matters, because every rate below
        // would otherwise be a division by zero dressed as a result.
        return ProbeResult("Frame contract", .absent, "no frames were presented")
    }

    let permille = (missed * 1000) / total
    var detail = "\(missed) of \(total) missed (\(permille) per mille)"
    if let cost = fields["composite-p99-us"] { detail += ", composite p99 \(cost)us" }
    if let period = fields["period-us"] { detail += ", period \(period)us" }

    // **When frames are being missed, say which term is eating them.** A report
    // that says "19% missed" and stops is a report that sends somebody back to
    // the machine. The margin is `wake + cost + commit + safety`, each measured,
    // so the largest one is the answer — and `margin-pinned` says whether the
    // control loop has hit its ceiling, which is the difference between "slow"
    // and "given up".
    if missed > 0 {
        let terms = [("waking late", fields["margin-wake-us"]),
                     ("compositing", fields["margin-cost-us"]),
                     ("display commit", fields["margin-commit-us"]),
                     ("unattributed", fields["margin-safety-us"])]
            .compactMap { name, v -> (String, Int)? in
                guard let v, let n = Int(v) else { return nil }
                return (name, n)
            }
        if let worst = terms.max(by: { $0.1 < $1.1 }), worst.1 > 0 {
            detail += "; margin dominated by \(worst.0) (\(worst.1)us)"
        }
        if fields["margin-pinned"] == "yes" {
            detail += "; MARGIN PINNED AT ITS CEILING, the loop cannot compensate further"
        }
    }

    // **Whose clock, and not merely whether one was seen.** §2.48: a nested
    // compositor presents when its *host* presents, and passes real timestamps
    // through — so `vblank-source=hardware` is true there and the numbers still
    // mean nothing. Only the backend separates "our own vblank" from "somebody
    // else's", which is why the label is built from both fields and why a nested
    // result is called not-applicable rather than reported as a measurement.
    let clock = fields["vblank-source"]
    switch fields["backend"] {
    case "drm":
        detail += clock == "hardware" ? " [hardware clock, DRM]"
                                      : " [DRM but NO hardware clock: treat as provisional]"
    case "nested-wayland", "nested-x11":
        detail += " [NESTED: measured against the host's clock, NOT APPLICABLE]"
    case "headless":
        detail += " [HEADLESS: a synthetic grid, not a hardware measurement]"
    default:
        // Output from a build that predates the label. Saying nothing would let
        // it read as a hardware measurement, which is the failure being guarded.
        detail += clock == "hardware" ? " [clock hardware, backend unstated]"
                                      : " [clock and backend unstated]"
    }
    return ProbeResult("Frame contract", .present, detail)
}

// MARK: - Getting it off the machine

/// The filename a report should be saved under.
///
/// **The matrix is populated by people who are not us, so the retrieval path
/// cannot assume a network** — and the machines where the network does not come
/// up are exactly thesis 5's weak spot. The report goes on the medium's own ESP,
/// which is FAT: the one filesystem Windows, macOS and Linux all read. Pull the
/// stick out, plug it into whatever computer you do have, and the report is a
/// file.
///
/// **The name identifies the machine and not the person** (§6.2, again, because
/// a filename is as public as the contents). Maker and model go in; hostname,
/// serial and user do not. Two different machines on one stick get two files,
/// which is the case the matrix is for; the same machine twice overwrites, which
/// is the case a person is for.
///
/// FAT-safe by construction: lowercase ASCII, digits and hyphens only.
public func reportFilename(maker: String?, product: String?) -> String {
    func slug(_ s: String?) -> String {
        var out = ""
        var lastWasDash = false
        for ch in (s ?? "").lowercased() {
            if ch.isLetter || ch.isNumber, ch.isASCII {
                out.append(ch)
                lastWasDash = false
            } else if !out.isEmpty && !lastWasDash {
                out.append("-")
                lastWasDash = true
            }
        }
        while out.last == "-" { out.removeLast() }
        return out
    }
    let parts = [slug(maker), slug(product)].filter { !$0.isEmpty }
    guard !parts.isEmpty else { return "fathom-unknown.txt" }
    // Long enough to distinguish machines, short enough that no filesystem
    // argues about it.
    let name = parts.joined(separator: "-")
    return "fathom-" + String(name.prefix(48)) + ".txt"
}
