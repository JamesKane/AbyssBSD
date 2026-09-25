// MenuClient — asking an application what it can do (PHASE10.md P10.2).
//
// The first consumer of the vocabulary is `abyssmenu`, which cannot draw a menu
// at all; the menu bar (P10.4) is the second. Both go through this.

import CurrentIPC
import MenuModel

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

public enum MenuClient {
    /// How long an application gets to answer. **A menu bar must never wait
    /// for ever on somebody else's program** — the portal half of abyss-dbus
    /// blocks behind a dialog, an application can hang — so every call is
    /// bounded, and a slow answer is an error the bar survives (P10.6).
    public static let timeoutSeconds = 2.0

    static func call(_ service: String, _ request: Msg) throws -> Msg {
        let s = try Current.connect(service)
        defer { close(s) }
        var tv = timeval(tv_sec: Int(timeoutSeconds),
                         tv_usec: Int((timeoutSeconds - Double(Int(timeoutSeconds))) * 1_000_000))
        _ = setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        try Current.send(request, on: s)
        return try Current.receive(on: s)
    }

    /// `target`: for a service that answers for more than one application —
    /// the GTK bridge — which one (PHASE10 P10.6). Our own applications ignore it.
    static func request(_ method: String, target: String?) -> Msg {
        var m = Msg(); m.set("method", method)
        if let target { m.set("target", target) }
        return m
    }

    public static func describe(_ service: String, target: String? = nil) throws
        -> (model: MenuBarModel, enablement: [String: Enablement]) {
        try MenuWire.decodeDescribe(call(service, request("describe", target: target)))
    }

    public static func validate(_ service: String, target: String? = nil) throws -> [String: Enablement] {
        try MenuWire.decodeValidate(call(service, request("validate", target: target)))
    }

    public static func activate(_ service: String, verb: String,
                                arguments: [String: String] = [:],
                                target: String? = nil) throws -> CommandResult {
        var m = MenuWire.activateRequest(verb: verb, arguments: arguments)
        if let target { m.set("target", target) }
        return try MenuWire.decodeResult(call(service, m))
    }

    /// Ask to be told when `service`'s vocabulary changes. Returns the held
    /// connection: it becomes readable with a `changed` message each time, and
    /// with EOF when the application goes. The caller owns and closes it.
    public static func subscribe(_ service: String) throws -> Int32 {
        let s = try Current.connect(service)
        do {
            // Bounded like every call; the held connection is only ever read
            // when poll says it is readable, so the timeout costs nothing later.
            var tv = timeval(tv_sec: Int(timeoutSeconds), tv_usec: 0)
            _ = setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            var m = Msg(); m.set("method", "subscribe")
            try Current.send(m, on: s)
            let reply = try Current.receive(on: s)
            guard reply.bool("ok") == true else {
                throw MenuWireError.service(reply.string("error") ?? "subscribe refused")
            }
            return s
        } catch {
            close(s)
            throw error
        }
    }

    /// Every menu service in the runtime directory that answers a connection —
    /// a socket left behind by a crash is not an application.
    public static func services() -> [String] {
        guard let dir = try? Current.runtimeDir(), let d = opendir(dir) else { return [] }
        defer { closedir(d) }
        var names: [String] = []
        while let e = readdir(d) {
            var raw = e.pointee.d_name
            let cap = MemoryLayout.size(ofValue: raw)
            let file = withUnsafePointer(to: &raw) {
                $0.withMemoryRebound(to: CChar.self, capacity: cap) { String(cString: $0) }
            }
            guard file.hasPrefix(MenuWire.servicePrefix), file.hasSuffix(".sock") else { continue }
            names.append(String(file.dropLast(5)))
        }
        return names.filter(isLive).sorted()
    }

    static func isLive(_ service: String) -> Bool {
        guard let s = try? Current.connect(service) else { return false }
        close(s)
        return true
    }

    /// A service from what a person types: its full name, or an application
    /// name (`finder`) that exactly one live service carries.
    public static func resolve(_ name: String) throws -> String {
        let live = services()
        if live.contains(name) { return name }
        let slug = MenuWire.serviceName(app: name, pid: 0).dropLast(1)   // "menus.finder."
        let matches = live.filter { $0.hasPrefix(slug) }
        switch matches.count {
        case 1:  return matches[0]
        case 0:  throw MenuWireError.noSuchApplication(name)
        default: throw MenuWireError.ambiguous(name, matches)
        }
    }
}
