// BridgeRouter — what ADE's D-Bus bridge does with a message (BACKLOG D.1,
// PRODUCT §5.6).
//
// **A bridge, not a bus.** Two kinds of peer, and messages go between kinds,
// never within one:
//
//   - **applications** connect at `DBUS_SESSION_BUS_ADDRESS` (or a jail's);
//   - **ADE's services** — the portal, the menu bridge — connect on a private
//     socket in the session's runtime directory, and only they may own names
//     that anyone else can call.
//
// An application reaches ADE's services and nothing else: a call addressed to
// another application is refused, its broadcast signals go only to services
// that asked, and it never sees another application's traffic (no
// eavesdropping, no `BecomeMonitor`, nothing started by name). A name an
// application asks for is granted as far as it can tell, and only ADE's
// services can call it by that name — two copies of an application each think
// they are the only one, which is the price PRODUCT §5.6 states.
//
// Pure: no sockets. `BridgeEndpoint` reads and writes; this decides, and the
// tests read every decision on Linux.

import DBus

public enum PeerKind: Equatable, Sendable { case application, service }

public struct MatchRule: Equatable, Sendable {
    public var fields: [String: String]

    /// `type='signal',interface='x',arg0='y'` — values quoted with ' and the
    /// spec's `'\''` escape. Nil for a rule that does not parse.
    public init?(_ text: String) {
        var out: [String: String] = [:]
        var chars = Array(text)
        var i = 0
        func skipCommas() { while i < chars.count && (chars[i] == "," || chars[i] == " ") { i += 1 } }
        skipCommas()
        while i < chars.count {
            var key = ""
            while i < chars.count && chars[i] != "=" { key.append(chars[i]); i += 1 }
            guard i < chars.count, !key.isEmpty else { return nil }
            i += 1
            var value = ""
            while i < chars.count && chars[i] != "," {
                if chars[i] == "'" {
                    i += 1
                    while i < chars.count && chars[i] != "'" { value.append(chars[i]); i += 1 }
                    guard i < chars.count else { return nil }
                    i += 1
                } else if chars[i] == "\\" && i + 1 < chars.count && chars[i + 1] == "'" {
                    value.append("'"); i += 2
                } else { value.append(chars[i]); i += 1 }
            }
            out[key.trimmingSpaces()] = value
            skipCommas()
        }
        chars = []
        fields = out
    }

    /// `senderNames`: every name the sending connection answers to — its
    /// unique name and the well-known names it owns — because a rule may name
    /// either (`sender='org.freedesktop.portal.Desktop'`), as on any bus.
    public func matches(_ m: DBusMessage, senderNames: Set<String> = []) -> Bool {
        for (k, v) in fields {
            switch k {
            case "type":
                let t: String
                switch m.type {
                case .methodCall: t = "method_call"
                case .methodReturn: t = "method_return"
                case .error: t = "error"
                case .signal: t = "signal"
                }
                if t != v { return false }
            case "sender": if m.sender != v && !senderNames.contains(v) { return false }
            case "interface": if m.interface != v { return false }
            case "member": if m.member != v { return false }
            case "path": if m.path != v { return false }
            case "path_namespace":
                guard let p = m.path else { return false }
                if !(p == v || v == "/" || p.hasPrefix(v + "/")) { return false }
            case "destination": if m.destination != v { return false }
            case "eavesdrop": continue   // asked for, never granted
            default:
                if k.hasPrefix("arg"), let n = Int(k.dropFirst(3)), n >= 0, n < 64 {
                    guard n < m.body.count, case .string(let s) = m.body[n] else { return false }
                    if s != v { return false }
                } else if k.hasPrefix("arg") && k.hasSuffix("path") {
                    continue   // argNpath: not needed by anything ADE serves
                } else { return false }
            }
        }
        return true
    }
}

extension String {
    func trimmingSpaces() -> String {
        var s = Substring(self)
        while s.first == " " { s.removeFirst() }
        while s.last == " " { s.removeLast() }
        return String(s)
    }
}

public struct BridgeRouter {
    public static let driverName = "org.freedesktop.DBus"
    static let driverPath = "/org/freedesktop/DBus"

    public struct Peer: Equatable, Sendable {
        public var kind: PeerKind
        public var unique: String
        public var uid: UInt32
        public var pid: Int32
        public var greeted = false
        /// Names it asked for. A service's are everyone's to call; an
        /// application's are for ADE's services only.
        public var names: [String] = []
        public var rules: [MatchRule] = []
    }

    /// What to do: deliver to a connection, or close one.
    public enum Action: Equatable, Sendable {
        case deliver(Int, DBusMessage)
        case close(Int, String)
    }

    public private(set) var peers: [Int: Peer] = [:]
    private var nextUnique = 1
    private var serial: UInt32 = 1
    /// The bridge's id (`GetId`): 32 hex digits, per bridge.
    public let guid: String

    public init(guid: String) { self.guid = guid }

    // MARK: - connections

    public mutating func attach(_ id: Int, kind: PeerKind, uid: UInt32, pid: Int32) {
        peers[id] = Peer(kind: kind, unique: ":1.\(nextUnique)", uid: uid, pid: pid)
        nextUnique += 1
    }

    /// A connection went: its names go with it, and services hear about it.
    public mutating func detach(_ id: Int) -> [Action] {
        guard let p = peers.removeValue(forKey: id) else { return [] }
        var out: [Action] = []
        for n in p.names + (p.greeted ? [p.unique] : []) {
            out += ownerChanged(n, from: p.unique, to: "", kind: p.kind)
        }
        return out
    }

    /// Who owns `name`, as `asker` may know it.
    func owner(of name: String, for asker: PeerKind) -> Int? {
        if name.hasPrefix(":") { return peers.first { $0.value.unique == name && $0.value.greeted }?.key }
        // A service's name is anyone's; an application's, only a service's.
        if let s = peers.first(where: { $0.value.kind == .service && $0.value.names.contains(name) }) { return s.key }
        if asker == .service {
            // The newest copy, if an application is running twice.
            return peers.filter { $0.value.kind == .application && $0.value.names.contains(name) }.max { $0.key < $1.key }?.key
        }
        return nil
    }

    // MARK: - a message arrives

    public mutating func route(from id: Int, _ incoming: DBusMessage) -> [Action] {
        guard var me = peers[id] else { return [] }
        var m = incoming
        // The sender is who the bridge says, never who the message says.
        m.sender = me.unique
        if !me.greeted {
            guard m.type == .methodCall, m.destination == Self.driverName, m.member == "Hello" else {
                return [.close(id, "a message before Hello")]
            }
        }
        if m.destination == Self.driverName {
            return driver(id, &me, m)
        }
        switch m.type {
        case .methodCall:
            guard let dest = m.destination, let to = owner(of: dest, for: me.kind),
                  let target = peers[to] else {
                return m.flags.contains(.noReplyExpected) ? [] : [.deliver(id, error(to: m, "org.freedesktop.DBus.Error.ServiceUnknown",
                    "\(m.destination ?? "(no destination)") is not here: the bridge connects applications to the desktop, not to each other"))]
            }
            if me.kind == .application && target.kind == .application {
                return m.flags.contains(.noReplyExpected) ? [] : [.deliver(id, error(to: m, "org.freedesktop.DBus.Error.AccessDenied",
                    "an application cannot call another application through ADE's bridge (PRODUCT §5.6)"))]
            }
            return [.deliver(to, m)]
        case .methodReturn, .error:
            guard let dest = m.destination, let to = owner(of: dest, for: .service), let target = peers[to],
                  !(me.kind == .application && target.kind == .application) else { return [] }
            return [.deliver(to, m)]
        case .signal:
            if let dest = m.destination {
                guard let to = owner(of: dest, for: me.kind), let target = peers[to],
                      !(me.kind == .application && target.kind == .application) else { return [] }
                return [.deliver(to, m)]
            }
            return broadcast(m, from: me.kind, except: id)
        }
    }

    /// A broadcast signal: to every connection whose rules match — but an
    /// application's reaches services only.
    func broadcast(_ m: DBusMessage, from kind: PeerKind, except: Int? = nil) -> [Action] {
        // The sender's well-known names count for rules — but an application's
        // only as far as services may know them.
        let sender = except.flatMap { peers[$0] }
        let names = Set((sender.map { [$0.unique] + $0.names }) ?? [])
        return peers.filter { (k, p) in
            k != except && p.greeted && (kind == .service || p.kind == .service)
                && p.rules.contains { $0.matches(m, senderNames: (kind == .service || p.kind == .service) ? names : []) }
        }.keys.sorted().map { .deliver($0, m) }
    }

    // MARK: - org.freedesktop.DBus, as the bridge answers it

    mutating func driver(_ id: Int, _ me: inout Peer, _ m: DBusMessage) -> [Action] {
        guard m.type == .methodCall else { return [] }
        func ok(_ body: [DBusValue] = []) -> [Action] {
            m.flags.contains(.noReplyExpected) ? [] : [.deliver(id, reply(to: m, body))]
        }
        func fail(_ name: String, _ text: String) -> [Action] {
            m.flags.contains(.noReplyExpected) ? [] : [.deliver(id, error(to: m, name, text))]
        }
        func arg(_ i: Int) -> String? {
            guard i < m.body.count, case .string(let s) = m.body[i] else { return nil }
            return s
        }
        var out: [Action] = []
        switch (m.interface ?? Self.driverName, m.member ?? "") {
        case (Self.driverName, "Hello"):
            guard !me.greeted else { return fail("org.freedesktop.DBus.Error.Failed", "Hello twice") }
            me.greeted = true
            peers[id] = me
            out = ok([.string(me.unique)])
            out.append(.deliver(id, signal("NameAcquired", destination: me.unique, [.string(me.unique)])))
            out += ownerChanged(me.unique, from: "", to: me.unique, kind: me.kind)
            return out
        case (Self.driverName, "RequestName"):
            guard let name = arg(0), !name.hasPrefix(":"), !name.isEmpty, name != Self.driverName else {
                return fail("org.freedesktop.DBus.Error.InvalidArgs", "not a name that can be owned")
            }
            if me.names.contains(name) { return ok([.uint32(4)]) }   // already the owner
            if me.kind == .service, let other = owner(of: name, for: .service), peers[other]?.kind == .service {
                _ = other
                return ok([.uint32(3)])                               // exists: one service per name
            }
            me.names.append(name)
            peers[id] = me
            out = ok([.uint32(1)])
            out.append(.deliver(id, signal("NameAcquired", destination: me.unique, [.string(name)])))
            out += ownerChanged(name, from: "", to: me.unique, kind: me.kind)
            return out
        case (Self.driverName, "ReleaseName"):
            guard let name = arg(0) else { return fail("org.freedesktop.DBus.Error.InvalidArgs", "no name") }
            guard let i = me.names.firstIndex(of: name) else { return ok([.uint32(3)]) }   // not owner
            me.names.remove(at: i)
            peers[id] = me
            out = ok([.uint32(1)])
            out.append(.deliver(id, signal("NameLost", destination: me.unique, [.string(name)])))
            out += ownerChanged(name, from: me.unique, to: "", kind: me.kind)
            return out
        case (Self.driverName, "GetNameOwner"):
            guard let name = arg(0) else { return fail("org.freedesktop.DBus.Error.InvalidArgs", "no name") }
            if name == Self.driverName { return ok([.string(Self.driverName)]) }
            if me.names.contains(name) { return ok([.string(me.unique)]) }
            guard let o = owner(of: name, for: me.kind), let p = peers[o] else {
                return fail("org.freedesktop.DBus.Error.NameHasNoOwner", "\(name) has no owner here")
            }
            if me.kind == .application && p.kind == .application && p.unique != me.unique {
                return fail("org.freedesktop.DBus.Error.NameHasNoOwner", "\(name) has no owner here")
            }
            return ok([.string(p.unique)])
        case (Self.driverName, "NameHasOwner"):
            guard let name = arg(0) else { return fail("org.freedesktop.DBus.Error.InvalidArgs", "no name") }
            if name == Self.driverName || me.names.contains(name) || name == me.unique { return ok([.bool(true)]) }
            let o = owner(of: name, for: me.kind).flatMap { peers[$0] }
            return ok([.bool(o != nil && !(me.kind == .application && o!.kind == .application))])
        case (Self.driverName, "ListNames"):
            var names = [Self.driverName, me.unique] + me.names
            for p in peers.values.sorted(by: { $0.unique < $1.unique }) where p.unique != me.unique && p.greeted {
                if p.kind == .service { names += [p.unique] + p.names }
                else if me.kind == .service { names += [p.unique] + p.names }
            }
            return ok([.array("s", names.map { .string($0) })])
        case (Self.driverName, "ListActivatableNames"):
            return ok([.array("s", [.string(Self.driverName)])])
        case (Self.driverName, "StartServiceByName"):
            return fail("org.freedesktop.DBus.Error.ServiceUnknown", "the bridge starts nothing by name")
        case (Self.driverName, "UpdateActivationEnvironment"):
            return fail("org.freedesktop.DBus.Error.AccessDenied", "the bridge starts nothing, so has no environment")
        case (Self.driverName, "AddMatch"):
            guard let text = arg(0), let rule = MatchRule(text) else {
                return fail("org.freedesktop.DBus.Error.MatchRuleInvalid", "cannot read that rule")
            }
            me.rules.append(rule)
            peers[id] = me
            return ok()
        case (Self.driverName, "RemoveMatch"):
            guard let text = arg(0), let rule = MatchRule(text), let i = me.rules.firstIndex(of: rule) else {
                return fail("org.freedesktop.DBus.Error.MatchRuleNotFound", "no such rule")
            }
            me.rules.remove(at: i)
            peers[id] = me
            return ok()
        case (Self.driverName, "GetId"):
            return ok([.string(guid)])
        case (Self.driverName, "GetConnectionUnixUser"), (Self.driverName, "GetConnectionUnixProcessID"),
             (Self.driverName, "GetConnectionCredentials"):
            // About yourself, or — for a service — about anyone.
            guard let name = arg(0), let o = owner(of: name, for: me.kind) ?? (me.names.contains(name) || name == me.unique ? id : nil),
                  let p = peers[o], o == id || me.kind == .service else {
                return fail("org.freedesktop.DBus.Error.NameHasNoOwner", "\(arg(0) ?? "?") has no owner you may ask about")
            }
            switch m.member {
            case "GetConnectionUnixUser": return ok([.uint32(p.uid)])
            case "GetConnectionUnixProcessID": return ok([.uint32(UInt32(bitPattern: p.pid))])
            default:
                return ok([.array("{sv}", [.dictEntry(.string("UnixUserID"), .variant(.uint32(p.uid))),
                                           .dictEntry(.string("ProcessID"), .variant(.uint32(UInt32(bitPattern: p.pid))))])])
            }
        case ("org.freedesktop.DBus.Monitoring", "BecomeMonitor"):
            return fail("org.freedesktop.DBus.Error.AccessDenied", "nobody watches anybody through ADE's bridge (PRODUCT §5.6)")
        case ("org.freedesktop.DBus.Peer", "Ping"):
            return ok()
        case ("org.freedesktop.DBus.Peer", "GetMachineId"):
            return ok([.string(guid)])
        case ("org.freedesktop.DBus.Introspectable", "Introspect"):
            return ok([.string(Self.introspection)])
        case ("org.freedesktop.DBus.Properties", "Get"), ("org.freedesktop.DBus.Properties", "GetAll"):
            if m.member == "GetAll" { return ok([.array("{sv}", [])]) }
            return fail("org.freedesktop.DBus.Error.UnknownProperty", "the bridge publishes no properties")
        default:
            return fail("org.freedesktop.DBus.Error.UnknownMethod",
                        "the bridge does not answer \(m.interface ?? "?").\(m.member ?? "?")")
        }
    }

    /// NameOwnerChanged: a service's names are news to everyone who asked; an
    /// application's, to ADE's services only.
    mutating func ownerChanged(_ name: String, from old: String, to new: String, kind: PeerKind) -> [Action] {
        let s = signal("NameOwnerChanged", destination: nil, [.string(name), .string(old), .string(new)])
        return peers.filter { (_, p) in
            p.greeted && (kind == .service || p.kind == .service) && p.rules.contains { $0.matches(s) }
        }.keys.sorted().map { .deliver($0, s) }
    }

    // MARK: - the driver's own messages

    mutating func nextSerial() -> UInt32 { defer { serial &+= 1 }; return serial }

    mutating func reply(to call: DBusMessage, _ body: [DBusValue]) -> DBusMessage {
        var r = DBusMessage.methodReturn(to: call, body: body)
        r.sender = Self.driverName
        r.serial = nextSerial()
        return r
    }

    mutating func error(to call: DBusMessage, _ name: String, _ text: String) -> DBusMessage {
        var e = DBusMessage.error(to: call, name: name, message: text)
        e.sender = Self.driverName
        e.serial = nextSerial()
        return e
    }

    mutating func signal(_ member: String, destination: String?, _ body: [DBusValue]) -> DBusMessage {
        var s = DBusMessage.signal(path: Self.driverPath, interface: Self.driverName, member: member, body: body)
        s.sender = Self.driverName
        s.destination = destination
        s.serial = nextSerial()
        return s
    }

    static let introspection = """
    <!DOCTYPE node PUBLIC "-//freedesktop//DTD D-BUS Object Introspection 1.0//EN"
     "http://www.freedesktop.org/standards/dbus/1.0/introspect.dtd">
    <node>
      <interface name="org.freedesktop.DBus">
        <method name="Hello"><arg direction="out" type="s"/></method>
        <method name="RequestName"><arg direction="in" type="s"/><arg direction="in" type="u"/><arg direction="out" type="u"/></method>
        <method name="ReleaseName"><arg direction="in" type="s"/><arg direction="out" type="u"/></method>
        <method name="GetNameOwner"><arg direction="in" type="s"/><arg direction="out" type="s"/></method>
        <method name="NameHasOwner"><arg direction="in" type="s"/><arg direction="out" type="b"/></method>
        <method name="ListNames"><arg direction="out" type="as"/></method>
        <method name="AddMatch"><arg direction="in" type="s"/></method>
        <method name="RemoveMatch"><arg direction="in" type="s"/></method>
        <method name="GetId"><arg direction="out" type="s"/></method>
        <signal name="NameOwnerChanged"><arg type="s"/><arg type="s"/><arg type="s"/></signal>
        <signal name="NameLost"><arg type="s"/></signal>
        <signal name="NameAcquired"><arg type="s"/></signal>
      </interface>
      <interface name="org.freedesktop.DBus.Introspectable">
        <method name="Introspect"><arg direction="out" type="s"/></method>
      </interface>
      <interface name="org.freedesktop.DBus.Peer">
        <method name="Ping"/>
        <method name="GetMachineId"><arg direction="out" type="s"/></method>
      </interface>
    </node>
    """
}
