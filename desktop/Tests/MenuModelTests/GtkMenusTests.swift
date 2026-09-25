import XCTest
import DBus
import MenuModel
@testable import DBusMenus

/// GTK's menus as our vocabulary, with no bus: the fixture is the
/// `org.gtk.Menus.Start` reply a stock GtkApplication sent in PHASE10 §4.1.
final class GtkMenusTests: XCTestCase {
    private func item(_ kv: [(String, DBusValue)]) -> DBusValue {
        .array("{sv}", kv.map { .dictEntry(.string($0.0), .variant($0.1)) })
    }
    private func link(_ g: UInt32, _ m: UInt32) -> DBusValue { .structure([.uint32(g), .uint32(m)]) }
    private func group(_ g: UInt32, _ m: UInt32, _ items: [DBusValue]) -> DBusValue {
        .structure([.uint32(g), .uint32(m), .array("a{sv}", items)])
    }

    /// What gtkmenu.c's GtkApplication exported, verbatim in shape.
    private var spikeReply: [DBusValue] {
        [.array("(uuaa{sv})", [
            group(0, 0, [item([("label", .string("File")), (":submenu", link(1, 0))]),
                         item([("label", .string("Edit")), (":submenu", link(2, 0))])]),
            group(1, 0, [item([("action", .string("app.new")), ("label", .string("New"))]),
                         item([("action", .string("app.open")), ("label", .string("Open…"))]),
                         item([("action", .string("app.quit")), ("label", .string("Quit"))])]),
            group(2, 0, [item([("action", .string("app.copy")), ("label", .string("Copy"))]),
                         item([("action", .string("app.paste")), ("label", .string("Paste"))])]),
        ])]
    }

    func testTheSpikesMenusBecomeOurModel() {
        let groups = GtkMenus.groups(fromStartReply: spikeReply)
        XCTAssertEqual(groups.count, 3)
        XCTAssertEqual(GtkMenus.missingGroups(groups), [], "every link is satisfied")
        let m = GtkMenus.model(appName: "MenuSpike", menubar: groups, appMenu: [])
        XCTAssertEqual(m.menus.map(\.title), ["MenuSpike", "File", "Edit"],
                       "the application menu first, as Jaguar's is")
        XCTAssertEqual(m.commands.map(\.verb),
                       ["app.new", "app.open", "app.quit", "app.copy", "app.paste"])
        XCTAssertEqual(m.command("app.open")?.title, "Open…")
        XCTAssertNil(m.command("app.quit")?.key,
                     "set_accels_for_action is not in the model (§4.1) — no key is invented")
    }

    func testOnlyGroup0IsKnownAtFirstSoTheRestAreAskedFor() {
        let only0 = GtkMenus.groups(fromStartReply: [.array("(uuaa{sv})", [
            group(0, 0, [item([("label", .string("File")), (":submenu", link(1, 0))]),
                         item([("label", .string("Edit")), (":submenu", link(2, 0))])])])])
        XCTAssertEqual(GtkMenus.missingGroups(only0), [1, 2])
    }

    func testSectionsAreInlineWithSeparatorsBetween() {
        let groups = GtkMenus.groups(fromStartReply: [.array("(uuaa{sv})", [
            group(0, 0, [item([("label", .string("_File")), (":submenu", link(0, 1))])]),
            group(0, 1, [item([(":section", link(0, 2))]), item([(":section", link(0, 3))])]),
            group(0, 2, [item([("action", .string("app.new")), ("label", .string("_New")),
                               ("accel", .string("<Primary>n"))])]),
            group(0, 3, [item([("action", .string("app.quit")), ("label", .string("_Quit"))])]),
        ])])
        let file = GtkMenus.model(appName: "A", menubar: groups, appMenu: []).menus[1]
        XCTAssertEqual(file.title, "File", "the mnemonic underscore is not a letter")
        XCTAssertEqual(file.items.count, 3)
        XCTAssertEqual(file.items[1], .separator)
        XCTAssertEqual(file.commands.first?.key, .cmd("n"), "an accel in the model is shown")
    }

    func testAModelThatLinksToItselfEnds() {
        let groups = GtkMenus.groups(fromStartReply: [.array("(uuaa{sv})", [
            group(0, 0, [item([("label", .string("Loop")), (":submenu", link(0, 0))])])])])
        _ = GtkMenus.model(appName: "A", menubar: groups, appMenu: [])   // must return
    }

    func testTitlesAndAccelerators() {
        XCTAssertEqual(GtkMenus.title("_Open"), "Open")
        XCTAssertEqual(GtkMenus.title("Save __As"), "Save _As")
        XCTAssertEqual(GtkMenus.accel("<Primary>q"), .cmd("q"))
        XCTAssertEqual(GtkMenus.accel("<Primary><Shift>n"), .cmd("n", .shift))
        XCTAssertEqual(GtkMenus.accel("<Control><Alt>Delete"),
                       KeyEquivalent(.forwardDelete, [.control, .option]))
        XCTAssertNil(GtkMenus.accel("<Hyper>x"), "a modifier we cannot draw is no key at all")
        XCTAssertNil(GtkMenus.accel("<Primary>F12"))
    }

    func testEnablementComesFromDescribeAllWithItsPrefix() {
        let body: [DBusValue] = [.array("{s(bgav)}", [
            .dictEntry(.string("paste"), .structure([.bool(false), .signature(""), .array("v", [])])),
            .dictEntry(.string("open"), .structure([.bool(true), .signature(""), .array("v", [])])),
        ])]
        let acts = GtkMenus.actions(fromDescribeAll: body, prefix: "app.")
        XCTAssertEqual(acts, ["app.paste": false, "app.open": true])
        XCTAssertEqual(GtkMenus.enablement(Command("app.open", "Open", summary: ""), actions: acts), .enabled)
        XCTAssertEqual(GtkMenus.enablement(Command("app.paste", "Paste", summary: ""), actions: acts),
                       .disabled("the application has disabled it"))
        XCTAssertEqual(GtkMenus.enablement(Command("win.close", "Close", summary: ""), actions: acts),
                       .disabled("the application has no action win.close"))
    }

    func testAParameterisedItemIsDrawnAndNotBridged() {
        let groups = GtkMenus.groups(fromStartReply: [.array("(uuaa{sv})", [
            group(0, 0, [item([("label", .string("View")), (":submenu", link(1, 0))])]),
            group(1, 0, [item([("action", .string("win.zoom")), ("label", .string("Big")),
                               ("target", .string("big"))])]),
        ])])
        let c = GtkMenus.model(appName: "A", menubar: groups, appMenu: []).commands.first!
        XCTAssertEqual(c.title, "Big")
        XCTAssertEqual(GtkMenus.enablement(c, actions: ["win.zoom": true]),
                       .disabled("a parameterised action, which the bridge does not carry yet"))
    }

    func testTheAddressRoundTripsAndKnowsWhenThereIsNothingToRead() {
        let a = GtkMenuAddress(applicationID: "org.abyss.MenuSpike", busName: ":1.0",
                               applicationPath: "/org/abyss/MenuSpike",
                               menubarPath: "/org/abyss/MenuSpike/menus/menubar",
                               appMenuPath: "", windowPath: "/org/abyss/MenuSpike/window/1")
        XCTAssertEqual(GtkMenuAddress(encoded: a.encoded), a)
        XCTAssertTrue(a.hasMenus)
        var none = a; none.menubarPath = ""
        XCTAssertFalse(none.hasMenus, "a window with no menubar and no app menu has nothing to show")
        XCTAssertNil(GtkMenuAddress(encoded: "just one line"))
        XCTAssertEqual(GtkMenuBridge.appName(a), "MenuSpike")
    }
}
