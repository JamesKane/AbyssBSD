//! A key press into the bytes a terminal sends (KeyEncoder.swift, P15.4b).
//!
//! xterm's encodings, as `TERM=xterm` tells a program to expect: text as
//! UTF-8; Control folds a letter to its C0 byte; Option is Meta and
//! prefixes ESC (a shell's word motions need it); cursor keys are `CSI A`,
//! or `SS3 A` in application mode (DECCKM: vi and less ask); a modified
//! cursor or function key is `CSI 1;<m>A`. Backspace sends DEL, the tty's
//! erase character on FreeBSD and Linux. Command chords never get here.
//! Keysyms are X11's, as numbers, so this needs no display to test.

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct KeyMods {
    pub shift: bool,
    pub option: bool,
    pub control: bool,
}

/// The X11 keysyms this cares about.
pub mod sym {
    pub const BACKSPACE: u32 = 0xff08;
    pub const TAB: u32 = 0xff09;
    pub const ENTER: u32 = 0xff0d;
    pub const ESCAPE: u32 = 0xff1b;
    pub const DELETE: u32 = 0xffff;
    pub const INSERT: u32 = 0xff63;
    pub const HOME: u32 = 0xff50;
    pub const LEFT: u32 = 0xff51;
    pub const UP: u32 = 0xff52;
    pub const RIGHT: u32 = 0xff53;
    pub const DOWN: u32 = 0xff54;
    pub const PAGE_UP: u32 = 0xff55;
    pub const PAGE_DOWN: u32 = 0xff56;
    pub const END: u32 = 0xff57;
    pub const BACK_TAB: u32 = 0xfe20;
    pub const KP_ENTER: u32 = 0xff8d;
    /// …F12 is F1 + 11.
    pub const F1: u32 = 0xffbe;
}

/// xterm's modifier parameter: 1 + shift(1) + alt(2) + ctrl(4).
fn xterm_modifier(m: KeyMods) -> u32 {
    1 + u32::from(m.shift) + 2 * u32::from(m.option) + 4 * u32::from(m.control)
}

/// Control folds `@A–Z[\]^_` (and lower case, and space) to 0x00–0x1F, and
/// `?` to DEL: the VT100's table.
fn control(b: u8) -> Option<u8> {
    match b {
        0x40..=0x5F => Some(b - 0x40),
        0x61..=0x7A => Some(b - 0x60),
        b' ' | b'2' => Some(0x00),
        b'3'..=b'7' => Some(b - b'3' + 0x1B), // ESC FS GS RS US
        b'8' | b'?' => Some(0x7F),
        b'/' => Some(0x1F),
        _ => None,
    }
}

/// The bytes for `keysym` with `text` (what the layout makes of it,
/// unmodified by Control) and `mods`; empty for a key that sends nothing.
/// `app_cursor` is the screen's DECCKM.
pub fn encode(keysym: u32, text: &str, mods: KeyMods, app_cursor: bool) -> Vec<u8> {
    let m = xterm_modifier(mods);
    let cursor = |c: char| if m > 1 { format!("\x1b[1;{m}{c}") } else if app_cursor { format!("\x1bO{c}") } else { format!("\x1b[{c}") }.into_bytes();
    let tilde = |n: u32| if m > 1 { format!("\x1b[{n};{m}~") } else { format!("\x1b[{n}~") }.into_bytes();
    let meta = |b: &[u8]| if mods.option { [&[0x1B], b].concat() } else { b.to_vec() };
    match keysym {
        sym::UP => return cursor('A'),
        sym::DOWN => return cursor('B'),
        sym::RIGHT => return cursor('C'),
        sym::LEFT => return cursor('D'),
        sym::HOME => return cursor('H'),
        sym::END => return cursor('F'),
        sym::INSERT => return tilde(2),
        sym::DELETE => return tilde(3),
        sym::PAGE_UP => return tilde(5),
        sym::PAGE_DOWN => return tilde(6),
        // F1–F4: SS3 P…S.
        k @ sym::F1..=0xffc1 => {
            let c = char::from(b'P' + (k - sym::F1) as u8);
            return if m > 1 { format!("\x1b[1;{m}{c}") } else { format!("\x1bO{c}") }.into_bytes();
        }
        // F5–F12.
        k @ 0xffc2..=0xffc9 => return tilde([15, 17, 18, 19, 20, 21, 23, 24][(k - sym::F1 - 4) as usize]),
        sym::BACKSPACE => return meta(if mods.control { &[0x08] } else { &[0x7F] }),
        sym::ENTER | sym::KP_ENTER => return meta(&[0x0D]),
        sym::TAB if mods.shift => return b"\x1b[Z".to_vec(),
        sym::TAB => return meta(&[0x09]),
        sym::BACK_TAB => return b"\x1b[Z".to_vec(),
        sym::ESCAPE => return meta(&[0x1B]),
        _ => {}
    }
    // With Control held a toolkit may hand over no text (a control
    // character is not text); a printable key's keysym is its character.
    let mut bytes = text.as_bytes().to_vec();
    if bytes.is_empty()
        && (0x20..0x7F).contains(&keysym)
    {
        bytes = vec![keysym as u8]
    }
    if bytes.is_empty() {
        return bytes;
    }
    if mods.control
        && bytes.len() == 1
        && let Some(c) = control(bytes[0])
    {
        bytes = vec![c]
    }
    meta(&bytes)
}
