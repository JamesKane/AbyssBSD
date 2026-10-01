// Islands — named workspaces, per display (PHASE13 P13.1, PRODUCT §7.3).
//
// **An island is a number on a window and a predicate in the latch**, which
// is the whole data structure (PRODUCT §7.4). Each display shows one island at
// a time; a window belongs to an island of the display it lives on; and a
// window on an island nobody is looking at is treated exactly as a minimised
// one is: not drawn, not hit, and kept alive on the 1 Hz clock with xdg-shell's
// `suspended` (U.2, T.3). Everything that asks "what is showing" asks through
// `mappedToplevels`, so the predicate is in one place.
//
// **A switch is a commit, not an animation** (C6): the active island, the
// focused window and the keyboard all change here, before the next latch.
// Anything that moves on screen afterwards is P13.3's decoration.

import CWlroots
import PoolConfig

/// `islands.ini`: how many islands each display has, and what they are called.
/// §6.1: a fixed count, so Ctrl-3 always means the same place.
public struct IslandsConfig: Equatable, Sendable {
    public static let defaultCount = 4
    public static let maxCount = 9          // one per digit key

    public var count: Int
    /// Index 0 is island 1. A missing name is the number.
    public var names: [String]
    /// The slide (P13.3, §6.5): on by default, 150 ms, skippable. Decoration
    /// only — the switch is committed before the first frame of it (C6).
    public var animate: Bool
    /// Its length. PRODUCT §7.2 budgets ~150 ms; up to 2 s is allowed so a
    /// test (or a person who wants to watch) can slow it down.
    public var slideMs: Int

    public init(count: Int = IslandsConfig.defaultCount, names: [String] = [],
                animate: Bool = true, slideMs: Int = 150) {
        self.count = min(max(count, 1), IslandsConfig.maxCount)
        self.names = names
        self.animate = animate
        self.slideMs = min(max(slideMs, 0), 2000)
    }

    public func name(_ n: Int) -> String {
        n >= 1 && n <= names.count && !names[n - 1].isEmpty ? names[n - 1] : "\(n)"
    }

    public static func from(_ c: Config) -> IslandsConfig {
        let count = c.int64("islands", "count").map(Int.init) ?? defaultCount
        var names: [String] = []
        for n in 1...maxCount { names.append(c.string("islands", "name.\(n)") ?? "") }
        while let last = names.last, last.isEmpty { names.removeLast() }
        return IslandsConfig(count: count, names: names,
                             animate: c.bool("islands", "animate") ?? true,
                             slideMs: c.int64("islands", "slide_ms").map(Int.init) ?? 150)
    }

    public static func load(configDir: String?) -> IslandsConfig {
        (try? Pool.load("islands", in: configDir)).map(from) ?? IslandsConfig()
    }

    /// The island one step from `n`, wrapping — Ctrl-→ from the last is the first.
    public func step(_ n: Int, by d: Int) -> Int {
        ((n - 1 + d) % count + count) % count + 1
    }
}

/// A slide in progress on one display: the view moving from where it was
/// (an island position, fractional mid-slide) to the island now shown.
struct IslandSlide {
    var from: Double
    var to: Int
    var start: UInt64
    var durationNs: UInt64

    /// Ease-out cubic: fast away, settling in — the motion reads as arriving.
    static func ease(_ t: Double) -> Double { let u = 1 - t; return 1 - u * u * u }

    /// Where the view is at `now`, or nil once it has arrived.
    func view(at now: UInt64) -> Double? {
        guard now > start else { return from }
        let t = Double(now - start) / Double(durationNs)
        guard t < 1 else { return nil }
        return from + (Double(to) - from) * IslandSlide.ease(t)
    }
}

extension Compositor {
    /// Where display `d`'s view is mid-slide (an island position, fractional),
    /// or nil when it is still. **Free when nobody is switching**: one
    /// emptiness test, called once per display per frame by its scene.
    func islandView(on d: String, now: UInt64) -> Double? {
        guard !islandSlides.isEmpty, let s = islandSlides[d] else { return nil }
        if let v = s.view(at: now) { return v }
        islandSlides[d] = nil
        return nil
    }

    /// The island display `d` is showing (1 until somebody switches).
    public func activeIsland(on d: String) -> Int { activeIslands[d] ?? 1 }

    /// Whether `t` is on the island its display is showing.
    @inline(__always)
    func isOnActiveIsland(_ t: Toplevel) -> Bool { (activeIslands[t.islandDisplay] ?? 1) == t.island }

    /// Say so to the client: hidden (minimised, or on an island nobody is
    /// looking at) is xdg-shell v6's `suspended`, and the hidden clock starts
    /// at once rather than a second late.
    func refreshSuspended(_ t: Toplevel) {
        let hidden = t.minimized || !isOnActiveIsland(t)
        guard hidden != t.suspendedSaid else { return }
        t.suspendedSaid = hidden
        _ = wlr_xdg_toplevel_set_suspended(t.xdgToplevel, hidden)
        t.hiddenFrameAt = 0
    }

    /// Which display a window lives on, and so which island it can be on.
    ///
    /// Settled when it maps (`fresh`: the display's active island) and when a
    /// drag ends: a window dragged to another display joins the island that
    /// display is showing. Not during the drag — the window you are carrying
    /// must not vanish because its middle crossed a border.
    func settleIsland(_ t: Toplevel, fresh: Bool = false) {
        let d = layout.display(for: Rect(x: t.x, y: t.y, width: t.width, height: t.height))?.name
            ?? layout.main?.name ?? ""
        guard fresh || d != t.islandDisplay else { return }
        t.islandDisplay = d
        t.island = activeIsland(on: d)
        refreshSuspended(t)
    }

    /// The display a keystroke means: the focused window's, else the one under
    /// the pointer, else the main one.
    func commandDisplay() -> String {
        if let f = seat?.focused, f.mapped { return f.islandDisplay }
        if let s = seat, let d = layout.display(at: s.cursorX, s.cursorY) { return d.name }
        return layout.main?.name ?? ""
    }

    /// The topmost window showing on display `d`.
    func topmostShowing(on d: String) -> Toplevel? {
        mappedToplevels.last { $0.islandDisplay == d }
    }

    /// Show island `n` on display `d` (the command display if nil). **The
    /// commit**: what is drawn, what is under the pointer, and who has the
    /// keyboard all change now, before the next frame is latched.
    public func switchIsland(_ n: Int, on display: String? = nil) {
        let d = display ?? commandDisplay()
        guard n >= 1, n <= islands.count, activeIsland(on: d) != n else { return }
        // The slide starts from wherever the view is — mid-slide, that is
        // between two islands — so asking again re-targets; it never queues
        // (PRODUCT §7.2 rule 2). Off, or zero-length: the view just is there.
        if islands.animate, islands.slideMs > 0 {
            let now = Mono.now()
            let from = islandView(on: d, now: now) ?? Double(activeIsland(on: d))
            islandSlides[d] = IslandSlide(from: from, to: n, start: now,
                                          durationNs: UInt64(islands.slideMs) * 1_000_000)
        }
        activeIslands[d] = n
        islandSwitches &+= 1
        // Stamped for C6: the earliest unshown request is what a person is
        // waiting on.
        if islandInputs[d] == nil { islandInputs[d] = Mono.now() }
        // A window being dragged goes with you (Spaces does the same): it is
        // in your hand, not on the island you are leaving.
        if let carried = moving, carried.islandDisplay == d { carried.island = n }
        for t in toplevels where t.mapped && t.islandDisplay == d { refreshSuspended(t) }
        if let w = topmostShowing(on: d) {
            seat?.focus(w)
        } else if let f = seat?.focused, !isOnActiveIsland(f) {
            seat?.focusTopmost()
        }
        menus?.sendIsland(of: d)
        Compositor.log("island \(d) \(n) (\(islands.name(n)))")
    }

    /// The stamp of a switch on `d` not yet drawn, taken by the scene that
    /// draws it — 0 if none. Free when nobody is switching: one emptiness test.
    @inline(__always)
    func takeIslandInput(_ d: String) -> UInt64 {
        guard !islandInputs.isEmpty, let t = islandInputs.removeValue(forKey: d) else { return 0 }
        return t
    }

    /// Ctrl-← / Ctrl-→: the next island on the command display, wrapping.
    public func stepIsland(_ by: Int) {
        let d = commandDisplay()
        switchIsland(islands.step(activeIsland(on: d), by: by), on: d)
    }

    /// The focused window to island `n` (§6.2): it goes and you stay, unless
    /// `follow`, in which case you go with it.
    public func moveFocusedWindow(toIsland n: Int, follow: Bool) {
        guard let t = seat?.focused, n >= 1, n <= islands.count, t.island != n else { return }
        t.island = n
        refreshSuspended(t)
        Compositor.log("window \(t.placeKey ?? "?") to island \(n)\(follow ? ", followed" : "")")
        if follow {
            switchIsland(n, on: t.islandDisplay)
            seat?.focus(t)
        } else if let w = topmostShowing(on: t.islandDisplay) {
            seat?.focus(w)
        } else {
            seat?.focusTopmost()
        }
    }

    /// Bring `t` to the front wherever it is (§6.3, and the Dock's rule): its
    /// island first, then out of the Dock, then raised and focused. **A window is
    /// never lost**, because asking for it always goes to it.
    func bringToFront(_ t: Toplevel) {
        if !isOnActiveIsland(t) { switchIsland(t.island, on: t.islandDisplay) }
        setMinimized(t, false)
        raise(t)
        seat?.focus(t)
    }
}
