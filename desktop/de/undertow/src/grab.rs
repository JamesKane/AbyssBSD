//! Interactive move and resize (Compositor.swift, P6.7 and P9.4): the
//! client asks, the compositor does. xdg_toplevel has no set-position for a
//! reason: only the compositor may place a window. The seat drives these
//! with the pointer (`cursor`).

use crate::compositor::{Compositor, Toplevel, MINIMUM_WINDOW_HEIGHT, MINIMUM_WINDOW_WIDTH};
use crate::frame::{EDGE_BOTTOM, EDGE_LEFT, EDGE_RIGHT, EDGE_TOP};
use crate::geometry::{snap_rect, snap_zone, Rect, SnapZone};
use std::rc::Rc;

/// A resize in progress: from which edges, where it started, and the edges
/// that stay put.
#[derive(Clone, Copy, Debug, Default)]
pub struct Resize {
    pub edges: u32,
    pub start: (f64, f64),
    pub start_box: Rect,
    pub anchor_right: i32,
    pub anchor_bottom: i32,
}

impl Compositor {
    fn pointer(&self) -> (f64, f64) {
        self.cursor.get().unwrap_or((0.0, 0.0))
    }

    pub fn resizing(&self) -> Option<Rc<Toplevel>> {
        self.resizing.borrow().as_ref().and_then(|(w, _)| w.upgrade())
    }

    pub fn begin_move(&self, t: &Rc<Toplevel>) {
        let (cx, cy) = self.pointer();
        *self.moving.borrow_mut() = Some(Rc::downgrade(t));
        self.move_offset.set((cx - t.x.get() as f64, cy - t.y.get() as f64));
        self.raise(t);
    }

    /// Follow the pointer, clamped so a window can never be dragged off the
    /// desktop and become unreachable: across the whole layout, and never
    /// above the usable top of the display the pointer is on, so a title bar
    /// cannot hide under that display's menu bar.
    pub fn update_move(&self, cx: f64, cy: f64) {
        let Some(t) = self.moving() else { return };
        let (dx, dy) = self.move_offset.get();
        let b = self.layout.borrow().bounds();
        let (max_x, max_y) = ((b.x + b.width - 1) as f64, (b.y + b.height - 1) as f64);
        t.x.set((cx - dx).max((b.x + 1 - t.width()) as f64).min(max_x) as i32);
        t.y.set((cy - dy).max(self.usable_area_at(cx, cy).y as f64).min(max_y) as i32);
    }

    /// End the drag: snap if it ended on an edge, then remember where it
    /// landed. **Snap on release, not during the drag**: a window that
    /// resizes while you move it fights the pointer.
    pub fn end_move(&self) {
        let Some(t) = self.moving.borrow_mut().take().and_then(|w| w.upgrade()) else { return };
        let (cx, cy) = self.pointer();
        let area = self.usable_area_at(cx, cy);
        if let Some(zone) = snap_zone(cx as i32, cy as i32, area) {
            if t.restore_box.get().is_none() {
                t.restore_box.set(Some(t.rect()));
            }
            let b = snap_rect(zone, area);
            t.x.set(b.x);
            t.y.set(b.y);
            t.xdg.set_size(b.width.max(0), b.height.max(0));
            if zone == SnapZone::Maximize {
                self.set_maximized(&t, true);
            }
            self.snap_count.set(self.snap_count.get() + 1);
        }
        self.remember_place(&t);
        // Dropped on another display: it joins the island that one shows.
        self.settle_island(&t, false);
    }

    pub fn begin_resize(&self, t: &Rc<Toplevel>, edges: u32) {
        let start = self.pointer();
        let r = t.rect();
        *self.resizing.borrow_mut() = Some((Rc::downgrade(t), Resize { edges, start, start_box: r, anchor_right: r.x + r.width, anchor_bottom: r.y + r.height }));
        self.resizes_started.set(self.resizes_started.get() + 1);
        self.raise(t);
    }

    /// Follow the pointer. The compositor decides the size; the client
    /// answers with a commit at whatever size it managed, so a left- or
    /// top-dragged window's position is fixed when that commit arrives
    /// (`resize_committed`), or the anchored edge walks.
    pub fn update_resize(&self, cx: f64, cy: f64) {
        let Some((t, r)) = self.resizing.borrow().as_ref().and_then(|(w, r)| w.upgrade().map(|t| (t, *r))) else { return };
        let (dx, dy) = ((cx - r.start.0) as i32, (cy - r.start.1) as i32);
        let (mut w, mut h) = (r.start_box.width, r.start_box.height);
        if r.edges & EDGE_LEFT != 0 {
            w -= dx
        }
        if r.edges & EDGE_RIGHT != 0 {
            w += dx
        }
        if r.edges & EDGE_TOP != 0 {
            h -= dy
        }
        if r.edges & EDGE_BOTTOM != 0 {
            h += dy
        }
        // A window smaller than its own title bar cannot be dragged back.
        t.xdg.set_size(w.max(MINIMUM_WINDOW_WIDTH), h.max(MINIMUM_WINDOW_HEIGHT));
        if r.edges & EDGE_TOP == 0 {
            t.y.set(r.start_box.y)
        }
        if r.edges & EDGE_LEFT == 0 {
            t.x.set(r.start_box.x)
        }
    }

    /// The client committed a new size during a resize: keep the anchored
    /// edges where they were.
    pub fn resize_committed(&self, t: &Toplevel) {
        let Some(r) = self.resizing.borrow().as_ref().filter(|(w, _)| w.upgrade().is_some_and(|o| o.id == t.id)).map(|(_, r)| *r) else { return };
        if r.edges & EDGE_LEFT != 0 {
            t.x.set(r.anchor_right - t.width())
        }
        if r.edges & EDGE_TOP != 0 {
            t.y.set(r.anchor_bottom - t.height())
        }
    }

    pub fn end_resize(&self) {
        let Some((w, _)) = self.resizing.borrow_mut().take() else { return };
        if let Some(t) = w.upgrade() {
            self.remember_place(&t)
        }
    }
}
