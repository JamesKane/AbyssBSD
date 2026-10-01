// Activity Monitor — what is running, and quitting it (PHASE15 P15.7).
//
// The process table (`Vents.Processes`: `kern.proc.proc` on FreeBSD, /proc on
// Linux) every two seconds, %CPU measured between samples (`ProcessTable`),
// sorted by any column, filtered to My Processes or All, and narrowed by a
// name typed into the filter field. Quit Process asks first, as Jaguar's did —
// Quit (SIGTERM), Force Quit (SIGKILL), Cancel — and then:
//
// - **one's own process** is signalled from here, after checking the pid is
//   still the process that was chosen (its start time and name: a pid freed
//   and reused in the meantime is somebody else);
// - **another user's** goes to the privileged helper as a `signal` plan
//   (P14.3's: administrators only, the same identity check made again as
//   root, a kernel process refused) — this program never gains privilege.
//
// What a test reads (ABYSS_ACTIVITY_DUMP=1): the rows shown and where each is
// drawn, the toolbar's and the sheet's buttons, and what was quit.

import Surface
import CCairo
import AquaDraw
import MenuModel
import MenuWire
import CurrentIPC
import CWayland
import Vents
import Settings
import SettingsWire

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

// MARK: - The vocabulary

public enum ActivityVerb {
    public static let about = "app.about", quit = "app.quit", close = "window.close", minimize = "window.minimize"
    public static let quitProcess = "process.quit", mine = "view.mine", all = "view.all", refresh = "view.refresh"
}

public func activityMenuBar() -> MenuBarModel {
    func c(_ verb: String, _ title: String, _ key: KeyEquivalent? = nil, _ summary: String) -> MenuItem {
        .command(Command(verb, title, key: key, summary: summary))
    }
    return MenuBarModel(appName: "Activity Monitor", menus: [
        Menu("Activity Monitor", [
            c(ActivityVerb.about, "About Activity Monitor", nil, "Show Activity Monitor's version."),
            .separator,
            c(ActivityVerb.quit, "Quit Activity Monitor", .cmd("q"), "Close Activity Monitor."),
        ]),
        Menu("File", [c(ActivityVerb.close, "Close", .cmd("w"), "Close the window.")]),
        Menu("View", [
            c(ActivityVerb.mine, "My Processes", .cmd("1"), "Show only your processes."),
            c(ActivityVerb.all, "All Processes", .cmd("2"), "Show every process."),
            .separator,
            c(ActivityVerb.quitProcess, "Quit Process…", .cmd("q", .option), "Quit the selected process."),
            c(ActivityVerb.refresh, "Update Now", .cmd("r"), "Read the process table again."),
        ]),
        Menu("Window", [c(ActivityVerb.minimize, "Minimize", .cmd("m"), "Put the window in the Dock.")]),
    ])
}

// MARK: - Layout and painting

/// Columns: their titles, widths, and whether numbers sit right.
public let activityColumns: [(column: ProcessTable.Column, title: String, width: Double, right: Bool)] = [
    (.pid, "PID", 60, true), (.name, "Process Name", 190, false), (.user, "User", 90, false),
    (.cpu, "% CPU", 64, true), (.threads, "Threads", 62, true), (.memory, "Real Memory", 96, true),
]

public struct ActivityLayout: Equatable, Sendable {
    public let quitButton: Rect, mine: Rect, all: Rect, filter: Rect
    public let header: Rect, table: Rect, footer: Rect
    public let rowHeight: Double
    public init(w: Double, h: Double) {
        let top = Theme.titleBarHeight
        quitButton = Rect(12, top + 12, 110, 26)
        mine = Rect(136, top + 12, 110, 26)
        all = Rect(250, top + 12, 110, 26)
        filter = Rect(max(372, w - 200), top + 14, 180, 22)
        header = Rect(0, top + 50, w, 20)
        footer = Rect(0, h - 28 - windowResizeBand, w, 28)
        table = Rect(0, header.y + header.h, w, max(0, footer.y - header.y - header.h))
        rowHeight = 18
    }
}

public struct ActivityView: Sendable {
    public var rows: [ProcessTable.Row] = []
    public var sortBy: ProcessTable.Column = .cpu
    public var ascending = false
    public var mineOnly = true
    public var filter = ""
    public var selected: Processes.Identity?
    public var scroll = 0
    public var memoryTotal: UInt64 = 0, memoryAvailable: UInt64 = 0
    public var cpuTotal = 0.0
    public var status = ""
    public init() {}
}

public func paintActivity(_ cr: OpaquePointer, w: Double, h: Double, view: ActivityView,
                          userName: (UInt32) -> String = Processes.userName) -> ActivityLayout {
    paintWindowChrome(cr, w: w, h: h, title: "Activity Monitor — \(view.mineOnly ? "My" : "All") Processes")
    let l = ActivityLayout(w: w, h: h)
    Draw.setColor(cr, Theme.contentBackground)
    cairo_rectangle(cr, 0, Theme.titleBarHeight, w, h - Theme.titleBarHeight); cairo_fill(cr)
    Draw.gelButton(cr, l.quitButton, label: "Quit Process", blue: false, pressed: false)
    Draw.gelButton(cr, l.mine, label: "My Processes", blue: view.mineOnly, pressed: false)
    Draw.gelButton(cr, l.all, label: "All Processes", blue: !view.mineOnly, pressed: false)
    Draw.textField(cr, l.filter, text: view.filter, caret: false, placeholder: "Filter")

    // Header, with the sorted column's arrow.
    Draw.setColor(cr, Color(hex: 0xE4E4E4)); cairo_rectangle(cr, l.header.x, l.header.y, l.header.w, l.header.h); cairo_fill(cr)
    var x = 8.0
    for c in activityColumns {
        let mark = c.column == view.sortBy ? (view.ascending ? " ▲" : " ▼") : ""
        let t = c.title + mark
        let tx = c.right ? x + c.width - 8 - Draw.textWidth(cr, t, size: 11) : x
        Draw.textLeft(cr, t, x: tx, baselineY: l.header.y + 14, color: Theme.bodyText, size: 11, style: .bold)
        x += c.width
    }
    // Rows: striped, the selection blue.
    let visible = Int(l.table.h / l.rowHeight)
    let rows = view.rows
    for i in 0..<max(0, min(visible, rows.count - view.scroll)) {
        let r = rows[i + view.scroll]
        let y = l.table.y + Double(i) * l.rowHeight
        let isSel = view.selected == r.info.identity
        Draw.setColor(cr, isSel ? Color(hex: 0x3875D7) : (i % 2 == 0 ? Color(hex: 0xFFFFFF) : Color(hex: 0xEDF3FE)))
        cairo_rectangle(cr, 0, y, w, l.rowHeight); cairo_fill(cr)
        let fg = isSel ? Color(1, 1, 1) : (r.info.system ? Theme.bodyText.with(a: 0.55) : Theme.bodyText)
        let cells = [String(r.info.pid), r.info.name, userName(r.info.uid), ProcessTable.formatPercent(r.cpuPercent),
                     String(r.info.threads), ProcessTable.formatBytes(r.info.residentBytes)]
        var cx = 8.0
        for (c, s) in zip(activityColumns, cells) {
            let tx = c.right ? cx + c.width - 8 - Draw.textWidth(cr, s, size: 11) : cx
            cairo_save(cr); cairo_rectangle(cr, cx, y, c.width - 4, l.rowHeight); cairo_clip(cr)
            Draw.textLeft(cr, s, x: tx, baselineY: y + 13, color: fg, size: 11)
            cairo_restore(cr)
            cx += c.width
        }
    }
    // The machine, along the bottom.
    Draw.setColor(cr, Color(hex: 0xE4E4E4)); cairo_rectangle(cr, l.footer.x, l.footer.y, l.footer.w, l.footer.h); cairo_fill(cr)
    let used = view.memoryTotal > view.memoryAvailable ? view.memoryTotal - view.memoryAvailable : 0
    let foot = "\(rows.count) processes    CPU: \(ProcessTable.formatPercent(view.cpuTotal))%    Memory: "
        + "\(ProcessTable.formatBytes(used)) used of \(ProcessTable.formatBytes(view.memoryTotal))"
        + (view.status.isEmpty ? "" : "    " + view.status)
    Draw.textLeft(cr, foot, x: 12, baselineY: l.footer.y + 18, color: Theme.bodyText, size: 11)
    return l
}

/// "Are you sure you want to quit this process?" — Jaguar's, from the title bar.
public struct QuitSheetLayout: Equatable, Sendable {
    public let panel: Rect, quit: Rect, force: Rect, cancel: Rect
    public init(w: Double) {
        let pw = min(440, w - 40), ph = 116.0
        panel = Rect((w - pw) / 2, Theme.titleBarHeight, pw, ph)
        let by = panel.y + ph - 40
        quit = Rect(panel.x + pw - 92, by, 78, 26)
        force = Rect(quit.x - 104, by, 96, 26)
        cancel = Rect(panel.x + 16, by, 78, 26)
    }
}

func paintQuitSheet(_ cr: OpaquePointer, w: Double, name: String) -> QuitSheetLayout {
    let l = QuitSheetLayout(w: w)
    Draw.setColor(cr, Color(0, 0, 0, 0.18)); cairo_rectangle(cr, l.panel.x + 2, l.panel.y, l.panel.w, l.panel.h + 3); cairo_fill(cr)
    Draw.setColor(cr, Color(hex: 0xECECEC)); cairo_rectangle(cr, l.panel.x, l.panel.y, l.panel.w, l.panel.h); cairo_fill(cr)
    Draw.textLeft(cr, "Are you sure you want to quit \"\(name)\"?", x: l.panel.x + 18, baselineY: l.panel.y + 30,
                  color: Theme.bodyText, size: Theme.fontSize, style: .bold)
    Draw.textLeft(cr, "Force Quit ends it at once; anything it has not saved is lost.",
                  x: l.panel.x + 18, baselineY: l.panel.y + 50, color: Theme.bodyText, size: Theme.fontSize - 1)
    Draw.gelButton(cr, l.cancel, label: "Cancel", blue: false, pressed: false)
    Draw.gelButton(cr, l.force, label: "Force Quit", blue: false, pressed: false)
    Draw.gelButton(cr, l.quit, label: "Quit", blue: true, pressed: false)
    return l
}

// MARK: - The application

public final class ActivityMonitorApp: WindowDelegate, MenuProvider {
    private let display: Display
    private var window: Window?
    private var view = ActivityView()
    private var table = ProcessTable()
    private var last: Processes.Sample?
    private var timer: Int32 = -1
    private var menuService: MenuService?
    private var pointerX = 0.0, pointerY = 0.0
    private var asking: ProcessTable.Row?
    private var helperSock: Int32?
    private let me = UInt32(getuid())
    private let dump = getenv("ABYSS_ACTIVITY_DUMP") != nil
    private var lastDump = ""
    private var logged = false
    public var onQuit: () -> Void = { exit(0) }

    public static let menuBar = activityMenuBar()

    public init?(display: Display) {
        self.display = display
        let scale: Int32, auto: Bool
        if let s = getenv("AQUA_SCALE"), let v = Int32(String(cString: s)), v > 0 { (scale, auto) = (v, false) }
        else { (scale, auto) = (1, true) }
        guard let win = Window(display: display, title: "Activity Monitor", appID: "org.abyssbsd.activitymonitor",
                               width: 620, height: 460, scale: scale, autoScale: auto, delegate: self) else { return nil }
        window = win
        display.window = win
        let name = MenuWire.serviceName(app: "ActivityMonitor", pid: getpid())
        if let service = try? MenuService(name: name, provider: self) {
            display.addFileDescriptor(service.fd) { [weak service] in service?.serviceReadable() }
            menuService = service
            _ = win.publishMenus(at: name)
        }
        refresh()
        timer = aw_create_interval_timer(2000)
        if timer >= 0 {
            display.addFileDescriptor(timer) { [weak self] in
                guard let self else { return }
                var n: UInt64 = 0
                _ = withUnsafeMutablePointer(to: &n) { read(self.timer, $0, MemoryLayout<UInt64>.size) }
                self.refresh()
            }
        }
    }

    static func log(_ s: String) { ("Activity Monitor: " + s + "\n").withCString { _ = write(2, $0, strlen($0)) } }

    // MARK: the table

    private func refresh() {
        guard let now = Processes.sample() else { view.status = "The process table could not be read."; return }
        table = ProcessTable(now: now, before: last)
        last = now
        view.memoryTotal = now.memoryTotal; view.memoryAvailable = now.memoryAvailable
        let cpus = max(1, Int(sysconf(Int32(_SC_NPROCESSORS_ONLN))))
        view.cpuTotal = table.rows.reduce(0) { $0 + $1.cpuPercent } / Double(cpus)
        rebuild()
    }

    /// Filter, sort, and keep the selection on the same process.
    private func rebuild() {
        var rows = table.view(filter: view.mineOnly ? .mine(me) : .all, sortBy: view.sortBy, ascending: view.ascending)
        let f = view.filter.lowercased()
        if !f.isEmpty { rows = rows.filter { $0.info.name.lowercased().contains(f) } }
        view.rows = rows
        if let s = view.selected, !rows.contains(where: { $0.info.identity == s }) { view.selected = nil }
        let layout = ActivityLayout(w: Double(window?.size.width ?? 620), h: Double(window?.size.height ?? 460))
        let visible = Int(layout.table.h / layout.rowHeight)
        view.scroll = min(view.scroll, max(0, rows.count - visible))
        window?.setNeedsDisplay()
        if dump { dumpRows(layout, visible) }
    }

    private func dumpRows(_ l: ActivityLayout, _ visible: Int) {
        var parts: [String] = []
        for i in 0..<max(0, min(visible, view.rows.count - view.scroll)) {
            let r = view.rows[i + view.scroll]
            parts.append("\(r.info.pid)@\(Int(l.table.y + Double(i) * l.rowHeight + l.rowHeight / 2))")
        }
        let line = "rows \(view.rows.count): " + parts.joined(separator: " ")
        guard line != lastDump else { return }
        lastDump = line
        Self.log(line)
    }

    private func rowAt(_ y: Double) -> ProcessTable.Row? {
        let l = ActivityLayout(w: Double(window?.size.width ?? 620), h: Double(window?.size.height ?? 460))
        guard y >= l.table.y, y < l.table.y + l.table.h else { return nil }
        let i = Int((y - l.table.y) / l.rowHeight) + view.scroll
        return i < view.rows.count ? view.rows[i] : nil
    }

    private var selectedRow: ProcessTable.Row? { view.rows.first { $0.info.identity == view.selected } }

    // MARK: quitting

    private func askToQuit() -> CommandResult {
        guard let r = selectedRow else { return .refused("no process is selected") }
        guard !r.info.system else { return .refused("\(r.info.name) is part of the kernel, and is not quit") }
        asking = r
        Self.log("asked to quit \(r.info.name) (pid \(r.info.pid))")
        window?.setNeedsDisplay()
        return .ok("")
    }

    private func answer(force: Bool?) {
        guard let r = asking else { return }
        asking = nil
        window?.setNeedsDisplay()
        guard let force else { Self.log("quit cancelled"); return }
        let what = force ? "force quit" : "quit"
        if r.info.uid == me {
            // Still the process that was chosen? A pid freed and reused since
            // would be somebody else's program.
            guard let now = Processes.sample()?.processes.first(where: { $0.pid == r.info.pid }),
                  now.identity == r.info.identity, now.name == r.info.name else {
                view.status = "\(r.info.name) has already quit."
                Self.log("\(what) \(r.info.name): it has already quit")
                return
            }
            if kill(r.info.pid, force ? SIGKILL : SIGTERM) == 0 {
                Self.log("\(what) \(r.info.name) (pid \(r.info.pid)): sent \(force ? "SIGKILL" : "SIGTERM")")
                view.status = "Sent \(force ? "Force Quit" : "Quit") to \(r.info.name)."
            } else {
                let why = String(cString: strerror(errno))
                Self.log("\(what) \(r.info.name): \(why)")
                view.status = "Could not quit \(r.info.name): \(why)."
            }
            refresh()
            return
        }
        // Another user's: the helper decides, as root, with the same checks.
        let plan = SettingsPlan.signal(SignalPlan(pid: r.info.pid, force: force, started: r.info.started, name: r.info.name))
        var request = Msg(); request.set("method", "apply")
        SettingsWire.encode(plan, into: &request)
        guard let sock = SettingsClient.begin(request) else {
            view.status = "The settings helper is not running, so another user's process cannot be quit."
            Self.log("\(what) \(r.info.name): no settings helper"); return
        }
        helperSock = sock
        Self.log("\(what) \(r.info.name) (pid \(r.info.pid), uid \(r.info.uid)): asked the helper")
        display.addFileDescriptor(sock) { [weak self] in
            guard let self else { return }
            guard let e = SettingsClient.next(on: sock) else {
                self.display.removeFileDescriptor(sock); close(sock); self.helperSock = nil; return
            }
            if case .finished(let ok, let err) = e {
                Self.log("helper: \(ok ? "done" : "refused: \(err)")")
                self.view.status = ok ? "Quit \(r.info.name)." : "Not quit: \(err)"
                self.display.removeFileDescriptor(sock); close(sock); self.helperSock = nil
                self.refresh()
            }
        }
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
        let l = paintActivity(cr, w: w, h: h, view: view)
        var sheet: QuitSheetLayout?
        if let r = asking { sheet = paintQuitSheet(cr, w: w, name: r.info.name) }
        cairo_surface_flush(cs); cairo_destroy(cr); cairo_surface_destroy(cs)
        if dump {
            func c(_ r: Rect) -> String { "\(Int(r.x + r.w / 2)),\(Int(r.y + r.h / 2))" }
            if !logged {
                logged = true
                Self.log("toolbar quit=\(c(l.quitButton)) mine=\(c(l.mine)) all=\(c(l.all)) filter=\(c(l.filter)) header=\(Int(l.header.y + l.header.h / 2))")
            }
            if let s = sheet { Self.log("sheet quit=\(c(s.quit)) force=\(c(s.force)) cancel=\(c(s.cancel))") }
        }
    }

    public func pointerMoved(x: Double, y: Double) { pointerX = x; pointerY = y }

    public func pointerButton(_ button: UInt32, pressed: Bool) {
        guard pressed, let w = window else { return }
        let size = w.size, W = Double(size.width), H = Double(size.height)
        switch windowChromeHit(x: pointerX, y: pointerY, w: W, h: H) {
        case .close: onQuit(); return
        case .minimize: _ = w.minimize(); return
        case .zoom: w.setMaximized(!w.isMaximized); return
        case .depth: _ = w.lower(); return
        case .title: w.beginMove(); return
        case .resize(let e): w.beginResize(e); return
        case .pill, .content: break
        }
        guard button == 0x110 else { return }
        if asking != nil {
            let s = QuitSheetLayout(w: W)
            if s.quit.contains(pointerX, pointerY) { answer(force: false) }
            else if s.force.contains(pointerX, pointerY) { answer(force: true) }
            else if s.cancel.contains(pointerX, pointerY) { answer(force: nil) }
            return
        }
        let l = ActivityLayout(w: W, h: H)
        if l.quitButton.contains(pointerX, pointerY) {
            if case .refused(let why) = askToQuit() { view.status = why; window?.setNeedsDisplay() }
            return
        }
        if l.mine.contains(pointerX, pointerY) { view.mineOnly = true; rebuild(); return }
        if l.all.contains(pointerX, pointerY) { view.mineOnly = false; rebuild(); return }
        if l.header.contains(pointerX, pointerY) {
            var x = 8.0
            for c in activityColumns {
                if pointerX >= x && pointerX < x + c.width {
                    if view.sortBy == c.column { view.ascending.toggle() }
                    else { view.sortBy = c.column; view.ascending = c.column == .name || c.column == .user || c.column == .pid }
                    rebuild()
                    return
                }
                x += c.width
            }
            return
        }
        if let r = rowAt(pointerY) {
            view.selected = r.info.identity
            if dump { Self.log("selected \(r.info.name) (pid \(r.info.pid))") }
            window?.setNeedsDisplay()
        }
    }

    public func pointerAxis(_ axis: UInt32, value: Double) {
        guard axis == 0 else { return }
        view.scroll = max(0, view.scroll + Int((value / 10 * 3).rounded()))
        rebuild()
    }

    public func keyEvent(_ event: KeyEvent) {
        guard event.pressed else { return }
        if asking != nil {
            if event.keysym == KeySym.enter { answer(force: false) }
            else if event.keysym == KeySym.escape { answer(force: nil) }
            return
        }
        if event.modifiers.contains(.command) {
            if let press = keyEquivalent(event), let verb = Self.menuBar.verb(for: press),
               case .refused(let why) = perform(verb) { Self.log("\(verb) refused: \(why)") }
            return
        }
        switch event.keysym {
        case KeySym.up, KeySym.down:
            let i = view.rows.firstIndex { $0.info.identity == view.selected } ?? -1
            let j = min(max(0, i + (event.keysym == KeySym.up ? -1 : 1)), view.rows.count - 1)
            if j >= 0 { view.selected = view.rows[j].info.identity }
        case KeySym.backspace:
            if !view.filter.isEmpty { view.filter.removeLast(); rebuild() }
        case KeySym.escape:
            view.filter = ""; rebuild()
        default:
            // Typing narrows the table by name, as the toolbar's filter field.
            guard !event.text.isEmpty, event.text.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7F }) else { return }
            view.filter += event.text
            rebuild()
        }
        window?.setNeedsDisplay()
    }

    public func windowShouldClose(_ window: Window) { onQuit() }

    // MARK: MenuProvider

    public var menuModel: MenuBarModel { Self.menuBar }

    private func perform(_ verb: String) -> CommandResult {
        switch verb {
        case ActivityVerb.quit, ActivityVerb.close: onQuit(); return .ok("")
        case ActivityVerb.minimize: _ = window?.minimize(); return .ok("")
        case ActivityVerb.mine: view.mineOnly = true; rebuild(); return .ok("")
        case ActivityVerb.all: view.mineOnly = false; rebuild(); return .ok("")
        case ActivityVerb.refresh: refresh(); return .ok("")
        case ActivityVerb.quitProcess: return askToQuit()
        default: return .refused("Activity Monitor has no verb \(verb)")
        }
    }

    public func menuValidate(_ command: Command) -> Enablement {
        switch command.verb {
        case ActivityVerb.about: return .disabled("Activity Monitor has no About box yet")
        case ActivityVerb.quitProcess:
            guard let r = selectedRow else { return .disabled("no process is selected") }
            return r.info.system ? .disabled("a kernel process is not quit") : .enabled
        default: return .enabled
        }
    }

    public func menuPerform(_ command: Command, arguments: [String: String]) -> CommandResult {
        if case .disabled(let why) = menuValidate(command) { return .refused(why) }
        return perform(command.verb)
    }
}
