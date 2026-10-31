//! Keyboard translation (Keyboard.swift): the keymap the compositor sends,
//! its modifier state, and a key's keysym and text.

use abyss_sys::xkb::Keymap;
use std::fs::File;
use std::os::fd::OwnedFd;
use std::os::unix::fs::FileExt;

/// The modifiers held when a key event fired. `COMMAND` is the Logo key,
/// where the Mac's Command lives on PC hardware.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash)]
pub struct KeyModifiers(pub u32);

impl KeyModifiers {
    pub const SHIFT: KeyModifiers = KeyModifiers(1 << 0);
    pub const CONTROL: KeyModifiers = KeyModifiers(1 << 1);
    pub const ALT: KeyModifiers = KeyModifiers(1 << 2);
    pub const COMMAND: KeyModifiers = KeyModifiers(1 << 3);
    pub const CAPS_LOCK: KeyModifiers = KeyModifiers(1 << 4);

    pub fn contains(self, o: KeyModifiers) -> bool {
        self.0 & o.0 == o.0
    }
    pub fn is_empty(self) -> bool {
        self.0 == 0
    }
}

impl std::ops::BitOr for KeyModifiers {
    type Output = KeyModifiers;
    fn bitor(self, o: KeyModifiers) -> KeyModifiers {
        KeyModifiers(self.0 | o.0)
    }
}

/// One key transition, resolved to a keysym and its text.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct KeyEvent {
    /// The layout-resolved X11 keysym.
    pub keysym: u32,
    /// What the key types; empty for keys that type nothing (arrows,
    /// Backspace, Return: the keysym says those).
    pub text: String,
    pub pressed: bool,
    pub modifiers: KeyModifiers,
}

/// The non-text keysyms the toolkit reacts to.
pub struct KeySym;
impl KeySym {
    pub const SPACE: u32 = 0x0020;
    pub const BACKSPACE: u32 = 0xff08;
    pub const TAB: u32 = 0xff09;
    /// ISO_Left_Tab: Shift-Tab.
    pub const BACK_TAB: u32 = 0xfe20;
    pub const ENTER: u32 = 0xff0d;
    pub const ESCAPE: u32 = 0xff1b;
    pub const DELETE: u32 = 0xffff;
    pub const LEFT: u32 = 0xff51;
    pub const UP: u32 = 0xff52;
    pub const RIGHT: u32 = 0xff53;
    pub const DOWN: u32 = 0xff54;
    pub const HOME: u32 = 0xff50;
    pub const END: u32 = 0xff57;
    pub const PAGE_UP: u32 = 0xff55;
    pub const PAGE_DOWN: u32 = 0xff56;
}

/// evdev to xkb keycodes.
const EVDEV_OFFSET: u32 = 8;

#[derive(Default)]
pub struct KeyboardState {
    keymap: Option<Keymap>,
    /// Keys a second, 0 for no repeat, and the delay before it starts.
    pub repeat_rate: i32,
    pub repeat_delay_ms: i32,
}

impl KeyboardState {
    /// `wl_keyboard.keymap`: format 1 is text-v1, and `size` counts the NUL.
    /// Read with pread: the descriptor may be one file shared by every
    /// client, whose offset a read(2) would move for all of them.
    pub fn load_keymap(&mut self, fd: OwnedFd, size: u32, format: u32) {
        if format != 1 {
            return;
        }
        let mut text = vec![0u8; size as usize];
        if File::from(fd).read_exact_at(&mut text, 0).is_err() {
            return;
        }
        if let Some(k) = Keymap::from_string(&text) {
            self.keymap = Some(k)
        }
    }

    pub fn update_modifiers(&self, depressed: u32, latched: u32, locked: u32, group: u32) {
        if let Some(k) = &self.keymap {
            k.update_mask(depressed, latched, locked, group)
        }
    }

    pub fn key_repeats(&self, evdev: u32) -> bool {
        self.keymap.as_ref().is_some_and(|k| k.repeats(evdev + EVDEV_OFFSET))
    }

    fn modifiers(k: &Keymap) -> KeyModifiers {
        let mut m = KeyModifiers::default();
        for (name, bit) in [("Shift", KeyModifiers::SHIFT), ("Control", KeyModifiers::CONTROL), ("Mod1", KeyModifiers::ALT), ("Mod4", KeyModifiers::COMMAND), ("Lock", KeyModifiers::CAPS_LOCK)] {
            if k.mod_active(name) {
                m = m | bit
            }
        }
        m
    }

    /// An evdev keycode from `wl_keyboard.key`, resolved.
    pub fn event(&self, evdev: u32, pressed: bool) -> Option<KeyEvent> {
        let k = self.keymap.as_ref()?;
        let (keysym, text) = k.key(evdev + EVDEV_OFFSET);
        // Control characters are the keysym's to say (Backspace, Return).
        let text = match text.chars().next() {
            Some(c) if c as u32 >= 0x20 && c as u32 != 0x7f => text,
            _ => String::new(),
        };
        Some(KeyEvent { keysym, text, pressed, modifiers: KeyboardState::modifiers(k) })
    }
}
