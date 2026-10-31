//! relative-pointer-v1 and pointer-constraints-v1 (PointerConstraints.swift,
//! BACKLOG U.6): a game turns the camera with the mouse and wants how far
//! it moved, not a pointer that goes anywhere.
//!
//! - **relative-pointer**: every motion is also a delta to the client with
//!   the pointer, even at the display's edge;
//! - **pointer-constraints**: a client may LOCK the pointer (deltas only)
//!   or CONFINE it to a region of its surface.
//!
//! When one takes effect is ours, as sway keeps it: while its surface has
//! the pointer AND belongs to the focused window (a lock must not survive
//! ⌘-Tab), and only once the pointer is inside its region. A lock's
//! cursor-position hint is where the pointer goes when it ends. A move or
//! resize owns the pointer, constraint or not.

use crate::seat::Seat;
use abyss_sys::wlr::{globals, Constraint, ConstraintManager, Display, Listener, RelativePointerManager};
use std::cell::{Cell, RefCell};
use std::rc::Weak;

pub struct PointerConstraints {
    relative: RelativePointerManager,
    manager: ConstraintManager,
    pub(crate) entries: RefCell<Vec<(Constraint, Vec<Listener>)>>,
    pub(crate) listener: RefCell<Option<Listener>>,
    /// The constraint in force, if any.
    active: Cell<Option<Constraint>>,
    /// For the log a test reads: `held` counts motions a constraint
    /// changed, swallowed by a lock or pulled back into a confinement.
    pub locks: Cell<u64>,
    pub confines: Cell<u64>,
    pub held: Cell<u64>,
    pub warps: Cell<u64>,
}

impl PointerConstraints {
    pub fn new(d: &Display, seat: Weak<Seat>) -> Option<PointerConstraints> {
        let pc = PointerConstraints {
            relative: globals::relative_pointer_manager(d)?,
            manager: globals::pointer_constraints(d)?,
            entries: RefCell::default(),
            listener: RefCell::default(),
            active: Cell::new(None),
            locks: Cell::new(0),
            confines: Cell::new(0),
            held: Cell::new(0),
            warps: Cell::new(0),
        };
        *pc.listener.borrow_mut() = pc.manager.on_new_constraint(move |c| {
            if let Some(s) = seat.upgrade() {
                s.new_constraint(c)
            }
        });
        Some(pc)
    }

    pub fn is_active(&self) -> bool {
        self.active.get().is_some()
    }
}

impl Seat {
    fn constraints(&self) -> Option<&PointerConstraints> {
        self.pointer_constraints.as_ref()
    }

    pub(crate) fn new_constraint(&self, c: Constraint) {
        let Some(pc) = self.constraints() else { return };
        let (w1, w2) = (self.me.clone(), self.me.clone());
        let ls = [
            // The region is double-buffered: it changes on the commit.
            c.on_set_region(move || {
                if let Some(s) = w1.upgrade() {
                    s.refresh_constraints()
                }
            }),
            c.on_destroy(move || {
                if let Some(s) = w2.upgrade() {
                    s.constraint_gone(c)
                }
            }),
        ]
        .into_iter()
        .flatten()
        .collect();
        pc.entries.borrow_mut().push((c, ls));
        // It may apply at once: a game locks when clicked.
        self.refresh_constraints();
    }

    fn constraint_gone(&self, c: Constraint) {
        let Some(pc) = self.constraints() else { return };
        if pc.active.get() == Some(c) {
            pc.active.set(None);
            self.warp_to_hint(c);
        }
        // Off both signals, from inside one (HANDOFF §2.82).
        let gone: Vec<_> = {
            let mut e = pc.entries.borrow_mut();
            let (out, keep): (Vec<_>, Vec<_>) = std::mem::take(&mut *e).into_iter().partition(|(o, _)| *o == c);
            *e = keep;
            out
        };
        drop(gone);
    }

    /// Every motion, as a delta, to whoever has the pointer.
    pub(crate) fn send_relative(&self, time_msec: u32, d: (f64, f64), unaccel: (f64, f64)) {
        if let Some(pc) = self.constraints() {
            pc.relative.send(self.seat, time_msec, d, unaccel)
        }
    }

    /// Where a motion from `from` toward `to` goes, in layout coordinates;
    /// None when it goes nowhere (locked).
    pub(crate) fn constrain(&self, from: (f64, f64), to: (f64, f64)) -> Option<(f64, f64)> {
        let Some(pc) = self.constraints() else { return Some(to) };
        let Some(c) = pc.active.get() else { return Some(to) };
        let Some((ox, oy)) = self.constraint_origin(c, from) else { return Some(to) };
        if c.locked() {
            pc.held.set(pc.held.get() + 1);
            return None;
        }
        let (lx, ly) = (to.0 - ox, to.1 - oy);
        if c.contains(lx, ly) {
            return Some(to);
        }
        pc.held.set(pc.held.get() + 1);
        // Outside: the region's nearest point; an empty one holds still.
        Some(c.nearest(lx, ly).map_or(from, |(nx, ny)| (ox + nx, oy + ny)))
    }

    /// Bring the constraint in force up to date with who has the pointer
    /// and the keyboard: after every motion, on every focus change, and as
    /// constraints arrive or change their regions.
    pub fn refresh_constraints(&self) {
        let Some(pc) = self.constraints() else { return };
        let want = self.seat.pointer_focused().and_then(|(s, sx, sy)| {
            if !self.c().focused().is_some_and(|t| s.root() == t.surface) {
                return None;
            }
            let c = pc.manager.for_surface(s, self.seat)?;
            (pc.active.get() == Some(c) || c.contains(sx, sy)).then_some(c)
        });
        if want == pc.active.get() {
            return;
        }
        if let Some(a) = pc.active.take() {
            self.warp_to_hint(a);
            // May destroy it (oneshot): constraint_gone finds it inactive.
            a.send_deactivated();
        }
        if let Some(w) = want {
            pc.active.set(Some(w));
            let n = if w.locked() { &pc.locks } else { &pc.confines };
            n.set(n.get() + 1);
            w.send_activated();
        }
    }

    /// The constraint's surface's origin in layout coordinates, from where
    /// the seat last told it the pointer was; None unless it has it.
    fn constraint_origin(&self, c: Constraint, cursor: (f64, f64)) -> Option<(f64, f64)> {
        let (s, sx, sy) = self.seat.pointer_focused()?;
        (Some(s) == c.surface()).then_some((cursor.0 - sx, cursor.1 - sy))
    }

    /// A lock ending: the pointer goes where the client said it drew it.
    fn warp_to_hint(&self, c: Constraint) {
        if !c.locked() {
            return;
        }
        let (Some((hx, hy)), Some((ox, oy))) = (c.hint(), self.constraint_origin(c, self.cursor.get())) else { return };
        self.warp_cursor(ox + hx, oy + hy, hx, hy);
        if let Some(pc) = self.constraints() {
            pc.warps.set(pc.warps.get() + 1)
        }
    }
}
