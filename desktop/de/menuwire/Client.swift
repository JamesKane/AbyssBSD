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
    public static func describe(_ service: String) throws
        -> (model: MenuBarModel, enablement: [String: Enablement]) {
        var m = Msg(); m.set("method", "describe")
        return try MenuWire.decodeDescribe(Current.call(service, m))
    }

    public static func validate(_ service: String) throws -> [String: Enablement] {
        var m = Msg(); m.set("method", "validate")
        return try MenuWire.decodeValidate(Current.call(service, m))
    }

    public static func activate(_ service: String, verb: String,
                                arguments: [String: String] = [:]) throws -> CommandResult {
        try MenuWire.decodeResult(
            Current.call(service, MenuWire.activateRequest(verb: verb, arguments: arguments)))
    }

    /// Ask to be told when `service`'s vocabulary changes. Returns the held
    /// connection: it becomes readable with a `changed` message each time, and
    /// with EOF when the application goes. The caller owns and closes it.
    public static func subscribe(_ service: String) throws -> Int32 {
        let s = try Current.connect(service)
        do {
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
