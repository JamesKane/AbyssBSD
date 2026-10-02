import XCTest
import CurrentIPC
import MenuModel
@testable import MenuWire

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// A provider with one of everything the wire has to carry.
private final class FakeApp: MenuProvider {
    var performed: [(String, [String: String])] = []
    var pasteEnabled = false

    let menuModel = MenuBarModel(appName: "Fake", menus: [
        Menu("Fake", [
            .command(Command("app.about", "About Fake", summary: "Say what this is.")),
        ]),
        Menu("File", [
            .command(Command("file.open", "Open", key: .cmd("o"),
                             alternateKeys: [.cmd(.down)], summary: "Open it.")),
            .separator,
            .submenu(Menu("Recent", [
                .submenu(Menu("Older", [
                    .command(Command("file.oldest", "Oldest", key: .cmd("9", [.shift, .option]),
                                     summary: "Three deep.")),
                ])),
            ])),
            .command(Command("file.go", "Go…",
                             arguments: [Argument("path", .path, "Where."),
                                         Argument("times", .integer, "How often.")],
                             summary: "Go somewhere.")),
        ]),
        Menu("Edit", [
            .command(Command("edit.paste", "Paste", key: .cmd("v"), summary: "Paste.")),
        ]),
        Menu("Empty", []),
    ])

    func menuValidate(_ c: Command) -> Enablement {
        c.verb == "edit.paste" && !pasteEnabled ? .disabled("the clipboard is empty") : .enabled
    }

    func menuPerform(_ c: Command, arguments: [String: String]) -> CommandResult {
        performed.append((c.verb, arguments))
        return c.verb == "file.go" ? .ok(arguments["path"]) : .ok(nil)
    }
}

final class MenuWireTests: XCTestCase {
    private func roundTrip(_ m: Msg) throws -> Msg { try Msg.unpack(m.pack()) }

    /// `writes` (P18.11) travels, and an application that never says it
    /// reads as writing nothing.
    func testWritesRoundTrips() throws {
        let model = MenuBarModel(appName: "W", menus: [Menu("File", [
            .command(Command("file.save", "Save", summary: "Save.", writes: true)),
            .command(Command("file.close", "Close", summary: "Close.")),
        ])])
        let d = try MenuWire.decodeDescribe(roundTrip(MenuWire.describeReply(model, enablement: { _ in .enabled })))
        XCTAssertEqual(d.model.commands.map(\.writes), [true, false])
        XCTAssertEqual(d.model, model)
    }

    func testDescribeRoundTripsTheWholeTree() throws {
        let app = FakeApp()
        let reply = try roundTrip(MenuWire.describeReply(app.menuModel,
                                                         enablement: app.menuValidate))
        let d = try MenuWire.decodeDescribe(reply)
        XCTAssertEqual(d.model, app.menuModel,
                       "menus, separators, a submenu three deep, an empty menu, keys, arguments")
        XCTAssertEqual(d.enablement["edit.paste"], .disabled("the clipboard is empty"),
                       "enablement travels with the reason, for a reader that sees no grey")
        XCTAssertEqual(d.enablement["file.oldest"], .enabled)
    }

    func testValidateCarriesEveryCommand() throws {
        let app = FakeApp()
        app.pasteEnabled = true
        let v = try MenuWire.decodeValidate(roundTrip(
            MenuWire.validateReply(app.menuModel, enablement: app.menuValidate)))
        XCTAssertEqual(Set(v.keys), Set(app.menuModel.commands.map(\.verb)))
        XCTAssertEqual(v["edit.paste"], .enabled)
    }

    func testEveryKeyNameRoundTrips() {
        let keys: [KeyEquivalent.Key] = [.character("a"), .character("["), .backspace,
                                         .forwardDelete, .up, .down, .left, .right,
                                         .enter, .escape, .tab]
        for k in keys { XCTAssertEqual(MenuWire.key(named: MenuWire.keyName(k)), k) }
        XCTAssertNil(MenuWire.key(named: "char:ab"))
        XCTAssertNil(MenuWire.key(named: "hyper"))
    }

    func testArgumentsAreCheckedAgainstTheirDeclaredTypes() {
        let go = FakeApp().menuModel.command("file.go")!
        XCTAssertNil(MenuService.check(go, ["path": "/tmp", "times": "2"]))
        XCTAssertEqual(MenuService.check(go, ["path": "/tmp"]),
                       "file.go needs times (integer): How often.")
        XCTAssertEqual(MenuService.check(go, ["path": "tmp", "times": "2"]),
                       "path must be an absolute path, not tmp")
        XCTAssertEqual(MenuService.check(go, ["path": "/tmp", "times": "two"]),
                       "times must be an integer, not two")
        XCTAssertEqual(MenuService.check(go, ["path": "/tmp", "times": "2", "tims": "3"]),
                       "file.go takes no argument tims", "a misspelt name fails rather than being ignored")
    }

    func testActivateIsRefusedWithAReasonAndNeverReachesTheApp() throws {
        let app = FakeApp()
        let service = try withRuntimeDir { try MenuService(name: "menus.fake.1", provider: app) }
        func run(_ verb: String, _ args: [String: String] = [:]) throws -> CommandResult {
            try MenuWire.decodeResult(roundTrip(service.handle(
                roundTrip(MenuWire.activateRequest(verb: verb, arguments: args)))))
        }
        XCTAssertEqual(try run("edit.paste"), .refused("the clipboard is empty"))
        XCTAssertEqual(try run("file.nope"), .refused("Fake has no verb file.nope"))
        XCTAssertEqual(try run("file.go", ["path": "/tmp"]),
                       .refused("file.go needs times (integer): How often."))
        XCTAssertTrue(app.performed.isEmpty, "a refused command never reaches perform")

        XCTAssertEqual(try run("file.go", ["path": "/tmp", "times": "1"]), .ok("/tmp"),
                       "a result comes back, not nothing")
        XCTAssertEqual(app.performed.map(\.0), ["file.go"])
        XCTAssertEqual(app.performed.first?.1, ["path": "/tmp", "times": "1"])
    }

    func testAnUnknownMethodIsAnErrorNotAResult() throws {
        let app = FakeApp()
        let service = try withRuntimeDir { try MenuService(name: "menus.fake.2", provider: app) }
        var m = Msg(); m.set("method", "dance")
        let reply = service.handle(m)
        XCTAssertEqual(reply.bool("ok"), false)
        XCTAssertThrowsError(try MenuWire.decodeResult(reply))
    }

    // MARK: a real socket

    func testDescribeActivateAndSubscribeOverARealSocket() throws {
        let dir = try scratchRuntimeDir()
        defer { unsetenv("ABYSS_RUNTIME_DIR"); _ = rmdirTree(dir) }
        let app = FakeApp()
        let name = MenuWire.serviceName(app: "Fake", pid: 77)
        XCTAssertEqual(name, "menus.fake.77")
        let service = try MenuService(name: name, provider: app)

        // One thread, taking turns: the connection waits in the backlog until
        // the service is told its fd is readable, as the run loop would.
        func exchange(_ request: Msg) throws -> Msg {
            let c = try Current.connect(name)
            defer { close(c) }
            try Current.send(request, on: c)
            service.serviceReadable()
            return try Current.receive(on: c)
        }
        var describe = Msg(); describe.set("method", "describe")
        XCTAssertEqual(try MenuWire.decodeDescribe(exchange(describe)).model.appName, "Fake")
        XCTAssertEqual(try MenuWire.decodeResult(exchange(
            MenuWire.activateRequest(verb: "file.open", arguments: [:]))), .ok(nil))

        // Subscribe, then change: the push arrives on the held connection.
        let sub = try Current.connect(name)
        var s = Msg(); s.set("method", "subscribe")
        try Current.send(s, on: sub)
        service.serviceReadable()
        XCTAssertEqual(try Current.receive(on: sub).bool("ok"), true)
        XCTAssertEqual(service.subscriberCount, 1)
        service.changed()
        XCTAssertEqual(try Current.receive(on: sub).string("method"), "changed")

        // A subscriber that has gone is dropped the next time there is news.
        close(sub)
        service.changed()
        service.changed()   // the first send may still land in the socket buffer
        XCTAssertEqual(service.subscriberCount, 0)
    }

    func testResolveFindsAnApplicationByName() throws {
        let dir = try scratchRuntimeDir()
        defer { unsetenv("ABYSS_RUNTIME_DIR"); _ = rmdirTree(dir) }
        let app = FakeApp()
        XCTAssertThrowsError(try MenuClient.resolve("fake")) { e in
            XCTAssertEqual(e as? MenuWireError, .noSuchApplication("fake"))
        }
        let one = try MenuService(name: MenuWire.serviceName(app: "Fake", pid: 1), provider: app)
        XCTAssertEqual(try MenuClient.resolve("fake"), "menus.fake.1")
        XCTAssertEqual(try MenuClient.resolve("menus.fake.1"), "menus.fake.1")

        // A socket left by a crash is not an application: it does not make the
        // name ambiguous.
        try leaveStaleSocket(MenuWire.serviceName(app: "Fake", pid: 2))
        XCTAssertEqual(try MenuClient.resolve("fake"), "menus.fake.1")

        let two = try MenuService(name: MenuWire.serviceName(app: "Fake", pid: 3), provider: app)
        XCTAssertThrowsError(try MenuClient.resolve("fake")) { e in
            XCTAssertEqual(e as? MenuWireError,
                           .ambiguous("fake", ["menus.fake.1", "menus.fake.3"]))
        }
        withExtendedLifetime((one, two)) {}
    }

    // MARK: helpers

    /// What a crashed service leaves: a socket file bound and never listened
    /// on, so a connect is refused.
    private func leaveStaleSocket(_ service: String) throws {
        let path = try Current.socketPath(service)
        #if os(Linux)
        let s = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        #else
        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        #endif
        XCTAssertGreaterThanOrEqual(s, 0)
        defer { close(s) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            let b = Array(path.utf8)
            raw.copyBytes(from: b)
            raw[b.count] = 0
        }
        let rc = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        XCTAssertEqual(rc, 0, "bind \(path)")
    }

    private func withRuntimeDir<T>(_ body: () throws -> T) throws -> T {
        let dir = try scratchRuntimeDir()
        addTeardownBlock { [dir] in unsetenv("ABYSS_RUNTIME_DIR"); _ = self.rmdirTree(dir) }
        return try body()
    }

    private func scratchRuntimeDir() throws -> String {
        var template = Array("/tmp/abyss-menu-XXXXXX".utf8CString)
        guard let dir = template.withUnsafeMutableBufferPointer({
            mkdtemp($0.baseAddress!).map { String(cString: $0) }
        }) else { throw CurrentError.system(errno, "mkdtemp") }
        setenv("ABYSS_RUNTIME_DIR", dir, 1)
        return dir
    }

    private func rmdirTree(_ path: String) -> Bool {
        if let d = opendir(path) {
            while let e = readdir(d) {
                let name = withUnsafeBytes(of: e.pointee.d_name) { raw -> String in
                    String(cString: raw.baseAddress!.assumingMemoryBound(to: CChar.self))
                }
                if name == "." || name == ".." { continue }
                unlink(path + "/" + name)
            }
            closedir(d)
        }
        return rmdir(path) == 0
    }
}
