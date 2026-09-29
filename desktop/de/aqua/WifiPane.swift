// WifiPane — Wi-Fi, on the Network pane (PHASE14 P14.5c).
//
// Jaguar showed AirPort beside Ethernet in the Network pane's "Show:" menu;
// here a radio appears in the same row, and choosing it shows this page:
//
//   - **status**, read without privilege from `ifconfig wlanN`: associated
//     with which network, on which channel (`Vents.Wifi`);
//   - **the networks a scan found** — the scan is root's, so the helper does
//     it — strongest first, a lock where they are secured;
//   - **a passphrase field** that draws dots, and **Join**: the pane turns the
//     passphrase into the WPA key (`WifiKey`) and sends only that. The
//     passphrase is never sent, stored, logged or published;
//   - **the networks this machine knows**, each with Forget.

import AquaDraw
import CCairo
import Settings
import SettingsWire
import Vents

public struct WifiPaneState: Equatable, Sendable {
    public var device: String
    public var interface: String = "wlan0"
    public var status: Vents.Wifi.Status
    public var known: [String] = []
    public var scanned: [WifiNetwork] = []
    /// The network chosen from the list.
    public var chosen: String?
    /// What was typed — never drawn, only counted.
    public var passphrase: String = ""
    public var fieldFocused = false
    public var note = ""
    public var busy = false

    public init(device: String, interface: String = "wlan0", status: Vents.Wifi.Status? = nil) {
        self.device = device; self.interface = interface
        self.status = status ?? Vents.Wifi.Status(interface: interface, exists: false)
    }

    public var chosenNetwork: WifiNetwork? { scanned.first { $0.ssid == chosen } }

    public static let sample: WifiPaneState = {
        var s = WifiPaneState(device: "iwn0", status: Vents.Wifi.Status(interface: "wlan0", exists: true, associated: true,
                                                                       ssid: "Home", bssid: "aa:bb:cc:dd:ee:01", channel: 6))
        s.known = ["Home", "Café Wi-Fi"]
        s.scanned = [WifiNetwork(ssid: "Home", bssid: "aa:bb:cc:dd:ee:01", channel: 6, signal: -41, secured: true),
                     WifiNetwork(ssid: "Café Wi-Fi 5G", bssid: "aa:bb:cc:dd:ee:02", channel: 40, signal: -58, secured: true),
                     WifiNetwork(ssid: "Library", bssid: "aa:bb:cc:dd:ee:03", channel: 11, signal: -72, secured: false)]
        s.chosen = "Café Wi-Fi 5G"
        s.passphrase = "12345678"
        s.fieldFocused = true
        return s
    }()
}

public enum WifiWords {
    public static func status(_ s: Vents.Wifi.Status) -> String {
        guard s.exists else { return "Not set up: this radio has no wlan interface yet" }
        guard s.associated, let n = s.ssid else { return "Not associated with a network" }
        return "Associated with “\(n)”" + (s.channel.map { ", channel \($0)" } ?? "")
    }

    /// The signal in three steps, 1…3 bars.
    public static func bars(_ signal: Int) -> Int {
        // Real radios report dBm (−30 strong … −90 weak); the lab's wtap a
        // small positive S. Both read sensibly on one scale.
        let s = signal > 0 ? -40 - (30 - min(signal, 30)) : signal
        return s >= -55 ? 3 : s >= -70 ? 2 : 1
    }

    /// The page as one line, for the log a test reads.
    public static func statusLine(_ s: WifiPaneState) -> String {
        "\(s.device) \(s.interface) " + (s.status.associated ? "associated \(s.status.ssid ?? "?")" : "not-associated")
            + " known " + (s.known.isEmpty ? "none" : s.known.joined(separator: ","))
    }
}

// MARK: - Layout

public struct WifiLayout: Equatable, Sendable {
    public var body = Rect(0, 0, 0, 0)
    public var statusBaseline = 0.0
    public var scan = Rect(0, 0, 0, 0)
    public var networks: [Rect] = []          // one per scanned network, in order
    public var field = Rect(0, 0, 0, 0)
    public var join = Rect(0, 0, 0, 0)
    public var knownBaseline = 0.0
    public var forgets: [Rect] = []           // one per known network
    public var noteBaseline = 0.0
}

public func wifiLayout(body: Rect, top: Double, _ s: WifiPaneState) -> WifiLayout {
    var l = WifiLayout()
    l.body = body
    let left = body.x + 40, w = body.w - 80
    l.statusBaseline = top + 18
    l.scan = Rect(left + w - 100, top + 34, 100, 24)
    var y = top + 66
    for _ in s.scanned.prefix(6) {
        l.networks.append(Rect(left, y, w, 22))
        y += 22
    }
    if s.scanned.isEmpty { y += 22 }
    y += 30                                   // the password's label sits above its field
    l.field = Rect(left + 16, y, 260, 24)
    l.join = Rect(left + 16 + 270, y, 90, 24)
    y += 58
    l.knownBaseline = y
    y += 8
    for _ in s.known.prefix(4) {
        l.forgets.append(Rect(left + w - 90, y, 90, 22))
        y += 26
    }
    l.noteBaseline = y + 22
    return l
}

public enum WifiHit: Equatable, Sendable {
    case scan, network(String), field, join, forget(String)
}

public func wifiHit(_ l: WifiLayout, _ s: WifiPaneState, x: Double, y: Double) -> WifiHit? {
    if l.scan.contains(x, y) { return .scan }
    for (r, n) in zip(l.networks, s.scanned) where r.contains(x, y) { return .network(n.ssid) }
    if l.field.contains(x, y) { return .field }
    if l.join.contains(x, y) { return .join }
    for (r, n) in zip(l.forgets, s.known) where r.contains(x, y) { return .forget(n) }
    return nil
}

// MARK: - Paint

public func paintWifiPane(_ cr: OpaquePointer, _ l: WifiLayout, _ s: WifiPaneState) {
    let left = l.body.x + 40
    Draw.textLeft(cr, "Status: " + WifiWords.status(s.status), x: left, baselineY: l.statusBaseline,
                  color: Theme.bodyText, size: 13)
    Draw.textLeft(cr, "Networks:", x: left, baselineY: l.scan.y + 16, color: Theme.bodyText, size: 13, style: .bold)
    Draw.gelButton(cr, l.scan, label: s.busy ? "…" : "Scan", blue: false, pressed: false)
    if s.scanned.isEmpty {
        Draw.textLeft(cr, "Scan to see the networks in range.", x: left + 16, baselineY: l.scan.y + 48,
                      color: Theme.secondaryText, size: 12)
    }
    for (r, n) in zip(l.networks, s.scanned) {
        if n.ssid == s.chosen { Draw.paint("menu.highlight", cr, r) }
        let on = n.ssid == s.chosen
        let color = on ? Theme.menuTextOnHighlight : Theme.bodyText
        let here = s.status.associated && s.status.ssid == n.ssid
        Draw.textLeft(cr, n.ssid + (here ? "  (connected)" : ""), x: r.x + 8, baselineY: r.y + 15, color: color, size: 13)
        // The signal as three bars, drawn — no font has to hold them.
        let nb = WifiWords.bars(n.signal)
        for b in 0..<3 {
            let bh = 4.0 + Double(b) * 4, bx = r.x + r.w - 28 + Double(b) * 7
            Draw.setColor(cr, b < nb ? color : color.with(a: color.a * 0.25))
            cairo_rectangle(cr, bx, r.y + 17 - bh, 5, bh)
            cairo_fill(cr)
        }
        if n.secured {
            let w = Draw.textWidth(cr, "WPA", size: 10)
            Draw.textLeft(cr, "WPA", x: r.x + r.w - 36 - w, baselineY: r.y + 15,
                          color: on ? color : Theme.secondaryText, size: 10)
        }
    }
    let label = s.chosenNetwork.map { $0.secured ? "Password for “\($0.ssid)”:" : "“\($0.ssid)” is open." } ?? "Choose a network."
    Draw.textLeft(cr, label, x: l.field.x, baselineY: l.field.y - 8, color: Theme.bodyText, size: 12)
    if s.chosenNetwork?.secured ?? true {
        // Dots, one per character: the passphrase itself is never drawn.
        Draw.textField(cr, l.field, text: String(repeating: "•", count: s.passphrase.count), caret: s.fieldFocused)
    }
    Draw.gelButton(cr, l.join, label: "Join", blue: s.chosen != nil, pressed: false)
    Draw.textLeft(cr, "Known networks:", x: left, baselineY: l.knownBaseline, color: Theme.bodyText, size: 13, style: .bold)
    if s.known.isEmpty {
        Draw.textLeft(cr, "None yet.", x: left + 16, baselineY: l.knownBaseline + 22, color: Theme.secondaryText, size: 12)
    }
    for (r, n) in zip(l.forgets, s.known) {
        Draw.textLeft(cr, n, x: left + 16, baselineY: r.y + 15, color: Theme.bodyText, size: 13)
        Draw.gelButton(cr, r, label: "Forget", blue: false, pressed: false)
    }
    if !s.note.isEmpty {
        Draw.textLeft(cr, s.note, x: left, baselineY: l.noteBaseline, color: Theme.bodyText, size: 12)
    }
}
