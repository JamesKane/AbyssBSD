//! An xdg-shell toplevel over shm buffers (Window.swift). The toolkit plugs
//! in as a `WindowDelegate`: it paints a cairo surface the buffer's size,
//! and hears pointer and keys in the window's own points. Drawing is paced
//! by frame callbacks, over two buffers so a present never waits for one.

use crate::backing::{Backing, Kind, RenderTarget, Role};
use crate::display::Display;
use crate::keyboard::KeyEvent;
use crate::popup::{Parent, Popup, PopupDelegate};
use abyss_sys::wlc::{abyss_menu_manager_v1, abyss_window_manager_v1, u32s, wl_compositor, wl_surface, xdg_surface, xdg_toplevel, xdg_wm_base, Obj};
use std::cell::{Cell, RefCell};
use std::rc::{Rc, Weak};

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

fn log(msg: &str) {
    eprintln!("Surface.Window: {msg}")
}

pub struct Window {
    backing: Backing,
    /// The `wl_surface`: a drag names the surface it started from.
    pub surface: Obj,
    pub(crate) xdg_surface: Obj,
    toplevel: Obj,
    delegate: RefCell<Weak<dyn WindowDelegate>>,
    pending: Cell<(i32, i32)>,
    pending_states: RefCell<Vec<u32>>,
    maximized: Cell<bool>,
    fullscreen: Cell<bool>,
    activated: Cell<bool>,
    resizing: Cell<bool>,
    suspended: Cell<bool>,
    capabilities: RefCell<Option<Vec<u32>>>,
    bounds: Cell<Option<(i32, i32)>>,
    redraws_held: Cell<u32>,
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
            backing: Backing::new(display, surface, "Surface.Window", (width, height), scale, auto_scale),
            surface,
            xdg_surface: xs,
            toplevel,
            delegate: RefCell::new(delegate),
            pending: Cell::new((width, height)),
            pending_states: RefCell::default(),
            maximized: Cell::new(false),
            fullscreen: Cell::new(false),
            activated: Cell::new(false),
            resizing: Cell::new(false),
            suspended: Cell::new(false),
            capabilities: RefCell::new(None),
            bounds: Cell::new(None),
            redraws_held: Cell::new(0),
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
        xdg_toplevel::set_title(toplevel, title);
        xdg_toplevel::set_app_id(toplevel, app_id);
        // The first commit asks for the first configure.
        w.backing.attach(Rc::downgrade(&w) as Weak<dyn Role>);
        wl_surface::commit(surface);
        Some(w)
    }

    fn delegate(&self) -> Option<Rc<dyn WindowDelegate>> {
        self.delegate.borrow().upgrade()
    }

    pub fn set_delegate(&self, d: Weak<dyn WindowDelegate>) {
        *self.delegate.borrow_mut() = d
    }

    pub fn display(&self) -> &Rc<Display> {
        &self.backing.display
    }

    /// Destroy its surfaces and leave the display's routing. Idempotent.
    ///
    /// **The destructor requests, not a proxy freed**: freeing the local
    /// proxy tells the compositor nothing, and a surface left mapped there
    /// swallows every click where the window was (P9.3).
    pub fn close(&self) {
        if !self.backing.tear_down() {
            return;
        }
        xdg_toplevel::destroy(self.toplevel);
        xdg_surface::destroy(self.xdg_surface);
        self.backing.destroy_surface();
    }

    /// End the run loop (the one-window `should_close`).
    pub fn stop_display(&self) {
        self.backing.display.stop()
    }

    /// Draw again. From inside render, the frame being drawn already has
    /// it; the next frame draws again.
    pub fn set_needs_display(&self) {
        self.backing.set_needs_display()
    }

    pub fn scale(&self) -> i32 {
        self.backing.scale()
    }
    /// The window's size in points.
    pub fn size(&self) -> (i32, i32) {
        self.backing.size()
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
            self.backing.mark_dirty();
            if let Some(d) = self.delegate() {
                d.state_changed(self)
            }
        }
        self.backing.resize((pw, ph));
        xdg_surface::ack_configure(self.xdg_surface, serial);
        self.backing.mark_dirty();
        if !self.backing.frame_pending() {
            self.backing.render_and_commit()
        }
    }

    // MARK: what a window may ask about itself (P9.4)

    /// Hand the pointer to the compositor to move the window: a request, on
    /// the press, quoting its serial (§4.2).
    pub fn begin_move(&self) {
        let Some(seat) = self.backing.display.globals.borrow().seat else { return };
        if self.backing.is_torn_down() {
            return;
        }
        xdg_toplevel::r#move(self.toplevel, seat, self.backing.display.last_pointer_serial());
        self.backing.display.flush()
    }

    pub fn begin_resize(&self, edge: ResizeEdge) {
        let Some(seat) = self.backing.display.globals.borrow().seat else { return };
        if self.backing.is_torn_down() {
            return;
        }
        xdg_toplevel::resize(self.toplevel, seat, self.backing.display.last_pointer_serial(), edge.0);
        self.backing.display.flush()
    }

    /// Zoom: what maximized means is the compositor's (undertow's is the
    /// usable area, less the menu bar).
    pub fn set_maximized(&self, on: bool) {
        if self.backing.is_torn_down() {
            return;
        }
        if !self.can_maximize() {
            return log("not zooming: the compositor does not maximise");
        }
        if on { xdg_toplevel::set_maximized(self.toplevel) } else { xdg_toplevel::unset_maximized(self.toplevel) }
        self.backing.display.flush()
    }

    /// Minimize. The protocol has no un-minimize: the compositor restores.
    pub fn minimize(&self) -> bool {
        if self.backing.is_torn_down() {
            return false;
        }
        if !self.can_minimize() {
            log("not minimising: the compositor does not");
            return false;
        }
        xdg_toplevel::set_minimized(self.toplevel);
        self.backing.display.flush();
        true
    }

    pub fn set_fullscreen(&self, on: bool) {
        if self.backing.is_torn_down() {
            return;
        }
        if on { xdg_toplevel::set_fullscreen(self.toplevel, None) } else { xdg_toplevel::unset_fullscreen(self.toplevel) }
        self.backing.display.flush()
    }

    /// Send it behind the others (the depth gadget, P11.6): abyss-window-v1,
    /// so false under anything but undertow.
    pub fn lower(&self) -> bool {
        let Some((m, _)) = self.backing.display.globals.borrow().window_manager else { return false };
        if self.backing.is_torn_down() {
            return false;
        }
        abyss_window_manager_v1::lower(m, self.toplevel);
        self.backing.display.flush();
        true
    }

    /// Say where this window's menus are published (P10.3), or "" to
    /// withdraw them; false when the compositor does not speak it.
    pub fn publish_menus(&self, address: &str) -> bool {
        let Some(m) = self.backing.display.globals.borrow().menu_manager else { return false };
        abyss_menu_manager_v1::set_address(m, self.surface, address);
        self.backing.display.flush();
        true
    }

    /// Open a grabbing popup (a menu) below a rect in this window's points.
    /// The caller owns it; dropping it, or the compositor's `popup_done`,
    /// takes it down.
    pub fn open_popup(&self, anchor: (i32, i32, i32, i32), width: i32, height: i32, delegate: Weak<dyn PopupDelegate>) -> Option<Rc<Popup>> {
        if self.backing.is_torn_down() {
            return None;
        }
        Popup::below(&self.backing.display, Parent::Xdg(self.xdg_surface), self.scale(), anchor, width, height, delegate)
    }

    /// Ask the compositor to raise it (xdg-activation); false without the
    /// protocol.
    pub fn activate(&self) -> bool {
        !self.backing.is_torn_down() && self.backing.display.activate(self.surface)
    }

    pub fn set_title(&self, title: &str) {
        if !self.backing.is_torn_down() {
            xdg_toplevel::set_title(self.toplevel, title)
        }
    }
}

impl Role for Window {
    fn backing(&self) -> &Backing {
        &self.backing
    }
    fn kind(&self) -> Kind {
        Kind::Window
    }
    fn paint(&self, target: &RenderTarget) {
        if let Some(d) = self.delegate() {
            d.render(self, target)
        }
    }
    fn frame_shown(&self) {
        if let Some(d) = self.delegate() {
            d.did_render_frame(self)
        }
    }
    /// **Not for nobody** (T.3): the configure that ends the suspension asks
    /// again.
    fn hold(&self, wanted: bool) -> bool {
        if self.suspended.get() && wanted {
            self.redraws_held.set(self.redraws_held.get() + 1)
        }
        self.suspended.get()
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
    fn pointer_axis(&self, axis: u32, value: f64) {
        if let Some(d) = self.delegate() {
            d.pointer_axis(self, axis, value)
        }
    }
    fn key_event(&self, ev: &KeyEvent) {
        if let Some(d) = self.delegate() {
            d.key_event(self, ev)
        }
    }
}

impl Drop for Window {
    fn drop(&mut self) {
        self.close()
    }
}

