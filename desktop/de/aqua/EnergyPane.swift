// EnergyPane — System Preferences' Energy Saver (PHASE14 P14.8).
//
// Deliberately thin, as PHASE14 says. Three things:
//
//   - **Sleep delays** for the computer and the display: the user's, written
//     to energy.ini (`EnergyPrefs`) as the slider is let go. Nothing sleeps
//     yet — idle and suspend are Phase 16's — and the page says so, rather
//     than drawing sliders that look like they do something today.
//   - **powerd**: whether the processor's speed follows the work, and how on
//     AC and on battery. rc.conf's, so through the settings helper (the
//     `energy` plan, P14.3 — the first plan the helper ever had).
//   - **The battery**, where `Vents` finds one; and which sleep states the
//     machine says it supports (`hw.acpi.supported_sleep_state`).

import AquaDraw
import PoolConfig
import Settings
import Vents

// MARK: - What the page is drawn from

public struct EnergyPaneState: Equatable, Sendable {
    public var prefs = EnergyPrefs()
    /// rc.conf's powerd, through the helper; nil when it could not be read.
    public var powerd: EnergyPlan?
    public var battery: Vents.Battery?
    /// `S3 S4 S5`, or nil where there is no ACPI to ask.
    public var sleepStates: String?
    public var note = ""
    public var busy = false

    public init(prefs: EnergyPrefs = EnergyPrefs(), powerd: EnergyPlan? = nil, battery: Vents.Battery? = nil,
                sleepStates: String? = nil, note: String = "") {
        self.prefs = prefs; self.powerd = powerd; self.battery = battery; self.sleepStates = sleepStates; self.note = note
    }

    public static let sample = EnergyPaneState(
        prefs: EnergyPrefs(displaySleepMinutes: 10, systemSleepMinutes: 30),
        powerd: EnergyPlan(powerd: true, onAC: .hiadaptive, onBattery: .adaptive),
        battery: Vents.Battery(percent: 83, minutesRemaining: 214, isCharging: false),
        sleepStates: "S3 S4 S5")
}

public enum EnergyWords {
    public static func mode(_ m: PowerdMode) -> String {
        switch m {
        case .adaptive: return "Adaptive"
        case .hiadaptive: return "Responsive"
        case .minimum: return "Slowest"
        case .maximum: return "Fastest"
        }
    }

    /// What the machine says it can do, in words.
    public static func sleepStates(_ s: String?) -> String {
        guard let s, !s.isEmpty else { return "This machine reports no sleep states." }
        var can: [String] = []
        if s.contains("S3") { can.append("sleep (S3)") }
        if s.contains("S4") { can.append("hibernate (S4)") }
        if s.contains("S5") { can.append("power off (S5)") }
        return can.isEmpty ? "This machine reports no sleep states it can enter." : "This machine can " + can.joined(separator: ", ") + "."
    }

    public static func battery(_ b: Vents.Battery?) -> String {
        guard let b else { return "No battery" }
        var s = b.label
        if b.isCharging { s += ", charging" }
        else if let m = b.minutesRemaining { s += ", \(EnergyPrefs.words(m)) remaining" }
        return s
    }

    /// The page as one line, for the log a test reads.
    public static func statusLine(_ s: EnergyPaneState) -> String {
        "computer \(s.prefs.systemSleepMinutes) display \(s.prefs.displaySleepMinutes) powerd "
            + (s.powerd.map { $0.powerd ? "on ac \($0.onAC.rawValue) battery \($0.onBattery.rawValue)" : "off" } ?? "unknown")
            + " battery " + (s.battery?.percent.map { "\($0)" } ?? "none")
    }
}

/// A slider position (0…1) and the minutes it means: the stops, then Never.
public enum EnergySlider {
    public static var positions: Int { EnergyPrefs.stops.count + 1 }

    public static func minutes(at t: Double) -> Int {
        let i = Int((max(0, min(1, t)) * Double(positions - 1)).rounded())
        return i < EnergyPrefs.stops.count ? EnergyPrefs.stops[i] : 0
    }

    public static func position(_ minutes: Int) -> Double {
        guard minutes > 0 else { return 1 }
        let i = EnergyPrefs.stops.firstIndex { $0 >= minutes } ?? EnergyPrefs.stops.count - 1
        return Double(i) / Double(positions - 1)
    }
}

// MARK: - Layout (paint and hit-test read this, §2.9)

public struct EnergyLayout: Equatable, Sendable {
    public struct Row: Equatable, Sendable {
        public let value: String
        public let hit: Rect
        public let control: Rect
    }
    public var computer = Rect(0, 0, 0, 0)       // the tracks
    public var display = Rect(0, 0, 0, 0)
    public var sleepBox = Rect(0, 0, 0, 0)
    public var powerdBox = Rect(0, 0, 0, 0)
    public var powerd = Row(value: "powerd", hit: Rect(0, 0, 0, 0), control: Rect(0, 0, 0, 0))
    public var ac: [Row] = []
    public var battery: [Row] = []
    public var labelRight = 0.0
    public var acBaseline = 0.0, batteryBaseline = 0.0, batteryLineBaseline = 0.0, noteBaseline = 0.0
}

public func energyLayout(body: Rect) -> EnergyLayout {
    var l = EnergyLayout()
    let left = body.x + 40, w = body.w - 80
    l.sleepBox = Rect(left, body.y + 18, w, 186)
    l.computer = Rect(left + 20, body.y + 70, w - 40, 20)
    l.display = Rect(left + 20, body.y + 140, w - 40, 20)
    var y = l.sleepBox.y + l.sleepBox.h + 16
    l.powerdBox = Rect(left, y, w, 128)
    y += 26
    l.powerd = .init(value: "powerd", hit: Rect(left + 16, y, 420, 22), control: Rect(left + 16, y + 3, 16, 16))
    y += 30
    l.labelRight = left + 150
    l.acBaseline = y + 15
    var x = l.labelRight + 12
    for m in PowerdMode.allCases {
        l.ac.append(.init(value: m.rawValue, hit: Rect(x, y, 108, 22), control: Rect(x, y + 3, 16, 16)))
        x += 112
    }
    y += 28
    l.batteryBaseline = y + 15
    x = l.labelRight + 12
    for m in PowerdMode.allCases {
        l.battery.append(.init(value: m.rawValue, hit: Rect(x, y, 108, 22), control: Rect(x, y + 3, 16, 16)))
        x += 112
    }
    l.batteryLineBaseline = l.powerdBox.y + l.powerdBox.h + 28
    l.noteBaseline = l.batteryLineBaseline + 26
    return l
}

public enum EnergyHit: Equatable, Sendable {
    /// A sleep slider — the computer's or the display's — and the minutes the
    /// pointer's x means on it.
    case sleep(display: Bool, minutes: Int)
    case powerd
    case ac(PowerdMode)
    case battery(PowerdMode)
}

public func energyHit(_ l: EnergyLayout, x: Double, y: Double) -> EnergyHit? {
    func t(_ r: Rect) -> Double { (x - r.x) / max(1, r.w) }
    func near(_ r: Rect) -> Bool { x >= r.x - 8 && x <= r.x + r.w + 8 && y >= r.y - 6 && y <= r.y + r.h + 6 }
    if near(l.computer) { return .sleep(display: false, minutes: EnergySlider.minutes(at: t(l.computer))) }
    if near(l.display) { return .sleep(display: true, minutes: EnergySlider.minutes(at: t(l.display))) }
    if l.powerd.hit.contains(x, y) { return .powerd }
    if let r = l.ac.first(where: { $0.hit.contains(x, y) }), let m = PowerdMode(rawValue: r.value) { return .ac(m) }
    if let r = l.battery.first(where: { $0.hit.contains(x, y) }), let m = PowerdMode(rawValue: r.value) { return .battery(m) }
    return nil
}

// MARK: - Paint

public func paintEnergyPane(_ cr: OpaquePointer, _ l: EnergyLayout, _ s: EnergyPaneState) {
    Draw.groupBox(cr, l.sleepBox, title: "Sleep")
    func slider(_ track: Rect, _ title: String, _ minutes: Int) {
        Draw.textLeft(cr, title, x: track.x, baselineY: track.y - 10, color: Theme.bodyText, size: 13)
        Draw.slider(cr, track, value: EnergySlider.position(minutes))
        let words = EnergyPrefs.words(minutes)
        let w = Draw.textWidth(cr, words, size: 12)
        Draw.textLeft(cr, words, x: track.x + track.w - w, baselineY: track.y - 10, color: Theme.secondaryText, size: 12)
        Draw.textLeft(cr, "1 min", x: track.x, baselineY: track.y + track.h + 12, color: Theme.secondaryText, size: 10)
        let n = Draw.textWidth(cr, "Never", size: 10)
        Draw.textLeft(cr, "Never", x: track.x + track.w - n, baselineY: track.y + track.h + 12, color: Theme.secondaryText, size: 10)
    }
    slider(l.computer, "Put the computer to sleep when it is inactive for:", s.prefs.systemSleepMinutes)
    slider(l.display, "Put the display to sleep when the computer is inactive for:", s.prefs.displaySleepMinutes)
    Draw.text(cr, "Nothing sleeps on its own yet: these are kept for when it does.  "
              + EnergyWords.sleepStates(s.sleepStates),
              centerX: l.sleepBox.x + l.sleepBox.w / 2, centerY: l.sleepBox.y + l.sleepBox.h - 12,
              color: Theme.secondaryText, size: 11)

    Draw.groupBox(cr, l.powerdBox, title: "Processor")
    let on = s.powerd?.powerd ?? false
    Draw.checkbox(cr, l.powerd.control, checked: on)
    Draw.textLeft(cr, "Adjust the processor's speed to the work (powerd)", x: l.powerd.control.x + 24,
                  baselineY: l.powerd.control.y + 12, color: Theme.bodyText, size: 13)
    func heading(_ t: String, _ baseline: Double) {
        let w = Draw.textWidth(cr, t, size: 13)
        Draw.textLeft(cr, t, x: l.labelRight - w, baselineY: baseline, color: on ? Theme.bodyText : Theme.secondaryText, size: 13)
    }
    heading("On AC power:", l.acBaseline)
    heading("On battery:", l.batteryBaseline)
    for (rows, chosen) in [(l.ac, s.powerd?.onAC), (l.battery, s.powerd?.onBattery)] {
        for r in rows {
            guard let m = PowerdMode(rawValue: r.value) else { continue }
            Draw.radioButton(cr, cx: r.control.x + 8, cy: r.control.y + 8, radius: 7, selected: m == chosen)
            Draw.textLeft(cr, EnergyWords.mode(m), x: r.control.x + 22,
                          baselineY: r.control.y + 12, color: on ? Theme.bodyText : Theme.secondaryText, size: 12)
        }
    }
    Draw.textLeft(cr, "Battery: " + EnergyWords.battery(s.battery), x: l.sleepBox.x, baselineY: l.batteryLineBaseline,
                  color: Theme.bodyText, size: 13)
    if !s.note.isEmpty {
        Draw.textLeft(cr, s.note, x: l.sleepBox.x, baselineY: l.noteBaseline, color: Theme.bodyText, size: 12)
    }
}
