// Agent — the chat window (PHASE18 P18.8b).
//
// Ours, and **outside** the jail: the agent runs confined (P18.8a), and this
// window is how the person talks to it. It asks the session's keeper for an
// agent session in a class (`agent` unless $ABYSS_AGENT_CLASS says), then
// talks to the socket the keeper hands back. It shows what the agent did, not
// only what it said: each tool call is a line of the conversation. The status
// line says where the agent runs and why it stopped, in the words of whatever
// stopped it (abyss-model's budget, the step limit).
//
// Nothing here waits: the keeper's answer (a local model may take a while to
// load) and every reply arrive on a socket the display's poll loop watches.

import Surface
import CCairo
import CWayland
import AquaDraw
import CurrentIPC
import MenuModel
import MenuWire

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

// MARK: - The vocabulary

public enum AgentVerb {
    public static let about = "app.about", quit = "app.quit"
    public static let ask = "agent.ask", question = "agent.question", clear = "agent.clear"
    public static let giveApp = "agent.give-app", give = "agent.give"
    public static let takeApp = "agent.take-app", take = "agent.take"
    public static let allow = "agent.allow", stop = "agent.stop"
    public static let minimize = "window.minimize"
}

public func agentMenuBar() -> MenuBarModel {
    func c(_ verb: String, _ title: String, _ key: KeyEquivalent? = nil, _ summary: String,
           _ args: [Argument] = []) -> MenuItem {
        .command(Command(verb, title, key: key, arguments: args, summary: summary))
    }
    return MenuBarModel(appName: "Agent", menus: [
        Menu("Agent", [
            c(AgentVerb.about, "About Agent", nil, "Show Agent's version."),
            .separator,
            c(AgentVerb.quit, "Quit Agent", .cmd("q"), "End the agent session and close."),
        ]),
        Menu("Conversation", [
            c(AgentVerb.ask, "Ask", nil, "Ask the agent what is in the field."),
            // A script asks as a person does: into the field, then Ask. Its
            // own verb, as Finder's Go to Folder… is: a declared argument is
            // required (MenuService.check).
            c(AgentVerb.question, "Ask Question…", nil, "Put a question in the field and ask it.",
              [Argument("text", .string, "The question.")]),
            c(AgentVerb.clear, "Clear Field", .cmd("k"), "Empty the question field."),
            .separator,
            // §6b.2: the agent drives only what it is given, one running
            // application at a time — picked from a list, or named by a script.
            c(AgentVerb.giveApp, "Give Application…", nil, "Pick a running application for the agent to drive."),
            c(AgentVerb.give, "Give", nil, "Give the agent a running application, by name.",
              [Argument("app", .string, "The application, as abyssmenu names it.")]),
            c(AgentVerb.takeApp, "Take Back Application…", nil, "Pick a given application to take back."),
            c(AgentVerb.take, "Take Back", nil, "Take a given application back, by name.",
              [Argument("app", .string, "The application, as the agent was given it.")]),
            .separator,
            // Requester 4 (P18.11): the budget is spent — allow more, or stop.
            c(AgentVerb.allow, "Allow More", nil, "Let the agent use another budget's worth of tokens, and carry on."),
            c(AgentVerb.stop, "Stop", nil, "End the question the budget stopped."),
        ]),
        Menu("Window", [
            c(AgentVerb.minimize, "Minimize", .cmd("m"), "Put the window in the Dock."),
        ]),
    ])
}

// MARK: - Layout and painting

public struct AgentLayout: Equatable, Sendable {
    public let conversation: Rect, field: Rect, ask: Rect
    public let statusBaseline: Double

    public init(w: Double, h: Double) {
        let top = Theme.titleBarHeight + 10
        conversation = Rect(10, top, w - 20, max(40, h - top - 78))
        statusBaseline = h - 50
        field = Rect(10, h - 38, w - 106, 26)
        ask = Rect(w - 86, h - 38, 76, 26)
    }
}

/// Give Application…'s list, over the conversation: a heading and a row per
/// running application. Pure, for the window, the golden and the test.
public struct AgentPickerLayout: Equatable, Sendable {
    public let panel: Rect
    public let rows: [Rect]
    public static let rowHeight = 24.0
    public init(in area: Rect, count: Int) {
        let h = min(area.h - 20, 44 + Double(max(1, count)) * AgentPickerLayout.rowHeight)
        panel = Rect(area.x + 20, area.y + 10, area.w - 40, h)
        rows = (0..<count).map { Rect(area.x + 30, area.y + 46 + Double($0) * AgentPickerLayout.rowHeight, area.w - 60, AgentPickerLayout.rowHeight - 2) }
    }
    public func hit(_ x: Double, _ y: Double) -> Int? { rows.firstIndex { $0.contains(x, y) } }
}

@discardableResult
public func paintAgentPicker(_ cr: OpaquePointer, in area: Rect, names: [String], title: String? = nil) -> AgentPickerLayout {
    let l = AgentPickerLayout(in: area, count: names.count)
    Draw.setColor(cr, Theme.contentBackground)
    cairo_rectangle(cr, l.panel.x, l.panel.y, l.panel.w, l.panel.h); cairo_fill(cr)
    Draw.setColor(cr, Color(0.6, 0.6, 0.6))
    cairo_set_line_width(cr, 1)
    cairo_rectangle(cr, l.panel.x + 0.5, l.panel.y + 0.5, l.panel.w - 1, l.panel.h - 1); cairo_stroke(cr)
    Draw.textLeft(cr, names.isEmpty ? "No other application is running." : (title ?? "Give an application to the agent:"),
                  x: l.panel.x + 10, baselineY: l.panel.y + 22, color: Theme.bodyText, size: Theme.fontSize, style: .bold)
    for (i, r) in l.rows.enumerated() {
        Draw.setColor(cr, Color(1, 1, 1))
        cairo_rectangle(cr, r.x, r.y, r.w, r.h); cairo_fill(cr)
        Draw.textLeft(cr, names[i], x: r.x + 10, baselineY: r.y + 16, color: Theme.bodyText, size: Theme.fontSize)
    }
    return l
}

/// A requester over the conversation (P18.11): what it asks, why, and two
/// buttons — the one that lets the agent go on is the default.
public struct AgentRequesterLayout: Equatable, Sendable {
    public let panel: Rect, stop: Rect, allow: Rect
    public init(in area: Rect) {
        panel = Rect(area.x + 20, area.y + 10, area.w - 40, 120)
        allow = Rect(panel.x + panel.w - 112, panel.y + panel.h - 34, 100, 22)
        stop = Rect(allow.x - 92, allow.y, 80, 22)
    }
}

@discardableResult
public func paintAgentRequester(_ cr: OpaquePointer, in area: Rect, title: String, body: String) -> AgentRequesterLayout {
    let l = AgentRequesterLayout(in: area)
    Draw.setColor(cr, Theme.contentBackground)
    cairo_rectangle(cr, l.panel.x, l.panel.y, l.panel.w, l.panel.h); cairo_fill(cr)
    Draw.setColor(cr, Color(0.6, 0.6, 0.6))
    cairo_set_line_width(cr, 1)
    cairo_rectangle(cr, l.panel.x + 0.5, l.panel.y + 0.5, l.panel.w - 1, l.panel.h - 1); cairo_stroke(cr)
    Draw.textLeft(cr, title, x: l.panel.x + 12, baselineY: l.panel.y + 22, color: Theme.bodyText, size: 13, style: .bold)
    var y = l.panel.y + 42
    for line in wrapWords(cr, body, width: l.panel.w - 24, size: 11).prefix(3) {
        Draw.textLeft(cr, line, x: l.panel.x + 12, baselineY: y, color: Theme.bodyText, size: 11)
        y += 15
    }
    Draw.gelButton(cr, l.stop, label: "Stop", blue: false, pressed: false)
    Draw.gelButton(cr, l.allow, label: "Allow More", blue: true, pressed: false)
    return l
}

/// The window, from its state: pure, so the golden image is the live window.
public func paintAgentWindow(_ cr: OpaquePointer, w: Double, h: Double, conversation: TextView,
                             status: String, field: String, caret: Bool, canAsk: Bool,
                             picker: [String]? = nil, pickerTitle: String? = nil,
                             requester: (title: String, body: String)? = nil) -> AgentLayout {
    paintWindowChrome(cr, w: w, h: h, title: "Agent")
    Draw.setColor(cr, Theme.contentBackground)
    cairo_rectangle(cr, 0, Theme.titleBarHeight, w, h - Theme.titleBarHeight); cairo_fill(cr)
    let l = AgentLayout(w: w, h: h)
    conversation.frame = l.conversation
    conversation.caretOn = false
    conversation.paint(cr, focused: false)
    if let picker { paintAgentPicker(cr, in: l.conversation, names: picker, title: pickerTitle) }
    if let r = requester { paintAgentRequester(cr, in: l.conversation, title: r.title, body: r.body) }
    Draw.textLeft(cr, status, x: 12, baselineY: l.statusBaseline, color: Theme.bodyText, size: Theme.fontSize)
    Draw.textField(cr, l.field, text: field, caret: caret,
                   placeholder: canAsk ? "Ask the agent…" : "")
    Draw.gelButton(cr, l.ask, label: "Ask", blue: canAsk && !field.isEmpty, pressed: false)
    return l
}

/// A turn of the conversation, in the three pieces the window writes as they
/// happen: the question at once, each tool call as it starts, the answer.
public func agentQuestionLine(_ q: String) -> String { "You: \(q)\n" }
public func agentCallLine(_ c: String) -> String { "  › \(c)\n" }
public func agentAnswerLine(_ a: String) -> String { "Agent: \(a)\n\n" }

/// Requester 4's question: abyss-model's words, as a sentence, and the ask.
public func agentBudgetQuestion(_ why: String, budget: Int) -> String {
    let said = why.prefix(1).uppercased() + why.dropFirst()
    return "\(said). Let it use another \(budget) tokens and carry on?"
}

/// A whole turn: what the pieces add up to. Pure, for the tests.
public func agentTurn(question: String, calls: [String], answer: String) -> String {
    agentQuestionLine(question) + calls.map(agentCallLine).joined() + agentAnswerLine(answer)
}

// MARK: - The application

public final class AgentApp: WindowDelegate, MenuProvider {
    public enum Phase: Equatable { case starting, ready, asking, ended }

    private let display: Display
    private(set) var window: Window?
    public private(set) var phase = Phase.starting
    public let conversation = TextView()
    public private(set) var status = "" { didSet { window?.setNeedsDisplay() } }
    public private(set) var field = ""
    private var caretOn = true
    private var pointerX = 0.0, pointerY = 0.0
    private var agentSocket = ""
    private var pending: Int32 = -1
    private var asked = ""
    private var callsSoFar = 0
    /// The keeper's session ID (for a give), and whether the session can be
    /// given applications at all: `debug` cannot.
    private var sessionID = ""
    private var hasVocabulary = false
    public private(set) var given: [String] = []
    /// Give Application…'s list while it is open: names and their services.
    private var picking: [(name: String, service: String)]?
    /// Whether the open list is Take Back Application…'s.
    private var pickingToTake = false
    /// The session's budget: what Allow More allows again (P18.11).
    private var sessionBudget = 0
    /// The budget requester, while it is up: abyss-model's words.
    public private(set) var requester: String?
    private var loggedRequester = false
    private var menuService: MenuService?
    private var menuName = ""
    private var logged = false
    private var loggedPicker = false
    public var onQuit: () -> Void = { exit(0) }

    public static let menuBar = agentMenuBar()
    /// The keeper's service and method (JailKeeper's KeeperWire): named here
    /// rather than linked, so the window does not carry the keeper.
    static let keeperService = "jails"
    let agentClass: String

    public init?(display: Display) {
        self.display = display
        agentClass = getenv("ABYSS_AGENT_CLASS").map { String(cString: $0) } ?? "agent"
        menuName = MenuWire.serviceName(app: "Agent", pid: getpid())
        if let service = try? MenuService(name: menuName, provider: self) {
            display.addFileDescriptor(service.fd) { [weak service] in service?.serviceReadable() }
            menuService = service
        }
        guard let w = Window(display: display, title: "Agent", appID: "org.abyssbsd.agent",
                             width: 560, height: 460, delegate: self) else { return nil }
        window = w
        display.window = w
        if !menuName.isEmpty, w.publishMenus(at: menuName) { AgentApp.log("menus on \(menuName)") }
        let blink = aw_create_interval_timer(500)
        if blink >= 0 {
            display.addFileDescriptor(blink) { [weak self] in
                var n: UInt64 = 0
                _ = read(blink, &n, 8)
                guard let self, self.phase == .ready else { return }
                self.caretOn.toggle(); self.window?.setNeedsDisplay()
            }
        }
        startSession()
    }

    static func log(_ s: String) { ("Agent: " + s + "\n").withCString { _ = write(2, $0, strlen($0)) } }

    var readyStatus: String {
        if agentClass == "debug" { return "Confined in debug: one crash, read-only; no network." }
        return "Confined in \(agentClass): no network; " + (given.isEmpty ? "only what you grant it." : "given \(given.joined(separator: ", ")).")
    }

    // MARK: giving applications (P18.10b)

    /// Every other running application that publishes a vocabulary, by its
    /// own name. Each answers in two seconds or is left out (MenuClient).
    /// **Never this window itself**: asked while it is answering a menu
    /// request of its own, it would wait on itself until the timeout.
    func runningApplications() -> [(name: String, service: String)] {
        let mine = MenuWire.serviceName(app: "Agent", pid: getpid())
        return MenuClient.services().filter { $0 != mine }.compactMap { s in
            (try? MenuClient.describe(s)).map { ($0.model.appName, s) }
        }.sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    func openTakePicker() {
        pickingToTake = true
        picking = given.map { ($0, "") }
        AgentApp.log("picker (take) " + given.joined(separator: ", "))
        loggedPicker = false
        window?.setNeedsDisplay()
    }

    /// Take `app` back (P18.11): the keeper tells the session's bridge, which
    /// refuses it from now on.
    func take(_ app: String) {
        picking = nil
        pickingToTake = false
        var m = Msg(); m.set("method", "take"); m.set("session", sessionID); m.set("app", app)
        let sent = request({ try Current.connect(AgentApp.keeperService) }, m) { [weak self] r in
            guard let self else { return }
            guard let r, r.bool("ok") == true else {
                self.status = "Not taken back: \(r?.string("error") ?? "the session's jails did not answer")"
                AgentApp.log("take refused: \(self.status)")
                return
            }
            self.given.removeAll { $0.lowercased() == app.lowercased() }
            self.append("  (you took \(app) back)\n")
            if self.phase == .ready { self.status = self.readyStatus }
            AgentApp.log("took \(app) back")
        }
        if !sent { status = "Not taken back: the session's jails are not running." }
        window?.setNeedsDisplay()
    }

    func openPicker() {
        pickingToTake = false
        picking = runningApplications()
        AgentApp.log("picker " + (picking ?? []).map(\.name).joined(separator: ", "))
        loggedPicker = false
        window?.setNeedsDisplay()
    }

    /// Ask the keeper to give `app` (a name or a menu service) to this
    /// session; the answer comes through the poll loop.
    func give(_ app: String) {
        picking = nil
        var m = Msg(); m.set("method", "give"); m.set("session", sessionID); m.set("app", app)
        let sent = request({ try Current.connect(AgentApp.keeperService) }, m) { [weak self] r in
            guard let self else { return }
            guard let r, r.bool("ok") == true, let name = r.string("app") else {
                self.status = "Not given: \(r?.string("error") ?? "the session's jails did not answer")"
                AgentApp.log("give refused: \(self.status)")
                return
            }
            if !self.given.contains(name) { self.given.append(name) }
            self.append("  (you gave the agent \(name))\n")
            if self.phase == .ready { self.status = self.readyStatus }
            AgentApp.log("gave \(name)")
        }
        if !sent { status = "Not given: the session's jails are not running." }
        window?.setNeedsDisplay()
    }

    // MARK: talking to the keeper and the agent

    /// Send `m` on a new connection and hand the reply to `then` when it comes.
    private func request(_ connect: () throws -> Int32, _ m: Msg, then: @escaping (Msg?) -> Void) -> Bool {
        guard let fd = try? connect() else { return false }
        do { try Current.send(m, on: fd) } catch { close(fd); return false }
        pending = fd
        display.addFileDescriptor(fd) { [weak self] in
            guard let self else { return }
            let reply = try? Current.receive(on: fd)
            self.display.removeFileDescriptor(fd)
            close(fd)
            self.pending = -1
            then(reply)
        }
        return true
    }

    private func startSession() {
        // A session already started for it (a crash's debug session): use it,
        // and ask what it was opened to ask.
        if let given = getenv("ABYSS_AGENT_SOCKET").map({ String(cString: $0) }), !given.isEmpty {
            agentSocket = given
            phase = .ready
            status = readyStatus
            AgentApp.log("session (given) at \(given)")
            if let q = getenv("ABYSS_AGENT_ASK").map({ String(cString: $0) }), !q.isEmpty {
                field = q
                ask()
            }
            return
        }
        status = "Starting an agent in \(agentClass)…"
        var m = Msg(); m.set("method", "agent"); m.set("class", agentClass)
        let sent = request({ try Current.connect(AgentApp.keeperService) }, m) { [weak self] r in
            guard let self else { return }
            guard let r, r.bool("ok") == true, let sock = r.string("socket") else {
                self.phase = .ended
                self.status = "No agent: \(r?.string("error") ?? "the session's jails did not answer")"
                AgentApp.log("refused: \(self.status)")
                return
            }
            self.agentSocket = sock
            self.sessionID = r.string("session") ?? ""
            self.hasVocabulary = r.bool("vocabulary") ?? false
            self.sessionBudget = Int(r.uint64("budget") ?? 0)
            self.phase = .ready
            self.status = self.readyStatus
            AgentApp.log("session \(r.string("session") ?? "") at \(sock)")
        }
        if !sent {
            phase = .ended
            status = "No agent: the session's jails are not running."
            AgentApp.log("refused: \(status)")
        }
    }

    public func ask() {
        let q = field.trimmingSpaces
        guard phase == .ready, !q.isEmpty else { return }
        var m = Msg(); m.set("method", "ask"); m.set("text", q)
        asked = q
        field = ""
        append(agentQuestionLine(q))
        AgentApp.log("asked: \(q)")
        stream(m)
    }

    /// Carry on from where the budget stopped it (P18.11), once the person
    /// allowed more: the same question, not asked again.
    func resume() {
        var m = Msg(); m.set("method", "continue")
        AgentApp.log("continued")
        stream(m)
    }

    /// Send `m` to the agent, and take its events (a tool call as it starts)
    /// and then its reply through the poll loop.
    private func stream(_ m: Msg) {
        guard let fd = try? Current.connect(path: agentSocket), (try? Current.send(m, on: fd)) != nil else {
            status = "The agent is gone."; phase = .ended; return
        }
        phase = .asking
        callsSoFar = 0
        status = "Thinking…"
        pending = fd
        display.addFileDescriptor(fd) { [weak self] in
            guard let self else { return }
            let r = try? Current.receive(on: fd)
            if let r, r.string("event") == "call" {
                self.callsSoFar += 1
                let c = r.string("call") ?? ""
                self.append(agentCallLine(c))
                self.status = "Thinking… (\(self.callsSoFar) tool call\(self.callsSoFar == 1 ? "" : "s") so far)"
                AgentApp.log("call \(c)")
                return
            }
            self.display.removeFileDescriptor(fd)
            close(fd)
            self.pending = -1
            self.answered(r)
        }
    }

    // MARK: requester 4 — the budget (P18.11)

    /// Let it use another budget's worth: the keeper raises abyss-model's
    /// budget, and the agent carries on.
    func allowMore() {
        guard requester != nil else { return }
        requester = nil
        var m = Msg(); m.set("method", "raise"); m.set("session", sessionID); m.set("tokens", UInt64(max(1, sessionBudget)))
        status = "Allowing more…"
        let sent = request({ try Current.connect(AgentApp.keeperService) }, m) { [weak self] r in
            guard let self else { return }
            guard let r, r.bool("ok") == true else {
                self.phase = .ended
                self.status = "Not allowed: \(r?.string("error") ?? "the session's jails did not answer")"
                AgentApp.log("raise refused: \(self.status)")
                return
            }
            AgentApp.log("allowed \(self.sessionBudget) more (budget \(r.uint64("budget") ?? 0))")
            self.resume()
        }
        if !sent { phase = .ended; status = "Not allowed: the session's jails are not running." }
        window?.setNeedsDisplay()
    }

    func stopAsked() {
        guard let why = requester else { return }
        requester = nil
        phase = .ended
        status = "Stopped: \(why)"
        AgentApp.log("stopped by the person")
        window?.setNeedsDisplay()
    }

    private func append(_ text: String) {
        conversation.edit { $0.move(.documentEnd); $0.insert(text) }
        window?.setNeedsDisplay()
    }

    private func answered(_ r: Msg?) {
        guard let r, r.bool("ok") == true else {
            phase = .ended
            status = "The agent is gone."
            AgentApp.log("the agent did not answer")
            return
        }
        let calls = String(decoding: r.bytes("calls") ?? [], as: UTF8.self).split(separator: "\n").map(String.init)
        let text = r.string("text") ?? ""
        let stop = r.string("stop") ?? "failed"
        append(agentAnswerLine(stop == "answered" ? text : "(stopped)"))
        switch stop {
        case "answered": phase = .ready; status = readyStatus
        case "budget":
            // Requester 4 (P18.11): the person decides, in the window, where
            // they can — a session the keeper started, whose model it can raise.
            if !sessionID.isEmpty {
                requester = text
                loggedRequester = false
                phase = .asking
                status = "The agent's budget is spent."
                AgentApp.log("requester budget: \(text)")
            } else { phase = .ended; status = "Stopped: \(text)" }
        case "steps": phase = .ready; status = "Stopped: \(text)"
        default: phase = .ready; status = "Failed: \(text)"
        }
        AgentApp.log("answered: stop=\(stop) calls=\(calls.count) steps=\(r.uint64("steps") ?? 0)")
        window?.setNeedsDisplay()
    }

    func quit() {
        if !agentSocket.isEmpty, let fd = try? Current.connect(path: agentSocket) {
            var m = Msg(); m.set("method", "bye")
            try? Current.send(m, on: fd)
            _ = try? Current.receive(on: fd)
            close(fd)
            AgentApp.log("bye")
        }
        onQuit()
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
        let l = paintAgentWindow(cr, w: w, h: h, conversation: conversation, status: status, field: field,
                                 caret: phase == .ready && caretOn && picking == nil, canAsk: phase == .ready,
                                 picker: picking?.map(\.name),
                                 pickerTitle: pickingToTake ? "Take an application back:" : nil,
                                 requester: requester.map { (title: "The agent has used its budget.",
                                                             body: agentBudgetQuestion($0, budget: sessionBudget)) })
        if requester != nil, !loggedRequester {
            loggedRequester = true
            let r = AgentRequesterLayout(in: l.conversation)
            func c(_ x: Rect) -> String { "\(Int(x.x + x.w / 2)),\(Int(x.y + x.h / 2))" }
            AgentApp.log("requester stop=\(c(r.stop)) allow=\(c(r.allow))")
        }
        if let p = picking, !loggedPicker {
            loggedPicker = true
            let rows = AgentPickerLayout(in: l.conversation, count: p.count).rows
            AgentApp.log("picker rows " + zip(p, rows).map { "\($0.0.name.replacingSpaces)=\(Int($0.1.x + $0.1.w / 2)),\(Int($0.1.y + $0.1.h / 2))" }.joined(separator: " "))
        }
        cairo_surface_flush(cs); cairo_destroy(cr); cairo_surface_destroy(cs)
        if !logged {
            logged = true
            func c(_ r: Rect) -> String { "\(Int(r.x + r.w / 2)),\(Int(r.y + r.h / 2))" }
            AgentApp.log("layout field=\(c(l.field)) ask=\(c(l.ask))")
        }
    }

    public func pointerMoved(x: Double, y: Double) { pointerX = x; pointerY = y }

    public func pointerButton(_ button: UInt32, pressed: Bool) {
        guard pressed, let w = window else { return }
        let size = w.size
        switch windowChromeHit(x: pointerX, y: pointerY, w: Double(size.width), h: Double(size.height)) {
        case .close: quit(); return
        case .minimize: _ = w.minimize(); return
        case .depth: _ = w.lower(); return
        case .title: w.beginMove(); return
        case .zoom, .pill, .content, .resize: break
        }
        let layout = AgentLayout(w: Double(size.width), h: Double(size.height))
        if requester != nil {
            let r = AgentRequesterLayout(in: layout.conversation)
            if r.allow.contains(pointerX, pointerY) { allowMore() }
            else if r.stop.contains(pointerX, pointerY) { stopAsked() }
            return
        }
        if let p = picking {
            if let i = AgentPickerLayout(in: layout.conversation, count: p.count).hit(pointerX, pointerY) {
                if pickingToTake { take(p[i].name) } else { give(p[i].service) }
            }
            else { picking = nil; window?.setNeedsDisplay() }
            return
        }
        if layout.ask.contains(pointerX, pointerY) { ask() }
    }

    public func pointerAxis(_ axis: UInt32, value: Double) {
        if axis == 0 { conversation.scroll(by: value); window?.setNeedsDisplay() }
    }

    public func keyEvent(_ event: KeyEvent) {
        guard event.pressed else { return }
        if event.modifiers.contains(.command) {
            if let press = keyEquivalent(event), let verb = AgentApp.menuBar.verb(for: press) { _ = perform(verb) }
            return
        }
        if requester != nil {
            if event.keysym == KeySym.enter { allowMore() } else if event.keysym == KeySym.escape { stopAsked() }
            return
        }
        if picking != nil {
            if event.keysym == KeySym.escape { picking = nil; window?.setNeedsDisplay() }
            return
        }
        guard phase == .ready else { return }
        switch event.keysym {
        case KeySym.enter: ask()
        case KeySym.backspace: if !field.isEmpty { field.removeLast() }
        default:
            if !event.text.isEmpty, event.text.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7F }) {
                field += event.text
            }
        }
        caretOn = true
        window?.setNeedsDisplay()
    }

    public func windowShouldClose(_ window: Window) { quit() }

    // MARK: MenuProvider

    func perform(_ verb: String) -> CommandResult {
        switch verb {
        case AgentVerb.quit: quit(); return .ok("")
        case AgentVerb.ask:
            guard phase == .ready else { return .refused("there is no agent") }
            guard !field.trimmingSpaces.isEmpty else { return .refused("the field is empty") }
            ask(); return .ok("")
        case AgentVerb.clear: field = ""; window?.setNeedsDisplay(); return .ok("")
        case AgentVerb.giveApp: openPicker(); return .ok("")
        case AgentVerb.takeApp: openTakePicker(); return .ok("")
        case AgentVerb.allow: allowMore(); return .ok("")
        case AgentVerb.stop: stopAsked(); return .ok("")
        case AgentVerb.minimize: _ = window?.minimize(); return .ok("")
        default: return .refused("Agent has no verb \(verb)")
        }
    }

    public var menuModel: MenuBarModel { AgentApp.menuBar }

    public func menuValidate(_ command: Command) -> Enablement {
        switch command.verb {
        case AgentVerb.about: return .disabled("Agent has no About box yet")
        // Enabled whenever the agent can be asked; an empty field is refused
        // when run, with its reason. (Enablement is checked before the
        // arguments are seen, so Ask Question… could not depend on the field.)
        case AgentVerb.ask, AgentVerb.question:
            return phase == .ready ? .enabled
                : .disabled(phase == .asking ? "the agent is answering" : "there is no agent")
        case AgentVerb.allow, AgentVerb.stop:
            return requester != nil ? .enabled : .disabled("nothing is being asked")
        case AgentVerb.takeApp, AgentVerb.take:
            return given.isEmpty ? .disabled("nothing was given") : .enabled
        case AgentVerb.giveApp, AgentVerb.give:
            if sessionID.isEmpty { return .disabled(phase == .starting ? "there is no agent yet" : "this session cannot be given applications") }
            return hasVocabulary ? .enabled : .disabled("\(agentClass) sessions drive no applications")
        default: return .enabled
        }
    }

    public func menuPerform(_ command: Command, arguments: [String: String]) -> CommandResult {
        if case .disabled(let why) = menuValidate(command) { return .refused(why) }
        if command.verb == AgentVerb.give {
            give(arguments["app"] ?? "")
            return .ok("")
        }
        if command.verb == AgentVerb.take {
            take(arguments["app"] ?? "")
            return .ok("")
        }
        if command.verb == AgentVerb.question {
            field = arguments["text"] ?? ""
            window?.setNeedsDisplay()
            return perform(AgentVerb.ask)
        }
        return perform(command.verb)
    }
}

extension String {
    var replacingSpaces: String { String(map { $0 == " " ? "_" : $0 }) }
    var trimmingSpaces: String {
        var s = Substring(self)
        while s.first == " " { s.removeFirst() }
        while s.last == " " { s.removeLast() }
        return String(s)
    }
}
