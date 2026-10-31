//! An xdg-shell toplevel over shm buffers (Window.swift). The toolkit plugs
//! in as a `WindowDelegate`: it paints a cairo surface the buffer's size,
//! and hears pointer and keys in the window's own points. Drawing is paced
//! by frame callbacks, over two buffers so a present never waits for one.

use crate::display::Display;
use crate::keyboard::KeyEvent;
use abyss_sys::shm::ShmMemory;
use abyss_sys::wlc::{abyss_menu_manager_v1, abyss_window_manager_v1, u32s, wl_buffer, wl_callback, wl_compositor, wl_shm, wl_shm_pool, wl_surface, xdg_surface, xdg_toplevel, xdg_wm_base, Obj};
use abyss_sys::Surface;
use std::cell::{Cell, RefCell};
use std::os::fd::AsFd;
use std::rc::{Rc, Weak};

/// What a delegate paints: `surface` is `width`×`height` buffer pixels, the
/// window's points times `scale`.
pub struct RenderTarget<'a> {
    pub surface: &'a Surface,
    pub width: i32,
    pub height: i32,
    pub scale: i32,
}

/// The toolkit's half of a window. Methods take `&self`: a delegate keeps
/// its state in Cells, and may call back into the window from any of them.
pub trait WindowDelegate {
    fn render(&self, window: &Window, target: &RenderTarget);
    fn pointer_moved(&self, _window: &Window, _x: f64, _y: f64) {}
    fn pointer_button(&self, _window: &Window, _button: u32, _pressed: bool) {}
    /// `axis` 0 is vertical, 1 horizontal; `value` in points, positive down
    /// or right.
    fn pointer_axis(&self, _window: &Window, _axis: u32, _value: f64) {}
    fn key_event(&self, _window: &Window, _event: &KeyEvent) {}
    /// After each frame is shown: advance an animation and ask again.
    fn did_render_frame(&self, _window: &Window) {}
    /// The compositor asked it to close. One window's default: the process
    /// ends.
    fn should_close(&self, window: &Window) {
        window.stop_display()
    }
    /// Maximized, fullscreen or activated changed: what the compositor says
    /// the window *is* (P9.4).
    fn state_changed(&self, _window: &Window) {}
}

/// Which edges an interactive resize drags: `xdg_toplevel.resize_edge`'s
/// own values, so the compositor knows which corner stays put.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ResizeEdge(pub u32);

impl ResizeEdge {
    pub const TOP: ResizeEdge = ResizeEdge(1);
    pub const BOTTOM: ResizeEdge = ResizeEdge(2);
    pub const LEFT: ResizeEdge = ResizeEdge(4);
    pub const RIGHT: ResizeEdge = ResizeEdge(8);
    pub const TOP_LEFT: ResizeEdge = ResizeEdge(5);
    pub const TOP_RIGHT: ResizeEdge = ResizeEdge(9);
    pub const BOTTOM_LEFT: ResizeEdge = ResizeEdge(6);
    pub const BOTTOM_RIGHT: ResizeEdge = ResizeEdge(10);
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

fn log(msg: &str) {
    eprintln!("Surface.Window: {msg}")
}

pub struct Window {
    display: Rc<Display>,
    /// The `wl_surface`: a drag names the surface it started from.
    pub surface: Obj,
    xdg_surface: Obj,
    toplevel: Obj,
    delegate: RefCell<Weak<dyn WindowDelegate>>,
    scale: Cell<i32>,
    auto_scale: bool,
    entered: RefCell<Vec<Obj>>,
    logical: Cell<(i32, i32)>,
    pending: Cell<(i32, i32)>,
    pending_states: RefCell<Vec<u32>>,
    maximized: Cell<bool>,
    fullscreen: Cell<bool>,
    activated: Cell<bool>,
    resizing: Cell<bool>,
    suspended: Cell<bool>,
    capabilities: RefCell<Option<Vec<u32>>>,
    bounds: Cell<Option<(i32, i32)>>,
    buffers: RefCell<Vec<Rc<ShmBuffer>>>,
    needs_redraw: Cell<bool>,
    frame_pending: Cell<bool>,
    frame_callback: Cell<Option<Obj>>,
    rendering: Cell<bool>,
    redraws_held: Cell<u32>,
    torn_down: Cell<bool>,
}

impl Window {
    /// A toplevel `width`×`height` points. `auto_scale` follows the outputs
    /// it is shown on; otherwise `scale` is pinned.
    #[allow(clippy::too_many_arguments)]
    pub fn new(display: &Rc<Display>, title: &str, app_id: &str, width: i32, height: i32, scale: i32, auto_scale: bool, delegate: Weak<dyn WindowDelegate>) -> Option<Rc<Window>> {
        let (compositor, wm_base) = {
            let g = display.globals.borrow();
            (g.compositor?, g.wm_base?)
        };
        let surface = wl_compositor::create_surface(compositor)?;
        let xs = xdg_wm_base::get_xdg_surface(wm_base, surface)?;
        let toplevel = xdg_surface::get_toplevel(xs)?;
        let w = Rc::new(Window {
            display: display.clone(),
            surface,
            xdg_surface: xs,
            toplevel,
            delegate: RefCell::new(delegate),
            scale: Cell::new(scale.max(1)),
            auto_scale,
            entered: RefCell::default(),
            logical: Cell::new((width, height)),
            pending: Cell::new((width, height)),
            pending_states: RefCell::default(),
            maximized: Cell::new(false),
            fullscreen: Cell::new(false),
            activated: Cell::new(false),
            resizing: Cell::new(false),
            suspended: Cell::new(false),
            capabilities: RefCell::new(None),
            bounds: Cell::new(None),
            buffers: RefCell::default(),
            needs_redraw: Cell::new(true),
            frame_pending: Cell::new(false),
            frame_callback: Cell::new(None),
            rendering: Cell::new(false),
            redraws_held: Cell::new(0),
            torn_down: Cell::new(false),
        });
        let me = Rc::downgrade(&w);
        xdg_surface::listen(xs, move |xdg_surface::Event::Configure { serial }| {
            if let Some(w) = me.upgrade() {
                w.apply_configure(serial)
            }
        });
        let me = Rc::downgrade(&w);
        xdg_toplevel::listen(toplevel, move |e| {
            let Some(w) = me.upgrade() else { return };
            match e {
                // **The states are half of what a configure says**: without
                // them a window cannot know it was maximized.
                xdg_toplevel::Event::Configure { width, height, states } => {
                    let (pw, ph) = w.pending.get();
                    w.pending.set((if width > 0 { width } else { pw }, if height > 0 { height } else { ph }));
                    *w.pending_states.borrow_mut() = u32s(&states);
                }
                xdg_toplevel::Event::Close {} => {
                    if let Some(d) = w.delegate() {
                        d.should_close(&w)
                    }
                }
                xdg_toplevel::Event::ConfigureBounds { width, height } => w.bounds.set((width > 0 && height > 0).then_some((width, height))),
                xdg_toplevel::Event::WmCapabilities { capabilities } => {
                    let caps = u32s(&capabilities);
                    let names: Vec<&str> = [(xdg_toplevel::WM_CAPABILITIES_WINDOW_MENU, "window-menu"), (xdg_toplevel::WM_CAPABILITIES_MAXIMIZE, "maximize"), (xdg_toplevel::WM_CAPABILITIES_FULLSCREEN, "fullscreen"), (xdg_toplevel::WM_CAPABILITIES_MINIMIZE, "minimize")]
                        .into_iter()
                        .filter(|(c, _)| caps.contains(c))
                        .map(|(_, n)| n)
                        .collect();
                    log(&format!("the compositor serves: {}", if names.is_empty() { "nothing".into() } else { names.join(" ") }));
                    *w.capabilities.borrow_mut() = Some(caps);
                }
            }
        });
        // The outputs it is shown on, for the buffer scale.
        let me = Rc::downgrade(&w);
        wl_surface::listen(surface, move |e| {
            let Some(w) = me.upgrade() else { return };
            match e {
                wl_surface::Event::Enter { output: Some(o) } => {
                    if !w.entered.borrow().contains(&o) {
                        w.entered.borrow_mut().push(o)
                    }
                    w.recompute_scale()
                }
                wl_surface::Event::Leave { output: Some(o) } => {
                    w.entered.borrow_mut().retain(|x| *x != o);
                    w.recompute_scale()
                }
                _ => {}
            }
        });
        xdg_toplevel::set_title(toplevel, title);
        xdg_toplevel::set_app_id(toplevel, app_id);
        // The first commit asks for the first configure.
        wl_surface::commit(surface);
        display.register(&w);
        Some(w)
    }

    fn delegate(&self) -> Option<Rc<dyn WindowDelegate>> {
        self.delegate.borrow().upgrade()
    }

    pub fn set_delegate(&self, d: Weak<dyn WindowDelegate>) {
        *self.delegate.borrow_mut() = d
    }

    pub fn display(&self) -> &Rc<Display> {
        &self.display
    }

    /// Destroy its surfaces and leave the display's routing. Idempotent.
    ///
    /// **The destructor requests, not a proxy freed**: freeing the local
    /// proxy tells the compositor nothing, and a surface left mapped there
    /// swallows every click where the window was (P9.3).
    pub fn close(&self) {
        if self.torn_down.replace(true) {
            return;
        }
        self.display.unregister(self);
        self.buffers.borrow_mut().clear();
        // **The pending frame callback first** (P15.6): a `done` for a
        // window already gone is a call into nothing.
        if let Some(c) = self.frame_callback.take() {
            wl_callback::destroy(c)
        }
        xdg_toplevel::destroy(self.toplevel);
        xdg_surface::destroy(self.xdg_surface);
        wl_surface::destroy(self.surface);
        self.display.flush();
    }

    /// End the run loop (the one-window `should_close`).
    pub fn stop_display(&self) {
        self.display.stop()
    }

    pub fn set_needs_display(&self) {
        if self.torn_down.get() {
            return;
        }
        self.needs_redraw.set(true);
        // From inside render, the frame being drawn already has it; the
        // next frame draws again.
        if !self.frame_pending.get() && !self.rendering.get() {
            self.render_and_commit()
        }
    }

    pub fn scale(&self) -> i32 {
        self.scale.get()
    }
    /// The window's size in points.
    pub fn size(&self) -> (i32, i32) {
        self.logical.get()
    }
    /// What the compositor last said the window is: read this rather than
    /// remembering what was asked, which the compositor may refuse.
    pub fn is_maximized(&self) -> bool {
        self.maximized.get()
    }
    pub fn is_fullscreen(&self) -> bool {
        self.fullscreen.get()
    }
    pub fn is_activated(&self) -> bool {
        self.activated.get()
    }
    /// While an interactive resize asked for runs.
    pub fn is_resizing(&self) -> bool {
        self.resizing.get()
    }
    /// **Nobody can see it** (xdg-shell v6, T.3): nothing is drawn, and a
    /// redraw asked for happens once, when it can be seen again.
    pub fn is_suspended(&self) -> bool {
        self.suspended.get()
    }
    /// The most room the compositor will give a window (v4), if it said.
    pub fn bounds(&self) -> Option<(i32, i32)> {
        self.bounds.get()
    }
    /// A compositor that never said (below v5) serves everything.
    fn can(&self, cap: u32) -> bool {
        self.capabilities.borrow().as_ref().is_none_or(|c| c.contains(&cap))
    }
    pub fn can_minimize(&self) -> bool {
        self.can(xdg_toplevel::WM_CAPABILITIES_MINIMIZE)
    }
    pub fn can_maximize(&self) -> bool {
        self.can(xdg_toplevel::WM_CAPABILITIES_MAXIMIZE)
    }

    fn apply_configure(&self, serial: u32) {
        // **The states take effect here, with the size**: a configure is
        // one atomic answer.
        let states = self.pending_states.borrow().clone();
        let has = |s: u32| states.contains(&s);
        let was = (self.maximized.get(), self.fullscreen.get(), self.activated.get());
        let was_suspended = self.suspended.get();
        self.maximized.set(has(xdg_toplevel::STATE_MAXIMIZED));
        self.fullscreen.set(has(xdg_toplevel::STATE_FULLSCREEN));
        self.activated.set(has(xdg_toplevel::STATE_ACTIVATED));
        self.resizing.set(has(xdg_toplevel::STATE_RESIZING));
        self.suspended.set(has(xdg_toplevel::STATE_SUSPENDED));
        if self.suspended.get() != was_suspended {
            if self.suspended.get() {
                log("suspended: nobody can see it; drawing nothing")
            } else {
                log(&format!("resumed after {} redraw(s) held; drawing once", self.redraws_held.get()));
                self.redraws_held.set(0)
            }
        }
        // The size left to us (0×0): keep within the bounds, so a window on
        // a small display fits it.
        let (mut pw, mut ph) = self.pending.get();
        if let Some((bw, bh)) = self.bounds.get()
            && (pw > bw || ph > bh)
            && !self.maximized.get()
            && !self.fullscreen.get()
        {
            pw = pw.min(bw);
            ph = ph.min(bh);
            self.pending.set((pw, ph));
        }
        if (self.maximized.get(), self.fullscreen.get(), self.activated.get()) != was {
            self.needs_redraw.set(true);
            if let Some(d) = self.delegate() {
                d.state_changed(self)
            }
        }
        if (pw, ph) != self.logical.get() || self.buffers.borrow().is_empty() {
            self.logical.set((pw, ph));
            self.allocate_buffers();
        }
        xdg_surface::ack_configure(self.xdg_surface, serial);
        self.needs_redraw.set(true);
        if !self.frame_pending.get() {
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
        log(&format!("buffer scale -> {s}x"));
        if !self.buffers.borrow().is_empty() {
            self.allocate_buffers();
            self.needs_redraw.set(true);
            if !self.frame_pending.get() {
                self.render_and_commit()
            }
        }
    }

    fn allocate_buffers(&self) {
        let (w, h) = self.logical.get();
        let s = self.scale.get();
        let fresh: Vec<Rc<ShmBuffer>> = (0..2).filter_map(|_| ShmBuffer::new(&self.display, w * s, h * s, None, wl_shm::FORMAT_ARGB8888)).collect();
        *self.buffers.borrow_mut() = fresh;
    }

    fn render_and_commit(&self) {
        if self.torn_down.get() {
            return;
        }
        // **Not for nobody** (T.3): the configure that ends the suspension
        // asks again. An ack still needs a commit, with no new buffer.
        if self.suspended.get() {
            if self.needs_redraw.get() {
                self.redraws_held.set(self.redraws_held.get() + 1)
            }
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
        if let Some(d) = self.delegate() {
            self.rendering.set(true);
            let scale = self.scale.get();
            buf.memory.borrow_mut().draw(buf.width, buf.height, buf.stride, |cs| d.render(self, &RenderTarget { surface: cs, width: buf.width, height: buf.height, scale }));
            self.rendering.set(false);
        }
        buf.busy.set(true);
        wl_surface::attach(self.surface, Some(buf.buffer), 0, 0);
        wl_surface::set_buffer_scale(self.surface, self.scale.get());
        wl_surface::damage_buffer(self.surface, 0, 0, buf.width, buf.height);
        if let Some(cb) = wl_surface::frame(self.surface) {
            self.frame_callback.set(Some(cb));
            self.frame_pending.set(true);
            let me = self.display.clone();
            let surface = self.surface;
            wl_callback::listen(cb, move |_| {
                // `done` ends the callback's life.
                wl_callback::destroy(cb);
                let w = me.window_by_surface(surface);
                if let Some(w) = w {
                    w.frame_callback.set(None);
                    w.frame_done()
                }
            });
        }
        wl_surface::commit(self.surface);
        self.display.flush();
    }

    fn frame_done(&self) {
        self.frame_pending.set(false);
        if self.torn_down.get() {
            return;
        }
        if let Some(d) = self.delegate() {
            d.did_render_frame(self)
        }
        if self.needs_redraw.get() {
            self.render_and_commit()
        }
    }

    pub(crate) fn pointer_moved(&self, x: f64, y: f64) {
        if let Some(d) = self.delegate() {
            d.pointer_moved(self, x, y)
        }
    }
    pub(crate) fn pointer_button(&self, button: u32, pressed: bool) {
        if let Some(d) = self.delegate() {
            d.pointer_button(self, button, pressed)
        }
    }
    pub(crate) fn pointer_axis(&self, axis: u32, value: f64) {
        if let Some(d) = self.delegate() {
            d.pointer_axis(self, axis, value)
        }
    }
    pub(crate) fn key_event(&self, ev: &KeyEvent) {
        if let Some(d) = self.delegate() {
            d.key_event(self, ev)
        }
    }

    // MARK: what a window may ask about itself (P9.4)

    /// Hand the pointer to the compositor to move the window: a request, on
    /// the press, quoting its serial (§4.2).
    pub fn begin_move(&self) {
        let Some(seat) = self.display.globals.borrow().seat else { return };
        if self.torn_down.get() {
            return;
        }
        xdg_toplevel::r#move(self.toplevel, seat, self.display.last_pointer_serial());
        self.display.flush()
    }

    pub fn begin_resize(&self, edge: ResizeEdge) {
        let Some(seat) = self.display.globals.borrow().seat else { return };
        if self.torn_down.get() {
            return;
        }
        xdg_toplevel::resize(self.toplevel, seat, self.display.last_pointer_serial(), edge.0);
        self.display.flush()
    }

    /// Zoom: what maximized means is the compositor's (undertow's is the
    /// usable area, less the menu bar).
    pub fn set_maximized(&self, on: bool) {
        if self.torn_down.get() {
            return;
        }
        if !self.can_maximize() {
            return log("not zooming: the compositor does not maximise");
        }
        if on { xdg_toplevel::set_maximized(self.toplevel) } else { xdg_toplevel::unset_maximized(self.toplevel) }
        self.display.flush()
    }

    /// Minimize. The protocol has no un-minimize: the compositor restores.
    pub fn minimize(&self) -> bool {
        if self.torn_down.get() {
            return false;
        }
        if !self.can_minimize() {
            log("not minimising: the compositor does not");
            return false;
        }
        xdg_toplevel::set_minimized(self.toplevel);
        self.display.flush();
        true
    }

    pub fn set_fullscreen(&self, on: bool) {
        if self.torn_down.get() {
            return;
        }
        if on { xdg_toplevel::set_fullscreen(self.toplevel, None) } else { xdg_toplevel::unset_fullscreen(self.toplevel) }
        self.display.flush()
    }

    /// Send it behind the others (the depth gadget, P11.6): abyss-window-v1,
    /// so false under anything but undertow.
    pub fn lower(&self) -> bool {
        let Some((m, _)) = self.display.globals.borrow().window_manager else { return false };
        if self.torn_down.get() {
            return false;
        }
        abyss_window_manager_v1::lower(m, self.toplevel);
        self.display.flush();
        true
    }

    /// Say where this window's menus are published (P10.3), or "" to
    /// withdraw them; false when the compositor does not speak it.
    pub fn publish_menus(&self, address: &str) -> bool {
        let Some(m) = self.display.globals.borrow().menu_manager else { return false };
        abyss_menu_manager_v1::set_address(m, self.surface, address);
        self.display.flush();
        true
    }

    pub fn set_title(&self, title: &str) {
        if !self.torn_down.get() {
            xdg_toplevel::set_title(self.toplevel, title)
        }
    }
}

impl Drop for Window {
    fn drop(&mut self) {
        self.close()
    }
}

