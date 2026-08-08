// DBusPortal — the service: own the name, answer the calls, run the Finder.
//
// The shape of one file-chooser call, and the ordering is the whole point:
//
//   1. `OpenFile` arrives. We derive the Request path from the *caller's* name
//      and *its* token, and **return that path immediately** — before anything
//      slow happens.
//   2. Only once that reply has been written do we call `abyss-portal`, which
//      runs the Finder and blocks until the user decides.
//   3. Then the `Response` signal goes out on the path from step 1.
//
// Steps 2 and 3 are deliberately *not* inside the method handler. A handler's
// return value is what the connection sends, so blocking inside one would keep
// the caller waiting for its handle until the dialog had already been answered
// — and a client that only subscribes when the handle arrives would then be
// subscribing after the signal had been emitted. It would hang, with no error,
// on every call. So the slow half is queued and drained by the run loop, which
// guarantees the method return is on the wire first (PHASE8.md §6.1).

import CurrentIPC

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

public let portalBusName = "org.freedesktop.portal.Desktop"
public let portalObjectPath = "/org/freedesktop/portal/desktop"
public let fileChooserInterface = "org.freedesktop.portal.FileChooser"
public let requestInterface = "org.freedesktop.portal.Request"

/// The FileChooser version we advertise.
///
/// **1, on purpose.** Version 3 added `directory` and `SaveFiles`, neither of
/// which the Finder does; claiming 3 would invite calls we answer with an error
/// where claiming 1 gets us calls we can actually serve. Advertising a version
/// you do not implement is the interop equivalent of a test that always passes.
public let fileChooserVersion: UInt32 = 1

public final class DBusPortalService {
    private let conn: DBusConnection
    /// The `CurrentIPC` service to translate to — `abyss-portal`, normally.
    public let portalService: String
    /// Requests that have been handed out and not yet answered or closed.
    private var live: Set<String> = []
    /// Work deferred out of a method handler; see the file comment.
    private var queue: [() -> Void] = []
    public private(set) var journal: [String] = []
    /// Completed chooser interactions, for `--once` and for the tests.
    public private(set) var served = 0

    public init(connection: DBusConnection, portalService: String? = nil) {
        self.conn = connection
        if let p = portalService {
            self.portalService = p
        } else if let env = getenv("ABYSS_PORTAL_SERVICE"), env.pointee != 0 {
            self.portalService = String(cString: env)
        } else {
            self.portalService = "portal"
        }
    }

    public func log(_ msg: String) {
        journal.append(msg)
        let b = Array("abyss-dbus: \(msg)\n".utf8)
        _ = b.withUnsafeBufferPointer { write(2, $0.baseAddress, b.count) }
    }

    // MARK: - Coming up

    /// Take the name and register the interfaces. Throws if we are not the
    /// **primary** owner: a portal that shares its name with the stock
    /// `xdg-desktop-portal` would answer some calls and not others, which is a
    /// far worse failure than refusing to start.
    public func attach() throws {
        let code = try conn.requestName(portalBusName)
        guard code == 1 else {
            throw DBusError("could not own \(portalBusName): RequestName returned \(code)"
                            + " — is xdg-desktop-portal already on this bus?")
        }
        log("owning \(portalBusName), translating to the '\(portalService)' service")

        conn.handle(fileChooserInterface, "OpenFile") { [weak self] call in
            self?.chooser(.open, call)
        }
        conn.handle(fileChooserInterface, "SaveFile") { [weak self] call in
            self?.chooser(.save, call)
        }
        conn.handle(requestInterface, "Close") { [weak self] call in
            self?.closeRequest(call)
        }
        conn.handle("org.freedesktop.DBus.Properties", "Get") { [weak self] call in
            self?.property(call, all: false)
        }
        conn.handle("org.freedesktop.DBus.Properties", "GetAll") { [weak self] call in
            self?.property(call, all: true)
        }
        conn.handle("org.freedesktop.DBus.Introspectable", "Introspect") { [weak self] call in
            .methodReturn(to: call, body: [.string(self?.introspection(call.path) ?? "")])
        }
    }

    // MARK: - The run loop

    /// Read, dispatch, then drain. The order is load-bearing — see the file
    /// comment — and so is the fact that the queue is drained *outside*
    /// `readAndDispatch`, where nothing is holding a reply back.
    public func step(timeoutMs: Int32 = 200) throws {
        try conn.readAndDispatch(timeoutMs: timeoutMs)
        while !queue.isEmpty {
            let work = queue.removeFirst()
            work()
        }
    }

    // MARK: - FileChooser

    private func chooser(_ kind: ChooserKind, _ call: DBusMessage) -> DBusMessage? {
        guard call.path == portalObjectPath else {
            return .error(to: call, name: "org.freedesktop.DBus.Error.UnknownObject",
                          message: "no FileChooser at \(call.path ?? "?")")
        }
        // s parent_window, s title, a{sv} options.
        guard call.body.count >= 3, case .string(let title)? = call.body.dropFirst().first
        else {
            return .error(to: call, name: "org.freedesktop.DBus.Error.InvalidArgs",
                          message: "expected (s parent_window, s title, a{sv} options)")
        }
        let options = ChooserOptions(call.body[2])
        guard let sender = call.sender else {
            return .error(to: call, name: "org.freedesktop.DBus.Error.Failed",
                          message: "the bus attached no sender to this call")
        }

        // No token means we invent one; the client then has to use the handle we
        // returned, and races us. The spec's own remedy is for it to send a
        // token, so say so rather than let it fail mysteriously later.
        let token = options.handleToken ?? "abyss\(served + 1)"
        if options.handleToken == nil {
            log("\(sender) sent no handle_token — using '\(token)';"
                + " a client that subscribes after the call may miss the Response")
        }
        guard let path = RequestHandle.path(sender: sender, token: token) else {
            return .error(to: call, name: "org.freedesktop.DBus.Error.InvalidArgs",
                          message: "handle_token '\(token)' is not a valid object path element")
        }

        if options.directory {
            // Said plainly instead of opening a file picker and pretending.
            log("\(sender) asked for a directory chooser, which the Finder is not")
            live.insert(path)
            queue.append { [weak self] in
                self?.respond(path, .other, DBusValue.options([]))
            }
            return .methodReturn(to: call, body: [.objectPath(path)])
        }
        if options.multiple {
            log("\(sender) asked to select multiple files; the Finder returns one")
        }
        if !options.ignored.isEmpty {
            log("ignored options: \(options.ignored.joined(separator: ", "))")
        }

        live.insert(path)
        let service = portalService
        queue.append { [weak self] in
            guard let self else { return }
            self.runChooser(kind: kind, options: options, path: path,
                            service: service, title: title, sender: sender)
        }
        return .methodReturn(to: call, body: [.objectPath(path)])
    }

    /// The blocking half: ask `abyss-portal`, wait for the human, answer.
    private func runChooser(kind: ChooserKind, options: ChooserOptions, path: String,
                            service: String, title: String, sender: String) {
        log("\(sender) asked for \(kind == .open ? "OpenFile" : "SaveFile")"
            + " (\"\(title)\") → \(path)")
        let request = portalCallMessage(kind: kind, options: options)
        var reply: Msg
        do {
            reply = try Current.call(service, request)
        } catch {
            log("cannot reach the '\(service)' portal: \(error)")
            respond(path, .other, DBusValue.options([]))
            return
        }

        // **The descriptor stops here.** `abyss-portal` opened the file the user
        // chose and sent it over SCM_RIGHTS, because that is what its own
        // protocol does for our own apps. The FileChooser interface has no `h`
        // in its Response — the answer it defines is a URI — so this one is
        // closed rather than leaked, and the caller opens the path by name.
        // PHASE8.md §6.6 is about exactly this asymmetry.
        if let fd = reply.takeFD("file") {
            close(fd)
        }
        reply.closeFDs()

        let (code, results) = chooserResponse(reply: reply)
        served += 1
        respond(path, code, results)
    }

    /// Emit `Response` — unless the client closed the Request first, in which
    /// case the spec says no signal is emitted at all.
    private func respond(_ path: String, _ code: PortalResponse, _ results: DBusValue) {
        guard live.remove(path) != nil else {
            log("\(path) was closed before it finished; no Response emitted")
            return
        }
        let signal = DBusMessage.signal(path: path, interface: requestInterface,
                                        member: "Response",
                                        body: [.uint32(code.rawValue), results])
        do {
            try conn.send(signal)
            log("Response(\(code.rawValue)) on \(path)")
        } catch {
            log("could not emit Response on \(path): \(error)")
        }
    }

    // MARK: - Request.Close

    /// A Request the caller has given up on.
    ///
    /// The honest limitation, stated once here rather than implied: while the
    /// picker is up this process is blocked inside `Current.call`, so a `Close`
    /// arriving then is not seen until the dialog has already closed. What it
    /// does guarantee is that no `Response` is emitted for a request the client
    /// abandoned — which is the part the spec actually requires.
    private func closeRequest(_ call: DBusMessage) -> DBusMessage? {
        guard let path = call.path, live.contains(path) else {
            return .error(to: call, name: "org.freedesktop.DBus.Error.UnknownObject",
                          message: "no live request at \(call.path ?? "?")")
        }
        live.remove(path)
        log("closed \(path) at the client's request")
        return .methodReturn(to: call)
    }

    // MARK: - Properties and introspection

    private func property(_ call: DBusMessage, all: Bool) -> DBusMessage? {
        guard case .string(let iface)? = call.body.first else {
            return .error(to: call, name: "org.freedesktop.DBus.Error.InvalidArgs",
                          message: "expected an interface name")
        }
        guard iface == fileChooserInterface else {
            return all
                ? .methodReturn(to: call, body: [.options([])])
                : .error(to: call, name: "org.freedesktop.DBus.Error.UnknownInterface",
                         message: "no properties on \(iface)")
        }
        if all {
            return .methodReturn(to: call,
                                 body: [.options([("version", .uint32(fileChooserVersion))])])
        }
        guard case .string(let name)? = call.body.dropFirst().first, name == "version" else {
            return .error(to: call, name: "org.freedesktop.DBus.Error.UnknownProperty",
                          message: "no such property on \(iface)")
        }
        return .methodReturn(to: call, body: [.variant(.uint32(fileChooserVersion))])
    }

    /// Introspection XML. Real clients parse this with a real XML parser, so it
    /// has to be well-formed rather than merely plausible — `gdbus introspect`
    /// in the live script is what checks that.
    private func introspection(_ path: String?) -> String {
        let properties = """
        <interface name="org.freedesktop.DBus.Properties">\
        <method name="Get"><arg type="s" direction="in"/><arg type="s" direction="in"/>\
        <arg type="v" direction="out"/></method>\
        <method name="GetAll"><arg type="s" direction="in"/>\
        <arg type="a{sv}" direction="out"/></method></interface>\
        <interface name="org.freedesktop.DBus.Introspectable">\
        <method name="Introspect"><arg type="s" direction="out"/></method></interface>
        """
        if path == portalObjectPath {
            return """
            <!DOCTYPE node PUBLIC "-//freedesktop//DTD D-BUS Object Introspection 1.0//EN" \
            "http://www.freedesktop.org/standards/dbus/1.0/introspect.dtd">
            <node>\(properties)\
            <interface name="\(fileChooserInterface)">\
            <method name="OpenFile">\
            <arg type="s" name="parent_window" direction="in"/>\
            <arg type="s" name="title" direction="in"/>\
            <arg type="a{sv}" name="options" direction="in"/>\
            <arg type="o" name="handle" direction="out"/></method>\
            <method name="SaveFile">\
            <arg type="s" name="parent_window" direction="in"/>\
            <arg type="s" name="title" direction="in"/>\
            <arg type="a{sv}" name="options" direction="in"/>\
            <arg type="o" name="handle" direction="out"/></method>\
            <property name="version" type="u" access="read"/>\
            </interface></node>
            """
        }
        if let path, path.hasPrefix(RequestHandle.prefix) {
            return """
            <node>\(properties)\
            <interface name="\(requestInterface)">\
            <method name="Close"/>\
            <signal name="Response"><arg type="u" name="response"/>\
            <arg type="a{sv}" name="results"/></signal></interface></node>
            """
        }
        // Everything else gets a bare node naming the one child that leads
        // towards us, so a client walking the tree down from `/` arrives at the
        // portal instead of concluding the bus name is empty.
        let child = DBusPortalService.nextComponent(towards: portalObjectPath, from: path ?? "/")
        let children = child.map { "<node name=\"\($0)\"/>" } ?? ""
        return "<node>\(properties)\(children)</node>"
    }

    /// The next path element on the way from `here` to `target`, or nil if
    /// `here` is not an ancestor of it.
    static func nextComponent(towards target: String, from here: String) -> String? {
        let prefix = here == "/" ? "/" : here + "/"
        guard target.hasPrefix(prefix), target.count > prefix.count else { return nil }
        let rest = target.dropFirst(prefix.count)
        return String(rest.prefix(while: { $0 != "/" }))
    }
}
