// Settings — what System Preferences may ask the machine to change, as values
// (PHASE14 P14.3).
//
// The installer's shape, built once more on purpose (PHASE14 §3): an
// unprivileged pane describes what it wants as a typed **plan**; this decides
// whether that may happen (refusals, in words) and compiles it to the exact
// **steps** a root helper will run. Nothing here runs anything, and it imports
// nothing at all — so every refusal and every step list is tested on a machine
// with no rc.conf, as `de/install`'s are.
//
// **The pane never names a command, a file or a key.** A plan says "powerd on,
// adaptive on AC"; which rc.conf variables that means, and which service to
// restart, is decided here and nowhere else. A caller that could send "set
// this variable to that" would be handing root to whoever can reach the socket.
//
// The first plan is the Energy pane's powerd half (P14.8), chosen because it is
// real and harmless in a build guest; the network plan (P14.4) is neither.

/// powerd's policy for one power source (`powerd(8)` `-a` / `-b`).
public enum PowerdMode: String, CaseIterable, Equatable, Sendable {
    case adaptive, hiadaptive
    case minimum = "min"
    case maximum = "max"
}

/// The Energy pane's machine half: whether `powerd` runs, and how.
public struct EnergyPlan: Equatable, Sendable {
    public var powerd: Bool
    public var onAC: PowerdMode
    public var onBattery: PowerdMode

    public init(powerd: Bool, onAC: PowerdMode = .hiadaptive, onBattery: PowerdMode = .adaptive) {
        self.powerd = powerd
        self.onAC = onAC
        self.onBattery = onBattery
    }

    /// What rc.conf says, as `sysrc -n` reports it (defaults already applied).
    /// A flags string this does not understand is kept as the defaults rather
    /// than guessed at — a pane that showed a policy nobody set would be worse.
    public static func from(enable: String?, flags: String?) -> EnergyPlan {
        var p = EnergyPlan(powerd: (enable ?? "NO").uppercased() == "YES")
        let words = (flags ?? "").split(separator: " ").map(String.init)
        var i = 0
        while i + 1 < words.count {
            if let m = PowerdMode(rawValue: words[i + 1]) {
                if words[i] == "-a" { p.onAC = m } else if words[i] == "-b" { p.onBattery = m }
            }
            i += 2
        }
        return p
    }
}

/// Everything System Preferences may ask of the machine. One case per pane;
/// P14.4 adds network, P14.6 sound.
public enum SettingsPlan: Equatable, Sendable {
    case energy(EnergyPlan)

    public var kind: String {
        switch self {
        case .energy: return "energy"
        }
    }
}

/// One thing the helper will do.
public enum SettingsStep: Equatable, Sendable {
    /// Set an rc.conf variable, or remove it (`nil`) so the default applies.
    /// Written into a **staged copy** first; the real file is replaced only when
    /// every write succeeded.
    case rcConf(key: String, value: String?)
    /// `service NAME ACTION`, after rc.conf is in place. `mayFail` when the
    /// action's failure is not the plan's — stopping what is not running.
    case service(name: String, action: String, mayFail: Bool)

    /// What a person reads in the journal and the pane.
    public var description: String {
        switch self {
        case .rcConf(let k, let v?): return "set \(k)=\"\(v)\" in rc.conf"
        case .rcConf(let k, nil): return "remove \(k) from rc.conf"
        case .service(let n, let a, _): return "\(a) the \(n) service"
        }
    }

    /// The exact command. `rcConf` is the file `sysrc` edits — the staged copy.
    public func command(rcConf: String) -> [String] {
        switch self {
        case .rcConf(let k, let v?): return ["sysrc", "-f", rcConf, "\(k)=\(v)"]
        case .rcConf(let k, nil): return ["sysrc", "-f", rcConf, "-x", k]
        case .service(let n, let a, _): return ["service", n, a]
        }
    }
}

public struct SettingsRefusal: Equatable, Sendable, Error {
    public let message: String
    public init(_ m: String) { message = m }
}

public enum Settings {
    /// Why a plan must not be carried out, in words; empty when it may be.
    /// A typed plan leaves little to refuse — the modes are an enumeration, not
    /// a string — which is the point of typing it. Later plans (addresses,
    /// devices) will have more.
    public static func problems(_ plan: SettingsPlan) -> [SettingsRefusal] {
        switch plan {
        case .energy:
            return []
        }
    }

    /// The step list, or the refusals. The same function `check` and `apply`
    /// call, so a plan that checks is a plan that applies.
    public static func compile(_ plan: SettingsPlan) throws -> [SettingsStep] {
        let refusals = problems(plan)
        if let first = refusals.first { throw first }
        switch plan {
        case .energy(let e):
            guard e.powerd else {
                // Off: say so in rc.conf, drop the policy, and stop it — which
                // may well not be running, and that is not a failure.
                return [.rcConf(key: "powerd_enable", value: "NO"),
                        .rcConf(key: "powerd_flags", value: nil),
                        .service(name: "powerd", action: "onestop", mayFail: true)]
            }
            return [.rcConf(key: "powerd_enable", value: "YES"),
                    .rcConf(key: "powerd_flags", value: "-a \(e.onAC.rawValue) -b \(e.onBattery.rawValue)"),
                    .service(name: "powerd", action: "onerestart", mayFail: false)]
        }
    }

    /// The rc.conf variables a plan kind reads back, so the pane can show what
    /// the machine says now.
    public static func keys(for kind: String) -> [String]? {
        switch kind {
        case "energy": return ["powerd_enable", "powerd_flags"]
        default: return nil
        }
    }

    /// The plan the machine is carrying out now, from those variables.
    public static func current(kind: String, values: [String: String]) -> SettingsPlan? {
        switch kind {
        case "energy":
            return .energy(EnergyPlan.from(enable: values["powerd_enable"], flags: values["powerd_flags"]))
        default: return nil
        }
    }

    /// The list, as the commands it will run — for `check`, the journal, and a
    /// person reading either.
    public static func render(_ steps: [SettingsStep], rcConf: String = "/etc/rc.conf") -> String {
        steps.enumerated().map { i, s in
            "\(i + 1). \(s.description)\n   $ " + s.command(rcConf: rcConf).joined(separator: " ")
        }.joined(separator: "\n")
    }
}
