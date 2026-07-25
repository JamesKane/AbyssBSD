// Dock — the magnifying Jaguar Dock: a wlr-layer-shell BOTTOM surface with a
// translucent rounded shelf of app tiles that magnify under the pointer, running
// indicators beneath open apps, and the Trash at the right.
//
// This is net-new design (the Rust sibling's GNOME-2 shell had no Dock), so the
// 512px Jaguar reference is the spec. The magnification curve is the centrepiece:
// a pure function (`dockMagnify`) computes each tile's scaled size and centre
// from the pointer position, so it's unit-testable and shared by paint + hit
// test. Running apps come from ForeignToplevels; clicking a tile activates its
// window. Icons are original procedural glyphs (not Apple artwork), per policy.

import Surface
import PoolConfig
import CCairo

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

private let kBtnLeft: UInt32 = 0x110

public enum DockIcon: Sendable {
    case finder, browser, mail, music, prefs, genericApp, trash
}

public struct DockItem: Sendable {
    public let icon: DockIcon
    public let label: String
    public let appID: String?   // matches a running toplevel's app_id; nil for Trash
    public let isTrash: Bool
    /// What to run when the tile isn't already running. argv, plus environment
    /// to add — nil for a tile we can't launch (yet).
    public let command: [String]?
    public let environment: [String: String]

    public init(icon: DockIcon, label: String, appID: String?, isTrash: Bool = false,
                command: [String]? = nil, environment: [String: String] = [:]) {
        self.icon = icon; self.label = label; self.appID = appID; self.isTrash = isTrash
        self.command = command; self.environment = environment
    }
}

/// One tile's laid-out geometry: its centre x and current (magnified) size.
public struct DockTileFrame: Equatable, Sendable {
    public var centerX: Double
    public var size: Double
    public var scale: Double
}

public enum DockMetrics {
    public static let gap: Double = 6
    public static let maxScale: Double = 1.9
    public static let panelPadV: Double = 6
    public static let panelPadH: Double = 12
    public static let bottomMargin: Double = 6
    /// Surface height needed to fit a magnified tile of base `size`.
    public static func surfaceHeight(tileSize: Double) -> Double {
        (tileSize * maxScale + 2 * panelPadV + bottomMargin + 20).rounded(.up)
    }
}

/// The magnification layout — the Dock's defining curve. Distances are measured
/// against the fixed base layout (stable), then tiles are re-laid-out at their
/// scaled sizes, centred on `centerX`. `pointerX` nil = no magnification (rest).
public func dockMagnify(count: Int, baseSize S: Double, gap G: Double,
                        centerX: Double, pointerX: Double?,
                        maxScale M: Double, range R: Double) -> [DockTileFrame] {
    guard count > 0 else { return [] }
    let baseW = Double(count) * S + Double(count - 1) * G
    let baseLeft = centerX - baseW / 2

    var scales = [Double](repeating: 1, count: count)
    if let px = pointerX {
        for i in 0..<count {
            let c = baseLeft + Double(i) * (S + G) + S / 2   // base centre
            let t = abs(c - px) / R
            if t < 1 { scales[i] = 1 + (M - 1) * (cos(.pi * t) + 1) / 2 }
        }
    }

    let sizes = scales.map { S * $0 }
    let totalW = sizes.reduce(0, +) + Double(count - 1) * G
    var left = centerX - totalW / 2
    var frames: [DockTileFrame] = []
    frames.reserveCapacity(count)
    for i in 0..<count {
        frames.append(DockTileFrame(centerX: left + sizes[i] / 2,
                                    size: sizes[i], scale: scales[i]))
        left += sizes[i] + G
    }
    return frames
}

/// Paint the Dock, returning the tile frames for hit-testing (layout is truth).
@discardableResult
public func paintDock(_ cr: OpaquePointer, w: Double, h: Double,
                      items: [DockItem], running: [Bool], pointerX: Double?,
                      tileSize S: Double, magnify: Bool) -> [DockTileFrame] {
    let frames = dockMagnify(count: items.count, baseSize: S, gap: DockMetrics.gap,
                             centerX: w / 2, pointerX: magnify ? pointerX : nil,
                             maxScale: DockMetrics.maxScale,
                             range: 2.2 * (S + DockMetrics.gap))
    guard !frames.isEmpty else { return frames }

    let panelBottom = h - DockMetrics.bottomMargin
    let iconBottom = panelBottom - DockMetrics.panelPadV
    let panelH = S + 2 * DockMetrics.panelPadV
    let panelTop = panelBottom - panelH
    let left = frames.first!.centerX - frames.first!.size / 2 - DockMetrics.panelPadH
    let right = frames.last!.centerX + frames.last!.size / 2 + DockMetrics.panelPadH
    let panel = Rect(left, panelTop, right - left, panelH)

    // The translucent shelf.
    Draw.roundedRect(cr, panel, radius: panelH / 4)
    let g = cairo_pattern_create_linear(0, panelTop, 0, panelBottom)
    cairo_pattern_add_color_stop_rgba(g, 0, 1, 1, 1, 0.55)
    cairo_pattern_add_color_stop_rgba(g, 1, 0.86, 0.88, 0.92, 0.5)
    cairo_set_source(cr, g)
    cairo_fill_preserve(cr)
    cairo_pattern_destroy(g)
    cairo_set_source_rgba(cr, 0, 0, 0, 0.28)
    cairo_set_line_width(cr, 1)
    cairo_stroke(cr)

    // A separator just before the Trash (if present).
    if let ti = items.firstIndex(where: { $0.isTrash }), ti > 0 {
        let sx = (frames[ti - 1].centerX + frames[ti - 1].size / 2
                  + frames[ti].centerX - frames[ti].size / 2) / 2
        cairo_set_source_rgba(cr, 0, 0, 0, 0.22)
        cairo_move_to(cr, sx, panelTop + 6); cairo_line_to(cr, sx, panelBottom - 6)
        cairo_stroke(cr)
    }

    for (i, item) in items.enumerated() {
        let sz = frames[i].size
        let rect = Rect(frames[i].centerX - sz / 2, iconBottom - sz, sz, sz)
        drawDockIcon(cr, item.icon, rect)
        if running[i] {
            // A small dark triangle beneath the tile (Jaguar's running mark).
            let cx = frames[i].centerX, ty = panelBottom - 3
            cairo_new_path(cr)
            cairo_move_to(cr, cx - 3, ty)
            cairo_line_to(cr, cx + 3, ty)
            cairo_line_to(cr, cx, ty - 4)
            cairo_close_path(cr)
            cairo_set_source_rgba(cr, 0.1, 0.1, 0.1, 0.85)
            cairo_fill(cr)
        }
    }

    // Label the hovered (most-magnified) tile, in a small tooltip above it.
    if magnify, pointerX != nil,
       let hi = frames.indices.max(by: { frames[$0].scale < frames[$1].scale }),
       frames[hi].scale > 1.15 {
        drawDockLabel(cr, items[hi].label, centerX: frames[hi].centerX,
                      bottomY: iconBottom - frames[hi].size - 8)
    }
    return frames
}

private func drawDockLabel(_ cr: OpaquePointer, _ text: String,
                           centerX: Double, bottomY: Double) {
    let tw = Draw.textWidth(cr, text, size: 12)
    let padX = 8.0, hgt = 20.0
    let box = Rect(centerX - tw / 2 - padX, bottomY - hgt, tw + 2 * padX, hgt)
    Draw.roundedRect(cr, box, radius: 5)
    cairo_set_source_rgba(cr, 0.12, 0.12, 0.14, 0.9)
    cairo_fill(cr)
    Draw.text(cr, text, centerX: centerX, centerY: box.y + hgt / 2,
              color: Color(1, 1, 1), size: 12)
}

// MARK: procedural Dock icons (original glyphs, not Apple artwork)

private func drawDockIcon(_ cr: OpaquePointer, _ kind: DockIcon, _ r: Rect) {
    switch kind {
    case .trash: drawTrash(cr, r); return
    default: break
    }
    // A rounded app tile with a per-app hue, a top sheen, and a white emblem.
    let (top, bot): (Color, Color)
    switch kind {
    case .finder:   (top, bot) = (Color(hex: 0x5a86c4), Color(hex: 0x2f5698))
    case .browser:  (top, bot) = (Color(hex: 0x3fb0a6), Color(hex: 0x1d7d78))
    case .mail:     (top, bot) = (Color(hex: 0x6fa8e6), Color(hex: 0x3a6fc0))
    case .music:    (top, bot) = (Color(hex: 0xc06fd0), Color(hex: 0x8236a8))
    case .prefs:    (top, bot) = (Color(hex: 0x9aa2ad), Color(hex: 0x5c636e))
    default:        (top, bot) = (Color(hex: 0xb8beca), Color(hex: 0x7c8494))
    }
    let radius = r.w * 0.22
    Draw.roundedRect(cr, r, radius: radius)
    let g = cairo_pattern_create_linear(0, r.y, 0, r.y + r.h)
    cairo_pattern_add_color_stop_rgba(g, 0, top.r, top.g, top.b, 1)
    cairo_pattern_add_color_stop_rgba(g, 1, bot.r, bot.g, bot.b, 1)
    cairo_set_source(cr, g); cairo_fill(cr); cairo_pattern_destroy(g)
    // top sheen
    Draw.roundedRect(cr, Rect(r.x + 2, r.y + 2, r.w - 4, r.h * 0.42), radius: radius * 0.7)
    cairo_set_source_rgba(cr, 1, 1, 1, 0.22); cairo_fill(cr)

    cairo_save(cr)
    cairo_translate(cr, r.x, r.y)
    let s = r.w
    switch kind {
    case .finder:   emblemFolder(cr, s)
    case .browser:  emblemGlobe(cr, s)
    case .mail:     emblemEnvelope(cr, s)
    case .music:    emblemNote(cr, s)
    case .prefs:    emblemGear(cr, s)
    default:        emblemWindow(cr, s)
    }
    cairo_restore(cr)
}

private func emblemFolder(_ cr: OpaquePointer, _ s: Double) {
    cairo_set_source_rgba(cr, 1, 1, 1, 0.95)
    let x = s * 0.24, y = s * 0.34, w = s * 0.52, h = s * 0.34
    Draw.roundedRect(cr, Rect(x, y + s * 0.06, w, h), radius: s * 0.04); cairo_fill(cr)
    Draw.roundedRect(cr, Rect(x, y, w * 0.42, s * 0.10), radius: s * 0.03); cairo_fill(cr)
}

private func emblemGlobe(_ cr: OpaquePointer, _ s: Double) {
    cairo_set_source_rgba(cr, 1, 1, 1, 0.95)
    cairo_set_line_width(cr, s * 0.05)
    let cx = s / 2, cy = s / 2, rad = s * 0.26
    cairo_new_sub_path(cr); cairo_arc(cr, cx, cy, rad, 0, 2 * .pi); cairo_stroke(cr)
    cairo_new_sub_path(cr); cairo_arc(cr, cx, cy, rad * 0.5, 0, 2 * .pi)
    cairo_save(cr); cairo_translate(cr, cx, cy); cairo_scale(cr, 0.45, 1); cairo_translate(cr, -cx, -cy)
    cairo_new_sub_path(cr); cairo_arc(cr, cx, cy, rad, 0, 2 * .pi); cairo_restore(cr)
    cairo_move_to(cr, cx - rad, cy); cairo_line_to(cr, cx + rad, cy)
    cairo_stroke(cr)
}

private func emblemEnvelope(_ cr: OpaquePointer, _ s: Double) {
    cairo_set_source_rgba(cr, 1, 1, 1, 0.95)
    let x = s * 0.24, y = s * 0.34, w = s * 0.52, h = s * 0.32
    Draw.roundedRect(cr, Rect(x, y, w, h), radius: s * 0.03); cairo_fill(cr)
    cairo_set_source_rgba(cr, 0.3, 0.45, 0.7, 0.9)
    cairo_set_line_width(cr, s * 0.045)
    cairo_move_to(cr, x + s * 0.02, y + s * 0.02)
    cairo_line_to(cr, x + w / 2, y + h * 0.55)
    cairo_line_to(cr, x + w - s * 0.02, y + s * 0.02)
    cairo_stroke(cr)
}

private func emblemNote(_ cr: OpaquePointer, _ s: Double) {
    cairo_set_source_rgba(cr, 1, 1, 1, 0.95)
    cairo_set_line_width(cr, s * 0.06)
    cairo_move_to(cr, s * 0.42, s * 0.30); cairo_line_to(cr, s * 0.42, s * 0.64); cairo_stroke(cr)
    cairo_move_to(cr, s * 0.62, s * 0.26); cairo_line_to(cr, s * 0.62, s * 0.60); cairo_stroke(cr)
    cairo_move_to(cr, s * 0.42, s * 0.30); cairo_line_to(cr, s * 0.62, s * 0.26); cairo_stroke(cr)
    cairo_new_sub_path(cr); cairo_arc(cr, s * 0.36, s * 0.64, s * 0.07, 0, 2 * .pi); cairo_fill(cr)
    cairo_new_sub_path(cr); cairo_arc(cr, s * 0.56, s * 0.60, s * 0.07, 0, 2 * .pi); cairo_fill(cr)
}

private func emblemGear(_ cr: OpaquePointer, _ s: Double) {
    cairo_set_source_rgba(cr, 1, 1, 1, 0.95)
    let cx = s / 2, cy = s / 2, rad = s * 0.2
    for k in 0..<8 {
        let a = Double(k) * .pi / 4
        cairo_save(cr); cairo_translate(cr, cx, cy); cairo_rotate(cr, a)
        cairo_rectangle(cr, -s * 0.04, -rad - s * 0.09, s * 0.08, s * 0.1); cairo_fill(cr)
        cairo_restore(cr)
    }
    cairo_new_sub_path(cr); cairo_arc(cr, cx, cy, rad, 0, 2 * .pi); cairo_fill(cr)
    cairo_set_source_rgba(cr, 0.36, 0.4, 0.45, 1)
    cairo_new_sub_path(cr); cairo_arc(cr, cx, cy, rad * 0.45, 0, 2 * .pi); cairo_fill(cr)
}

private func emblemWindow(_ cr: OpaquePointer, _ s: Double) {
    cairo_set_source_rgba(cr, 1, 1, 1, 0.95)
    let x = s * 0.26, y = s * 0.30, w = s * 0.48, h = s * 0.4
    Draw.roundedRect(cr, Rect(x, y, w, h), radius: s * 0.03); cairo_fill(cr)
    cairo_set_source_rgba(cr, 0.4, 0.45, 0.55, 0.9)
    cairo_rectangle(cr, x, y, w, s * 0.1); cairo_fill(cr)
}

private func drawTrash(_ cr: OpaquePointer, _ r: Rect) {
    cairo_save(cr)
    cairo_translate(cr, r.x, r.y)
    let s = r.w
    cairo_set_source_rgba(cr, 0.78, 0.80, 0.85, 1)
    cairo_set_line_width(cr, s * 0.05)
    // can body (trapezoid)
    cairo_move_to(cr, s * 0.30, s * 0.34)
    cairo_line_to(cr, s * 0.70, s * 0.34)
    cairo_line_to(cr, s * 0.64, s * 0.74)
    cairo_line_to(cr, s * 0.36, s * 0.74)
    cairo_close_path(cr); cairo_stroke(cr)
    // vertical mesh lines
    for fx in [0.44, 0.5, 0.56] {
        cairo_move_to(cr, s * fx, s * 0.36); cairo_line_to(cr, s * fx, s * 0.72); cairo_stroke(cr)
    }
    // lid + handle
    cairo_move_to(cr, s * 0.26, s * 0.30); cairo_line_to(cr, s * 0.74, s * 0.30); cairo_stroke(cr)
    cairo_move_to(cr, s * 0.42, s * 0.30); cairo_line_to(cr, s * 0.44, s * 0.24)
    cairo_line_to(cr, s * 0.56, s * 0.24); cairo_line_to(cr, s * 0.58, s * 0.30); cairo_stroke(cr)
    cairo_restore(cr)
}

public final class Dock: LayerSurfaceDelegate, ForeignToplevelsDelegate {
    private var layer: LayerSurface?
    private var toplevels: ForeignToplevels?
    private let pinned: [DockItem]
    private let trash: DockItem
    private let tileSize: Double
    private let magnify: Bool

    private var displayItems: [DockItem] = []
    private var running: [Bool] = []
    private var extras: [ToplevelInfo] = []   // running apps not matching a pinned tile
    private var frames: [DockTileFrame] = []
    private var pointerX: Double?
    private var pointerY = 0.0

    public static func defaultPinned() -> [DockItem] {
        // The two tiles that map to something real launch another copy of this
        // binary in the right scene; the rest are placeholders until there are
        // apps behind them.
        let selfExe = Launcher.selfExecutable()
        return [
            DockItem(icon: .finder, label: "Finder", appID: "org.abyssbsd.finder",
                     command: selfExe.map { [$0] },
                     environment: ["AQUA_SCENE": "finder"]),
            DockItem(icon: .browser, label: "Browser", appID: "org.abyssbsd.browser"),
            DockItem(icon: .mail,    label: "Mail",    appID: "org.abyssbsd.mail"),
            DockItem(icon: .music,   label: "Music",   appID: "org.abyssbsd.music"),
            DockItem(icon: .prefs, label: "System Preferences", appID: "org.abyssbsd.prefs",
                     command: selfExe.map { [$0] },
                     environment: ["AQUA_SCENE": "sysprefs"]),
        ]
    }

    public init?(display: Display) {
        let config = (try? Pool.load("dock")) ?? Config()
        tileSize = Double(config.uint64("dock", "tile_size") ?? 48)
        magnify = config.bool("dock", "magnify") ?? true
        pinned = Dock.defaultPinned()
        trash = DockItem(icon: .trash, label: "Trash", appID: nil, isTrash: true)

        let height = Int32(DockMetrics.surfaceHeight(tileSize: tileSize))
        guard let ls = LayerSurface(
            display: display, layer: .bottom, namespace: "abyss.dock",
            width: 0, height: height, anchor: [.bottom, .left, .right],
            exclusiveZone: 0, keyboard: .none, delegate: self)
        else { return nil }
        layer = ls
        rebuild()

        // Track running apps (optional — the compositor may not offer it).
        toplevels = ForeignToplevels(display: display, delegate: self)
    }

    // MARK: ForeignToplevelsDelegate

    public func toplevelsChanged(_ tops: [ToplevelInfo]) {
        let pinnedIDs = Set(pinned.compactMap { $0.appID })
        extras = tops.filter { !pinnedIDs.contains($0.appID) }
        for t in tops {
            Dock.log("running \(t.appID.isEmpty ? "?" : t.appID) '\(t.title)'")
        }
        rebuild()
        layer?.setNeedsDisplay()
    }

    /// Recompute the displayed tiles (pinned + running-unpinned + Trash) and
    /// which have a running indicator.
    private func rebuild() {
        let runningIDs = Set((toplevels?.current ?? []).map { $0.appID })
        var items = pinned
        var flags = pinned.map { item in item.appID.map { runningIDs.contains($0) } ?? false }
        for t in extras {
            let label = t.title.isEmpty ? (t.appID.isEmpty ? "App" : t.appID) : t.title
            items.append(DockItem(icon: .genericApp, label: label, appID: t.appID))
            flags.append(true)
        }
        items.append(trash)
        flags.append(false)
        displayItems = items
        running = flags
    }

    private static func log(_ msg: String) {
        let line = "Dock: \(msg)\n"
        line.withCString { _ = write(2, $0, strlen($0)) }
    }

    // MARK: LayerSurfaceDelegate

    public func render(_ buffer: PixelBuffer) {
        Text.renderScale = buffer.scale
        let w = Double(buffer.width / buffer.scale)
        let h = Double(buffer.height / buffer.scale)
        let cs = cairo_image_surface_create_for_data(
            buffer.data.assumingMemoryBound(to: UInt8.self),
            CAIRO_FORMAT_ARGB32, buffer.width, buffer.height, buffer.stride)
        guard let cr = cairo_create(cs) else { cairo_surface_destroy(cs); return }
        cairo_scale(cr, Double(buffer.scale), Double(buffer.scale))
        cairo_save(cr); cairo_set_operator(cr, CAIRO_OPERATOR_CLEAR); cairo_paint(cr); cairo_restore(cr)
        cairo_set_operator(cr, CAIRO_OPERATOR_OVER)
        frames = paintDock(cr, w: w, h: h, items: displayItems, running: running,
                           pointerX: pointerX, tileSize: tileSize, magnify: magnify)
        cairo_surface_flush(cs)
        cairo_destroy(cr)
        cairo_surface_destroy(cs)
    }

    public func pointerMoved(x: Double, y: Double) {
        pointerX = x; pointerY = y
        layer?.setNeedsDisplay()   // re-magnify
    }

    public func pointerLeft() {
        if pointerX != nil { pointerX = nil; layer?.setNeedsDisplay() }
    }

    public func pointerButton(_ button: UInt32, pressed: Bool) {
        guard button == kBtnLeft, pressed, let px = pointerX else { return }
        // Hit-test the tile the pointer is over (using the drawn frames).
        let h = Double(layer?.size.height ?? 0)
        let iconBottom = h - DockMetrics.bottomMargin - DockMetrics.panelPadV
        for (i, f) in frames.enumerated() {
            let rect = Rect(f.centerX - f.size / 2, iconBottom - f.size, f.size, f.size)
            guard px >= rect.x, px <= rect.x + rect.w,
                  pointerY >= rect.y, pointerY <= rect.y + rect.h else { continue }
            activate(displayItems[i])
            return
        }
    }

    private func activate(_ item: DockItem) {
        if item.isTrash { Dock.log("clicked Trash"); return }
        guard let appID = item.appID else { return }
        // Running: raise it. Not running: launch it, if the tile knows how.
        if toplevels?.activate(appID: appID) == true {
            Dock.log("activated \(appID)")
            return
        }
        guard let command = item.command else {
            Dock.log("no launcher for \(appID)")
            return
        }
        if Launcher.launchDetached(command, extraEnv: item.environment) {
            Dock.log("launched \(appID)")
        } else {
            Dock.log("launch failed for \(appID)")
        }
    }
}
