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
import AppBundles
import CCairo

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

private let kBtnLeft: UInt32 = 0x110
private let kBtnRight: UInt32 = 0x111

public enum DockIcon: Sendable {
    case finder, browser, mail, music, prefs, genericApp, trash, trashFull, terminal, agent
    case textedit, grab, activity, diskutility, systemprofiler
    /// An installed application's own icon: its bundle's PNG (P15.2).
    case bundle(String)
}

public struct DockItem: Sendable {
    public let icon: DockIcon
    public let label: String
    public let appID: String?   // matches a running toplevel's app_id; nil for Trash
    /// Every app_id this tile's windows may carry (P15.2): a bundle's
    /// `Contents/app-id`, or just `appID`. `owns` is the one test.
    public let appIDs: [String]
    /// The `dock.ini` entry that pinned this tile (`finder`, `Galculator`, a path);
    /// nil for a tile that is only there because its application is running.
    public let pinToken: String?
    /// The bundle an installed application's tile opens, for Recent Items.
    public let bundle: String?
    public let isTrash: Bool
    /// What to run when the tile isn't already running. argv, plus environment
    /// to add — nil for a tile we can't launch (yet).
    public let command: [String]?
    public let environment: [String: String]

    public init(icon: DockIcon, label: String, appID: String?, isTrash: Bool = false,
                command: [String]? = nil, environment: [String: String] = [:], appIDs: [String] = [],
                pinToken: String? = nil, bundle: String? = nil) {
        self.icon = icon; self.label = label; self.appID = appID; self.isTrash = isTrash
        self.command = command; self.environment = environment; self.pinToken = pinToken
        self.bundle = bundle
        self.appIDs = appIDs.isEmpty ? (appID.map { [$0] } ?? []) : appIDs
    }

    /// An installed application's tile.
    public init(app: InstalledApp, pinToken: String? = nil) {
        self.init(icon: .bundle(app.icon ?? ""), label: app.name,
                  appID: app.appIDs.first ?? app.name, command: app.executable.map { [$0] },
                  appIDs: app.appIDs.isEmpty ? [app.name] : app.appIDs, pinToken: pinToken,
                  bundle: app.bundle)
    }

    /// An installed application's own tile — not the desktop's Finder or System
    /// Preferences, which are this binary in another scene.
    public var isBundle: Bool { if case .bundle = icon { return true } else { return false } }

    /// Whether a running window is this tile's.
    public func owns(_ runningAppID: String) -> Bool {
        !isTrash && AppBundle.matches(appID: runningAppID, candidates: appIDs)
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
                      tileSize S: Double, magnify: Bool,
                      agentBadge: AgentBadge = .none) -> [DockTileFrame] {
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
        if item.appID == "org.abyssbsd.agent" { paintAgentBadge(cr, agentBadge, tile: rect) }
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

/// The Agent tile's badge (PHASE18 P18.13b), Mail's: at the tile's top
/// right, a count of sessions waiting for the person, or "…" while one works.
func paintAgentBadge(_ cr: OpaquePointer, _ badge: AgentBadge, tile: Rect) {
    let text: String, color: Color
    switch badge {
    case .none: return
    case .working: text = "…"; color = Theme.current.dockBadgeWorking
    case .waiting(let n): text = n > 99 ? "99+" : String(n); color = Theme.current.dockBadgeWaiting
    }
    let d = max(18, tile.w * 0.38)
    let w = max(d, Draw.textWidth(cr, text, size: d * 0.62, style: .bold) + d * 0.5)
    let r = Rect(tile.x + tile.w - w + d * 0.15, tile.y - d * 0.15, w, d)
    Draw.paint("dock.badge", cr, r, colors: ["c": color])
    Draw.text(cr, text, centerX: r.x + r.w / 2, centerY: r.y + r.h / 2, color: Theme.dockBadgeText,
              size: d * 0.62, style: .bold)
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
    // The theme's icon set (themes/aqua/icons/dock.dl, P11.8).
    let name: String
    switch kind {
    case .finder: name = "finder"
    case .browser: name = "browser"
    case .mail: name = "mail"
    case .music: name = "music"
    case .prefs: name = "prefs"
    case .genericApp: name = "genericApp"
    case .trash: name = "trash"
    case .trashFull: name = "trashFull"
    case .terminal: name = "terminal"
    // A theme without an Agent icon of its own draws the compiled Aqua one
    // (JaguarLists, as for any list a theme lacks); the generic one only if
    // even that is gone. A tile never goes blank.
    case .agent: name = Theme.lists["dock.icon.agent"] != nil ? "agent" : "genericApp"
    case .textedit: name = "textedit"
    case .grab: name = "grab"
    case .activity: name = "activity"
    case .diskutility: name = "diskutility"
    case .systemprofiler: name = "systemprofiler"
    case .bundle(let path):
        // The application's own icon; the generic one if it has none or it
        // cannot be read — a tile never goes blank.
        if !path.isEmpty, AppIcon.draw(cr, path: path, r) { return }
        name = "genericApp"
    }
    Draw.icon("dock.icon." + name, cr, r)
}

public final class Dock: LayerSurfaceDelegate, ForeignToplevelsDelegate {
    private var layer: LayerSurface?
    private var toplevels: ForeignToplevels?
    private var pinned: [DockItem]
    /// `dock.ini`'s `apps`, parsed; what an edit changes and saves (P15.2b).
    private var pinTokens: [String]
    /// The installed bundles, reread when windows come and go — at first login
    /// `abyss-appgen` may still be writing them (P15.1).
    private var library: [InstalledApp] = []
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
    private var presenceWatcher: Pool.Watcher?
    private var agentBadge = AgentBadge.none
    private var trashWatcher: Pool.Watcher?
    private var menu: AquaMenu?
    private var popup: Popup?

    /// The tiles `dock.ini`'s `apps` names, in order (P15.2): a token in
    /// `builtins` (`finder`, `terminal`, `sysprefs`, `agent`, `textedit`,
    /// `grab`, `activity`, `diskutility`, `systemprofiler`) is the desktop's
    /// own; anything else is an
    /// installed bundle, by name (`Galculator`) or path. Without the key: the
    /// Finder, the browser if one is installed, Terminal (P15.4) and System
    /// Preferences — no placeholder tile that launches nothing (the Browser,
    /// Mail and Music tiles until P15.2).
    public static func pinned(setting: String?, library: [InstalledApp]) -> [DockItem] {
        items(tokens: pinTokens(setting: setting, library: library), library: library)
    }

    /// The desktop's own applications: each is this binary in a scene. The
    /// token pins it in dock.ini; the app ID is the one its window gives the
    /// compositor (System Preferences' is `org.abyssbsd.preferences`: the tile
    /// once said `.prefs`, so a running Preferences never lit its own tile).
    public static let builtins: [(token: String, label: String, appID: String, scene: String, icon: DockIcon)] = [
        ("finder", "Finder", "org.abyssbsd.finder", "finder", .finder),
        ("terminal", "Terminal", "org.abyssbsd.terminal", "terminal", .terminal),
        ("sysprefs", "System Preferences", "org.abyssbsd.preferences", "sysprefs", .prefs),
        ("agent", "Agent", "org.abyssbsd.agent", "agent", .agent),
        ("textedit", "TextEdit", "org.abyssbsd.textedit", "textedit", .textedit),
        ("grab", "Grab", "org.abyssbsd.grab", "grab", .grab),
        ("activity", "Activity Monitor", "org.abyssbsd.activitymonitor", "activity", .activity),
        ("diskutility", "Disk Utility", "org.abyssbsd.diskutility", "diskutility", .diskutility),
        ("systemprofiler", "System Profiler", "org.abyssbsd.systemprofiler", "systemprofiler", .systemprofiler),
    ]

    /// The built-in tile a running window of the desktop's own wears when it
    /// is not pinned (its icon, its name, how to start another), by app ID.
    public static func builtin(appID: String) -> DockItem? {
        guard let token = builtins.first(where: { $0.appID == appID })?.token,
              let i = items(tokens: [token], library: []).first else { return nil }
        // Running, not pinned: no pin token, so it leaves the Dock when it quits.
        return DockItem(icon: i.icon, label: i.label, appID: i.appID, command: i.command, environment: i.environment)
    }

    /// `dock.ini`'s entries, or the default ones.
    public static func pinTokens(setting: String?, library: [InstalledApp]) -> [String] {
        guard let setting else {
            var out = ["finder"]
            if let browser = library.first(where: { $0.matches(appID: "firefox") || $0.name.hasPrefix("Firefox") }) {
                out.append(browser.name)
            }
            out.append("terminal")
            out.append("sysprefs")
            return out
        }
        return setting.split(separator: ";").map { $0.trimmingWhitespaceForDock() }.filter { !$0.isEmpty }
    }

    /// The tiles for those entries. One naming a bundle that is not installed
    /// has no tile — but stays in the list, so an application reinstalled comes
    /// back where it was, and editing the Dock does not forget it.
    public static func items(tokens: [String], library: [InstalledApp]) -> [DockItem] {
        let selfExe = Launcher.selfExecutable()
        return tokens.compactMap { t -> DockItem? in
            // No Agent tile while agents are off (P18.13): the token stays in
            // dock.ini, so turning them on again brings it back where it was.
            if t == "agent", !Agents.on() { return nil }
            if let b = builtins.first(where: { $0.token == t }) {
                return DockItem(icon: b.icon, label: b.label, appID: b.appID,
                                command: selfExe.map { [$0] }, environment: ["AQUA_SCENE": b.scene],
                                pinToken: t)
            }
            switch t {
            default:
                guard let app = AppLibrary.find(t, in: library) else {
                    Dock.log("dock.ini names \(t), which is not installed")
                    return nil
                }
                return DockItem(app: app, pinToken: t)
            }
        }
    }

    /// The entry that pins a bundle: its name when that finds it again (so a
    /// bundle regenerated or moved between the two Applications folders stays
    /// pinned), else its path.
    public static func pinToken(forBundle path: String, library: [InstalledApp]) -> String {
        let base = String(path.split(separator: "/").last ?? Substring(path))
        let name = base.hasSuffix(".app") ? String(base.dropLast(4)) : base
        return AppLibrary.find(name, in: library)?.bundle == path ? name : path
    }

    /// `tokens` with `token` placed before `before` (at the end if nil or not
    /// there), moved rather than doubled if it is already pinned.
    public static func pinning(_ token: String, before: String?, in tokens: [String]) -> [String] {
        var out = tokens.filter { $0 != token }
        let at = before.flatMap { b in out.firstIndex(of: b) } ?? out.count
        out.insert(token, at: at)
        return out
    }

    /// For the golden scene and anything else that wants the stock Dock.
    public static func defaultPinned() -> [DockItem] { pinned(setting: nil, library: []) }

    public init?(display: Display) {
        let config = (try? Pool.load("dock")) ?? Config()
        tileSize = Double(config.uint64("dock", "tile_size") ?? 48)
        magnify = config.bool("dock", "magnify") ?? true
        library = AppLibrary.all()
        pinTokens = Dock.pinTokens(setting: config.string("dock", "apps"), library: library)
        pinned = Dock.items(tokens: pinTokens, library: library)
        Dock.log("pinned " + pinned.map(\.label).joined(separator: ", "))

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

        // Agent presence (PHASE18 P18.13b): the Agent windows say their
        // sessions' states as files; the Agent tile badges them.
        if let dir = AgentPresenceIO.dir(), let w = try? Pool.Watcher(in: dir) {
            presenceWatcher = w
            display.addFileDescriptor(w.fileDescriptor) { [weak self] in self?.presenceChanged() }
        }
        presenceChanged()

        acceptDrops(display)
    }

    /// Re-read the agents' presence; redraw if the badge moved. Off, no badge
    /// (P18.13a): the tile itself is gone.
    private func presenceChanged() {
        _ = presenceWatcher?.drain()
        let badge = Agents.on() ? AgentBadge(AgentPresenceIO.read()) : .none
        guard badge != agentBadge else { return }
        agentBadge = badge
        Dock.log("agent badge: \(badge)")
        layer?.setNeedsDisplay()
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
        // A window gone may be an Agent window killed outright, whose
        // presence file nothing else would clear (P18.13b).
        presenceChanged()
        // Bundles written since the last look (a login's appgen, a new port).
        let now = AppLibrary.all()
        if now != library {
            library = now
            pinned = Dock.items(tokens: pinTokens, library: library)
            Dock.log("pinned " + pinned.map(\.label).joined(separator: ", "))
        }
        var seen = Set<String>()
        extras = tops.filter { t in
            !pinned.contains { $0.owns(t.appID) } && seen.insert(t.appID).inserted
        }
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
            let hit = self.tile(at: x, y)
            // An application dropped anywhere on the Dock but the Trash is
            // pinned there, before the tile it landed on (P15.2b).
            if path.hasSuffix(".app"), finderIsDirectory(path),
               hit.map({ !self.displayItems[$0.0].isTrash }) ?? true {
                self.pin(path, before: hit.flatMap { self.displayItems[$0.0].pinToken })
                return
            }
            guard let (i, _) = hit else {
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
        if item.isBundle, let command = item.command {
            // The bundle's launcher passes its arguments on as the files to
            // open (P15.1's `"$@"`).
            if Launcher.launchDetached(command + [path], extraEnv: item.environment) {
                if let b = item.bundle { RecentItems.record(b) }
                Dock.log("opened \(path) with \(item.label)")
            } else {
                Dock.log("failed to open \(path) with \(item.label)")
            }
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

    // MARK: - Editing (P15.2b)

    private func pin(_ bundle: String, before: String?) {
        let token = Dock.pinToken(forBundle: bundle, library: library)
        if AppLibrary.find(token, in: library) == nil { library = AppLibrary.all() }
        guard AppLibrary.find(token, in: library) != nil else {
            Dock.log("\(bundle) is not an application")
            return
        }
        pinTokens = Dock.pinning(token, before: before, in: pinTokens)
        Dock.log("kept \(token) in the Dock")
        pinsChanged()
    }

    private func unpin(_ item: DockItem) {
        guard let token = item.pinToken else { return }
        pinTokens.removeAll { $0 == token }
        Dock.log("removed \(item.label) from the Dock")
        pinsChanged()
    }

    /// Show the new tiles and write them to `dock.ini`, keeping its other keys.
    private func pinsChanged() {
        pinned = Dock.items(tokens: pinTokens, library: library)
        var config = (try? Pool.load("dock")) ?? Config()
        _ = config.set("dock", "apps", pinTokens.joined(separator: "; "))
        do {
            try config.store("dock")
            Dock.log("saved apps = \(pinTokens.joined(separator: "; "))")
        } catch {
            Dock.log("could not save dock.ini: \(error)")
        }
        toplevelsChanged(toplevels?.current ?? [])
    }

    private func rebuild() {
        let current = toplevels?.current ?? []
        var items = pinned
        var flags = pinned.map { item in current.contains { item.owns($0.appID) } }
        for t in extras {
            // A running application that is not pinned wears its bundle's icon
            // and name when it has one.
            if let b = Dock.builtin(appID: t.appID) {
                items.append(b)
            } else if let app = AppLibrary.owner(of: t.appID, in: library) {
                items.append(DockItem(icon: .bundle(app.icon ?? ""), label: app.name, appID: t.appID,
                                      command: app.executable.map { [$0] }, appIDs: [t.appID],
                                      bundle: app.bundle))
            } else {
                let label = t.title.isEmpty ? (t.appID.isEmpty ? "App" : t.appID) : t.title
                items.append(DockItem(icon: .genericApp, label: label, appID: t.appID))
            }
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
                           pointerX: pointerX, tileSize: tileSize, magnify: magnify, agentBadge: agentBadge)
        logTiles(width: w)
        cairo_surface_flush(cs)
        cairo_destroy(cr)
        cairo_surface_destroy(cs)
    }

    /// Where each tile is, unmagnified, when the set changes (P15.2): its centre
    /// x — the Dock spans the output, so that is the output's x — and its
    /// centre's height above the output's bottom edge. Tests aim here instead of
    /// at coordinates measured once for one set of tiles; hovering a tile's own
    /// centre magnifies it in place, so the aim holds while it grows.
    private var lastTiles = ""
    private func logTiles(width w: Double) {
        let base = dockMagnify(count: displayItems.count, baseSize: tileSize, gap: DockMetrics.gap,
                               centerX: w / 2, pointerX: nil, maxScale: 1, range: 1)
        let up = Int(DockMetrics.bottomMargin + DockMetrics.panelPadV + tileSize / 2)
        let line = zip(displayItems, base).map { "\($0.label)=\(Int($1.centerX)),\(up)" }.joined(separator: " ")
        guard line != lastTiles else { return }
        lastTiles = line
        Dock.log("tiles " + line)
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
    static let removeFromDock = Command("dock.remove", "Remove from Dock",
                                        summary: "Take this application's tile off the Dock.")
    static let keepInDock = Command("dock.keep", "Keep in Dock",
                                    summary: "Leave this application's tile on the Dock when it quits.")

    /// A tile's menu: the Trash's two commands, or an application's — Open when
    /// it is not running, Quit when it is (P10.8).
    /// A pinned tile can be removed (the Finder's cannot: it is always there,
    /// as on Mac); a running application's own tile can be kept (P15.2b).
    static func tileMenu(isTrash: Bool, running: Bool, pinned: Bool = false,
                         removable: Bool = false) -> Menu {
        if isTrash { return Menu("Trash", [.command(trashOpen), .command(trashEmpty)]) }
        var items: [MenuItem] = [.command(running ? appQuit : appOpen), .separator]
        if pinned {
            if removable { items.append(.command(removeFromDock)) }
        } else if removable {
            items.append(.command(keepInDock))
        }
        items.append(.command(showInFinder))
        return Menu("", items)
    }

    private func isRunning(_ item: DockItem) -> Bool {
        toplevels?.current.contains { item.owns($0.appID) } ?? false
    }

    /// A tile's contextual menu. The Trash's was the only one until P10.8 —
    /// "Empty Trash" had to live somewhere, and on Mac that somewhere is here.
    private func openTileMenu(_ item: DockItem, frame f: DockTileFrame, iconBottom: Double) {
        closeMenu()
        let running = isRunning(item)
        let menu = Dock.tileMenu(isTrash: item.isTrash, running: running,
                                 pinned: item.pinToken != nil,
                                 removable: item.pinToken.map { $0 != "finder" } ?? item.isBundle)
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
                case "dock.remove":      self.unpin(item)
                case "dock.keep":
                    if let app = AppLibrary.owner(of: item.appID ?? "", in: self.library) {
                        self.pin(app.bundle, before: nil)
                    }
                case "dock.quit":
                    let ids = Set((self.toplevels?.current ?? []).map(\.appID).filter { item.owns($0) })
                    let n = ids.reduce(0) { $0 + (self.toplevels?.close(appID: $1) ?? 0) }
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
        if let t = toplevels?.current.first(where: { item.owns($0.appID) }) {
            toplevels?.activate(t)
            Dock.log("activated \(t.appID)")
            return
        }
        guard let command = item.command else {
            Dock.log("no launcher for \(appID)")
            return
        }
        if Launcher.launchDetached(command, extraEnv: item.environment) {
            if let b = item.bundle { RecentItems.record(b) }
            Dock.log("launched \(appID)")
        } else {
            Dock.log("launch failed for \(appID)")
        }
    }
}

extension Substring {
    func trimmingWhitespaceForDock() -> String {
        String(drop(while: { $0 == " " || $0 == "\t" }).reversed().drop(while: { $0 == " " || $0 == "\t" }).reversed())
    }
}
