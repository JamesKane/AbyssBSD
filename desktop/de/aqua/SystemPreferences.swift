// System Preferences — an application now, not a painting (PHASE14 P14.1).
//
// Until Phase 14 `paintSystemPreferences` drew Jaguar's pane grid and nothing
// was behind it. This is the application the rest of the phase fills in: the
// grid, the toolbar's favourites and Show All, a page per pane, the menus a
// Jaguar application publishes (Phase 10), and — for every pane — a line that
// says what it cannot do yet, or what failed, in words (PLAN: "somewhere the
// machine says what failed").
//
// **One layout, read by the painter and the hit-test** (§2.9): `prefsLayout`
// places every icon, and a click is tested against the same rects. The grid's
// geometry is P9's, moved here unchanged — the `sysprefs` golden is its proof.

import Surface
import CCairo
import AquaDraw
import MenuModel
import MenuWire
import Vents
import CWayland

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

// MARK: - The panes

/// One preference pane.
public struct PrefPane: Equatable, Sendable {
    public let id: String          // stable: "displays", "network" — the icon set's name
    public let title: String
    public let icon: PrefIcon
    /// What it will do, for the page and for a reader that cannot see it.
    public let purpose: String
}

public enum PrefCatalogue {
    static func pane(_ icon: PrefIcon, _ title: String, _ purpose: String) -> PrefPane {
        PrefPane(id: icon.name, title: title, icon: icon, purpose: purpose)
    }

    /// Jaguar's panes, in Jaguar's sections and order.
    public static let sections: [(title: String, panes: [PrefPane])] = [
        ("Personal", [
            pane(.desktop, "Desktop", "The picture on your desktop."),
            pane(.dock, "Dock", "Where the Dock sits, and how it magnifies."),
            pane(.general, "General", "Appearance: the theme, its colours and its settings."),
            pane(.international, "International", "Languages, formats and input sources."),
            pane(.loginItems, "Login Items", "What opens when you log in."),
            pane(.myAccount, "My Account", "Your name, picture and password."),
            pane(.screenEffects, "Screen Effects", "What the screen shows while you are away."),
        ]),
        ("Hardware", [
            pane(.cdsDvds, "CDs & DVDs", "What happens when a disc is inserted."),
            pane(.colorSync, "ColorSync", "Colour profiles for displays and printers."),
            pane(.displays, "Displays", "Resolution, arrangement and scale of each display."),
            pane(.energySaver, "Energy Saver", "When the display and the computer sleep."),
            pane(.keyboard, "Keyboard", "Key repeat, layouts and shortcuts."),
            pane(.mouse, "Mouse", "Tracking and scrolling speed."),
            pane(.sound, "Sound", "Output device, volume and alerts."),
        ]),
        ("Internet & Network", [
            pane(.internetIcon, "Internet", "Your default browser and mail."),
            pane(.network, "Network", "Wired and wireless connections, addresses and DNS."),
            pane(.quicktime, "QuickTime", "Media playback settings."),
            pane(.sharing, "Sharing", "What this computer offers to others."),
        ]),
        ("System", [
            pane(.accounts, "Accounts", "Who can log in to this computer."),
            pane(.classic, "Classic", "Not on this machine: there is no Classic here."),
            pane(.dateTime, "Date & Time", "The clock, the time zone and network time."),
            pane(.softwareUpdate, "Software Update", "Updates to AbyssBSD."),
            pane(.speech, "Speech", "Spoken alerts and voices."),
            pane(.startupDisk, "Startup Disk", "The disk this computer starts from."),
            pane(.universalAccess, "Universal Access", "Seeing, hearing and typing help."),
        ]),
    ]

    /// The toolbar's favourites, after Show All.
    public static let toolbar: [PrefPane] = ["displays", "sound", "network", "startupDisk"].compactMap(pane(id:))

    public static var all: [PrefPane] { sections.flatMap(\.panes) }
    public static func pane(id: String) -> PrefPane? { all.first { $0.id == id } }
}

// MARK: - The model

public enum PrefsView: Equatable, Sendable {
    case all
    case pane(String)
}

public struct PrefsModel: Equatable, Sendable {
    public var view: PrefsView = .all
    /// The grid cell the keyboard is on (a pane id), if any.
    public var focus: String?
    /// What a pane cannot do, or what failed, said on its page (P14.1: every
    /// pane says "not yet" until a later pass builds it).
    public var notes: [String: String] = [:]

    public init() {}

    public var title: String {
        if case .pane(let id) = view, let p = PrefCatalogue.pane(id: id) { return p.title }
        return "System Preferences"
    }

    /// What the page says a pane does not do yet — until a pass builds it.
    public func note(for id: String) -> String {
        if let n = notes[id] { return n }
        // General chooses the theme (P14.2) — the first pane that changes anything.
        switch id {
        case PrefsModel.appearancePane: return "Choose the theme, its scheme and its settings."
        case PrefsModel.networkPane: return "A wired interface's address, by DHCP or by hand, and the name servers."
        case PrefsModel.soundPane: return "The output device, its levels and mute, and who is playing."
        default: return "This pane cannot change anything yet."
        }
    }

    /// Jaguar's General pane, which chose the appearance: here, the theme.
    public static let appearancePane = "general"
    /// The wired network (P14.4c).
    public static let networkPane = "network"
    /// Sound (P14.6c).
    public static let soundPane = "sound"

    /// Arrow keys on the grid: across a row, then down into the next section
    /// as if the sections were one list — the order a reader walks them.
    public mutating func moveFocus(_ delta: Int) {
        let ids = PrefCatalogue.all.map(\.id)
        guard !ids.isEmpty else { return }
        guard let f = focus, let i = ids.firstIndex(of: f) else { focus = ids[delta < 0 ? ids.count - 1 : 0]; return }
        focus = ids[max(0, min(ids.count - 1, i + delta))]
    }
}

// MARK: - Layout (paint and hit-test read this)

public struct PrefsCell: Equatable, Sendable {
    public let pane: String
    public let icon: Rect
    public let hit: Rect           // the icon and its label
    public let labelCenterX: Double, labelTop: Double, labelMaxWidth: Double
}

public struct PrefsLayout: Equatable, Sendable {
    public var toolbar = Rect(0, 0, 0, 0)
    public var showAll = Rect(0, 0, 0, 0)
    public var toolbarItems: [PrefsCell] = []
    public var sectionTitles: [(String, Double, Double)] = []   // title, x, baseline
    public var cells: [PrefsCell] = []
    public var rules: [Rect] = []
    public var body = Rect(0, 0, 0, 0)
    /// The General pane's controls, when it is showing (P14.2).
    public var appearance = AppearanceLayout()
    /// The Network pane's controls, when it is showing (P14.4c).
    public var network = NetworkLayout()
    /// The Sound pane's controls, when it is showing (P14.6c).
    public var sound = SoundLayout()

    public static func == (a: PrefsLayout, b: PrefsLayout) -> Bool {
        a.toolbar == b.toolbar && a.showAll == b.showAll && a.toolbarItems == b.toolbarItems
            && a.cells == b.cells && a.rules == b.rules && a.body == b.body && a.appearance == b.appearance && a.network == b.network && a.sound == b.sound
            && a.sectionTitles.map(\.0) == b.sectionTitles.map(\.0)
    }
}

extension PrefsLayout: @unchecked Sendable {}

/// Where everything in the System Preferences window goes, at `w`×`h`.
public func prefsLayout(w: Double, h: Double) -> PrefsLayout {
    var l = PrefsLayout()
    let tbY = Theme.titleBarHeight, tbH = 58.0
    l.toolbar = Rect(0, tbY, w, tbH)
    let top = tbY + 6
    func item(_ id: String, _ cx: Double) -> PrefsCell {
        PrefsCell(pane: id, icon: Rect(cx - 16, top, 32, 32), hit: Rect(cx - 32, top, 64, 50),
                  labelCenterX: cx, labelTop: top + 42, labelMaxWidth: 64)
    }
    l.showAll = Rect(44 - 32, top, 64, 50)
    var tx = 130.0
    for p in PrefCatalogue.toolbar { l.toolbarItems.append(item(p.id, tx)); tx += 70 }

    let margin = 24.0, cols = 7, rowH = 80.0
    let cellW = (w - 2 * margin) / Double(cols)
    var y = tbY + tbH + 16
    l.body = Rect(0, tbY + tbH, w, h - tbY - tbH)
    for (title, panes) in PrefCatalogue.sections {
        l.sectionTitles.append((title, margin, y + 12))
        y += 24
        let rows = (panes.count + cols - 1) / cols
        for (i, p) in panes.enumerated() {
            let col = i % cols, row = i / cols
            let cx = margin + Double(col) * cellW + cellW / 2
            let iy = y + Double(row) * rowH
            l.cells.append(PrefsCell(pane: p.id, icon: Rect(cx - 24, iy, 48, 48),
                                     // 1 pt apart: cells that merely touched overlapped by
                                     // a rounding error, and a click on the seam was anyone's.
                                     hit: Rect(cx - cellW / 2 + 1, iy, cellW - 2, rowH - 8),
                                     labelCenterX: cx, labelTop: iy + 54, labelMaxWidth: cellW - 6))
        }
        y += Double(rows) * rowH + 6
        if title != "System" {
            l.rules.append(Rect(margin, y, w - 2 * margin, 1))
            y += 14
        }
    }
    return l
}

public enum PrefsHit: Equatable, Sendable { case showAll, pane(String) }

/// What a click at (x, y) means, from the same layout the painter drew.
/// The grid's cells only answer while the grid is showing.
public func prefsHit(_ l: PrefsLayout, _ m: PrefsModel, x: Double, y: Double) -> PrefsHit? {
    if l.showAll.contains(x, y) { return .showAll }
    if let t = l.toolbarItems.first(where: { $0.hit.contains(x, y) }) { return .pane(t.pane) }
    guard m.view == .all else { return nil }
    return l.cells.first { $0.hit.contains(x, y) }.map { .pane($0.pane) }
}

// MARK: - Paint

/// The window: chrome, toolbar, then the grid or a pane's page.
@discardableResult
public func paintSystemPreferences(_ cr: OpaquePointer, w: Double, h: Double,
                                   model: PrefsModel = PrefsModel(),
                                   themes: [InstalledTheme]? = nil,
                                   choice: AppearanceChoice? = nil,
                                   dragging: (String, Double)? = nil,
                                   network: NetworkPaneState? = nil,
                                   sound: SoundPaneState? = nil) -> PrefsLayout {
    var l = prefsLayout(w: w, h: h)
    paintWindowChrome(cr, w: w, h: h, title: model.title)

    Draw.paint("prefs.toolbar", cr, l.toolbar)
    toolbarItem(cr, .showAll, "Show All", centerX: 44, top: l.showAll.y)
    Draw.paint("prefs.toolbar.divider", cr, l.toolbar, parameters: ["x": 86])
    for t in l.toolbarItems {
        guard let p = PrefCatalogue.pane(id: t.pane) else { continue }
        toolbarItem(cr, p.icon, p.title, centerX: t.labelCenterX, top: t.icon.y)
    }

    switch model.view {
    case .all:
        for (title, x, baseline) in l.sectionTitles {
            Draw.textLeft(cr, title, x: x, baselineY: baseline, color: Theme.sectionTitleText, size: 13)
        }
        for c in l.cells {
            guard let p = PrefCatalogue.pane(id: c.pane) else { continue }
            if model.focus == c.pane {
                Draw.focusRing(cr, Rect(c.icon.x - 4, c.icon.y - 4, c.icon.w + 8, c.icon.h + 8), radius: 8)
            }
            Icons.draw(cr, p.icon, in: c.icon)
            centeredLabel(cr, p.title, centerX: c.labelCenterX, top: c.labelTop, maxWidth: c.labelMaxWidth)
        }
        for r in l.rules { Draw.paint("rule", cr, r) }
    case .pane(let id) where id == PrefsModel.appearancePane:
        // Read, not remembered: what is installed, and what appearance.ini
        // says now — so a change made elsewhere shows here too.
        let installed = themes ?? AppearanceCatalogue.installed()
        let chosen = choice ?? AppearanceChoice.current()
        l.appearance = appearanceLayout(body: l.body, themes: installed, choice: chosen)
        paintAppearancePane(cr, l.appearance, body: l.body, themes: installed, choice: chosen,
                            dragging: dragging)
    case .pane(let id) where id == PrefsModel.networkPane:
        let n = network ?? .sample
        l.network = networkLayout(body: l.body, interfaces: n.interfaces)
        paintNetworkPane(cr, l.network, status: n.status, form: n.form, note: n.note, busy: n.busy)
    case .pane(let id) where id == PrefsModel.soundPane:
        let s = sound ?? .sample
        l.sound = soundLayout(body: l.body, s)
        paintSoundPane(cr, l.sound, s)
    case .pane(let id):
        paintPrefPage(cr, l, id, model)
    }
    return l
}

/// A pane's page. In P14.1 every page says what the pane is for and that it
/// cannot change anything yet — honestly, rather than as a painting of
/// controls that do nothing.
private func paintPrefPage(_ cr: OpaquePointer, _ l: PrefsLayout, _ id: String, _ m: PrefsModel) {
    guard let p = PrefCatalogue.pane(id: id) else { return }
    let cx = l.body.x + l.body.w / 2, top = l.body.y + 40
    Icons.draw(cr, p.icon, in: Rect(cx - 32, top, 64, 64))
    Draw.text(cr, p.title, centerX: cx, centerY: top + 88, color: Theme.bodyText, size: 15, style: .bold)
    Draw.text(cr, p.purpose, centerX: cx, centerY: top + 114, color: Theme.secondaryText, size: 12)
    Draw.text(cr, m.note(for: id), centerX: cx, centerY: top + 144, color: Theme.bodyText, size: 13)
}

private func toolbarItem(_ cr: OpaquePointer, _ icon: PrefIcon, _ label: String,
                         centerX: Double, top: Double) {
    Icons.draw(cr, icon, in: Rect(centerX - 16, top, 32, 32))
    Draw.text(cr, label, centerX: centerX, centerY: top + 42,
              color: Theme.toolbarLabelText, size: 10)
}

/// Centred icon label, wrapped to two lines when it doesn't fit `maxWidth`.
private func centeredLabel(_ cr: OpaquePointer, _ s: String, centerX: Double,
                           top: Double, maxWidth: Double) {
    let size = 11.0
    if Draw.textWidth(cr, s, size: size) <= maxWidth {
        Draw.text(cr, s, centerX: centerX, centerY: top + size / 2,
                  color: Theme.iconLabelText, size: size)
        return
    }
    // Split into two balanced lines at a space.
    let words = s.split(separator: " ").map(String.init)
    var first = "", second = ""
    if words.count <= 1 {
        first = s
    } else {
        let mid = (words.count + 1) / 2
        first = words[0..<mid].joined(separator: " ")
        second = words[mid...].joined(separator: " ")
    }
    Draw.text(cr, first, centerX: centerX, centerY: top + size / 2,
              color: Theme.iconLabelText, size: size)
    if !second.isEmpty {
        Draw.text(cr, second, centerX: centerX, centerY: top + size * 1.5 + 1,
                  color: Theme.iconLabelText, size: size)
    }
}

// MARK: - The vocabulary (Phase 10)

public enum PrefsVerb {
    public static let about = "app.about"
    public static let quit = "app.quit"
    public static let showAll = "view.showAll"
    public static let minimize = "window.minimize"
    public static let close = "window.close"
    /// `view.pane.<id>` — one per pane, as Jaguar's View menu lists them.
    public static func pane(_ id: String) -> String { "view.pane." + id }
    public static func paneID(_ verb: String) -> String? {
        verb.hasPrefix("view.pane.") ? String(verb.dropFirst("view.pane.".count)) : nil
    }
}

public func systemPreferencesMenuBar() -> MenuBarModel {
    func c(_ verb: String, _ title: String, _ key: KeyEquivalent? = nil, _ summary: String) -> MenuItem {
        .command(Command(verb, title, key: key, summary: summary))
    }
    var view: [MenuItem] = [c(PrefsVerb.showAll, "Show All Preferences", .cmd("l"), "Show every pane.")]
    for (_, panes) in PrefCatalogue.sections {
        view.append(.separator)
        for p in panes { view.append(c(PrefsVerb.pane(p.id), p.title, nil, "Open the \(p.title) pane.")) }
    }
    return MenuBarModel(appName: "System Preferences", menus: [
        Menu("System Preferences", [
            c(PrefsVerb.about, "About System Preferences", nil, "Show System Preferences' version."),
            .separator,
            c(PrefsVerb.quit, "Quit System Preferences", .cmd("q"), "Close System Preferences."),
        ]),
        Menu("View", view),
        Menu("Window", [
            c(PrefsVerb.minimize, "Minimize", .cmd("m"), "Put the window in the Dock."),
            c(PrefsVerb.close, "Close", .cmd("w"), "Close the window."),
        ]),
    ])
}

// MARK: - The application

public final class SystemPreferencesApp: WindowDelegate, MenuProvider {
    private var window: Window?
    private let display: Display
    public private(set) var model = PrefsModel()
    public private(set) var layout = PrefsLayout()
    private var pointerX = 0.0, pointerY = 0.0
    private var menuService: MenuService?
    private let dumpLayout = getenv("ABYSS_PREFS_DUMP") != nil
    private var dumpedView: PrefsView?
    private var dumpedAppearance: AppearanceLayout?
    public var onQuit: () -> Void = { exit(0) }
    /// The themes installed, read when the General pane is shown.
    private var installedThemes: [InstalledTheme] = []
    /// A setting being dragged: its name and the value under the pointer.
    /// Written when the button comes up, not on every step — one change,
    /// not a stream of them for every process on the desktop to follow.
    private var dragging: (String, Double)?
    /// The Network pane: the kernel's status, the form, what the helper said.
    private var network = NetworkPaneState(status: Vents.Network.Status(interfaces: [], router: nil, nameServers: []),
                                           form: nil)
    private var networkWatch: Vents.Network.Watch?
    /// The socket an apply is reporting on, while it is.
    private var applying: Int32?
    private var skipped: [String] = []
    private var dumpedNetwork: NetworkLayout?
    /// The Sound pane: the machine as last read, a drag in progress, an apply.
    private var sound = SoundPaneState()
    private var soundDrag: String?
    private var soundApplying: Int32?
    private var soundTimer: Int32 = -1
    private var dumpedSound: SoundLayout?

    public static let menuBar = systemPreferencesMenuBar()

    public init?(display: Display, width: Int32 = 760, height: Int32 = 620) {
        self.display = display
        let scale: Int32, auto: Bool
        if let s = getenv("AQUA_SCALE"), let v = Int32(String(cString: s)), v > 0 { (scale, auto) = (v, false) }
        else { (scale, auto) = (1, true) }
        guard let win = Window(display: display, title: "System Preferences",
                               appID: "org.abyssbsd.preferences", width: width, height: height,
                               scale: scale, autoScale: auto, delegate: self) else { return nil }
        window = win
        display.window = win
        let name = MenuWire.serviceName(app: "SystemPreferences", pid: getpid())
        if let service = try? MenuService(name: name, provider: self) {
            display.addFileDescriptor(service.fd) { [weak service] in service?.serviceReadable() }
            menuService = service
            if win.publishMenus(at: name) { SystemPreferencesApp.log("menus on \(name)") }
        }
        // The kernel says when an address, a link or a route changes; the
        // Network pane redraws from it, so a lease or a cable shows at once.
        if let w = Vents.Network.Watch() {
            display.addFileDescriptor(w.fileDescriptor) { [weak self] in self?.networkChanged() }
            networkWatch = w
        }
        // Nothing tells anyone a mixer level changed, so the Sound pane reads
        // the machine again every second while it shows (the menu bar's rate).
        soundTimer = aw_create_interval_timer(1000)
        if soundTimer >= 0 {
            display.addFileDescriptor(soundTimer) { [weak self] in self?.soundTick() }
        }
    }

    static func log(_ s: String) {
        ("SystemPreferences: " + s + "\n").withCString { _ = write(2, $0, strlen($0)) }
    }

    // MARK: navigation

    public func show(_ v: PrefsView) {
        guard model.view != v else { return }
        model.view = v
        if v == .pane(PrefsModel.appearancePane) { installedThemes = AppearanceCatalogue.installed() }
        if v == .pane(PrefsModel.networkPane) { loadNetwork(interface: nil) }
        if v == .pane(PrefsModel.soundPane) { loadSound(readConfigured: true) }
        window?.setTitle(model.title)
        switch v {
        case .all: SystemPreferencesApp.log("showing all")
        case .pane(let id): SystemPreferencesApp.log("showing \(id) — \(model.note(for: id))")
        }
        menuService?.changed()
        window?.setNeedsDisplay()
    }

    // MARK: WindowDelegate

    public func render(_ buffer: PixelBuffer) {
        Text.renderScale = buffer.scale
        let w = Double(buffer.width / buffer.scale), h = Double(buffer.height / buffer.scale)
        let cs = cairo_image_surface_create_for_data(buffer.data.assumingMemoryBound(to: UInt8.self),
                                                     CAIRO_FORMAT_ARGB32, buffer.width, buffer.height, buffer.stride)
        guard let cr = cairo_create(cs) else { cairo_surface_destroy(cs); return }
        cairo_scale(cr, Double(buffer.scale), Double(buffer.scale))
        cairo_save(cr); cairo_set_operator(cr, CAIRO_OPERATOR_CLEAR); cairo_paint(cr); cairo_restore(cr)
        cairo_set_operator(cr, CAIRO_OPERATOR_OVER)
        layout = paintSystemPreferences(cr, w: w, h: h, model: model,
                                        themes: installedThemes, choice: AppearanceChoice.current(),
                                        dragging: dragging, network: network, sound: sound)
        cairo_surface_flush(cs); cairo_destroy(cr); cairo_surface_destroy(cs)
        // Publish what was drawn, so a test clicks it rather than coordinates
        // copied into a script (§2.46).
        if dumpLayout && dumpedView != model.view {
            dumpedView = model.view
            func c(_ r: Rect) -> String { "\(Int(r.x + r.w / 2)),\(Int(r.y + r.h / 2))" }
            var line = "SystemPreferences: layout showAll=\(c(layout.showAll))"
            for t in layout.toolbarItems { line += " tb.\(t.pane)=\(c(t.hit))" }
            if model.view == .all { for cell in layout.cells { line += " \(cell.pane)=\(c(cell.icon))" } }
            SystemPreferencesApp.log(String(line.dropFirst("SystemPreferences: ".count)))
        }
        // The General pane's controls move with the theme chosen (its schemes
        // and settings are that theme's), so they are published whenever they
        // change: `theme.<id>` and `scheme.<name>` at the radio,
        // `param.<name>=x0-x1,y` along the track.
        if dumpLayout, model.view == .pane(PrefsModel.appearancePane), dumpedAppearance != layout.appearance {
            dumpedAppearance = layout.appearance
            func c(_ r: Rect) -> String { "\(Int(r.x + r.w / 2)),\(Int(r.y + r.h / 2))" }
            var line = "appearance"
            for r in layout.appearance.themes { line += " theme.\(r.value)=\(c(r.control))" }
            for r in layout.appearance.schemes { line += " scheme.\(r.value)=\(c(r.control))" }
            for r in layout.appearance.parameters {
                line += " param.\(r.value)=\(Int(r.control.x))-\(Int(r.control.x + r.control.w)),\(Int(r.control.y + r.control.h / 2))"
            }
            SystemPreferencesApp.log(line)
        }
        // The Network pane's: `iface.<name>`, `mode.dhcp`/`mode.manual`,
        // `field.<name>` (the editable ones), `revert`, `apply`.
        if dumpLayout, model.view == .pane(PrefsModel.networkPane), dumpedNetwork != layout.network {
            dumpedNetwork = layout.network
            func c(_ r: Rect) -> String { "\(Int(r.x + r.w / 2)),\(Int(r.y + r.h / 2))" }
            let n = layout.network
            var line = "network layout"
            for r in n.interfaces { line += " iface.\(r.value)=\(c(r.hit))" }
            line += " mode.dhcp=\(c(n.dhcp.hit)) mode.manual=\(c(n.manual.hit))"
            for f in NetworkField.allCases { if let r = n.fields[f] { line += " field.\(f.rawValue)=\(c(r))" } }
            line += " revert=\(c(n.revert)) apply=\(c(n.apply))"
            SystemPreferencesApp.log(line)
        }
        // The Sound pane's: `output.<unit>` at the radio, `level.<control>=
        // x0-x1,y` along the track, `mute.<control>` at the checkbox.
        if dumpLayout, model.view == .pane(PrefsModel.soundPane), dumpedSound != layout.sound {
            dumpedSound = layout.sound
            func c(_ r: Rect) -> String { "\(Int(r.x + r.w / 2)),\(Int(r.y + r.h / 2))" }
            var line = "sound layout"
            for r in layout.sound.outputs { line += " output.\(r.value)=\(c(r.hit))" }
            for r in layout.sound.levels {
                line += " level.\(r.value)=\(Int(r.control.x))-\(Int(r.control.x + r.control.w)),\(Int(r.control.y + r.control.h / 2))"
            }
            for r in layout.sound.mutes { line += " mute.\(r.value)=\(c(r.hit))" }
            SystemPreferencesApp.log(line)
        }
    }

    // MARK: the Sound pane

    private func loadSound(readConfigured: Bool) {
        let note = sound.note, busy = sound.busy
        sound = SoundPaneState.read()
        sound.note = note; sound.busy = busy
        SystemPreferencesApp.log("sound: status \(SoundWords.statusLine(sound))")
        guard readConfigured, !sound.devices.isEmpty else { return }
        // What the next boot will choose — which is not always what /dev/dsp
        // means now (a device plugged in since, with default_auto).
        switch SettingsClient.read("sound") {
        case .success(.sound(let p)):
            SystemPreferencesApp.log("sound: read default pcm\(p.defaultUnit)")
            if p.defaultUnit != sound.defaultUnit {
                sound.note = "At the next start, the output will be pcm\(p.defaultUnit)."
            }
        case .success: break
        case .failure(let why):
            sound.note = "The settings helper says: \(why.message)"
            SystemPreferencesApp.log("sound: cannot read: \(why.message)")
        }
        window?.setNeedsDisplay()
    }

    private func soundTick() {
        var buf = UInt64(0)
        _ = withUnsafeMutableBytes(of: &buf) { read(soundTimer, $0.baseAddress, MemoryLayout<UInt64>.size) }
        guard model.view == .pane(PrefsModel.soundPane), soundDrag == nil else { return }
        var fresh = SoundPaneState.read()
        fresh.note = sound.note; fresh.busy = sound.busy
        guard fresh != sound else { return }
        sound = fresh
        SystemPreferencesApp.log("sound: changed \(SoundWords.statusLine(sound))")
        window?.setNeedsDisplay()
    }

    /// Set a level on the default device, and show it at once (the next tick
    /// reads it back from the mixer).
    private func setLevel(_ name: String, _ level: Int) {
        guard let unit = sound.defaultUnit, let i = sound.controls.firstIndex(where: { $0.name == name }) else { return }
        if let why = Vents.Sound.set(unit: unit, control: name, left: level, right: level) {
            sound.note = "Could not set \(SoundWords.label(name)): \(why)"
            SystemPreferencesApp.log("sound: \(sound.note)")
        } else {
            let c = sound.controls[i]
            sound.controls[i] = .init(name: c.name, left: level, right: level, muted: c.muted, recordable: c.recordable)
        }
        window?.setNeedsDisplay()
    }

    private func pressSound(_ hit: SoundHit) {
        switch hit {
        case .level(let name, let v):
            soundDrag = name
            setLevel(name, v)
        case .mute(let name):
            guard let unit = sound.defaultUnit, let c = sound.controls.first(where: { $0.name == name }) else { return }
            if let why = Vents.Sound.set(unit: unit, control: name, muted: !c.muted) {
                sound.note = "Could not mute \(SoundWords.label(name)): \(why)"
            } else {
                SystemPreferencesApp.log("sound: \(name) \(c.muted ? "unmuted" : "muted")")
            }
            loadSound(readConfigured: false)
        case .output(let unit):
            guard unit != sound.defaultUnit, soundApplying == nil else { return }
            SystemPreferencesApp.log("sound: apply default pcm\(unit)")
            guard let sock = SettingsClient.begin(SettingsClient.soundRequest(defaultUnit: unit)) else {
                sound.note = "Not changed: the settings helper is not running on this machine"
                SystemPreferencesApp.log("sound: \(sound.note)")
                window?.setNeedsDisplay()
                return
            }
            soundApplying = sock
            skipped = []
            sound.busy = true
            display.addFileDescriptor(sock) { [weak self] in self?.soundEvent() }
        }
        window?.setNeedsDisplay()
    }

    private func soundEvent() {
        guard let sock = soundApplying else { return }
        let e = SettingsClient.next(on: sock) ?? .finished(ok: false, error: "the settings helper hung up")
        switch e {
        case .starting(let i, let n, let what): SystemPreferencesApp.log("sound: [\(i + 1)/\(n)] \(what)")
        case .ok: return
        case .skipped(_, let why): skipped.append(why); SystemPreferencesApp.log("sound: skipped: \(why)")
        case .failed(_, _, let why, let ignored):
            SystemPreferencesApp.log("sound: \(ignored ? "failed, and that is allowed" : "FAILED"): \(why)")
        case .finished(let ok, let error):
            display.removeFileDescriptor(sock)
            close(sock)
            soundApplying = nil
            sound.busy = false
            let said = NetworkWords.outcome(ok: ok, error: error, skipped: skipped)
            sound.note = said
            SystemPreferencesApp.log("sound: \(ok ? "applied" : "not applied") — \(said)")
            loadSound(readConfigured: false)
        }
        window?.setNeedsDisplay()
    }

    // MARK: the Network pane

    /// Status from the kernel, the form from rc.conf through the helper. With
    /// no interface named, the one showing — else the first there is.
    private func loadNetwork(interface: String?) {
        network.status = Vents.Network.status()
        let names = network.interfaces
        guard let name = interface ?? network.form.map(\.interface).flatMap({ names.contains($0) ? $0 : nil })
                ?? names.first else {
            network.form = nil
            SystemPreferencesApp.log("network: no wired interface")
            return
        }
        SystemPreferencesApp.log("network: status \(NetworkWords.statusLine(network.status, interface: name))")
        switch NetworkClient.read(name) {
        case .success(let plan):
            network.form = NetworkForm.from(plan)
            network.note = ""
            SystemPreferencesApp.log("network: read \(network.form!.summary)")
        case .failure(let why):
            // Nothing to show from rc.conf: the form starts at DHCP, and the
            // page says why in the helper's words.
            network.form = NetworkForm(interface: name)
            network.note = "The settings helper says: \(why.message)"
            SystemPreferencesApp.log("network: cannot read \(name): \(why.message)")
        }
        window?.setNeedsDisplay()
    }

    private func networkChanged() {
        guard networkWatch?.drain() == true, model.view == .pane(PrefsModel.networkPane) else { return }
        network.status = Vents.Network.status()
        if let f = network.form {
            SystemPreferencesApp.log("network: changed \(NetworkWords.statusLine(network.status, interface: f.interface))")
        }
        window?.setNeedsDisplay()
    }

    private func applyNetwork() {
        guard applying == nil, let form = network.form else { return }
        SystemPreferencesApp.log("network: apply \(form.summary)")
        guard let sock = NetworkClient.begin(form) else {
            network.note = "Not applied: the settings helper is not running on this machine"
            SystemPreferencesApp.log("network: \(network.note)")
            window?.setNeedsDisplay()
            return
        }
        applying = sock
        skipped = []
        network.busy = true
        network.note = "Applying…"
        display.addFileDescriptor(sock) { [weak self] in self?.networkEvent() }
        window?.setNeedsDisplay()
    }

    private func networkEvent() {
        guard let sock = applying else { return }
        let e = NetworkClient.next(on: sock) ?? .finished(ok: false, error: "the settings helper hung up")
        switch e {
        case .starting(let i, let n, let what):
            network.note = "Step \(i + 1) of \(n): \(what)"
            SystemPreferencesApp.log("network: [\(i + 1)/\(n)] \(what)")
        case .ok: return
        case .skipped(_, let why):
            skipped.append(why)
            SystemPreferencesApp.log("network: skipped: \(why)")
        case .failed(_, _, let why, let ignored):
            SystemPreferencesApp.log("network: \(ignored ? "failed, and that is allowed" : "FAILED"): \(why)")
        case .finished(let ok, let error):
            display.removeFileDescriptor(sock)
            close(sock)
            applying = nil
            network.busy = false
            let said = NetworkWords.outcome(ok: ok, error: error, skipped: skipped)
            SystemPreferencesApp.log("network: \(ok ? "applied" : "not applied") — \(said)")
            if ok, let name = network.form?.interface { loadNetwork(interface: name) }
            network.note = said
        }
        window?.setNeedsDisplay()
    }

    private func pressNetwork(_ hit: NetworkHit) {
        guard network.form != nil else { return }
        switch hit {
        case .interface(let name):
            guard name != network.form?.interface else { return }
            loadNetwork(interface: name)
        case .mode(let dhcp):
            network.form!.setDHCP(dhcp)
            SystemPreferencesApp.log("network: mode \(dhcp ? "dhcp" : "manual")")
        case .field(let f):
            network.form!.focus = f
            SystemPreferencesApp.log("network: focus \(f.rawValue)")
        case .revert:
            SystemPreferencesApp.log("network: revert")
            loadNetwork(interface: network.form!.interface)
        case .apply:
            applyNetwork()
        }
        window?.setNeedsDisplay()
    }

    private func networkKey(_ event: KeyEvent) {
        guard network.form != nil else { return }
        switch event.keysym {
        case KeySym.tab where event.modifiers.contains(.shift), KeySym.backTab: network.form!.moveFocus(-1)
        case KeySym.tab: network.form!.moveFocus(1)
        case KeySym.backspace: network.form!.backspace()
        case KeySym.enter: applyNetwork(); return
        default:
            guard !event.modifiers.contains(.command), !event.modifiers.contains(.control) else { return }
            network.form!.type(event.text)
        }
        window?.setNeedsDisplay()
    }

    public func pointerMoved(x: Double, y: Double) {
        pointerX = x; pointerY = y
        if let name = soundDrag, let row = layout.sound.levels.first(where: { $0.value == name }) {
            let v = soundLevel(track: row.control, x: x)
            if sound.controls.first(where: { $0.name == name })?.level != v { setLevel(name, v) }
        }
        if let (name, _) = dragging,
           let row = layout.appearance.parameters.first(where: { $0.value == name }),
           let p = installedThemes.first(where: { $0.id == AppearanceChoice.current().theme })?
               .parameters.first(where: { $0.name == name }) {
            dragging = (name, appearanceValue(p, track: row.control, x: x))
            window?.setNeedsDisplay()
        }
    }

    /// Write a choice where every process reads it, and say so. Nothing else:
    /// this window redraws because its own watch sees the file change, the
    /// same way every other process does.
    private func choose(_ hit: AppearanceHit) {
        let now = AppearanceChoice.current()
        let next = AppearanceWrite.next(hit, from: now)
        guard next != now else { return }
        do {
            try AppearanceWrite.store(next)
            model.notes[PrefsModel.appearancePane] = nil
            let params = next.parameters.keys.sorted().map { "\($0)=\(twoPlaces(next.parameters[$0]!))" }
            SystemPreferencesApp.log("appearance -> \(next.theme)"
                + (next.scheme.map { " (\($0))" } ?? "")
                + (params.isEmpty ? "" : " " + params.joined(separator: " ")))
        } catch {
            model.notes[PrefsModel.appearancePane] = "Could not save the theme: \(error)"
            SystemPreferencesApp.log("appearance: could not write appearance.ini: \(error)")
        }
        window?.setNeedsDisplay()
    }

    public func pointerButton(_ button: UInt32, pressed: Bool) {
        if !pressed, let name = soundDrag {
            soundDrag = nil
            SystemPreferencesApp.log("sound: \(name) set to \(sound.controls.first { $0.name == name }?.level ?? -1)")
            return
        }
        if !pressed, let (name, value) = dragging {
            dragging = nil
            choose(.parameter(name, value))
            return
        }
        guard pressed, let w = window else { return }
        let size = w.size
        switch windowChromeHit(x: pointerX, y: pointerY, w: Double(size.width), h: Double(size.height)) {
        case .close: onQuit(); return
        case .minimize: w.minimize(); return
        case .zoom: w.setMaximized(!w.isMaximized); return
        case .depth: w.lower(); return
        case .title: w.beginMove(); return
        case .resize(let e): w.beginResize(e); return
        case .pill, .content: break
        }
        if dumpLayout {
            SystemPreferencesApp.log("press at \(Int(pointerX)),\(Int(pointerY))")
        }
        if model.view == .pane(PrefsModel.soundPane), let hit = soundHit(layout.sound, x: pointerX, y: pointerY) {
            pressSound(hit)
            return
        }
        if model.view == .pane(PrefsModel.networkPane),
           let hit = networkHit(layout.network, form: network.form ?? NetworkForm(interface: ""),
                                x: pointerX, y: pointerY) {
            pressNetwork(hit)
            return
        }
        if model.view == .pane(PrefsModel.appearancePane),
           let hit = appearanceHit(layout.appearance, themes: installedThemes,
                                   choice: AppearanceChoice.current(), x: pointerX, y: pointerY) {
            if case .parameter(let name, let v) = hit {
                dragging = (name, v)          // written when the button comes up
                SystemPreferencesApp.log("appearance: dragging \(name) from \(twoPlaces(v))")
                window?.setNeedsDisplay()
            } else {
                choose(hit)
            }
            return
        }
        switch prefsHit(layout, model, x: pointerX, y: pointerY) {
        case .showAll?: show(.all)
        case .pane(let id)?: model.focus = id; show(.pane(id))
        case nil: break
        }
    }

    public func keyEvent(_ event: KeyEvent) {
        guard event.pressed else { return }
        if event.modifiers.contains(.command), let press = keyEquivalent(event),
           let verb = SystemPreferencesApp.menuBar.verb(for: press) {
            _ = menuPerform(Command(verb, verb, summary: ""), arguments: [:])
            return
        }
        guard model.view == .all else {
            if event.keysym == KeySym.escape { show(.all) }
            else if model.view == .pane(PrefsModel.networkPane) { networkKey(event) }
            return
        }
        switch event.keysym {
        case KeySym.left: model.moveFocus(-1)
        case KeySym.right, KeySym.tab: model.moveFocus(1)
        case KeySym.up: model.moveFocus(-7)
        case KeySym.down: model.moveFocus(7)
        case KeySym.enter, KeySym.space:
            if let f = model.focus { show(.pane(f)); return }
        default: return
        }
        SystemPreferencesApp.log("focus \(model.focus ?? "none")")
        window?.setNeedsDisplay()
    }

    public func windowShouldClose(_ window: Window) { onQuit() }

    // MARK: MenuProvider

    public var menuModel: MenuBarModel { SystemPreferencesApp.menuBar }

    public func menuValidate(_ command: Command) -> Enablement {
        switch command.verb {
        case PrefsVerb.about: return .disabled("System Preferences has no About box yet")
        case PrefsVerb.showAll: return model.view == .all ? .disabled("every pane is showing") : .enabled
        case PrefsVerb.quit, PrefsVerb.minimize, PrefsVerb.close: return .enabled
        default:
            guard let id = PrefsVerb.paneID(command.verb), PrefCatalogue.pane(id: id) != nil else {
                return .disabled("System Preferences has no verb \(command.verb)")
            }
            return model.view == .pane(id) ? .disabled("that pane is showing") : .enabled
        }
    }

    public func menuPerform(_ command: Command, arguments: [String: String]) -> CommandResult {
        if case .disabled(let why) = menuValidate(command) { return .refused(why) }
        switch command.verb {
        case PrefsVerb.quit, PrefsVerb.close: onQuit(); return .ok("")
        case PrefsVerb.minimize: window?.minimize(); return .ok("")
        case PrefsVerb.showAll: show(.all); return .ok("all")
        default:
            guard let id = PrefsVerb.paneID(command.verb) else { return .refused("no such verb") }
            model.focus = id
            show(.pane(id))
            return .ok(id)
        }
    }
}
