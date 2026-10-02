// The menu bar's island item (PHASE13 P13.4): where you are, and every
// island's windows — the fourth member of PRODUCT §7.3's set, with the Dock.
// Once a window can be somewhere you are not, something on screen must always
// know where it is; this menu is that, for every window at once.
//
// Pure: the bar asks the compositor for the list when the menu opens
// (`abyss_menubar_v1.list_islands`) and builds the menu here.

import MenuWire
import Surface

public enum IslandMenu {
    /// What a chosen row asks for.
    public enum Action: Equatable, Sendable {
        case switchTo(Int)
        case window(UInt32)
        /// Shoals (P13.6): a shoal command for the compositor.
        case shoal(String, UInt32)
    }

    /// One row per island of `display`, the one shown ticked; under each, its
    /// windows, indented. Choosing an island goes there; choosing a window
    /// goes to it, wherever it is (the Dock's rule).
    public static func build(display: String, active: Int, count: Int, names: [String],
                             windows: [MenuBarFocus.IslandWindow],
                             shoals: [MenuBarFocus.ShoalInfo] = [],
                             agents: [AgentPresence] = []) -> Menu {
        var items: [MenuItem] = []
        for n in 1...max(count, 1) {
            let name = n <= names.count && !names[n - 1].isEmpty ? names[n - 1] : "\(n)"
            let title = (n == active ? "✓ " : "    ") + (name == "\(n)" ? "Island \(n)" : name)
            items.append(.command(Command("island.switch.\(n)", title,
                                          key: n <= 9 ? KeyEquivalent(.character(Character("\(n)")), .control) : nil,
                                          summary: "Show island \(n) on this display.")))
            for w in windows where w.display == display && w.island == n {
                var label = w.title.isEmpty ? w.appID : w.title
                // An agent session's window says its state (PHASE18 P18.13b),
                // matched by the process that owns it.
                if w.pid > 0, let a = agents.first(where: { $0.pid == w.pid }) { label += " — " + a.state.words }
                items.append(.command(Command("island.window.\(w.id)", "        " + label,
                                              summary: "Go to this window.")))
            }
        }
        // Shoals (P13.6): this island's, each recalled by its row; then what
        // the front window can do.
        let here = shoals.filter { $0.display == display && $0.island == active }
        items.append(.separator)
        for s in here {
            items.append(.command(Command("shoal.recall.\(s.index)", "Recall \(s.name) (\(s.open))",
                                          summary: "Bring this shoal's windows to the front together.")))
        }
        items.append(.command(Command("shoal.new.0", "New Shoal from Front Window",
                                      summary: "Make a shoal of the front window.")))
        if !here.isEmpty {
            items.append(.submenu(Menu("Add Front Window To", here.map { s in
                .command(Command("shoal.add.\(s.index)", s.name, summary: "Add the front window to this shoal."))
            })))
        }
        items.append(.command(Command("shoal.remove.0", "Remove Front Window from Its Shoal",
                                      summary: "Take the front window out of its shoal.")))
        items.append(.command(Command("shoal.strip.0", "Show or Hide the Strip",
                                      summary: "The shoals of this island, down the left edge.")))
        return Menu("Islands", items)
    }

    public static func action(_ verb: String) -> Action? {
        if verb.hasPrefix("island.switch."), let n = Int(verb.dropFirst("island.switch.".count)) {
            return .switchTo(n)
        }
        if verb.hasPrefix("island.window."), let id = UInt32(verb.dropFirst("island.window.".count)) {
            return .window(id)
        }
        // shoal.VERB.ARG
        let p = verb.split(separator: ".")
        if p.count == 3, p[0] == "shoal", ["recall", "new", "add", "remove", "strip"].contains(String(p[1])),
           let a = UInt32(p[2]) {
            return .shoal(String(p[1]), a)
        }
        return nil
    }
}
