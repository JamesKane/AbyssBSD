//! A grabbing xdg-popup (Popup.swift): the surface a menu is drawn on. It is
//! parented to a rect in a window, a layer surface (the menu bar's and the
//! Dock's menus) or another popup (a submenu); its grab sends the pointer
//! to it, and the compositor's `popup_done` on a click outside is how a
//! menu dismisses.

use crate::backing::{Backing, Kind, RenderTarget, Role};
use crate::display::Display;
use abyss_sys::wlc::{wl_compositor, wl_surface, xdg_popup, xdg_positioner as pos, xdg_surface, xdg_wm_base, zwlr_layer_surface_v1, Obj};
use std::cell::RefCell;
use std::rc::{Rc, Weak};

const BTN_LEFT: u32 = 0x110;

/// The menu's half of a popup.
pub trait PopupDelegate {
    fn render(&self, popup: &Popup, target: &RenderTarget);
    fn pointer_moved(&self, _popup: &Popup, _x: f64, _y: f64) {}
    /// The left button: a menu chooses on its release.
    fn pointer_button(&self, _popup: &Popup, _pressed: bool) {}
    /// The compositor took it down (a click outside). It is already torn
    /// down when this is heard; `close` is not reported.
    fn dismissed(&self, _popup: &Popup) {}
}

/// What a popup hangs from.
pub(crate) enum Parent {
    Xdg(Obj),
    /// A layer surface: the popup is made parent-less, then given to it.
    Layer(Obj),
}

pub struct Popup {
    backing: Backing,
    xdg_surface: Obj,
    popup: Obj,
    delegate: RefCell<Weak<dyn PopupDelegate>>,
}

impl Popup {
    /// Below `anchor` (x, y, w, h in the parent's points), left-aligned, and
    /// kept on screen: slid along either edge, flipped above when there is
    /// no room below.
    #[allow(clippy::too_many_arguments)]
    pub(crate) fn below(display: &Rc<Display>, parent: Parent, scale: i32, anchor: (i32, i32, i32, i32), width: i32, height: i32, delegate: Weak<dyn PopupDelegate>) -> Option<Rc<Popup>> {
        Popup::open(display, parent, scale, anchor, (width, height), delegate, |p| {
            pos::set_anchor(p, pos::ANCHOR_BOTTOM_LEFT);
            pos::set_gravity(p, pos::GRAVITY_BOTTOM_RIGHT);
            pos::set_constraint_adjustment(p, pos::CONSTRAINT_ADJUSTMENT_SLIDE_X | pos::CONSTRAINT_ADJUSTMENT_SLIDE_Y | pos::CONSTRAINT_ADJUSTMENT_FLIP_Y);
        })
    }

    /// A **submenu** (P10.8) beside the row `anchor_y`…`anchor_y + anchor_h`
    /// of this one: its top-left at the row's top-right, `offset_y` up so
    /// its first item is level with the row, flipped to the left when the
    /// display's edge is in the way.
    pub fn submenu(&self, anchor_y: i32, anchor_h: i32, offset_y: i32, width: i32, height: i32, delegate: Weak<dyn PopupDelegate>) -> Option<Rc<Popup>> {
        if self.backing.is_torn_down() {
            return None;
        }
        let anchor = (0, anchor_y, self.width(), anchor_h);
        Popup::open(&self.backing.display, Parent::Xdg(self.xdg_surface), self.backing.scale(), anchor, (width, height), delegate, |p| {
            pos::set_anchor(p, pos::ANCHOR_TOP_RIGHT);
            pos::set_gravity(p, pos::GRAVITY_BOTTOM_RIGHT);
            pos::set_offset(p, 0, -offset_y);
            pos::set_constraint_adjustment(p, pos::CONSTRAINT_ADJUSTMENT_FLIP_X | pos::CONSTRAINT_ADJUSTMENT_SLIDE_Y);
        })
    }

    fn open(display: &Rc<Display>, parent: Parent, scale: i32, anchor: (i32, i32, i32, i32), size: (i32, i32), delegate: Weak<dyn PopupDelegate>, place: impl FnOnce(Obj)) -> Option<Rc<Popup>> {
        let (compositor, wm_base, seat) = {
            let g = display.globals.borrow();
            (g.compositor?, g.wm_base?, g.seat?)
        };
        let surface = wl_compositor::create_surface(compositor)?;
        let xs = xdg_wm_base::get_xdg_surface(wm_base, surface)?;
        let p = xdg_wm_base::create_positioner(wm_base)?;
        pos::set_size(p, size.0, size.1);
        pos::set_anchor_rect(p, anchor.0, anchor.1, anchor.2, anchor.3);
        place(p);
        let popup = match parent {
            Parent::Xdg(x) => xdg_surface::get_popup(xs, Some(x), p),
            Parent::Layer(_) => xdg_surface::get_popup(xs, None, p),
        };
        pos::destroy(p);
        let popup = popup?;
        if let Parent::Layer(ls) = parent {
            zwlr_layer_surface_v1::get_popup(ls, popup)
        }
        let me = Rc::new(Popup { backing: Backing::new(display, surface, "Surface.Popup", size, scale, false), xdg_surface: xs, popup, delegate: RefCell::new(delegate) });
        let w = Rc::downgrade(&me);
        xdg_surface::listen(xs, move |xdg_surface::Event::Configure { serial }| {
            if let Some(p) = w.upgrade() {
                p.configure(serial)
            }
        });
        let w = Rc::downgrade(&me);
        xdg_popup::listen(popup, move |e| match e {
            // The size is our own; where the compositor put it, relative to
            // its parent, is what a test aims a click at (P15.2b).
            xdg_popup::Event::Configure { x, y, width, height } => eprintln!("Surface.Popup: placed at {x},{y} {width}x{height}"),
            xdg_popup::Event::PopupDone {} => {
                if let Some(p) = w.upgrade() {
                    p.done()
                }
            }
            xdg_popup::Event::Repositioned { .. } => {}
        });
        me.backing.attach(Rc::downgrade(&me) as Weak<dyn Role>);
        // The grab quotes the click that opened it, so the compositor
        // dismisses it on one outside.
        xdg_popup::grab(popup, seat, display.last_pointer_serial());
        // The first commit asks for the first configure.
        wl_surface::commit(surface);
        display.flush();
        Some(me)
    }

    fn delegate(&self) -> Option<Rc<dyn PopupDelegate>> {
        self.delegate.borrow().upgrade()
    }

    pub fn set_delegate(&self, d: Weak<dyn PopupDelegate>) {
        *self.delegate.borrow_mut() = d
    }

    fn configure(&self, serial: u32) {
        self.backing.resize(self.backing.size());
        xdg_surface::ack_configure(self.xdg_surface, serial);
        self.backing.mark_dirty();
        if !self.backing.frame_pending() {
            self.backing.render_and_commit()
        }
    }

    fn done(&self) {
        if self.tear_down()
            && let Some(d) = self.delegate()
        {
            d.dismissed(self)
        }
    }

    /// Its width in the parent's points: where a submenu anchors.
    pub fn width(&self) -> i32 {
        self.backing.size().0
    }
    pub fn size(&self) -> (i32, i32) {
        self.backing.size()
    }
    pub fn scale(&self) -> i32 {
        self.backing.scale()
    }
    pub fn is_open(&self) -> bool {
        !self.backing.is_torn_down()
    }

    pub fn set_needs_display(&self) {
        self.backing.set_needs_display()
    }

    /// Take it down (after a choice). Idempotent, and not reported as a
    /// dismissal. **Children first**: destroying a popup that is not the
    /// topmost is a protocol error, so a menu closes its submenus before
    /// itself.
    pub fn close(&self) {
        self.tear_down();
    }

    fn tear_down(&self) -> bool {
        if !self.backing.tear_down() {
            return false;
        }
        xdg_popup::destroy(self.popup);
        xdg_surface::destroy(self.xdg_surface);
        self.backing.destroy_surface();
        true
    }
}

impl Role for Popup {
    fn backing(&self) -> &Backing {
        &self.backing
    }
    fn kind(&self) -> Kind {
        Kind::Popup
    }
    fn paint(&self, target: &RenderTarget) {
        if let Some(d) = self.delegate() {
            d.render(self, target)
        }
    }
    fn pointer_moved(&self, x: f64, y: f64) {
        if let Some(d) = self.delegate() {
            d.pointer_moved(self, x, y)
        }
    }
    fn pointer_button(&self, button: u32, pressed: bool) {
        if button == BTN_LEFT
            && let Some(d) = self.delegate()
        {
            d.pointer_button(self, pressed)
        }
    }
}

impl Drop for Popup {
    fn drop(&mut self) {
        self.tear_down();
    }
}
