// The Agent window (PHASE18 P18.8b): what a reply adds to the conversation,
// where the controls are, and the menu's enablement as the session goes.

import XCTest
import CCairo
import AppBundles
@testable import Aqua
import MenuModel
import PoolConfig
#if canImport(Glibc)
import Glibc
#endif

final class AgentWindowTests: XCTestCase {
    func testATurnShowsTheToolCallsBeforeTheAnswer() {
        XCTAssertEqual(agentTurn(question: "due monday?", calls: ["list_directory({})", "read_file({})"], answer: "The plumber."),
                       "You: due monday?\n  › list_directory({})\n  › read_file({})\nAgent: The plumber.\n\n")
        XCTAssertEqual(agentTurn(question: "hi", calls: [], answer: "Hello."), "You: hi\nAgent: Hello.\n\n")
    }

    func testThePiecesAddUpToTheTurn() {
        XCTAssertEqual(agentQuestionLine("q") + agentCallLine("c()") + agentAnswerLine("a"),
                       agentTurn(question: "q", calls: ["c()"], answer: "a"))
    }

    func testTheLayoutKeepsTheFieldAndButtonAtTheBottom() {
        for (w, h) in [(560.0, 460.0), (900.0, 700.0), (300.0, 200.0)] {
            let l = AgentLayout(w: w, h: h)
            XCTAssertEqual(l.field.y + l.field.h, h - 12, "\(w)x\(h)")
            XCTAssertEqual(l.ask.y, l.field.y)
            XCTAssertEqual(l.ask.x + l.ask.w, w - 10)
            XCTAssertLessThan(l.field.x + l.field.w, l.ask.x, "the field stops before the button")
            XCTAssertLessThan(l.conversation.y + l.conversation.h, l.statusBaseline - 10, "the conversation is above the status")
            XCTAssertGreaterThanOrEqual(l.conversation.h, 40)
        }
    }

    /// `agent` in dock.ini pins Agent; and a running Agent that is not pinned
    /// wears its own tile, not the generic one, and leaves when it quits.
    /// Off is one file, absent (P18.13): no System ▸ Agent…, no Agent tile.
    func testOffHidesTheMenuItemAndTheTile() {
        XCTAssertTrue(MenuBar.systemMenu(agentsOn: true).commands.contains { $0.verb == "system.agent" })
        XCTAssertFalse(MenuBar.systemMenu(agentsOn: false).commands.contains { $0.verb == "system.agent" })
        XCTAssertEqual(MenuBar.systemMenu(agentsOn: false).commands.count, MenuBar.systemMenu(agentsOn: true).commands.count - 1,
                       "and the rest of the menu does not know the difference")
        withAgents(false) { XCTAssertTrue(Dock.items(tokens: ["agent", "finder"], library: []).map(\.label) == ["Finder"]) }
        withAgents(true) { XCTAssertEqual(Dock.items(tokens: ["agent", "finder"], library: []).map(\.label), ["Agent", "Finder"]) }
    }

    /// Run `body` with a config dir in which agents are on or off.
    func withAgents(_ on: Bool, _ body: () -> Void) {
        var t = Array("/tmp/abyss-agents-XXXXXX".utf8CString)
        let dir = String(cString: mkdtemp(&t)!)
        let old = getenv("ABYSS_CONFIG_DIR").map { String(cString: $0) }
        setenv("ABYSS_CONFIG_DIR", dir, 1)
        if on { _ = Agents.set(true, configDir: dir) }
        body()
        unlink(dir + "/agents.ini"); rmdir(dir)
        if let old { setenv("ABYSS_CONFIG_DIR", old, 1) } else { unsetenv("ABYSS_CONFIG_DIR") }
    }

    func testTheDockKnowsAgent() { withAgents(true) { dockKnowsAgent() } }
    func dockKnowsAgent() {
        let pinned = Dock.items(tokens: ["agent"], library: [])
        XCTAssertEqual(pinned.count, 1)
        XCTAssertEqual(pinned[0].label, "Agent")
        XCTAssertEqual(pinned[0].appID, "org.abyssbsd.agent")
        XCTAssertEqual(pinned[0].environment["AQUA_SCENE"], "agent")
        XCTAssertEqual(pinned[0].pinToken, "agent")
        let running = Dock.builtin(appID: "org.abyssbsd.agent")
        XCTAssertEqual(running?.label, "Agent")
        XCTAssertNil(running?.pinToken, "running, not pinned")
        if case .agent? = running?.icon {} else { XCTFail("a running Agent wears the generic icon") }
        XCTAssertEqual(Dock.builtin(appID: "org.abyssbsd.terminal")?.label, "Terminal")
        XCTAssertNil(Dock.builtin(appID: "org.mozilla.firefox"), "a bundle's app is the library's to name")
    }

    /// Every built-in can be pinned, wears its own icon running, and is the
    /// app ID its window really gives (System Preferences': `.preferences`).
    func testEveryBuiltinHasATile() { withAgents(true) { everyBuiltinHasATile() } }
    func everyBuiltinHasATile() {
        for b in Dock.builtins {
            let pinned = Dock.items(tokens: [b.token], library: [])
            XCTAssertEqual(pinned.first?.label, b.label, b.token)
            XCTAssertEqual(pinned.first?.environment["AQUA_SCENE"], b.scene, b.token)
            let running = Dock.builtin(appID: b.appID)
            XCTAssertEqual(running?.label, b.label, b.appID)
            if case .genericApp? = running?.icon { XCTFail("\(b.label) wears the generic icon") }
            XCTAssertNotNil(Theme.lists["dock.icon.\(b.token)"] ?? (b.token == "sysprefs" ? Theme.lists["dock.icon.prefs"] : nil),
                            "\(b.label) has no icon in the theme")
        }
        XCTAssertEqual(Dock.builtin(appID: "org.abyssbsd.preferences")?.label, "System Preferences",
                       "the app ID System Preferences' window gives")
        XCTAssertNil(Dock.builtin(appID: "org.abyssbsd.prefs"))
        XCTAssertEqual(Set(Dock.builtins.map(\.token)).count, Dock.builtins.count)
        XCTAssertEqual(Set(Dock.builtins.map(\.appID)).count, Dock.builtins.count)
    }

    func testThePickersRowsAreWhereTheyAreDrawn() {
        let area = AgentLayout(w: 560, h: 460).conversation
        let l = AgentPickerLayout(in: area, count: 3)
        XCTAssertEqual(l.rows.count, 3)
        XCTAssertEqual(l.hit(l.rows[2].x + 5, l.rows[2].y + 5), 2)
        XCTAssertNil(l.hit(l.panel.x + 2, l.panel.y + 2), "the heading is not a row")
        XCTAssertTrue(l.rows.allSatisfy { $0.y + $0.h <= l.panel.y + l.panel.h }, "every row inside the panel")
        XCTAssertTrue(zip(l.rows, l.rows.dropFirst()).allSatisfy { $0.y + $0.h <= $1.y }, "rows do not overlap")
    }

    /// Requester 1 (P18.11): which verbs write, said on the wire, and how
    /// the window asks.
    func testWritesAreMarkedAndAsked() throws {
        XCTAssertEqual(textEditMenuBar().commands.filter(\.writes).map(\.verb), [TextEditVerb.save, TextEditVerb.saveAs])
        XCTAssertEqual(Set(finderMenuBar().commands.filter(\.writes).map(\.verb)), ["file.move-to-trash", "finder.empty-trash"])
        let t = AgentAsk.write(app: "TextEdit", verb: "file.save-as", title: "Save As…").text(budget: 0)
        XCTAssertEqual(t.title, "Allow the agent to write with TextEdit?")
        XCTAssertEqual(t.body, "It wants to Save As (file.save-as) in TextEdit: the first time it would write one of your files this session. Allow TextEdit to write for it until the session ends?")
        XCTAssertEqual(t.no, "Don't Allow")
        XCTAssertEqual(AgentAsk.budget("spent").text(budget: 9).yes, "Allow More")
        let h = AgentAsk.host("example.org", url: "https://example.org/a").text(budget: 0)
        XCTAssertEqual(h.title, "Allow the agent to reach example.org?")
        XCTAssertEqual(h.body, "It wants to fetch https://example.org/a: the first time it would reach example.org this session. Allow it to fetch from example.org until the session ends?")
    }

    func testTheBudgetRequester() {
        XCTAssertEqual(agentBudgetQuestion("the session's budget of 500 tokens is spent (600 used)", budget: 500),
                       "The session's budget of 500 tokens is spent (600 used). Let it use another 500 tokens and carry on?")
        let l = AgentRequesterLayout(in: AgentLayout(w: 560, h: 460).conversation)
        XCTAssertLessThan(l.stop.x + l.stop.w, l.allow.x, "Stop, then Allow More: the default last")
        XCTAssertTrue(l.allow.x + l.allow.w <= l.panel.x + l.panel.w && l.allow.y + l.allow.h <= l.panel.y + l.panel.h,
                      "the buttons are inside the panel")
    }

    func testTheMenusSayWhatTheyDo() {
        let verbs = agentMenuBar().menus.flatMap { $0.items }.compactMap { item -> String? in
            if case .command(let c) = item { return c.verb }; return nil
        }
        XCTAssertEqual(verbs, [AgentVerb.about, AgentVerb.quit, AgentVerb.ask, AgentVerb.question, AgentVerb.clear,
                               AgentVerb.giveApp, AgentVerb.give, AgentVerb.takeApp, AgentVerb.take,
                               AgentVerb.allow, AgentVerb.stop, AgentVerb.minimize])
        XCTAssertEqual(agentMenuBar().verb(for: .cmd("q")), AgentVerb.quit)
        XCTAssertEqual(agentMenuBar().verb(for: .cmd("k")), AgentVerb.clear)
    }

    /// Every built-in's bundle names an icon both themes draw: a name that
    /// is not a list drew the generic "A" for System Preferences once.
    func testEveryBuiltinsThemeIconExists() throws {
        let root = "/" + String(#filePath).split(separator: "/").dropLast(3).joined(separator: "/")
        for theme in ["aqua", "trench"] {
            guard let f = fopen(root + "/themes/\(theme)/icons/dock.dl", "r") else { return XCTFail("no \(theme) dock.dl") }
            var lists = Set<String>(), buf = [CChar](repeating: 0, count: 4096)
            while fgets(&buf, Int32(buf.count), f) != nil {
                let l = String(cString: buf)
                if l.hasPrefix("list ") { lists.insert(String(l.dropFirst(5).filter { $0 != "\n" })) }
            }
            fclose(f)
            for b in BuiltinApp.all where b.folder != nil {
                XCTAssertTrue(lists.contains(b.themeIcon), "\(theme) has no \(b.themeIcon) for \(b.name)")
            }
        }
    }

    /// The Dock's built-ins are the shared list's, in its order (P18.13 loose ends).
    func testTheDockBuiltinsAreTheSharedList() {
        XCTAssertEqual(Dock.builtins.map(\.token), BuiltinApp.all.map(\.token))
        XCTAssertEqual(Dock.builtins.map(\.appID), BuiltinApp.all.map(\.appID))
    }

    /// A bundle may name a theme icon; the Finder and the Dock draw the
    /// theme's (P18.13 loose ends). The Applications folder's Utilities is read.
    func testABuiltinsBundleWearsTheThemesIcon() throws {
        var t = Array("/tmp/abyss-apps-XXXXXX".utf8CString)
        let dir = String(cString: mkdtemp(&t)!)
        defer { _ = system("rm -rf '\(dir)'") }
        let b = dir + "/Utilities/Grab.app"
        _ = system("mkdir -p '\(b)/Contents/MacOS' && printf 'dock.icon.grab\\n' > '\(b)/Contents/theme-icon' && printf 'org.abyssbsd.grab\\n' > '\(b)/Contents/app-id'")
        XCTAssertEqual(AppIcon.iconFile(inBundle: b), "theme:dock.icon.grab")
        let lib = AppLibrary.all(in: [dir])
        XCTAssertEqual(lib.map(\.name), ["Grab"], "Utilities is read")
        XCTAssertEqual(lib.first?.icon, "theme:dock.icon.grab")
        XCTAssertTrue(lib.first?.matches(appID: "org.abyssbsd.grab") ?? false)
        let s = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, 64, 64)!, cr = cairo_create(s)!
        defer { cairo_destroy(cr); cairo_surface_destroy(s) }
        XCTAssertTrue(AppIcon.draw(cr, path: "theme:dock.icon.grab", Rect(0, 0, 64, 64)))
        XCTAssertFalse(AppIcon.draw(cr, path: "theme:dock.icon.nothing", Rect(0, 0, 64, 64)), "an icon the theme lacks falls back")
        cairo_surface_flush(s)
        let px = cairo_image_surface_get_data(s)!.withMemoryRebound(to: UInt32.self, capacity: 64 * 64) { p in (0..<(64 * 64)).filter { p[$0] != 0 }.count }
        XCTAssertGreaterThan(px, 500, "the theme's Grab was drawn")
        _ = system("printf 'builtin:grab\\n' > '\(b)/Contents/abyss-appgen'")
        XCTAssertEqual(Dock.pinToken(forBundle: b, library: lib), "grab", "dragged in, it pins the built-in")
    }
}
