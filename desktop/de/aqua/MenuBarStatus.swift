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
import Surface
import AquaDraw

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// What the status area has to show right now. Empty is a valid state.
public struct MenuBarStatus: Equatable, Sendable {
    /// Master volume, 0...100, or nil when there is no mixer.
    public var volume: UInt8?
    /// The output is muted: the speaker is drawn dimmed (P14.6d).
    public var muted: Bool = false
    /// The device and control the volume is: the default unit's `vol`.
    public var volumeUnit: Int?
    public var volumeControl: String = "vol"
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
    ///
    /// The volume is the **default device's** `vol` (or its first control),
    /// read afresh each time through `/dev/mixerN` — so a change of default
    /// device, or a card that attached after the bar started, is followed on
    /// the next tick rather than never (P14.6d).
    public static func read() -> MenuBarStatus {
        var s = MenuBarStatus()
        if let fake = envInt("ABYSS_FAKE_VOLUME") {
            s.volume = UInt8(clamping: fake)
            s.muted = getenv("ABYSS_FAKE_MUTED") != nil
        } else if let unit = Vents.Sound.defaultUnit() {
            let controls = Vents.Sound.controls(unit: unit)
            if let c = controls.first(where: { $0.name == "vol" }) ?? controls.first {
                s.volume = UInt8(clamping: c.level)
                s.muted = c.muted
                s.volumeUnit = unit
                s.volumeControl = c.name
            }
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
        // shell.dl: status.volume.0…3, one arc per third of the range. Muted,
        // the speaker is dimmed rather than redrawn: every theme has the
        // four lists, and none has to learn a fifth.
        let arcs = level == 0 ? 0 : (Int(level) - 1) / 34 + 1
        Draw.paint("status.volume.\(arcs)", cr, Rect(r.x + 2, (h - 12) / 2, 14, 12),
                   colors: ["color": status.muted ? color.with(a: color.a * 0.35) : color])
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


// MARK: - The volume slider (P14.6d)

/// Jaguar's volume menu extra: a click on the speaker drops a narrow popup with
/// a vertical slider; dragging sets the output level as it moves, and letting
/// go closes it. The level goes straight to `/dev/mixerN` — the user's.
public enum VolumeSliderMetrics {
    public static let width = 34.0
    public static let height = 132.0
    /// The track, top to bottom, inside the popup.
    public static var track: Rect { Rect(9, 12, 16, height - 24) }

    /// The level (0…100) a pointer at `y` means: loud at the top.
    public static func level(y: Double) -> Int {
        let t = track
        return Int((max(0, min(1, (t.y + t.h - y) / t.h)) * 100).rounded())
    }
}

public final class VolumeSlider: PopupDelegate {
    public weak var popup: Popup?
    public private(set) var level: Int
    private var dragging = false
    private let unit: Int, control: String
    /// Called with the level set, when the button comes up.
    public var onDone: (Int) -> Void = { _ in }
    public var onDismiss: () -> Void = {}

    public init(unit: Int, control: String, level: Int) {
        self.unit = unit; self.control = control; self.level = level
    }

    public func render(_ buffer: PixelBuffer) {
        let w = Double(buffer.width / buffer.scale), h = Double(buffer.height / buffer.scale)
        let cs = cairo_image_surface_create_for_data(buffer.data.assumingMemoryBound(to: UInt8.self),
                                                     CAIRO_FORMAT_ARGB32, buffer.width, buffer.height, buffer.stride)
        guard let cr = cairo_create(cs) else { cairo_surface_destroy(cs); return }
        cairo_scale(cr, Double(buffer.scale), Double(buffer.scale))
        cairo_save(cr); cairo_set_operator(cr, CAIRO_OPERATOR_CLEAR); cairo_paint(cr); cairo_restore(cr)
        cairo_set_operator(cr, CAIRO_OPERATOR_OVER)
        Draw.paint("menu", cr, Rect(0, 0, w, h))
        // The theme's slider is horizontal; turned a quarter, it is this one.
        let t = VolumeSliderMetrics.track
        cairo_save(cr)
        cairo_translate(cr, t.x, t.y + t.h)
        cairo_rotate(cr, -Double.pi / 2)
        Draw.slider(cr, Rect(0, 0, t.h, t.w), value: Double(level) / 100)
        cairo_restore(cr)
        cairo_surface_flush(cs); cairo_destroy(cr); cairo_surface_destroy(cs)
    }

    private func set(_ v: Int) {
        guard v != level else { return }
        level = v
        _ = Vents.Sound.set(unit: unit, control: control, left: v, right: v)
        popup?.setNeedsDisplay()
    }

    public func pointerMoved(x: Double, y: Double) {
        lastY = y
        if dragging { set(VolumeSliderMetrics.level(y: y)) }
    }
    private var lastY = 0.0

    public func pointerButton(pressed: Bool) {
        if pressed {
            dragging = true
            set(VolumeSliderMetrics.level(y: lastY))
        } else if dragging {
            dragging = false
            onDone(level)
        }
    }

    public func popupDismissed() { onDismiss() }
}
