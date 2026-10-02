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

/// The window, from its state: pure, so the golden image is the live window.
public func paintAgentWindow(_ cr: OpaquePointer, w: Double, h: Double, conversation: TextView,
                             status: String, field: String, caret: Bool, canAsk: Bool) -> AgentLayout {
    paintWindowChrome(cr, w: w, h: h, title: "Agent")
    Draw.setColor(cr, Theme.contentBackground)
    cairo_rectangle(cr, 0, Theme.titleBarHeight, w, h - Theme.titleBarHeight); cairo_fill(cr)
    let l = AgentLayout(w: w, h: h)
    conversation.frame = l.conversation
    conversation.caretOn = false
    conversation.paint(cr, focused: false)
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
    private var menuService: MenuService?
    private var menuName = ""
    private var logged = false
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
        agentClass == "debug" ? "Confined in debug: one crash, read-only; no network."
                              : "Confined in \(agentClass): no network; only what you grant it."
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
        guard let fd = try? Current.connect(path: agentSocket), (try? Current.send(m, on: fd)) != nil else {
            status = "The agent is gone."; phase = .ended; return
        }
        asked = q
        field = ""
        phase = .asking
        callsSoFar = 0
        status = "Thinking…"
        append(agentQuestionLine(q))
        AgentApp.log("asked: \(q)")
        // Events (a tool call as it starts) until the reply.
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
        case "budget": phase = .ended; status = "Stopped: \(text)"
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
                                 caret: phase == .ready && caretOn, canAsk: phase == .ready)
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
        if AgentLayout(w: Double(size.width), h: Double(size.height)).ask.contains(pointerX, pointerY) { ask() }
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
        default: return .enabled
        }
    }

    public func menuPerform(_ command: Command, arguments: [String: String]) -> CommandResult {
        if case .disabled(let why) = menuValidate(command) { return .refused(why) }
        if command.verb == AgentVerb.question {
            field = arguments["text"] ?? ""
            window?.setNeedsDisplay()
            return perform(AgentVerb.ask)
        }
        return perform(command.verb)
    }
}

extension String {
    var trimmingSpaces: String {
        var s = Substring(self)
        while s.first == " " { s.removeFirst() }
        while s.last == " " { s.removeLast() }
        return String(s)
    }
}
