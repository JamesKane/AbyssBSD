// VTParser — bytes from a program into terminal actions (PHASE15 P15.4a).
//
// The state machine is the one Paul Williams drew for DEC's VT500 series
// (vt100.net/emu/dec_ansi_parser), cut to what an xterm-subset needs: ground,
// escape, CSI, OSC and a DCS that is recognised and ignored. It knows nothing
// about screens; it turns a byte stream into `VTAction`s, and `Screen` decides
// what they mean. Pure: no I/O, no display — which is what lets `vi`'s output
// be asserted on in a unit test.
//
// UTF-8 is decoded in the ground state only, as xterm does: a control byte in
// the middle of a sequence aborts it (the partial character becomes U+FFFD) and
// is then acted on, so a stray ESC can never be swallowed by a broken rune.

public enum VTAction: Equatable, Sendable {
    /// A character to put on the screen.
    case print(Unicode.Scalar)
    /// A C0 control: BEL, BS, HT, LF, VT, FF, CR, SO, SI.
    case execute(UInt8)
    /// `CSI params intermediates final` — `ESC [ ? 1 0 4 9 h`.
    case csi(params: [Int], intermediates: [UInt8], private: UInt8?, final: UInt8)
    /// `ESC intermediates final` — `ESC 7`, `ESC ( 0`.
    case esc(intermediates: [UInt8], final: UInt8)
    /// `OSC string (BEL|ST)` — `ESC ] 0 ; title BEL`.
    case osc(String)
}

public struct VTParser: Sendable {
    enum State: Sendable { case ground, escape, escapeIntermediate, csiEntry, csiParam, csiIntermediate, csiIgnore, osc, dcs }

    private var state: State = .ground
    private var params: [Int] = []
    private var current: Int? = nil
    private var intermediates: [UInt8] = []
    private var privateMarker: UInt8? = nil
    private var oscBytes: [UInt8] = []
    /// A string terminator's ESC seen inside OSC/DCS: the next `\` ends it.
    private var sawEscInString = false
    // UTF-8, in ground.
    private var utf8Need = 0
    private var utf8Value: UInt32 = 0

    /// Longest parameter list and OSC string kept: a program that sends more
    /// is either broken or hostile, and a terminal must not grow without bound.
    static let maxParams = 32
    static let maxOSC = 4096

    public init() {}

    public mutating func feed<S: Sequence>(_ bytes: S, _ emit: (VTAction) -> Void) where S.Element == UInt8 {
        for b in bytes { step(b, emit) }
    }

    public mutating func step(_ b: UInt8, _ emit: (VTAction) -> Void) {
        // Anywhere: CAN and SUB abort a sequence; ESC starts one (except inside
        // a string, where it may be the start of ST).
        switch b {
        case 0x18, 0x1A:
            if utf8Need > 0 { emit(.print("\u{FFFD}")); utf8Need = 0 }
            state = .ground
            return
        case 0x1B where state != .osc && state != .dcs:
            if utf8Need > 0 { emit(.print("\u{FFFD}")); utf8Need = 0 }
            enterEscape()
            return
        default: break
        }

        switch state {
        case .ground:
            ground(b, emit)
        case .escape:
            if b < 0x20 { emit(.execute(b)) }
            else if b <= 0x2F { intermediates.append(b); state = .escapeIntermediate }
            else if b == 0x5B { enterCSI() }                       // [
            else if b == 0x5D { oscBytes = []; sawEscInString = false; state = .osc }  // ]
            else if b == 0x50 { sawEscInString = false; state = .dcs }               // P
            else if b == 0x58 || b == 0x5E || b == 0x5F { sawEscInString = false; state = .dcs } // SOS PM APC: ignored alike
            else if b <= 0x7E { emit(.esc(intermediates: intermediates, final: b)); state = .ground }
        case .escapeIntermediate:
            if b < 0x20 { emit(.execute(b)) }
            else if b <= 0x2F { if intermediates.count < 4 { intermediates.append(b) } }
            else if b <= 0x7E { emit(.esc(intermediates: intermediates, final: b)); state = .ground }
        case .csiEntry, .csiParam:
            if b < 0x20 { emit(.execute(b)) }
            else if b >= 0x30 && b <= 0x39 {
                let v = (current ?? 0) &* 10 &+ Int(b - 0x30)
                current = min(v, 65535)
                state = .csiParam
            } else if b == 0x3B || b == 0x3A {                         // ; (and : as xterm's SGR sub-separator)
                pushParam()
                state = .csiParam
            } else if b >= 0x3C && b <= 0x3F {                         // < = > ?
                if state == .csiEntry { privateMarker = b; state = .csiParam } else { state = .csiIgnore }
            } else if b <= 0x2F { intermediates.append(b); state = .csiIntermediate }
            else if b <= 0x7E { dispatchCSI(b, emit) }
        case .csiIntermediate:
            if b < 0x20 { emit(.execute(b)) }
            else if b <= 0x2F { if intermediates.count < 4 { intermediates.append(b) } }
            else if b <= 0x3F { state = .csiIgnore }
            else if b <= 0x7E { dispatchCSI(b, emit) }
        case .csiIgnore:
            if b < 0x20 { emit(.execute(b)) }
            else if b >= 0x40 && b <= 0x7E { state = .ground }
        case .osc:
            if b == 0x07 { finishOSC(emit); return }                   // BEL ends it (xterm)
            if sawEscInString {
                sawEscInString = false
                if b == 0x5C { finishOSC(emit); return }               // ESC \ = ST
                // An ESC that is not ST aborts the string and starts a sequence.
                enterEscape(); step(b, emit); return
            }
            if b == 0x1B { sawEscInString = true; return }
            if b >= 0x20, oscBytes.count < VTParser.maxOSC { oscBytes.append(b) }
        case .dcs:
            if sawEscInString { sawEscInString = false; if b == 0x5C { state = .ground; return }; enterEscape(); step(b, emit); return }
            if b == 0x1B { sawEscInString = true }
        }
    }

    private mutating func ground(_ b: UInt8, _ emit: (VTAction) -> Void) {
        if utf8Need > 0 {
            if b & 0xC0 == 0x80 {
                utf8Value = (utf8Value << 6) | UInt32(b & 0x3F)
                utf8Need -= 1
                if utf8Need == 0 { emit(.print(Unicode.Scalar(utf8Value) ?? "\u{FFFD}")) }
                return
            }
            // A broken rune: say so, then take this byte on its own.
            emit(.print("\u{FFFD}"))
            utf8Need = 0
        }
        switch b {
        case 0x00..<0x20: emit(.execute(b))
        case 0x7F: break                                               // DEL: ignored
        case 0x20..<0x7F: emit(.print(Unicode.Scalar(b)))
        case 0xC2...0xDF: utf8Need = 1; utf8Value = UInt32(b & 0x1F)
        case 0xE0...0xEF: utf8Need = 2; utf8Value = UInt32(b & 0x0F)
        case 0xF0...0xF4: utf8Need = 3; utf8Value = UInt32(b & 0x07)
        default: emit(.print("\u{FFFD}"))                              // a lone continuation, or not UTF-8
        }
    }

    private mutating func enterEscape() {
        intermediates = []
        state = .escape
    }

    private mutating func enterCSI() {
        params = []; current = nil; intermediates = []; privateMarker = nil
        state = .csiEntry
    }

    private mutating func pushParam() {
        if params.count < VTParser.maxParams { params.append(current ?? 0) }
        current = nil
    }

    private mutating func dispatchCSI(_ final: UInt8, _ emit: (VTAction) -> Void) {
        if current != nil || !params.isEmpty { pushParam() }
        emit(.csi(params: params, intermediates: intermediates, private: privateMarker, final: final))
        state = .ground
    }

    private mutating func finishOSC(_ emit: (VTAction) -> Void) {
        emit(.osc(String(decoding: oscBytes, as: UTF8.self)))
        oscBytes = []
        state = .ground
    }
}
