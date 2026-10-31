//! ext-session-lock-v1 (SessionLock.swift, PHASE16 P16.2a).
//!
//! A lock client asks to lock the session; from then until it unlocks,
//! **nothing of the desktop is shown and nothing of it is reachable**: every
//! output draws the lock client's surface and nothing else, and the pointer
//! and keys go to those surfaces alone. The security boundary of the session
//! (PHASE16 §6.6), so the rules are sway's and the protocol's:
//!
//! - **One lock at a time.** A second client asking while a lock is held is
//!   told `finished`.
//! - **A lock client that dies without unlocking leaves the session
//!   locked** ("abandoned"): the lock colour, input reaching nothing, and a
//!   new lock client may take over, which is how a person gets back in.
//! - **`locked` is said after a frame**, so the frame that hides everything
//!   has been drawn before the client is told.
//! - Windows that map while locked are neither drawn nor focused.
//!
//! What the pointer and keyboard do about it is the seat's: it hears
//! `LockEvent`s through `Compositor::on_lock`.

use crate::backend::log;
use crate::compositor::Compositor;
use crate::displays::DisplayBox;
use abyss_sys::wlr::{Listener, Lock, LockSurface, Surface};
use std::cell::RefCell;
use std::rc::Rc;

/// What the seat is told.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum LockEvent {
    /// Nothing behind the lock keeps the pointer, the keys or a grab.
    Locked,
    /// A lock surface drew: it may take the keyboard and the pointer.
    SurfaceCommitted(Surface),
    /// The keys go back to the window that was frontmost.
    Unlocked,
}

pub struct LockEntry {
    pub lock_surface: LockSurface,
    pub surface: Surface,
    listeners: RefCell<Vec<Listener>>,
}

impl LockEntry {
    pub fn output_name(&self) -> String {
        self.lock_surface.output().map(|o| o.name()).unwrap_or_default()
    }
}

#[derive(Default)]
pub struct LockState {
    /// The lock held; None when none is (unlocked, or abandoned).
    lock: Option<Lock>,
    lock_listeners: Vec<Listener>,
    pub surfaces: Vec<Rc<LockEntry>>,
    /// `locked` is owed to the client, after the next frame.
    locked_owed: bool,
    /// **The session is locked**: held, or abandoned by a client that died.
    pub locked: bool,
    pub locks: u64,
    pub unlocks: u64,
    pub refused: u64,
    pub abandonments: u64,
    manager_listener: Option<Listener>,
}

impl LockState {
    /// Locked with nobody holding the lock: its client died.
    pub fn abandoned(&self) -> bool {
        self.locked && self.lock.is_none()
    }

    pub(crate) fn clear(&mut self) {
        self.manager_listener = None;
        self.lock_listeners.clear();
        self.surfaces.clear();
    }
}

impl Compositor {
    pub fn is_locked(&self) -> bool {
        self.lock.borrow().locked
    }

    pub(crate) fn listen_for_locks(&self, m: abyss_sys::wlr::LockManager) {
        let w = self.me.clone();
        self.lock.borrow_mut().manager_listener = m.on_new_lock(move |l| {
            if let Some(c) = w.upgrade() {
                c.new_lock(l)
            }
        });
    }

    fn lock_event(&self, e: LockEvent) {
        if let Some(f) = &*self.lock_hook.borrow() {
            f(e)
        }
    }

    fn new_lock(&self, l: Lock) {
        let was_abandoned = {
            let st = self.lock.borrow();
            // Somebody holds it: they keep it (`finished` to this one).
            if st.lock.is_some() {
                drop(st);
                self.lock.borrow_mut().refused += 1;
                log("session lock refused: another client holds the lock");
                l.destroy();
                return;
            }
            st.abandoned()
        };
        let w = || self.me.clone();
        let (a, b, d) = (w(), w(), w());
        let ls: Vec<Listener> = [
            l.on_new_surface(move |s| {
                if let Some(c) = a.upgrade() {
                    c.new_lock_surface(s)
                }
            }),
            l.on_unlock(move || {
                if let Some(c) = b.upgrade() {
                    c.unlocked()
                }
            }),
            l.on_destroy(move || {
                if let Some(c) = d.upgrade() {
                    c.lock_gone()
                }
            }),
        ]
        .into_iter()
        .flatten()
        .collect();
        {
            let mut st = self.lock.borrow_mut();
            st.lock = Some(l);
            st.locked = true;
            st.locks += 1;
            st.locked_owed = true;
            st.lock_listeners = ls;
        }
        log(if was_abandoned { "session locked again, taking over an abandoned lock" } else { "session locked" });
        self.lock_event(LockEvent::Locked);
    }

    fn new_lock_surface(&self, s: LockSurface) {
        let e = Rc::new(LockEntry { lock_surface: s, surface: s.surface(), listeners: RefCell::default() });
        let (w1, e1) = (self.me.clone(), Rc::downgrade(&e));
        let (w2, e2) = (self.me.clone(), Rc::downgrade(&e));
        let ls: Vec<Listener> = [
            s.on_destroy(move || {
                let (Some(c), Some(e)) = (w1.upgrade(), e1.upgrade()) else { return };
                // Its listeners dropped from inside this one (§2.82).
                c.lock.borrow_mut().surfaces.retain(|o| !Rc::ptr_eq(o, &e));
            }),
            // The first buffer: it may take the keyboard if no lock surface
            // has it.
            e.surface.on_commit(move || {
                let (Some(c), Some(e)) = (w2.upgrade(), e2.upgrade()) else { return };
                c.lock_event(LockEvent::SurfaceCommitted(e.surface));
            }),
        ]
        .into_iter()
        .flatten()
        .collect();
        *e.listeners.borrow_mut() = ls;
        // Its output's whole size, in the layout's points.
        let name = e.output_name();
        let (w, h) = self.layout.borrow().named(&name).map_or((0, 0), |d| (d.width, d.height));
        self.lock.borrow_mut().surfaces.push(e);
        s.configure(w as u32, h as u32);
    }

    fn unlocked(&self) {
        let gone = {
            let mut st = self.lock.borrow_mut();
            st.locked = false;
            st.unlocks += 1;
            st.lock = None;
            std::mem::take(&mut st.surfaces)
        };
        drop(gone);
        log("session unlocked");
        self.lock_event(LockEvent::Unlocked);
        // Focus did not move while locked: the bar hears who is frontmost.
        self.menus_focus_changed();
    }

    /// The lock object went. After `unlock` that is the end of it; without,
    /// the client died holding the lock, and the session stays locked.
    fn lock_gone(&self) {
        let mut st = self.lock.borrow_mut();
        let ls = std::mem::take(&mut st.lock_listeners);
        let held = st.lock.take().is_some();
        if held {
            st.locked_owed = false;
            st.abandonments += 1;
        }
        drop(st);
        drop(ls); // this listener among them, from inside its callback
        if held {
            log("the lock client went without unlocking: the session STAYS locked");
        }
    }

    /// Once a frame has been drawn under the lock, say so to its client.
    pub fn lock_frame_drawn(&self) {
        let l = {
            let mut st = self.lock.borrow_mut();
            if !st.locked_owed {
                return;
            }
            st.locked_owed = false;
            st.lock
        };
        if let Some(l) = l {
            l.send_locked()
        }
    }

    /// The lock surface for display `name`, with a buffer.
    pub fn lock_surface_on(&self, name: &str) -> Option<Surface> {
        self.lock.borrow().surfaces.iter().find(|e| e.output_name() == name && e.surface.has_buffer()).map(|e| e.surface)
    }

    /// Every lock surface with a buffer, with the display it covers.
    pub fn lock_mapped(&self) -> Vec<(Surface, DisplayBox)> {
        let l = self.layout.borrow();
        self.lock.borrow().surfaces.iter().filter(|e| e.surface.has_buffer()).filter_map(|e| l.named(&e.output_name()).map(|d| (e.surface, d.clone()))).collect()
    }

    /// The lock surface the keyboard belongs to: the main display's, else any.
    pub fn lock_keyboard_target(&self) -> Option<Surface> {
        let main = self.layout.borrow().main().map(|m| m.name.clone());
        main.and_then(|m| self.lock_surface_on(&m)).or_else(|| self.lock_mapped().first().map(|(s, _)| *s))
    }

    /// Who hears what the lock does: the seat (R4e).
    pub fn on_lock(&self, f: impl Fn(LockEvent) + 'static) {
        *self.lock_hook.borrow_mut() = Some(Box::new(f));
    }
}
