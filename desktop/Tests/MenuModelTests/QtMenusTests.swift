import XCTest
import DBus
import MenuModel
@testable import DBusMenus

/// Qt's menus as our vocabulary, with no bus: the fixture is the shape of the
/// `com.canonical.dbusmenu.GetLayout` reply stock kcalc sent (PHASE10 §4.5).
final class QtMenusTests: XCTestCase {
    private func node(_ id: Int32, _ props: [(String, DBusValue)], _ kids: [DBusValue] = []) -> DBusValue {
        .variant(.structure([.int32(id),
                             .array("{sv}", props.map { .dictEntry(.string($0.0), .variant($0.1)) }),
                             .array("v", kids)]))
    }
    private func keys(_ parts: [String]) -> DBusValue {
        .array("as", [.array("s", parts.map { .string($0) })])
    }

    /// kcalc's File and Edit menus, and a lazy Help, as GetLayout returned them.
    private var kcalc: [DBusValue] {
        let root = node(0, [("children-display", .string("submenu"))], [
            node(1, [("children-display", .string("submenu")), ("label", .string("_File"))], [
                node(2, [("label", .string("_Quit")), ("shortcut", keys(["Control", "Q"]))]),
            ]),
            node(3, [("children-display", .string("submenu")), ("label", .string("_Edit"))], [
                node(4, [("label", .string("_Undo")), ("shortcut", keys(["Control", "Z"]))]),
                node(5, [("label", .string("Re_do")), ("shortcut", keys(["Control", "Shift", "Z"])),
                         ("enabled", .bool(false))]),
                node(6, [("type", .string("separator"))]),
                node(7, [("label", .string("_Copy")), ("shortcut", keys(["Control", "C"]))]),
                node(8, [("label", .string("Hidden")), ("visible", .bool(false))]),
            ]),
            node(22, [("children-display", .string("submenu")), ("label", .string("_Help"))], []),
        ])
        guard case .variant(let inner) = root else { return [] }
        return [.uint32(1), inner]
    }

    func testKcalcsLayoutBecomesOurModel() throws {
        let root = try XCTUnwrap(QtMenus.root(fromGetLayout: kcalc))
        let r = QtMenus.model(appName: "kcalc", root: root)
        XCTAssertEqual(r.model.menus.map(\.title), ["kcalc", "File", "Edit", "Help"])
        XCTAssertEqual(r.model.commands.map(\.verb), ["file.quit", "edit.undo", "edit.redo", "edit.copy"],
                       "verbs are menu paths, not ids — ids are renumbered when Qt rebuilds")
        XCTAssertEqual(r.ids["edit.copy"], 7)
        XCTAssertEqual(r.enabled["edit.redo"], false)
        XCTAssertNil(r.model.command("edit.hidden"), "an invisible item is not in the vocabulary")
        let edit = r.model.menus[2]
        XCTAssertEqual(edit.items.count, 4, "undo, redo, separator, copy")
        XCTAssertEqual(edit.items[2], .separator)
    }

    func testShortcutsAreShownAsTheKeysThatWork() throws {
        let root = try XCTUnwrap(QtMenus.root(fromGetLayout: kcalc))
        let m = QtMenus.model(appName: "kcalc", root: root).model
        XCTAssertEqual(m.command("edit.undo")?.key?.display, "⌃Z",
                       "Qt listens for Ctrl; ⌘Z would be a key that does nothing")
        XCTAssertEqual(m.command("edit.redo")?.key?.display, "⌃⇧Z")
        XCTAssertNil(QtMenus.shortcut(keys(["Control", "F12"])), "no spelling, no key")
    }

    func testALazySubmenuIsFoundSoItCanBeAskedToFill() throws {
        let root = try XCTUnwrap(QtMenus.root(fromGetLayout: kcalc))
        XCTAssertEqual(QtMenus.lazySubmenus(root), [22], "Help says submenu and shows no children")
    }

    func testDuplicateLabelsGetDistinctVerbs() throws {
        let root = node(0, [], [
            node(1, [("children-display", .string("submenu")), ("label", .string("View"))], [
                node(2, [("label", .string("Zoom"))]), node(3, [("label", .string("Zoom"))]),
            ])])
        guard case .variant(let inner) = root else { return XCTFail() }
        let r = QtMenus.model(appName: "a", root: try XCTUnwrap(QtMenus.root(fromGetLayout: [.uint32(1), inner])))
        XCTAssertEqual(r.model.duplicateVerbs, [])
        XCTAssertEqual(r.model.commands.map(\.verb), ["view.zoom", "view.zoom-2"])
    }

    func testTheAddressRoundTripsAndIsNotAGtkAddress() {
        let a = DBusMenuAddress(focusAddress: ":1.1\n/MenuBar/2", applicationID: "org.kde.kcalc")
        XCTAssertEqual(a?.service, ":1.1")
        XCTAssertEqual(a.flatMap { DBusMenuAddress(encoded: $0.encoded) }, a)
        XCTAssertNil(a.flatMap { GtkMenuAddress(encoded: $0.encoded) },
                     "the bridge must never read a Qt address as a GTK one")
        XCTAssertNil(DBusMenuAddress(focusAddress: ":1.1", applicationID: "x"))
        XCTAssertEqual(QtMenus.appName("org.kde.kcalc"), "kcalc")
    }
}
