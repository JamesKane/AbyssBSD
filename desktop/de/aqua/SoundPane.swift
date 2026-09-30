// SoundPane — System Preferences' Sound pane (PHASE14 P14.6c).
//
// What it changes, and how:
//
//   - **Levels and mute** of the default device's mixer controls: straight to
//     `/dev/mixerN` (`Vents.Sound`), which is the user's — no helper, no
//     privilege, applied as the slider moves, as a Mac's is. `rc.d/mixer`
//     keeps them across a reboot.
//   - **The output device** (`hw.snd.default_unit`): root's, so through the
//     settings helper (P14.6b), like the Network pane's Apply.
//
// And what it only shows: **which applications are playing, at the level each
// set for itself** — read from `/dev/sndstat`. OSS lets another process read a
// channel's volume and not set it (PHASE14 §4.3); control arrives with
// `virtual_oss` and Phase 18. The page says so rather than drawing a slider
// that would do nothing.
//
// Everything is read, not remembered: devices, levels and players are read
// again once a second while the page shows, so a level changed with mixer(8)
// or a player that starts is on the page within a second.

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

// MARK: - What the page is drawn from

public struct SoundPaneState: Equatable, Sendable {
    public var devices: [Vents.Sound.Device] = []
    /// The unit `/dev/dsp` means now.
    public var defaultUnit: Int?
    /// The default device's mixer controls.
    public var controls: [Vents.Sound.Control] = []
    public var note: String = ""
    public var busy = false

    public init(devices: [Vents.Sound.Device] = [], defaultUnit: Int? = nil,
                controls: [Vents.Sound.Control] = [], note: String = "", busy: Bool = false) {
        self.devices = devices; self.defaultUnit = defaultUnit; self.controls = controls
        self.note = note; self.busy = busy
    }

    /// The machine, now.
    public static func read() -> SoundPaneState {
        let devices = Vents.Sound.devices()
        let unit = Vents.Sound.defaultUnit().flatMap { u in devices.contains { $0.unit == u } ? u : nil }
            ?? devices.first?.unit
        return SoundPaneState(devices: devices, defaultUnit: unit,
                              controls: unit.map { Vents.Sound.controls(unit: $0) } ?? [])
    }

    public var outputs: [Vents.Sound.Device] { devices.filter(\.playback) }
    public var defaultDevice: Vents.Sound.Device? { devices.first { $0.unit == defaultUnit } }
    /// Every application playing, on any device.
    public var playing: [Vents.Sound.Channel] { devices.flatMap(\.playing) }

    /// A fixed machine, for the golden picture (the host's own sound, or its
    /// lack of any, would make a different picture on every host).
    public static let sample = SoundPaneState(
        devices: [
            .init(unit: 0, name: "pcm0", description: "Realtek ALC897 (Rear Analog)", devnode: "dsp0",
                  playback: true, recording: true, fromUser: false, channels: [
                    .init(name: "dsp0.virtual_play.0", pid: 2211, command: "firefox", left: 100, right: 100),
                    .init(name: "dsp0.virtual_play.1", pid: 3104, command: "mpv", left: 45, right: 45),
                  ]),
            .init(unit: 1, name: "pcm1", description: "USB Headset", devnode: "dsp1",
                  playback: true, recording: true, fromUser: false, channels: []),
        ],
        defaultUnit: 0,
        controls: [.init(name: "vol", left: 60, right: 60, muted: false, recordable: false),
                   .init(name: "pcm", left: 75, right: 75, muted: false, recordable: false),
                   .init(name: "rec", left: 50, right: 50, muted: true, recordable: true)])
}

public enum SoundWords {
    /// A control as a person reads it.
    public static func label(_ control: String) -> String {
        switch control {
        case "vol": return "Output volume"
        case "pcm": return "Applications"
        case "rec": return "Input"
        case "mic": return "Microphone"
        case "line": return "Line in"
        case "speaker": return "Speaker"
        case "cd": return "CD"
        default: return control
        }
    }

    /// The page as one line, for the log a test reads: the default device,
    /// each control, and who is playing — in `ventsctl sound`'s terms.
    public static func statusLine(_ s: SoundPaneState) -> String {
        guard let d = s.defaultDevice else { return "no devices" }
        var parts = ["default \(d.name)"]
        for c in s.controls { parts.append("\(c.name) \(c.left):\(c.right)" + (c.muted ? " muted" : "")) }
        let p = s.playing
        parts.append("playing " + (p.isEmpty ? "none" : p.map { "\($0.pid ?? -1) \($0.command) \($0.left):\($0.right)" }
                                                            .joined(separator: ", ")))
        return parts.joined(separator: "; ")
    }

    /// An application's line in the read-only list.
    public static func player(_ c: Vents.Sound.Channel) -> String {
        "\(c.command) (pid \(c.pid ?? -1)) — \(max(c.left, c.right))%"
            + (c.left != c.right ? " (\(c.left):\(c.right))" : "")
    }
}

// MARK: - Layout (paint and hit-test read this, §2.9)

public struct SoundLayout: Equatable, Sendable {
    public struct Row: Equatable, Sendable {
        public let value: String      // a unit, or a control's name
        public let hit: Rect
        public let control: Rect      // the radio, the slider's track, or the checkbox
    }
    public var outputs: [Row] = []
    public var levels: [Row] = []
    public var mutes: [Row] = []
    public var levelsBox = Rect(0, 0, 0, 0)
    public var labelRight = 0.0
    public var outputBaseline = 0.0
    public var playingBaseline = 0.0
    public var noteBaseline = 0.0
}

public func soundLayout(body: Rect, _ s: SoundPaneState) -> SoundLayout {
    var l = SoundLayout()
    l.labelRight = body.x + 170
    let x = l.labelRight + 12
    var y = body.y + 24
    l.outputBaseline = y + 15
    for d in s.outputs {
        l.outputs.append(.init(value: "\(d.unit)", hit: Rect(x, y, 420, 22), control: Rect(x, y + 3, 16, 16)))
        y += 22
    }
    if s.outputs.isEmpty { y += 22 }
    y += 16
    l.levelsBox = Rect(body.x + 40, y, body.w - 80, Double(max(1, s.controls.count)) * 32 + 30)
    var ry = y + 28
    for c in s.controls {
        l.levels.append(.init(value: c.name, hit: Rect(x, ry, 240, 24), control: Rect(x + 4, ry + 2, 232, 20)))
        l.mutes.append(.init(value: c.name, hit: Rect(x + 290, ry, 80, 24), control: Rect(x + 290, ry + 4, 16, 16)))
        ry += 32
    }
    y = l.levelsBox.y + l.levelsBox.h + 28
    l.playingBaseline = y
    l.noteBaseline = y + Double(max(1, s.playing.count)) * 20 + 48
    return l
}

public enum SoundHit: Equatable, Sendable {
    case output(Int)
    /// A control, and the level (0…100) the pointer's x means on its track.
    case level(String, Int)
    case mute(String)
}

public func soundHit(_ l: SoundLayout, x: Double, y: Double) -> SoundHit? {
    if let r = l.outputs.first(where: { $0.hit.contains(x, y) }), let u = Int(r.value) { return .output(u) }
    if let r = l.levels.first(where: { $0.hit.contains(x, y) }) { return .level(r.value, soundLevel(track: r.control, x: x)) }
    if let r = l.mutes.first(where: { $0.hit.contains(x, y) }) { return .mute(r.value) }
    return nil
}

/// The level a pointer at `x` means on a track, 0…100.
public func soundLevel(track: Rect, x: Double) -> Int {
    Int((max(0, min(1, (x - track.x) / max(1, track.w))) * 100).rounded())
}

// MARK: - Paint

public func paintSoundPane(_ cr: OpaquePointer, _ l: SoundLayout, _ s: SoundPaneState) {
    func heading(_ t: String, _ baseline: Double) {
        let w = Draw.textWidth(cr, t, size: 13)
        Draw.textLeft(cr, t, x: l.labelRight - w, baselineY: baseline, color: Theme.bodyText, size: 13)
    }
    heading("Output device:", l.outputBaseline)
    guard !s.devices.isEmpty else {
        Draw.textLeft(cr, "This machine has no sound devices — /dev/sndstat lists none.",
                      x: l.labelRight + 12, baselineY: l.outputBaseline, color: Theme.secondaryText, size: 13)
        return
    }
    for r in l.outputs {
        guard let d = s.devices.first(where: { "\($0.unit)" == r.value }) else { continue }
        Draw.radioButton(cr, cx: r.control.x + 8, cy: r.control.y + 8, radius: 7, selected: d.unit == s.defaultUnit)
        Draw.textLeft(cr, "\(d.description)  (\(d.name))", x: r.control.x + 24, baselineY: r.control.y + 12,
                      color: Theme.bodyText, size: 13)
    }

    Draw.groupBox(cr, l.levelsBox, title: "Levels" + (s.defaultDevice.map { " — \($0.name)" } ?? ""))
    for (r, m) in zip(l.levels, l.mutes) {
        guard let c = s.controls.first(where: { $0.name == r.value }) else { continue }
        heading(SoundWords.label(c.name) + ":", r.hit.y + 16)
        Draw.slider(cr, r.control, value: Double(c.level) / 100)
        Draw.textLeft(cr, "\(c.level)%", x: r.hit.x + r.hit.w + 8, baselineY: r.hit.y + 16,
                      color: Theme.secondaryText, size: 11)
        Draw.checkbox(cr, m.control, checked: c.muted)
        Draw.textLeft(cr, "Mute", x: m.control.x + 22, baselineY: m.control.y + 12, color: Theme.bodyText, size: 13)
    }

    heading("Playing now:", l.playingBaseline)
    let p = s.playing
    var y = l.playingBaseline
    if p.isEmpty {
        Draw.textLeft(cr, "No application is playing.", x: l.labelRight + 12, baselineY: y,
                      color: Theme.secondaryText, size: 13)
        y += 20
    }
    for c in p {
        Draw.textLeft(cr, SoundWords.player(c), x: l.labelRight + 12, baselineY: y, color: Theme.bodyText, size: 13)
        y += 20
    }
    Draw.textLeft(cr, "Each application sets its own level. Changing it from here comes with",
                  x: l.labelRight + 12, baselineY: y + 4, color: Theme.secondaryText, size: 11)
    Draw.textLeft(cr, "per-application sound, which needs each application on a device of its own.",
                  x: l.labelRight + 12, baselineY: y + 18, color: Theme.secondaryText, size: 11)
    if !s.note.isEmpty {
        Draw.textLeft(cr, s.note, x: l.levelsBox.x, baselineY: l.noteBaseline, color: Theme.bodyText, size: 12)
    }
}

// MARK: - Talking to the helper

/// The settings helper, as a pane talks to it: one call, or an apply whose
/// events arrive on the run loop.
public enum SettingsClient {
    public static var service: String {
        getenv("ABYSS_SETTINGS_SERVICE").map { String(cString: $0) } ?? "settings"
    }

    /// The configured plan of `kind`, or the helper's reason there isn't one.
    public static func read(_ kind: String, interface: String? = nil) -> Result<SettingsPlan, SettingsRefusal> {
        var request = Msg()
        request.set("method", "read")
        request.set("kind", kind)
        if let interface { request.set("interface", interface) }
        guard let reply = try? Current.call(service, request) else {
            return .failure(SettingsRefusal("the settings helper is not running on this machine"))
        }
        guard reply.bool("ok") == true else { return .failure(SettingsRefusal(reply.string("error") ?? "refused")) }
        return SettingsWire.decodePlan(reply)
    }

    /// Send an apply; the socket, for the caller's run loop, or nil.
    public static func begin(_ request: Msg) -> Int32? {
        guard let sock = try? Current.connect(service) else { return nil }
        guard (try? Current.send(request, on: sock)) != nil else { close(sock); return nil }
        return sock
    }

    /// One event, or nil when the helper has hung up; a refusal becomes the
    /// `finished` it amounts to.
    public static func next(on sock: Int32) -> SettingsEvent? {
        guard let m = try? Current.receive(on: sock) else { return nil }
        if let e = SettingsWire.decodeEvent(m) { return e }
        if m.bool("ok") == false { return .finished(ok: false, error: m.string("error") ?? "refused") }
        return nil
    }

    /// A radio's wlan and the networks wpa_supplicant.conf holds.
    public static func readWifi(_ device: String) -> Result<WifiKnown, SettingsRefusal> {
        var request = Msg()
        request.set("method", "read")
        request.set("kind", "wifi")
        request.set("wifi.device", device)
        guard let reply = try? Current.call(service, request) else {
            return .failure(SettingsRefusal("the settings helper is not running on this machine"))
        }
        guard reply.bool("ok") == true else { return .failure(SettingsRefusal(reply.string("error") ?? "refused")) }
        return .success(SettingsWire.decodeKnown(reply))
    }

    /// Scan from a radio, as root. Synchronous: a scan takes a second or two,
    /// and the page has nothing to show until it is done.
    public static func scanWifi(device: String, interface: String) -> Result<[WifiNetwork], SettingsRefusal> {
        var request = Msg()
        request.set("method", "scan")
        request.set("wifi.device", device)
        request.set("wifi.interface", interface)
        guard let reply = try? Current.call(service, request) else {
            return .failure(SettingsRefusal("the settings helper is not running on this machine"))
        }
        guard reply.bool("ok") == true else { return .failure(SettingsRefusal(reply.string("error") ?? "refused")) }
        return .success(SettingsWire.decodeScan(reply))
    }

    /// Make `unit` the default output, as a request.
    public static func soundRequest(defaultUnit unit: Int) -> Msg {
        var m = Msg()
        m.set("method", "apply")
        SettingsWire.encode(.sound(SoundPlan(defaultUnit: unit)), into: &m)
        return m
    }
}
