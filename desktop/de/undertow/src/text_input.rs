//! text-input-v3 and input-method-v2: the relay (TextInput.swift, BACKLOG
//! U.5). An application's field speaks text-input-v3; an input method
//! (fcitx5, ibus) speaks input-method-v2; neither talks to the other, and
//! the compositor relays, which is why without this there is no CJK.
//!
//! The rules, as sway keeps them: a text input is entered when its surface
//! gets keyboard focus and left when it loses it; the enabled one on the
//! focused surface is the ACTIVE one, whose state goes to the method and to
//! which the method's commits come back; a method may GRAB the keyboard
//! (keys then go to it, except its own virtual keyboard's, which is it
//! typing); its candidate popup goes below the text cursor.
//!
//! **Nothing here logs text**: what a method commits can be a password.

use crate::backend::log;
use crate::geometry::Rect;
use crate::seat::Seat;
use abyss_sys::wlr::{self, globals, Display, InputMethod, InputPopup, Keyboard, KeyboardGrab, Listener, Press, Surface, TextInput};
use std::cell::{Cell, RefCell};
use std::rc::Weak;

pub struct TextInputRelay {
    text_inputs: RefCell<Vec<(TextInput, Vec<Listener>)>>,
    method: Cell<Option<InputMethod>>,
    method_listeners: RefCell<Vec<Listener>>,
    grab: Cell<Option<KeyboardGrab>>,
    grab_listener: RefCell<Option<Listener>>,
    popups: RefCell<Vec<(InputPopup, Option<Listener>)>>,
    listeners: RefCell<Vec<Listener>>,
    /// The enabled text input on the focused surface.
    active: Cell<Option<TextInput>>,
    /// For the log a test reads: counts, never text.
    pub enters: Cell<u64>,
    pub activations: Cell<u64>,
    pub commits_relayed: Cell<u64>,
    pub keys_grabbed: Cell<u64>,
}

impl TextInputRelay {
    pub(crate) fn new(d: &Display, seat: wlr::Seat, me: Weak<Seat>) -> Option<TextInputRelay> {
        let tim = globals::text_input_manager(d)?;
        let imm = globals::input_method_manager(d)?;
        let r = TextInputRelay {
            text_inputs: RefCell::default(),
            method: Cell::new(None),
            method_listeners: RefCell::default(),
            grab: Cell::new(None),
            grab_listener: RefCell::default(),
            popups: RefCell::default(),
            listeners: RefCell::default(),
            active: Cell::new(None),
            enters: Cell::new(0),
            activations: Cell::new(0),
            commits_relayed: Cell::new(0),
            keys_grabbed: Cell::new(0),
        };
        let (w1, w2, w3) = (me.clone(), me.clone(), me);
        *r.listeners.borrow_mut() = [
            tim.on_new_text_input(move |ti| {
                if let Some(s) = w1.upgrade() {
                    s.new_text_input(ti)
                }
            }),
            imm.on_new_input_method(move |im| {
                if let Some(s) = w2.upgrade() {
                    s.new_input_method(im)
                }
            }),
            seat.on_keyboard_focus_change(move |to| {
                if let Some(s) = w3.upgrade() {
                    s.text_focus_changed(to)
                }
            }),
        ]
        .into_iter()
        .flatten()
        .collect();
        Some(r)
    }

    pub(crate) fn clear(&self) {
        self.listeners.borrow_mut().clear();
        self.method_listeners.borrow_mut().clear();
        self.grab_listener.borrow_mut().take();
        self.text_inputs.borrow_mut().clear();
        self.popups.borrow_mut().clear();
    }
}

impl Seat {
    fn relay(&self) -> Option<&TextInputRelay> {
        self.text_input.as_ref()
    }

    fn new_text_input(&self, ti: TextInput) {
        let Some(r) = self.relay() else { return };
        // wlroots 0.20 sends these with NULL data: each closure says which.
        let w = || self.me.clone();
        let (a, b, c, d) = (w(), w(), w(), w());
        let ls = [
            ti.on_enable(move || {
                if let Some(s) = a.upgrade() {
                    s.text_input_enabled(ti)
                }
            }),
            ti.on_commit(move || {
                let Some(s) = b.upgrade() else { return };
                let Some(r) = s.relay() else { return };
                if r.active.get() == Some(ti) && ti.enabled() {
                    s.send_text_state(ti)
                }
            }),
            ti.on_disable(move || {
                let Some(s) = c.upgrade() else { return };
                if s.relay().is_some_and(|r| r.active.get() == Some(ti)) {
                    s.deactivate_text_input()
                }
            }),
            ti.on_destroy(move || {
                let Some(s) = d.upgrade() else { return };
                let Some(r) = s.relay() else { return };
                if r.active.get() == Some(ti) {
                    s.deactivate_text_input()
                }
                // Its listeners, dropped from inside one (§2.82).
                let gone: Vec<_> = {
                    let mut v = r.text_inputs.borrow_mut();
                    let (out, keep) = std::mem::take(&mut *v).into_iter().partition(|(t, _)| *t == ti);
                    *v = keep;
                    out
                };
                drop(gone);
            }),
        ]
        .into_iter()
        .flatten()
        .collect();
        r.text_inputs.borrow_mut().push((ti, ls));
        // Its client may already have the keyboard.
        if let Some(f) = self.seat.keyboard_focused()
            && ti.same_client(f)
        {
            ti.send_enter(f);
            r.enters.set(r.enters.get() + 1);
        }
    }

    fn text_focus_changed(&self, to: Option<Surface>) {
        let Some(r) = self.relay() else { return };
        if r.active.get().is_some() {
            self.deactivate_text_input()
        }
        let tis: Vec<TextInput> = r.text_inputs.borrow().iter().map(|(t, _)| *t).collect();
        for ti in tis {
            let f = ti.focused_surface();
            if f.is_some() && f != to {
                ti.send_leave()
            }
            if let Some(s) = to
                && ti.same_client(s)
                && ti.focused_surface() != Some(s)
            {
                ti.send_enter(s);
                r.enters.set(r.enters.get() + 1);
                log("text-input: entered on focus");
            }
        }
    }

    fn send_text_state(&self, ti: TextInput) {
        let Some(r) = self.relay() else { return };
        let Some(im) = r.method.get() else { return };
        ti.send_state_to(im);
        self.place_input_popups();
    }

    fn text_input_enabled(&self, ti: TextInput) {
        let Some(r) = self.relay() else { return };
        if ti.focused_surface().is_none() {
            return;
        }
        r.active.set(Some(ti));
        log(&format!("text-input: enabled{}", if r.method.get().is_none() { " (no input method)" } else { "" }));
        let Some(im) = r.method.get() else { return };
        im.send_activate();
        r.activations.set(r.activations.get() + 1);
        self.send_text_state(ti);
    }

    fn deactivate_text_input(&self) {
        let Some(r) = self.relay() else { return };
        r.active.set(None);
        log("text-input: deactivated");
        if let Some(im) = r.method.get() {
            im.send_deactivate();
            im.send_done();
        }
    }

    fn new_input_method(&self, im: InputMethod) {
        let Some(r) = self.relay() else { return };
        // One per seat: a second is told it is unavailable.
        if r.method.get().is_some() {
            return im.send_unavailable();
        }
        r.method.set(Some(im));
        log("input-method: bound");
        let w = || self.me.clone();
        let (a, b, c, d) = (w(), w(), w(), w());
        *r.method_listeners.borrow_mut() = [
            im.on_commit(move || {
                let Some(s) = a.upgrade() else { return };
                let Some(r) = s.relay() else { return };
                let Some(ti) = r.active.get() else { return };
                let (pre, com) = im.relay_to(ti);
                r.commits_relayed.set(r.commits_relayed.get() + 1);
                log(&format!("input-method: commit relayed (preedit {pre} bytes, commit {com} bytes)"));
            }),
            im.on_grab_keyboard(move |g| {
                if let Some(s) = b.upgrade() {
                    s.input_method_grabbed(g)
                }
            }),
            im.on_new_popup_surface(move |p| {
                let Some(s) = c.upgrade() else { return };
                let Some(r) = s.relay() else { return };
                let w = s.me.clone();
                let l = p.on_destroy(move || {
                    if let Some(s) = w.upgrade()
                        && let Some(r) = s.relay()
                    {
                        let gone: Vec<_> = {
                            let mut v = r.popups.borrow_mut();
                            let (out, keep) = std::mem::take(&mut *v).into_iter().partition(|(o, _)| *o == p);
                            *v = keep;
                            out
                        };
                        drop(gone);
                    }
                });
                r.popups.borrow_mut().push((p, l));
                s.place_input_popups();
            }),
            im.on_destroy(move || {
                let Some(s) = d.upgrade() else { return };
                let Some(r) = s.relay() else { return };
                let gone = std::mem::take(&mut *r.method_listeners.borrow_mut());
                r.method.set(None);
                r.grab.set(None);
                let g = r.grab_listener.borrow_mut().take();
                let p = std::mem::take(&mut *r.popups.borrow_mut());
                // The field's composing is over: its preedit is withdrawn.
                if let Some(ti) = r.active.get() {
                    ti.clear_preedit()
                }
                log("input-method: gone");
                drop((gone, g, p));
            }),
        ]
        .into_iter()
        .flatten()
        .collect();
        // A field already active gets the method at once.
        if let Some(ti) = r.active.get() {
            im.send_activate();
            r.activations.set(r.activations.get() + 1);
            self.send_text_state(ti);
        }
    }

    fn input_method_grabbed(&self, g: KeyboardGrab) {
        let Some(r) = self.relay() else { return };
        r.grab.set(Some(g));
        if let Some(k) = self.keyboard() {
            g.set_keyboard(k)
        }
        let w = self.me.clone();
        *r.grab_listener.borrow_mut() = g.on_destroy(move || {
            let Some(s) = w.upgrade() else { return };
            let Some(r) = s.relay() else { return };
            r.grab.set(None);
            // **Off the signal before wlroots finishes destroying it**.
            let l = r.grab_listener.borrow_mut().take();
            drop(l);
            // Modifiers held across the release are re-sent, not stuck.
            if let Some(k) = s.keyboard() {
                s.seat.keyboard_modifiers(k)
            }
            log("input-method: keyboard released");
        });
        log("input-method: keyboard grabbed");
    }

    /// A key goes to the method's grab instead of the application; never its
    /// own virtual keyboard's, which would come straight back to it.
    pub(crate) fn route_key_to_method(&self, k: Keyboard, e: Press) -> bool {
        let Some(r) = self.relay() else { return false };
        let (Some(g), Some(im)) = (r.grab.get(), r.method.get()) else { return false };
        if im.owns_keyboard(k) {
            return false;
        }
        g.send_key(k, e);
        r.keys_grabbed.set(r.keys_grabbed.get() + 1);
        true
    }

    pub(crate) fn route_modifiers_to_method(&self, k: Keyboard) -> bool {
        let Some(r) = self.relay() else { return false };
        let (Some(g), Some(im)) = (r.grab.get(), r.method.get()) else { return false };
        if im.owns_keyboard(k) {
            return false;
        }
        g.send_modifiers(k);
        true
    }

    /// Where the focused field's text cursor is on the desktop.
    fn text_cursor_rect(&self) -> Option<Rect> {
        let ti = self.relay()?.active.get()?;
        let s = ti.focused_surface()?;
        let c = self.c();
        let origin = c.toplevels.borrow().iter().find(|t| t.surface == s).map(|t| (t.x.get(), t.y.get())).or_else(|| c.layers.borrow().iter().find(|l| l.surface == s).map(|l| (l.rect.get().x, l.rect.get().y)))?;
        let [x, y, w, h] = ti.cursor();
        Some(Rect::new(origin.0 + x, origin.1 + y, w.max(1), h.max(1)))
    }

    fn place_input_popups(&self) {
        let Some(r) = self.relay() else { return };
        let Some(ti) = r.active.get() else { return };
        for (p, _) in r.popups.borrow().iter() {
            p.send_rectangle(ti.cursor())
        }
    }

    /// The candidate popups with something to show: just below the text
    /// cursor, in layout coordinates.
    pub fn input_method_popups(&self) -> Vec<(Surface, i32, i32)> {
        let (Some(r), Some(c)) = (self.relay(), self.text_cursor_rect()) else { return vec![] };
        r.popups.borrow().iter().filter_map(|(p, _)| p.surface().filter(|s| s.has_buffer()).map(|s| (s, c.x, c.y + c.height))).collect()
    }
}
