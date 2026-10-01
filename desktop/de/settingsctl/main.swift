// abyss-settingsctl — the command-line face of the settings helper (P14.3).
//
//   abyss-settingsctl read  energy
//   abyss-settingsctl check energy --powerd on|off [--ac MODE] [--battery MODE]
//   abyss-settingsctl apply energy --powerd on|off [--ac MODE] [--battery MODE]
//   abyss-settingsctl read  power-profile
//   abyss-settingsctl check|apply power-profile --profile power-saver|balanced|performance
//   abyss-settingsctl read  network --interface IF
//   abyss-settingsctl check network --interface IF (--dhcp |
//                     --address A --netmask M [--router R]) [--dns "A B"]
//   abyss-settingsctl apply network …
//   abyss-settingsctl read  sound
//   abyss-settingsctl check|apply sound --default pcmN
//   abyss-settingsctl read  wifi --device RADIO
//   abyss-settingsctl scan  wifi --device RADIO [--interface wlanN]
//   abyss-settingsctl check|apply wifi --device RADIO [--interface wlanN]
//                     (--join SSID (--passphrase P | --open) | --forget SSID)
//
// It links `SettingsWire` and not `SettingsRun`, as the pane does: a client
// speaks the protocol and carries none of the code that runs `sysrc`. It exists
// so every plan is testable without a GUI (PHASE14 P14.3), and so a machine
// whose display is broken can still be told to change something.

import CurrentIPC
import Settings
import SettingsWire

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

func emit(_ fd: Int32, _ s: String) {
    let b = Array((s + "\n").utf8)
    _ = b.withUnsafeBufferPointer { write(fd, $0.baseAddress, b.count) }
}
func usage() -> Never {
    emit(1, """
    usage: abyss-settingsctl <read|check|apply|scan> <energy|network|sound|wifi> [options]
      --powerd on|off      energy: whether powerd runs
      --ac MODE            its policy on AC: \(PowerdMode.allCases.map(\.rawValue).joined(separator: ", "))
      --battery MODE       its policy on battery
      --interface IF       network: the wired interface (em0, igc0, vtnet0)
      --dhcp               network: its address by DHCP
      --address A --netmask M [--router R]
                           network: a manual IPv4 address
      --dns "A B"          network: name servers
      --default pcmN       sound: the device /dev/dsp means
      --device RADIO       wifi: the radio (iwn0, wtap1)
      --join SSID          wifi: a network to join, with --passphrase P or --open
      --forget SSID        wifi: a network to forget
      --service NAME       the service to talk to (default settings)
    """)
    exit(2)
}

var args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 2, ["read", "check", "apply", "scan"].contains(args[0]) else { usage() }
let verb = args[0], kind = args[1]
args.removeFirst(2)
var serviceName = "settings"
var fields: [String: String] = [:]
var i = 0
while i < args.count {
    if args[i] == "--dhcp" { fields["mode"] = "dhcp"; i += 1; continue }
    if args[i] == "--open" { fields["open"] = "1"; i += 1; continue }
    if args[i] == "--force" { fields["force"] = "1"; i += 1; continue }
    guard i + 1 < args.count else { emit(2, "abyss-settingsctl: \(args[i]) needs a value"); exit(2) }
    switch args[i] {
    case "--service": serviceName = args[i + 1]
    case "--powerd", "--ac", "--battery", "--profile", "--interface", "--address", "--netmask", "--router", "--dns", "--default",
         "--device", "--join", "--forget", "--passphrase", "--pid", "--started", "--name":
        fields[String(args[i].dropFirst(2))] = args[i + 1]
    default: emit(2, "abyss-settingsctl: unknown option '\(args[i])'"); exit(2)
    }
    i += 2
}

var request = Msg()
request.set("method", verb)
request.set("kind", kind)
if let iface = fields["interface"] { request.set("interface", iface) }
if kind == "wifi" {
    request.set("wifi.device", fields["device"] ?? "")
    request.set("wifi.interface", fields["interface"] ?? "wlan0")
}
if verb != "read" && verb != "scan" {
    switch kind {
    case "energy":
        guard let on = fields["powerd"], on == "on" || on == "off" else {
            emit(2, "abyss-settingsctl: --powerd on|off is required"); exit(2)
        }
        request.set("energy.powerd", on == "on")
        if let a = fields["ac"] { request.set("energy.ac", a) }
        if let b = fields["battery"] { request.set("energy.battery", b) }
    case "power-profile":
        // Sent as typed; the helper refuses a name that is not a profile.
        request.set("power-profile", fields["profile"] ?? "")
    case "network":
        // Sent as typed: the helper decides what is an address, not this.
        request.set("network.interface", fields["interface"] ?? "")
        request.set("network.mode", fields["mode"] ?? (fields["address"] != nil ? "manual" : ""))
        for k in ["address", "netmask", "router", "dns"] {
            if let v = fields[k] { request.set("network.\(k)", v) }
        }
    case "wifi":
        if let ssid = fields["join"] {
            request.set("wifi.action", "join")
            request.set("wifi.ssid", ssid)
            if let pass = fields["passphrase"] {
                // The key, derived here: the passphrase goes no further.
                guard let psk = WifiKey.psk(passphrase: pass, ssid: ssid) else {
                    emit(2, "abyss-settingsctl: a WPA passphrase is 8 to 63 characters"); exit(2)
                }
                request.set("wifi.psk", psk)
            } else if fields["open"] == nil {
                emit(2, "abyss-settingsctl: --join needs --passphrase P, or --open for an open network"); exit(2)
            }
        } else if let ssid = fields["forget"] {
            request.set("wifi.action", "forget")
            request.set("wifi.ssid", ssid)
        } else {
            emit(2, "abyss-settingsctl: wifi needs --join SSID or --forget SSID"); exit(2)
        }
    case "sound":
        guard let d = fields["default"] else { emit(2, "abyss-settingsctl: --default pcmN is required"); exit(2) }
        request.set("sound.default", d)       // as typed: the helper decides
    case "signal":
        // Quit another user's process (P15.7): which one, as the caller saw it.
        guard let pid = fields["pid"], let started = fields["started"], let name = fields["name"] else {
            emit(2, "abyss-settingsctl: signal needs --pid N --started SECONDS --name NAME [--force]"); exit(2)
        }
        request.set("signal.pid", pid)
        request.set("signal.started", started)
        request.set("signal.name", name)
        request.set("signal.force", fields["force"] != nil)
    default:
        emit(2, "abyss-settingsctl: there is no \(kind) plan"); exit(2)
    }
}

let sock: Int32
do { sock = try Current.connect(serviceName) } catch {
    emit(2, "abyss-settingsctl: cannot reach the settings helper (\(serviceName)): \(error)"); exit(1)
}
defer { close(sock) }
do { try Current.send(request, on: sock) } catch {
    emit(2, "abyss-settingsctl: could not send: \(error)"); exit(1)
}

func receive() -> Msg {
    do { return try Current.receive(on: sock) } catch {
        emit(2, "abyss-settingsctl: the helper hung up: \(error)"); exit(1)
    }
}

switch verb {
case "read" where kind == "wifi":
    let r = receive()
    guard r.bool("ok") == true else { emit(2, "abyss-settingsctl: \(r.string("error") ?? "refused")"); exit(1) }
    let k = SettingsWire.decodeKnown(r)
    emit(1, "wifi \(k.device): " + (k.interface ?? "no wlan") + ", networks: "
         + (k.networks.isEmpty ? "none" : k.networks.map { "\"\($0)\"" }.joined(separator: " ")))
case "scan":
    let r = receive()
    guard r.bool("ok") == true else { emit(2, "abyss-settingsctl: \(r.string("error") ?? "refused")"); exit(1) }
    let nets = SettingsWire.decodeScan(r)
    if nets.isEmpty { emit(1, "no networks") }
    for n in nets {
        emit(1, "network \"\(n.ssid)\" signal \(n.signal) channel \(n.channel) \(n.secured ? "secured" : "open")")
    }
case "read":
    let r = receive()
    guard r.bool("ok") == true else { emit(2, "abyss-settingsctl: \(r.string("error") ?? "refused")"); exit(1) }
    switch SettingsWire.decodePlan(r) {
    case .success(.energy(let e)):
        emit(1, "energy: powerd \(e.powerd ? "on" : "off"), ac \(e.onAC.rawValue), battery \(e.onBattery.rawValue)")
    case .success(.network(let n)):
        let dns = n.dns.isEmpty ? "" : ", dns \(n.dns.map(\.description).joined(separator: " "))"
        switch n.ipv4 {
        case .dhcp: emit(1, "network \(n.interface): dhcp\(dns)")
        case .manual(let a, let p, let r):
            emit(1, "network \(n.interface): \(a)/\(p)" + (r.map { " via \($0)" } ?? "") + dns)
        }
    case .success(.sound(let s)):
        emit(1, "sound: default pcm\(s.defaultUnit)")
    case .success(.powerProfile(let p)):
        emit(1, "power profile: \(p.profile.rawValue)")
    case .success(.signal):
        emit(1, "signal: nothing to read")
    case .success(.wifi):
        emit(2, "abyss-settingsctl: read wifi is answered separately"); exit(1)
    case .failure(let why):
        emit(2, "abyss-settingsctl: \(why.message)"); exit(1)
    }
case "check":
    let r = receive()
    if let e = r.string("error") { emit(2, "abyss-settingsctl: \(e)"); exit(1) }
    for p in 0..<Int(r.uint64("problems.count") ?? 0) { emit(1, "refused: \(r.string("problem.\(p)") ?? "")") }
    if let render = r.string("render") { emit(1, render) }
    exit(r.bool("ok") == true ? 0 : 1)
default:
    while true {
        let m = receive()
        if let e = m.string("error"), m.string("event") == nil {
            emit(2, "abyss-settingsctl: \(e)"); exit(1)
        }
        guard let e = SettingsWire.decodeEvent(m) else { continue }
        switch e {
        case .starting(let i, let n, let what): emit(1, "[\(i + 1)/\(n)] \(what)")
        case .ok: break
        case .skipped(_, let why): emit(1, "    (skipped) " + why)
        case .failed(_, _, let why, let ignored): emit(1, (ignored ? "    (allowed to fail) " : "    FAILED: ") + why)
        case .finished(let ok, let err):
            emit(1, ok ? "done" : "not applied: \(err)")
            exit(ok ? 0 : 1)
        }
    }
}
