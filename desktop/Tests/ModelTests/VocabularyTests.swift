// The vocabulary bridge (PHASE18 P18.10): only what was given, as the
// application's own menus say it, and every step in the transcript.

import XCTest
import CurrentIPC
import MenuModel
@testable import Model
@testable import Vocabulary

final class VocabularyTests: XCTestCase {
    final class FakeMenus: MenuCaller {
        var activated: [(String, String, [String: String])] = []
        let models: [String: MenuBarModel] = [
            "menus.textedit.42": MenuBarModel(appName: "TextEdit", menus: [
                Menu("File", [.command(Command("file.save", "Save", key: .cmd("s"), summary: "Save the document.")),
                              .command(Command("file.open", "Open…", arguments: [Argument("path", .path, "The file.")],
                                               summary: "Open a file."))]),
            ]),
            "menus.grab.7": MenuBarModel(appName: "Grab", menus: [
                Menu("Capture", [.command(Command("capture.screen", "Screen", summary: "Capture the screen."))]),
            ]),
        ]
        func describe(_ service: String) throws -> (model: MenuBarModel, enablement: [String: Enablement]) {
            guard let m = models[service] else { throw MenuWireTestError.gone }
            return (m, ["file.open": .disabled("a document is open")])
        }
        func activate(_ service: String, verb: String, arguments: [String: String]) throws -> CommandResult {
            activated.append((service, verb, arguments))
            return verb == "file.save" ? .ok(nil) : .refused("not now")
        }
    }
    enum MenuWireTestError: Error { case gone }

    func msg(_ method: String, app: String = "", verb: String = "", arguments: String = "") -> Msg {
        var m = Msg(); m.set("method", method)
        if !app.isEmpty { m.set("app", app) }
        if !verb.isEmpty { m.set("verb", verb) }
        if !arguments.isEmpty { m.set("arguments", arguments) }
        return m
    }

    func testOnlyWhatWasGivenIsReachable() throws {
        let menus = FakeMenus()
        var logged: [String] = []
        let b = VocabularyBridge(menus: menus) { kind, f in logged.append(kind + " " + (f.first { $0.0 == "app" }?.1.string ?? "")) }
        XCTAssertEqual(b.handle(msg("apps")).string("apps"), "", "nothing until something is given")
        XCTAssertEqual(try b.give(service: "menus.textedit.42"), "TextEdit")
        XCTAssertEqual(b.handle(msg("apps")).string("apps"), "TextEdit")
        let grab = b.handle(msg("describe", app: "Grab"))
        XCTAssertEqual(grab.bool("ok"), false)
        XCTAssertEqual(grab.string("error"), "Grab was not given to this session")
        XCTAssertEqual(b.handle(msg("activate", app: "Grab", verb: "capture.screen")).bool("ok"), false)
        XCTAssertTrue(menus.activated.isEmpty, "a refusal is never forwarded")
        XCTAssertEqual(logged, ["given TextEdit", "refused Grab", "refused Grab"])
    }

    func testActivateGoesToTheApplicationWithItsArguments() throws {
        let menus = FakeMenus()
        let b = VocabularyBridge(menus: menus)
        _ = try b.give(service: "menus.textedit.42")
        XCTAssertEqual(b.handle(msg("activate", app: "textedit", verb: "file.save")).string("text"), "ok", "names are matched without case")
        XCTAssertEqual(b.handle(msg("activate", app: "TextEdit", verb: "file.open", arguments: "path=/home/a.txt")).string("text"),
                       "refused: not now", "the application's refusal, in its words")
        XCTAssertEqual(menus.activated.map { $0.0 }, ["menus.textedit.42", "menus.textedit.42"])
        XCTAssertEqual(menus.activated[1].2, ["path": "/home/a.txt"])
    }

    func testTheDescriptionIsTheApplicationsOwn() throws {
        let b = VocabularyBridge(menus: FakeMenus())
        _ = try b.give(service: "menus.textedit.42")
        XCTAssertEqual(b.handle(msg("describe", app: "TextEdit")).string("text"), """
        TextEdit:
          file.save — "Save" in File [enabled]. Save the document.
          file.open — "Open…" in File; arguments: path (path): The file. [disabled: a document is open]. Open a file.
        """)
    }

    /// The agent's side answers apps, describe and activate — never give:
    /// what it may drive is the keeper's to say, on a socket the jail cannot see.
    func testTheAgentCannotGiveItselfAnything() {
        let menus = FakeMenus()
        let b = VocabularyBridge(menus: menus)
        var m = msg("give"); m.set("service", "menus.grab.7")
        let r = b.handle(m)
        XCTAssertEqual(r.bool("ok"), false)
        XCTAssertEqual(r.string("error"), "the vocabulary bridge answers apps, describe and activate")
        XCTAssertTrue(b.given.isEmpty)
    }

    /// Taken back (P18.11): refused from then on, as never given.
    func testATakenApplicationIsRefusedAgain() throws {
        let menus = FakeMenus()
        var logged: [String] = []
        let b = VocabularyBridge(menus: menus) { kind, _ in logged.append(kind) }
        _ = try b.give(service: "menus.textedit.42")
        XCTAssertTrue(b.take("textedit"))
        XCTAssertFalse(b.take("textedit"), "nothing to take twice")
        let r = b.handle(msg("activate", app: "TextEdit", verb: "file.save"))
        XCTAssertEqual(r.string("error"), "TextEdit was not given to this session")
        XCTAssertTrue(menus.activated.isEmpty)
        XCTAssertEqual(logged, ["given", "taken", "refused"])
    }

    func testAGiveIsOneRunningCopy() throws {
        let b = VocabularyBridge(menus: FakeMenus())
        XCTAssertThrowsError(try b.give(service: "menus.textedit.999"), "an application that does not answer is not given")
        _ = try b.give(service: "menus.textedit.42")
        _ = try b.give(service: "menus.textedit.42")
        XCTAssertEqual(b.given.count, 1, "giving again does not duplicate")
    }
}
