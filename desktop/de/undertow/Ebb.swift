// Ebb — every window, side by side, one click to pick (PHASE13 P13.5,
// PRODUCT §7.3).
//
// The tide goes out and leaves everything that was covered in plain sight, then
// comes back. **A view, not a layout:** nothing is moved. Each window is drawn
// scaled into a slot (the scene's `dst_box` already takes any size), the
// desktop is dimmed behind them, and dismissing it draws everything back where
// it was — no window's position was ever touched. Three scopes: this island,
// every island of this display (the archipelago), and this application.

import AquaDraw
import CCairo
import CWlroots

public enum EbbScope: String, Sendable {
    case island, archipelago, app
}

/// The grid. Pure, so its promises have unit tests:
/// - no two slots overlap, and every slot is inside the area;
/// - a window keeps its aspect and is never drawn larger than it is;
/// - **stable**: windows are placed in the order given (by island, then by the
///   id undertow gave them when they opened), so a window's slot does not jump
///   about when another opens — it only shrinks.
public enum EbbLayout {
    public struct Item: Equatable, Sendable {
        public let id: UInt32
        public let width: Int32, height: Int32
        public init(id: UInt32, width: Int32, height: Int32) {
            self.id = id; self.width = width; self.height = height
        }
    }

    public static func arrange(_ items: [Item], in area: Rect, gap: Int32 = 24) -> [UInt32: Rect] {
        let n = items.count
        guard n > 0, area.width > gap * 2, area.height > gap * 2 else { return [:] }
        // The column count that shows the windows largest, all told; on a tie
        // (small windows fit any grid whole), the grid whose cells are most
        // the windows' own shape, so three windows sit in a row, not a tower.
        let shape = items.map { Double($0.width) / Double(max($0.height, 1)) }.reduce(0, +) / Double(n)
        var best = (cols: 1, score: -1.0, misfit: Double.infinity)
        for cols in 1...n {
            let rows = (n + cols - 1) / cols
            let cw = Double(area.width - gap * Int32(cols + 1)) / Double(cols)
            let ch = Double(area.height - gap * Int32(rows + 1)) / Double(rows)
            guard cw > 8, ch > 8 else { continue }
            var score = 0.0
            for it in items {
                let s = min(1, cw / Double(max(it.width, 1)), ch / Double(max(it.height, 1)))
                score += s * s * Double(it.width) * Double(it.height)
            }
            let misfit = abs(log((cw / ch) / shape))
            if score > best.score * 1.0001 || (score >= best.score * 0.9999 && misfit < best.misfit) {
                best = (cols, score, misfit)
            }
        }
        let cols = best.cols, rows = (n + cols - 1) / cols
        let cw = Double(area.width - gap * Int32(cols + 1)) / Double(cols)
        let ch = Double(area.height - gap * Int32(rows + 1)) / Double(rows)
        var out: [UInt32: Rect] = [:]
        for (i, it) in items.enumerated() {
            let row = i / cols, col = i % cols
            // A short last row is centred, as Exposé's was.
            let inRow = row == rows - 1 ? n - row * cols : cols
            let rowInset = Double(cols - inRow) * (cw + Double(gap)) / 2
            let s = min(1, cw / Double(max(it.width, 1)), ch / Double(max(it.height, 1)))
            let w = Double(it.width) * s, h = Double(it.height) * s
            let cx = Double(area.x) + Double(gap) + rowInset + Double(col) * (cw + Double(gap)) + (cw - w) / 2
            let cy = Double(area.y) + Double(gap) + Double(row) * (ch + Double(gap)) + (ch - h) / 2
            out[it.id] = Rect(x: Int32(cx.rounded()), y: Int32(cy.rounded()),
                              width: Int32(w.rounded(.down)), height: Int32(h.rounded(.down)))
        }
        return out
    }
}

/// One Ebb, open (or opening, or closing) on one display.
final class Ebb {
    struct Slot {
        unowned let window: Toplevel
        /// Where the window really is, and where Ebb draws it.
        let home: Rect
        let slot: Rect
    }
    let display: String
    let scope: EbbScope
    private(set) var slots: [Slot]
    /// The window under the pointer, by id.
    var hovered: UInt32?
    /// 0 is every window at home, 1 is every window in its slot. Opening runs
    /// it up; closing runs it down from wherever it is, so Escape mid-way does
    /// not jump.
    private var from: Double = 0, to: Double = 1
    private var start: UInt64
    let durationNs: UInt64

    init(display: String, scope: EbbScope, slots: [Slot], now: UInt64, durationNs: UInt64) {
        self.display = display; self.scope = scope; self.slots = slots
        self.start = now; self.durationNs = durationNs
    }

    /// Eased, 0…1.
    func progress(at now: UInt64) -> Double {
        guard durationNs > 0, now > start else { return durationNs == 0 ? to : from }
        let t = min(1, Double(now - start) / Double(durationNs))
        return from + (to - from) * IslandSlide.ease(t)
    }
    var closing: Bool { to == 0 }
    func finished(at now: UInt64) -> Bool { closing && progress(at: now) <= 0.0001 }

    func close(at now: UInt64) {
        guard !closing else { return }
        from = progress(at: now); to = 0; start = now
    }

    /// Where slot `s` is drawn at `now`.
    func rect(_ s: Slot, at now: UInt64) -> Rect {
        let p = progress(at: now)
        func lerp(_ a: Int32, _ b: Int32) -> Int32 { Int32((Double(a) + (Double(b) - Double(a)) * p).rounded()) }
        return Rect(x: lerp(s.home.x, s.slot.x), y: lerp(s.home.y, s.slot.y),
                    width: lerp(s.home.width, s.slot.width), height: lerp(s.home.height, s.slot.height))
    }

    /// The topmost slot at a point, once open (hit-testing a moving picture
    /// would pick whatever happened to fly past).
    func slot(at x: Double, _ y: Double) -> Slot? {
        guard !closing else { return nil }
        return slots.last { s in
            x >= Double(s.slot.x) && x < Double(s.slot.x + s.slot.width)
                && y >= Double(s.slot.y) && y < Double(s.slot.y + s.slot.height)
        }
    }

    func forget(_ t: Toplevel) { slots.removeAll { $0.window === t } }
}

extension Compositor {
    /// F3, Ctrl-↑, Ctrl-↓ (§6.4): open Ebb on the command display in `scope`,
    /// or — the same key again, or any Ebb key — put the tide back.
    public func toggleEbb(_ scope: EbbScope) {
        let now = Mono.now()
        if let e = ebb, !e.closing { e.close(at: now); Compositor.log("ebb \(e.display) off"); return }
        let d = commandDisplay()
        let appID = seat?.focused?.appID
        let windows = toplevels.filter { t in
            guard t.mapped, !t.minimized, t.islandDisplay == d, wlr_surface_has_buffer(t.surface) else { return false }
            switch scope {
            case .island:      return isOnActiveIsland(t)
            case .archipelago: return true
            case .app:         return appID != nil && t.appID == appID
            }
        }.sorted { ($0.island, $0.id) < ($1.island, $1.id) }
        guard !windows.isEmpty, let box = layout.displays.first(where: { $0.name == d }) else {
            Compositor.log("ebb \(d): nothing to show for \(scope.rawValue)")
            return
        }
        let area = usable[d] ?? box.rect
        let placed = EbbLayout.arrange(windows.map { EbbLayout.Item(id: $0.id, width: $0.width, height: $0.height) },
                                       in: area)
        let slots = windows.compactMap { t -> Ebb.Slot? in
            guard let r = placed[t.id] else { return nil }
            return Ebb.Slot(window: t, home: Rect(x: t.x, y: t.y, width: t.width, height: t.height), slot: r)
        }
        let ms = islands.animate ? UInt64(min(islands.slideMs, 2000)) : 0
        ebb = Ebb(display: d, scope: scope, slots: slots, now: now, durationNs: ms * 1_000_000)
        ebbOpens &+= 1
        Compositor.log("ebb \(d) on \(scope.rawValue): \(slots.count) window(s)")
        for s in slots {
            Compositor.log("ebb-slot \(s.window.placeKey ?? "?") \(s.slot.x),\(s.slot.y) \(s.slot.width)x\(s.slot.height)")
        }
    }

    /// The pointer moved, with Ebb open: which window it is over.
    func ebbHover(_ x: Double, _ y: Double) {
        guard let e = ebb else { return }
        e.hovered = e.slot(at: x, y)?.window.id
    }

    /// A click, with Ebb open: on a window, go to it (its island first) and put
    /// the tide back; anywhere else, just put it back.
    func ebbClick(_ x: Double, _ y: Double) {
        guard let e = ebb, !e.closing else { return }
        let now = Mono.now()
        if let s = e.slot(at: x, y) {
            Compositor.log("ebb picked \(s.window.placeKey ?? "?")")
            bringToFront(s.window)
        }
        e.close(at: now)
        Compositor.log("ebb \(e.display) off")
    }

    /// Escape, with Ebb open.
    func ebbDismiss() {
        guard let e = ebb, !e.closing else { return }
        e.close(at: Mono.now())
        Compositor.log("ebb \(e.display) off")
    }

    /// Ebb as display `d`'s scene should draw it at `now`, or nil; a finished
    /// close is forgotten here.
    func ebbFrame(on d: String, now: UInt64) -> Ebb? {
        guard let e = ebb else { return nil }
        if e.finished(at: now) { ebb = nil; return nil }
        return e.display == d ? e : nil
    }
}

/// The title shown under the window the pointer is over: white on a dark
/// rounded plate, Exposé's own way of saying which is which. Drawn once per
/// window and title, and kept.
final class EbbLabel {
    let texture: UnsafeMutablePointer<wlr_texture>
    let width: Int32, height: Int32
    let title: String

    init?(renderer: UnsafeMutablePointer<wlr_renderer>, title: String) {
        let size = 12.0
        // Measure on a scratch surface, then draw at that size.
        guard let probe = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, 1, 1),
              let pcr = cairo_create(probe) else { return nil }
        let tw = Draw.textWidth(pcr, title, size: size, style: .bold, role: .chrome)
        cairo_destroy(pcr); cairo_surface_destroy(probe)
        let w = Int32(min(tw + 24, 480)), h: Int32 = 22
        guard let surface = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, w, h),
              let cr = cairo_create(surface) else { return nil }
        defer { cairo_destroy(cr); cairo_surface_destroy(surface) }
        let r = Double(h) / 2
        cairo_new_path(cr)
        cairo_arc(cr, r, r, r, .pi / 2, 3 * .pi / 2)
        cairo_arc(cr, Double(w) - r, r, r, 3 * .pi / 2, .pi / 2)
        cairo_close_path(cr)
        cairo_set_source_rgba(cr, 0, 0, 0, 0.7)
        cairo_fill(cr)
        Draw.textLeft(cr, title, x: 12, baselineY: 15, color: Theme.menuTextOnHighlight,
                      size: size, style: .bold, role: .chrome)
        cairo_surface_flush(surface)
        guard let data = cairo_image_surface_get_data(surface),
              let tex = wlr_texture_from_pixels(renderer, UInt32(0x34325241),
                                                UInt32(cairo_image_surface_get_stride(surface)),
                                                UInt32(w), UInt32(h), data) else { return nil }
        texture = tex; width = w; height = h; self.title = title
    }

    deinit { wlr_texture_destroy(texture) }
}

extension Compositor {
    /// Window `t`'s label, drawn when first asked and when its title changes.
    func ebbLabel(for t: Toplevel, renderer: UnsafeMutablePointer<wlr_renderer>) -> EbbLabel? {
        let title = (t.title?.isEmpty == false ? t.title : t.appID) ?? ""
        guard !title.isEmpty else { return nil }
        if let l = ebbLabels[t.id], l.title == title { return l }
        let l = EbbLabel(renderer: renderer, title: title)
        ebbLabels[t.id] = l
        return l
    }
}
