// Shoals — a working set of windows, recalled together (PHASE13 P13.6,
// PRODUCT §7.3).
//
// Stage Manager done properly: **sets are explicit** (nothing joins by itself),
// **recall restores the places `WindowPlaces` remembers** and never moves or
// resizes anything else, and **a shoal lives on an island** — islands separate
// contexts, shoals recall a working set within one.
//
// Membership is by window key (app id and title, `WindowPlaces.key`), so a
// window that is closed and opened again is still a member, and the set is
// re-formed when its windows come back. Kept in `shoals.ini`.

import CWlroots
import PoolConfig

/// One shoal: a name, where it lives, and its members by window key.
public struct Shoal: Equatable, Sendable {
    public var name: String
    public var display: String
    public var island: Int
    public var members: [String]
    public init(name: String, display: String, island: Int, members: [String]) {
        self.name = name; self.display = display; self.island = island; self.members = members
    }
}

/// Every shoal, and the rules for changing them. Pure: no windows, no files.
public struct ShoalBook: Equatable, Sendable {
    public private(set) var shoals: [Shoal] = []
    /// The strip stays up (§6.7: summoned by default, pinned by choice).
    public var pinned = false
    /// The shoal "add" means: the last one made, added to or recalled.
    public private(set) var current: Int?

    public init(shoals: [Shoal] = [], pinned: Bool = false) {
        self.shoals = shoals; self.pinned = pinned
        current = shoals.isEmpty ? nil : 0
    }

    /// The shoal a window key belongs to — one at most.
    public func shoal(of key: String) -> Int? { shoals.firstIndex { $0.members.contains(key) } }

    /// Shoals living on an island, in the order they were made: what Ctrl-
    /// Shift-N numbers and what the strip shows.
    public func onIsland(_ display: String, _ island: Int) -> [Int] {
        shoals.indices.filter { shoals[$0].display == display && shoals[$0].island == island }
    }

    /// A new shoal of one window, which leaves any other it was in. Named
    /// "Shoal N", N one past the highest number in use.
    @discardableResult
    public mutating func new(with key: String, display: String, island: Int) -> Int {
        leave(key)
        let used = shoals.compactMap { s -> Int? in
            s.name.hasPrefix("Shoal ") ? Int(s.name.dropFirst(6)) : nil
        }
        shoals.append(Shoal(name: "Shoal \((used.max() ?? 0) + 1)", display: display,
                            island: island, members: [key]))
        current = shoals.count - 1
        return shoals.count - 1
    }

    /// Add a window to shoal `i` (leaving any other). False if there is none.
    @discardableResult
    public mutating func add(_ key: String, to i: Int) -> Bool {
        guard shoals.indices.contains(i) else { return false }
        if shoals[i].members.contains(key) { current = i; return true }
        // Leaving its old shoal may remove that one and move this one's index:
        // found again by name, which is unique.
        let name = shoals[i].name
        leave(key)
        guard let j = shoals.firstIndex(where: { $0.name == name }) else { return false }
        shoals[j].members.append(key)
        current = j
        return true
    }

    /// Take a window out of its shoal; a shoal left empty is gone.
    @discardableResult
    public mutating func leave(_ key: String) -> Bool {
        guard let i = shoal(of: key) else { return false }
        shoals[i].members.removeAll { $0 == key }
        if shoals[i].members.isEmpty {
            shoals.remove(at: i)
            if let c = current { current = c == i ? (shoals.isEmpty ? nil : shoals.count - 1) : (c > i ? c - 1 : c) }
        }
        return true
    }

    public mutating func recalled(_ i: Int) { if shoals.indices.contains(i) { current = i } }

    // MARK: shoals.ini

    public static func from(_ c: Config) -> ShoalBook {
        var shoals: [Shoal] = []
        for n in 1...64 {
            let s = "shoal.\(n)"
            guard let name = c.string(s, "name") else { continue }
            let members = (c.string(s, "members") ?? "").split(separator: "\t").map(String.init)
            guard !members.isEmpty else { continue }
            shoals.append(Shoal(name: name, display: c.string(s, "display") ?? "",
                                island: c.int64(s, "island").map(Int.init) ?? 1, members: members))
        }
        return ShoalBook(shoals: shoals, pinned: c.bool("strip", "pinned") ?? false)
    }

    public static func load(configDir: String?) -> ShoalBook {
        (try? Pool.load("shoals", in: configDir)).map(from) ?? ShoalBook()
    }

    public var config: Config {
        var c = Config()
        for (i, s) in shoals.enumerated() {
            let sec = "shoal.\(i + 1)"
            c = c.set(sec, "name", s.name)
            c = c.set(sec, "display", s.display)
            c = c.set(sec, "island", String(s.island))
            c = c.set(sec, "members", s.members.joined(separator: "\t"))
        }
        c = c.set("strip", "pinned", bool: pinned)
        return c
    }
}

extension Compositor {
    private func saveShoals() { try? shoalBook.config.store("shoals", in: configDir) }

    /// The focused window as a key, and the window.
    private func focusedKey() -> (Toplevel, String)? {
        guard let t = seat?.focused, let k = t.placeKey else { return nil }
        return (t, k)
    }

    /// Ctrl-Alt-N: a new shoal, of the focused window.
    public func newShoal() {
        guard let (t, k) = focusedKey() else { return }
        let i = shoalBook.new(with: k, display: t.islandDisplay, island: t.island)
        saveShoals()
        Compositor.log("shoal \(shoalBook.shoals[i].name) made of \(k) on \(t.islandDisplay) island \(t.island)")
    }

    /// Ctrl-Alt-=: the focused window joins the current shoal (or shoal `i`).
    public func addFocusedToShoal(_ i: Int? = nil) {
        guard let (_, k) = focusedKey(), let target = i ?? shoalBook.current,
              shoalBook.add(k, to: target), let j = shoalBook.shoal(of: k) else { return }
        saveShoals()
        Compositor.log("shoal \(shoalBook.shoals[j].name) + \(k) (\(shoalBook.shoals[j].members.count))")
    }

    /// Ctrl-Alt--: the focused window leaves its shoal.
    public func removeFocusedFromShoal() {
        guard let (_, k) = focusedKey(), let j = shoalBook.shoal(of: k) else { return }
        let name = shoalBook.shoals[j].name
        shoalBook.leave(k)
        saveShoals()
        Compositor.log("shoal \(name) − \(k)")
    }

    /// Ctrl-Shift-N: recall this island's Nth shoal (1-based).
    public func recallShoal(number n: Int) {
        let d = commandDisplay()
        let list = shoalBook.onIsland(d, activeIsland(on: d))
        guard n >= 1, n <= list.count else { return }
        recallShoal(list[n - 1])
    }

    /// Bring a shoal back: its island, then every member that is open — back
    /// on that island, out of the Dock, at the place it was last left — raised
    /// together in the shoal's order, the last focused. **Nothing else moves.**
    public func recallShoal(_ i: Int) {
        guard shoalBook.shoals.indices.contains(i) else { return }
        let s = shoalBook.shoals[i]
        if activeIsland(on: s.display) != s.island { switchIsland(s.island, on: s.display) }
        var raised: [Toplevel] = []
        for key in s.members {
            guard let t = toplevels.first(where: { $0.mapped && $0.placeKey == key }) else { continue }
            if t.islandDisplay == s.display, t.island != s.island { t.island = s.island; refreshSuspended(t) }
            setMinimized(t, false)
            if let p = places.place(forKey: key), (p.x, p.y) != (t.x, t.y) { t.x = p.x; t.y = p.y }
            raise(t)
            raised.append(t)
        }
        if let last = raised.last { seat?.focus(last) }
        shoalBook.recalled(i)
        recalls &+= 1
        Compositor.log("shoal \(s.name) recalled: \(raised.compactMap(\.placeKey).joined(separator: " "))")
    }

    /// A window mapped: if it is a member, its shoal has it back.
    func shoalRejoined(_ t: Toplevel) {
        guard let k = t.placeKey, let j = shoalBook.shoal(of: k) else { return }
        Compositor.log("shoal \(shoalBook.shoals[j].name) has \(k) again")
    }

    // MARK: the strip

    /// A shoal's name plate, drawn once per name.
    func stripLabel(_ name: String, renderer: UnsafeMutablePointer<wlr_renderer>) -> EbbLabel? {
        if let l = stripLabels[name] { return l }
        let l = EbbLabel(renderer: renderer, title: name)
        stripLabels[name] = l
        return l
    }

    /// Ctrl-F3: show or hide the strip. Pinned (`shoals.ini [strip] pinned`)
    /// it stays; otherwise it goes when a shoal is recalled from it.
    public func toggleShoalStrip() {
        stripShown.toggle()
        Compositor.log("shoal strip \(stripShown ? "on" : "off")")
        if stripShown {
            for tile in stripTiles(on: commandDisplay()) {
                let r = tile.rect
                Compositor.log("shoal-tile \(String(shoalBook.shoals[tile.index].name.map { $0 == " " ? "_" : $0 })) \(r.x),\(r.y) \(r.width)x\(r.height)")
            }
        }
    }

    /// The strip's tiles on display `d`: one per shoal of its island, top to
    /// bottom along the left edge.
    func stripTiles(on d: String) -> [(index: Int, rect: Rect)] {
        guard stripShown || shoalBook.pinned, let box = layout.displays.first(where: { $0.name == d }) else { return [] }
        let area = usable[d] ?? box.rect
        let w = Compositor.stripTileWidth, h = Compositor.stripTileHeight
        return shoalBook.onIsland(d, activeIsland(on: d)).enumerated().map { (n, i) in
            (i, Rect(x: area.x + 12, y: area.y + 12 + Int32(n) * (h + 16), width: w, height: h))
        }
    }
    static let stripTileWidth: Int32 = 160, stripTileHeight: Int32 = 110

    /// A click: on a tile, recall that shoal (and the strip goes, unless
    /// pinned). True if the strip took the click.
    func stripClick(_ x: Double, _ y: Double) -> Bool {
        guard stripShown || shoalBook.pinned else { return false }
        let d = layout.display(at: x, y)?.name ?? ""
        for tile in stripTiles(on: d) where x >= Double(tile.rect.x) && x < Double(tile.rect.x + tile.rect.width)
            && y >= Double(tile.rect.y) && y < Double(tile.rect.y + tile.rect.height) {
            if !shoalBook.pinned { stripShown = false }
            recallShoal(tile.index)
            return true
        }
        return false
    }
}
