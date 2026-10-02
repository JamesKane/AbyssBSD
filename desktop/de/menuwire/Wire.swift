// MenuWire — an application's vocabulary on the control plane (PHASE10.md P10.2).
//
// Four methods, the `CurrentIPC` idiom of every other service here (`method`
// in, `ok` + `error` out):
//
//   describe   → the whole vocabulary: menus, and per command its verb, title,
//                keys, arguments, a sentence of description and whether it can
//                run now. *What can you do.*
//   validate   → enablement only, for every command. What a menu asks as it opens.
//   activate   → run one verb with typed arguments, and get a **result** back:
//                `ok` with an optional value, or `refused` with a reason.
//   subscribe  → keep the connection; `changed` is pushed down it when the
//                vocabulary itself changes.
//
// `Msg` is flat and a menu is a tree, so a subtree travels as a packed `Msg` in
// a `.bytes` field (PHASE10 §4.4) and a list as a `Msg` whose fields are named
// "0", "1", …. One parser — `Msg.unpack` — reads every level.

import CurrentIPC
import MenuModel

public enum MenuWire {
    /// The service name an application's menus are published under:
    /// `menus.<app>.<pid>`. The pid keeps two Finders apart; the app name is
    /// what a person types to `abyssmenu`.
    public static func serviceName(app: String, pid: Int32) -> String {
        let slug = String(app.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" })
        return "menus.\(slug).\(pid)"
    }

    public static let servicePrefix = "menus."

    // MARK: lists and nesting

    static func packList(_ items: [Msg]) -> [UInt8] {
        var m = Msg()
        for (i, item) in items.enumerated() { m.set(String(i), bytes: item.pack()) }
        return m.pack()
    }

    static func unpackList(_ bytes: [UInt8]?) throws -> [Msg] {
        guard let bytes else { return [] }
        let m = try Msg.unpack(bytes)
        var out: [Msg] = []
        var i = 0
        while let b = m.bytes(String(i)) {
            out.append(try Msg.unpack(b))
            i += 1
        }
        return out
    }

    // MARK: key equivalents

    static func encode(_ k: KeyEquivalent) -> Msg {
        var m = Msg()
        m.set("mods", UInt64(k.modifiers.rawValue))
        m.set("key", keyName(k.key))
        m.set("display", k.display)   // for a reader that will not parse keys
        return m
    }

    static func decodeKey(_ m: Msg) throws -> KeyEquivalent {
        guard let name = m.string("key"), let key = key(named: name) else {
            throw CurrentError.malformed("key equivalent with no key")
        }
        return KeyEquivalent(key, .init(rawValue: UInt8(truncatingIfNeeded: m.uint64("mods") ?? 0)))
    }

    static func keyName(_ k: KeyEquivalent.Key) -> String {
        switch k {
        case .character(let c): return "char:" + String(c)
        case .backspace:        return "backspace"
        case .forwardDelete:    return "forward-delete"
        case .up:               return "up"
        case .down:             return "down"
        case .left:             return "left"
        case .right:            return "right"
        case .enter:            return "enter"
        case .escape:           return "escape"
        case .tab:              return "tab"
        }
    }

    static func key(named s: String) -> KeyEquivalent.Key? {
        if s.hasPrefix("char:") {
            let rest = s.dropFirst(5)
            return rest.count == 1 ? .character(rest.first!) : nil
        }
        switch s {
        case "backspace":      return .backspace
        case "forward-delete": return .forwardDelete
        case "up":             return .up
        case "down":           return .down
        case "left":           return .left
        case "right":          return .right
        case "enter":          return .enter
        case "escape":         return .escape
        case "tab":            return .tab
        default:               return nil
        }
    }

    // MARK: commands and menus

    static func encode(_ c: Command, enablement: Enablement?) -> Msg {
        var m = Msg()
        m.set("kind", "command")
        m.set("verb", c.verb)
        m.set("title", c.title)
        m.set("summary", c.summary)
        if c.writes { m.set("writes", true) }
        if let k = c.key { m.set("key", bytes: encode(k).pack()) }
        if !c.alternateKeys.isEmpty {
            m.set("alternates", bytes: packList(c.alternateKeys.map(encode)))
        }
        if !c.arguments.isEmpty {
            m.set("arguments", bytes: packList(c.arguments.map { a in
                var am = Msg()
                am.set("name", a.name)
                am.set("type", a.type.rawValue)
                am.set("summary", a.summary)
                return am
            }))
        }
        if let e = enablement { set(e, into: &m) }
        return m
    }

    static func set(_ e: Enablement, into m: inout Msg) {
        switch e {
        case .enabled:
            m.set("enabled", true)
        case .disabled(let why):
            m.set("enabled", false)
            m.set("reason", why)
        }
    }

    static func enablement(_ m: Msg) -> Enablement? {
        guard let on = m.bool("enabled") else { return nil }
        return on ? .enabled : .disabled(m.string("reason") ?? "")
    }

    static func decodeCommand(_ m: Msg) throws -> Command {
        guard let verb = m.string("verb"), let title = m.string("title") else {
            throw CurrentError.malformed("command with no verb or title")
        }
        let key = try m.bytes("key").map { try decodeKey(Msg.unpack($0)) }
        let alternates = try unpackList(m.bytes("alternates")).map(decodeKey)
        let arguments = try unpackList(m.bytes("arguments")).map { am -> Argument in
            guard let name = am.string("name"),
                  let type = am.string("type").flatMap(ArgumentType.init(rawValue:)) else {
                throw CurrentError.malformed("argument with no name or type")
            }
            return Argument(name, type, am.string("summary") ?? "")
        }
        return Command(verb, title, key: key, alternateKeys: alternates,
                       arguments: arguments, summary: m.string("summary") ?? "",
                       writes: m.bool("writes") ?? false)
    }

    static func encode(_ menu: Menu, enablement: (Command) -> Enablement?) -> Msg {
        var m = Msg()
        m.set("title", menu.title)
        m.set("items", bytes: packList(menu.items.map { item in
            switch item {
            case .command(let c):
                return encode(c, enablement: enablement(c))
            case .separator:
                var s = Msg(); s.set("kind", "separator"); return s
            case .submenu(let sub):
                var s = encode(sub, enablement: enablement)
                s.set("kind", "submenu")
                return s
            }
        }))
        return m
    }

    /// A menu, and the enablement that travelled with each of its commands.
    static func decodeMenu(_ m: Msg, into states: inout [String: Enablement]) throws -> Menu {
        let items = try unpackList(m.bytes("items")).map { im -> MenuItem in
            switch im.string("kind") {
            case "command":
                let c = try decodeCommand(im)
                if let e = enablement(im) { states[c.verb] = e }
                return .command(c)
            case "separator":
                return .separator
            case "submenu":
                return .submenu(try decodeMenu(im, into: &states))
            default:
                throw CurrentError.malformed("menu item of unknown kind")
            }
        }
        return Menu(m.string("title") ?? "", items)
    }

    // MARK: the four replies

    /// `describe`'s reply body: the model, with each command's enablement.
    public static func describeReply(_ model: MenuBarModel,
                                     enablement: (Command) -> Enablement) -> Msg {
        var m = Msg()
        m.set("ok", true)
        m.set("app", model.appName)
        m.set("menus", bytes: packList(model.menus.map { encode($0, enablement: enablement) }))
        return m
    }

    public static func decodeDescribe(_ m: Msg) throws
        -> (model: MenuBarModel, enablement: [String: Enablement]) {
        try checkOK(m)
        var states: [String: Enablement] = [:]
        let menus = try unpackList(m.bytes("menus")).map { try decodeMenu($0, into: &states) }
        return (MenuBarModel(appName: m.string("app") ?? "", menus: menus), states)
    }

    public static func validateReply(_ model: MenuBarModel,
                                     enablement: (Command) -> Enablement) -> Msg {
        var m = Msg()
        m.set("ok", true)
        m.set("commands", bytes: packList(model.commands.map { c in
            var cm = Msg()
            cm.set("verb", c.verb)
            set(enablement(c), into: &cm)
            return cm
        }))
        return m
    }

    public static func decodeValidate(_ m: Msg) throws -> [String: Enablement] {
        try checkOK(m)
        var out: [String: Enablement] = [:]
        for cm in try unpackList(m.bytes("commands")) {
            if let v = cm.string("verb"), let e = enablement(cm) { out[v] = e }
        }
        return out
    }

    public static func activateRequest(verb: String, arguments: [String: String]) -> Msg {
        var m = Msg()
        m.set("method", "activate")
        m.set("verb", verb)
        if !arguments.isEmpty {
            var a = Msg()
            for (k, v) in arguments.sorted(by: { $0.key < $1.key }) { a.set(k, v) }
            m.set("arguments", bytes: a.pack())
        }
        return m
    }

    /// The arguments an `activate` carried, as name → text. Every argument
    /// travels as a string and is checked against its declared type by the
    /// service (`MenuService.check`), so a script writes `path=/tmp` and never
    /// has to know how the wire spells an integer.
    public static func arguments(of request: Msg) throws -> [String: String] {
        guard let b = request.bytes("arguments") else { return [:] }
        var out: [String: String] = [:]
        for (name, value) in try Msg.unpack(b).fields {
            guard case .string(let s) = value else {
                throw CurrentError.malformed("argument \(name) is not text")
            }
            out[name] = s
        }
        return out
    }

    public static func resultReply(_ r: CommandResult) -> Msg {
        var m = Msg()
        switch r {
        case .ok(let value):
            m.set("ok", true)
            m.set("result", "ok")
            if let value { m.set("value", value) }
        case .refused(let why):
            m.set("ok", false)
            m.set("result", "refused")
            m.set("error", why)
        }
        return m
    }

    public static func decodeResult(_ m: Msg) throws -> CommandResult {
        switch m.string("result") {
        case "ok":      return .ok(m.string("value"))
        case "refused": return .refused(m.string("error") ?? "")
        default:
            // Not a result at all — the service could not run the method.
            throw MenuWireError.service(m.string("error") ?? "no result")
        }
    }

    public static func errorReply(_ why: String) -> Msg {
        var m = Msg()
        m.set("ok", false)
        m.set("error", why)
        return m
    }

    static func checkOK(_ m: Msg) throws {
        guard m.bool("ok") == true else {
            throw MenuWireError.service(m.string("error") ?? "the service said no")
        }
    }
}

public enum MenuWireError: Error, Equatable, CustomStringConvertible {
    case service(String)
    case noSuchApplication(String)
    case ambiguous(String, [String])

    public var description: String {
        switch self {
        case .service(let why): return why
        case .noSuchApplication(let name): return "no application called \(name) is publishing menus"
        case .ambiguous(let name, let all):
            return "\(name) matches \(all.count) services: \(all.joined(separator: ", "))"
        }
    }
}
