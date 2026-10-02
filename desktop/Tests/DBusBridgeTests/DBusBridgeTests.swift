// DBusBridge tests (BACKLOG D.1): every decision the bridge makes, and above
// all the ones that make it a bridge and not a bus (PRODUCT §5.6).

import XCTest
@testable import DBusBridge
import DBus

final class DBusBridgeTests: XCTestCase {
    var r = BridgeRouter(guid: "0123456789abcdef0123456789abcdef")
    let portal = 1, menus = 2, zenity = 3, gimp = 4

    override func setUp() {
        r = BridgeRouter(guid: "0123456789abcdef0123456789abcdef")
        r.attach(portal, kind: .service, uid: 1001, pid: 10)
        r.attach(menus, kind: .service, uid: 1001, pid: 11)
        r.attach(zenity, kind: .application, uid: 1001, pid: 20)
        r.attach(gimp, kind: .application, uid: 1001, pid: 21)
        for id in [portal, menus, zenity, gimp] { _ = hello(id) }
        _ = driver(portal, "RequestName", [.string("org.freedesktop.portal.Desktop"), .uint32(0)])
    }

    var serial: UInt32 = 100
    func call(_ dest: String, _ member: String, _ body: [DBusValue] = [], iface: String = "org.example.I") -> DBusMessage {
        var m = DBusMessage.methodCall(destination: dest, path: "/o", interface: iface, member: member, body: body)
        serial += 1; m.serial = serial
        return m
    }
    func driver(_ from: Int, _ member: String, _ body: [DBusValue] = [], iface: String = BridgeRouter.driverName) -> [BridgeRouter.Action] {
        r.route(from: from, call(BridgeRouter.driverName, member, body, iface: iface))
    }
    func hello(_ id: Int) -> [BridgeRouter.Action] { driver(id, "Hello") }
    func unique(_ id: Int) -> String { r.peers[id]!.unique }
    func delivered(_ a: [BridgeRouter.Action]) -> [(Int, DBusMessage)] {
        a.compactMap { if case .deliver(let to, let m) = $0 { return (to, m) }; return nil }
    }
    func reply(_ a: [BridgeRouter.Action], to id: Int) -> DBusMessage? {
        delivered(a).first { $0.0 == id && ($0.1.type == .methodReturn || $0.1.type == .error) }?.1
    }
    func addMatch(_ id: Int, _ rule: String) { XCTAssertEqual(reply(driver(id, "AddMatch", [.string(rule)]), to: id)?.type, .methodReturn) }

    // MARK: - connecting

    func testHelloGivesAUniqueNameAndNothingComesBeforeIt() {
        var fresh = BridgeRouter(guid: "x")
        fresh.attach(9, kind: .application, uid: 1, pid: 1)
        XCTAssertEqual(fresh.route(from: 9, call("org.freedesktop.portal.Desktop", "OpenFile")), [.close(9, "a message before Hello")])
        let a = fresh.route(from: 9, call(BridgeRouter.driverName, "Hello", iface: BridgeRouter.driverName))
        let d = delivered(a)
        XCTAssertEqual(d.first?.1.body, [.string(fresh.peers[9]!.unique)])
        XCTAssertTrue(d.contains { $0.1.member == "NameAcquired" && $0.1.destination == fresh.peers[9]!.unique })
        XCTAssertEqual(reply(fresh.route(from: 9, call(BridgeRouter.driverName, "Hello", iface: BridgeRouter.driverName)), to: 9)?.type, .error, "Hello twice")
    }

    // MARK: - applications reach ADE's services

    func testAnApplicationsCallReachesTheServiceWithItsTrueSender() {
        var m = call("org.freedesktop.portal.Desktop", "OpenFile", iface: "org.freedesktop.portal.FileChooser")
        m.sender = ":1.999"                               // forged
        let d = delivered(r.route(from: zenity, m))
        XCTAssertEqual(d.count, 1)
        XCTAssertEqual(d[0].0, portal)
        XCTAssertEqual(d[0].1.sender, unique(zenity), "the bridge says who sent it, not the message")
    }

    func testTheServicesReplyReachesTheApplication() {
        let m = call("org.freedesktop.portal.Desktop", "OpenFile")
        let fwd = delivered(r.route(from: zenity, m))[0].1
        let back = DBusMessage.methodReturn(to: fwd, body: [.objectPath("/r")])
        XCTAssertEqual(delivered(r.route(from: portal, back)).map(\.0), [zenity])
    }

    func testAServiceMayCallAnApplicationByItsUniqueNameOrTheNameItAskedFor() {
        _ = driver(zenity, "RequestName", [.string("org.gnome.Zenity"), .uint32(0)])
        XCTAssertEqual(delivered(r.route(from: menus, call(unique(zenity), "Describe", iface: "org.gtk.Menus"))).map(\.0), [zenity])
        XCTAssertEqual(delivered(r.route(from: menus, call("org.gnome.Zenity", "Describe", iface: "org.gtk.Menus"))).map(\.0), [zenity])
    }

    // MARK: - and never each other (the bridge, not a bus)

    func testAnApplicationCannotCallAnotherApplication() {
        _ = driver(gimp, "RequestName", [.string("org.gimp.GIMP"), .uint32(0)])
        let byUnique = reply(r.route(from: zenity, call(unique(gimp), "Activate")), to: zenity)
        XCTAssertEqual(byUnique?.errorName, "org.freedesktop.DBus.Error.AccessDenied")
        let byName = reply(r.route(from: zenity, call("org.gimp.GIMP", "Activate")), to: zenity)
        XCTAssertEqual(byName?.errorName, "org.freedesktop.DBus.Error.ServiceUnknown", "an application's name is not anyone else's to call")
        XCTAssertFalse(delivered(r.route(from: zenity, call(unique(gimp), "Activate"))).contains { $0.0 == gimp })
    }

    func testAnApplicationsSignalsReachOnlyServicesThatAsked() {
        addMatch(menus, "type='signal',interface='org.gtk.Menus'")
        addMatch(gimp, "type='signal'")                   // another application, asking for everything
        let s = DBusMessage.signal(path: "/m", interface: "org.gtk.Menus", member: "Changed")
        XCTAssertEqual(delivered(r.route(from: zenity, s)).map(\.0), [menus])
        var to = DBusMessage.signal(path: "/m", interface: "org.x", member: "Poke")
        to.destination = unique(gimp)
        XCTAssertTrue(delivered(r.route(from: zenity, to)).isEmpty, "a signal addressed to another application goes nowhere")
    }

    func testAServicesBroadcastReachesApplicationsThatAsked() {
        addMatch(zenity, "type='signal',interface='org.freedesktop.portal.Settings',member='SettingChanged'")
        let s = DBusMessage.signal(path: "/org/freedesktop/portal/desktop", interface: "org.freedesktop.portal.Settings",
                                   member: "SettingChanged", body: [.string("org.freedesktop.appearance")])
        XCTAssertEqual(delivered(r.route(from: portal, s)).map(\.0), [zenity])
    }

    /// A rule may name the sender by its well-known name, as GLib's
    /// `gdbus monitor --dest` and every portal client's subscription do.
    func testARuleMayNameTheSenderByItsWellKnownName() {
        addMatch(zenity, "type='signal',sender='org.freedesktop.portal.Desktop',interface='org.freedesktop.portal.Settings'")
        let s = DBusMessage.signal(path: "/org/freedesktop/portal/desktop", interface: "org.freedesktop.portal.Settings",
                                   member: "SettingChanged", body: [.string("org.freedesktop.appearance")])
        XCTAssertEqual(delivered(r.route(from: portal, s)).map(\.0), [zenity])
        XCTAssertTrue(delivered(r.route(from: menus, s)).isEmpty, "another service is not that name")
    }

    func testNobodyWatchesAnybody() {
        addMatch(gimp, "eavesdrop='true',type='method_call'")
        XCTAssertFalse(delivered(r.route(from: zenity, call("org.freedesktop.portal.Desktop", "OpenFile"))).contains { $0.0 == gimp },
                       "an eavesdrop rule is accepted and grants nothing")
        XCTAssertEqual(reply(driver(gimp, "BecomeMonitor", [.array("s", []), .uint32(0)], iface: "org.freedesktop.DBus.Monitoring"), to: gimp)?.errorName,
                       "org.freedesktop.DBus.Error.AccessDenied")
    }

    func testNothingIsStartedByName() {
        XCTAssertEqual(reply(driver(zenity, "StartServiceByName", [.string("org.gnome.Nautilus"), .uint32(0)]), to: zenity)?.errorName,
                       "org.freedesktop.DBus.Error.ServiceUnknown")
        XCTAssertEqual(reply(driver(zenity, "UpdateActivationEnvironment", [.array("{ss}", [])]), to: zenity)?.errorName,
                       "org.freedesktop.DBus.Error.AccessDenied")
    }

    func testAReplyBetweenApplicationsGoesNowhere() {
        let fake = DBusMessage.methodReturn(to: { var c = call(unique(gimp), "X"); c.sender = unique(gimp); return c }(), body: [])
        XCTAssertTrue(delivered(r.route(from: zenity, fake)).isEmpty)
    }

    // MARK: - names

    func testEveryCopyOfAnApplicationThinksItIsTheOnlyOne() {
        XCTAssertEqual(reply(driver(zenity, "RequestName", [.string("org.gnome.Zenity"), .uint32(4)]), to: zenity)?.body, [.uint32(1)])
        XCTAssertEqual(reply(driver(gimp, "RequestName", [.string("org.gnome.Zenity"), .uint32(4)]), to: gimp)?.body, [.uint32(1)],
                       "no single-instance handover between applications (PRODUCT §5.6's price)")
        XCTAssertEqual(reply(driver(zenity, "GetNameOwner", [.string("org.gnome.Zenity")]), to: zenity)?.body, [.string(unique(zenity))])
        XCTAssertEqual(reply(driver(gimp, "GetNameOwner", [.string("org.gnome.Zenity")]), to: gimp)?.body, [.string(unique(gimp))])
    }

    func testOneServicePerName() {
        XCTAssertEqual(reply(driver(menus, "RequestName", [.string("org.freedesktop.portal.Desktop"), .uint32(0)]), to: menus)?.body, [.uint32(3)])
    }

    func testAnApplicationSeesADEsNamesAndItsOwnOnly() {
        _ = driver(gimp, "RequestName", [.string("org.gimp.GIMP"), .uint32(0)])
        guard case .array(_, let items)? = reply(driver(zenity, "ListNames"), to: zenity)?.body.first else { return XCTFail() }
        let names = items.compactMap { v -> String? in if case .string(let s) = v { return s }; return nil }
        XCTAssertTrue(names.contains("org.freedesktop.portal.Desktop"))
        XCTAssertTrue(names.contains(unique(zenity)))
        XCTAssertFalse(names.contains(unique(gimp)))
        XCTAssertFalse(names.contains("org.gimp.GIMP"))
        XCTAssertEqual(reply(driver(zenity, "NameHasOwner", [.string("org.gimp.GIMP")]), to: zenity)?.body, [.bool(false)])
        XCTAssertEqual(reply(driver(menus, "NameHasOwner", [.string("org.gimp.GIMP")]), to: menus)?.body, [.bool(true)], "a service may know")
    }

    func testAnApplicationMayAskAboutItselfAndAServiceAboutAnyone() {
        XCTAssertEqual(reply(driver(zenity, "GetConnectionUnixUser", [.string(unique(zenity))]), to: zenity)?.body, [.uint32(1001)])
        XCTAssertEqual(reply(driver(zenity, "GetConnectionUnixUser", [.string(unique(gimp))]), to: zenity)?.type, .error)
        XCTAssertEqual(reply(driver(menus, "GetConnectionUnixProcessID", [.string(unique(gimp))]), to: menus)?.body, [.uint32(21)])
    }

    func testOwnerChangesOfApplicationsAreForServicesOnly() {
        addMatch(menus, "type='signal',member='NameOwnerChanged'")
        addMatch(gimp, "type='signal',member='NameOwnerChanged'")
        let a = r.detach(zenity)
        XCTAssertEqual(Set(delivered(a).map(\.0)), [menus], "an application's coming and going is not news to other applications")
        let b = r.detach(portal)
        XCTAssertEqual(Set(delivered(b).map(\.0)), [menus, gimp], "a service's is")
        XCTAssertEqual(reply(driver(menus, "RequestName", [.string("org.freedesktop.portal.Desktop"), .uint32(0)]), to: menus)?.body,
                       [.uint32(1)], "a name goes with its owner")
    }

    // MARK: - match rules

    func testMatchRulesParseAndMatch() {
        let m = MatchRule("type='signal',interface='org.gtk.Menus',path_namespace='/org/gtk',arg0='a''b'")
        XCTAssertNil(MatchRule("type"), "a key with no value")
        let r1 = MatchRule("type='signal',interface='org.gtk.Menus',path_namespace='/org/gtk',arg0='x'")!
        var s = DBusMessage.signal(path: "/org/gtk/menus/0", interface: "org.gtk.Menus", member: "Changed", body: [.string("x")])
        XCTAssertTrue(r1.matches(s))
        s.path = "/org/gtkx"
        XCTAssertFalse(r1.matches(s), "path_namespace is by component")
        s.path = "/org/gtk"; s.body = [.string("y")]
        XCTAssertFalse(r1.matches(s))
        XCTAssertNotNil(m)
        XCTAssertFalse(MatchRule("type='method_call'")!.matches(s))
    }
}
