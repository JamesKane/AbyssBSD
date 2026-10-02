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
    /// Requests that have been handed out and not yet answered or closed,
    /// **and who each one belongs to** — the `Response` is addressed to that
    /// caller rather than broadcast (see `respond`).
    private var live: [String: String] = [:]
    /// Work deferred out of a method handler; see the file comment.
    private var queue: [() -> Void] = []
    public private(set) var journal: [String] = []
    /// Completed chooser interactions, for `--once` and for the tests.
    public private(set) var served = 0
    /// What we tell a foreign toolkit about how this desktop looks (P8.3).
    public var settings: PortalSettings = .aqua
    /// For a jail's bus (PHASE18 P18.4): put the chosen file where the caller
    /// can open it — given the path the person chose and the portal's
    /// descriptor of it, the path inside the jail, or nil if it could not be
    /// granted (the chooser then fails, rather than name a file the caller
    /// cannot reach).
    public var grant: ((String, Int32) -> String?)?

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
        conn.handle(PortalSettings.interface, "ReadAll") { [weak self] call in
            self?.settingsReadAll(call)
        }
        conn.handle(PortalSettings.interface, "Read") { [weak self] call in
            self?.settingsRead(call, layers: 2)
        }
        conn.handle(PortalSettings.interface, "ReadOne") { [weak self] call in
            self?.settingsRead(call, layers: 1)
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
            live[path] = sender
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

        live[path] = sender
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
        // **A jail's folder is not a folder here** (PHASE18 P18.6): what a
        // jailed caller names as current_folder is a path inside its jail —
        // its own private home, or nothing at all on the host, or worse, the
        // same name as the person's real home. The Finder opens where the
        // person's files are, and the caller learns nothing of them by
        // naming one.
        var options = options
        if grant != nil, let f = options.currentFolder {
            log("ignoring the jailed caller's folder \(f): it names a place inside its jail")
            options.currentFolder = nil
        }
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
        //
        // **Except in a jail** (PHASE18 P18.4), where the descriptor is the
        // proof that lets the file in: the caller cannot open the path the
        // person chose, so it is mounted where the caller can, and that is the
        // path the answer names.
        if let fd = reply.takeFD("file") {
            if let grant, reply.bool("ok") == true, let chosen = reply.string("path") {
                if let inside = grant(chosen, fd) {
                    log("granted \(chosen) to the jail as \(inside)")
                    reply.set("path", inside)
                } else {
                    log("could not grant \(chosen) to the jail")
                    reply.set("ok", false)
                    reply.set("error", "could not be granted")
                }
            }
            close(fd)
        }
        reply.closeFDs()

        let (code, results) = chooserResponse(reply: reply)
        served += 1
        respond(path, code, results)
    }

    /// Change what the desktop tells toolkits — the theme changed (P14.2) —
    /// and **say so**: `SettingChanged(namespace, key, value)` for every key
    /// that differs, broadcast, as the spec defines it. Until P14.2 nothing
    /// ever emitted it, because nothing ever changed after startup; a running
    /// GTK application would have kept the old `color-scheme` for ever.
    /// Returns how many settings changed.
    @discardableResult
    public func update(settings new: PortalSettings) -> Int {
        let changed = settings.changes(to: new)
        settings = new
        for c in changed {
            let signal = DBusMessage.signal(path: portalObjectPath, interface: PortalSettings.interface,
                                            member: "SettingChanged",
                                            body: [.string(c.namespace), .string(c.key), .variant(c.value)])
            do { try conn.send(signal) } catch {
                log("could not emit SettingChanged(\(c.namespace), \(c.key)): \(error)")
            }
        }
        return changed.count
    }

    /// Emit `Response` — unless the client closed the Request first, in which
    /// case the spec says no signal is emitted at all.
    private func respond(_ path: String, _ code: PortalResponse, _ results: DBusValue) {
        guard let sender = live.removeValue(forKey: path) else {
            log("\(path) was closed before it finished; no Response emitted")
            return
        }
        let signal = DBusMessage.signal(path: path, interface: requestInterface,
                                        member: "Response", to: sender,
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
        guard let path = call.path, live[path] != nil else {
            return .error(to: call, name: "org.freedesktop.DBus.Error.UnknownObject",
                          message: "no live request at \(call.path ?? "?")")
        }
        live.removeValue(forKey: path)
        log("closed \(path) at the client's request")
        return .methodReturn(to: call)
    }

    // MARK: - Settings

    /// `ReadAll` — the call a GTK application makes on startup, before anything
    /// else. It must succeed even when we publish nothing the client asked for:
    /// an empty dictionary means "no such settings here" and the toolkit uses its
    /// own defaults, while an error means "this desktop is broken" and gets
    /// logged as a warning on every launch. That distinction is the entire
    /// difference between a GTK app that works and one that merely runs.
    private func settingsReadAll(_ call: DBusMessage) -> DBusMessage? {
        guard call.path == portalObjectPath else {
            return .error(to: call, name: "org.freedesktop.DBus.Error.UnknownObject",
                          message: "no Settings at \(call.path ?? "?")")
        }
        guard case .array("s", let items)? = call.body.first else {
            return .error(to: call, name: "org.freedesktop.DBus.Error.InvalidArgs",
                          message: "expected (as namespaces)")
        }
        var patterns: [String] = []
        for item in items {
            guard case .string(let s) = item else { continue }
            patterns.append(s)
        }
        return .methodReturn(to: call, body: [settings.readAll(patterns: patterns)])
    }

    /// `Read` (two variants) and `ReadOne` (one). See `PortalSettings.read`.
    private func settingsRead(_ call: DBusMessage, layers: Int) -> DBusMessage? {
        guard call.path == portalObjectPath else {
            return .error(to: call, name: "org.freedesktop.DBus.Error.UnknownObject",
                          message: "no Settings at \(call.path ?? "?")")
        }
        guard case .string(let namespace)? = call.body.first,
              case .string(let key)? = call.body.dropFirst().first else {
            return .error(to: call, name: "org.freedesktop.DBus.Error.InvalidArgs",
                          message: "expected (s namespace, s key)")
        }
        let value = layers == 2
            ? settings.read(namespace: namespace, key: key)
            : settings.readOne(namespace: namespace, key: key)
        guard let value else {
            // The spec requires an error for an unknown namespace or key, and it
            // is the right answer: a made-up default is indistinguishable from a
            // real setting once it reaches the toolkit.
            return .error(to: call, name: "org.freedesktop.portal.Error.NotFound",
                          message: "no setting '\(key)' in '\(namespace)'")
        }
        return .methodReturn(to: call, body: [value])
    }

    // MARK: - Properties and introspection

    /// The `version` each interface advertises. Both are read by real clients
    /// before they call anything, and a missing one reads as version 0.
    private var versions: [String: UInt32] {
        [fileChooserInterface: fileChooserVersion,
         PortalSettings.interface: PortalSettings.version]
    }

    private func property(_ call: DBusMessage, all: Bool) -> DBusMessage? {
        guard case .string(let iface)? = call.body.first else {
            return .error(to: call, name: "org.freedesktop.DBus.Error.InvalidArgs",
                          message: "expected an interface name")
        }
        guard let version = versions[iface] else {
            return all
                ? .methodReturn(to: call, body: [.options([])])
                : .error(to: call, name: "org.freedesktop.DBus.Error.UnknownInterface",
                         message: "no properties on \(iface)")
        }
        if all {
            return .methodReturn(to: call, body: [.options([("version", .uint32(version))])])
        }
        guard case .string(let name)? = call.body.dropFirst().first, name == "version" else {
            return .error(to: call, name: "org.freedesktop.DBus.Error.UnknownProperty",
                          message: "no such property on \(iface)")
        }
        return .methodReturn(to: call, body: [.variant(.uint32(version))])
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
            </interface>\
            <interface name="\(PortalSettings.interface)">\
            <method name="ReadAll">\
            <arg type="as" name="namespaces" direction="in"/>\
            <arg type="a{sa{sv}}" name="value" direction="out"/></method>\
            <method name="Read">\
            <annotation name="org.freedesktop.DBus.Deprecated" value="true"/>\
            <arg type="s" name="namespace" direction="in"/>\
            <arg type="s" name="key" direction="in"/>\
            <arg type="v" name="value" direction="out"/></method>\
            <method name="ReadOne">\
            <arg type="s" name="namespace" direction="in"/>\
            <arg type="s" name="key" direction="in"/>\
            <arg type="v" name="value" direction="out"/></method>\
            <property name="version" type="u" access="read"/>\
            <signal name="SettingChanged">\
            <arg type="s" name="namespace"/><arg type="s" name="key"/>\
            <arg type="v" name="value"/></signal>\
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
