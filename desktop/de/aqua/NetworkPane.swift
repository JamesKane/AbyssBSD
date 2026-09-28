// NetworkPane — System Preferences' Network pane: a wired interface, by DHCP
// or by hand, and its name servers (PHASE14 P14.4c).
//
// Two sources, shown side by side and never confused:
//
//   - **Status** is the kernel's, now (`Vents.Network`, P14.4b) — read without
//     privilege and redrawn when the routing socket says something changed. It
//     is what a DHCP lease or a cable pulled out actually did.
//   - **Configure** is rc.conf's, read through the root helper (P14.4a) — what
//     the machine will do at the next boot, and what Apply Now writes.
//
// The pane links `SettingsWire` and not `SettingsRun`, as the installer links
// `InstallWire`: it can ask the helper for a change, and it cannot run `sysrc`.
// What it sends is what was typed; the helper decides what is an address, and
// its refusals are shown in its words rather than re-invented here.

import AquaDraw
import CurrentIPC
import Settings
import SettingsWire
import Vents

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

// MARK: - The form

public enum NetworkField: String, CaseIterable, Sendable {
    case address, netmask, router, dns

    public var label: String {
        switch self {
        case .address: return "IP Address:"
        case .netmask: return "Subnet Mask:"
        case .router: return "Router:"
        case .dns: return "DNS Servers:"
        }
    }
}

/// What the Configure half says, as typed.
public struct NetworkForm: Equatable, Sendable {
    public var interface: String
    public var dhcp = true
    public var values: [NetworkField: String] = [:]
    public var focus: NetworkField?

    public init(interface: String) { self.interface = interface }

    /// The form rc.conf's plan fills in.
    public static func from(_ plan: NetworkPlan) -> NetworkForm {
        var f = NetworkForm(interface: plan.interface)
        f.values[.dns] = plan.dns.map(\.description).joined(separator: " ")
        if case .manual(let a, let p, let r) = plan.ipv4 {
            f.dhcp = false
            f.values[.address] = a.description
            f.values[.netmask] = IPv4.mask(prefix: p).description
            f.values[.router] = r?.description ?? ""
        }
        return f
    }

    public subscript(_ f: NetworkField) -> String { values[f] ?? "" }

    /// The fields that mean something in this mode: with DHCP the lease says
    /// the address, mask and router, and only the name servers are yours.
    public var editable: [NetworkField] { dhcp ? [.dns] : NetworkField.allCases }

    public mutating func type(_ s: String) {
        guard let f = focus, !s.isEmpty, s.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7f })
        else { return }
        values[f, default: ""] += s
    }

    public mutating func backspace() {
        guard let f = focus, let v = values[f], !v.isEmpty else { return }
        values[f] = String(v.dropLast())
    }

    /// Tab: the next editable field, round again after the last.
    public mutating func moveFocus(_ delta: Int) {
        let e = editable
        guard !e.isEmpty else { focus = nil; return }
        guard let f = focus, let i = e.firstIndex(of: f) else { focus = e[delta < 0 ? e.count - 1 : 0]; return }
        focus = e[((i + delta) % e.count + e.count) % e.count]
    }

    public mutating func setDHCP(_ on: Bool) {
        dhcp = on
        if let f = focus, !editable.contains(f) { focus = nil }
    }

    /// The request, as `abyss-settingsctl` would send it for the same fields.
    public func request(_ method: String) -> Msg {
        var m = Msg()
        m.set("method", method)
        m.set("kind", "network")
        m.set("interface", interface)
        m.set("network.interface", interface)
        m.set("network.mode", dhcp ? "dhcp" : "manual")
        if !dhcp {
            for f in [NetworkField.address, .netmask, .router] { m.set("network.\(f.rawValue)", trimmed(self[f])) }
        }
        // Commas and runs of spaces are how people type lists; the wire's list is spaces.
        let dns = self[.dns].split(whereSeparator: { $0 == " " || $0 == "," }).joined(separator: " ")
        m.set("network.dns", dns)
        return m
    }

    /// One line for a log: what would be sent.
    public var summary: String {
        var s = "\(interface) " + (dhcp ? "dhcp" : "manual address=\(self[.address]) netmask=\(self[.netmask]) router=\(self[.router])")
        s += " dns=\(self[.dns])"
        return s
    }
}

private func trimmed(_ s: String) -> String {
    var t = Substring(s)
    while t.first == " " { t = t.dropFirst() }
    while t.last == " " { t = t.dropLast() }
    return String(t)
}

// MARK: - What the pane says

public enum NetworkWords {
    /// The interfaces this pane offers: ones with an Ethernet address, not
    /// the loopback, and not wireless (`wlan0`, `wlp3s0` — joining a network
    /// is more than an address, and is its own pane). The first five, which
    /// is what fits in a row. Whether the helper will accept a name is the
    /// helper's to say, in its words, when asked.
    public static func choosable(_ all: [Vents.Network.Interface]) -> [Vents.Network.Interface] {
        Array(all.filter { !$0.loopback && $0.mac != nil && !$0.name.hasPrefix("wl") }.prefix(5))
    }

    /// The Status box's lines for `name`, as label and value.
    public static func status(_ s: Vents.Network.Status, interface name: String) -> [(String, String)] {
        guard let i = s.interfaces.first(where: { $0.name == name }) else {
            return [("Status:", "\(name) is not on this machine now")]
        }
        let state: String
        if !i.up { state = "Turned off" }
        else {
            switch i.link {
            case .up: state = i.ipv4.isEmpty ? "Connected, with no IPv4 address" : "Connected"
            case .down: state = "Cable unplugged"
            case .unknown: state = "On (the link state is unknown)"
            }
        }
        let router = s.router.flatMap { $0.interface == name ? $0.address : nil }
        return [
            ("Status:", state),
            ("IPv4 Address:", i.ipv4.isEmpty ? "none" : i.ipv4.map { "\($0.address)/\($0.prefix)" }.joined(separator: ", ")),
            ("Router:", router ?? "none through \(name)"),
            ("DNS Servers:", s.nameServers.isEmpty ? "none" : s.nameServers.joined(separator: " ")),
            ("Ethernet Address:", i.mac ?? "none"),
        ]
    }

    /// The status as one line, for the log a test reads.
    public static func statusLine(_ s: Vents.Network.Status, interface name: String) -> String {
        guard let i = s.interfaces.first(where: { $0.name == name }) else { return "\(name) absent" }
        return "\(name) \(i.up ? "up" : "down") link \(i.link.rawValue) ipv4 "
            + (i.ipv4.isEmpty ? "none" : i.ipv4.map { "\($0.address)/\($0.prefix)" }.joined(separator: ","))
            + " router " + (s.router.map { "\($0.address) via \($0.interface)" } ?? "none")
            + " dns " + (s.nameServers.isEmpty ? "none" : s.nameServers.joined(separator: ","))
    }

    /// What an apply came to, in a sentence for the pane.
    public static func outcome(ok: Bool, error: String, skipped: [String]) -> String {
        if !ok { return "Not applied: \(error)" }
        if let why = skipped.first { return "Saved, and not put into effect (\(why))." }
        return "Applied."
    }
}

// MARK: - Talking to the helper

public enum NetworkClient {
    /// rc.conf's configuration for `interface`, or the helper's reason there isn't one.
    public static func read(_ interface: String) -> Result<NetworkPlan, SettingsRefusal> {
        switch SettingsClient.read("network", interface: interface) {
        case .success(.network(let n)): return .success(n)
        case .success: return .failure(SettingsRefusal("the helper answered with another kind of plan"))
        case .failure(let r): return .failure(r)
        }
    }

    /// Start an apply; the socket goes into the run loop, as the installer's
    /// does — a pane that blocks while the network restarts stops painting.
    public static func begin(_ form: NetworkForm) -> Int32? { SettingsClient.begin(form.request("apply")) }

    public static func next(on sock: Int32) -> SettingsEvent? { SettingsClient.next(on: sock) }
}

// MARK: - Layout (paint and hit-test read this, §2.9)

public struct NetworkLayout: Equatable, Sendable {
    public struct Row: Equatable, Sendable {
        public let value: String
        public let hit: Rect
        public let control: Rect
    }
    public var interfaces: [Row] = []
    public var status = Rect(0, 0, 0, 0)
    public var dhcp = Row(value: "dhcp", hit: Rect(0, 0, 0, 0), control: Rect(0, 0, 0, 0))
    public var manual = Row(value: "manual", hit: Rect(0, 0, 0, 0), control: Rect(0, 0, 0, 0))
    public var fields: [NetworkField: Rect] = [:]
    public var labelRight = 0.0
    public var revert = Rect(0, 0, 0, 0)
    public var apply = Rect(0, 0, 0, 0)
    public var noteBaseline = 0.0
    public var showBaseline = 0.0
    public var configureBaseline = 0.0
}

public func networkLayout(body: Rect, interfaces: [String]) -> NetworkLayout {
    var l = NetworkLayout()
    l.labelRight = body.x + 170
    let x = l.labelRight + 12
    var y = body.y + 24
    l.showBaseline = y + 15
    var ix = x
    for name in interfaces {
        l.interfaces.append(.init(value: name, hit: Rect(ix, y, 100, 22), control: Rect(ix, y + 3, 16, 16)))
        ix += 104
    }
    y += 36
    l.status = Rect(body.x + 40, y, body.w - 80, 5 * 20 + 30)
    y += l.status.h + 18
    l.configureBaseline = y + 15
    l.dhcp = .init(value: "dhcp", hit: Rect(x, y, 200, 22), control: Rect(x, y + 3, 16, 16))
    l.manual = .init(value: "manual", hit: Rect(x, y + 22, 200, 22), control: Rect(x, y + 25, 16, 16))
    y += 56
    for f in NetworkField.allCases {
        l.fields[f] = Rect(x, y, f == .dns ? 300 : 180, 24)
        y += 32
    }
    y += 10
    let right = body.x + body.w - 40
    l.apply = Rect(right - 110, y, 110, 24)
    l.revert = Rect(right - 110 - 12 - 90, y, 90, 24)
    l.noteBaseline = y + 50
    return l
}

public enum NetworkHit: Equatable, Sendable {
    case interface(String)
    case mode(dhcp: Bool)
    case field(NetworkField)
    case revert, apply
}

public func networkHit(_ l: NetworkLayout, form: NetworkForm, x: Double, y: Double) -> NetworkHit? {
    if let r = l.interfaces.first(where: { $0.hit.contains(x, y) }) { return .interface(r.value) }
    if l.dhcp.hit.contains(x, y) { return .mode(dhcp: true) }
    if l.manual.hit.contains(x, y) { return .mode(dhcp: false) }
    for f in form.editable where l.fields[f]?.contains(x, y) == true { return .field(f) }
    if l.revert.contains(x, y) { return .revert }
    if l.apply.contains(x, y) { return .apply }
    return nil
}

// MARK: - Paint

public func paintNetworkPane(_ cr: OpaquePointer, _ l: NetworkLayout, status: Vents.Network.Status,
                             form: NetworkForm?, note: String, busy: Bool) {
    func heading(_ s: String, _ baseline: Double) {
        let w = Draw.textWidth(cr, s, size: 13)
        Draw.textLeft(cr, s, x: l.labelRight - w, baselineY: baseline, color: Theme.bodyText, size: 13)
    }
    heading("Show:", l.showBaseline)
    guard let form else {
        Draw.textLeft(cr, "This machine has no wired interface to configure.", x: l.labelRight + 12,
                      baselineY: l.showBaseline, color: Theme.secondaryText, size: 13)
        return
    }
    for r in l.interfaces {
        Draw.radioButton(cr, cx: r.control.x + 8, cy: r.control.y + 8, radius: 7, selected: r.value == form.interface)
        Draw.textLeft(cr, r.value, x: r.control.x + 24, baselineY: r.control.y + 12, color: Theme.bodyText, size: 13)
    }

    Draw.groupBox(cr, l.status, title: "Status")
    var y = l.status.y + 30
    for (label, value) in NetworkWords.status(status, interface: form.interface) {
        let w = Draw.textWidth(cr, label, size: 12)
        Draw.textLeft(cr, label, x: l.labelRight - w, baselineY: y, color: Theme.secondaryText, size: 12)
        Draw.textLeft(cr, value, x: l.labelRight + 12, baselineY: y, color: Theme.bodyText, size: 12)
        y += 20
    }

    heading("Configure IPv4:", l.configureBaseline)
    for (row, on, text) in [(l.dhcp, form.dhcp, "Using DHCP"), (l.manual, !form.dhcp, "Manually")] {
        Draw.radioButton(cr, cx: row.control.x + 8, cy: row.control.y + 8, radius: 7, selected: on)
        Draw.textLeft(cr, text, x: row.control.x + 24, baselineY: row.control.y + 12, color: Theme.bodyText, size: 13)
    }
    for f in NetworkField.allCases {
        guard let r = l.fields[f] else { continue }
        heading(f.label, r.y + 16)
        if form.editable.contains(f) {
            Draw.textField(cr, r, text: form[f], caret: form.focus == f,
                           placeholder: f == .dns ? "from DHCP, or none" : "")
        } else {
            Draw.textLeft(cr, "provided by DHCP", x: r.x + 4, baselineY: r.y + 16,
                          color: Theme.secondaryText, size: 12)
        }
    }
    Draw.gelButton(cr, l.revert, label: "Revert", blue: false, pressed: false)
    Draw.gelButton(cr, l.apply, label: busy ? "Applying…" : "Apply Now", blue: !busy, pressed: busy)
    if !note.isEmpty {
        Draw.textLeft(cr, note, x: l.status.x, baselineY: l.noteBaseline, color: Theme.bodyText, size: 12)
    }
}

// MARK: - What the page is drawn from

public struct NetworkPaneState: Sendable {
    public var status: Vents.Network.Status
    public var form: NetworkForm?
    public var note: String
    public var busy: Bool

    public init(status: Vents.Network.Status, form: NetworkForm?, note: String = "", busy: Bool = false) {
        self.status = status; self.form = form; self.note = note; self.busy = busy
    }

    public var interfaces: [String] { NetworkWords.choosable(status.interfaces).map(\.name) }

    /// A fixed machine, for the golden picture: the page drawn from whatever
    /// network the test host has would be a different picture on every host.
    public static let sample: NetworkPaneState = {
        let s = Vents.Network.Status(
            interfaces: [
                .init(name: "lo0", up: true, loopback: true, link: .unknown,
                      ipv4: [.init(address: "127.0.0.1", prefix: 8)], mac: nil),
                .init(name: "em0", up: true, loopback: false, link: .up,
                      ipv4: [.init(address: "192.168.1.20", prefix: 24)], mac: "52:54:00:12:34:56"),
                .init(name: "igc0", up: true, loopback: false, link: .down, ipv4: [], mac: "52:54:00:ab:cd:ef"),
            ],
            router: (address: "192.168.1.1", interface: "em0"),
            nameServers: ["192.168.1.1"])
        var f = NetworkForm(interface: "em0")
        f.dhcp = false
        f.values = [.address: "192.168.1.20", .netmask: "255.255.255.0", .router: "192.168.1.1", .dns: "192.168.1.1"]
        f.focus = .address
        return NetworkPaneState(status: s, form: f, note: "Applied.")
    }()
}
