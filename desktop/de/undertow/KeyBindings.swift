// Undertow — the keybind table (PHASE9.md P9.5).
//
// The compositor is the only thing that can hear a key before the focused
// application does, so shortcuts that belong to the *desktop* — switch windows,
// close this one, take a picture of the screen — have to be decided here or not
// at all. Until this pass `Seat` forwarded every key straight to
// `wlr_seat_keyboard_notify_key`, which is why Cmd-Tab did nothing.
//
// **The match is a pure function**, for the same reason `PointerRouting.hit`
// and `WindowSnap.zone` are (§2.9): the rule that decides what a key *does* is
// exactly the kind of thing that must be checkable without a running desktop,
// and exactly the kind of thing whose corner cases (a bound key with an extra
// modifier held; a bound key an application is allowed to keep) are miserable to
// drive through a live compositor.

import PoolConfig

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// The modifiers a binding can name. Values are wlroots' own mask bits.
///
/// Caps Lock and Num Lock are deliberately absent: they are *states*, not
/// modifiers a person holds, and a table that distinguished them would make
/// every shortcut stop working the moment somebody left Caps Lock on.
public struct KeyModifiers: OptionSet, Sendable, Hashable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public static let shift = KeyModifiers(rawValue: 1)
    public static let ctrl  = KeyModifiers(rawValue: 4)
    public static let alt   = KeyModifiers(rawValue: 8)
    /// The Logo/Super key, which on this desktop is **Command**.
    public static let cmd   = KeyModifiers(rawValue: 64)

    /// The bits a binding may name, so lock states never enter a comparison.
    public static let meaningful: KeyModifiers = [.shift, .ctrl, .alt, .cmd]
    public func normalized() -> KeyModifiers { intersection(.meaningful) }
}

/// What a bound key does.
/// Ctrl-Alt-F*n*: the virtual terminal it asks for, or nil.
///
/// Not a binding in the table, because it is not the desktop's to rebind: it is
/// how a person leaves the desktop for a text console, and on the live medium
/// it is the *only* way to a command line (the metal box had no other; the
/// address it printed at boot was under the desktop). xkb's `pc` symbols
/// already turn Ctrl-Alt-F*n* into `XF86Switch_VT_n`, so this is a range check
/// on the translated symbol, and any layout that keeps those symbols works.
public enum VTSwitch {
    static let first: UInt32 = 0x1008FE01   // XKB_KEY_XF86Switch_VT_1
    static let last: UInt32 = 0x1008FE0C    // XKB_KEY_XF86Switch_VT_12

    public static func vt(for syms: [UInt32]) -> UInt32? {
        for s in syms where s >= first && s <= last { return s - first + 1 }
        return nil
    }
}

public enum KeyAction: Equatable, Sendable {
    case nextWindow
    case previousWindow
    case closeWindow
    /// Close every window belonging to the focused application, which is what
    /// Cmd-Q means on a Mac and is not the same thing as closing a window.
    case quitApplication
    /// Run a command, detached. **Every hardware key is one of these** — volume
    /// and brightness go out through `ventsctl`, so the compositor needs no
    /// dependency on the hardware bridges to answer a volume key, and a person
    /// can bind anything else the same way.
    case run([String])
    /// Islands (PHASE13 P13.1): show island N; step one way or the other,
    /// wrapping; send the focused window to island N, and go with it or not.
    case island(Int)
    case islandStep(Int)
    case moveToIsland(Int, follow: Bool)
    /// Ebb (P13.5): open in a scope, or put the tide back.
    case ebb(EbbScope)
    /// Shoals (P13.6): make one of the focused window, add it to the
    /// current one, take it out, recall this island's Nth, show the strip.
    case shoalNew, shoalAdd, shoalRemove
    case shoalRecall(Int)
    case shoalStrip
}

/// One row of the table.
public struct KeyBinding: Equatable, Sendable {
    public let sym: UInt32
    public let modifiers: KeyModifiers
    public let action: KeyAction
    public init(sym: UInt32, modifiers: KeyModifiers, action: KeyAction) {
        self.sym = sym
        self.modifiers = modifiers.normalized()
        self.action = action
    }
}

/// The table, and the rule that reads it.
public struct KeyBindings: Sendable {
    public private(set) var bindings: [KeyBinding] = []
    /// app_id → the bindings that application keeps for itself. See §6.2.
    public private(set) var passthrough: [String: [KeyBinding]] = [:]

    public init(bindings: [KeyBinding] = [], passthrough: [String: [KeyBinding]] = [:]) {
        self.bindings = bindings
        self.passthrough = passthrough
    }

    /// The action for a keystroke, or nil to let the client have it.
    ///
    /// **Modifiers must match exactly** (after masking off the lock states).
    /// Cmd-Q and Cmd-Shift-Q are different keystrokes, and a table that treated
    /// "at least these modifiers" as a match would swallow the second one.
    public func match(sym: UInt32, modifiers: KeyModifiers,
                      focusedAppID: String? = nil) -> KeyAction? {
        let mods = modifiers.normalized()
        guard let hit = bindings.first(where: { $0.sym == sym && $0.modifiers == mods })
        else { return nil }
        // **§6.2: an application may keep a combination.** A terminal that
        // cannot receive Cmd-Q is a terminal that cannot run a program that
        // wants it, and Phase 15 will have one. The list is per application and
        // lives in the table, so the decision is data rather than a special case
        // in the compositor — and `*` lets one application opt out of the whole
        // table, which is what a remote desktop or a virtual machine window
        // eventually needs.
        if let app = focusedAppID, let kept = passthrough[app] {
            if kept.contains(where: { $0.sym == hit.sym && $0.modifiers == hit.modifiers }) {
                return nil
            }
        }
        if let app = focusedAppID, passthrough[app]?.isEmpty == true { return nil }
        return hit.action
    }
}

// MARK: - Reading the table

public enum KeyBindingParser {
    /// Turn `"Cmd+Shift+3"` into modifiers and a keysym.
    ///
    /// Case-insensitive on the modifier names and forgiving about spaces,
    /// because this is a file a person edits. The key name itself is passed to
    /// xkb untouched first — X keysym names are case-sensitive (`a` and `A` are
    /// different symbols) — and only then retried capitalised, so `tab` works
    /// and `A` still means Shift-a's symbol.
    public static func parse(spec: String,
                             keysym: (String) -> UInt32?) -> (KeyModifiers, UInt32)? {
        var mods: KeyModifiers = []
        var name: String? = nil
        for rawPart in spec.split(separator: "+") {
            let part = rawPart.trimmingWhitespace()
            guard !part.isEmpty else { return nil }
            switch part.lowercased() {
            case "cmd", "command", "super", "logo", "meta": mods.insert(.cmd)
            case "shift":                                   mods.insert(.shift)
            case "ctrl", "control":                         mods.insert(.ctrl)
            case "alt", "option", "opt":                    mods.insert(.alt)
            default:
                // Two key names in one spec is a typo, not a chord.
                guard name == nil else { return nil }
                name = part
            }
        }
        guard let keyName = name else { return nil }
        if let s = keysym(keyName), s != 0 { return (mods, s) }
        let capitalised = keyName.prefix(1).uppercased() + keyName.dropFirst()
        if let s = keysym(capitalised), s != 0 { return (mods, s) }
        return nil
    }

    public static func parse(action: String) -> KeyAction? {
        let a = action.trimmingWhitespace()
        switch a.lowercased() {
        case "next-window":     return .nextWindow
        case "previous-window": return .previousWindow
        case "close-window":    return .closeWindow
        case "quit-app":        return .quitApplication
        case "shoal new":       return .shoalNew
        case "shoal add":       return .shoalAdd
        case "shoal remove":    return .shoalRemove
        case "shoal strip":     return .shoalStrip
        case "ebb island":      return .ebb(.island)
        case "ebb archipelago": return .ebb(.archipelago)
        case "ebb app":         return .ebb(.app)
        case "island next":     return .islandStep(1)
        case "island previous": return .islandStep(-1)
        default:
            // `island N`, `move-to-island N`, `move-to-island N follow`.
            let w = a.lowercased().split(separator: " ")
            if w.count == 2, w[0] == "island", let n = Int(w[1]), n >= 1, n <= 9 { return .island(n) }
            if w.count == 3, w[0] == "shoal", w[1] == "recall", let n = Int(w[2]), n >= 1, n <= 9 { return .shoalRecall(n) }
            if w.count >= 2, w.count <= 3, w[0] == "move-to-island", let n = Int(w[1]), n >= 1, n <= 9 {
                if w.count == 3 { return w[2] == "follow" ? .moveToIsland(n, follow: true) : nil }
                return .moveToIsland(n, follow: false)
            }
            // `run: cmd arg arg`. Deliberately not a shell — no quoting, no
            // globbing, no `rm -rf $HOME` from a stray semicolon in a config
            // file the desktop reads at every keystroke.
            guard a.lowercased().hasPrefix("run:") else { return nil }
            let words = a.dropFirst(4).split(separator: " ").map(String.init)
                         .filter { !$0.isEmpty }
            return words.isEmpty ? nil : .run(words)
        }
    }

    /// The whole table, out of a `Config`.
    ///
    /// `[keys]` is `spec = action`; `[passthrough]` is `app_id = spec spec …`,
    /// where an empty value means "this application keeps everything".
    public static func table(from config: Config,
                             keysym: (String) -> UInt32?) -> KeyBindings {
        var rows: [KeyBinding] = []
        for (spec, action) in config.pairs("keys") {
            guard let (mods, sym) = parse(spec: spec, keysym: keysym),
                  let act = parse(action: action) else { continue }
            rows.append(KeyBinding(sym: sym, modifiers: mods, action: act))
        }
        var kept: [String: [KeyBinding]] = [:]
        for (app, specs) in config.pairs("passthrough") {
            var list: [KeyBinding] = []
            for spec in specs.split(separator: " ") {
                let s = String(spec)
                if s == "*" { list = []; break }
                guard let (mods, sym) = parse(spec: s, keysym: keysym) else { continue }
                list.append(KeyBinding(sym: sym, modifiers: mods, action: .closeWindow))
            }
            kept[app] = list
        }
        return KeyBindings(bindings: rows, passthrough: kept)
    }

    /// What the desktop does with no configuration at all.
    ///
    /// A desktop whose shortcuts only exist if you write a file is a desktop
    /// with no shortcuts, so these are compiled in and `~/.config/abyss/keys.ini`
    /// overrides them row by row.
    public static var defaults: [(String, String)] { DesktopKeys.defaults }
}

private extension Substring {
    func trimmingWhitespace() -> String {
        var s = self
        while let f = s.first, f == " " || f == "\t" { s = s.dropFirst() }
        while let l = s.last, l == " " || l == "\t" { s = s.dropLast() }
        return String(s)
    }
}

private extension String {
    func trimmingWhitespace() -> String { Substring(self).trimmingWhitespace() }
}
