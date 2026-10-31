//! xdg-activation-v1 (Activation.swift): how a client raises one of its own
//! windows. It cannot focus itself by fiat: it asks for a token tied to a
//! real input serial, and hands the token back with the surface to raise.
//! The Finder's spatial mode raises a folder's window this way rather than
//! open a second.

use crate::display::Display;
use abyss_sys::wlc::{xdg_activation_token_v1 as token, xdg_activation_v1, Obj};
use std::rc::Rc;

impl Display {
    pub fn can_activate(&self) -> bool {
        self.globals.borrow().activation.is_some()
    }

    /// Ask the compositor to raise `surface` (one of ours); false without
    /// the protocol, so the caller can fall back. The token's `done` does
    /// the raising, a round trip later.
    pub fn activate(self: &Rc<Self>, surface: Obj) -> bool {
        let (Some(activation), seat) = ({
            let g = self.globals.borrow();
            (g.activation, g.seat)
        }) else {
            return false;
        };
        let Some(t) = xdg_activation_v1::get_activation_token(activation) else { return false };
        // Rooted in real input: compositors refuse activation that is not.
        if let Some(seat) = seat {
            token::set_serial(t, self.last_pointer_serial(), seat)
        }
        // Where it comes from: whether the hand-off is legitimate is decided
        // by that.
        if let Some(from) = self.activation_source() {
            token::set_surface(t, from)
        }
        let me = Rc::downgrade(self);
        token::listen(t, move |token::Event::Done { token: s }| {
            if let Some(d) = me.upgrade() {
                xdg_activation_v1::activate(activation, &s, surface);
                token::destroy(t);
                d.flush()
            }
        });
        token::commit(t);
        self.flush();
        true
    }
}
