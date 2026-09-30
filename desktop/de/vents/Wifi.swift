// Vents.Wifi — the radios, and what a wlan interface is doing, without
// privilege (PHASE14 P14.5).
//
// `net.wlan.devices` names the radios (on FreeBSD 14+ a radio is not an
// interface: it is the parent a `wlanN` is made on), and `ifconfig wlanN`,
// which any user may run, says what the interface is associated with. That is
// 802.11 association — which comes BEFORE WPA's handshake — so the pane says
// "associated", and the helper's journal and wpa_supplicant are what say a key
// was accepted.

import Spawn

public extension Vents {
    enum Wifi {
        public struct Status: Equatable, Sendable {
            public var interface: String
            public var exists: Bool
            public var associated: Bool
            public var ssid: String?
            public var bssid: String?
            public var channel: Int?
            public init(interface: String, exists: Bool, associated: Bool = false,
                        ssid: String? = nil, bssid: String? = nil, channel: Int? = nil) {
                self.interface = interface; self.exists = exists; self.associated = associated
                self.ssid = ssid; self.bssid = bssid; self.channel = channel
            }
        }

        /// The radios the kernel has, in its order; empty where there are none
        /// (and on Linux, which has no such sysctl).
        public static func radios() -> [String] {
            (Vents.Sysctl.string("net.wlan.devices") ?? "").split(separator: " ").map(String.init)
        }

        public static func status(_ interface: String) -> Status {
            let r = Spawn.run(["ifconfig", interface], limit: 16384)
            guard r.succeeded else { return Status(interface: interface, exists: false) }
            return parseIfconfig(r.stdoutText, interface: interface)
        }

        /// `ifconfig wlanN`: its `ssid … channel … bssid …` line, and `status:`.
        public static func parseIfconfig(_ text: String, interface: String) -> Status {
            var s = Status(interface: interface, exists: true)
            for line in text.split(separator: "\n") {
                let w = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
                guard let first = w.first else { continue }
                if first == "status:" { s.associated = w.dropFirst().joined(separator: " ") == "associated" }
                if first == "ssid", w.count >= 2 {
                    // The name may hold spaces, and ifconfig quotes it then:
                    // everything up to " channel".
                    var rest = line.drop { $0 == " " || $0 == "\t" }.dropFirst(5)
                    var name = Substring("")
                    if rest.hasPrefix("\"") {
                        rest = rest.dropFirst()
                        name = rest.prefix { $0 != "\"" }
                    } else {
                        name = rest.prefix { $0 != " " }
                    }
                    s.ssid = name.isEmpty ? nil : String(name)
                    if let i = w.firstIndex(of: "channel"), i + 1 < w.count { s.channel = Int(w[i + 1]) }
                    if let i = w.firstIndex(of: "bssid"), i + 1 < w.count { s.bssid = String(w[i + 1]) }
                }
            }
            return s
        }
    }
}
