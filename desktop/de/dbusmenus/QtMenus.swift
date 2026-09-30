// QtMenus — a Qt/KDE application's menus, read as our vocabulary (PHASE10.md P10.7).
//
// Qt exports its menu bar as `com.canonical.dbusmenu` — once somebody owns
// `com.canonical.AppMenu.Registrar` — and tells the compositor where through
// `org_kde_kwin_appmenu` (spiked in PHASE10 §4.5 against stock kcalc). This turns
// `GetLayout` into a `MenuBarModel`, and runs an item with `Event(…"clicked"…)`.
//
// **Verbs are the menu path, not the item id.** dbusmenu ids are integers the
// application may renumber at will — kcalc rebuilt its whole menubar under a
// live window in the spike — so a verb built from one would change between a
// script reading the vocabulary and running it. `edit.undo` does not. The id
// is found again, by verb, from a fresh layout at the moment of activation.
//
// Compared with GTK (GtkMenus.swift), dbusmenu gives more: **real shortcuts**
// and enablement live in the model. Still absent: descriptions (the summary is
// the label) and argument types (dbusmenu items take none — a radio item is
// its own verb, which is honest). Toggle state is read and not yet drawn.

import DBus
import MenuModel

/// One dbusmenu node: `(i id, a{sv} properties, av children)`.
public struct DBusMenuNode: Equatable, Sendable {
    public let id: Int32
    public let properties: [String: DBusValue]
    public let children: [DBusMenuNode]
}

public enum QtMenus {
    /// `GetLayout`'s reply → its root node.
    public static func root(fromGetLayout body: [DBusValue]) -> DBusMenuNode? {
        guard body.count >= 2 else { return nil }
        return node(body[1])
    }

    static func node(_ v: DBusValue) -> DBusMenuNode? {
        var v = v
        if case .variant(let inner) = v { v = inner }
        guard case .structure(let f) = v, f.count == 3, case .int32(let id) = f[0],
              case .array(_, let kvs) = f[1], case .array(_, let kids) = f[2] else { return nil }
        var props: [String: DBusValue] = [:]
        for kv in kvs { if case .dictEntry(.string(let k), let val) = kv { props[k] = val } }
        return DBusMenuNode(id: id, properties: props, children: kids.compactMap(node))
    }

    static func unwrap(_ v: DBusValue?) -> DBusValue? {
        if case .variant(let inner)? = v { return unwrap(inner) }
        return v
    }
    static func string(_ n: DBusMenuNode, _ k: String) -> String? {
        if case .string(let s)? = unwrap(n.properties[k]) { return s }
        return nil
    }
    static func bool(_ n: DBusMenuNode, _ k: String, default d: Bool) -> Bool {
        if case .bool(let b)? = unwrap(n.properties[k]) { return b }
        return d
    }

    static func isSeparator(_ n: DBusMenuNode) -> Bool { string(n, "type") == "separator" }
    static func isSubmenu(_ n: DBusMenuNode) -> Bool {
        string(n, "children-display") == "submenu" || !n.children.isEmpty
    }
    static func visible(_ n: DBusMenuNode) -> Bool { bool(n, "visible", default: true) }
    public static func enabled(_ n: DBusMenuNode) -> Bool { bool(n, "enabled", default: true) }

    /// Submenus that say they have children and show none — dbusmenu's lazy
    /// menus, which fill in only after `AboutToShow(id)`.
    public static func lazySubmenus(_ n: DBusMenuNode) -> [Int32] {
        var out: [Int32] = []
        for c in n.children where visible(c) {
            if string(c, "children-display") == "submenu", c.children.isEmpty { out.append(c.id) }
            out += lazySubmenus(c)
        }
        return out
    }

    /// `[['Control','Shift','Z']]` → ⌃⇧Z. The first chord only; a multi-chord
    /// shortcut has no Mac spelling. **Control stays Control**: the application
    /// listens for Ctrl, and drawing it as ⌘ would show a key that does not
    /// work — ⌘Q is the compositor's (P9.5).
    public static func shortcut(_ v: DBusValue?) -> KeyEquivalent? {
        guard case .array(_, let chords)? = unwrap(v), case .array(_, let parts)? = chords.first
        else { return nil }
        var mods: KeyEquivalent.Modifiers = []
        var key: KeyEquivalent.Key?
        for p in parts {
            guard case .string(let s) = p else { return nil }
            switch s {
            case "Control": mods.insert(.control)
            case "Shift":   mods.insert(.shift)
            case "Alt":     mods.insert(.option)
            case "Super":   mods.insert(.command)
            case "Backspace": key = .backspace
            case "Delete":    key = .forwardDelete
            case "Up": key = .up
            case "Down": key = .down
            case "Left": key = .left
            case "Right": key = .right
            case "Return", "Enter": key = .enter
            case "Escape": key = .escape
            case "Tab": key = .tab
            default:
                guard s.count == 1, let c = s.first else { return nil }
                key = .character(c)
            }
        }
        return key.map { KeyEquivalent($0, mods) }
    }

    /// A label as a verb component: `Show _History` → `show-history`.
    static func slug(_ label: String) -> String {
        var out = ""
        var dash = false
        for ch in GtkMenus.title(label).lowercased() {
            if ch.isLetter || ch.isNumber { out.append(ch); dash = false }
            else if !dash, !out.isEmpty { out.append("-"); dash = true }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return out.isEmpty ? "item" : out
    }

    /// The model, and which dbusmenu id each verb is right now.
    public static func model(appName: String, root: DBusMenuNode)
        -> (model: MenuBarModel, ids: [String: Int32], enabled: [String: Bool]) {
        var ids: [String: Int32] = [:]
        var enabled: [String: Bool] = [:]

        func items(_ n: DBusMenuNode, path: String) -> [MenuItem] {
            var out: [MenuItem] = []
            for c in n.children where visible(c) {
                if isSeparator(c) {
                    if !out.isEmpty, out.last != .separator { out.append(.separator) }
                    continue
                }
                let label = string(c, "label") ?? ""
                let here = path + "." + slug(label)
                if isSubmenu(c) {
                    out.append(.submenu(Menu(GtkMenus.title(label), items(c, path: here))))
                    continue
                }
                var verb = here
                var n = 2
                while ids[verb] != nil { verb = "\(here)-\(n)"; n += 1 }
                ids[verb] = c.id
                enabled[verb] = self.enabled(c)
                let title = GtkMenus.title(label)
                out.append(.command(Command(verb, title, key: shortcut(c.properties["shortcut"]),
                                            summary: title)))
            }
            while out.last == .separator { out.removeLast() }
            return out
        }

        var menus = [Menu(appName, [])]   // the application menu first, as Jaguar's is
        for top in root.children where visible(top) && isSubmenu(top) {
            let label = string(top, "label") ?? ""
            menus.append(Menu(GtkMenus.title(label), items(top, path: slug(label))))
        }
        return (MenuBarModel(appName: appName, menus: menus), ids, enabled)
    }

    public static func appName(_ applicationID: String) -> String {
        applicationID.split(separator: ".").last.map(String.init) ?? applicationID
    }
}
