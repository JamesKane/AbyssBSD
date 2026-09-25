// Commands — where `MenuModel` meets the toolkit (PHASE10.md P10.1).
//
// Two translations, both pure: a key event into the `KeyEquivalent` a command
// table is keyed by, and a `Menu` into the rows an `AquaMenu` draws. Neither
// knows which application it is serving, which is the point — the Finder, the
// menu bar and the Dock all go through the same two functions.

import Surface

/// The key equivalent a key press spells, or nil if the key cannot be one.
///
/// The character comes from the **layout-resolved** keysym, lowercased, with
/// Shift kept as a modifier: ⌘⇧N arrives as keysym `N` with Shift held and is
/// `.cmd("n", .shift)`. That is right for letters and wrong for shifted
/// punctuation — on a US layout ⇧3 is `numbersign` — so a model must not bind
/// ⇧⌘3-style equivalents until this tries the unshifted symbol too, as the
/// compositor's table does (PHASE9 P9.5). Caps Lock is ignored for the same
/// reason the compositor ignores it: a table that saw it would disable every
/// shortcut the moment somebody left it on.
public func keyEquivalent(keysym: UInt32, modifiers: KeyModifiers) -> KeyEquivalent? {
    let key: KeyEquivalent.Key
    switch keysym {
    case KeySym.backspace:          key = .backspace
    case KeySym.delete:             key = .forwardDelete
    case KeySym.up:                 key = .up
    case KeySym.down:               key = .down
    case KeySym.left:               key = .left
    case KeySym.right:              key = .right
    case KeySym.enter:              key = .enter
    case KeySym.escape:             key = .escape
    case KeySym.tab, KeySym.backTab: key = .tab
    case 0x21...0x7e:
        guard let scalar = UnicodeScalar(keysym) else { return nil }
        key = .character(Character(scalar))
    default:
        return nil
    }
    var m: KeyEquivalent.Modifiers = []
    if modifiers.contains(.command) { m.insert(.command) }
    if modifiers.contains(.shift)   { m.insert(.shift) }
    if modifiers.contains(.alt)     { m.insert(.option) }
    if modifiers.contains(.control) { m.insert(.control) }
    return KeyEquivalent(key, m)
}

public func keyEquivalent(_ event: KeyEvent) -> KeyEquivalent? {
    keyEquivalent(keysym: event.keysym, modifiers: event.modifiers)
}

/// One row of a drawn menu.
public struct AquaMenuItem: Equatable, Sendable {
    public var title: String
    /// Right-aligned, as Jaguar draws it: `⇧⌘N`. Empty for none.
    public var keyText: String
    public var enabled: Bool
    public var isSeparator: Bool
    /// Draws the ▸ that says a submenu opens here.
    public var hasSubmenu: Bool
    /// The command this row runs, when it came from a `Menu`.
    public var verb: String?

    public init(_ title: String, keyText: String = "", enabled: Bool = true,
                hasSubmenu: Bool = false, verb: String? = nil) {
        self.title = title; self.keyText = keyText; self.enabled = enabled
        self.isSeparator = false; self.hasSubmenu = hasSubmenu; self.verb = verb
    }

    public static let separator: AquaMenuItem = {
        var s = AquaMenuItem("")
        s.isSeparator = true
        s.enabled = false
        return s
    }()

    /// A row that can be highlighted and chosen.
    public var isChoosable: Bool { enabled && !isSeparator }
}

/// A `Menu`'s rows, each command's enablement asked of `enablement`. A submenu
/// is a row with an arrow; it is enabled when anything inside it is.
public func aquaMenuItems(_ menu: Menu,
                          enablement: (Command) -> Enablement) -> [AquaMenuItem] {
    menu.items.map { item in
        switch item {
        case .command(let c):
            return AquaMenuItem(c.title, keyText: c.key?.display ?? "",
                                enabled: enablement(c).isEnabled, verb: c.verb)
        case .separator:
            return .separator
        case .submenu(let m):
            let anyEnabled = m.commands.contains { enablement($0).isEnabled }
            return AquaMenuItem(m.title, enabled: anyEnabled, hasSubmenu: true)
        }
    }
}

public enum AquaMenuMetrics {
    public static let itemHeight = 20.0
    public static let separatorHeight = 12.0
    public static let padV = 4.0
    public static let titleX = 22.0
    /// Space between the longest title and the key column, and the key column's
    /// right inset.
    public static let keyGap = 28.0
    public static let rightInset = 14.0
}

/// Where each row sits: its top and height. One function feeds paint and
/// hit-test (§2.9), because separators make rows different heights and a
/// hit-test that assumed otherwise would choose the row below the one drawn.
public func aquaMenuRows(_ items: [AquaMenuItem]) -> [(y: Double, h: Double)] {
    var y = AquaMenuMetrics.padV
    return items.map { item in
        let h = item.isSeparator ? AquaMenuMetrics.separatorHeight
                                 : AquaMenuMetrics.itemHeight
        defer { y += h }
        return (y, h)
    }
}

public func aquaMenuHeight(_ items: [AquaMenuItem]) -> Double {
    let rows = aquaMenuRows(items)
    let bottom = rows.last.map { $0.y + $0.h } ?? AquaMenuMetrics.padV
    return bottom + AquaMenuMetrics.padV
}

/// The row under `y`, if it is one that can be chosen.
public func aquaMenuRow(atY y: Double, _ items: [AquaMenuItem]) -> Int? {
    for (i, r) in aquaMenuRows(items).enumerated() where y >= r.y && y < r.y + r.h {
        return items[i].isChoosable ? i : nil
    }
    return nil
}

/// The next choosable row from `from` in `step`'s direction, wrapping; nil if
/// there is none. `from == nil` starts before the first (or after the last).
/// Disabled rows and separators are skipped, as Jaguar skips them.
public func aquaMenuStep(from: Int?, step: Int, _ items: [AquaMenuItem]) -> Int? {
    let n = items.count
    guard n > 0 else { return nil }
    var i = from ?? (step > 0 ? -1 : n)
    for _ in 0..<n {
        i = ((i + step) % n + n) % n
        if items[i].isChoosable { return i }
    }
    return nil
}
