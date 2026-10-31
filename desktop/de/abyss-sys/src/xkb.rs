//! xkbcommon, the client's half (Keyboard.swift's CXkb): a keymap the
//! compositor sends, the modifier state, and a key's keysym and text.

use std::ffi::{c_char, c_int, CString};

#[repr(C)]
struct xkb_context {
    _p: [u8; 0],
}
#[repr(C)]
struct xkb_keymap {
    _p: [u8; 0],
}
#[repr(C)]
struct xkb_state {
    _p: [u8; 0],
}

const KEYMAP_FORMAT_TEXT_V1: c_int = 1;
const STATE_MODS_EFFECTIVE: c_int = 1 << 3;

unsafe extern "C" {
    fn xkb_context_new(flags: c_int) -> *mut xkb_context;
    fn xkb_context_unref(c: *mut xkb_context);
    fn xkb_keymap_new_from_string(c: *mut xkb_context, s: *const c_char, format: c_int, flags: c_int) -> *mut xkb_keymap;
    fn xkb_keymap_unref(k: *mut xkb_keymap);
    fn xkb_keymap_key_repeats(k: *mut xkb_keymap, key: u32) -> c_int;
    fn xkb_state_new(k: *mut xkb_keymap) -> *mut xkb_state;
    fn xkb_state_unref(s: *mut xkb_state);
    fn xkb_state_update_mask(s: *mut xkb_state, dep: u32, lat: u32, lock: u32, dl: u32, ll: u32, group: u32) -> c_int;
    fn xkb_state_mod_name_is_active(s: *mut xkb_state, name: *const c_char, kind: c_int) -> c_int;
    fn xkb_state_key_get_one_sym(s: *mut xkb_state, key: u32) -> u32;
    fn xkb_state_key_get_utf8(s: *mut xkb_state, key: u32, buf: *mut c_char, size: usize) -> c_int;
}

/// A compiled keymap and the live state over it.
pub struct Keymap {
    context: *mut xkb_context,
    keymap: *mut xkb_keymap,
    state: *mut xkb_state,
}

impl Keymap {
    /// Compile a text-v1 keymap.
    pub fn from_string(text: &[u8]) -> Option<Keymap> {
        let text = CString::new(text.split(|b| *b == 0).next().unwrap_or(&[])).ok()?;
        let context = unsafe { xkb_context_new(0) };
        if context.is_null() {
            return None;
        }
        let keymap = unsafe { xkb_keymap_new_from_string(context, text.as_ptr(), KEYMAP_FORMAT_TEXT_V1, 0) };
        if keymap.is_null() {
            unsafe { xkb_context_unref(context) };
            return None;
        }
        let state = unsafe { xkb_state_new(keymap) };
        if state.is_null() {
            unsafe { xkb_keymap_unref(keymap) };
            unsafe { xkb_context_unref(context) };
            return None;
        }
        Some(Keymap { context, keymap, state })
    }

    pub fn update_mask(&self, depressed: u32, latched: u32, locked: u32, group: u32) {
        unsafe { xkb_state_update_mask(self.state, depressed, latched, locked, 0, 0, group) };
    }

    /// Whether a modifier, by its XKB name ("Shift", "Mod4"), is in effect.
    pub fn mod_active(&self, name: &str) -> bool {
        let n = CString::new(name).unwrap();
        unsafe { xkb_state_mod_name_is_active(self.state, n.as_ptr(), STATE_MODS_EFFECTIVE) > 0 }
    }

    /// The keysym and UTF-8 of an xkb keycode.
    pub fn key(&self, keycode: u32) -> (u32, String) {
        let sym = unsafe { xkb_state_key_get_one_sym(self.state, keycode) };
        let mut buf = [0u8; 16];
        let n = unsafe { xkb_state_key_get_utf8(self.state, keycode, buf.as_mut_ptr() as *mut c_char, buf.len()) };
        let n = (n.max(0) as usize).min(buf.len() - 1);
        (sym, String::from_utf8_lossy(&buf[..n]).into_owned())
    }

    pub fn repeats(&self, keycode: u32) -> bool {
        unsafe { xkb_keymap_key_repeats(self.keymap, keycode) != 0 }
    }
}

impl Drop for Keymap {
    fn drop(&mut self) {
        unsafe {
            xkb_state_unref(self.state);
            xkb_keymap_unref(self.keymap);
            xkb_context_unref(self.context);
        }
    }
}
