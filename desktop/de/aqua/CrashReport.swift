// CrashReport — "The application … has unexpectedly quit" (PHASE18 P18.9b).
//
// Jaguar told you when an application died, and said the rest of the system
// was fine. A confined application's crash is said the same way, with what is
// true of a jail: nothing else was affected. The keeper starts this dialog
// when a program it launched dies of a signal (`AQUA_SCENE=crashreport`,
// `ABYSS_CRASH_*`). If the crash left a core, **Ask the Agent…** asks the
// keeper for a `debug` session on that crash alone (its core and binary,
// read-only), and opens the Agent window on it with the question asked.
//
// Nothing here waits: the keeper's answer comes through the display's poll
// loop. A refusal is shown in the keeper's words, with an OK.

import Surface
import CCairo
import AquaDraw
import CurrentIPC
import MenuModel
import MenuWire

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

public enum CrashVerb {
    public static let ask = "crash.ask", close = "crash.close"
}

/// What crashed, as the keeper said it.
public struct CrashNotice: Equatable, Sendable {
    public var id: Int
    public var app: String
    public var signal: String
    public var core: Bool
    /// Whether agents are on (P18.13): off, there is no Ask the Agent.
    public var agents: Bool

    public init(id: Int, app: String, signal: String, core: Bool, agents: Bool = true) {
        self.id = id; self.app = app; self.signal = signal; self.core = core; self.agents = agents
    }

    /// From the keeper's environment (`ABYSS_CRASH_ID`, `_APP`, `_SIGNAL`, `_CORE`).
    public static func fromEnvironment() -> CrashNotice {
        func e(_ n: String) -> String? { getenv(n).map { String(cString: $0) } }
        return CrashNotice(id: Int(e("ABYSS_CRASH_ID") ?? "") ?? 0, app: e("ABYSS_CRASH_APP") ?? "An application",
                           signal: e("ABYSS_CRASH_SIGNAL") ?? "a signal", core: e("ABYSS_CRASH_CORE") == "1",
                           agents: e("ABYSS_AGENTS") == "1")
    }

    public var headline: String { "The application \(app) has unexpectedly quit." }
    public var detail: String {
        "It ran confined, so nothing else was affected. It was killed by \(signal)"
            + (!core ? ", and left nothing to read." : agents ? "; an agent can read what it left and say why." : ".")
    }
    /// Whether to offer Ask the Agent: a core to read, and agents on.
    public var canAsk: Bool { core && agents }
    /// The question the Agent window is opened with.
    public var question: String { "Why did \(app) crash?" }
}

public enum CrashChoice: String, Sendable {
    case close = "Close", ask = "Ask the Agent…", ok = "OK"
}

public struct CrashReportLayout: Equatable, Sendable {
    public var icon = Rect(0, 0, 0, 0)
    public var textX = 0.0
    public var buttons: [(CrashChoice, Rect)] = []

    public static func == (a: CrashReportLayout, b: CrashReportLayout) -> Bool {
        a.icon == b.icon && a.textX == b.textX && a.buttons.map { $0.0 } == b.buttons.map { $0.0 }
            && a.buttons.map { $0.1 } == b.buttons.map { $0.1 }
    }

    /// The buttons right-aligned, the last the default; Ask is wider.
    public init(choices: [CrashChoice], w: Double, h: Double) {
        icon = Rect(20, Theme.titleBarHeight + 16, 64, 64)
        textX = 100
        let bh = 22.0, gap = 12.0, y = h - bh - 18
        let widths = choices.map { $0 == .ask ? 128.0 : 92.0 }
        var x = w - 20 - widths.reduce(0, +) - gap * Double(max(0, choices.count - 1))
        for (c, bw) in zip(choices, widths) { buttons.append((c, Rect(x, y, bw, bh))); x += bw + gap }
    }

    public func hit(_ x: Double, _ y: Double) -> CrashChoice? { buttons.first { $0.1.contains(x, y) }?.0 }
}

@discardableResult
public func paintCrashReport(_ cr: OpaquePointer, w: Double, h: Double, notice: CrashNotice,
                             refusal: String?, choices: [CrashChoice]) -> CrashReportLayout {
    paintWindowChrome(cr, w: w, h: h, title: "")
    Draw.setColor(cr, Theme.contentBackground)
    cairo_rectangle(cr, 0, Theme.titleBarHeight, w, h - Theme.titleBarHeight); cairo_fill(cr)
    let l = CrashReportLayout(choices: choices, w: w, h: h)
    Draw.icon("dock.icon.genericApp", cr, l.icon)
    var y = Theme.titleBarHeight + 30
    for line in wrapWords(cr, notice.headline, width: w - l.textX - 20, size: 13, style: .bold) {
        Draw.textLeft(cr, line, x: l.textX, baselineY: y, color: Theme.bodyText, size: 13, style: .bold)
        y += 18
    }
    y += 4
    for line in wrapWords(cr, refusal ?? notice.detail, width: w - l.textX - 20, size: 11) {
        Draw.textLeft(cr, line, x: l.textX, baselineY: y, color: refusal == nil ? Theme.bodyText : Color(0.65, 0.05, 0.05), size: 11)
        y += 15
    }
    for (c, r) in l.buttons {
        Draw.gelButton(cr, r, label: c.rawValue, blue: c == choices.last, pressed: false)
    }
    return l
}

public final class CrashReport: WindowDelegate, MenuProvider {
    private(set) var window: Window?
    private let display: Display
    public let notice: CrashNotice
    public private(set) var choices: [CrashChoice]
    private var refusal: String?
    private var asking = false
    private var pointerX = 0.0, pointerY = 0.0
    private var logged = false
    private var menuService: MenuService?
    public var onDone: () -> Void = { exit(0) }

    static func log(_ s: String) { ("CrashReport: " + s + "\n").withCString { _ = write(2, $0, strlen($0)) } }

    public static func menuBar() -> MenuBarModel {
        MenuBarModel(appName: "Crash Reporter", menus: [
            Menu("Crash Reporter", [
                .command(Command(CrashVerb.ask, "Ask the Agent…", summary: "Start an agent on this crash, and ask it why.")),
                .separator,
                .command(Command(CrashVerb.close, "Close", key: .cmd("w"), summary: "Close this report.")),
            ]),
        ])
    }

    public init?(display: Display, notice: CrashNotice) {
        self.display = display
        self.notice = notice
        choices = notice.canAsk ? [.close, .ask] : [.ok]
        let name = MenuWire.serviceName(app: "Crash Reporter", pid: getpid())
        if let service = try? MenuService(name: name, provider: self) {
            display.addFileDescriptor(service.fd) { [weak service] in service?.serviceReadable() }
            menuService = service
        }
        guard let w = Window(display: display, title: "", appID: "org.abyssbsd.crashreport",
                             width: 480, height: 180, delegate: self) else { return nil }
        window = w
        display.window = w
        if w.publishMenus(at: name) { CrashReport.log("menus on \(name)") }
        CrashReport.log("up: crash \(notice.id), \(notice.app), \(notice.signal), core \(notice.core ? "yes" : "no")")
    }

    // MARK: Ask the Agent

    func ask() {
        guard notice.canAsk, !asking, let fd = try? Current.connect("jails") else {
            if !asking { refuse("The session's jails are not running.") }
            return
        }
        var m = Msg(); m.set("method", "debug"); m.set("crash", UInt64(notice.id))
        guard (try? Current.send(m, on: fd)) != nil else { close(fd); refuse("The session's jails did not answer."); return }
        asking = true
        CrashReport.log("asked for a debug session on crash \(notice.id)")
        display.addFileDescriptor(fd) { [weak self] in
            guard let self else { return }
            let r = try? Current.receive(on: fd)
            self.display.removeFileDescriptor(fd)
            close(fd)
            self.asking = false
            guard let r, r.bool("ok") == true, let sock = r.string("socket") else {
                self.refuse(r?.string("error") ?? "The session's jails did not answer.")
                return
            }
            CrashReport.log("debug session \(r.string("session") ?? "") at \(sock)")
            // The Agent window, on that session, with the question asked.
            let opened = Launcher.selfExecutable().map {
                Launcher.launchDetached([$0], extraEnv: ["AQUA_SCENE": "agent", "ABYSS_AGENT_SOCKET": sock,
                                                         "ABYSS_AGENT_CLASS": "debug", "ABYSS_AGENT_ASK": self.notice.question])
            } ?? false
            guard opened else { self.refuse("The Agent window could not be opened."); return }
            self.finish()
        }
    }

    private func refuse(_ why: String) {
        CrashReport.log("refused: \(why)")
        refusal = why
        choices = [.ok]
        logged = false
        window?.setNeedsDisplay()
    }

    private func finish() {
        CrashReport.log("closed")
        window?.close()
        window = nil
        onDone()
    }

    private func choose(_ c: CrashChoice) {
        switch c {
        case .ask: ask()
        case .close, .ok: finish()
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
        let l = paintCrashReport(cr, w: w, h: h, notice: notice, refusal: refusal, choices: choices)
        cairo_surface_flush(cs); cairo_destroy(cr); cairo_surface_destroy(cs)
        if !logged {
            logged = true
            let at = l.buttons.map { b in
                "\(b.0 == .ask ? "ask" : b.0.rawValue.lowercased())=\(Int(b.1.x + b.1.w / 2)),\(Int(b.1.y + b.1.h / 2))"
            }
            CrashReport.log("buttons " + at.joined(separator: " "))
        }
    }

    public func pointerMoved(x: Double, y: Double) { pointerX = x; pointerY = y }
    public func pointerAxis(_ axis: UInt32, value: Double) {}

    public func pointerButton(_ button: UInt32, pressed: Bool) {
        guard pressed, let w = window else { return }
        let size = w.size
        switch windowChromeHit(x: pointerX, y: pointerY, w: Double(size.width), h: Double(size.height)) {
        case .close: finish(); return
        case .title: w.beginMove(); return
        default: break
        }
        if let c = CrashReportLayout(choices: choices, w: Double(size.width), h: Double(size.height)).hit(pointerX, pointerY) {
            choose(c)
        }
    }

    public func keyEvent(_ e: KeyEvent) {
        guard e.pressed else { return }
        if e.keysym == KeySym.enter || e.keysym == 0xff8d, let d = choices.last { choose(d) }
        else if e.keysym == KeySym.escape { finish() }
    }

    public func windowShouldClose(_ window: Window) { finish() }

    // MARK: MenuProvider

    public var menuModel: MenuBarModel { CrashReport.menuBar() }

    public func menuValidate(_ command: Command) -> Enablement {
        switch command.verb {
        case CrashVerb.ask:
            if !notice.core { return .disabled("it left nothing to read") }
            if !notice.agents { return .disabled("agents are off") }
            if asking { return .disabled("an agent is being started") }
            return choices.contains(.ask) ? .enabled : .disabled("this report was answered")
        default: return .enabled
        }
    }

    public func menuPerform(_ command: Command, arguments: [String: String]) -> CommandResult {
        if case .disabled(let why) = menuValidate(command) { return .refused(why) }
        switch command.verb {
        case CrashVerb.ask: ask(); return .ok("")
        case CrashVerb.close: finish(); return .ok("")
        default: return .refused("Crash Reporter has no verb \(command.verb)")
        }
    }
}
