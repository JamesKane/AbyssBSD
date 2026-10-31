//! What every surface this client paints shares: two shm buffers, the
//! buffer scale from the outputs it is shown on, and drawing paced by frame
//! callbacks. Window, Popup and LayerSurface each own one, and are a
//! `Role` to it: what to paint, and where input goes.
//!
//! Swift copied this discipline into each surface class; here it is once.

use crate::display::Display;
use crate::keyboard::KeyEvent;
use abyss_sys::shm::ShmMemory;
use abyss_sys::wlc::{wl_buffer, wl_callback, wl_shm, wl_shm_pool, wl_surface, Obj};
use abyss_sys::Surface;
use std::cell::{Cell, RefCell};
use std::os::fd::AsFd;
use std::rc::{Rc, Weak};

/// What a delegate paints: `surface` is `width`×`height` buffer pixels, the
/// surface's points times `scale`.
pub struct RenderTarget<'a> {
    pub surface: &'a Surface,
    pub width: i32,
    pub height: i32,
    pub scale: i32,
}

/// How the display routes input to a kind of surface.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub(crate) enum Kind {
    Window,
    Popup,
    Layer,
    Lock,
}

/// A painted surface, as its backing and the display see it.
pub(crate) trait Role {
    fn backing(&self) -> &Backing;
    fn kind(&self) -> Kind;
    fn paint(&self, target: &RenderTarget);
    /// After each frame is shown: an animation advances here.
    fn frame_shown(&self) {}
    /// Whether to draw nothing now (a suspended window); `wanted` says a
    /// redraw was asked for, so one held can be counted.
    fn hold(&self, _wanted: bool) -> bool {
        false
    }
    fn pointer_moved(&self, _x: f64, _y: f64) {}
    fn pointer_button(&self, _button: u32, _pressed: bool) {}
    fn pointer_axis(&self, _axis: u32, _value: f64) {}
    fn pointer_left(&self) {}
    fn key_event(&self, _event: &KeyEvent) {}
}

/// A wl_buffer over its own shared memory.
pub(crate) struct ShmBuffer {
    pub(crate) buffer: Obj,
    pub(crate) memory: RefCell<ShmMemory>,
    pub(crate) width: i32,
    pub(crate) height: i32,
    pub(crate) stride: i32,
    pub(crate) busy: Cell<bool>,
}

impl ShmBuffer {
    /// A painted surface's buffer: packed ARGB8888 rows, as cairo's ARGB32.
    /// Screencopy dictates `stride` and `format` instead.
    pub(crate) fn new(display: &Display, width: i32, height: i32, stride: Option<i32>, format: u32) -> Option<Rc<ShmBuffer>> {
        let shm = display.globals.borrow().shm?;
        let stride_ = stride.unwrap_or(width * 4);
        if width <= 0 || height <= 0 || stride_ < if stride.is_none() { width * 4 } else { width } {
            return None;
        }
        let len = stride_ as usize * height as usize;
        let (memory, fd) = ShmMemory::new(len)?;
        let pool = wl_shm::create_pool(shm, fd.as_fd(), len as i32)?;
        let buffer = wl_shm_pool::create_buffer(pool, 0, width, height, stride_, format);
        // The compositor has its own mapping now.
        wl_shm_pool::destroy(pool);
        let b = Rc::new(ShmBuffer { buffer: buffer?, memory: RefCell::new(memory), width, height, stride: stride_, busy: Cell::new(false) });
        let me = Rc::downgrade(&b);
        wl_buffer::listen(b.buffer, move |wl_buffer::Event::Release {}| {
            if let Some(b) = me.upgrade() {
                b.busy.set(false)
            }
        });
        Some(b)
    }
}

impl Drop for ShmBuffer {
    fn drop(&mut self) {
        wl_buffer::destroy(self.buffer)
    }
}

pub(crate) struct Backing {
    pub(crate) display: Rc<Display>,
    pub(crate) surface: Obj,
    role: RefCell<Option<Weak<dyn Role>>>,
    /// Whose log line a scale change is ("Surface.Window").
    who: &'static str,
    scale: Cell<i32>,
    auto_scale: bool,
    entered: RefCell<Vec<Obj>>,
    size: Cell<(i32, i32)>,
    buffers: RefCell<Vec<Rc<ShmBuffer>>>,
    needs_redraw: Cell<bool>,
    frame_pending: Cell<bool>,
    frame_callback: Cell<Option<Obj>>,
    rendering: Cell<bool>,
    torn_down: Cell<bool>,
}

impl Backing {
    pub(crate) fn new(display: &Rc<Display>, surface: Obj, who: &'static str, size: (i32, i32), scale: i32, auto_scale: bool) -> Backing {
        Backing {
            display: display.clone(),
            surface,
            role: RefCell::new(None),
            who,
            scale: Cell::new(scale.max(1)),
            auto_scale,
            entered: RefCell::default(),
            size: Cell::new(size),
            buffers: RefCell::default(),
            needs_redraw: Cell::new(true),
            frame_pending: Cell::new(false),
            frame_callback: Cell::new(None),
            rendering: Cell::new(false),
            torn_down: Cell::new(false),
        }
    }

    /// Bind it to its owner, hear which outputs it is shown on, and join the
    /// display's routing.
    pub(crate) fn attach(&self, role: Weak<dyn Role>) {
        *self.role.borrow_mut() = Some(role.clone());
        let me = role.clone();
        wl_surface::listen(self.surface, move |e| {
            let Some(r) = me.upgrade() else { return };
            let b = r.backing();
            match e {
                wl_surface::Event::Enter { output: Some(o) } => {
                    if !b.entered.borrow().contains(&o) {
                        b.entered.borrow_mut().push(o)
                    }
                    b.recompute_scale()
                }
                wl_surface::Event::Leave { output: Some(o) } => {
                    b.entered.borrow_mut().retain(|x| *x != o);
                    b.recompute_scale()
                }
                _ => {}
            }
        });
        self.display.register(role);
    }

    fn role(&self) -> Option<Rc<dyn Role>> {
        self.role.borrow().as_ref()?.upgrade()
    }

    pub(crate) fn scale(&self) -> i32 {
        self.scale.get()
    }
    pub(crate) fn size(&self) -> (i32, i32) {
        self.size.get()
    }
    pub(crate) fn is_torn_down(&self) -> bool {
        self.torn_down.get()
    }
    pub(crate) fn frame_pending(&self) -> bool {
        self.frame_pending.get()
    }
    pub(crate) fn mark_dirty(&self) {
        self.needs_redraw.set(true)
    }

    /// A pinned scale, from what the owner knows of its output: fresh
    /// buffers at the next `resize`.
    pub(crate) fn set_scale(&self, s: i32) {
        if s.max(1) != self.scale.get() {
            self.scale.set(s.max(1));
            self.buffers.borrow_mut().clear()
        }
    }

    /// A new size in points: fresh buffers when it changed, or there are
    /// none yet.
    pub(crate) fn resize(&self, size: (i32, i32)) {
        if size != self.size.get() || self.buffers.borrow().is_empty() {
            self.size.set(size);
            self.allocate_buffers()
        }
    }

    fn allocate_buffers(&self) {
        let (w, h) = self.size.get();
        let s = self.scale.get();
        let fresh: Vec<Rc<ShmBuffer>> = (0..2).filter_map(|_| ShmBuffer::new(&self.display, w * s, h * s, None, wl_shm::FORMAT_ARGB8888)).collect();
        *self.buffers.borrow_mut() = fresh;
    }

    /// Draw again: now, unless a frame is in flight (its `done` draws), or
    /// this is inside the drawing (the next frame has it).
    pub(crate) fn set_needs_display(&self) {
        if self.torn_down.get() {
            return;
        }
        self.needs_redraw.set(true);
        if !self.frame_pending.get() && !self.rendering.get() {
            self.render_and_commit()
        }
    }

    /// The buffer scale from the outputs it is on: the largest (HiDPI). A
    /// no-op when pinned.
    pub(crate) fn recompute_scale(&self) {
        if !self.auto_scale {
            return;
        }
        let s = self.entered.borrow().iter().map(|o| self.display.output_scale(*o)).max().unwrap_or(1).max(1);
        if s == self.scale.get() {
            return;
        }
        self.scale.set(s);
        eprintln!("{}: buffer scale -> {s}x", self.who);
        if !self.buffers.borrow().is_empty() {
            self.allocate_buffers();
            self.needs_redraw.set(true);
            if !self.frame_pending.get() {
                self.render_and_commit()
            }
        }
    }

    pub(crate) fn render_and_commit(&self) {
        if self.torn_down.get() {
            return;
        }
        let Some(role) = self.role() else { return };
        // An ack still needs a commit, with no new buffer.
        if role.hold(self.needs_redraw.get()) {
            self.needs_redraw.set(true);
            wl_surface::commit(self.surface);
            self.display.flush();
            return;
        }
        let Some(buf) = self.buffers.borrow().iter().find(|b| !b.busy.get()).cloned() else {
            // Both busy: the next release or frame retries.
            self.needs_redraw.set(true);
            return;
        };
        self.needs_redraw.set(false);
        self.rendering.set(true);
        let scale = self.scale.get();
        buf.memory.borrow_mut().draw(buf.width, buf.height, buf.stride, |cs| role.paint(&RenderTarget { surface: cs, width: buf.width, height: buf.height, scale }));
        self.rendering.set(false);
        buf.busy.set(true);
        wl_surface::attach(self.surface, Some(buf.buffer), 0, 0);
        wl_surface::set_buffer_scale(self.surface, scale);
        wl_surface::damage_buffer(self.surface, 0, 0, buf.width, buf.height);
        if let Some(cb) = wl_surface::frame(self.surface) {
            self.frame_callback.set(Some(cb));
            self.frame_pending.set(true);
            let me = Rc::downgrade(&role);
            wl_callback::listen(cb, move |_| {
                // `done` ends the callback's life.
                wl_callback::destroy(cb);
                if let Some(r) = me.upgrade() {
                    r.backing().frame_callback.set(None);
                    r.backing().frame_done(&*r)
                }
            });
        }
        wl_surface::commit(self.surface);
        self.display.flush();
    }

    fn frame_done(&self, role: &dyn Role) {
        self.frame_pending.set(false);
        if self.torn_down.get() {
            return;
        }
        role.frame_shown();
        if self.needs_redraw.get() {
            self.render_and_commit()
        }
    }

    /// Leave the routing and drop the buffers and the frame in flight; the
    /// owner then destroys its role objects, and `destroy_surface` last.
    /// False if it was already torn down.
    pub(crate) fn tear_down(&self) -> bool {
        if self.torn_down.replace(true) {
            return false;
        }
        self.display.unregister(self.surface);
        self.buffers.borrow_mut().clear();
        // **The pending frame callback first** (P15.6): a `done` for a
        // surface already gone is a call into nothing.
        if let Some(c) = self.frame_callback.take() {
            wl_callback::destroy(c)
        }
        true
    }

    pub(crate) fn destroy_surface(&self) {
        wl_surface::destroy(self.surface);
        self.display.flush();
    }
}
