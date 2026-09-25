import XCTest
@testable import MenuModel

final class MenuModelTests: XCTestCase {
    func testDisplayOrdersModifiersTheMacWay() {
        XCTAssertEqual(KeyEquivalent.cmd("n", .shift).display, "⇧⌘N")
        XCTAssertEqual(KeyEquivalent.cmd(.backspace).display, "⌘⌫")
        XCTAssertEqual(KeyEquivalent.cmd(.escape, .option).display, "⌥⌘⎋")
        XCTAssertEqual(KeyEquivalent(.character("x"), [.control, .option, .shift, .command]).display,
                       "⌃⌥⇧⌘X")
        XCTAssertEqual(KeyEquivalent.cmd(.up).display, "⌘↑")
    }

    func testCharactersAreStoredLowercased() {
        // Shift is a modifier, not a different letter: an uppercase definition
        // and a lowercase press are the same key.
        XCTAssertEqual(KeyEquivalent(.character("N"), [.command, .shift]),
                       KeyEquivalent.cmd("n", .shift))
    }

    private let model = MenuBarModel(appName: "Test", menus: [
        Menu("File", [
            .command(Command("file.open", "Open", key: .cmd("o"),
                             alternateKeys: [.cmd(.down)], summary: "Open it.")),
            .separator,
            .submenu(Menu("Recent", [
                .command(Command("file.recent", "Recent", key: .cmd("r"), summary: "Again.")),
            ])),
        ]),
        Menu("Edit", [
            .command(Command("edit.copy", "Copy", key: .cmd("c"), summary: "Copy it.")),
            .command(Command("edit.noKey", "No Key", summary: "Mouse only.")),
        ]),
    ])

    func testVerbLookupIsExactOnModifiers() {
        XCTAssertEqual(model.verb(for: .cmd("o")), "file.open")
        XCTAssertEqual(model.verb(for: .cmd(.down)), "file.open", "an alternate key runs it too")
        XCTAssertNil(model.verb(for: .cmd("o", .shift)), "⇧⌘O is a different keystroke")
        XCTAssertNil(model.verb(for: KeyEquivalent(.character("o"), [])), "a bare O is typing")
        XCTAssertEqual(model.verb(for: .cmd("r")), "file.recent", "submenus are searched")
    }

    func testCommandsFlattenInMenuOrder() {
        XCTAssertEqual(model.commands.map(\.verb),
                       ["file.open", "file.recent", "edit.copy", "edit.noKey"])
        XCTAssertEqual(model.command("edit.copy")?.title, "Copy")
        XCTAssertEqual(model.command("file.open")?.allKeys, [.cmd("o"), .cmd(.down)])
    }

    func testConflictsAndDuplicatesAreFound() {
        XCTAssertEqual(model.conflictingKeys, [])
        XCTAssertEqual(model.duplicateVerbs, [])
        let bad = MenuBarModel(appName: "Bad", menus: [Menu("M", [
            .command(Command("a", "A", key: .cmd("a"), summary: ".")),
            .command(Command("b", "B", key: .cmd("a"), summary: ".")),
            .command(Command("a", "A again", summary: ".")),
        ])])
        XCTAssertEqual(bad.conflictingKeys, [.cmd("a")])
        XCTAssertEqual(bad.duplicateVerbs, ["a"])
    }
}
