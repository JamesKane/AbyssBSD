// The settings plan on the wire (PHASE14 P14.3).
//
// Its own target for the installer's reason (InstallWire): System Preferences
// must be able to speak the protocol **without linking the code that runs
// `sysrc` as root**. `Msg` has scalars and no arrays, so a plan is a few named
// fields and a step list is indexed ones — verbose, and trivially readable in a
// log, which is where a root helper's messages end up being read.

import CurrentIPC
import Settings

/// What an apply reports as it happens — the vocabulary both ends share.
public enum SettingsEvent: Equatable, Sendable {
    case starting(index: Int, total: Int, what: String)
    case ok(index: Int)
    case failed(index: Int, what: String, why: String, ignored: Bool)
    /// Not run, on purpose: a write-only helper (a test's) leaves the machine
    /// alone and says so, rather than calling it done.
    case skipped(index: Int, why: String)
    case finished(ok: Bool, error: String)
}

public enum SettingsWire {

    // MARK: - The plan

    public static func encode(_ p: SettingsPlan, into m: inout Msg) {
        m.set("kind", p.kind)
        switch p {
        case .energy(let e):
            m.set("energy.powerd", e.powerd)
            m.set("energy.ac", e.onAC.rawValue)
            m.set("energy.battery", e.onBattery.rawValue)
            if e.modesFromProfile { m.set("energy.modes-from-profile", true) }
        case .powerProfile(let pp):
            m.set("power-profile", pp.profile.rawValue)
        case .network(let n):
            m.set("network.interface", n.interface)
            switch n.ipv4 {
            case .dhcp:
                m.set("network.mode", "dhcp")
            case .manual(let a, let p, let r):
                m.set("network.mode", "manual")
                m.set("network.address", a.description)
                m.set("network.netmask", IPv4.mask(prefix: p).description)
                if let r { m.set("network.router", r.description) }
            }
            m.set("network.dns", n.dns.map(\.description).joined(separator: " "))
        case .sound(let s):
            m.set("sound.default", "\(s.defaultUnit)")
        case .volume(let v):
            switch v.action {
            case .snapshot(let ds, let name): m.set("volume.action", "snapshot"); m.set("volume.dataset", ds); m.set("volume.name", name)
            case .rollback(let snap): m.set("volume.action", "rollback"); m.set("volume.snapshot", snap)
            case .mountDataset(let ds): m.set("volume.action", "mount"); m.set("volume.dataset", ds)
            case .unmountDataset(let ds): m.set("volume.action", "unmount"); m.set("volume.dataset", ds)
            case .unmount(let path): m.set("volume.action", "unmount"); m.set("volume.path", path)
            }
        case .signal(let s):
            m.set("signal.pid", "\(s.pid)")
            m.set("signal.force", s.force)
            m.set("signal.started", "\(s.started)")
            m.set("signal.name", s.name)
        case .wifi(let w):
            m.set("wifi.device", w.device)
            m.set("wifi.interface", w.interface)
            m.set("wifi.ssid", w.ssid)
            switch w.action {
            case .join(_, let psk):
                m.set("wifi.action", "join")
                if let psk { m.set("wifi.psk", psk) }      // the derived key; never a passphrase
            case .forget:
                m.set("wifi.action", "forget")
            }
        }
    }

    /// The plan a message describes, or why it describes none. An unknown kind
    /// or an unknown mode is refused rather than defaulted: a helper that
    /// guessed what a caller meant is a helper that does something nobody asked.
    public static func decodePlan(_ m: Msg) -> Result<SettingsPlan, SettingsRefusal> {
        switch m.string("kind") ?? "" {
        case "energy":
            guard let on = m.bool("energy.powerd") else {
                return .failure(SettingsRefusal("an energy plan must say whether powerd runs"))
            }
            let ac = m.string("energy.ac") ?? PowerdMode.hiadaptive.rawValue
            let bat = m.string("energy.battery") ?? PowerdMode.adaptive.rawValue
            guard let a = PowerdMode(rawValue: ac), let b = PowerdMode(rawValue: bat) else {
                return .failure(SettingsRefusal("powerd has no mode \(PowerdMode(rawValue: ac) == nil ? ac : bat)"
                    + " (it has: \(PowerdMode.allCases.map(\.rawValue).joined(separator: ", ")))"))
            }
            return .success(.energy(EnergyPlan(powerd: on, onAC: a, onBattery: b,
                                               modesFromProfile: m.bool("energy.modes-from-profile") ?? false)))
        case "power-profile":
            guard let v = m.string("power-profile"), let pp = PowerProfile(rawValue: v) else {
                return .failure(SettingsRefusal("a power-profile plan must name power-saver, balanced or performance"))
            }
            return .success(.powerProfile(PowerProfilePlan(profile: pp)))
        case "network":
            let iface = m.string("network.interface") ?? ""
            var dns: [IPv4] = []
            for w in (m.string("network.dns") ?? "").split(separator: " ") {
                guard let d = IPv4(String(w)) else {
                    return .failure(SettingsRefusal("\(w) is not an IPv4 address (a name server)"))
                }
                dns.append(d)
            }
            switch m.string("network.mode") ?? "" {
            case "dhcp":
                return .success(.network(NetworkPlan(interface: iface, ipv4: .dhcp, dns: dns)))
            case "manual":
                let a = m.string("network.address") ?? "", mask = m.string("network.netmask") ?? ""
                guard let addr = IPv4(a) else {
                    return .failure(SettingsRefusal("\(a.isEmpty ? "no address" : a) is not an IPv4 address"))
                }
                guard let mk = IPv4(mask), let prefix = mk.prefixLength else {
                    return .failure(SettingsRefusal("\(mask.isEmpty ? "no subnet mask" : mask) is not a subnet mask"))
                }
                var router: IPv4?
                if let r = m.string("network.router"), !r.isEmpty {
                    guard let rv = IPv4(r) else { return .failure(SettingsRefusal("\(r) is not a router's IPv4 address")) }
                    router = rv
                }
                return .success(.network(NetworkPlan(interface: iface,
                                                     ipv4: .manual(address: addr, prefix: prefix, router: router),
                                                     dns: dns)))
            case let other:
                return .failure(SettingsRefusal(other.isEmpty ? "a network plan must say DHCP or manual"
                                                             : "\(other) is not DHCP or manual"))
            }
        case "volume":
            let ds = m.string("volume.dataset"), path = m.string("volume.path")
            switch m.string("volume.action") ?? "" {
            case "snapshot":
                guard let ds, let name = m.string("volume.name") else { return .failure(SettingsRefusal("a snapshot needs a dataset and a name")) }
                return .success(.volume(VolumePlan(.snapshot(dataset: ds, name: name))))
            case "rollback":
                guard let snap = m.string("volume.snapshot") else { return .failure(SettingsRefusal("a rollback needs a snapshot")) }
                return .success(.volume(VolumePlan(.rollback(snapshot: snap))))
            case "mount":
                guard let ds else { return .failure(SettingsRefusal("a mount needs a dataset")) }
                return .success(.volume(VolumePlan(.mountDataset(ds))))
            case "unmount":
                if let ds { return .success(.volume(VolumePlan(.unmountDataset(ds)))) }
                guard let path else { return .failure(SettingsRefusal("an unmount needs a dataset or a mount point")) }
                return .success(.volume(VolumePlan(.unmount(path: path))))
            case let other:
                return .failure(SettingsRefusal(other.isEmpty ? "a volume plan must say what to do" : "\(other) is not something Disk Utility does"))
            }
        case "signal":
            guard let pid = Int32(m.string("signal.pid") ?? ""), let started = Int64(m.string("signal.started") ?? "") else {
                return .failure(SettingsRefusal("a quit must say which process, and when it started"))
            }
            return .success(.signal(SignalPlan(pid: pid, force: m.bool("signal.force") ?? false,
                                               started: started, name: m.string("signal.name") ?? "")))
        case "sound":
            let said = m.string("sound.default") ?? ""
            guard let u = Int(said.hasPrefix("pcm") ? String(said.dropFirst(3)) : said) else {
                return .failure(SettingsRefusal(said.isEmpty ? "a sound plan must say which device is the default"
                                                             : "\(said) is not a sound device (pcm0, pcm1 …)"))
            }
            return .success(.sound(SoundPlan(defaultUnit: u)))
        case "wifi":
            let device = m.string("wifi.device") ?? "", interface = m.string("wifi.interface") ?? "wlan0"
            let ssid = m.string("wifi.ssid") ?? ""
            switch m.string("wifi.action") ?? "" {
            case "join":
                return .success(.wifi(WifiPlan(device: device, interface: interface,
                                               action: .join(ssid: ssid, psk: m.string("wifi.psk")))))
            case "forget":
                return .success(.wifi(WifiPlan(device: device, interface: interface, action: .forget(ssid: ssid))))
            case let other:
                return .failure(SettingsRefusal(other.isEmpty ? "a Wi-Fi plan must say join or forget"
                                                             : "\(other) is not join or forget"))
            }
        case "":
            return .failure(SettingsRefusal("the request names no kind of plan"))
        case let other:
            return .failure(SettingsRefusal("there is no \(other) plan (there is: energy, network, power-profile, sound, wifi)"))
        }
    }

    // MARK: - Events

    public static func encode(_ e: SettingsEvent) -> Msg {
        var m = Msg()
        switch e {
        case .starting(let i, let n, let what):
            m.set("event", "starting"); m.set("index", UInt64(i)); m.set("total", UInt64(n)); m.set("what", what)
        case .ok(let i):
            m.set("event", "ok"); m.set("index", UInt64(i))
        case .failed(let i, let what, let why, let ignored):
            m.set("event", "failed"); m.set("index", UInt64(i)); m.set("what", what)
            m.set("why", why); m.set("ignored", ignored)
        case .skipped(let i, let why):
            m.set("event", "skipped"); m.set("index", UInt64(i)); m.set("why", why)
        case .finished(let ok, let error):
            m.set("event", "finished"); m.set("ok", ok); m.set("error", error)
        }
        return m
    }

    public static func decodeEvent(_ m: Msg) -> SettingsEvent? {
        let i = Int(m.uint64("index") ?? 0)
        switch m.string("event") ?? "" {
        case "starting": return .starting(index: i, total: Int(m.uint64("total") ?? 0), what: m.string("what") ?? "")
        case "ok": return .ok(index: i)
        case "failed": return .failed(index: i, what: m.string("what") ?? "", why: m.string("why") ?? "",
                                      ignored: m.bool("ignored") ?? false)
        case "skipped": return .skipped(index: i, why: m.string("why") ?? "")
        case "finished": return .finished(ok: m.bool("ok") ?? false, error: m.string("error") ?? "")
        default: return nil
        }
    }
}


// MARK: - Wi-Fi: what the machine knows, and what a scan found (P14.5)

/// A radio's configuration as rc.conf and wpa_supplicant.conf have it.
public struct WifiKnown: Equatable, Sendable {
    public var device: String
    /// The wlan interface rc makes on it, or nil when `wlans_<device>` is unset.
    public var interface: String?
    /// The networks wpa_supplicant.conf holds, in order.
    public var networks: [String]
    public init(device: String, interface: String?, networks: [String]) {
        self.device = device; self.interface = interface; self.networks = networks
    }
}

extension SettingsWire {
    public static func encode(_ k: WifiKnown, into m: inout Msg) {
        m.set("wifi.device", k.device)
        if let i = k.interface { m.set("wifi.interface", i) }
        m.set("wifi.known.count", UInt64(k.networks.count))
        for (i, n) in k.networks.enumerated() { m.set("wifi.known.\(i)", n) }
    }

    public static func decodeKnown(_ m: Msg) -> WifiKnown {
        let n = Int(m.uint64("wifi.known.count") ?? 0)
        return WifiKnown(device: m.string("wifi.device") ?? "", interface: m.string("wifi.interface"),
                         networks: (0..<n).compactMap { m.string("wifi.known.\($0)") })
    }

    public static func encode(_ nets: [WifiNetwork], into m: inout Msg) {
        m.set("scan.count", UInt64(nets.count))
        for (i, n) in nets.enumerated() {
            m.set("scan.\(i).ssid", n.ssid); m.set("scan.\(i).bssid", n.bssid)
            m.set("scan.\(i).channel", UInt64(max(0, n.channel))); m.set("scan.\(i).signal", "\(n.signal)")
            m.set("scan.\(i).secured", n.secured)
        }
    }

    public static func decodeScan(_ m: Msg) -> [WifiNetwork] {
        (0..<Int(m.uint64("scan.count") ?? 0)).compactMap { i in
            guard let ssid = m.string("scan.\(i).ssid") else { return nil }
            return WifiNetwork(ssid: ssid, bssid: m.string("scan.\(i).bssid") ?? "",
                               channel: Int(m.uint64("scan.\(i).channel") ?? 0),
                               signal: Int(m.string("scan.\(i).signal") ?? "") ?? 0,
                               secured: m.bool("scan.\(i).secured") ?? false)
        }
    }
}
