// Displays — where each output sits in the desktop, as a pure value
// (PHASE14 P14.7a).
//
// Until P14.7 undertow drove one output, and "output coordinates" and "desktop
// coordinates" were the same thing. With several they are not: the desktop is
// one coordinate space — the **layout** — and each output shows a rectangle of
// it. Windows, layer surfaces, popups and the pointer all live in layout
// coordinates; only the scene that draws an output, and the cursor it draws,
// subtract that output's origin.
//
// The first display is the **main display**, as a Mac has one: the menu bar and
// the Dock go there, new windows open there, and it sits at the origin, so a
// desktop of one output is exactly what it was before.
//
// Everything here is arithmetic on rectangles, tested without a compositor —
// the same discipline as `LayerArrange` and `PointerRouting`.

public struct DisplayBox: Equatable, Sendable {
    /// The output's name — `HEADLESS-1`, `DP-2` — the key everything else uses.
    public var name: String
    /// Where it sits in the layout, and its size in layout units (its mode
    /// divided by its scale).
    public var x, y, width, height: Int32
    /// Buffer pixels per layout unit.
    public var scale: Double

    public init(name: String, x: Int32, y: Int32, width: Int32, height: Int32, scale: Double = 1) {
        self.name = name; self.x = x; self.y = y; self.width = width; self.height = height; self.scale = scale
    }

    public var rect: Rect { Rect(x: x, y: y, width: width, height: height) }

    public func contains(_ px: Double, _ py: Double) -> Bool {
        px >= Double(x) && py >= Double(y) && px < Double(x + width) && py < Double(y + height)
    }
}

public struct DisplayLayout: Equatable, Sendable {
    /// In order; the first is the main display.
    public private(set) var displays: [DisplayBox]

    public init(_ displays: [DisplayBox]) { self.displays = displays }

    /// Outputs side by side, left to right, tops aligned — where a newly found
    /// output goes when nothing has said otherwise.
    public static func row(_ sizes: [(name: String, width: Int32, height: Int32)]) -> DisplayLayout {
        var x: Int32 = 0
        return DisplayLayout(sizes.map { s in
            defer { x += s.width }
            return DisplayBox(name: s.name, x: x, y: 0, width: s.width, height: s.height)
        })
    }

    public var main: DisplayBox? { displays.first }
    public var isEmpty: Bool { displays.isEmpty }

    public func named(_ name: String) -> DisplayBox? { displays.first { $0.name == name } }

    /// The smallest rectangle holding every display.
    public var bounds: Rect {
        guard let f = displays.first else { return Rect(x: 0, y: 0, width: 0, height: 0) }
        var x0 = f.x, y0 = f.y, x1 = f.x + f.width, y1 = f.y + f.height
        for d in displays.dropFirst() {
            x0 = min(x0, d.x); y0 = min(y0, d.y)
            x1 = max(x1, d.x + d.width); y1 = max(y1, d.y + d.height)
        }
        return Rect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    /// The display a point is on, if any — there may be gaps between them.
    public func display(at px: Double, _ py: Double) -> DisplayBox? {
        displays.first { $0.contains(px, py) }
    }

    /// The display a rectangle is mostly on: the one holding its centre, else
    /// the one it overlaps most, else the main display.
    public func display(for r: Rect) -> DisplayBox? {
        let cx = Double(r.x) + Double(r.width) / 2, cy = Double(r.y) + Double(r.height) / 2
        if let d = display(at: cx, cy) { return d }
        func overlap(_ d: DisplayBox) -> Int64 {
            let w = min(r.x + r.width, d.x + d.width) - max(r.x, d.x)
            let h = min(r.y + r.height, d.y + d.height) - max(r.y, d.y)
            return w > 0 && h > 0 ? Int64(w) * Int64(h) : 0
        }
        if let best = displays.max(by: { overlap($0) < overlap($1) }), overlap(best) > 0 { return best }
        return main
    }

    /// Keep a point on some display: a cursor in the gap between two screens,
    /// or past the edge of the last, addresses nothing anyone can see. The
    /// nearest point of the nearest display.
    public func clamp(_ px: Double, _ py: Double) -> (Double, Double) {
        if display(at: px, py) != nil { return (px, py) }
        var best = (px, py), bestD = Double.infinity
        for d in displays {
            let cx = min(max(px, Double(d.x)), Double(d.x + d.width) - 1)
            let cy = min(max(py, Double(d.y)), Double(d.y + d.height) - 1)
            let dist = (cx - px) * (cx - px) + (cy - py) * (cy - py)
            if dist < bestD { bestD = dist; best = (cx, cy) }
        }
        return best
    }

    /// Replace one display's box (a mode, a move, a scale), keeping the order.
    public mutating func update(_ box: DisplayBox) {
        if let i = displays.firstIndex(where: { $0.name == box.name }) { displays[i] = box }
    }

    public mutating func remove(_ name: String) { displays.removeAll { $0.name == name } }

    /// The layout as one line for the log — `HEADLESS-1 1024x768@0,0 main;
    /// HEADLESS-2 800x600@1024,0` — which is how a test reads it back.
    public var summary: String {
        displays.enumerated().map { i, d in
            "\(d.name) \(d.width)x\(d.height)@\(d.x),\(d.y)" + (d.scale != 1 ? " scale \(d.scale)" : "")
                + (i == 0 ? " main" : "")
        }.joined(separator: "; ")
    }
}

// MARK: - A configuration: what a client asks for, and what is kept (P14.7b)

/// One output as a configuration names it: its mode in buffer pixels, where
/// it sits, and its scale. The layout box follows from these: mode ÷ scale.
public struct DisplaySetting: Equatable, Sendable {
    public var name: String
    public var enabled: Bool = true
    public var modeWidth: Int32, modeHeight: Int32
    /// mHz; 0 for "whatever the output has".
    public var refreshMilliHz: Int32 = 0
    public var x: Int32, y: Int32
    public var scale: Double = 1

    public init(name: String, enabled: Bool = true, modeWidth: Int32, modeHeight: Int32,
                refreshMilliHz: Int32 = 0, x: Int32, y: Int32, scale: Double = 1) {
        self.name = name; self.enabled = enabled; self.modeWidth = modeWidth; self.modeHeight = modeHeight
        self.refreshMilliHz = refreshMilliHz; self.x = x; self.y = y; self.scale = scale
    }

    /// Where it sits in the layout: its mode in layout units.
    public var box: DisplayBox {
        DisplayBox(name: name, x: x, y: y,
                   width: Int32((Double(modeWidth) / scale).rounded()),
                   height: Int32((Double(modeHeight) / scale).rounded()), scale: scale)
    }
}

public enum DisplaysConfig {
    /// Why a requested arrangement is refused, in words; empty when it may be
    /// applied. Checked before anything is committed: a configuration is
    /// applied whole or not at all, as the protocol says.
    public static func problems(_ settings: [DisplaySetting]) -> [String] {
        var out: [String] = []
        if settings.isEmpty { return ["a configuration must name at least one display"] }
        for s in settings where !s.enabled {
            // Turning a display off means taking it out of the run loop and
            // moving everything on it; not yet.
            out.append("\(s.name): turning a display off is not supported yet")
        }
        for s in settings {
            if !(0.5...4).contains(s.scale) { out.append("\(s.name): a scale of \(s.scale) is outside 0.5 to 4") }
            if s.modeWidth <= 0 || s.modeHeight <= 0 { out.append("\(s.name): \(s.modeWidth)x\(s.modeHeight) is not a mode") }
        }
        let boxes = settings.filter(\.enabled).map(\.box)
        for (i, a) in boxes.enumerated() {
            for b in boxes[(i + 1)...] {
                let w = min(a.x + a.width, b.x + b.width) - max(a.x, b.x)
                let h = min(a.y + a.height, b.y + b.height) - max(a.y, b.y)
                if w > 0 && h > 0 { out.append("\(a.name) and \(b.name) overlap") }
            }
        }
        return out
    }

    /// `x,y WxH@mHz scale` — one line per display in displays.ini.
    public static func format(_ s: DisplaySetting) -> String {
        "\(s.x),\(s.y) \(s.modeWidth)x\(s.modeHeight)@\(s.refreshMilliHz) \(s.scale == s.scale.rounded() ? String(Int(s.scale)) : String(s.scale))"
    }

    public static func parse(name: String, _ value: String) -> DisplaySetting? {
        let f = value.split(separator: " ")
        guard f.count == 3 else { return nil }
        let xy = f[0].split(separator: ","), mr = f[1].split(separator: "@"), wh = mr.first?.split(separator: "x") ?? []
        guard xy.count == 2, let x = Int32(xy[0]), let y = Int32(xy[1]),
              mr.count == 2, wh.count == 2, let w = Int32(wh[0]), let h = Int32(wh[1]), let r = Int32(mr[1]),
              let scale = Double(f[2]) else { return nil }
        return DisplaySetting(name: name, modeWidth: w, modeHeight: h, refreshMilliHz: r, x: x, y: y, scale: scale)
    }
}

