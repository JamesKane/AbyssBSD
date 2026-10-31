//! The client side of ext-session-lock-v1 (SessionLock.swift, P16.2b): what
//! the lock screen is to the compositor. A `SessionLock` asks to lock and
//! gives every display a `LockSurface`, one plugged in while locked too,
//! since the compositor shows a display without one as a plain colour. The
//! compositor answers `locked` (once it has drawn a frame with nothing of
//! the desktop in it) or `finished` (it refused, or ended this lock).
//! Unlocking is one request, sent only once the authenticator said yes.
//!
//! **Dying is not unlocking.** A lock client that exits without that
//! request leaves the session locked (undertow's rule, P16.2a): nothing here
//! need be careful about that, only about not asking too early.

use crate::backing::{Backing, Kind, RenderTarget, Role};
use crate::display::{Display, OutputHooks};
use crate::keyboard::KeyEvent;
use abyss_sys::wlc::{ext_session_lock_manager_v1, ext_session_lock_surface_v1 as ls, ext_session_lock_v1 as lock, wl_compositor, Obj};
use std::cell::{Cell, RefCell};
use std::rc::{Rc, Weak};

/// The lock screen's half.
pub trait SessionLockDelegate {
    /// Draw the lock screen for one display.
    fn render(&self, surface: &LockSurface, target: &RenderTarget);
    fn pointer_moved(&self, _surface: &LockSurface, _x: f64, _y: f64) {}
    fn pointer_button(&self, _surface: &LockSurface, _button: u32, _pressed: bool) {}
    /// Keys, from whichever lock surface has the keyboard.
    fn key_event(&self, _event: &KeyEvent) {}
    /// The compositor hid the desktop.
    fn locked(&self) {}
    /// The compositor refused the lock, or ended it.
    fn finished(&self) {}
}

pub struct SessionLock {
    display: Rc<Display>,
    me: Weak<SessionLock>,
    lock: Cell<Option<Obj>>,
    delegate: Weak<dyn SessionLockDelegate>,
    surfaces: RefCell<Vec<Rc<LockSurface>>>,
    is_locked: Cell<bool>,
}

impl SessionLock {
    /// Ask to lock. None when the compositor offers no ext-session-lock: a
    /// lock screen that cannot lock must say so, not pretend.
    pub fn new(display: &Rc<Display>, delegate: Weak<dyn SessionLockDelegate>) -> Option<Rc<SessionLock>> {
        let manager = display.globals.borrow().session_lock_manager?;
        let l = ext_session_lock_manager_v1::lock(manager)?;
        let c = Rc::new_cyclic(|me| SessionLock { display: display.clone(), me: me.clone(), lock: Cell::new(Some(l)), delegate, surfaces: RefCell::default(), is_locked: Cell::new(false) });
        let me = Rc::downgrade(&c);
        lock::listen(l, move |e| {
            let Some(c) = me.upgrade() else { return };
            match e {
                lock::Event::Locked {} => {
                    c.is_locked.set(true);
                    if let Some(d) = c.delegate.upgrade() {
                        d.locked()
                    }
                }
                lock::Event::Finished {} => {
                    c.is_locked.set(false);
                    c.tear_down();
                    if let Some(d) = c.delegate.upgrade() {
                        d.finished()
                    }
                }
            }
        });
        for i in 0..display.output_count() {
            c.add_surface(i)
        }
        let (a, r) = (Rc::downgrade(&c), Rc::downgrade(&c));
        *display.output_hooks.borrow_mut() = Some(OutputHooks {
            added: Rc::new(move |i| {
                if let Some(c) = a.upgrade() {
                    c.add_surface(i)
                }
            }),
            removed: Rc::new(move |o| {
                if let Some(c) = r.upgrade() {
                    c.surfaces.borrow_mut().retain(|s| {
                        if s.output == o {
                            s.close()
                        }
                        s.output != o
                    })
                }
            }),
        });
        display.flush();
        Some(c)
    }

    pub fn is_locked(&self) -> bool {
        self.is_locked.get()
    }

    pub fn surfaces(&self) -> Vec<Rc<LockSurface>> {
        self.surfaces.borrow().clone()
    }

    fn add_surface(&self, index: usize) {
        let (Some(l), Some(output)) = (self.lock.get(), self.display.output(index)) else { return };
        if let Some(s) = LockSurface::new(self, l, output, index) {
            self.surfaces.borrow_mut().push(s)
        }
    }

    /// The authenticator said yes: give the session back. Only then.
    pub fn unlock(&self) {
        let Some(l) = self.lock.take() else { return };
        for s in self.surfaces.borrow_mut().drain(..) {
            s.close()
        }
        lock::unlock_and_destroy(l);
        self.is_locked.set(false);
        self.display.flush();
        self.display.roundtrip()
    }

    fn tear_down(&self) {
        self.display.output_hooks.borrow_mut().take();
        for s in self.surfaces.borrow_mut().drain(..) {
            s.close()
        }
        // `destroy` after `finished` is the protocol's way out; destroying a
        // held lock is a protocol error, so this is reached only for a lock
        // refused or already given back.
        if let Some(l) = self.lock.take() {
            lock::destroy(l)
        }
        self.display.flush()
    }

    pub fn set_needs_display(&self) {
        for s in self.surfaces.borrow().iter() {
            s.set_needs_display()
        }
    }
}

impl Drop for SessionLock {
    fn drop(&mut self) {
        self.tear_down()
    }
}

/// One display's lock surface: always the display's size, as the configure
/// says, and nothing else is allowed.
pub struct LockSurface {
    backing: Backing,
    lock_surface: Obj,
    client: Weak<SessionLock>,
    output: Obj,
    /// The display's place in the registry's order: 0 is the first.
    pub index: usize,
}

impl LockSurface {
    fn new(client: &SessionLock, l: Obj, output: Obj, index: usize) -> Option<Rc<LockSurface>> {
        let display = &client.display;
        let compositor = display.globals.borrow().compositor?;
        let surface = wl_compositor::create_surface(compositor)?;
        let Some(s) = lock::get_lock_surface(l, surface, output) else {
            abyss_sys::wlc::wl_surface::destroy(surface);
            return None;
        };
        let me = Rc::new(LockSurface { backing: Backing::new(display, surface, "Surface.LockSurface", (1, 1), display.output_scale(output), false), lock_surface: s, client: client.me.clone(), output, index });
        let w = Rc::downgrade(&me);
        ls::listen(s, move |ls::Event::Configure { serial, width, height }| {
            if let Some(m) = w.upgrade() {
                m.configure(serial, width as i32, height as i32)
            }
        });
        me.backing.attach(Rc::downgrade(&me) as Weak<dyn Role>);
        Some(me)
    }

    fn delegate(&self) -> Option<Rc<dyn SessionLockDelegate>> {
        self.client.upgrade()?.delegate.upgrade()
    }

    fn configure(&self, serial: u32, w: i32, h: i32) {
        ls::ack_configure(self.lock_surface, serial);
        self.backing.set_scale(self.backing.display.output_scale(self.output));
        self.backing.resize((w.max(1), h.max(1)));
        self.backing.mark_dirty();
        if !self.backing.frame_pending() {
            self.backing.render_and_commit()
        }
    }

    pub fn size(&self) -> (i32, i32) {
        self.backing.size()
    }
    pub fn scale(&self) -> i32 {
        self.backing.scale()
    }

    pub fn set_needs_display(&self) {
        self.backing.set_needs_display()
    }

    fn close(&self) {
        if !self.backing.tear_down() {
            return;
        }
        ls::destroy(self.lock_surface);
        self.backing.destroy_surface();
    }
}

impl Role for LockSurface {
    fn backing(&self) -> &Backing {
        &self.backing
    }
    fn kind(&self) -> Kind {
        Kind::Lock
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
        if let Some(d) = self.delegate() {
            d.pointer_button(self, button, pressed)
        }
    }
    fn key_event(&self, ev: &KeyEvent) {
        if let Some(d) = self.delegate() {
            d.key_event(ev)
        }
    }
}

impl Drop for LockSurface {
    fn drop(&mut self) {
        self.close()
    }
}
