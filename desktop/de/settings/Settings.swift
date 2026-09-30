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
    /// powerd's modes are the power profile's to choose (P14.8b): run it with
    /// no flags, because rc.d/power_profile only sets powerd's mode when
    /// `powerd_flags` is empty. `onAC`/`onBattery` are then not written.
    public var modesFromProfile: Bool

    public init(powerd: Bool, onAC: PowerdMode = .hiadaptive, onBattery: PowerdMode = .adaptive,
                modesFromProfile: Bool = false) {
        self.powerd = powerd
        self.onAC = onAC
        self.onBattery = onBattery
        self.modesFromProfile = modesFromProfile
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

/// The base system's power profile (P14.8b): rc.conf's `power_profile`, as
/// `rc.d/power_profile` in the AbyssBSD base reads it — CPU idle depth, powerd's
/// mode and hooks such as a GPU's clocks, chosen as one thing, the way Linux
/// desktops offer power-profiles-daemon. **Upstream FreeBSD has no such
/// variable** (its `rc.d/power_profile` is the older AC-line script), so a base
/// without it is told, not guessed at: `unavailable(kind:values:)`.
public enum PowerProfile: String, CaseIterable, Equatable, Sendable {
    case powerSaver = "power-saver"
    case balanced
    case performance
}

public struct PowerProfilePlan: Equatable, Sendable {
    public var profile: PowerProfile
    public init(profile: PowerProfile) { self.profile = profile }
}

/// Everything System Preferences may ask of the machine. One case per pane;
/// P14.4 adds network, P14.6 sound.
public enum SettingsPlan: Equatable, Sendable {
    case energy(EnergyPlan)
    case powerProfile(PowerProfilePlan)
    case network(NetworkPlan)
    case sound(SoundPlan)
    case wifi(WifiPlan)

    public var kind: String {
        switch self {
        case .energy: return "energy"
        case .powerProfile: return "power-profile"
        case .network: return "network"
        case .sound: return "sound"
        case .wifi: return "wifi"
        }
    }
}

// MARK: - Sound (P14.6)

/// Which device `/dev/dsp` means. Levels and mute are not here: `/dev/mixerN`
/// is the user's to change, and `rc.d/mixer` saves them at shutdown and
/// restores them at boot. The default unit is a sysctl, which is root's.
public struct SoundPlan: Equatable, Sendable {
    public var defaultUnit: Int
    public init(defaultUnit: Int) { self.defaultUnit = defaultUnit }
}

// MARK: - Network (P14.4)

/// An IPv4 address, parsed strictly: four decimal octets, nothing else.
public struct IPv4: Equatable, Hashable, Sendable, CustomStringConvertible {
    public let octets: [UInt8]
    public init?(_ s: String) {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var o: [UInt8] = []
        for p in parts {
            guard !p.isEmpty, p.count <= 3, p.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let v = UInt8(p), !(p.count > 1 && p.first == "0") else { return nil }
            o.append(v)
        }
        octets = o
    }
    init(value v: UInt32) { octets = [UInt8(v >> 24), UInt8((v >> 16) & 0xff), UInt8((v >> 8) & 0xff), UInt8(v & 0xff)] }
    public var value: UInt32 { octets.reduce(0) { $0 << 8 | UInt32($1) } }
    public var description: String { octets.map(String.init).joined(separator: ".") }

    /// A dotted netmask as a prefix length, or nil when it is not a mask at
    /// all — its ones not contiguous from the top.
    public var prefixLength: Int? {
        let v = value
        let ones = v.nonzeroBitCount
        let mask: UInt32 = ones == 0 ? 0 : ~UInt32(0) << (32 - ones)
        return v == mask ? ones : nil
    }
    public static func mask(prefix: Int) -> IPv4 {
        IPv4(value: prefix == 0 ? 0 : ~UInt32(0) << (32 - UInt32(prefix)))
    }
}

/// How an interface gets its IPv4 address.
public enum IPv4Config: Equatable, Sendable {
    case dhcp
    case manual(address: IPv4, prefix: Int, router: IPv4?)
}

/// The Network pane's plan for one wired interface (P14.4).
public struct NetworkPlan: Equatable, Sendable {
    public var interface: String
    public var ipv4: IPv4Config
    /// Name servers, in order; empty for whatever DHCP says, or none.
    public var dns: [IPv4]

    public init(interface: String, ipv4: IPv4Config, dns: [IPv4] = []) {
        self.interface = interface
        self.ipv4 = ipv4
        self.dns = dns
    }

    /// What the machine says, from `ifconfig_<if>`, `defaultrouter` and
    /// resolvconf's `name_servers`. A line this does not understand — an alias,
    /// an IPv6 address, `ifconfig_DEFAULT` — reads as DHCP only when it says
    /// DHCP; otherwise the plan is nil and the pane says it cannot show it.
    public static func from(interface: String, ifconfig: String?, router: String?,
                            nameServers: String?) -> NetworkPlan? {
        let dns = (nameServers ?? "").split(separator: " ").compactMap { IPv4(String($0)) }
        let words = (ifconfig ?? "").split(separator: " ").map(String.init)
        if words.isEmpty || words.contains(where: { $0.uppercased().hasSuffix("DHCP") }) {
            return NetworkPlan(interface: interface, ipv4: .dhcp, dns: dns)
        }
        guard words.count >= 4, words[0] == "inet", let a = IPv4(words[1]),
              words[2] == "netmask", let m = IPv4(words[3]), let p = m.prefixLength else { return nil }
        return NetworkPlan(interface: interface,
                           ipv4: .manual(address: a, prefix: p, router: router.flatMap { IPv4($0) }),
                           dns: dns)
    }
}

/// A shell-variable file this helper edits with `sysrc -f`.
public enum ConfFile: String, CaseIterable, Equatable, Sendable {
    /// `/etc/rc.conf` — the machine's configuration.
    case rcConf = "rc.conf"
    /// `/etc/resolvconf.conf` — where name servers a person chose live, for
    /// `resolvconf -u` to put into resolv.conf beside what DHCP says.
    case resolvconf = "resolvconf.conf"
    /// `/etc/sysctl.conf` — kernel settings applied at boot (the default sound
    /// device). Not an sh file, so not `sysrc`'s: the helper edits it itself
    /// (`Settings.editSysctlConf`), in the same staged copy.
    case sysctlConf = "sysctl.conf"
    /// `/etc/wpa_supplicant.conf` — the Wi-Fi networks this machine may join
    /// (P14.5). Not sh either; the helper edits it itself (`WpaConf`).
    case wpaSupplicant = "wpa_supplicant.conf"

    /// Whether `sysrc` can edit it (sh variable assignments).
    public var isShellVariables: Bool { self != .sysctlConf && self != .wpaSupplicant }

    /// The mode a new copy is made with: a file of network keys is root's alone.
    public var newFileMode: UInt32 { self == .wpaSupplicant ? 0o600 : 0o644 }
}

/// One thing the helper will do.
public enum SettingsStep: Equatable, Sendable {
    /// Set a variable in one of the helper's files, or remove it (`nil`) so the
    /// default applies. Written into a **staged copy** of that file; the real
    /// files are replaced only when every write succeeded.
    case setVar(ConfFile, key: String, value: String?)
    /// `service NAME ACTION…`, after the files are in place. `mayFail` when
    /// the action's failure is not the plan's — stopping what is not running.
    case service(name: String, action: [String], mayFail: Bool)
    /// A base tool, run after the files are in place (`resolvconf -u`).
    case tool(argv: [String], mayFail: Bool)

    /// Set or remove an rc.conf variable — the common case.
    public static func rcConf(key: String, value: String?) -> SettingsStep {
        .setVar(.rcConf, key: key, value: value)
    }
    public static func service(name: String, action: String, mayFail: Bool) -> SettingsStep {
        .service(name: name, action: [action], mayFail: mayFail)
    }

    /// Whether it acts on the running machine, rather than writing a file.
    public var acts: Bool { if case .setVar = self { return false }; return true }

    /// What a person reads in the journal and the pane.
    public var description: String {
        switch self {
        // **Never the key.** This line is what `check` shows, the journal
        // keeps and the pane says; a network is named, its PSK is not.
        case .setVar(.wpaSupplicant, let k, let v):
            let name = WpaConf.unhex(k.dropFirst(5)).map { "\"\($0)\"" } ?? k
            return v == nil ? "forget network \(name) in wpa_supplicant.conf"
                            : "add network \(name) to wpa_supplicant.conf"
        case .setVar(let f, let k, let v?): return "set \(k)=\"\(v)\" in \(f.rawValue)"
        case .setVar(let f, let k, nil): return "remove \(k) from \(f.rawValue)"
        case .service(let n, let a, _):
            // "restart the netif service for wlan0", not "restart wlan0 the …".
            return "\(a.first ?? "") the \(n) service" + (a.count > 1 ? " for " + a.dropFirst().joined(separator: " ") : "")
        case .tool(let argv, _): return "run " + argv.joined(separator: " ")
        }
    }

    /// The exact command; `path(file)` is the file `sysrc` edits — the staged copy.
    public func command(path: (ConfFile) -> String) -> [String] {
        switch self {
        case .setVar(let f, _, _) where !f.isShellVariables:
            return []           // no command: the helper edits the file itself
        case .setVar(let f, let k, let v?): return ["sysrc", "-f", path(f), "\(k)=\(v)"]
        case .setVar(let f, let k, nil): return ["sysrc", "-f", path(f), "-x", k]
        case .service(let n, let a, _): return ["service", n] + a
        case .tool(let argv, _): return argv
        }
    }
    public func command(rcConf: String) -> [String] {
        command { $0 == .rcConf ? rcConf : "/etc/" + $0.rawValue }
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
        case .energy, .powerProfile:
            return []
        case .network(let n):
            return networkProblems(n)
        case .sound(let s):
            return s.defaultUnit < 0 ? [SettingsRefusal("pcm\(s.defaultUnit) is not a sound device's unit")] : []
        case .wifi(let w):
            return wifiProblems(w)
        }
    }

    /// A wired interface's name as FreeBSD spells it — letters, then a unit
    /// number (`em0`, `igc0`, `vtnet0`) — and not the loopback.
    public static func isInterfaceName(_ s: String) -> Bool {
        guard let firstDigit = s.firstIndex(where: { $0.isNumber }), firstDigit != s.startIndex,
              s[..<firstDigit].allSatisfy({ $0.isASCII && $0.isLowercase }),
              s[firstDigit...].allSatisfy({ $0.isASCII && $0.isNumber }), s.count <= 15 else { return false }
        return !s.hasPrefix("lo")
    }

    static func networkProblems(_ n: NetworkPlan) -> [SettingsRefusal] {
        var out: [SettingsRefusal] = []
        if !isInterfaceName(n.interface) {
            out.append(SettingsRefusal("\(n.interface.isEmpty ? "no interface" : n.interface) is not a wired interface's name"))
        }
        if case .manual(let a, let p, let r) = n.ipv4 {
            if !(8...30).contains(p) {
                out.append(SettingsRefusal("a /\(p) network is not one a wired interface is given (8 to 30)"))
            } else {
                let mask = IPv4.mask(prefix: p).value
                let host = a.value & ~mask
                if host == 0 { out.append(SettingsRefusal("\(a) is the network's own address, not a host's")) }
                if host == ~mask { out.append(SettingsRefusal("\(a) is the network's broadcast address")) }
                if let r {
                    if r.value & mask != a.value & mask {
                        out.append(SettingsRefusal("the router \(r) is not on \(a)'s network (/\(p)) — it could not be reached"))
                    } else if r == a {
                        out.append(SettingsRefusal("the router cannot be this machine's own address"))
                    }
                }
            }
            if a.octets[0] == 0 || a.octets[0] == 127 || a.octets[0] >= 224 {
                out.append(SettingsRefusal("\(a) cannot be an interface's address"))
            }
        }
        if n.dns.count > 3 {
            out.append(SettingsRefusal("\(n.dns.count) name servers: the resolver uses three at most"))
        }
        for d in n.dns where d.value == 0 || d.octets[0] >= 224 {
            out.append(SettingsRefusal("\(d) cannot be a name server"))
        }
        return out
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
                    .rcConf(key: "powerd_flags",
                            value: e.modesFromProfile ? nil : "-a \(e.onAC.rawValue) -b \(e.onBattery.rawValue)"),
                    .service(name: "powerd", action: "onerestart", mayFail: false)]
        case .powerProfile(let p):
            // The profile, then powerd's own flags cleared: rc.d/power_profile
            // chooses powerd's mode only when `powerd_flags` is empty, so a
            // policy the Energy pane once set would silently outrank the
            // profile. Then applied now, as boot would.
            return [.rcConf(key: "power_profile", value: p.profile.rawValue),
                    .rcConf(key: "powerd_flags", value: nil),
                    .service(name: "power_profile", action: "start", mayFail: false)]
        case .wifi(let w):
            return compileWifi(w)
        case .sound(let s):
            // For the next boot, then for now. The kernel refuses a unit with
            // no device behind it, which fails the plan — after sysctl.conf
            // is written, so the helper checks the unit exists first.
            return [.setVar(.sysctlConf, key: "hw.snd.default_unit", value: "\(s.defaultUnit)"),
                    .tool(argv: ["sysctl", "hw.snd.default_unit=\(s.defaultUnit)"], mayFail: false)]
        case .network(let n):
            var steps: [SettingsStep] = []
            switch n.ipv4 {
            case .dhcp:
                // SYNCDHCP, as the installer writes: rc waits for the lease, so
                // what starts after the network finds one.
                steps.append(.rcConf(key: "ifconfig_\(n.interface)", value: "SYNCDHCP"))
                steps.append(.rcConf(key: "defaultrouter", value: nil))
            case .manual(let a, let p, let r):
                steps.append(.rcConf(key: "ifconfig_\(n.interface)",
                                     value: "inet \(a) netmask \(IPv4.mask(prefix: p))"))
                steps.append(.rcConf(key: "defaultrouter", value: r?.description))
            }
            steps.append(.setVar(.resolvconf, key: "name_servers",
                                 value: n.dns.isEmpty ? nil : n.dns.map(\.description).joined(separator: " ")))
            // Then act: the interface again, the routes again, and the
            // resolver's file written from what is now configured.
            steps.append(.service(name: "netif", action: ["restart", n.interface], mayFail: false))
            steps.append(.service(name: "routing", action: ["restart"], mayFail: false))
            steps.append(.tool(argv: ["resolvconf", "-u"], mayFail: false))
            return steps
        }
    }

    /// The rc.conf variables a plan kind reads back, so the pane can show what
    /// the machine says now.
    /// Which file each key is read from; for network, `interface` names the
    /// interface whose line is read.
    public static func keys(for kind: String, interface: String = "")
        -> [(file: ConfFile, key: String)]? {
        switch kind {
        case "energy": return [(.rcConf, "powerd_enable"), (.rcConf, "powerd_flags")]
        case "power-profile": return [(.rcConf, "power_profile")]
        case "network":
            guard isInterfaceName(interface) else { return nil }
            return [(.rcConf, "ifconfig_\(interface)"), (.rcConf, "defaultrouter"),
                    (.resolvconf, "name_servers")]
        case "sound": return [(.sysctlConf, "hw.snd.default_unit")]
        default: return nil
        }
    }

    /// The plan the machine is carrying out now, from those variables.
    public static func current(kind: String, interface: String = "",
                               values: [String: String]) -> SettingsPlan? {
        switch kind {
        case "energy":
            return .energy(EnergyPlan.from(enable: values["powerd_enable"], flags: values["powerd_flags"]))
        case "power-profile":
            return values["power_profile"].flatMap { PowerProfile(rawValue: $0) }
                .map { .powerProfile(PowerProfilePlan(profile: $0)) }
        case "network":
            return NetworkPlan.from(interface: interface, ifconfig: values["ifconfig_\(interface)"],
                                    router: values["defaultrouter"],
                                    nameServers: values["name_servers"]).map { .network($0) }
        case "sound":
            return values["hw.snd.default_unit"].flatMap { Int($0) }.map { .sound(SoundPlan(defaultUnit: $0)) }
        default: return nil
        }
    }

    /// Why a plan kind cannot be shown or applied on this machine at all, from
    /// what reading its keys found — nil when it can. Power profiles are the one
    /// that depends on the base: `sysrc -n` answers from /etc/defaults/rc.conf,
    /// which declares `power_profile` in the AbyssBSD base and not upstream.
    public static func unavailable(kind: String, values: [String: String]) -> String? {
        guard kind == "power-profile" else { return nil }
        guard let v = values["power_profile"] else {
            return "this FreeBSD offers no power profiles — its rc.d/power_profile is the older AC-line script"
        }
        if v.uppercased() == "NONE" {
            return "power profiles are turned off on this machine (power_profile=NONE)"
        }
        return PowerProfile(rawValue: v) == nil ? "power_profile is \"\(v)\", which is not a profile this pane knows" : nil
    }

    /// The list, as the commands it will run — for `check`, the journal, and a
    /// person reading either.
    public static func render(_ steps: [SettingsStep],
                              path: (ConfFile) -> String = { "/etc/" + $0.rawValue }) -> String {
        steps.enumerated().map { i, s in
            let c = s.command(path: path)
            return "\(i + 1). \(s.description)\n   " + (c.isEmpty ? "(the helper edits the file itself)"
                                                               : "$ " + c.joined(separator: " "))
        }.joined(separator: "\n")
    }

    /// Edit a file the helper edits itself (not sh): the one place that knows
    /// which editor each such file has.
    public static func editFile(_ file: ConfFile, _ text: String, key: String, value: String?) -> String {
        switch file {
        case .wpaSupplicant: return WpaConf.edit(text, ssid: WpaConf.unhex(key.dropFirst(5)) ?? key, body: value)
        default: return editSysctlConf(text, key: key, value: value)
        }
    }

    // MARK: - sysctl.conf

    /// `text` with `key` set to `value` (or removed, for nil): the first
    /// assignment of the key is replaced in place and any later ones dropped
    /// (sysctl.conf applies lines in order, so a later one would win);
    /// otherwise the line is appended. Comments and everything else are kept.
    public static func editSysctlConf(_ text: String, key: String, value: String?) -> String {
        var out: [Substring] = []
        var done = false
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        for line in lines {
            if sysctlConfKey(line) == key {
                if !done, let v = value { out.append(Substring("\(key)=\(v)")) }
                done = true
                continue
            }
            out.append(line)
        }
        if !done, let v = value {
            if let last = out.last, last.isEmpty { out.removeLast() }
            out.append(Substring("\(key)=\(v)"))
            out.append("")
        }
        return out.joined(separator: "\n")
    }

    /// The value sysctl.conf gives `key` — the last assignment, as sysctl(8)
    /// would leave it — or nil.
    public static func sysctlConfValue(_ text: String, key: String) -> String? {
        var found: String?
        for line in text.split(separator: "\n") where sysctlConfKey(line) == key {
            var v = line[line.index(after: line.firstIndex(of: "=")!)...]
            if let hash = v.firstIndex(of: "#") { v = v[..<hash] }
            found = String(v.drop { $0 == " " || $0 == "\t" }.reversed().drop { $0 == " " || $0 == "\t" }.reversed())
        }
        return found
    }

    private static func sysctlConfKey(_ line: Substring) -> String? {
        let t = line.drop { $0 == " " || $0 == "\t" }
        guard !t.hasPrefix("#"), let eq = t.firstIndex(of: "=") else { return nil }
        let k = t[..<eq].reversed().drop { $0 == " " || $0 == "\t" }.reversed()
        return k.isEmpty ? nil : String(k)
    }
    public static func render(_ steps: [SettingsStep], rcConf: String) -> String {
        render(steps) { $0 == .rcConf ? rcConf : "/etc/" + $0.rawValue }
    }
}
