// Keyboard translation via xkbcommon.
//
// wl_keyboard delivers raw evdev keycodes plus a keymap (over a fd) and a
// running modifier mask. xkbcommon turns those into keysyms and UTF-8 text,
// which is what a toolkit actually wants. KeyboardState owns the xkb context,
// the compositor-supplied keymap, and the live modifier state; Display drives
// it from the wl_keyboard listener (Display.swift).

import CXkb

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// The modifiers held when a key event fired. `command` is the Logo/Super key,
/// which is where the Mac's Command lives on PC hardware — the Finder's
/// shortcuts (⌘C, ⌘⇧N, ⌘⌫) are spelled with it.
public struct KeyModifiers: OptionSet, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let shift    = KeyModifiers(rawValue: 1 << 0)
    public static let control  = KeyModifiers(rawValue: 1 << 1)
    public static let alt      = KeyModifiers(rawValue: 1 << 2)
    public static let command  = KeyModifiers(rawValue: 1 << 3)
    public static let capsLock = KeyModifiers(rawValue: 1 << 4)

    public var isEmpty: Bool { rawValue == 0 }
}

/// A single key transition, already resolved to a keysym and its text.
public struct KeyEvent: Sendable {
    /// The XKB/X11 keysym (e.g. `KeySym.backspace`). Layout-resolved.
    public let keysym: UInt32
    /// The UTF-8 the key produces given current modifiers — empty for keys
    /// that don't produce text (arrows, Backspace, function keys, …).
    public let text: String
    /// True on press, false on release.
    public let pressed: Bool
    /// Modifiers held at the time of the event.
    public let modifiers: KeyModifiers

    public init(keysym: UInt32, text: String, pressed: Bool,
                modifiers: KeyModifiers = []) {
        self.keysym = keysym
        self.text = text
        self.pressed = pressed
        self.modifiers = modifiers
    }
}

/// The handful of non-text keysyms the toolkit reacts to. Values are the
/// stable X11 keysyms xkbcommon reports (see xkbcommon-keysyms.h).
public enum KeySym {
    public static let space: UInt32     = 0x0020
    public static let backspace: UInt32 = 0xff08
    public static let tab: UInt32       = 0xff09
    public static let backTab: UInt32   = 0xfe20  // ISO_Left_Tab (Shift-Tab)
    public static let enter: UInt32     = 0xff0d
    public static let escape: UInt32    = 0xff1b
    public static let delete: UInt32    = 0xffff
    public static let left: UInt32      = 0xff51
    public static let up: UInt32        = 0xff52
    public static let right: UInt32     = 0xff53
    public static let down: UInt32      = 0xff54
    public static let home: UInt32      = 0xff50
    public static let end: UInt32       = 0xff57
    public static let pageUp: UInt32    = 0xff55
    public static let pageDown: UInt32  = 0xff56
}

final class KeyboardState {
    private let context: OpaquePointer
    private var keymap: OpaquePointer?
    private var state: OpaquePointer?

    // wl_keyboard.repeat_info: how the compositor wants held keys to repeat.
    // rate is keys/second (0 disables repeat), delay is ms before it starts.
    private(set) var repeatRate: Int32 = 0
    private(set) var repeatDelayMs: Int32 = 0

    func setRepeatInfo(rate: Int32, delay: Int32) {
        repeatRate = rate
        repeatDelayMs = delay
    }

    /// Whether the key at `evdev` is one the keymap marks as auto-repeating
    /// (letters/digits/space/arrows yes; modifiers no).
    func keyRepeats(evdev: UInt32) -> Bool {
        guard let keymap else { return false }
        return xkb_keymap_key_repeats(keymap, evdev + 8) != 0
    }

    init?() {
        guard let ctx = xkb_context_new(XKB_CONTEXT_NO_FLAGS) else { return nil }
        context = ctx
    }

    deinit {
        if let state { xkb_state_unref(state) }
        if let keymap { xkb_keymap_unref(keymap) }
        xkb_context_unref(context)
    }

    /// Load the keymap the compositor sent over `fd` (`wl_keyboard.keymap`).
    /// `format` 1 is XKB_KEYMAP_FORMAT_TEXT_V1; `size` includes the trailing
    /// NUL. We always close `fd` (the compositor owns its own copy).
    func loadKeymap(fd: Int32, size: UInt32, format: UInt32) {
        defer { close(fd) }
        guard format == 1 else { return }  // only text-v1 is defined
        let len = Int(size)
        // MAP_PRIVATE: the keymap fd may be sealed read-only by the compositor.
        guard let map = mmap(nil, len, PROT_READ, MAP_PRIVATE, fd, 0),
              map != UnsafeMutableRawPointer(bitPattern: -1) else { return }
        defer { munmap(map, len) }

        let str = map.assumingMemoryBound(to: CChar.self)
        guard let km = xkb_keymap_new_from_string(
            context, str, XKB_KEYMAP_FORMAT_TEXT_V1, XKB_KEYMAP_COMPILE_NO_FLAGS)
        else { return }
        guard let st = xkb_state_new(km) else { xkb_keymap_unref(km); return }

        if let old = state { xkb_state_unref(old) }
        if let old = keymap { xkb_keymap_unref(old) }
        keymap = km
        state = st
    }

    /// Track the modifier/group mask from `wl_keyboard.modifiers`.
    func updateModifiers(depressed: UInt32, latched: UInt32,
                         locked: UInt32, group: UInt32) {
        guard let state else { return }
        xkb_state_update_mask(state, depressed, latched, locked, 0, 0, group)
    }

    /// The modifiers currently held, as xkb sees them. The names are the XKB
    /// canonical ones ("Shift"/"Control"/"Mod1"/"Mod4"/"Lock") — spelled out
    /// rather than via the XKB_MOD_NAME_* macros, which are string #defines the
    /// Swift importer doesn't reliably surface.
    func currentModifiers() -> KeyModifiers {
        guard let state else { return [] }
        func active(_ name: String) -> Bool {
            name.withCString {
                xkb_state_mod_name_is_active(state, $0, XKB_STATE_MODS_EFFECTIVE) > 0
            }
        }
        var mods: KeyModifiers = []
        if active("Shift")   { mods.insert(.shift) }
        if active("Control") { mods.insert(.control) }
        if active("Mod1")    { mods.insert(.alt) }
        if active("Mod4")    { mods.insert(.command) }
        if active("Lock")    { mods.insert(.capsLock) }
        return mods
    }

    /// Resolve an evdev keycode from `wl_keyboard.key` into a KeyEvent.
    func event(evdev: UInt32, pressed: Bool) -> KeyEvent? {
        guard let state else { return nil }
        let keycode = evdev + 8  // evdev → xkb keycode offset
        let sym = xkb_state_key_get_one_sym(state, keycode)

        var buf = [UInt8](repeating: 0, count: 16)
        let cap = buf.count
        let n = buf.withUnsafeMutableBufferPointer {
            $0.baseAddress!.withMemoryRebound(to: CChar.self, capacity: cap) {
                Int(xkb_state_key_get_utf8(state, keycode, $0, cap))
            }
        }
        // Drop control characters (Backspace/Return/Esc report text too); the
        // toolkit decides on those via the keysym.
        var text = ""
        if n > 0 {
            let s = String(decoding: buf[0..<n], as: UTF8.self)
            if let scalar = s.unicodeScalars.first, scalar.value >= 0x20,
               scalar.value != 0x7f {
                text = s
            }
        }
        return KeyEvent(keysym: sym, text: text, pressed: pressed,
                        modifiers: currentModifiers())
    }
}
