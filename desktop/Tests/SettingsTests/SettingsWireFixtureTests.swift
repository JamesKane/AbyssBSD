// SettingsWire's cross-language fixtures (docs/RUST.md §3.3). Swift is the
// specification: this test writes the corpus (ABYSS_WIRE_UPDATE=1) and checks
// it; de/settingswire/tests checks the Rust half against the same files.
//
// abyss/tests/wire/settings/<case>.bin is a packed message, and <case>.txt
// names its decoder (plan, event, known, scan) and then what it read. For a
// plan that is the plan, its refusals and, when there are none, the steps
// the helper would run, as `check` renders them: so a Swift pane and a Rust
// helper (or the other way about) agree on what a plan does, not only on
// what it says. `refused "<why>"` is a plan the wire itself refuses. A
// `decode-only` line marks bytes the encoder would not produce.
//
// <case>.in is text the helper parses or edits (a scan, wpa_supplicant.conf,
// sysctl.conf); <case>.txt's first line is the operation, then its result.

import XCTest
import CurrentIPC
@testable import Settings
@testable import SettingsWire

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

final class SettingsWireFixtureTests: XCTestCase {

    static let dir: String = {
        // Tests/SettingsTests/SettingsWireFixtureTests.swift -> desktop/
        var p = "\(#filePath)".split(separator: "/", omittingEmptySubsequences: false).dropLast(3)
        p.append(contentsOf: ["abyss", "tests", "wire", "settings"])
        return p.joined(separator: "/")
    }()

    struct Case {
        let name: String
        let decoder: String
        let bytes: [UInt8]
        var decodeOnly = false
    }

    static let key = "f42c6fc52df0ebef9ebb4b90b38a5f902e83fe1b135a70e23aed762e9710a12e"
    static let hash = "$6$salt$abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ./abcdefgh"

    // MARK: the corpus

    static func plans() -> [(String, SettingsPlan)] {
        func ip(_ s: String) -> IPv4 { IPv4(s)! }
        return [
            ("energy-on", .energy(EnergyPlan(powerd: true, onAC: .maximum, onBattery: .minimum))),
            ("energy-off", .energy(EnergyPlan(powerd: false))),
            ("energy-from-profile", .energy(EnergyPlan(powerd: true, modesFromProfile: true))),
            ("power-profile", .powerProfile(PowerProfilePlan(profile: .powerSaver))),
            ("network-manual", .network(NetworkPlan(interface: "em0",
                ipv4: .manual(address: ip("10.0.0.5"), prefix: 24, router: ip("10.0.0.1")),
                dns: [ip("1.1.1.1"), ip("9.9.9.9")]))),
            ("network-manual-no-router", .network(NetworkPlan(interface: "vtnet0",
                ipv4: .manual(address: ip("192.168.7.9"), prefix: 23, router: nil)))),
            ("network-dhcp", .network(NetworkPlan(interface: "igc0", ipv4: .dhcp))),
            ("network-refused", .network(NetworkPlan(interface: "lo0",
                ipv4: .manual(address: ip("10.0.0.255"), prefix: 24, router: ip("10.0.1.1")),
                dns: ["1.1.1.1", "1.0.0.1", "8.8.8.8", "224.0.0.1"].map(ip)))),
            ("sound", .sound(SoundPlan(defaultUnit: 3))),
            ("sound-negative", .sound(SoundPlan(defaultUnit: -1))),
            ("wifi-join", .wifi(WifiPlan(device: "iwn0", action: .join(ssid: "Café Wi-Fi", psk: key)))),
            ("wifi-open", .wifi(WifiPlan(device: "wtap1", interface: "wlan1", action: .join(ssid: "Library", psk: nil)))),
            ("wifi-forget", .wifi(WifiPlan(device: "iwn0", action: .forget(ssid: "Café Wi-Fi")))),
            ("wifi-evil-ssid", .wifi(WifiPlan(device: "iwn0", action: .join(ssid: "a\"\n}\nnetwork={", psk: nil)))),
            ("wifi-refused", .wifi(WifiPlan(device: "lo", interface: "em0",
                                            action: .join(ssid: String(repeating: "x", count: 33), psk: "password")))),
            ("signal-quit", .signal(SignalPlan(pid: 4242, force: false, started: 1_700_000_000, name: "sleep"))),
            ("signal-force", .signal(SignalPlan(pid: 77, force: true, started: -5, name: "Ünïcode ✓"))),
            ("signal-init", .signal(SignalPlan(pid: 1, force: false, started: 0, name: "init"))),
            ("volume-snapshot", .volume(VolumePlan(.snapshot(dataset: "zroot/home", name: "abyss-2026-10-01")))),
            ("volume-rollback", .volume(VolumePlan(.rollback(snapshot: "zroot/home@s1")))),
            ("volume-mount", .volume(VolumePlan(.mountDataset("zroot/data")))),
            ("volume-unmount-dataset", .volume(VolumePlan(.unmountDataset("zroot/data")))),
            ("volume-unmount", .volume(VolumePlan(.unmount(path: "/media/stick")))),
            ("volume-system-mount", .volume(VolumePlan(.unmount(path: "/usr")))),
            ("volume-bad-name", .volume(VolumePlan(.snapshot(dataset: "zroot/../etc", name: "-rf")))),
            ("accounts-add", .accounts(AccountPlan(.add(name: "ada", fullName: "Ada Lovelace", passwordHash: hash, admin: true)))),
            ("accounts-add-user", .accounts(AccountPlan(.add(name: "bob", fullName: "", passwordHash: hash, admin: false)))),
            ("accounts-add-refused", .accounts(AccountPlan(.add(name: "Root", fullName: "a:b", passwordHash: "hunter2", admin: false)))),
            ("accounts-add-reserved", .accounts(AccountPlan(.add(name: "root", fullName: "", passwordHash: hash, admin: false)))),
            ("accounts-delete", .accounts(AccountPlan(.delete(name: "ada", removeHome: false)))),
            ("accounts-delete-home", .accounts(AccountPlan(.delete(name: "ada", removeHome: true)))),
            ("accounts-autologin", .accounts(AccountPlan(.autoLogin("ada")))),
            ("accounts-autologin-off", .accounts(AccountPlan(.autoLogin(nil)))),
        ]
    }

    static func valid() -> [Case] {
        var cases: [Case] = plans().map { name, plan in
            var m = Msg(); SettingsWire.encode(plan, into: &m)
            return Case(name: "plan-" + name, decoder: "plan", bytes: m.pack())
        }
        let events: [(String, SettingsEvent)] = [
            ("starting", .starting(index: 1, total: 3, what: "set powerd_enable=\"YES\" in rc.conf")),
            ("ok", .ok(index: 1)),
            ("failed", .failed(index: 2, what: "stop the powerd service", why: "not running", ignored: true)),
            ("skipped", .skipped(index: 0, why: "write-only")),
            ("finished", .finished(ok: false, error: "sysrc: not found")),
        ]
        cases += events.map { Case(name: "event-" + $0.0, decoder: "event", bytes: SettingsWire.encode($0.1).pack()) }
        var k = Msg()
        SettingsWire.encode(WifiKnown(device: "wtap1", interface: "wlan0", networks: ["abyss-lab", "Café \"Wi-Fi\""]), into: &k)
        cases.append(Case(name: "known-two", decoder: "known", bytes: k.pack()))
        var k0 = Msg()
        SettingsWire.encode(WifiKnown(device: "iwn0", interface: nil, networks: []), into: &k0)
        cases.append(Case(name: "known-none", decoder: "known", bytes: k0.pack()))
        var s = Msg()
        SettingsWire.encode([WifiNetwork(ssid: "x y", bssid: "00:11:22:33:44:55", channel: 6, signal: -48, secured: true),
                             WifiNetwork(ssid: "Ü", bssid: "", channel: 0, signal: 12, secured: false)], into: &s)
        cases.append(Case(name: "scan-two", decoder: "scan", bytes: s.pack()))
        return cases
    }

    static func handBuilt() -> [Case] {
        var cases: [Case] = []
        func only(_ name: String, _ decoder: String, _ build: (inout Msg) -> Void) {
            var m = Msg(); build(&m)
            cases.append(Case(name: name, decoder: decoder, bytes: m.pack(), decodeOnly: true))
        }
        func plan(_ name: String, _ fields: [(String, String)], _ build: (inout Msg) -> Void = { _ in }) {
            only("plan-" + name, "plan") { m in
                for (k, v) in fields { m.set(k, v) }
                build(&m)
            }
        }
        plan("no-kind", [])
        plan("unknown-kind", [("kind", "displays")])
        plan("energy-no-powerd", [("kind", "energy")])
        plan("energy-bad-ac", [("kind", "energy"), ("energy.ac", "turbo")]) { $0.set("energy.powerd", true) }
        plan("energy-bad-battery", [("kind", "energy"), ("energy.battery", "eco")]) { $0.set("energy.powerd", true) }
        plan("energy-defaults", [("kind", "energy")]) { $0.set("energy.powerd", true) }
        plan("power-profile-bad", [("kind", "power-profile"), ("power-profile", "turbo")])
        plan("network-bad-dns", [("kind", "network"), ("network.mode", "dhcp"), ("network.dns", "1.1.1.1  example.com")])
        plan("network-no-mode", [("kind", "network"), ("network.interface", "em0")])
        plan("network-bad-mode", [("kind", "network"), ("network.mode", "static")])
        plan("network-no-address", [("kind", "network"), ("network.mode", "manual")])
        plan("network-bad-mask", [("kind", "network"), ("network.mode", "manual"),
                                  ("network.address", "10.0.0.5"), ("network.netmask", "255.0.255.0")])
        plan("network-no-mask", [("kind", "network"), ("network.mode", "manual"), ("network.address", "10.0.0.5")])
        plan("network-bad-router", [("kind", "network"), ("network.interface", "em0"), ("network.mode", "manual"),
                                    ("network.address", "10.0.0.5"), ("network.netmask", "255.255.255.0"),
                                    ("network.router", "gateway")])
        plan("network-empty-router", [("kind", "network"), ("network.interface", "em0"), ("network.mode", "manual"),
                                      ("network.address", "10.0.0.5"), ("network.netmask", "255.255.255.0"),
                                      ("network.router", "")])
        plan("network-octal", [("kind", "network"), ("network.mode", "manual"),
                               ("network.address", "10.0.0.05"), ("network.netmask", "255.255.255.0")])
        plan("accounts-add-no-hash", [("kind", "accounts"), ("accounts.action", "add"), ("accounts.name", "ada")])
        plan("accounts-delete-no-name", [("kind", "accounts"), ("accounts.action", "delete")])
        plan("accounts-no-action", [("kind", "accounts")])
        plan("accounts-bad-action", [("kind", "accounts"), ("accounts.action", "rename")])
        plan("accounts-add-defaults", [("kind", "accounts"), ("accounts.action", "add"), ("accounts.name", "ada"),
                                       ("accounts.hash", hash)])
        plan("volume-snapshot-no-name", [("kind", "volume"), ("volume.action", "snapshot"), ("volume.dataset", "p/d")])
        plan("volume-rollback-none", [("kind", "volume"), ("volume.action", "rollback")])
        plan("volume-mount-none", [("kind", "volume"), ("volume.action", "mount"), ("volume.path", "/x")])
        plan("volume-unmount-none", [("kind", "volume"), ("volume.action", "unmount")])
        plan("volume-unmount-both", [("kind", "volume"), ("volume.action", "unmount"),
                                     ("volume.dataset", "p/d"), ("volume.path", "/media/x")])
        plan("volume-no-action", [("kind", "volume")])
        plan("volume-bad-action", [("kind", "volume"), ("volume.action", "destroy")])
        plan("signal-bad-pid", [("kind", "signal"), ("signal.pid", "four"), ("signal.started", "1")])
        plan("signal-no-started", [("kind", "signal"), ("signal.pid", "42")])
        plan("signal-pid-too-big", [("kind", "signal"), ("signal.pid", "2147483648"), ("signal.started", "1")])
        plan("signal-signed", [("kind", "signal"), ("signal.pid", "+42"), ("signal.started", "-1"), ("signal.name", "x")])
        plan("sound-pcm", [("kind", "sound"), ("sound.default", "pcm3")])
        plan("sound-bad", [("kind", "sound"), ("sound.default", "speakers")])
        plan("sound-empty", [("kind", "sound")])
        plan("sound-pcm-only", [("kind", "sound"), ("sound.default", "pcm")])
        plan("wifi-no-action", [("kind", "wifi"), ("wifi.device", "iwn0")])
        plan("wifi-bad-action", [("kind", "wifi"), ("wifi.action", "scan")])
        plan("wifi-defaults", [("kind", "wifi"), ("wifi.action", "forget")])
        plan("wifi-plus-interface", [("kind", "wifi"), ("wifi.device", "iwn0"), ("wifi.interface", "wlan+0"),
                                     ("wifi.ssid", "x"), ("wifi.action", "forget")])
        plan("kind-not-text", []) { $0.set("kind", UInt64(1)) }

        only("event-unknown", "event") { $0.set("event", "progress"); $0.set("index", UInt64(1)) }
        only("event-empty", "event") { _ in }
        only("event-defaults", "event") { $0.set("event", "failed") }
        only("known-sparse", "known") { m in
            m.set("wifi.device", "iwn0"); m.set("wifi.known.count", UInt64(3))
            m.set("wifi.known.0", "first"); m.set("wifi.known.2", "third"); m.set("wifi.known.3", "past the count")
            m.set("wifi.known.1", UInt64(7))
        }
        only("scan-sparse", "scan") { m in
            m.set("scan.count", UInt64(3))
            m.set("scan.0.bssid", "no ssid, so not a network")
            m.set("scan.1.ssid", "one"); m.set("scan.1.signal", "strong")
            m.set("scan.2.ssid", "two"); m.set("scan.2.channel", UInt64(11)); m.set("scan.2.signal", "-70")
        }
        return cases
    }

    /// Text in, for the helper's parsers and editors: (name, op line, input).
    static func texts() -> [(String, String, String)] {
        let scan = """
        SSID/MESH ID                      BSSID              CHAN RATE    S:N     INT CAPS
        abyss-lab                         00:98:9a:98:96:97    1   11M   10:10    100 EP   RSN
        Café Wi-Fi 5G                     aa:bb:cc:dd:ee:01   36   54M  -61:-95   100 EP   RSN HTCAP WME
        Café Wi-Fi 5G                     aa:bb:cc:dd:ee:02   40   54M  -48:-95   100 EP   RSN HTCAP WME
        Library                           aa:bb:cc:dd:ee:03    6   54M  -70:-95   100 E    WME
        Privacy only                      aa:bb:cc:dd:ee:04   11   54M  -70:-95   100 EP
        Tied                              aa:bb:cc:dd:ee:05   11   54M  -70:-95   100 E
        Tied                              aa:bb:cc:dd:ee:06   12   54M  -70:-95   100 E
        short row                         aa:bb:cc:dd:ee:07   11   54M
                                          aa:bb:cc:dd:ee:08   11   54M  -70:-95   100 E
        bad channel                       aa:bb:cc:dd:ee:09   x    54M  -70:-95   100 E

        """
        let doubled = """
        SSID/MESH ID                      BSSID              CHAN RATE    S:N     INT CAPS
        Doubled colon                     aa::bb:cc:dd:ee:ff   1   11M   10:10    100 EP   RSN
        Signed hex                        +a:bb:cc:dd:ee:ff    1   11M   10:10    100 EP   RSN
        """
        let hand = "# by hand\nctrl_interface=/var/run/wpa_supplicant\nnetwork={\n\tssid=\"Home\"\n\tpsk=\"hunter22\"\n}\nnetwork={\n\tssid=\"Work\"\n\tkey_mgmt=NONE\n}\n"
        let twice = "network={\n\tssid=\"Home\"\n}\nnetwork={\n\tssid=486f6d65\n}\nnetwork={\n\tssid=\"Work\"\n}\n\n\n"
        let unterminated = "update_config=1\nnetwork={\n\tssid=\"Cut\"\n\tkey_mgmt=NONE"
        let oddHex = "network={\n\tssid=486f6d6\n}\nnetwork={\n\tssid=+f\n}\nnetwork={\n\tssid=\"\n}\n"
        let sysctl = "# kernel settings\nsecurity.bsd.see_other_uids=0\n hw.snd.default_unit = 0  # the card\nkern.foo=1\nhw.snd.default_unit=3\n"
        let k = Self.key
        return [
            ("scan-ifconfig", "scan", scan),
            ("scan-odd-bssids", "scan", doubled),
            ("scan-empty", "scan", "SSID/MESH ID  BSSID  CHAN\n"),
            ("wpa-join-replaces", "wpa-edit \(q("Home")) \(q("ssid=\(WpaConf.hex("Home"))\npsk=\(k)"))", hand),
            ("wpa-join-appends", "wpa-edit \(q("Café")) \(q("ssid=\(WpaConf.hex("Café"))\n\nkey_mgmt=NONE\n"))", hand),
            ("wpa-forget", "wpa-edit \(q("Home")) none", hand),
            ("wpa-forget-missing", "wpa-edit \(q("Nowhere")) none", hand),
            ("wpa-twice", "wpa-edit \(q("Home")) \(q("ssid=486f6d65\nkey_mgmt=NONE"))", twice),
            ("wpa-evil", "wpa-edit \(q("a\"\n}\nnetwork={ssid=\"x")) \(q("ssid=\(WpaConf.hex("a\"\n}\nnetwork={ssid=\"x"))\nkey_mgmt=NONE"))", ""),
            ("wpa-unterminated", "wpa-edit \(q("New")) \(q("ssid=4e6577\nkey_mgmt=NONE"))", unterminated),
            ("wpa-odd-hex", "wpa-edit \(q("x")) none", oddHex),
            ("wpa-crlf", "wpa-edit \(q("Work")) none", hand.replacingOccurrences(of: "\n", with: "\r\n")),
            ("sysctl-set", "sysctl-edit \(q("hw.snd.default_unit")) \(q("1"))", sysctl),
            ("sysctl-remove", "sysctl-edit \(q("hw.snd.default_unit")) none", sysctl),
            ("sysctl-append", "sysctl-edit \(q("hw.snd.default_unit")) \(q("2"))", "#hw.snd.default_unit=5\nkern.foo=1"),
            ("sysctl-empty", "sysctl-edit \(q("a.b")) \(q("2"))", ""),
            ("sysctl-crlf", "sysctl-edit \(q("kern.foo")) \(q("2"))", "kern.foo=1\r\nkern.bar=1\r\n"),
        ]
    }

    // MARK: the text form

    static func q(_ s: String) -> String {
        var out = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            default:
                if u.value < 0x20 || u.value == 0x7f { out += "\\u{\(String(u.value, radix: 16))}" }
                else { out.unicodeScalars.append(u) }
            }
        }
        return out + "\""
    }

    static func b(_ v: Bool) -> String { v ? "1" : "0" }

    static func text(_ p: SettingsPlan) -> String {
        switch p {
        case .energy(let e):
            return "energy powerd=\(b(e.powerd)) ac=\(e.onAC.rawValue) battery=\(e.onBattery.rawValue) from-profile=\(b(e.modesFromProfile))"
        case .powerProfile(let pp):
            return "power-profile \(pp.profile.rawValue)"
        case .network(let n):
            let dns = "dns=" + n.dns.map(\.description).joined(separator: ",")
            switch n.ipv4 {
            case .dhcp: return "network \(q(n.interface)) dhcp \(dns)"
            case .manual(let a, let p, let r):
                return "network \(q(n.interface)) manual \(a)/\(p) router=\(r?.description ?? "none") \(dns)"
            }
        case .sound(let s):
            return "sound \(s.defaultUnit)"
        case .wifi(let w):
            switch w.action {
            case .join(let ssid, let psk):
                return "wifi \(q(w.device)) \(q(w.interface)) join \(q(ssid)) " + (psk.map { "psk=\(q($0))" } ?? "open")
            case .forget(let ssid):
                return "wifi \(q(w.device)) \(q(w.interface)) forget \(q(ssid))"
            }
        case .signal(let s):
            return "signal \(s.pid) force=\(b(s.force)) started=\(s.started) \(q(s.name))"
        case .volume(let v):
            switch v.action {
            case .snapshot(let ds, let name): return "volume snapshot \(q(ds)) \(q(name))"
            case .rollback(let snap): return "volume rollback \(q(snap))"
            case .mountDataset(let ds): return "volume mount \(q(ds))"
            case .unmountDataset(let ds): return "volume unmount-dataset \(q(ds))"
            case .unmount(let path): return "volume unmount \(q(path))"
            }
        case .accounts(let a):
            switch a.action {
            case .add(let n, let f, let h, let admin): return "accounts add \(q(n)) \(q(f)) \(q(h)) admin=\(b(admin))"
            case .delete(let n, let r): return "accounts delete \(q(n)) remove-home=\(b(r))"
            case .autoLogin(let n): return "accounts autologin \(n.map(q) ?? "none")"
            }
        }
    }

    static func text(_ e: SettingsEvent?) -> String {
        switch e {
        case nil: return "none"
        case .starting(let i, let n, let what)?: return "starting \(i) \(n) \(q(what))"
        case .ok(let i)?: return "ok \(i)"
        case .failed(let i, let what, let why, let ignored)?: return "failed \(i) \(q(what)) \(q(why)) ignored=\(b(ignored))"
        case .skipped(let i, let why)?: return "skipped \(i) \(q(why))"
        case .finished(let ok, let error)?: return "finished \(b(ok)) \(q(error))"
        }
    }

    static func text(_ n: WifiNetwork) -> String {
        "network \(q(n.ssid)) \(q(n.bssid)) \(n.channel) \(n.signal) secured=\(b(n.secured))"
    }

    /// What `decoder` reads from `bin`, and the bytes the encoder makes of
    /// that (nil when it read nothing to encode).
    static func decode(_ decoder: String, _ bin: [UInt8]) -> (String, [UInt8]?) {
        var out = decoder + "\n"
        guard let m = try? Msg.unpack(bin) else { return (out + "malformed\n", nil) }
        switch decoder {
        case "plan":
            switch SettingsWire.decodePlan(m) {
            case .failure(let r):
                return (out + "refused \(q(r.message))\n", nil)
            case .success(let p):
                out += text(p) + "\n"
                let problems = Settings.problems(p)
                for r in problems { out += "problem \(q(r.message))\n" }
                if problems.isEmpty, let steps = try? Settings.compile(p) {
                    out += "steps\n" + Settings.render(steps) + "\n"
                }
                var e = Msg(); SettingsWire.encode(p, into: &e)
                return (out, e.pack())
            }
        case "event":
            let e = SettingsWire.decodeEvent(m)
            return (out + text(e) + "\n", e.map { SettingsWire.encode($0).pack() })
        case "known":
            let k = SettingsWire.decodeKnown(m)
            out += "device \(q(k.device))\ninterface \(k.interface.map(q) ?? "none")\n"
            for n in k.networks { out += "network \(q(n))\n" }
            var e = Msg(); SettingsWire.encode(k, into: &e)
            return (out, e.pack())
        case "scan":
            let nets = SettingsWire.decodeScan(m)
            for n in nets { out += text(n) + "\n" }
            var e = Msg(); SettingsWire.encode(nets, into: &e)
            return (out, e.pack())
        default:
            return (out + "no decoder\n", nil)
        }
    }

    /// `op` applied to `input`.
    static func run(_ op: String, _ input: String) -> String {
        var out = op + "\n"
        if op == "scan" {
            for n in WifiScan.parse(input) { out += text(n) + "\n" }
            return out
        }
        // `<op> "<key>" "<value>"|none`
        let rest = String(op.drop { $0 != " " }.dropFirst())
        let (key, after) = unq(rest)
        let value: String? = after == "none" ? nil : unq(after).0
        if op.hasPrefix("wpa-edit ") {
            for n in WpaConf.networks(input) { out += "before \(q(n))\n" }
            let edited = WpaConf.edit(input, ssid: key, body: value)
            out += "---\n" + edited + "---\n"
            for n in WpaConf.networks(edited) { out += "after \(q(n))\n" }
        } else {
            out += "value \(Settings.sysctlConfValue(input, key: key).map(q) ?? "none")\n"
            let edited = Settings.editSysctlConf(input, key: key, value: value)
            out += "---\n" + edited + "\n---\n"
            out += "value \(Settings.sysctlConfValue(edited, key: key).map(q) ?? "none")\n"
        }
        return out
    }

    /// `q` undone, and what follows it.
    static func unq(_ s: String) -> (String, String) {
        let u = Array(s.unicodeScalars)
        var out = String.UnicodeScalarView(), i = 1
        while i < u.count {
            let c = u[i]; i += 1
            switch c {
            case "\"":
                while i < u.count, u[i] == " " { i += 1 }
                return (String(out), String(String.UnicodeScalarView(u[i...])))
            case "\\":
                let e = u[i]; i += 1
                switch e {
                case "n": out.append("\n")
                case "u":
                    var hex = ""
                    i += 1                                              // {
                    while u[i] != "}" { hex.unicodeScalars.append(u[i]); i += 1 }
                    i += 1
                    out.append(Unicode.Scalar(UInt32(hex, radix: 16)!)!)
                default: out.append(e)
                }
            default:
                out.append(c)
            }
        }
        return (String(out), "")
    }

    // MARK: files

    func write(_ path: String, _ bytes: [UInt8]) throws {
        guard let f = fopen(path, "wb") else { throw CurrentError.system(errno, "fopen \(path)") }
        defer { fclose(f) }
        _ = bytes.withUnsafeBufferPointer { fwrite($0.baseAddress, 1, bytes.count, f) }
    }

    func read(_ path: String) -> [UInt8]? {
        guard let f = fopen(path, "rb") else { return nil }
        defer { fclose(f) }
        var out: [UInt8] = []
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = buf.withUnsafeMutableBufferPointer { fread($0.baseAddress, 1, 65536, f) }
            if n <= 0 { break }
            out += buf[0..<n]
        }
        return out
    }

    func readText(_ path: String) -> String? { read(path).map { String(decoding: $0, as: UTF8.self) } }

    // MARK: the test

    func testTheFixturesAreWhatSwiftReadsAndWrites() throws {
        let dir = Self.dir
        let cases = Self.valid() + Self.handBuilt()
        let texts = Self.texts()
        XCTAssertEqual(Set(cases.map(\.name) + texts.map(\.0)).count, cases.count + texts.count, "case names are unique")
        if getenv("ABYSS_WIRE_UPDATE") != nil {
            _ = mkdir(String(dir.dropLast("/settings".count)), 0o755)   // abyss/tests/wire
            _ = mkdir(dir, 0o755)
            for c in cases {
                let (txt, _) = Self.decode(c.decoder, c.bytes)
                try write("\(dir)/\(c.name).bin", c.bytes)
                try write("\(dir)/\(c.name).txt", Array(((c.decodeOnly ? "decode-only\n" : "") + txt).utf8))
            }
            for (name, op, input) in texts {
                try write("\(dir)/\(name).in", Array(input.utf8))
                try write("\(dir)/\(name).txt", Array(Self.run(op, input).utf8))
            }
        }

        // Check every case on disk, whoever wrote it.
        for c in cases {
            guard let bin = read("\(dir)/\(c.name).bin"), let txt = readText("\(dir)/\(c.name).txt") else {
                XCTFail("\(c.name): missing; run with ABYSS_WIRE_UPDATE=1"); continue
            }
            let decodeOnly = txt.hasPrefix("decode-only\n")
            let expected = decodeOnly ? String(txt.dropFirst("decode-only\n".count)) : txt
            let (got, encoded) = Self.decode(String(expected.prefix { $0 != "\n" }), bin)
            XCTAssertEqual(got, expected, "\(c.name): decoding the bytes")
            if !decodeOnly {
                XCTAssertEqual(encoded, bin, "\(c.name): encoding what was decoded")
            }
        }
        for (name, _, _) in texts {
            guard let input = readText("\(dir)/\(name).in"), let txt = readText("\(dir)/\(name).txt") else {
                XCTFail("\(name): missing; run with ABYSS_WIRE_UPDATE=1"); continue
            }
            XCTAssertEqual(Self.run(String(txt.prefix { $0 != "\n" }), input), txt, name)
        }
    }
}
