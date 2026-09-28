// DisplaysPane — System Preferences' Displays pane (PHASE14 P14.7c).
//
// Jaguar's two tabs on one page: the **arrangement** — every display as a
// rectangle, to scale, the main one wearing the menu bar, dragged to where it
// sits beside the others — and the selected display's **resolution** and
// **scale**. Every change is applied at once, as a Mac's is, through
// wlr-output-management-v1 (`DisplayConfigurator`, P14.7b): the pane asks, the
// compositor decides, and undertow's displays.ini keeps it.
//
// What it shows is read, not remembered: the displays as the compositor last
// described them, redrawn when anyone (the pane, wlr-randr, kanshi) changes
// them.

import AquaDraw
import CCairo
import Surface

public typealias DisplayHead = DisplayConfigurator.Head

// MARK: - What the page is drawn from

public struct DisplaysPaneState: Equatable, Sendable {
    public var heads: [DisplayHead] = []
    /// The display whose resolution and scale are shown.
    public var selected: String?
    /// A display being dragged: its name, and its box where the pointer has it.
    public var dragging: (name: String, x: Int32, y: Int32)?
    public var note: String = ""

    public init(heads: [DisplayHead] = [], selected: String? = nil, note: String = "") {
        self.heads = heads; self.selected = selected ?? heads.first?.name; self.note = note
    }

    public static func == (a: DisplaysPaneState, b: DisplaysPaneState) -> Bool {
        a.heads == b.heads && a.selected == b.selected && a.note == b.note
            && a.dragging?.name == b.dragging?.name && a.dragging?.x == b.dragging?.x && a.dragging?.y == b.dragging?.y
    }

    public var selectedHead: DisplayHead? { heads.first { $0.name == selected } ?? heads.first }

    /// A fixed pair of displays, for the golden picture.
    public static let sample: DisplaysPaneState = {
        let m1 = DisplayConfigurator.Mode(width: 2560, height: 1440, refreshMilliHz: 59951, preferred: true)
        let m1b = DisplayConfigurator.Mode(width: 1920, height: 1080, refreshMilliHz: 60000)
        let m2 = DisplayConfigurator.Mode(width: 1920, height: 1200, refreshMilliHz: 59950, preferred: true)
        return DisplaysPaneState(heads: [
            DisplayHead(name: "DP-1", description: "Dell U2719D", modes: [m1, m1b], current: m1, x: 0, y: 0, scale: 1.25),
            DisplayHead(name: "HDMI-A-1", description: "LG 24UD58", modes: [m2], current: m2, x: 2048, y: 0),
        ])
    }()
}

public enum DisplaysWords {
    /// The page as one line for the log a test reads, in `abyss-displays`' terms.
    public static func statusLine(_ heads: [DisplayHead]) -> String {
        heads.map { h in
            let m = h.current.map { "\($0.width)x\($0.height)" } ?? "none"
            return "\(h.name) \(m) at \(h.x),\(h.y) scale \(scaleText(h.scale))"
        }.joined(separator: "; ")
    }

    public static func scaleText(_ s: Double) -> String {
        s == s.rounded() ? "\(Int(s))" : String(s)
    }

    public static func mode(_ m: DisplayConfigurator.Mode, among all: [DisplayConfigurator.Mode]) -> String {
        let sameSize = all.filter { $0.width == m.width && $0.height == m.height }.count > 1
        let hz = Double(m.refreshMilliHz) / 1000
        return "\(m.width) × \(m.height)" + (sameSize && m.refreshMilliHz > 0 ? ", \(Int(hz.rounded())) Hz" : "")
            + (m.preferred ? " (native)" : "")
    }

    /// The scales offered: the usual ones, and the current one if it is not.
    public static func scales(current: Double) -> [Double] {
        var s: [Double] = [1, 1.25, 1.5, 2]
        if !s.contains(current) { s.append(current); s.sort() }
        return s
    }
}

// MARK: - The arrangement's arithmetic (pure)

public enum DisplaysArrange {
    /// Layout units within which a dropped display's edge lines up with its
    /// neighbour's.
    public static let alignTolerance: Int32 = 24

    /// The layout's rectangles, fitted into `area` to scale and centred; with
    /// the factor, so a drag in the pane can be turned back into layout units.
    public static func fit(_ boxes: [(name: String, x: Int32, y: Int32, w: Int32, h: Int32)],
                           in area: Rect) -> (rects: [String: Rect], factor: Double) {
        guard let first = boxes.first else { return ([:], 1) }
        var x0 = first.x, y0 = first.y, x1 = first.x + first.w, y1 = first.y + first.h
        for b in boxes { x0 = min(x0, b.x); y0 = min(y0, b.y); x1 = max(x1, b.x + b.w); y1 = max(y1, b.y + b.h) }
        let bw = Double(max(1, x1 - x0)), bh = Double(max(1, y1 - y0))
        let k = min(area.w / bw, area.h / bh) * 0.8
        let ox = area.x + (area.w - bw * k) / 2, oy = area.y + (area.h - bh * k) / 2
        var out: [String: Rect] = [:]
        for b in boxes {
            out[b.name] = Rect(ox + Double(b.x - x0) * k, oy + Double(b.y - y0) * k, Double(b.w) * k, Double(b.h) * k)
        }
        return (out, k)
    }

    /// Where a dropped display goes: **touching** another along a whole edge
    /// segment, overlapping none — a Mac will not leave a display floating
    /// apart from the rest, and neither does this. The nearest such place to
    /// where it was dropped.
    public static func snap(name: String, x: Int32, y: Int32, w: Int32, h: Int32,
                            others: [(x: Int32, y: Int32, w: Int32, h: Int32)]) -> (x: Int32, y: Int32) {
        func overlaps(_ ax: Int32, _ ay: Int32) -> Bool {
            others.contains { o in min(ax + w, o.x + o.w) > max(ax, o.x) && min(ay + h, o.y + o.h) > max(ay, o.y) }
        }
        var best: (x: Int32, y: Int32)? = nil
        var bestD = Int64.max
        for o in others {
            // Along the shared edge: keep at least one unit of it, and line the
            // edges up when they are nearly lined up — a drop a few pixels off
            // is a person who meant them flush, as a Mac assumes.
            func align(_ v: Int32, _ start: Int32, _ len: Int32, _ size: Int32) -> Int32 {
                let c = min(max(v, start - size + 1), start + len - 1)
                for edge in [start, start + len - size] where abs(c - edge) <= alignTolerance { return edge }
                return c
            }
            let cy = align(y, o.y, o.h, h)
            let cx = align(x, o.x, o.w, w)
            for c in [(o.x - w, cy), (o.x + o.w, cy), (cx, o.y - h), (cx, o.y + o.h)] where !overlaps(c.0, c.1) {
                let d = Int64(c.0 - x) * Int64(c.0 - x) + Int64(c.1 - y) * Int64(c.1 - y)
                if d < bestD { bestD = d; best = c }
            }
        }
        return best ?? (x, y)
    }
}

// MARK: - Layout (paint and hit-test read this, §2.9)

public struct DisplaysLayout: Equatable, Sendable {
    public struct Row: Equatable, Sendable {
        public let value: String
        public let hit: Rect
        public let control: Rect
    }
    public var arrangement = Rect(0, 0, 0, 0)
    public var displays: [String: Rect] = [:]
    public var factor = 1.0
    public var modes: [Row] = []
    public var scales: [Row] = []
    public var labelRight = 0.0
    public var detailBaseline = 0.0
    public var modesBaseline = 0.0
    public var scalesBaseline = 0.0
    public var noteBaseline = 0.0
}

public func displaysLayout(body: Rect, _ s: DisplaysPaneState) -> DisplaysLayout {
    var l = DisplaysLayout()
    l.labelRight = body.x + 170
    l.arrangement = Rect(body.x + 40, body.y + 20, body.w - 80, 200)
    let boxes = s.heads.map { h -> (name: String, x: Int32, y: Int32, w: Int32, h: Int32) in
        if let d = s.dragging, d.name == h.name { return (h.name, d.x, d.y, h.layoutWidth, h.layoutHeight) }
        return (h.name, h.x, h.y, h.layoutWidth, h.layoutHeight)
    }
    // Fitted to the displays as they ARE, so the pane does not rescale under
    // the pointer mid-drag; the dragged one is placed in the same frame.
    let fitted = DisplaysArrange.fit(s.heads.map { ($0.name, $0.x, $0.y, $0.layoutWidth, $0.layoutHeight) },
                                     in: Rect(l.arrangement.x + 10, l.arrangement.y + 10,
                                              l.arrangement.w - 20, l.arrangement.h - 20))
    l.factor = fitted.factor
    for b in boxes {
        guard let base = fitted.rects[b.name], let h = s.heads.first(where: { $0.name == b.name }) else { continue }
        l.displays[b.name] = Rect(base.x + Double(b.x - h.x) * l.factor, base.y + Double(b.y - h.y) * l.factor, base.w, base.h)
    }
    var y = l.arrangement.y + l.arrangement.h + 48       // below the hint under the box
    l.detailBaseline = y
    y += 26
    l.modesBaseline = y + 15
    let x = l.labelRight + 12
    if let h = s.selectedHead {
        for m in h.modes {
            l.modes.append(.init(value: "\(m.width)x\(m.height)@\(m.refreshMilliHz)", hit: Rect(x, y, 300, 22),
                                 control: Rect(x, y + 3, 16, 16)))
            y += 22
        }
        y += 14
        l.scalesBaseline = y + 15
        var sx = x
        for sc in DisplaysWords.scales(current: h.scale) {
            l.scales.append(.init(value: DisplaysWords.scaleText(sc), hit: Rect(sx, y, 70, 22), control: Rect(sx, y + 3, 16, 16)))
            sx += 74
        }
        y += 22
    }
    l.noteBaseline = y + 34
    return l
}

public enum DisplaysHit: Equatable, Sendable {
    case display(String)
    case mode(String)        // "WxH@mHz"
    case scale(String)
}

public func displaysHit(_ l: DisplaysLayout, x: Double, y: Double) -> DisplaysHit? {
    // The topmost rectangle first: the dragged one is drawn last.
    if let (name, _) = l.displays.first(where: { $0.value.contains(x, y) }) { return .display(name) }
    if let r = l.modes.first(where: { $0.hit.contains(x, y) }) { return .mode(r.value) }
    if let r = l.scales.first(where: { $0.hit.contains(x, y) }) { return .scale(r.value) }
    return nil
}

// MARK: - Paint

public func paintDisplaysPane(_ cr: OpaquePointer, _ l: DisplaysLayout, _ s: DisplaysPaneState) {
    guard !s.heads.isEmpty else {
        Draw.text(cr, s.note.isEmpty ? "No displays to arrange." : s.note,
                  centerX: l.arrangement.x + l.arrangement.w / 2, centerY: l.arrangement.y + 60,
                  color: Theme.secondaryText, size: 13)
        return
    }
    Draw.groupBox(cr, l.arrangement, title: "Arrangement")
    let main = s.heads.first?.name
    let order = s.heads.map(\.name).filter { $0 != s.dragging?.name } + [s.dragging?.name].compactMap { $0 }
    for name in order {
        guard let r = l.displays[name] else { continue }
        let chosen = name == s.selectedHead?.name
        Draw.setColor(cr, chosen ? Color(0.36, 0.56, 0.86) : Color(0.55, 0.66, 0.82))
        Draw.roundedRect(cr, r, radius: 2)
        cairo_fill(cr)
        Draw.setColor(cr, chosen ? Color(0.12, 0.30, 0.66) : Color(0.35, 0.40, 0.50))
        cairo_set_line_width(cr, chosen ? 2 : 1)
        Draw.roundedRect(cr, r, radius: 2)
        cairo_stroke(cr)
        if name == main {
            // The menu bar: this is the main display, and dragging it here is
            // how a Mac moved the menu bar too.
            Draw.setColor(cr, Color(1, 1, 1, 0.92))
            cairo_rectangle(cr, r.x + 1, r.y + 1, r.w - 2, max(3, r.h * 0.07))
            cairo_fill(cr)
        }
        Draw.text(cr, name, centerX: r.x + r.w / 2, centerY: r.y + r.h / 2, color: Color(1, 1, 1), size: 11)
    }
    guard let h = s.selectedHead else { return }
    Draw.text(cr, "Drag displays to arrange them. The white bar is the menu bar: that display is the main one.",
              centerX: l.arrangement.x + l.arrangement.w / 2, centerY: l.arrangement.y + l.arrangement.h + 12,
              color: Theme.secondaryText, size: 11)
    let title = h.description.isEmpty ? h.name : "\(h.description) (\(h.name))"
    Draw.textLeft(cr, title, x: l.arrangement.x, baselineY: l.detailBaseline, color: Theme.bodyText, size: 13, style: .bold)
    func heading(_ t: String, _ baseline: Double) {
        let w = Draw.textWidth(cr, t, size: 13)
        Draw.textLeft(cr, t, x: l.labelRight - w, baselineY: baseline, color: Theme.bodyText, size: 13)
    }
    heading("Resolution:", l.modesBaseline)
    for r in l.modes {
        guard let m = h.modes.first(where: { "\($0.width)x\($0.height)@\($0.refreshMilliHz)" == r.value }) else { continue }
        Draw.radioButton(cr, cx: r.control.x + 8, cy: r.control.y + 8, radius: 7, selected: m == h.current)
        Draw.textLeft(cr, DisplaysWords.mode(m, among: h.modes), x: r.control.x + 24, baselineY: r.control.y + 12,
                      color: Theme.bodyText, size: 13)
    }
    heading("Scale:", l.scalesBaseline)
    for r in l.scales {
        Draw.radioButton(cr, cx: r.control.x + 8, cy: r.control.y + 8, radius: 7,
                         selected: r.value == DisplaysWords.scaleText(h.scale))
        Draw.textLeft(cr, r.value + "×", x: r.control.x + 24, baselineY: r.control.y + 12, color: Theme.bodyText, size: 13)
    }
    if !s.note.isEmpty {
        Draw.textLeft(cr, s.note, x: l.arrangement.x, baselineY: l.noteBaseline, color: Theme.bodyText, size: 12)
    }
}
