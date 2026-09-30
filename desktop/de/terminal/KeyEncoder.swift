// KeyEncoder — a key press into the bytes a terminal sends (PHASE15 P15.4b).
//
// xterm's encodings, which is what `TERM=xterm` tells a program to expect:
// text as UTF-8; Control folds a letter to its C0 byte; Option is Meta and
// prefixes ESC (the Mac Terminal setting "use Option as Meta key", on, because
// a shell's word motions need it); cursor keys are `CSI A` or, when the program
// asked for application mode (DECCKM — vi and less do), `SS3 A`; a modified
// cursor or function key is xterm's `CSI 1;<m>A`. Backspace sends DEL (0x7F),
// which is the tty's erase character on both FreeBSD and Linux.
//
// Keys the application keeps — Command chords — never get here. Pure: the
// keysyms are X11's, passed as numbers, so this needs no display to test.

public struct KeyEncoder: Sendable {
    public struct Modifiers: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let shift = Modifiers(rawValue: 1)
        public static let option = Modifiers(rawValue: 2)
        public static let control = Modifiers(rawValue: 4)
    }

    /// X11 keysyms this cares about.
    public enum Sym {
        public static let backspace: UInt32 = 0xff08, tab: UInt32 = 0xff09, enter: UInt32 = 0xff0d
        public static let escape: UInt32 = 0xff1b, delete: UInt32 = 0xffff, insert: UInt32 = 0xff63
        public static let home: UInt32 = 0xff50, left: UInt32 = 0xff51, up: UInt32 = 0xff52
        public static let right: UInt32 = 0xff53, down: UInt32 = 0xff54, pageUp: UInt32 = 0xff55
        public static let pageDown: UInt32 = 0xff56, end: UInt32 = 0xff57
        public static let backTab: UInt32 = 0xfe20, kpEnter: UInt32 = 0xff8d
        public static let f1: UInt32 = 0xffbe                        // …F12 = 0xffc9
    }

    /// The bytes for `keysym` with `text` (what the layout makes of it,
    /// unmodified by Control) and `mods`; empty for a key that sends nothing.
    /// `appCursor` is the screen's DECCKM.
    public static func encode(keysym: UInt32, text: String, mods: Modifiers, appCursor: Bool) -> [UInt8] {
        let esc: UInt8 = 0x1B
        let m = xtermModifier(mods)
        func csi(_ final: String) -> [UInt8] { Array("\u{1B}[\(final)".utf8) }
        func cursor(_ c: Character) -> [UInt8] {
            if m > 1 { return Array("\u{1B}[1;\(m)\(c)".utf8) }
            return Array((appCursor ? "\u{1B}O\(c)" : "\u{1B}[\(c)").utf8)
        }
        func tilde(_ n: Int) -> [UInt8] { m > 1 ? csi("\(n);\(m)~") : csi("\(n)~") }
        func meta(_ b: [UInt8]) -> [UInt8] { mods.contains(.option) ? [esc] + b : b }

        switch keysym {
        case Sym.up: return cursor("A")
        case Sym.down: return cursor("B")
        case Sym.right: return cursor("C")
        case Sym.left: return cursor("D")
        case Sym.home: return cursor("H")
        case Sym.end: return cursor("F")
        case Sym.insert: return tilde(2)
        case Sym.delete: return tilde(3)
        case Sym.pageUp: return tilde(5)
        case Sym.pageDown: return tilde(6)
        case Sym.f1...(Sym.f1 + 3):                                  // F1–F4: SS3 P…S
            let c = Character(Unicode.Scalar(UInt8(0x50) + UInt8(keysym - Sym.f1)))
            return m > 1 ? Array("\u{1B}[1;\(m)\(c)".utf8) : Array("\u{1B}O\(c)".utf8)
        case (Sym.f1 + 4)...(Sym.f1 + 11):                           // F5–F12
            let codes = [15, 17, 18, 19, 20, 21, 23, 24]
            return tilde(codes[Int(keysym - Sym.f1 - 4)])
        case Sym.backspace: return meta(mods.contains(.control) ? [0x08] : [0x7F])
        case Sym.enter, Sym.kpEnter: return meta([0x0D])
        case Sym.tab: return mods.contains(.shift) ? csi("Z") : meta([0x09])
        case Sym.backTab: return csi("Z")
        case Sym.escape: return meta([esc])
        default: break
        }

        // With Control held, a toolkit may hand over no text at all (a control
        // character is not text); the keysym of a printable key is its
        // character, which is all Control needs.
        var text = text
        if text.isEmpty, (0x20..<0x7F).contains(keysym), let u = Unicode.Scalar(keysym) { text = String(Character(u)) }
        guard !text.isEmpty else { return [] }
        var bytes = Array(text.utf8)
        if mods.contains(.control), bytes.count == 1, let c = control(bytes[0]) { bytes = [c] }
        return meta(bytes)
    }

    /// Control folds `@A–Z[\]^_` (and lower case, and space) to 0x00–0x1F, and
    /// `?` to DEL — the VT100's table.
    static func control(_ b: UInt8) -> UInt8? {
        switch b {
        case 0x40...0x5F: return b - 0x40
        case 0x61...0x7A: return b - 0x60
        case 0x20, 0x32: return 0x00                                   // Ctrl-Space, Ctrl-2: NUL
        case 0x33...0x37: return b - 0x33 + 0x1B                       // Ctrl-3…7: ESC FS GS RS US
        case 0x38, 0x3F: return 0x7F                                   // Ctrl-8, Ctrl-?: DEL
        case 0x2F: return 0x1F                                         // Ctrl-/: US
        default: return nil
        }
    }

    /// xterm's modifier parameter: 1 + shift(1) + alt(2) + ctrl(4).
    static func xtermModifier(_ m: Modifiers) -> Int {
        1 + (m.contains(.shift) ? 1 : 0) + (m.contains(.option) ? 2 : 0) + (m.contains(.control) ? 4 : 0)
    }
}
