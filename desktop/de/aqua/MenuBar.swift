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
    public init(titleRects: [Rect] = [], clockRect: Rect = Rect(0, 0, 0, 0),
                volumeRect: Rect? = nil, batteryRect: Rect? = nil) {
        self.titleRects = titleRects; self.clockRect = clockRect
        self.volumeRect = volumeRect; self.batteryRect = batteryRect
    }
}

public enum MenuBarMetrics {
    public static let height: Double = 22
    public static let leftMargin: Double = 8
    public static let systemSlot: Double = 26
    public static let titlePadX: Double = 9
    public static let clockMarginRight: Double = 14
    public static let fontSize: Double = 13
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
                          status: MenuBarStatus = MenuBarStatus()) -> MenuBarLayout {
    var rects: [Rect] = []
    var x = MenuBarMetrics.leftMargin
    for m in menus {
        let width: Double
        if m.isSystem {
            width = MenuBarMetrics.systemSlot
        } else {
            let style: Text.Style = m.bold ? .bold : .regular
            width = Draw.textWidth(cr, m.title, size: MenuBarMetrics.fontSize,
                                   style: style) + 2 * MenuBarMetrics.titlePadX
        }
        rects.append(Rect(x, 0, width, h))
        x += width
    }
    var clockRect = Rect(0, 0, 0, 0)
    if showClock && !clock.isEmpty {
        let cw = Draw.textWidth(cr, clock, size: MenuBarMetrics.fontSize) + 4
        clockRect = Rect(w - cw - MenuBarMetrics.clockMarginRight, 0, cw, h)
    }
    // Status items are right-aligned against whatever the clock left free (or
    // the bar's right margin when there is no clock).
    let statusRight = clockRect.w > 0 ? clockRect.x : w - MenuBarMetrics.clockMarginRight
    let items = menuBarStatusLayout(status: status, h: h, rightEdge: statusRight)
    return MenuBarLayout(titleRects: rects, clockRect: clockRect,
                         volumeRect: items.volume, batteryRect: items.battery)
}

/// Paint the menu bar. `openIndex` (if any) is drawn highlighted in menu blue.
/// Returns the layout for hit-testing.
@discardableResult
public func paintMenuBar(_ cr: OpaquePointer, w: Double, h: Double,
                         menus: [MenuBarMenu], clock: String,
                         openIndex: Int?, showClock: Bool,
                         status: MenuBarStatus = MenuBarStatus()) -> MenuBarLayout {
    cairo_rectangle(cr, 0, 0, w, h)
    Draw.fillVerticalGradient(cr, y: 0, h: h, stops: [
        (0, Theme.menuBarTop), (1, Theme.menuBarBottom),
    ])
    Draw.pinstripe(cr, Rect(0, 0, w, h), Theme.menuBarBottom.with(a: 0.5))
    Draw.setColor(cr, Theme.menuBarBorder)
    cairo_set_line_width(cr, 1)
    cairo_move_to(cr, 0, h - 0.5); cairo_line_to(cr, w, h - 0.5); cairo_stroke(cr)

    let layout = menuBarLayout(cr, w: w, h: h, menus: menus, clock: clock,
                               showClock: showClock, status: status)
    for (i, m) in menus.enumerated() {
        let r = layout.titleRects[i]
        let open = (i == openIndex)
        if open {
            Draw.setColor(cr, Theme.menuHighlight)
            cairo_rectangle(cr, r.x, 0, r.w, h)
            cairo_fill(cr)
        }
        let color = open ? Theme.menuTextOnHighlight : Theme.menuBarText
        if m.isSystem {
            drawSystemGlyph(cr, Rect(r.x + (r.w - 14) / 2, (h - 14) / 2, 14, 14), color: color)
        } else {
            let style: Text.Style = m.bold ? .bold : .regular
            Draw.textLeft(cr, m.title, x: r.x + MenuBarMetrics.titlePadX,
                          baselineY: h - 6.5, color: color,
                          size: MenuBarMetrics.fontSize, style: style)
        }
    }
    if showClock && !clock.isEmpty {
        Draw.textLeft(cr, clock, x: layout.clockRect.x + 2, baselineY: h - 6.5,
                      color: Theme.menuBarText, size: MenuBarMetrics.fontSize)
    }
    if !status.isEmpty {
        let statusRight = layout.clockRect.w > 0
            ? layout.clockRect.x : w - MenuBarMetrics.clockMarginRight
        paintMenuBarStatus(cr, status: status, h: h, rightEdge: statusRight,
                           color: Theme.menuBarText)
    }
    return layout
}

/// An original water-drop system mark (aquatic AbyssBSD motif) — a bulb topped by
/// a point. Deliberately not Apple's apple.
private func drawSystemGlyph(_ cr: OpaquePointer, _ r: Rect, color: Color) {
    let cx = r.x + r.w / 2
    let top = r.y + r.h * 0.08
    let bulbCy = r.y + r.h * 0.62
    let rad = r.w * 0.42
    cairo_new_path(cr)
    cairo_arc(cr, cx, bulbCy, rad, 0, 2 * Double.pi)
    cairo_new_sub_path(cr)
    cairo_move_to(cr, cx, top)
    cairo_line_to(cr, cx + rad * 0.92, bulbCy)
    cairo_line_to(cr, cx - rad * 0.92, bulbCy)
    cairo_close_path(cr)
    Draw.setColor(cr, color)
    cairo_fill(cr)
}

public final class MenuBar: LayerSurfaceDelegate {
    private var layer: LayerSurface?
    private let menus: [MenuBarMenu]
    private let showClock: Bool
    private var clock = ""
    private var layoutCache = MenuBarLayout()
    private var openIndex: Int?

    private var menu: AquaMenu?
    private var popup: Popup?
    private var pointerX = 0.0
    private var timerFd: Int32 = -1
    /// The hardware bridges behind the status items. The mixer is opened once —
    /// nil on a machine with no sound card, which is how the item stays hidden.
    private var mixer: Vents.Mixer?
    private var status = MenuBarStatus()
    /// Who is frontmost and where their menus are, from the compositor
    /// (P10.3). Nil unless this bar connected through undertow's privileged
    /// socket — the only connection offered it. P10.4 draws what it says.
    private var focus: MenuBarFocus?

    /// The system menu — the bar's own, whoever is frontmost. Nothing here can
    /// run yet (P10.8 gives the items that can a verb to call), so every item
    /// is drawn disabled rather than logging a title and pretending.
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
        .command(Command("system.log-out", "Log Out…", key: .cmd("q", .shift),
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
        let config = (try? Pool.load("panel")) ?? Config()
        showClock = config.bool("panel", "show_clock") ?? true
        let height = Int32(config.uint64("panel", "menubar_height") ?? 22)
        // The Finder's own definition, not a copy of it (P10.1). Which
        // application is frontmost arrives with P10.4.
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
        mixer = Vents.Mixer()
        status = MenuBarStatus.read(mixer: mixer)
        MenuBar.log("status \(status.volume.map { "volume \($0)%" } ?? "no mixer"), "
                    + "\(status.batteryPercent.map { "battery \($0)%" } ?? "no battery")")

        if let f = MenuBarFocus(display: display) {
            f.onFocus = { f in
                switch f.kind {
                case .none:
                    MenuBar.log("frontmost: " + (f.appID.isEmpty ? "nothing"
                                                 : "\(f.appID) (no menus)"))
                default:
                    MenuBar.log("frontmost: \(f.appID) at \(f.address) [\(f.kind)]")
                }
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
        let fresh = MenuBarStatus.read(mixer: mixer)
        if fresh != status { status = fresh; dirty = true }
        if dirty { layer?.setNeedsDisplay() }
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
                                   status: status)
        cairo_surface_flush(cs)
        cairo_destroy(cr)
        cairo_surface_destroy(cs)
    }

    public func pointerMoved(x: Double, y: Double) { pointerX = x }

    public func pointerButton(_ button: UInt32, pressed: Bool) {
        guard button == kBtnLeft, pressed else { return }
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
        case KeySym.left:  openMenu(neighbourTitle(from: open, step: -1))
        case KeySym.right: openMenu(neighbourTitle(from: open, step: 1))
        default:           menu?.keyDown(event.keysym)
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
        let rows = aquaMenuItems(m.menu, enablement: MenuBar.staticEnablement)
        let am = AquaMenu(items: rows)
        am.onChoose = { [weak self] idx in
            let row = rows[idx]
            MenuBar.log("chose \(name) > \(row.title) (\(row.verb ?? "no verb"))")
            self?.closeMenu()
        }
        am.onDismiss = { [weak self] in self?.menuDismissed() }

        let r = layoutCache.titleRects[i]
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
        layer?.setNeedsDisplay()
    }

    private func closeMenu() {
        popup?.close()   // programmatic close does not fire onDismiss
        popup = nil
        menu = nil
        if openIndex != nil { openIndex = nil; layer?.setNeedsDisplay() }
    }

    private func menuDismissed() {   // outside click (popup_done), or Escape
        popup = nil
        menu = nil
        if openIndex != nil {
            openIndex = nil
            MenuBar.log("closed")
            layer?.setNeedsDisplay()
        }
    }
}
