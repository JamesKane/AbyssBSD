// VocabularyBridge — an agent's way to the applications it was given
// (PHASE18 P18.10).
//
// Phase 10 made every application's menus a vocabulary: verbs with titles,
// arguments and enablement, served by the application itself (MenuWire) and
// read by the menu bar and by `abyssmenu`. An agent drives an application the
// same way, through this bridge — run by the keeper outside the agent's jail,
// answering on a socket inside it — and only the applications **this
// session was given** (§6b.2): the capability rule files already follow.
//
//   - A give is one running application, by its menu service (whose name
//     carries its pid): a second copy, or the same application relaunched,
//     was not given. It is the keeper's to make, on a socket the jail cannot
//     see; the agent cannot give itself anything.
//   - Asking about anything else is refused with a reason, never forwarded.
//   - Every give, activation and refusal is a line in the session's
//     transcript, beside abyss-model's.

import CurrentIPC
import MenuModel
import MenuWire
import Model

/// The applications' side, as the bridge sees it (the real one is MenuClient).
public protocol MenuCaller {
    func describe(_ service: String) throws -> (model: MenuBarModel, enablement: [String: Enablement])
    func activate(_ service: String, verb: String, arguments: [String: String]) throws -> CommandResult
}

public struct LiveMenus: MenuCaller {
    public init() {}
    public func describe(_ service: String) throws -> (model: MenuBarModel, enablement: [String: Enablement]) {
        try MenuClient.describe(service)
    }
    public func activate(_ service: String, verb: String, arguments: [String: String]) throws -> CommandResult {
        try MenuClient.activate(service, verb: verb, arguments: arguments)
    }
}

public final class VocabularyBridge {
    /// Given applications: the name the agent uses (the application's own),
    /// and the service it was given as.
    public private(set) var given: [(name: String, service: String)] = []
    let menus: MenuCaller
    let log: (String, [(String, JSON)]) -> Void

    public init(menus: MenuCaller, log: @escaping (String, [(String, JSON)]) -> Void = { _, _ in }) {
        self.menus = menus; self.log = log
    }

    /// The keeper's: give `service` to this session. Its name is what the
    /// application calls itself.
    public func give(service: String) throws -> String {
        let d = try menus.describe(service)
        let name = d.model.appName
        given.removeAll { $0.name.lowercased() == name.lowercased() || $0.service == service }
        given.append((name, service))
        log("given", [("app", .string(name)), ("service", .string(service))])
        return name
    }

    func service(of app: String) -> String? {
        given.first { $0.name.lowercased() == app.lowercased() }?.service
    }

    /// One request from inside the jail.
    public func handle(_ req: Msg) -> Msg {
        var r = Msg()
        func refuse(_ why: String) -> Msg {
            var m = Msg(); m.set("ok", false); m.set("error", why); return m
        }
        let app = req.string("app") ?? ""
        switch req.string("method") {
        case "apps":
            r.set("ok", true)
            r.set("apps", given.map(\.name).joined(separator: "\n"))
            return r
        case "describe":
            guard let s = service(of: app) else { return notGiven(app, refuse) }
            do {
                let d = try menus.describe(s)
                r.set("ok", true)
                r.set("text", VocabularyBridge.text(d.model, d.enablement))
                return r
            } catch { return refuse("\(app) did not answer: \(error)") }
        case "activate":
            guard let s = service(of: app) else { return notGiven(app, refuse) }
            let verb = req.string("verb") ?? ""
            let args = VocabularyBridge.arguments(req.string("arguments") ?? "")
            let result: CommandResult
            do { result = try menus.activate(s, verb: verb, arguments: args) } catch {
                log("activate", [("app", .string(app)), ("verb", .string(verb)), ("failed", .string("\(error)"))])
                return refuse("\(app) did not answer: \(error)")
            }
            let argsJSON = JSON.object(args.keys.sorted().map { ($0, .string(args[$0]!)) })
            switch result {
            case .ok(let said):
                log("activate", [("app", .string(app)), ("verb", .string(verb)), ("arguments", argsJSON), ("result", .string("ok"))])
                r.set("ok", true); r.set("text", said.map { "ok: \($0)" } ?? "ok")
            case .refused(let why):
                log("activate", [("app", .string(app)), ("verb", .string(verb)), ("arguments", argsJSON),
                                 ("result", .string("refused")), ("why", .string(why))])
                r.set("ok", true); r.set("text", "refused: \(why)")
            }
            return r
        default:
            return refuse("the vocabulary bridge answers apps, describe and activate")
        }
    }

    private func notGiven(_ app: String, _ refuse: (String) -> Msg) -> Msg {
        log("refused", [("app", .string(app)), ("reason", .string("not given"))])
        return refuse("\(app.isEmpty ? "that application" : app) was not given to this session")
    }

    /// `k=v` lines, as the agent's tool sends them.
    static func arguments(_ s: String) -> [String: String] {
        var out: [String: String] = [:]
        for line in s.split(separator: "\n") {
            guard let eq = line.firstIndex(of: "=") else { continue }
            out[String(line[..<eq])] = String(line[line.index(after: eq)...])
        }
        return out
    }

    /// An application's vocabulary as a model reads it: one line a verb, its
    /// title, its arguments, whether it can run now and why not, and what it
    /// does.
    public static func text(_ model: MenuBarModel, _ enablement: [String: Enablement]) -> String {
        var lines = ["\(model.appName):"]
        for menu in model.menus {
            for c in menu.commands {
                var l = "  \(c.verb) — \"\(c.title)\" in \(menu.title)"
                if !c.arguments.isEmpty {
                    l += "; arguments: " + c.arguments.map { "\($0.name) (\($0.type.rawValue)): \($0.summary)" }.joined(separator: ", ")
                }
                switch enablement[c.verb] {
                case .disabled(let why)?: l += " [disabled: \(why)]"
                default: l += " [enabled]"
                }
                l += ". " + c.summary
                lines.append(l)
            }
        }
        return lines.joined(separator: "\n")
    }
}
