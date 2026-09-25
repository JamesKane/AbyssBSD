// ContextMenu — the menu under a right-click (PHASE10.md P10.8).
//
// A contextual menu is not a second list of things an application can do. It
// is a **selection of the same `Command`s** its menus already define, shown at
// the pointer — so a right-click and the menu bar can never disagree about what
// "Duplicate" is called, what key it has, or whether it can run. The Finder's
// contextual menus are built from `finderMenuBar()` by verb; the Dock and the
// desktop define the few commands they have the same way.
//
// Every row is logged with its offset **inside the popup**. Where the popup
// lands on screen is the compositor's decision — at the pointer, or flipped
// above a Dock tile — and undertow logs it when the popup maps; a test adds the
// two and has no coordinate of its own (§2.46).

import Surface

public final class ContextMenu {
    public let menu: AquaMenu
    public let popup: Popup

    private init(menu: AquaMenu, popup: Popup) { self.menu = menu; self.popup = popup }

    /// Open `menu` at the pointer. `open` makes the popup (a window's, or a
    /// layer surface's) anchored at the click; `choose` runs a command.
    /// `onClose` is called when it goes away, chosen or not.
    public static func open(_ menu: Menu, name: String,
                            enablement: (Command) -> Enablement,
                            log: (String) -> Void,
                            open: (_ width: Int32, _ height: Int32, AquaMenu) -> Popup?,
                            choose: @escaping (Command) -> Void,
                            onClose: @escaping () -> Void) -> ContextMenu? {
        let rows = aquaMenuItems(menu, enablement: enablement)
        guard !rows.isEmpty else { return nil }
        let commands = Dictionary(menu.commands.map { ($0.verb, $0) }, uniquingKeysWith: { a, _ in a })
        let am = AquaMenu(items: rows)
        let w = Int32(max(150, am.preferredWidth))
        let h = Int32(am.preferredHeight.rounded(.up))
        guard let pop = open(w, h, am) else { return nil }
        am.popup = pop
        am.onChoose = { idx in
            pop.close()
            onClose()
            if let verb = rows[idx].verb, let c = commands[verb] { choose(c) }
        }
        am.onDismiss = { onClose() }
        log("context menu \(name)")
        for (row, geo) in zip(rows, aquaMenuRows(rows)) where !row.isSeparator {
            let state = row.enabled ? "enabled" : "disabled"
            log("context item '\(row.title)' at +30,+\(Int(geo.y + geo.h / 2)) "
                + "\(state)\(row.verb.map { " \($0)" } ?? "")")
        }
        return ContextMenu(menu: am, popup: pop)
    }

    public func close() { popup.close() }
}
