// GtkMenus — a GTK application's menus, read as our vocabulary (PHASE10.md P10.6).
//
// GTK exports a `GMenuModel` as `org.gtk.Menus` and its actions as
// `org.gtk.Actions` (spiked in PHASE10 §4.1, on both platforms). This turns the
// first into a `MenuBarModel` and the second into enablement, and runs an
// action when the bar chooses one. The translation is pure where it can be —
// groups in, a model out — so it is tested against the reply a real GTK sent
// in the spike, with no bus.
//
// **What GTK does not give us, said once here so nobody hunts for it:**
//
//   - **Descriptions.** A GMenu item has a label and an action, no sentence.
//     The summary is the label; a script reading a GTK application's
//     vocabulary gets titles, not documentation.
//   - **Argument types.** A parameterised action (`app.open-recent('…')`, a
//     radio item) carries its target in the menu, not a type. Such items are
//     drawn and not bridged: `activate` would need the value, and a vocabulary
//     that guessed it would be lying about what it can do.
//   - **Key equivalents set with `set_accels_for_action`**, which is how most
//     applications set them — they are not in the exported model (§4.1). Only
//     an item that carries an `accel` attribute shows one.

import DBus
import MenuModel

/// One GMenu group as `org.gtk.Menus.Start` returns it: (group, menu, items).
public struct GtkMenuGroup: Equatable, Sendable {
    public let group: UInt32
    public let menu: UInt32
    public let items: [[String: DBusValue]]
    public init(group: UInt32, menu: UInt32, items: [[String: DBusValue]]) {
        self.group = group; self.menu = menu; self.items = items
    }
}

public enum GtkMenus {
    /// A GTK label as a person reads it: `_File` → `File`, `__` → `_`.
    public static func title(_ label: String) -> String {
        var out = ""
        var pendingUnderscore = false
        for c in label {
            if c == "_" {
                if pendingUnderscore { out.append("_"); pendingUnderscore = false }
                else { pendingUnderscore = true }
            } else {
                pendingUnderscore = false
                out.append(c)
            }
        }
        return out
    }

    /// A GTK accelerator (`<Primary>q`, `<Control><Shift>n`) as a key
    /// equivalent, or nil for one we cannot spell. `<Primary>` is ⌘ here: it is
    /// GTK's word for "the platform's command key", which on this desktop is
    /// Command.
    public static func accel(_ s: String) -> KeyEquivalent? {
        var mods: KeyEquivalent.Modifiers = []
        var rest = Substring(s)
        while rest.hasPrefix("<"), let close = rest.firstIndex(of: ">") {
            switch rest[rest.index(after: rest.startIndex)..<close].lowercased() {
            case "primary", "super", "meta": mods.insert(.command)
            case "control", "ctrl":          mods.insert(.control)
            case "shift":                    mods.insert(.shift)
            case "alt", "mod1":              mods.insert(.option)
            default:                         return nil
            }
            rest = rest[rest.index(after: close)...]
        }
        let key: KeyEquivalent.Key
        switch rest.lowercased() {
        case "backspace":   key = .backspace
        case "delete":      key = .forwardDelete
        case "up":          key = .up
        case "down":        key = .down
        case "left":        key = .left
        case "right":       key = .right
        case "return":      key = .enter
        case "escape":      key = .escape
        case "tab":         key = .tab
        default:
            guard rest.count == 1, let c = rest.first else { return nil }
            key = .character(c)
        }
        return KeyEquivalent(key, mods)
    }

    static func string(_ v: DBusValue?) -> String? {
        switch v {
        case .variant(let inner)?: return string(inner)
        case .string(let s)?:      return s
        default:                   return nil
        }
    }

    /// `(group, menu)` from a `:section` or `:submenu` link.
    static func link(_ v: DBusValue?) -> (UInt32, UInt32)? {
        switch v {
        case .variant(let inner)?: return link(inner)
        case .structure(let f)?:
            guard f.count == 2, case .uint32(let g) = f[0], case .uint32(let m) = f[1] else { return nil }
            return (g, m)
        default: return nil
        }
    }

    /// Every group a set of groups links to that it does not itself contain —
    /// what to `Start` next.
    public static func missingGroups(_ groups: [GtkMenuGroup]) -> Set<UInt32> {
        let have = Set(groups.map(\.group))
        var want: Set<UInt32> = []
        for g in groups {
            for item in g.items {
                for key in [":section", ":submenu"] {
                    if let (grp, _) = link(item[key]), !have.contains(grp) { want.insert(grp) }
                }
            }
        }
        return want
    }

    /// The menu `(group, menu)`, flattened: sections inline with a separator
    /// between them, submenus as submenus, items as commands.
    static func menu(_ title: String, _ id: (UInt32, UInt32),
                     _ groups: [GtkMenuGroup], depth: Int = 0) -> Menu {
        guard depth < 8,   // a malformed (or hostile) model that links to itself
              let g = groups.first(where: { $0.group == id.0 && $0.menu == id.1 })
        else { return Menu(title, []) }
        var items: [MenuItem] = []
        for item in g.items {
            if let sec = link(item[":section"]) {
                let inner = menu("", sec, groups, depth: depth + 1).items
                guard !inner.isEmpty else { continue }
                if !items.isEmpty, items.last != .separator { items.append(.separator) }
                items += inner
                items.append(.separator)
            } else if let sub = link(item[":submenu"]) {
                items.append(.submenu(menu(self.title(string(item["label"]) ?? ""), sub,
                                           groups, depth: depth + 1)))
            } else if let action = string(item["action"]) {
                let label = self.title(string(item["label"]) ?? action)
                // A parameterised item gets a verb no action has, so it is
                // drawn, and refused with a reason, rather than bridged wrong.
                let verb = item["target"] == nil ? action : action + GtkMenus.parameterised
                items.append(.command(Command(
                    verb, label, key: string(item["accel"]).flatMap(accel),
                    // GTK has no sentence; the label is the most honest summary.
                    summary: label)))
            }
        }
        while items.first == .separator { items.removeFirst() }
        while items.last == .separator { items.removeLast() }
        return Menu(title, items)
    }

    /// The application's menus: its app menu, if it exported one, under its
    /// name and bold; then the menubar's top-level submenus.
    public static func model(appName: String, menubar: [GtkMenuGroup],
                             appMenu: [GtkMenuGroup]) -> MenuBarModel {
        var menus: [Menu] = []
        let app = menu(appName, (0, 0), appMenu)
        // An application menu is always first, as Jaguar's is; empty when the
        // application exported none, which still names the application.
        menus.append(Menu(appName, app.items))
        for case .submenu(let m) in menu("", (0, 0), menubar).items {
            menus.append(m)
        }
        return MenuBarModel(appName: appName, menus: menus)
    }

    /// `org.gtk.Menus.Start`'s reply as groups.
    public static func groups(fromStartReply body: [DBusValue]) -> [GtkMenuGroup] {
        guard case .array(_, let rows)? = body.first else { return [] }
        return rows.compactMap { row -> GtkMenuGroup? in
            guard case .structure(let f) = row, f.count == 3,
                  case .uint32(let g) = f[0], case .uint32(let m) = f[1],
                  case .array(_, let entries) = f[2] else { return nil }
            let items = entries.compactMap { e -> [String: DBusValue]? in
                guard case .array(_, let kvs) = e else { return nil }
                var d: [String: DBusValue] = [:]
                for kv in kvs {
                    if case .dictEntry(.string(let k), let v) = kv { d[k] = v }
                }
                return d
            }
            return GtkMenuGroup(group: g, menu: m, items: items)
        }
    }

    /// `org.gtk.Actions.DescribeAll`'s reply as name → enabled, with the
    /// prefix (`app.` or `win.`) the menu's actions are named with.
    public static func actions(fromDescribeAll body: [DBusValue], prefix: String) -> [String: Bool] {
        guard case .array(_, let rows)? = body.first else { return [:] }
        var out: [String: Bool] = [:]
        for row in rows {
            guard case .dictEntry(.string(let name), .structure(let f)) = row,
                  case .bool(let enabled)? = f.first else { continue }
            out[prefix + name] = enabled
        }
        return out
    }

    /// Marks a verb whose action needs a parameter the menu carries and we do
    /// not bridge (see the header).
    public static let parameterised = "(…)"

    /// Whether a command can run: the action exists and GTK says it is enabled.
    public static func enablement(_ c: Command, actions: [String: Bool]) -> Enablement {
        if c.verb.hasSuffix(parameterised) {
            return .disabled("a parameterised action, which the bridge does not carry yet")
        }
        guard let on = actions[c.verb] else {
            return .disabled("the application has no action \(c.verb)")
        }
        return on ? .enabled : .disabled("the application has disabled it")
    }
}
