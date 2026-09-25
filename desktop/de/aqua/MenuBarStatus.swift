// The menu bar's status items — Jaguar's "menu extras": volume and battery,
// sitting between the app menus and the clock.
//
// The data comes from `Vents`, which reads the machine the FreeBSD way (sysctl,
// OSS). The rule this file exists to enforce is **an item you can't feed isn't
// drawn**: a desktop with no sound card hides the speaker rather than showing a
// confident 0%, and a machine with no battery hides the battery rather than
// claiming it's full. So every field here is optional, and layout skips what is
// nil — which is exactly what the build VM shows, since qemu gives us neither.

import CCairo
import CVents
import Vents

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// What the status area has to show right now. Empty is a valid state.
public struct MenuBarStatus: Equatable, Sendable {
    /// Master volume, 0...100, or nil when there is no mixer.
    public var volume: UInt8?
    /// Battery charge 0...100, or nil when there is no battery (or the kernel
    /// doesn't know yet).
    public var batteryPercent: Int?
    /// Drawn as a plug/bolt on the battery.
    public var batteryCharging: Bool

    public init(volume: UInt8? = nil, batteryPercent: Int? = nil, batteryCharging: Bool = false) {
        self.volume = volume
        self.batteryPercent = batteryPercent
        self.batteryCharging = batteryCharging
    }

    public var isEmpty: Bool { volume == nil && batteryPercent == nil }

    /// Read the machine.
    ///
    /// `$ABYSS_FAKE_VOLUME` / `$ABYSS_FAKE_BATTERY` override the real bridges.
    /// They exist so the *drawing* can be exercised on a machine that has
    /// neither — the Linux dev box and the build VM both lack a mixer and a
    /// battery — and they are read only here, never inside `Vents`, so the
    /// bridges themselves are never faked.
    public static func read(mixer: Vents.Mixer?) -> MenuBarStatus {
        var s = MenuBarStatus()
        if let fake = envInt("ABYSS_FAKE_VOLUME") {
            s.volume = UInt8(clamping: fake)
        } else if let level = mixer?.level() {
            s.volume = level.mono
        }
        if let fake = envInt("ABYSS_FAKE_BATTERY") {
            s.batteryPercent = max(0, min(100, fake))
            s.batteryCharging = getenv("ABYSS_FAKE_BATTERY_CHARGING") != nil
        } else if let b = Vents.Battery.read() {
            s.batteryPercent = b.percent
            s.batteryCharging = b.isCharging
        }
        return s
    }

    private static func envInt(_ name: String) -> Int? {
        guard let v = getenv(name), v.pointee != 0 else { return nil }
        return Int(String(cString: v))
    }
}

public enum MenuBarStatusMetrics {
    /// Each item's slot. Wide enough for the battery's "100%" label.
    public static var volumeWidth: Double { Theme.current.statusVolumeWidth }
    public static var batteryWidth: Double { Theme.current.statusBatteryWidth }
    public static var gap: Double { Theme.current.statusGap }
    /// Space between the last status item and the clock.
    public static var clockGap: Double { Theme.current.statusClockGap }
}

/// Where the status items sit, right-aligned against `rightEdge` (the clock's
/// left edge). Pure geometry, shared by paint and hit-test — the §2.9 rule, so
/// a click on the speaker can never land somewhere else than it looks.
///
/// Items are laid out right-to-left in a fixed order (battery nearest the
/// clock, then volume), which is how Jaguar's menu extras behaved.
public func menuBarStatusLayout(status: MenuBarStatus, h: Double,
                                rightEdge: Double) -> (volume: Rect?, battery: Rect?) {
    var x = rightEdge - MenuBarStatusMetrics.clockGap
    var battery: Rect?
    var volume: Rect?
    if status.batteryPercent != nil {
        x -= MenuBarStatusMetrics.batteryWidth
        battery = Rect(x, 0, MenuBarStatusMetrics.batteryWidth, h)
        x -= MenuBarStatusMetrics.gap
    }
    if status.volume != nil {
        x -= MenuBarStatusMetrics.volumeWidth
        volume = Rect(x, 0, MenuBarStatusMetrics.volumeWidth, h)
    }
    return (volume, battery)
}

/// Draw the status items. Returns their rects so the caller can hit-test.
@discardableResult
public func paintMenuBarStatus(_ cr: OpaquePointer, status: MenuBarStatus,
                               h: Double, rightEdge: Double,
                               color: Color) -> (volume: Rect?, battery: Rect?) {
    let rects = menuBarStatusLayout(status: status, h: h, rightEdge: rightEdge)
    if let r = rects.volume, let level = status.volume {
        // shell.dl: status.volume.0…3, one arc per third of the range.
        let arcs = level == 0 ? 0 : (Int(level) - 1) / 34 + 1
        Draw.paint("status.volume.\(arcs)", cr, Rect(r.x + 2, (h - 12) / 2, 14, 12),
                   colors: ["color": color])
    }
    if let r = rects.battery, let pct = status.batteryPercent {
        Draw.paint("status.battery", cr, Rect(r.x, (h - 10) / 2, 22, 10),
                   status.batteryCharging ? .active : [],
                   parameters: ["charge": Double(max(0, min(100, pct))) / 100],
                   colors: ["color": color])
        Draw.textLeft(cr, "\(pct)%", x: r.x + 26, baselineY: h - 6.5,
                      color: color, size: MenuBarMetrics.fontSize - 1)
    }
    return rects
}
