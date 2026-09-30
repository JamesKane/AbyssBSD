// GtkMenuBridge — GTK applications' menus, served as MenuWire (PHASE10.md
// P10.6).
//
// The bar speaks one protocol. When the compositor says the frontmost window is
// a GTK application's (focus kind `gtk`), the bar sends its ordinary MenuWire
// requests to **one** service, `menus-dbus`, with the address as `target`; this
// answers them by asking the application over the session bus —
// `org.gtk.Menus`/`org.gtk.Actions`. `abyss-dbus` is where PLAN.md put the
// translation, and it is the only process that touches D-Bus.
//
// **GTK only.** P10.7 served Qt's `com.canonical.dbusmenu` here too; that was
// removed when AbyssBSD settled on one toolkit, GTK (PHASE15, 2026-09-30) —
// Firefox needs it, and FreeBSD's Qt pulls it in anyway.
//
// **A process of its own** (`abyss-dbus --menus`), not a second job for the
// portal bridge: that one blocks while a file dialog is open (PHASE8 §6.7), and
// a menu bar must never wait on somebody's Open panel.
//
// Nothing is cached. Every `describe` reads the menus again and every
// `validate` asks GTK what is enabled — the same "pulled as it opens" rule as
// our own applications (§6.4).
//
// **What changes is pushed (P10.9).** The bar subscribes with a target, as our
// own applications' bars do with theirs, and is told `changed` when the
// application's menus change under it: GTK's `org.gtk.Menus.Changed` (sent only
// to a watcher that has called `Start` and not `End`, so the bridge holds a
// `Start` on every group while anyone watches). A signal only marks the
// application dirty; after a short quiet the bridge reads the menus itself and
// says `changed` only if the model is different, which filters the noise.

import CurrentIPC
import DBus
import MenuModel
import MenuWire

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Bars watching one application's menus (P10.9).
final class MenuWatch {
    let target: String
    var subscribers: [Int32] = []
    /// The match rules asked for, to be removed word for word.
    var rules: [String] = []
    /// What the bars were last shown: `changed` is said only when it differs.
    var model: MenuBarModel?
    /// A signal arrived; read again once things are quiet.
    var dirtySince: UInt64?
    /// GTK: the groups held with Start, by object path, to End when done.
    var held: [String: [UInt32]] = [:]
    init(target: String) { self.target = target }
}

public final class GtkMenuBridge {
    public static let serviceName = "menus-dbus"

    private let conn: DBusConnection
    private let server: Current.Server
    public private(set) var served = 0
    /// Watched applications, by target.
    private var watches: [String: MenuWatch] = [:]
    /// `changed` pushed, and re-reads that found nothing new — for the log a
    /// test reads (the second is how an echo loop would show).
    public private(set) var changesPushed = 0, quietRereads = 0
    /// Where the bridge says what it did (abyss-dbus's log).
    public var log: (String) -> Void = { _ in }
    /// How long a burst of signals must be quiet before the menus are read.
    static let quietNs: UInt64 = 100_000_000

    public init(connection: DBusConnection, service: String = GtkMenuBridge.serviceName) throws {
        conn = connection
        server = try Current.Server(service: service)
        try server.setNonBlocking(true)
        conn.onMessage = { [weak self] m in self?.signal(m) }
    }

    deinit {
        for w in watches.values { for s in w.subscribers { close(s) } }
        server.shutdownAndUnlink()
    }

    /// Wait up to `timeoutMs` for either side and answer what arrived.
    public func step(timeoutMs: Int32) throws {
        let subs = watches.values.flatMap(\.subscribers)
        var pfds = [pollfd(fd: server.fd, events: Int16(POLLIN), revents: 0),
                    pollfd(fd: conn.fd, events: Int16(POLLIN), revents: 0)]
            + subs.map { pollfd(fd: $0, events: Int16(POLLIN), revents: 0) }
        // A dirty application is read within the quiet time, whatever else.
        let wait = watches.values.contains { $0.dirtySince != nil } ? min(timeoutMs, 50) : timeoutMs
        let pr = pfds.withUnsafeMutableBufferPointer { poll($0.baseAddress, nfds_t($0.count), wait) }
        if pr > 0 {
            if pfds[1].revents != 0 { try conn.readAndDispatch(timeoutMs: 0) }
            if pfds[0].revents != 0 { serveOne() }
            // A subscriber's connection is only ever readable when the bar
            // has gone (it sends nothing after subscribing).
            for (i, s) in subs.enumerated() where pfds[i + 2].revents != 0 { unsubscribe(s) }
        }
        rereadQuiet()
    }

    private func serveOne() {
        guard let c = try? server.accept() else { return }
        guard var request = try? Current.receive(on: c) else { close(c); return }
        defer { request.closeFDs() }
        served += 1
        if request.string("method") == "subscribe" {
            subscribe(request, c)
            return
        }
        let reply = handle(request)
        try? Current.send(reply, on: c)
        close(c)
    }

    // MARK: - Watching (P10.9)

    private func subscribe(_ request: Msg, _ c: Int32) {
        guard let t = request.string("target"),
              GtkMenuAddress(encoded: t) != nil else {
            try? Current.send(MenuWire.errorReply("subscribe needs a target: the address the compositor reported"), on: c)
            close(c)
            return
        }
        let w: MenuWatch
        if let have = watches[t] { w = have } else {
            w = MenuWatch(target: t)
            do { try watch(w) } catch {
                try? Current.send(MenuWire.errorReply("cannot watch it: \(error)"), on: c)
                close(c)
                return
            }
            watches[t] = w
        }
        var ok = Msg(); ok.set("ok", true)
        guard (try? Current.send(ok, on: c)) != nil else { close(c); return }
        w.subscribers.append(c)
        log("watching \(name(t)) for \(w.subscribers.count) bar(s)")
    }

    /// Start listening: the match rules, GTK's held groups, and the model as
    /// it is now — what "changed" will be measured against.
    private func watch(_ w: MenuWatch) throws {
        if let a = GtkMenuAddress(encoded: w.target) {
            for path in [a.menubarPath, a.appMenuPath] where !path.isEmpty {
                let rule = "type='signal',sender='\(a.busName)',path='\(path)',interface='org.gtk.Menus',member='Changed'"
                try conn.addMatch(rule)
                w.rules.append(rule)
            }
            w.model = try read(a)
            try hold(w, a)
        }
    }

    /// GTK sends Changed only to a watcher holding a Start: hold one on every
    /// group there is now, and let go of the ones held before.
    private func hold(_ w: MenuWatch, _ a: GtkMenuAddress) throws {
        let before = w.held
        w.held = [:]
        for path in [a.menubarPath, a.appMenuPath] where !path.isEmpty {
            w.held[path] = try groups(a, path: path, keep: true).map(\.group)
        }
        for (path, gs) in before where !gs.isEmpty {
            _ = try? conn.call(.methodCall(
                destination: a.busName, path: path, interface: "org.gtk.Menus",
                member: "End", body: [.array("u", gs.map { .uint32($0) })]), timeoutMs: 1000)
        }
    }

    private func unsubscribe(_ s: Int32) {
        close(s)
        for (t, w) in watches where w.subscribers.contains(s) {
            w.subscribers.removeAll { $0 == s }
            guard w.subscribers.isEmpty else { continue }
            for r in w.rules { try? conn.removeMatch(r) }
            if let a = GtkMenuAddress(encoded: t) {
                for (path, gs) in w.held where !gs.isEmpty {
                    _ = try? conn.call(.methodCall(
                        destination: a.busName, path: path, interface: "org.gtk.Menus",
                        member: "End", body: [.array("u", gs.map { .uint32($0) })]), timeoutMs: 1000)
                }
            }
            watches[t] = nil
            log("no bar watches \(name(t)) now")
        }
    }

    /// A signal from the bus: which watched application does it concern?
    private func signal(_ m: DBusMessage) {
        guard m.type == .signal, let sender = m.sender, let path = m.path else { return }
        for w in watches.values {
            if let a = GtkMenuAddress(encoded: w.target), a.busName == sender,
                      path == a.menubarPath || path == a.appMenuPath, m.member == "Changed" {
                if w.dirtySince == nil { w.dirtySince = GtkMenuBridge.nowNs() }
            }
        }
    }

    /// Read every application that has been quiet long enough since its last
    /// signal, and tell its bars if the menus are different.
    private func rereadQuiet() {
        let now = GtkMenuBridge.nowNs()
        for w in watches.values {
            guard let since = w.dirtySince, now &- since >= GtkMenuBridge.quietNs else { continue }
            w.dirtySince = nil
            let fresh: MenuBarModel?
            if let a = GtkMenuAddress(encoded: w.target), let m = try? read(a) {
                fresh = m
                try? hold(w, a)
            } else { fresh = nil }
            guard let fresh, fresh != w.model else {
                quietRereads += 1
                log("\(name(w.target)) signalled, and its menus are the same (\(quietRereads) quiet re-reads)")
                continue
            }
            w.model = fresh
            var msg = Msg(); msg.set("method", "changed")
            w.subscribers.removeAll { s in
                if (try? Current.send(msg, on: s)) != nil { return false }
                close(s)
                return true
            }
            changesPushed += 1
            log("\(name(w.target))'s menus changed; told \(w.subscribers.count) bar(s) "
                + "(\(changesPushed) changes, \(quietRereads) quiet re-reads)")
        }
    }

    static func nowNs() -> UInt64 {
        var ts = timespec()
        clock_gettime(CLOCK_MONOTONIC, &ts)
        return UInt64(ts.tv_sec) &* 1_000_000_000 &+ UInt64(ts.tv_nsec)
    }

    private func name(_ t: String) -> String {
        if let a = GtkMenuAddress(encoded: t) { return a.applicationID }
        return t
    }

    func handle(_ request: Msg) -> Msg {
        guard let t = request.string("target"), let a = GtkMenuAddress(encoded: t) else {
            return MenuWire.errorReply("menus-dbus needs a target: the address the compositor reported")
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
    /// With `keep`, the Start is held — a watch (P10.9) — and not ended here.
    private func groups(_ a: GtkMenuAddress, path: String, keep: Bool = false) throws -> [GtkMenuGroup] {
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
        // Unsubscribe, unless a watch holds it: otherwise GTK would send
        // signals to nobody.
        if keep { return have }
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
