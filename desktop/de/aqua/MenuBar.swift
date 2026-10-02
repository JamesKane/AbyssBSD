// MenuBar — the Jaguar menu bar: a wlr-layer-shell TOP strip across the top of
// the screen with an exclusive zone, the system (Apple-position) menu, the bold
// application menu, the standard app menus, and a clock at the right. It's the
// first *interactive* layer surface: clicking a title opens a real dropdown (an
// AquaMenu in a grabbing popup parented to this layer surface).
//
// Config (domain `panel`): `show_clock` (bool, default true), `menubar_height`
// (default 22). The clock ticks via a timerfd folded into the run loop.
//
// The system glyph in the Apple menu's position is an original water-drop mark
// (the aquatic AbyssBSD motif), not Apple's apple — same "original glyphs, not
// Apple artwork" policy as the pref icons.

import Surface
import PoolConfig
import Vents
import CCairo
import CWayland
import MenuWire
import CurrentIPC
import Login

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

private let kBtnLeft: UInt32 = 0x110

public struct MenuBarMenu: Sendable {
    public let isSystem: Bool   // the drop-glyph slot (Apple-menu position)
    public let bold: Bool       // the application-name menu is bold
    /// What opens under the title — a `MenuModel.Menu` since P10.1, so the bar
    /// draws an application's own definition rather than a list of strings.
    public let menu: Menu
    public var title: String { isSystem ? "" : menu.title }
    public init(_ menu: Menu, isSystem: Bool = false, bold: Bool = false) {
        self.menu = menu; self.isSystem = isSystem; self.bold = bold
    }
}

public struct MenuBarLayout {
    public var titleRects: [Rect]      // aligned with the menus array
    public var clockRect: Rect
    /// The status items ("menu extras"), nil when the machine can't feed them.
    public var volumeRect: Rect?
    public var batteryRect: Rect?
    /// The island item (PHASE13 P13.4), left of the status items; nil with
    /// one island, or no compositor to ask.
    public var islandRect: Rect?
    public init(titleRects: [Rect] = [], clockRect: Rect = Rect(0, 0, 0, 0),
                volumeRect: Rect? = nil, batteryRect: Rect? = nil, islandRect: Rect? = nil) {
        self.titleRects = titleRects; self.clockRect = clockRect
        self.volumeRect = volumeRect; self.batteryRect = batteryRect
        self.islandRect = islandRect
    }
}

public enum MenuBarMetrics {
    public static var height: Double { Theme.current.menuBarHeight }
    public static var leftMargin: Double { Theme.current.menuBarLeftMargin }
    public static var systemSlot: Double { Theme.current.menuBarSystemSlot }
    public static var titlePadX: Double { Theme.current.menuBarTitlePadX }
    public static var clockMarginRight: Double { Theme.current.menuBarClockMarginRight }
    public static var fontSize: Double { Theme.current.menuBarFontSize }
}

/// Format the menu-bar clock, Aqua-style ("Mon 9:41 AM", no leading zero on the
/// hour). Pure, so it's unit-testable without a real clock.
public func formatMenuClock(hour24: Int, minute: Int, wday: Int) -> String {
    let days = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
    let ampm = hour24 < 12 ? "AM" : "PM"
    var h = hour24 % 12; if h == 0 { h = 12 }
    let mm = minute < 10 ? "0\(minute)" : "\(minute)"
    let day = (wday >= 0 && wday < 7) ? days[wday] + " " : ""
    return "\(day)\(h):\(mm) \(ampm)"
}

/// Compute title/clock geometry. Title widths come from shaped text, so this
/// needs a cairo context; the component caches the result each render and
/// hit-tests against it (the "layout is truth" discipline).
public func menuBarLayout(_ cr: OpaquePointer, w: Double, h: Double,
                          menus: [MenuBarMenu], clock: String,
                          showClock: Bool,
                          status: MenuBarStatus = MenuBarStatus(),
                          island: String? = nil) -> MenuBarLayout {
    var rects: [Rect] = []
    var x = MenuBarMetrics.leftMargin
    for m in menus {
        let width: Double
        if m.isSystem {
            width = MenuBarMetrics.systemSlot
        } else {
            let style: Text.Style = m.bold ? .bold : .regular
            width = Draw.textWidth(cr, m.title, size: MenuBarMetrics.fontSize,
                                   style: style, role: .chrome) + 2 * MenuBarMetrics.titlePadX
        }
        rects.append(Rect(x, 0, width, h))
        x += width
    }
    var clockRect = Rect(0, 0, 0, 0)
    if showClock && !clock.isEmpty {
        let cw = Draw.textWidth(cr, clock, size: MenuBarMetrics.fontSize, role: .readout) + 4
        clockRect = Rect(w - cw - MenuBarMetrics.clockMarginRight, 0, cw, h)
    }
    // Status items are right-aligned against whatever the clock left free (or
    // the bar's right margin when there is no clock).
    let statusRight = clockRect.w > 0 ? clockRect.x : w - MenuBarMetrics.clockMarginRight
    let items = menuBarStatusLayout(status: status, h: h, rightEdge: statusRight)
    // The island item sits left of the status items, as one more of them.
    var islandRect: Rect? = nil
    if let island, !island.isEmpty {
        let left = [items.volume?.x, items.battery?.x].compactMap { $0 }.min() ?? statusRight
        let iw = Draw.textWidth(cr, island, size: MenuBarMetrics.fontSize, role: .chrome)
            + 2 * MenuBarMetrics.titlePadX
        islandRect = Rect(left - iw - 4, 0, iw, h)
    }
    return MenuBarLayout(titleRects: rects, clockRect: clockRect,
                         volumeRect: items.volume, batteryRect: items.battery,
                         islandRect: islandRect)
}

/// Paint the menu bar. `openIndex` (if any) is drawn highlighted in menu blue.
/// Returns the layout for hit-testing.
@discardableResult
public func paintMenuBar(_ cr: OpaquePointer, w: Double, h: Double,
                         menus: [MenuBarMenu], clock: String,
                         openIndex: Int?, showClock: Bool,
                         status: MenuBarStatus = MenuBarStatus(),
                         island: String? = nil, islandOpen: Bool = false) -> MenuBarLayout {
    Draw.paint("menubar", cr, Rect(0, 0, w, h))

    let layout = menuBarLayout(cr, w: w, h: h, menus: menus, clock: clock,
                               showClock: showClock, status: status, island: island)
    if let r = layout.islandRect, let island {
        if islandOpen { Draw.paint("menubar.highlight", cr, Rect(r.x, 0, r.w, h)) }
        Draw.textLeft(cr, island, x: r.x + MenuBarMetrics.titlePadX, baselineY: h - 6.5,
                      color: islandOpen ? Theme.menuTextOnHighlight : Theme.menuBarText,
                      size: MenuBarMetrics.fontSize, style: .regular, role: .chrome)
    }
    for (i, m) in menus.enumerated() {
        let r = layout.titleRects[i]
        let open = (i == openIndex)
        if open { Draw.paint("menubar.highlight", cr, Rect(r.x, 0, r.w, h)) }
        let color = open ? Theme.menuTextOnHighlight : Theme.menuBarText
        if m.isSystem {
            Draw.paint("menubar.system", cr, Rect(r.x + (r.w - 14) / 2, (h - 14) / 2, 14, 14),
                       open ? .selected : [])
        } else {
            let style: Text.Style = m.bold ? .bold : .regular
            Draw.textLeft(cr, m.title, x: r.x + MenuBarMetrics.titlePadX,
                          baselineY: h - 6.5, color: color,
                          size: MenuBarMetrics.fontSize, style: style, role: .chrome)
        }
    }
    if showClock && !clock.isEmpty {
        Draw.paint("menubar.clock", cr, Rect(layout.clockRect.x, 0, layout.clockRect.w, h),
                   label: clock, parameters: ["size": MenuBarMetrics.fontSize])
    }
    if !status.isEmpty {
        let statusRight = layout.clockRect.w > 0
            ? layout.clockRect.x : w - MenuBarMetrics.clockMarginRight
        paintMenuBarStatus(cr, status: status, h: h, rightEdge: statusRight,
                           color: Theme.menuBarText)
    }
    return layout
}

public final class MenuBar: LayerSurfaceDelegate {
    private var layer: LayerSurface?
    private var menus: [MenuBarMenu] { didSet { markConfined() } }
    /// The frontmost window's jail class, or "" (PHASE18 P18.6): said at the
    /// top of the application's menu, whatever the application published.
    private var confinedIn = ""
    private var markingConfined = false
    private let showClock: Bool
    private var clock = ""
    private var layoutCache = MenuBarLayout()
    private var openIndex: Int?

    private var menu: AquaMenu?
    private var popup: Popup?
    private var pointerX = 0.0
    private var timerFd: Int32 = -1
    /// What the status items show, read through Vents each tick; an item with
    /// nothing behind it (no sound card, no battery) is not drawn.
    private var status = MenuBarStatus()
    /// Who is frontmost and where their menus are, from the compositor
    /// (P10.3). Nil unless this bar connected through undertow's privileged
    /// socket — the only connection offered it.
    private var focus: MenuBarFocus?
    /// The main display's island, as the item shows it (P13.4): nil with one
    /// island, so a desktop that never uses them has no item.
    private var islandLabel: String?
    private var islandOpen = false
    private var loggedIslandItem: String?
    /// The frontmost application's menu service, when it has one (P10.4).
    /// Nil means the bar is drawing a definition it cannot ask about: the
    /// Finder's, under a compositor that has no view of focus to give.
    private var service: String?
    /// With `service`, which application it answers for — set only for the GTK
    /// bridge, which serves them all (P10.6).
    private var target: String?
    /// Enablement pulled when the open menu opened (PHASE10 §6.4).
    private var enablement: [String: Enablement] = [:]
    /// The recent applications the open system menu was built from: its
    /// `system.recent.N` means entry N of this (P15.2c).
    private var recentShown: [String] = []
    /// The held `subscribe` connection to `service`, folded into the run loop.
    private var changesFd: Int32 = -1
    /// The titles moved; say where, once they have been laid out.
    private var titlesDirty = true
    private let display: Display

    /// The system menu — the bar's own, whoever is frontmost (P10.8). The items
    /// something on this desktop can do are real; the rest are drawn disabled
    /// with the reason (`systemEnablement`), not removed and not pretending.
    public static let systemMenu = Menu("System", [
        .command(Command("system.about", "About This Computer",
                         summary: "Describe this machine.")),
        .separator,
        .command(Command("system.preferences", "System Preferences…",
                         summary: "Open System Preferences.")),
        .command(Command("system.dock", "Dock", summary: "Change the Dock.")),
        .command(Command("system.location", "Location", summary: "Change network location.")),
        .separator,
        .command(Command("system.recent", "Recent Items", summary: "Reopen something recent.")),
        .separator,
        .command(Command("system.force-quit", "Force Quit…",
                         key: .cmd(.escape, .option),
                         summary: "End an application that has stopped responding.")),
        .separator,
        .command(Command("system.sleep", "Sleep", summary: "Put the computer to sleep.")),
        .command(Command("system.restart", "Restart…", summary: "Restart the computer.")),
        .command(Command("system.shut-down", "Shut Down…", summary: "Turn the computer off.")),
        .separator,
        // Lock Screen (PHASE16 P16.2c), with the key later Macs gave it.
        // Fast user switching (PHASE16 P16.6b): this session locks and stays
        // running; the login window comes forward for someone else.
        .command(Command("system.login-window", "Login Window…",
                         summary: "Let someone else log in; your session stays, locked.")),
        .command(Command("system.lock", "Lock Screen", key: .cmd("q", .control),
                         summary: "Lock the screen; your password opens it.")),
        // No "…": there is no confirmation sheet yet, so this is Jaguar's
        // Option variant — Log Out now — and says so by its title.
        .command(Command("system.log-out", "Log Out", key: .cmd("q", .shift),
                         summary: "End this session.")),
    ])

    /// The bar for an application: the system menu, then the application's own
    /// menus, the first of which is its bold application menu.
    public static func menus(for app: MenuBarModel) -> [MenuBarMenu] {
        [MenuBarMenu(systemMenu, isSystem: true)]
            + app.menus.enumerated().map { MenuBarMenu($1, bold: $0 == 0) }
    }

    /// Whether the bar may offer `command`. **Until P10.4 the bar cannot ask the
    /// application**, so this answers from the definition alone: a Finder verb
    /// the Finder implements is offered; a system verb is not yet (P10.8). It
    /// is the one place the bar knows the Finder by name, and P10.4 deletes it.
    static func staticEnablement(_ command: Command) -> Enablement {
        if let v = FinderVerb(rawValue: command.verb) {
            return v.isImplemented ? .enabled : .disabled("the Finder cannot do this yet")
        }
        return .disabled("not available yet")
    }

    public init?(display: Display) {
        self.display = display
        let config = (try? Pool.load("panel")) ?? Config()
        showClock = config.bool("panel", "show_clock") ?? true
        let height = Int32(config.uint64("panel", "menubar_height") ?? 22)
        // Until the compositor says who is frontmost, the Finder's own
        // definition (P10.1) — which is also all a bar under a compositor with
        // no view of focus will ever have.
        menus = MenuBar.menus(for: finderMenuBar())

        guard let ls = LayerSurface(
            display: display, layer: .top, namespace: "abyss.menubar",
            width: 0, height: height, anchor: [.top, .left, .right],
            // ON_DEMAND, not NONE: the compositor hands the bar keyboard focus
            // when it's clicked (and takes it back when something else is
            // focused), which is exactly the Mac rule — click a title, then
            // drive the menus with the arrow keys. See HANDOFF §2.27.
            exclusiveZone: height, keyboard: .onDemand, delegate: self)
        else { return nil }
        layer = ls
        clock = MenuBar.currentClock()
        // The status items read the machine through Vents (sysctl / OSS). Both
        // are absent on a VM and on Linux, in which case nothing is drawn — see
        // MenuBarStatus.
        status = MenuBarStatus.read()
        MenuBar.log("status \(MenuBar.describe(status))")

        if let f = MenuBarFocus(display: display) {
            f.onFocus = { [weak self] f in
                switch f.kind {
                case .none:
                    MenuBar.log("frontmost: " + (f.appID.isEmpty ? "nothing"
                                                 : "\(f.appID) (no menus)"))
                default:
                    MenuBar.log("frontmost: \(f.appID) at \(f.address) [\(f.kind)]")
                }
                if !f.jail.isEmpty { MenuBar.log("frontmost is confined in \(f.jail)") }
                self?.confinedIn = f.jail
                self?.follow(f)
            }
            f.onIsland = { [weak self] i in
                guard let self, i.isMain else { return }
                let label = i.count > 1 ? i.name : nil
                MenuBar.log("island \(i.display) \(i.island) of \(i.count) (\(i.name))")
                if label != self.islandLabel { self.islandLabel = label; self.layer?.setNeedsDisplay() }
            }
            focus = f
        } else {
            MenuBar.log("not on the compositor's privileged socket: no view of focus")
        }

        // Tick the clock once a second via a timerfd in the run loop.
        let fd = aw_create_interval_timer(1000)
        if fd >= 0 {
            timerFd = fd
            display.addFileDescriptor(fd) { [weak self] in self?.clockTick() }
        }
    }

    // MARK: the frontmost application (P10.4)

    /// The confinement row (PHASE18 P18.6): first in the application's menu
    /// when its window came from a jail — a status, not a command, so the
    /// application's own menus (whatever a toolkit published) cannot hide it.
    static func confinedRow(_ cls: String) -> MenuItem {
        .command(Command(MenuBar.confinedVerb, "Confined (\(cls))",
                         summary: "This application runs in a jail of class \(cls): it sees only the files you give it."))
    }
    static let confinedVerb = "app.confined"

    /// Put the row into the bold menu, or take it out, as `confinedIn` says.
    /// Every assignment to `menus` comes through here.
    private func markConfined() {
        guard !markingConfined else { return }
        markingConfined = true
        defer { markingConfined = false }
        menus = menus.map { m in
            guard m.bold else { return m }
            var items = m.menu.items
            if case .command(let c)? = items.first, c.verb == MenuBar.confinedVerb {
                items.removeFirst()
                if case .separator? = items.first { items.removeFirst() }
            }
            if !confinedIn.isEmpty {
                items = [MenuBar.confinedRow(confinedIn)] + (items.isEmpty ? [] : [.separator]) + items
            }
            return MenuBarMenu(Menu(m.menu.title, items), bold: true)
        }
    }

    /// Show whoever the compositor says is frontmost.
    private func follow(_ f: MenuBarFocus.Focus) {
        closeMenu()
        unsubscribe()
        enablement = [:]
        switch f.kind {
        case .abyss, .gtk:
            // Our own applications serve their menus themselves; a GTK
            // application's are served by the bridge, told which by target.
            let svc: String, tgt: String?, from: String
            switch f.kind {
            case .gtk where !f.jail.isEmpty:
                // A confined GTK application's menus are on its jail's bus,
                // served by that jail class's own menu bridge (PHASE18).
                (svc, tgt, from) = ("menus-dbus-" + f.jail, f.address, "menus-dbus-\(f.jail) (GTK, confined)")
            case .gtk:
                (svc, tgt, from) = ("menus-dbus", f.address, "menus-dbus (GTK)")
            default:
                (svc, tgt, from) = (f.address, nil, f.address)
            }
            let t0 = MenuBar.nowUs()
            do {
                let d = try MenuClient.describe(svc, target: tgt)
                service = svc
                target = tgt
                menus = MenuBar.menus(for: d.model)
                MenuBar.log("showing \(d.model.appName)'s menus from \(from) "
                            + "(\(d.model.commands.count) commands, described in "
                            + "\(MenuBar.nowUs() - t0) us)")
                // Told when they change: our own applications say so
                // themselves, the bridge for a GTK one (P10.9).
                subscribe(svc, target: tgt)
            } catch {
                // An address nobody answers — the application is going, or
                // stuck. The bar must still be a bar.
                MenuBar.log("could not describe \(from): \(error)")
                show(nameOnly: f.appID)
            }
        case .none:
            // A window with no menus we can read still has a name, and the
            // application menu is where Jaguar put it.
            show(nameOnly: f.appID)
        }
        titlesDirty = true
        layer?.setNeedsDisplay()
    }

    /// The system menu, and the frontmost application's name with nothing
    /// under it — or just the system menu when nothing is frontmost.
    private func show(nameOnly appID: String) {
        service = nil
        target = nil
        let name = appID.split(separator: ".").last.map(String.init) ?? ""
        menus = [MenuBarMenu(MenuBar.systemMenu, isSystem: true)]
            + (name.isEmpty ? [] : [MenuBarMenu(Menu(name, []), bold: true)])
    }

    private func subscribe(_ address: String, target: String?) {
        guard let fd = try? MenuClient.subscribe(address, target: target) else {
            MenuBar.log("could not subscribe to \(address)'s changes")
            return
        }
        changesFd = fd
        display.addFileDescriptor(fd) { [weak self] in self?.vocabularyChanged() }
    }

    private func unsubscribe() {
        guard changesFd >= 0 else { return }
        display.removeFileDescriptor(changesFd)
        close(changesFd)
        changesFd = -1
    }

    /// The application said its vocabulary changed — or went away, which reads
    /// the same way on this connection until the read says which.
    private func vocabularyChanged() {
        guard changesFd >= 0, let address = service else { return }
        guard (try? Current.receive(on: changesFd))?.string("method") == "changed" else {
            MenuBar.log("\(address) went away")
            unsubscribe()
            return
        }
        if let d = try? MenuClient.describe(address, target: target) {
            closeMenu()
            menus = MenuBar.menus(for: d.model)
            MenuBar.log("\(d.model.appName)'s vocabulary changed; redescribed")
            titlesDirty = true
            layer?.setNeedsDisplay()
        }
    }

    /// Whether `command` can be chosen, as the frontmost application answered
    /// when its menu opened — or, with no application to ask, from the
    /// definition alone. The system menu is the bar's own (P10.8).
    private func enabled(_ command: Command) -> Enablement {
        if command.verb.hasPrefix("system.") { return systemEnablement(command.verb) }
        if command.verb == MenuBar.confinedVerb { return .disabled("a status: this application runs in a jail") }
        // The island menu's rows are the bar's own, not the application's.
        if IslandMenu.action(command.verb) != nil { return .enabled }
        if service == nil { return MenuBar.staticEnablement(command) }
        return enablement[command.verb] ?? .disabled("the application did not say")
    }

    // MARK: the system menu's own commands (P10.8)

    /// The frontmost application, if it is one Force Quit can mean — not the
    /// desktop, which is the Finder only by courtesy.
    private var forceQuitTarget: String? {
        guard let f = focus?.current, !f.appID.isEmpty, !f.appID.hasPrefix("abyss.") else { return nil }
        return f.appID
    }

    private func systemEnablement(_ verb: String) -> Enablement {
        switch verb {
        case "system.about", "system.preferences", "system.log-out", "system.lock", "system.sleep",
             "system.login-window":
            return .enabled
        case "system.force-quit":
            guard focus != nil else { return .disabled("the bar cannot see which application is frontmost") }
            return forceQuitTarget == nil ? .disabled("no application is frontmost") : .enabled
        case "system.restart", "system.shut-down":
            return .enabled
        case "system.recent.clear":
            return recentShown.isEmpty ? .disabled("nothing has been opened yet") : .enabled
        case _ where verb.hasPrefix("system.recent."):
            return .enabled
        default:
            return .disabled("not available yet")
        }
    }

    /// Carry out one of the bar's own commands.
    private func performSystem(_ verb: String) -> CommandResult {
        switch verb {
        case "system.about":
            // About This Mac opened Apple System Profiler; About This
            // Computer opens ours — fastfetch's report, in a window. On the
            // ordinary display, as every application the bar opens (P10.8).
            guard let display = MenuBar.appDisplay else {
                return .refused("the bar does not know the ordinary display to launch on")
            }
            let exe = getenv("ABYSS_APP_BINARY").map { String(cString: $0) }
                ?? Launcher.selfExecutable() ?? "AquaDemo"
            return Launcher.launchDetached([exe], extraEnv: ["AQUA_SCENE": "systemprofiler", "WAYLAND_DISPLAY": display])
                ? .ok("System Profiler") : .refused("could not start System Profiler")
        case "system.preferences":
            // **Never launch on our own connection's socket.** The bar is on
            // the compositor's privileged socket, and a child that inherited
            // WAYLAND_DISPLAY would be privileged too — able to watch focus and
            // force-quit anything. Found by P10.8's own test. An application
            // goes on the ordinary display, which anchor tells us; not knowing
            // it is a refusal, never a fallback to ours.
            guard let display = MenuBar.appDisplay else {
                return .refused("the bar does not know the ordinary display to launch on")
            }
            let exe = getenv("ABYSS_APP_BINARY").map { String(cString: $0) }
                ?? Launcher.selfExecutable() ?? "AquaDemo"
            return Launcher.launchDetached([exe], extraEnv: ["AQUA_SCENE": "sysprefs",
                                                             "WAYLAND_DISPLAY": display])
                ? .ok(nil) : .refused("could not start System Preferences")
        case "system.force-quit":
            guard let app = forceQuitTarget else { return .refused("no application is frontmost") }
            guard focus?.forceQuit(appID: app) == true else {
                return .refused("the compositor cannot be asked to force quit")
            }
            return .ok(app)
        case "system.recent.clear":
            RecentItems.save([])
            return .ok(nil)
        case _ where verb.hasPrefix("system.recent."):
            // The same rule as System Preferences: the ordinary display, never ours.
            guard let i = Int(verb.dropFirst("system.recent.".count)), recentShown.indices.contains(i) else {
                return .refused("no such recent item")
            }
            let bundle = recentShown[i]
            guard let exe = Launcher.bundleExecutable(bundle) else {
                return .refused("\(bundle) is not there any more")
            }
            guard let display = MenuBar.appDisplay else {
                return .refused("the bar does not know the ordinary display to launch on")
            }
            guard Launcher.launchDetached([exe], extraEnv: ["WAYLAND_DISPLAY": display]) else {
                return .refused("could not start \(exe)")
            }
            RecentItems.record(bundle)
            return .ok(bundle)
        case "system.login-window":
            var m = Msg(); m.set("method", "switch-user")
            do {
                let s = try Current.connect(path: LoginClient.socket)
                defer { close(s) }
                try Current.send(m, on: s)
                let r = try Current.receive(on: s)
                return r.bool("ok") == true ? .ok("the login window") : .refused(r.string("error") ?? "not switched")
            } catch {
                return .refused("nobody to ask for the login window: \(error)")
            }
        case "system.restart", "system.shut-down":
            // "…": it asks first (P16.4b) — the power dialog, on the ordinary
            // display like any application the bar opens (P10.8), never ours.
            guard let display = MenuBar.appDisplay else {
                return .refused("the bar does not know the ordinary display to launch on")
            }
            let exe = getenv("ABYSS_APP_BINARY").map { String(cString: $0) }
                ?? Launcher.selfExecutable() ?? "AquaDemo"
            let ask = verb == "system.restart" ? "restart" : "shut-down"
            return Launcher.launchDetached([exe], extraEnv: ["AQUA_SCENE": "powerdialog", "ABYSS_POWER_ASK": ask,
                                                             "WAYLAND_DISPLAY": display])
                ? .ok("asking") : .refused("could not open the dialog")
        case "system.sleep":
            // The root daemon sleeps the machine (P16.4a) — once every session
            // on it, this one included, has said it is locked. So the answer
            // comes after the lock screen is up, and is either "going to
            // sleep" or why not.
            do {
                let r = try PowerClient.request(.sleep)
                guard r.bool("ok") == true else { return .refused(r.string("error") ?? "the machine did not sleep") }
                return .ok("going to sleep")
            } catch {
                return .refused("nobody to ask the machine to sleep: \(error)")
            }
        case "system.lock":
            // anchor runs the lock screen — on the privileged display, and
            // again if it dies while locked — so the bar asks it to, rather
            // than starting one itself.
            var m = Msg(); m.set("method", "lock")
            guard let reply = try? Current.call("anchor", m) else {
                return .refused("no session supervisor answered")
            }
            guard reply.bool("ok") == true else { return .refused(reply.string("error") ?? "anchor said no") }
            return .ok(reply.bool("already") == true ? "already locked" : nil)
        case "system.log-out":
            var m = Msg(); m.set("method", "quit")
            guard (try? Current.call("anchor", m))?.bool("ok") == true else {
                return .refused("no session supervisor answered")
            }
            return .ok(nil)
        default:
            return .refused("not available yet")
        }
    }

    /// The display applications go on — anchor's, not the bar's privileged one.
    private static var appDisplay: String? {
        guard let d = getenv("ABYSS_APP_WAYLAND_DISPLAY").map({ String(cString: $0) }), !d.isEmpty else { return nil }
        return d
    }

    /// The system menu with Recent Items filled in from `recent.ini`, read now:
    /// the Finder and the Dock write it (P15.2c).
    private func systemMenuNow() -> Menu {
        recentShown = RecentItems.load()
        let sys = MenuBar.systemMenu
        return Menu(sys.title, sys.items.map { item in
            if case .command(let c) = item, c.verb == "system.recent" {
                return .submenu(RecentItems.submenu(recentShown))
            }
            return item
        })
    }

    /// Run a command the person chose, and say what came of it.
    private func choose(_ command: Command, in menuName: String) {
        let what = "\(menuName) > \(command.title) (\(command.verb))"
        if let a = IslandMenu.action(command.verb) {
            let main = focus?.mainIsland?.display ?? ""
            let ok: Bool
            switch a {
            case .switchTo(let n): ok = focus?.switchIsland(display: main, island: n) ?? false
            case .window(let id):  ok = focus?.activateWindow(id: id) ?? false
            case .shoal(let verb, let arg): ok = focus?.shoalCommand(verb, arg) ?? false
            }
            MenuBar.log("chose \(what) → " + (ok ? "ok" : "refused: no compositor to ask"))
            return
        }
        if command.verb.hasPrefix("system.") {
            switch performSystem(command.verb) {
            case .ok(let v):      MenuBar.log("chose \(what) → ok" + (v.map { " \($0)" } ?? ""))
            case .refused(let w): MenuBar.log("chose \(what) → refused: \(w)")
            }
            return
        }
        guard let address = service else {
            MenuBar.log("chose \(what)")
            return
        }
        do {
            switch try MenuClient.activate(address, verb: command.verb, target: target) {
            case .ok(let v):       MenuBar.log("chose \(what) → ok" + (v.map { " \($0)" } ?? ""))
            case .refused(let w):  MenuBar.log("chose \(what) → refused: \(w)")
            }
        } catch {
            MenuBar.log("chose \(what) → \(address) did not answer: \(error)")
        }
    }

    /// Where every title is, in output coordinates — so a test can click one
    /// without a coordinate in the script (§2.46). Logged when the titles
    /// change, which is rarely.
    private func logTitles() {
        guard !layoutCache.titleRects.isEmpty else { return }
        let parts = zip(menus, layoutCache.titleRects).map { m, r in
            "\(m.isSystem ? "System" : m.title)@\(Int(r.x + r.w / 2)),\(Int(r.h / 2))"
        }
        MenuBar.log("titles " + parts.joined(separator: " "))
    }

    private static func nowUs() -> Int64 {
        var ts = timespec()
        clock_gettime(CLOCK_MONOTONIC, &ts)
        return Int64(ts.tv_sec) * 1_000_000 + Int64(ts.tv_nsec) / 1000
    }

    private static func currentClock() -> String {
        var t = time(nil)
        var tmv = tm()
        localtime_r(&t, &tmv)
        return formatMenuClock(hour24: Int(tmv.tm_hour), minute: Int(tmv.tm_min),
                               wday: Int(tmv.tm_wday))
    }

    private func clockTick() {
        var expirations: UInt64 = 0
        _ = withUnsafeMutablePointer(to: &expirations) {
            read(timerFd, $0, MemoryLayout<UInt64>.size)
        }
        let now = MenuBar.currentClock()
        var dirty = false
        if now != clock { clock = now; dirty = true }
        // Poll the hardware on the same tick rather than adding a second timer:
        // volume and charge move on a human timescale, and a second-resolution
        // status item is what Jaguar had.
        let fresh = MenuBarStatus.read()
        if fresh != status {
            // Said when it changes, so a level set elsewhere is seen to arrive.
            if fresh.volume != status.volume || fresh.muted != status.muted { MenuBar.log("status \(MenuBar.describe(fresh))") }
            status = fresh; dirty = true
        }
        if dirty { layer?.setNeedsDisplay() }
    }

    static func describe(_ s: MenuBarStatus) -> String {
        (s.volume.map { "volume \($0)%" + (s.muted ? " muted" : "") } ?? "no mixer") + ", "
            + (s.batteryPercent.map { "battery \($0)%" } ?? "no battery")
    }

    private static func log(_ msg: String) {
        let line = "MenuBar: \(msg)\n"
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
        layoutCache = paintMenuBar(cr, w: w, h: h, menus: menus, clock: clock,
                                   openIndex: openIndex, showClock: showClock,
                                   status: status, island: islandLabel, islandOpen: islandOpen)
        // Where the island item is, for a test to click (§2.46).
        let item = layoutCache.islandRect.map { "'\(islandLabel ?? "")' at \(Int($0.x + $0.w / 2)),\(Int($0.y + $0.h / 2))" } ?? "none"
        if item != loggedIslandItem { loggedIslandItem = item; MenuBar.log("island item \(item)") }
        if titlesDirty { titlesDirty = false; logTitles() }
        // Where the speaker is, whenever that changes — for a test to click
        // (§2.46); "none" when there is nothing to set.
        if loggedVolumeRect == nil || loggedVolumeRect! != layoutCache.volumeRect {   // first frame too
            loggedVolumeRect = .some(layoutCache.volumeRect)
            MenuBar.log("volume item " + (layoutCache.volumeRect.map { "at \(Int($0.x + $0.w / 2)),\(Int($0.y + $0.h / 2))" } ?? "none"))
        }
        cairo_surface_flush(cs)
        cairo_destroy(cr)
        cairo_surface_destroy(cs)
    }

    public func pointerMoved(x: Double, y: Double) { pointerX = x }

    public func pointerButton(_ button: UInt32, pressed: Bool) {
        guard button == kBtnLeft, pressed else { return }
        if let r = layoutCache.volumeRect, pointerX >= r.x, pointerX < r.x + r.w {
            closeMenu()
            if volumeSlider == nil { openVolumeSlider(r) } else { closeVolumeSlider() }
            return
        }
        if let r = layoutCache.islandRect, pointerX >= r.x, pointerX < r.x + r.w {
            let wasOpen = islandOpen
            closeMenu()
            if !wasOpen { openIslandMenu(r) }
            return
        }
        if let i = titleAt(pointerX) {
            if openIndex == i { closeMenu() } else { openMenu(i) }
        } else {
            closeMenu()
        }
    }

    private func titleAt(_ x: Double) -> Int? {
        for (i, r) in layoutCache.titleRects.enumerated()
        where x >= r.x && x < r.x + r.w && !menus[i].menu.items.isEmpty {
            return i
        }
        return nil
    }

    // MARK: keyboard

    /// Keys while a dropdown is open. Left/Right walk the *titles* (closing one
    /// menu and opening its neighbour, as on Mac); everything else belongs to
    /// the open menu — Up/Down move the highlight, Return chooses, Escape
    /// closes. With no menu open the bar holds no keyboard focus at all, so
    /// nothing arrives here.
    public func keyEvent(_ event: KeyEvent) {
        guard event.pressed, let open = openIndex else { return }
        switch event.keysym {
        // ← and → walk the titles only from the top menu: inside a submenu
        // they go in and out of it (P10.8), and → on a submenu row opens it.
        case KeySym.left where menu?.keyMenu === menu:
            openMenu(neighbourTitle(from: open, step: -1))
        case KeySym.right where menu?.keyMenu === menu && menu?.highlightOpensSubmenu != true:
            openMenu(neighbourTitle(from: open, step: 1))
        default:
            menu?.keyDown(event.keysym)
        }
    }

    /// The next title in `step`'s direction that actually has a menu, wrapping.
    private func neighbourTitle(from i: Int, step: Int) -> Int {
        let n = menus.count
        var j = i
        for _ in 0..<n {
            j = (j + step + n) % n
            if !menus[j].menu.items.isEmpty { return j }
        }
        return i
    }

    private func openMenu(_ i: Int) {
        closeMenu()
        let m = menus[i]
        let name = m.isSystem ? "System" : m.title
        // **Pulled, as it opens** (PHASE10 §6.4): what can run is asked of the
        // application now, not pushed to the bar every time it changes.
        if let address = service, !m.isSystem {
            let t0 = MenuBar.nowUs()
            if let v = try? MenuClient.validate(address, target: target) {
                enablement = v
                MenuBar.log("validated \(v.count) commands in \(MenuBar.nowUs() - t0) us")
            } else {
                enablement = [:]
                MenuBar.log("\(address) did not answer validate")
            }
        }
        // Force Quit names what it would quit — the frontmost application,
        // which Jaguar's dialog would have preselected.
        let shown = m.isSystem
            ? systemMenuNow().retitled(["system.force-quit":
                forceQuitTarget.map { "Force Quit \($0.split(separator: ".").last.map(String.init) ?? $0)" }
                    ?? "Force Quit"])
            : m.menu
        let r = layoutCache.titleRects[i]
        let am = makeMenu(shown, name: name, at: (Int(r.x), Int(r.h)))
        let rows = am.items
        am.onDismiss = { [weak self] in self?.menuDismissed() }

        let popupW = Int32(max(150, am.preferredWidth))
        let popupH = Int32(am.preferredHeight.rounded(.up))
        guard let pop = layer?.openPopup(
            anchorX: Int32(r.x), anchorY: 0, anchorW: Int32(r.w),
            anchorH: Int32(r.h), width: popupW, height: popupH, delegate: am)
        else { return }
        am.popup = pop
        menu = am
        popup = pop
        openIndex = i
        MenuBar.log("opened \(name)")
        // Every row, where it will be on screen if the compositor places the
        // popup where it was asked to — under its title, flush left.
        MenuBar.logRows(rows, x: Int(r.x), y: Int(r.h))
        layer?.setNeedsDisplay()
    }

    /// One level of an open menu, and — through `submenuFor` — every level
    /// under it (P10.8). `at` is where its popup is asked to go on the output,
    /// for the rows a test reads; a submenu's is its parent's right edge, level
    /// with its row.
    private func makeMenu(_ menu: Menu, name: String, at origin: (x: Int, y: Int)) -> AquaMenu {
        let rows = aquaMenuItems(menu, enablement: enabled)
        let am = AquaMenu(items: rows)
        am.onChoose = { [weak self] idx in
            guard idx < menu.items.count, case .command(let c) = menu.items[idx] else { return }
            self?.closeMenu()
            self?.choose(c, in: name)
        }
        let width = Int(max(150, am.preferredWidth))
        am.submenuFor = { [weak self] idx in
            guard let self, idx < menu.items.count, case .submenu(let sub) = menu.items[idx] else { return nil }
            let geo = aquaMenuRows(rows)[idx]
            let child = self.makeMenu(sub, name: name + " > " + sub.title,
                                      at: (origin.x + width, origin.y + Int(geo.y) - Int(AquaMenu.padV)))
            return child
        }
        am.onSubmenuOpened = { idx, child in
            let geo = aquaMenuRows(rows)[idx]
            let cx = origin.x + width, cy = origin.y + Int(geo.y) - Int(AquaMenu.padV)
            MenuBar.log("opened submenu \(name) > \(rows[idx].title)")
            MenuBar.logRows(child.items, x: cx, y: cy)
        }
        am.onSubmenuClosed = { idx in
            guard idx >= 0, idx < rows.count else { return }
            MenuBar.log("closed submenu \(name) > \(rows[idx].title)")
        }
        return am
    }

    /// Every row of a menu whose popup's top-left is (x, y) on the output —
    /// where it will be if the compositor puts it where it was asked (§2.46).
    private static func logRows(_ rows: [AquaMenuItem], x: Int, y: Int) {
        for (row, geo) in zip(rows, aquaMenuRows(rows)) where !row.isSeparator {
            let state = row.enabled ? "enabled" : "disabled"
            let key = row.keyText.isEmpty ? "" : "\(row.keyText) "
            let sub = row.hasSubmenu ? " submenu" : ""
            MenuBar.log("item '\(row.title)' \(key)at \(x + 30),\(y + Int(geo.y + geo.h / 2)) "
                        + "\(state)\(row.verb.map { " \($0)" } ?? "")\(sub)")
        }
    }

    // MARK: the volume slider (P14.6d)

    /// What was last said about the speaker's place: nil before the first frame.
    private var loggedVolumeRect: Rect??
    private var volumeSlider: VolumeSlider?
    private var volumePopup: Popup?

    private func openVolumeSlider(_ r: Rect) {
        guard let unit = status.volumeUnit, let level = status.volume else {
            MenuBar.log("volume: nothing to set (\(MenuBar.describe(status)))")
            return
        }
        let slider = VolumeSlider(unit: unit, control: status.volumeControl, level: Int(level))
        slider.onDone = { [weak self] v in
            MenuBar.log("volume set to \(v)% (pcm\(unit) \(self?.status.volumeControl ?? "vol"))")
            self?.closeVolumeSlider()
            self?.clockTickNow()
        }
        slider.onDismiss = { [weak self] in self?.volumeSlider = nil; self?.volumePopup = nil }
        guard let pop = layer?.openPopup(anchorX: Int32(r.x), anchorY: 0, anchorW: Int32(r.w), anchorH: Int32(r.h),
                                         width: Int32(VolumeSliderMetrics.width),
                                         height: Int32(VolumeSliderMetrics.height), delegate: slider)
        else { return }
        slider.popup = pop
        volumeSlider = slider
        volumePopup = pop
        // Where the track is on the output, if the popup lands where asked —
        // under the speaker, flush left — for a test to press on (§2.46).
        let t = VolumeSliderMetrics.track
        MenuBar.log("volume slider x=\(Int(r.x + t.x + t.w / 2)) top=\(Int(r.h + t.y)) bottom=\(Int(r.h + t.y + t.h))")
    }

    private func closeVolumeSlider() {
        volumePopup?.close()
        volumePopup = nil
        volumeSlider = nil
    }

    /// Read the machine now, not at the next second: the level just set.
    private func clockTickNow() {
        let fresh = MenuBarStatus.read()
        if fresh != status {
            if fresh.volume != status.volume || fresh.muted != status.muted { MenuBar.log("status \(MenuBar.describe(fresh))") }
            status = fresh
            layer?.setNeedsDisplay()
        }
    }

    private func closeMenu() {
        menu?.closeAll()   // submenus first (P10.8); does not fire onDismiss
        popup?.close()
        popup = nil
        menu = nil
        if openIndex != nil { openIndex = nil; layer?.setNeedsDisplay() }
        if islandOpen { islandOpen = false; layer?.setNeedsDisplay() }
    }

    private func menuDismissed() {   // outside click (popup_done), or Escape
        popup = nil
        menu = nil
        if openIndex != nil || islandOpen {
            openIndex = nil
            islandOpen = false
            MenuBar.log("closed")
            layer?.setNeedsDisplay()
        }
    }

    // MARK: the island item (PHASE13 P13.4)

    /// Ask the compositor where every window is, then show the islands with
    /// theirs — pulled as it opens, like enablement (§6.4).
    private func openIslandMenu(_ r: Rect) {
        guard let focus, let main = focus.mainIsland else { return }
        let asked = focus.listIslands { [weak self] list in
            guard let self, self.menu == nil else { return }
            let m = IslandMenu.build(display: main.display, active: main.island, count: main.count,
                                     names: list.names, windows: list.windows, shoals: list.shoals)
            let am = self.makeMenu(m, name: "Islands", at: (Int(r.x), Int(r.h)))
            am.onDismiss = { [weak self] in self?.menuDismissed() }
            guard let pop = self.layer?.openPopup(
                anchorX: Int32(r.x), anchorY: 0, anchorW: Int32(r.w), anchorH: Int32(r.h),
                width: Int32(max(150, am.preferredWidth)), height: Int32(am.preferredHeight.rounded(.up)),
                delegate: am)
            else { return }
            am.popup = pop
            self.menu = am
            self.popup = pop
            self.islandOpen = true
            MenuBar.log("opened Islands")
            MenuBar.logRows(am.items, x: Int(r.x), y: Int(r.h))
            self.layer?.setNeedsDisplay()
        }
        if !asked { MenuBar.log("the compositor cannot list islands (abyss_menubar_v1 < 3)") }
    }
}
