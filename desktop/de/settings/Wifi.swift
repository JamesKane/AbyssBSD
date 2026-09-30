// Wi-Fi: the plan, wpa_supplicant.conf, and what a scan found (PHASE14 P14.5).
//
// Joining a network on FreeBSD is three things rc does: `wlans_<radio>` makes a
// `wlanN` on the radio, `ifconfig_wlanN="WPA DHCP"` has netif start
// wpa_supplicant on it, and `/etc/wpa_supplicant.conf` holds the networks it
// may join. The plan writes those and restarts the interface; forgetting a
// network takes its block out and tells wpa_supplicant to read the file again.
//
// **A network's name is written in hex** (`ssid=6162…`), which wpa_supplicant
// reads as readily as a quoted one: an SSID is 32 arbitrary bytes, and a name
// holding a quote or a newline could otherwise write configuration of its own
// into a root-owned file. **Its key is the PSK, never the passphrase**
// (`WifiKey`).

public enum WifiAction: Equatable, Sendable {
    /// `psk` is 64 hex digits (`WifiKey.psk`), or nil for an open network.
    case join(ssid: String, psk: String?)
    case forget(ssid: String)
}

public struct WifiPlan: Equatable, Sendable {
    /// The radio: `iwn0`, `iwlwifi0`, `wtap1` — a name in `net.wlan.devices`.
    public var device: String
    /// The wlan interface rc makes on it.
    public var interface: String
    public var action: WifiAction

    public init(device: String, interface: String = "wlan0", action: WifiAction) {
        self.device = device; self.interface = interface; self.action = action
    }

    public var ssid: String {
        switch action { case .join(let s, _), .forget(let s): return s }
    }
}

extension Settings {
    /// Letters then digits, as FreeBSD names a radio (`iwn0`, `rtwn0`, `wtap1`).
    public static func isRadioName(_ s: String) -> Bool {
        guard let d = s.firstIndex(where: { $0.isNumber }), d != s.startIndex, s.count <= 15 else { return false }
        return s[..<d].allSatisfy { $0.isASCII && $0.isLowercase } && s[d...].allSatisfy { $0.isASCII && $0.isNumber }
    }

    static func wifiProblems(_ w: WifiPlan) -> [SettingsRefusal] {
        var out: [SettingsRefusal] = []
        if !isRadioName(w.device) { out.append(SettingsRefusal("\(w.device.isEmpty ? "no radio" : w.device) is not a wireless device's name")) }
        if !(w.interface.hasPrefix("wlan") && Int(w.interface.dropFirst(4)) != nil) {
            out.append(SettingsRefusal("\(w.interface) is not a wlan interface (wlan0, wlan1 …)"))
        }
        let bytes = w.ssid.utf8.count
        if bytes == 0 || bytes > 32 { out.append(SettingsRefusal("a network's name is 1 to 32 bytes, not \(bytes)")) }
        if case .join(_, let psk?) = w.action, !WifiKey.isPSK(psk) {
            out.append(SettingsRefusal("the network key is not a WPA key (64 hex digits)"))
        }
        return out
    }

    static func compileWifi(_ w: WifiPlan) -> [SettingsStep] {
        switch w.action {
        case .join:
            // The network first, then the interface that uses it, then netif:
            // which creates wlanN on the radio and starts wpa_supplicant.
            return [.setVar(.wpaSupplicant, key: WpaConf.key(ssid: w.ssid), value: WpaConf.value(w)),
                    .rcConf(key: "wlans_\(w.device)", value: w.interface),
                    .rcConf(key: "ifconfig_\(w.interface)", value: "WPA DHCP"),
                    .service(name: "netif", action: ["restart", w.interface], mayFail: false)]
        case .forget:
            // Not running is not a failure: the file is what forgetting is.
            return [.setVar(.wpaSupplicant, key: WpaConf.key(ssid: w.ssid), value: nil),
                    .tool(argv: ["wpa_cli", "-i", w.interface, "reconfigure"], mayFail: true)]
        }
    }
}

// MARK: - wpa_supplicant.conf

public enum WpaConf {
    /// The key a network's block is found by: its SSID, in hex.
    public static func key(ssid: String) -> String { "ssid=" + hex(ssid) }

    /// What the plan writes for a join: the block's body, one setting a line.
    static func value(_ w: WifiPlan) -> String? {
        guard case .join(let ssid, let psk) = w.action else { return nil }
        return "ssid=" + hex(ssid) + "\n" + (psk.map { "psk=" + $0 } ?? "key_mgmt=NONE")
    }

    public static func hex(_ s: String) -> String { s.utf8.map { WifiKey.hex($0) }.joined() }

    public static func unhex(_ s: Substring) -> String? {
        guard s.count % 2 == 0 else { return nil }
        var bytes: [UInt8] = []
        var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            guard let b = UInt8(s[i..<j], radix: 16) else { return nil }
            bytes.append(b); i = j
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private struct Block { var lines: [Substring]; var ssid: String? }

    /// Split into the text outside blocks and the `network={…}` blocks.
    private static func split(_ text: String) -> (head: [Substring], blocks: [Block]) {
        var head: [Substring] = [], blocks: [Block] = []
        var current: [Substring]?
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let t = line.drop { $0 == " " || $0 == "\t" }
            if current == nil, t.hasPrefix("network={") { current = [line]; continue }
            if var c = current {
                c.append(line)
                if t.hasPrefix("}") { blocks.append(Block(lines: c, ssid: ssidOf(c))); current = nil }
                else { current = c }
                continue
            }
            head.append(line)
        }
        if let c = current { blocks.append(Block(lines: c, ssid: ssidOf(c))) }     // unterminated: kept as found
        return (head, blocks)
    }

    private static func ssidOf(_ lines: [Substring]) -> String? {
        for l in lines {
            let t = l.drop { $0 == " " || $0 == "\t" }
            guard t.hasPrefix("ssid=") else { continue }
            let v = t.dropFirst(5)
            if v.hasPrefix("\""), v.hasSuffix("\""), v.count >= 2 { return String(v.dropFirst().dropLast()) }
            return unhex(v)
        }
        return nil
    }

    /// The networks the file holds, by name, in order.
    public static func networks(_ text: String) -> [String] { split(text).blocks.compactMap(\.ssid) }

    /// `text` with the network named `ssid` set to `body` (its block's lines),
    /// or removed for nil. A block for the same network — written by us in hex
    /// or by hand in quotes — is replaced where it was; otherwise it is added
    /// last. A file with no control socket gets one, so `wpa_cli` can reach
    /// the supplicant.
    public static func edit(_ text: String, ssid: String, body: String?) -> String {
        var (head, blocks) = split(text)
        let block = body.map { b in
            Block(lines: ["network={"] + b.split(separator: "\n").map { Substring("\t" + $0) } + ["}"], ssid: ssid)
        }
        // Replaced where the first was; any other copy of it dropped.
        let at = blocks.firstIndex { $0.ssid == ssid } ?? blocks.count
        let kept = blocks.enumerated().filter { $0.element.ssid != ssid || $0.offset == at }.map(\.element)
        blocks = kept.filter { $0.ssid != ssid }
        if let block { blocks.insert(block, at: min(at, blocks.count)) }
        while let l = head.last, l.isEmpty { head.removeLast() }
        if !head.contains(where: { $0.hasPrefix("ctrl_interface=") }) {
            head.insert("ctrl_interface=/var/run/wpa_supplicant", at: 0)
        }
        let out = head.map(String.init) + blocks.flatMap { $0.lines.map(String.init) }
        return out.joined(separator: "\n") + "\n"
    }
}

// MARK: - What a scan found

public struct WifiNetwork: Equatable, Sendable {
    public var ssid: String
    public var bssid: String
    public var channel: Int
    /// The signal, as ifconfig reports it (`S` of `S:N`).
    public var signal: Int
    /// WPA/WPA2 (an RSN or WPA element), or at least privacy.
    public var secured: Bool
    public init(ssid: String, bssid: String, channel: Int, signal: Int, secured: Bool) {
        self.ssid = ssid; self.bssid = bssid; self.channel = channel; self.signal = signal; self.secured = secured
    }
}

public enum WifiScan {
    /// `ifconfig wlanN scan` (or `list scan`). A row is found by its BSSID —
    /// everything before it is the SSID, which may hold spaces — and a network
    /// seen by several access points is listed once, at its strongest.
    public static func parse(_ text: String) -> [WifiNetwork] {
        var best: [String: WifiNetwork] = [:], order: [String] = []
        for line in text.split(separator: "\n").dropFirst() {
            let words = line.split(separator: " ", omittingEmptySubsequences: true)
            guard let bi = words.firstIndex(where: isBSSID), bi + 4 < words.count else { continue }
            let ssidEnd = words[bi].startIndex          // a word of the line: its indices are the line's
            var ssid = line[..<ssidEnd]
            while ssid.last == " " { ssid = ssid.dropLast() }
            guard !ssid.isEmpty, let ch = Int(words[bi + 1]) else { continue }
            let sn = words[bi + 3].split(separator: ":")
            let signal = sn.first.flatMap { Int($0) } ?? 0
            let rest = words[(bi + 5)...].joined(separator: " ")
            let caps = words.count > bi + 5 ? String(words[bi + 5]) : ""
            let secured = rest.contains("RSN") || rest.contains("WPA") || caps.contains("P")
            let n = WifiNetwork(ssid: String(ssid), bssid: String(words[bi]), channel: ch, signal: signal, secured: secured)
            if let b = best[n.ssid] { if n.signal > b.signal { best[n.ssid] = n } }
            else { best[n.ssid] = n; order.append(n.ssid) }
        }
        return order.compactMap { best[$0] }.sorted { $0.signal > $1.signal }
    }

    static func isBSSID(_ w: Substring) -> Bool {
        let p = w.split(separator: ":")
        return p.count == 6 && p.allSatisfy { $0.count == 2 && UInt8($0, radix: 16) != nil }
    }
}
