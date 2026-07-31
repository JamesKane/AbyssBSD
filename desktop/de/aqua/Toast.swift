// Notifications — the Aqua toast (PHASE7.md P7.4).
//
// A design decision as much as an implementation (§6.5): Jaguar had no
// system-wide notification style — Growl arrived later and was third-party — so
// there is no 512pixels reference to copy. What is drawn here is built from the
// era's own vocabulary instead: a translucent rounded panel in the sheet/palette
// idiom, a bold summary over a lighter body, sitting under the menu bar at the
// top right where menu extras live.
//
// The geometry is pure and unit-tested, so stacking and expiry can be reasoned
// about without a compositor — the §2.9 "one layout function feeds paint and
// hit-test" rule, which here also decides where a click lands.

import CCairo

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// One notification on screen.
public struct Toast: Equatable, Sendable {
    public let id: UInt64
    public let summary: String
    public let body: String?
    /// Monotonic seconds when this toast should disappear.
    public let expiresAt: Double

    public init(id: UInt64, summary: String, body: String? = nil, expiresAt: Double) {
        self.id = id
        self.summary = summary
        self.body = body
        self.expiresAt = expiresAt
    }
}

public enum ToastMetrics {
    public static let width: Double = 300
    /// Clear of the menu bar's exclusive zone, so a toast never sits on it.
    public static let topInset: Double = 8
    public static let rightInset: Double = 12
    public static let gap: Double = 8
    public static let padX: Double = 14
    public static let padY: Double = 11
    public static let summarySize: Double = 13
    public static let bodySize: Double = 12
    public static let lineHeight: Double = 16
    public static let corner: Double = 10
    /// A toast with no body is this tall; a body adds line height per line.
    public static let baseHeight: Double = 42
    /// Refuse to grow without bound: a "notification" that needs ten lines is a
    /// window, and a wall of text from an app must not cover the screen.
    public static let maxBodyLines = 4
}

/// Wrap `text` to `width`, breaking on spaces, and cap the number of lines —
/// the last line is elided rather than dropped, so text is never silently lost
/// without a sign.
public func toastWrap(_ cr: OpaquePointer, _ text: String, width: Double,
                      size: Double, maxLines: Int) -> [String] {
    guard !text.isEmpty, maxLines > 0 else { return [] }
    var lines: [String] = []
    var current = ""
    for word in text.split(separator: " ", omittingEmptySubsequences: true) {
        let candidate = current.isEmpty ? String(word) : current + " " + word
        if Draw.textWidth(cr, candidate, size: size) <= width || current.isEmpty {
            current = candidate
        } else {
            lines.append(current)
            current = String(word)
            if lines.count == maxLines { break }
        }
    }
    if lines.count < maxLines && !current.isEmpty { lines.append(current) }
    if lines.count == maxLines, !current.isEmpty, lines.last != current {
        lines[maxLines - 1] = lines[maxLines - 1] + "…"
    }
    return lines
}

/// The height one toast needs, given its wrapped body.
public func toastHeight(bodyLines: Int) -> Double {
    ToastMetrics.baseHeight + Double(max(0, bodyLines)) * ToastMetrics.lineHeight
}

/// Where each toast sits within the notification surface, newest first, stacked
/// downward. Returns the rects and the surface size needed to hold them.
///
/// The surface is sized to the stack on purpose: an OVERLAY layer surface takes
/// pointer input wherever it extends, so one covering the whole screen would
/// swallow clicks meant for the desktop.
public func toastLayout(heights: [Double]) -> (rects: [Rect], width: Double, height: Double) {
    var rects: [Rect] = []
    var y: Double = 0
    for h in heights {
        rects.append(Rect(0, y, ToastMetrics.width, h))
        y += h + ToastMetrics.gap
    }
    let total = rects.isEmpty ? 0 : y - ToastMetrics.gap
    return (rects, ToastMetrics.width, total)
}

/// Which toast a click at `y` lands on, or nil for the gaps between them.
public func toastIndex(at y: Double, rects: [Rect]) -> Int? {
    for (i, r) in rects.enumerated() where y >= r.y && y < r.y + r.h { return i }
    return nil
}

/// Everything still live at `now`, in display order. Pure, so expiry is
/// testable without waiting.
public func liveToasts(_ toasts: [Toast], now: Double) -> [Toast] {
    toasts.filter { $0.expiresAt > now }
}

/// Paint one toast: a translucent panel, a bold summary, a lighter body.
public func paintToast(_ cr: OpaquePointer, _ r: Rect, toast: Toast, bodyLines: [String]) {
    // A soft shadow so the panel reads over any wallpaper, then the panel.
    cairo_save(cr)
    Draw.roundedRect(cr, Rect(r.x + 1, r.y + 2, r.w, r.h), radius: ToastMetrics.corner)
    cairo_set_source_rgba(cr, 0, 0, 0, 0.18)
    cairo_fill(cr)
    cairo_restore(cr)

    Draw.roundedRect(cr, r, radius: ToastMetrics.corner)
    cairo_save(cr)
    cairo_clip_preserve(cr)
    Draw.fillVerticalGradient(cr, y: r.y, h: r.h, stops: [
        (0, Color(hex: 0xfdfdfd, a: 0.96)), (1, Color(hex: 0xe6e8ec, a: 0.96)),
    ])
    Draw.pinstripe(cr, r, Color(hex: 0xd8dbe0, a: 0.45))
    cairo_restore(cr)
    Draw.setColor(cr, Color(hex: 0x8a8f96, a: 0.9))
    cairo_set_line_width(cr, 1)
    cairo_stroke(cr)

    // The drop glyph marks it as coming from the system, the way the menu bar's
    // system menu does — an original mark, not Apple's.
    drawToastMark(cr, Rect(r.x + ToastMetrics.padX, r.y + ToastMetrics.padY + 1, 13, 13))

    let textX = r.x + ToastMetrics.padX + 20
    Draw.textLeft(cr, toast.summary, x: textX,
                  baselineY: r.y + ToastMetrics.padY + 11,
                  color: Theme.bodyText, size: ToastMetrics.summarySize, style: .bold)
    var y = r.y + ToastMetrics.padY + 11 + ToastMetrics.lineHeight
    for line in bodyLines {
        Draw.textLeft(cr, line, x: textX, baselineY: y,
                      color: Theme.bodyText.with(a: 0.75), size: ToastMetrics.bodySize)
        y += ToastMetrics.lineHeight
    }
}

/// The same water-drop mark the menu bar uses, small.
private func drawToastMark(_ cr: OpaquePointer, _ r: Rect) {
    Draw.setColor(cr, Color(hex: 0x4a6fa5))
    let cx = r.x + r.w / 2
    cairo_move_to(cr, cx, r.y)
    cairo_curve_to(cr, cx + r.w * 0.55, r.y + r.h * 0.45,
                   cx + r.w * 0.5, r.y + r.h, cx, r.y + r.h)
    cairo_curve_to(cr, cx - r.w * 0.5, r.y + r.h,
                   cx - r.w * 0.55, r.y + r.h * 0.45, cx, r.y)
    cairo_close_path(cr)
    cairo_fill(cr)
}
