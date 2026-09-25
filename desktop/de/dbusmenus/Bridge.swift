// GtkMenuBridge — GTK's menus, served as MenuWire (PHASE10.md P10.6).
//
// The bar speaks one protocol. When the compositor says the frontmost window is
// a GTK application's (focus kind `gtk`), the bar sends its ordinary MenuWire
// requests to **one** service, `menus-gtk`, with the GTK address as `target`;
// this answers them by asking GTK over the session bus. `abyss-dbus` is where
// PLAN.md put the translation, and it is the only process that touches D-Bus.
//
// **A process of its own** (`abyss-dbus --menus`), not a second job for the
// portal bridge: that one blocks while a file dialog is open (PHASE8 §6.7), and
// a menu bar must never wait on somebody's Open panel.
//
// Nothing is cached. Every `describe` reads the menus again and every
// `validate` asks GTK what is enabled — the same "pulled as it opens" rule as
// our own applications (§6.4). GTK's `Changed` signal is not watched yet, so a
// menu GTK rebuilds while it is on screen is stale until it is opened again.

import CurrentIPC
import DBus
import MenuModel
import MenuWire

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

public final class GtkMenuBridge {
    public static let serviceName = "menus-gtk"

    private let conn: DBusConnection
    private let server: Current.Server
    public private(set) var served = 0

    public init(connection: DBusConnection, service: String = GtkMenuBridge.serviceName) throws {
        conn = connection
        server = try Current.Server(service: service)
        try server.setNonBlocking(true)
    }

    deinit { server.shutdownAndUnlink() }

    /// Wait up to `timeoutMs` for either side and answer what arrived.
    public func step(timeoutMs: Int32) throws {
        var pfds = [pollfd(fd: server.fd, events: Int16(POLLIN), revents: 0),
                    pollfd(fd: conn.fd, events: Int16(POLLIN), revents: 0)]
        let pr = pfds.withUnsafeMutableBufferPointer { poll($0.baseAddress, 2, timeoutMs) }
        guard pr > 0 else { return }
        if pfds[1].revents != 0 { try conn.readAndDispatch(timeoutMs: 0) }
        if pfds[0].revents != 0 { serveOne() }
    }

    private func serveOne() {
        guard let c = try? server.accept() else { return }
        defer { close(c) }
        guard var request = try? Current.receive(on: c) else { return }
        defer { request.closeFDs() }
        let reply = handle(request)
        try? Current.send(reply, on: c)
        served += 1
    }

    func handle(_ request: Msg) -> Msg {
        guard let t = request.string("target"), let a = GtkMenuAddress(encoded: t) else {
            return MenuWire.errorReply("menus-gtk needs a target: the GTK address the compositor reported")
        }
        do {
            switch request.string("method") {
            case "describe":
                let model = try read(a)
                let acts = try actions(a)
                return MenuWire.describeReply(model) { GtkMenus.enablement($0, actions: acts) }
            case "validate":
                let model = try read(a)
                let acts = try actions(a)
                return MenuWire.validateReply(model) { GtkMenus.enablement($0, actions: acts) }
            case "activate":
                guard let verb = request.string("verb") else {
                    return MenuWire.errorReply("activate needs a verb")
                }
                return MenuWire.resultReply(try activate(verb, a))
            default:
                return MenuWire.errorReply("unknown method \(request.string("method") ?? "(none)")")
            }
        } catch {
            // The application went away, or answered nonsense. The bar must
            // still be a bar: a clean error, never a hang.
            return MenuWire.errorReply("\(a.applicationID): \(error)")
        }
    }

    /// The application's name, as the bar draws it bold: the last component
    /// of its application id (`org.gnome.TextEditor` → `TextEditor`).
    static func appName(_ a: GtkMenuAddress) -> String {
        a.applicationID.split(separator: ".").last.map(String.init) ?? a.applicationID
    }

    /// Every group of the menu at `path`, following links until none is missing.
    private func groups(_ a: GtkMenuAddress, path: String) throws -> [GtkMenuGroup] {
        guard !path.isEmpty else { return [] }
        var have: [GtkMenuGroup] = []
        var want: Set<UInt32> = [0]
        var asked: Set<UInt32> = []
        while !want.isEmpty, asked.count < 64 {
            asked.formUnion(want)
            let reply = try conn.call(.methodCall(
                destination: a.busName, path: path, interface: "org.gtk.Menus",
                member: "Start", body: [.array("u", want.sorted().map { .uint32($0) })]),
                timeoutMs: 1000)
            have += GtkMenus.groups(fromStartReply: reply.body)
            want = GtkMenus.missingGroups(have).subtracting(asked)
        }
        // Unsubscribe: nothing here listens for Changed, so holding the
        // subscription would only make GTK send signals to nobody.
        _ = try? conn.call(.methodCall(
            destination: a.busName, path: path, interface: "org.gtk.Menus",
            member: "End", body: [.array("u", asked.sorted().map { .uint32($0) })]),
            timeoutMs: 1000)
        return have
    }

    func read(_ a: GtkMenuAddress) throws -> MenuBarModel {
        GtkMenus.model(appName: GtkMenuBridge.appName(a),
                       menubar: try groups(a, path: a.menubarPath),
                       appMenu: try groups(a, path: a.appMenuPath))
    }

    func actions(_ a: GtkMenuAddress) throws -> [String: Bool] {
        var out: [String: Bool] = [:]
        for (path, prefix) in [(a.applicationPath, "app."), (a.windowPath, "win.")] where !path.isEmpty {
            let reply = try conn.call(.methodCall(
                destination: a.busName, path: path, interface: "org.gtk.Actions",
                member: "DescribeAll"), timeoutMs: 1000)
            out.merge(GtkMenus.actions(fromDescribeAll: reply.body, prefix: prefix)) { $1 }
        }
        return out
    }

    func activate(_ verb: String, _ a: GtkMenuAddress) throws -> CommandResult {
        let acts = try actions(a)
        if case .disabled(let why) = GtkMenus.enablement(
            Command(verb, verb, summary: ""), actions: acts) {
            return .refused(why)
        }
        let (path, name): (String, String)
        if verb.hasPrefix("app.") { (path, name) = (a.applicationPath, String(verb.dropFirst(4))) }
        else if verb.hasPrefix("win.") { (path, name) = (a.windowPath, String(verb.dropFirst(4))) }
        else { return .refused("\(verb) is not an app. or win. action") }
        _ = try conn.call(.methodCall(
            destination: a.busName, path: path, interface: "org.gtk.Actions",
            member: "Activate",
            body: [.string(name), .array("v", []), .array("{sv}", [])]), timeoutMs: 1000)
        return .ok(nil)
    }
}
