// MenuModel — what an application can do, as a value (PHASE10.md P10.1).
//
// A `Command` is one definition with two routes: the key handler looks its key
// equivalent up here, and the menu is drawn from here, so the two can never
// disagree about what ⌘D means. It is also the *vocabulary* PHASE10 §1 is about:
// a stable verb, a sentence of description and typed arguments are what a
// script or an agent reads (PRODUCT.md §5.5), and they cost nothing to carry
// from the start.
//
// Deliberately dependency-free — no cairo, no Wayland, no toolkit — so the menu
// wire (P10.2) and a command-line client can link it without linking an
// application. Enablement is not in here: whether a command can run *now* is a
// question only the running application can answer (`Enablement`).

/// A key equivalent: the key and the modifiers that must be held with it.
///
/// Matching is **exact** on modifiers, the rule the compositor's keybind table
/// already uses (PHASE9 P9.5): ⌘D and ⇧⌘D are different keystrokes.
public struct KeyEquivalent: Hashable, Sendable {
    public struct Modifiers: OptionSet, Hashable, Sendable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }
        public static let command = Modifiers(rawValue: 1 << 0)
        public static let shift   = Modifiers(rawValue: 1 << 1)
        public static let option  = Modifiers(rawValue: 1 << 2)
        public static let control = Modifiers(rawValue: 1 << 3)
    }

    /// The key. A character is stored lowercased — Shift is a modifier, not a
    /// different letter — so ⇧⌘N is `.character("n")` with `.shift`.
    public enum Key: Hashable, Sendable {
        case character(Character)
        case backspace          // ⌫, the key Mac calls Delete
        case forwardDelete      // ⌦
        case up, down, left, right
        case enter, escape, tab
    }

    public let key: Key
    public let modifiers: Modifiers

    public init(_ key: Key, _ modifiers: Modifiers = .command) {
        if case .character(let c) = key {
            self.key = .character(Character(c.lowercased()))
        } else {
            self.key = key
        }
        self.modifiers = modifiers
    }

    /// ⌘ plus a character, the common case: `.cmd("d")`, `.cmd("n", .shift)`.
    public static func cmd(_ c: Character, _ extra: Modifiers = []) -> KeyEquivalent {
        KeyEquivalent(.character(c), extra.union(.command))
    }

    /// ⌘ plus a named key: `.cmd(.backspace)`.
    public static func cmd(_ k: Key, _ extra: Modifiers = []) -> KeyEquivalent {
        KeyEquivalent(k, extra.union(.command))
    }

    /// How a menu shows it, in the order the Mac draws modifiers — ⌃⌥⇧⌘ — then
    /// the key: `⇧⌘N`, `⌘⌫`, `⌘↑`.
    public var display: String {
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option)  { s += "⌥" }
        if modifiers.contains(.shift)   { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        switch key {
        case .character(let c): s += c.uppercased()
        case .backspace:        s += "⌫"
        case .forwardDelete:    s += "⌦"
        case .up:               s += "↑"
        case .down:             s += "↓"
        case .left:             s += "←"
        case .right:            s += "→"
        case .enter:            s += "↩"
        case .escape:           s += "⎋"
        case .tab:              s += "⇥"
        }
        return s
    }
}

/// The type of one argument a verb takes. Small on purpose: this is what a
/// script has to be able to supply, not a type system.
public enum ArgumentType: String, Sendable, CaseIterable {
    case string, path, integer, bool
}

public struct Argument: Equatable, Sendable {
    public let name: String
    public let type: ArgumentType
    public let summary: String
    public init(_ name: String, _ type: ArgumentType, _ summary: String) {
        self.name = name; self.type = type; self.summary = summary
    }
}

/// One thing an application can do.
public struct Command: Equatable, Sendable {
    /// Stable, never localised, what a script says: `file.duplicate`.
    public let verb: String
    /// What a person reads: `Duplicate`.
    public let title: String
    /// Shown in the menu, and answered by the key handler.
    public let key: KeyEquivalent?
    /// Also answered, never shown — ⌘↓ opens as well as ⌘O.
    public let alternateKeys: [KeyEquivalent]
    public let arguments: [Argument]
    /// One sentence: what it does. For a reader that cannot see the menu.
    public let summary: String

    public init(_ verb: String, _ title: String, key: KeyEquivalent? = nil,
                alternateKeys: [KeyEquivalent] = [], arguments: [Argument] = [],
                summary: String) {
        self.verb = verb; self.title = title; self.key = key
        self.alternateKeys = alternateKeys; self.arguments = arguments
        self.summary = summary
    }

    /// Every key that runs this command, shown one first.
    public var allKeys: [KeyEquivalent] { (key.map { [$0] } ?? []) + alternateKeys }
}

public indirect enum MenuItem: Equatable, Sendable {
    case command(Command)
    case separator
    case submenu(Menu)
}

public struct Menu: Equatable, Sendable {
    public let title: String
    public let items: [MenuItem]
    public init(_ title: String, _ items: [MenuItem]) {
        self.title = title; self.items = items
    }

    /// Every command in this menu and its submenus, in menu order.
    public var commands: [Command] {
        items.flatMap { item -> [Command] in
            switch item {
            case .command(let c): return [c]
            case .separator:      return []
            case .submenu(let m): return m.commands
            }
        }
    }
}

/// An application's menus: what goes to the right of the system menu, the first
/// being the bold application menu.
public struct MenuBarModel: Equatable, Sendable {
    public let appName: String
    public let menus: [Menu]
    public init(appName: String, menus: [Menu]) {
        self.appName = appName; self.menus = menus
    }

    public var commands: [Command] { menus.flatMap(\.commands) }

    public func command(_ verb: String) -> Command? {
        commands.first { $0.verb == verb }
    }

    /// The verb a key runs, if any. **This is the whole key handler**: an
    /// application that asks this instead of switching on keysyms has one
    /// definition of each command, and its menu is that definition drawn.
    public func verb(for press: KeyEquivalent) -> String? {
        commands.first { $0.allKeys.contains(press) }?.verb
    }

    /// Keys claimed by more than one command — each would silently run only the
    /// first. Empty in a well-formed model; a test asserts it.
    public var conflictingKeys: [KeyEquivalent] {
        var seen: Set<KeyEquivalent> = [], dup: [KeyEquivalent] = []
        for k in commands.flatMap(\.allKeys) where !seen.insert(k).inserted {
            dup.append(k)
        }
        return dup
    }

    /// Verbs that appear more than once. A verb names one thing.
    public var duplicateVerbs: [String] {
        var seen: Set<String> = [], dup: [String] = []
        for v in commands.map(\.verb) where !seen.insert(v).inserted { dup.append(v) }
        return dup
    }
}

/// Whether a command can run now, and if not, why — the reason is for a script,
/// which cannot see a greyed-out item.
public enum Enablement: Equatable, Sendable {
    case enabled
    case disabled(String)

    public var isEnabled: Bool { self == .enabled }
}

/// What running a command produced. Not `Void`: a script needs to know whether
/// it worked and what it made (PHASE10 P10.2).
public enum CommandResult: Equatable, Sendable {
    case ok(String?)
    case refused(String)
}
