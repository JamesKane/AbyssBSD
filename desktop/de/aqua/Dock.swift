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
private let kBtnRight: UInt32 = 0x111

public enum DockIcon: Sendable {
    case finder, browser, mail, music, prefs, genericApp, trash, trashFull
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
    public static var gap: Double { Theme.current.dockGap }
    public static var maxScale: Double { Theme.current.dockMaxScale }
    public static var panelPadV: Double { Theme.current.dockPanelPadV }
    public static var panelPadH: Double { Theme.current.dockPanelPadH }
    public static var bottomMargin: Double { Theme.current.dockBottomMargin }
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

    Draw.paint("dock.shelf", cr, panel)   // shell.dl

    // A separator just before the Trash (if present).
    if let ti = items.firstIndex(where: { $0.isTrash }), ti > 0 {
        let sx = (frames[ti - 1].centerX + frames[ti - 1].size / 2
                  + frames[ti].centerX - frames[ti].size / 2) / 2
        Draw.paint("dock.separator", cr, panel, parameters: ["x": sx - panel.x])
    }

    for (i, item) in items.enumerated() {
        let sz = frames[i].size
        let rect = Rect(frames[i].centerX - sz / 2, iconBottom - sz, sz, sz)
        drawDockIcon(cr, item.icon, rect)
        if running[i] {
            // A small dark triangle beneath the tile (Jaguar's running mark).
            let cx = frames[i].centerX, ty = panelBottom - 3
            Draw.paint("dock.running", cr, Rect(cx - 3, ty - 4, 6, 4))
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
    Draw.paint("dock.label", cr, box)
    Draw.text(cr, text, centerX: centerX, centerY: box.y + hgt / 2,
              color: Theme.dockLabelText, size: 12)
}

// MARK: procedural Dock icons (original glyphs, not Apple artwork)

private func drawDockIcon(_ cr: OpaquePointer, _ kind: DockIcon, _ r: Rect) {
    switch kind {
    case .trash:     drawTrash(cr, r, full: false); return
    case .trashFull: drawTrash(cr, r, full: true); return
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

private func drawTrash(_ cr: OpaquePointer, _ r: Rect, full: Bool) {
    cairo_save(cr)
    cairo_translate(cr, r.x, r.y)
    let s = r.w
    // A full Trash shows crumpled paper heaped above the rim, drawn *before* the
    // can so the wire mesh reads over it — the same "you can tell at a glance"
    // cue as 10.2, in our own glyph vocabulary.
    if full {
        cairo_set_source_rgba(cr, 0.94, 0.93, 0.88, 1)
        for (fx, fy, fr) in [(0.40, 0.30, 0.09), (0.56, 0.28, 0.10), (0.48, 0.22, 0.07)] {
            cairo_new_sub_path(cr)
            cairo_arc(cr, s * fx, s * fy, s * fr, 0, 2 * .pi)
            cairo_fill(cr)
        }
        cairo_set_source_rgba(cr, 0.72, 0.71, 0.66, 1)
        cairo_set_line_width(cr, s * 0.025)
        cairo_move_to(cr, s * 0.40, s * 0.30); cairo_line_to(cr, s * 0.50, s * 0.26)
        cairo_move_to(cr, s * 0.52, s * 0.32); cairo_line_to(cr, s * 0.60, s * 0.27)
        cairo_stroke(cr)
    }
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
    private let tileSize: Double
    private let magnify: Bool

    private var displayItems: [DockItem] = []
    private var running: [Bool] = []
    /// A tile's open contextual menu (P10.8).
    private var context: ContextMenu?
    private var extras: [ToplevelInfo] = []   // running apps not matching a pinned tile
    private var frames: [DockTileFrame] = []
    private var pointerX: Double?
    private var pointerY = 0.0

    /// Trash state: whether it holds anything (which tile glyph to draw), the
    /// watcher that keeps that honest, and the open tile menu.
    private var trashFull = false
    private var trashWatcher: Pool.Watcher?
    private var menu: AquaMenu?
    private var popup: Popup?

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

        let height = Int32(DockMetrics.surfaceHeight(tileSize: tileSize))
        guard let ls = LayerSurface(
            display: display, layer: .bottom, namespace: "abyss.dock",
            width: 0, height: height, anchor: [.bottom, .left, .right],
            exclusiveZone: 0, keyboard: .none, delegate: self)
        else { return nil }
        layer = ls
        trashFull = !finderTrashContents().isEmpty
        Dock.log("Trash \(trashFull ? "full" : "empty")")
        rebuild()

        // Track running apps (optional — the compositor may not offer it).
        toplevels = ForeignToplevels(display: display, delegate: self)

        // Watch ~/.Trash so the tile shows full/empty without polling — the same
        // run-loop fd hook the desktop uses for ~/Desktop (HANDOFF §2.18). No
        // Trash yet just means nothing to watch until something is thrown away.
        if let dir = finderTrashPath(), finderIsDirectory(dir),
           let w = try? Pool.Watcher(in: dir) {
            trashWatcher = w
            display.addFileDescriptor(w.fileDescriptor) { [weak self] in
                self?.trashChanged()
            }
        }

        acceptDrops(display)
    }

    private func trashChanged() {
        _ = trashWatcher?.drain()
        let full = !finderTrashContents().isEmpty
        guard full != trashFull else { return }
        trashFull = full
        Dock.log("Trash is now \(full ? "full" : "empty")")
        rebuild()
        layer?.setNeedsDisplay()
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
    // MARK: - Drops (P9.3)

    /// Take files dragged onto a tile.
    ///
    /// The Dock is a second client, so a file dragged out of the Finder and onto
    /// the Trash crosses a process boundary — which is the point: this is the
    /// protocol doing the work, not one program's internal bookkeeping.
    ///
    /// **A drag is a grab, so the pointer events stop for its duration.** The
    /// magnification and the hit-test both read `pointerX`/`pointerY`, so the
    /// drag's own motion is fed into them: the tiles swell under the dragged
    /// file exactly as they do under the cursor, and the tile that takes the
    /// drop is the one the person watched grow.
    private func acceptDrops(_ display: Display) {
        guard let clip = display.clipboard else {
            Dock.log("no data device — drops are off")
            return
        }
        clip.acceptedDragTypes = [ClipboardMIME.uriList, ClipboardMIME.text]
        clip.onDragMotion = { [weak self] x, y in
            guard let self, clip.dragSurface == self.layer?.surface else { return }
            self.pointerMoved(x: x, y: y)
        }
        clip.onDragLeave = { [weak self] in self?.pointerLeft() }
        clip.onDrop = { [weak self] _, bytes, x, y in
            guard let self, clip.dragSurface == self.layer?.surface else { return }
            guard let path = finderDroppedPath(bytes), finderExists(path) else { return }
            guard let (i, _) = self.tile(at: x, y) else {
                Dock.log("dropped \(path) on no tile")
                return
            }
            self.dropped(path, on: self.displayItems[i])
        }
    }

    /// The tile under a point, using the frames the last paint actually drew —
    /// magnified tiles are not where the unmagnified layout says they are.
    private func tile(at x: Double, _ y: Double) -> (Int, DockTileFrame)? {
        let h = Double(layer?.size.height ?? 0)
        let iconBottom = h - DockMetrics.bottomMargin - DockMetrics.panelPadV
        for (i, f) in frames.enumerated() {
            let rect = Rect(f.centerX - f.size / 2, iconBottom - f.size, f.size, f.size)
            if x >= rect.x, x <= rect.x + rect.w, y >= rect.y, y <= rect.y + rect.h {
                return (i, f)
            }
        }
        return nil
    }

    /// What a tile does with a file dropped on it.
    ///
    /// The Trash takes anything. An application tile opens the document with
    /// that application — and the Finder is the only application here that can
    /// open anything yet, so every other tile says so rather than swallowing
    /// the drop and doing nothing, which is the worse of the two failures.
    private func dropped(_ path: String, on item: DockItem) {
        if item.isTrash {
            guard let dest = finderMoveToTrash(path) else {
                Dock.log("could not throw away \(path)")
                return
            }
            Dock.log("threw away \(path) -> \(dest)")
            trashChanged()          // the watcher will also fire; this is idempotent
            return
        }
        guard item.appID == "org.abyssbsd.finder", let exe = Launcher.selfExecutable() else {
            Dock.log("\(item.label) does not open documents")
            return
        }
        // A folder opens itself; a file opens the folder it lives in.
        let dir = finderIsDirectory(path) ? path : (finderParent(path) ?? path)
        if Launcher.launchDetached([exe], extraEnv: ["AQUA_SCENE": "finder",
                                                     "ABYSS_FINDER_DIR": dir]) {
            Dock.log("opened \(dir) for \(path)")
        } else {
            Dock.log("failed to open \(dir)")
        }
    }

    private func rebuild() {
        let runningIDs = Set((toplevels?.current ?? []).map { $0.appID })
        var items = pinned
        var flags = pinned.map { item in item.appID.map { runningIDs.contains($0) } ?? false }
        for t in extras {
            let label = t.title.isEmpty ? (t.appID.isEmpty ? "App" : t.appID) : t.title
            items.append(DockItem(icon: .genericApp, label: label, appID: t.appID))
            flags.append(true)
        }
        items.append(DockItem(icon: trashFull ? .trashFull : .trash, label: "Trash",
                              appID: nil, isTrash: true))
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
        guard button == kBtnLeft || button == kBtnRight, pressed,
              let px = pointerX else { return }
        guard let (i, f) = tile(at: px, pointerY) else {
            if button == kBtnRight { closeMenu() }
            return
        }
        if button == kBtnRight {
            let h = Double(layer?.size.height ?? 0)
            openTileMenu(displayItems[i], frame: f,
                         iconBottom: h - DockMetrics.bottomMargin - DockMetrics.panelPadV)
        } else {
            activate(displayItems[i])
        }
    }

    /// The Dock's own commands (P10.8) — defined once, like every other menu
    /// on this desktop, and drawn as a tile's contextual menu.
    static let trashOpen = Command("dock.open-trash", "Open", summary: "Open the Trash in a Finder window.")
    static let trashEmpty = Command("dock.empty-trash", "Empty Trash",
                                    summary: "Permanently delete everything in the Trash.")
    static let appOpen = Command("dock.open", "Open", summary: "Start this application.")
    static let appQuit = Command("dock.quit", "Quit", summary: "Ask this application to quit.")
    static let showInFinder = Command("dock.show-in-finder", "Show In Finder",
                                      summary: "Show where this application lives.")

    /// A tile's menu: the Trash's two commands, or an application's — Open when
    /// it is not running, Quit when it is (P10.8).
    static func tileMenu(isTrash: Bool, running: Bool) -> Menu {
        isTrash ? Menu("Trash", [.command(trashOpen), .command(trashEmpty)])
                : Menu("", [.command(running ? appQuit : appOpen), .separator,
                            .command(showInFinder)])
    }

    private func isRunning(_ item: DockItem) -> Bool {
        guard let id = item.appID else { return false }
        return toplevels?.current.contains { $0.appID == id } ?? false
    }

    /// A tile's contextual menu. The Trash's was the only one until P10.8 —
    /// "Empty Trash" had to live somewhere, and on Mac that somewhere is here.
    private func openTileMenu(_ item: DockItem, frame f: DockTileFrame, iconBottom: Double) {
        closeMenu()
        let running = isRunning(item)
        let menu = Dock.tileMenu(isTrash: item.isTrash, running: running)
        let full = trashFull
        context = ContextMenu.open(
            menu, name: item.isTrash ? "Trash" : item.label,
            enablement: { c in
                switch c.verb {
                case "dock.empty-trash": return full ? .enabled : .disabled("the Trash is empty")
                case "dock.show-in-finder": return .disabled("not available yet")
                default: return .enabled
                }
            },
            log: { Dock.log($0) },
            // Anchor to the tile. The positioner's flip-Y constraint puts the
            // menu *above* the anchor, since the Dock leaves no room below it.
            open: { [weak self] w, h, am in
                self?.layer?.openPopup(
                    anchorX: Int32(f.centerX - f.size / 2), anchorY: Int32(iconBottom - f.size),
                    anchorW: Int32(f.size), anchorH: Int32(f.size),
                    width: w, height: h, delegate: am)
            },
            choose: { [weak self] c in
                guard let self else { return }
                switch c.verb {
                case "dock.open-trash":  self.openTrash()
                case "dock.empty-trash": self.emptyTrash()
                case "dock.open":        self.activate(item)
                case "dock.quit":
                    let n = self.toplevels?.close(appID: item.appID ?? "") ?? 0
                    Dock.log("asked \(item.label) to quit (\(n) window\(n == 1 ? "" : "s"))")
                default: break
                }
            },
            onClose: { [weak self] in self?.context = nil })
        if item.isTrash { Dock.log("opened Trash menu") }
        else { Dock.log("opened \(item.label) menu (\(running ? "running" : "not running"))") }
    }

    private func closeMenu() {
        popup?.close()   // programmatic close does not fire onDismiss
        popup = nil
        menu = nil
        context?.close()
        context = nil
    }

    private func menuDismissed() {   // outside click (compositor popup_done)
        popup = nil
        menu = nil
    }

    /// Widest item, measured on a scratch surface (pointer handlers have no cr).
    private func menuWidth(_ items: [String]) -> Double {
        guard let cs = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, 1, 1),
              let cr = cairo_create(cs) else { return 160 }
        defer { cairo_destroy(cr); cairo_surface_destroy(cs) }
        return items.map { Draw.textWidth(cr, $0, size: Theme.fontSize) }.max() ?? 120
    }

    /// Open the Trash in a Finder window — a plain click on the tile, as on Mac.
    private func openTrash() {
        guard let dir = finderTrashDirectory(), let exe = Launcher.selfExecutable() else {
            Dock.log("cannot open the Trash (no HOME?)")
            return
        }
        if Launcher.launchDetached([exe],
                                   extraEnv: ["AQUA_SCENE": "finder",
                                              "ABYSS_FINDER_DIR": dir]) {
            Dock.log("opened the Trash (\(dir))")
        } else {
            Dock.log("failed to open the Trash")
        }
    }

    /// Empty the Trash — the only place in the shell that permanently deletes.
    private func emptyTrash() {
        let (removed, failed) = finderEmptyTrash()
        Dock.log("emptied Trash: \(removed) removed, \(failed) failed")
        trashFull = !finderTrashContents().isEmpty
        rebuild()
        layer?.setNeedsDisplay()
    }

    private func activate(_ item: DockItem) {
        if item.isTrash { openTrash(); return }
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
