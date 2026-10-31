//! A wlr-layer-shell surface (LayerSurface.swift): the shell's anchored,
//! compositor-placed role (the wallpaper, the menu bar, the Dock), where a
//! Window is a floating toplevel. The client picks a layer, the edges it
//! is anchored to and the strip it reserves; the configure says the size
//! the compositor chose.

use crate::backing::{Backing, Kind, RenderTarget, Role};
use crate::display::Display;
use crate::keyboard::KeyEvent;
use crate::popup::{Parent, Popup, PopupDelegate};
use abyss_sys::wlc::{abyss_menu_manager_v1, wl_compositor, wl_surface, zwlr_layer_shell_v1, zwlr_layer_surface_v1 as zls, Obj};
use std::cell::{Cell, RefCell};
use std::rc::{Rc, Weak};

/// The layers, bottom to top.
#[derive(Clone, Copy, PartialEq, Eq, Debug, Default)]
pub enum Layer {
    Background = 0,
    #[default]
    Bottom = 1,
    Top = 2,
    Overlay = 3,
}

/// Screen edges, as bits: two opposite edges stretch the surface across
/// that axis, all four fill the output.
pub mod anchor {
    pub const TOP: u32 = 1;
    pub const BOTTOM: u32 = 2;
    pub const LEFT: u32 = 4;
    pub const RIGHT: u32 = 8;
    pub const ALL: u32 = 15;
}

/// Whether it takes the keyboard.
#[derive(Clone, Copy, PartialEq, Eq, Debug, Default)]
pub enum KeyboardInteractivity {
    #[default]
    None = 0,
    Exclusive = 1,
    OnDemand = 2,
}

/// How a layer surface asks to be placed.
#[derive(Clone, Debug, Default)]
pub struct LayerConfig {
    pub layer: Layer,
    /// What the compositor calls it ("menubar", "dock").
    pub namespace: String,
    /// In points; 0 on an axis anchored to both edges lets the compositor
    /// stretch it.
    pub width: i32,
    pub height: i32,
    pub anchor: u32,
    /// The strip it reserves (a menu bar's height), or -1 to sit under the
    /// others' (a wallpaper).
    pub exclusive_zone: i32,
    pub keyboard: KeyboardInteractivity,
    /// Insets from the anchored edges: top, right, bottom, left.
    pub margin: (i32, i32, i32, i32),
}

/// The shell component's half of a layer surface.
pub trait LayerSurfaceDelegate {
    fn render(&self, surface: &LayerSurface, target: &RenderTarget);
    fn pointer_moved(&self, _surface: &LayerSurface, _x: f64, _y: f64) {}
    fn pointer_button(&self, _surface: &LayerSurface, _button: u32, _pressed: bool) {}
    fn pointer_axis(&self, _surface: &LayerSurface, _axis: u32, _value: f64) {}
    /// The pointer went elsewhere: hover ends (the Dock's magnification).
    fn pointer_left(&self, _surface: &LayerSurface) {}
    fn key_event(&self, _surface: &LayerSurface, _event: &KeyEvent) {}
    fn did_render_frame(&self, _surface: &LayerSurface) {}
    /// The compositor withdrew it (its output went away). By default the
    /// process ends: a shell component without its surface has no work.
    fn closed(&self, surface: &LayerSurface) {
        surface.backing.display.stop()
    }
}

pub struct LayerSurface {
    backing: Backing,
    pub surface: Obj,
    layer_surface: Obj,
    namespace: String,
    delegate: RefCell<Weak<dyn LayerSurfaceDelegate>>,
    mapped: Cell<bool>,
}

impl LayerSurface {
    /// Create and map it; None without layer-shell.
    pub fn new(display: &Rc<Display>, config: &LayerConfig, scale: i32, auto_scale: bool, delegate: Weak<dyn LayerSurfaceDelegate>) -> Option<Rc<LayerSurface>> {
        let (compositor, shell) = {
            let g = display.globals.borrow();
            (g.compositor?, g.layer_shell?)
        };
        let surface = wl_compositor::create_surface(compositor)?;
        let ls = zwlr_layer_shell_v1::get_layer_surface(shell, surface, None, config.layer as u32, &config.namespace)?;
        zls::set_size(ls, config.width.max(0) as u32, config.height.max(0) as u32);
        zls::set_anchor(ls, config.anchor);
        zls::set_exclusive_zone(ls, config.exclusive_zone);
        zls::set_keyboard_interactivity(ls, config.keyboard as u32);
        let (t, r, b, l) = config.margin;
        if config.margin != (0, 0, 0, 0) {
            zls::set_margin(ls, t, r, b, l)
        }
        let size = (config.width.max(1), config.height.max(1));
        let me = Rc::new(LayerSurface {
            backing: Backing::new(display, surface, "Surface.LayerSurface", size, scale, auto_scale),
            surface,
            layer_surface: ls,
            namespace: config.namespace.clone(),
            delegate: RefCell::new(delegate),
            mapped: Cell::new(false),
        });
        let w = Rc::downgrade(&me);
        zls::listen(ls, move |e| {
            let Some(s) = w.upgrade() else { return };
            match e {
                zls::Event::Configure { serial, width, height } => s.configure(serial, width as i32, height as i32),
                zls::Event::Closed {} => {
                    if let Some(d) = s.delegate() {
                        d.closed(&s)
                    }
                }
            }
        });
        me.backing.attach(Rc::downgrade(&me) as Weak<dyn Role>);
        // No buffer yet: this asks for the first configure.
        wl_surface::commit(surface);
        display.flush();
        Some(me)
    }

    fn delegate(&self) -> Option<Rc<dyn LayerSurfaceDelegate>> {
        self.delegate.borrow().upgrade()
    }

    pub fn set_delegate(&self, d: Weak<dyn LayerSurfaceDelegate>) {
        *self.delegate.borrow_mut() = d
    }

    pub fn display(&self) -> &Rc<Display> {
        &self.backing.display
    }

    fn configure(&self, serial: u32, w: i32, h: i32) {
        let (lw, lh) = self.backing.size();
        self.backing.resize((if w > 0 { w } else { lw }, if h > 0 { h } else { lh }));
        zls::ack_configure(self.layer_surface, serial);
        if !self.mapped.replace(true) {
            // The compositor placed it: the live proof the handshake worked.
            let (w, h) = self.backing.size();
            eprintln!("Surface.LayerSurface: mapped {w}x{h} [{}]", self.namespace)
        }
        self.backing.mark_dirty();
        if !self.backing.frame_pending() {
            self.backing.render_and_commit()
        }
    }

    /// Its size in points, as the compositor placed it.
    pub fn size(&self) -> (i32, i32) {
        self.backing.size()
    }
    pub fn scale(&self) -> i32 {
        self.backing.scale()
    }

    pub fn set_needs_display(&self) {
        self.backing.set_needs_display()
    }

    /// Say where this surface's menus are published (P10.3). A layer
    /// surface is never focused as a window is: this means something only
    /// where the compositor gives it a meaning (the desktop's, frontmost
    /// when no window is, P10.4).
    pub fn publish_menus(&self, address: &str) -> bool {
        let Some(m) = self.backing.display.globals.borrow().menu_manager else { return false };
        abyss_menu_manager_v1::set_address(m, self.surface, address);
        self.backing.display.flush();
        true
    }

    /// Open a grabbing popup below a rect in this surface's points: the menu
    /// bar's and the Dock's menus.
    pub fn open_popup(&self, anchor: (i32, i32, i32, i32), width: i32, height: i32, delegate: Weak<dyn PopupDelegate>) -> Option<Rc<Popup>> {
        if self.backing.is_torn_down() {
            return None;
        }
        Popup::below(&self.backing.display, Parent::Layer(self.layer_surface), self.scale(), anchor, width, height, delegate)
    }

    /// Destroy it and leave the display's routing. Idempotent.
    pub fn close(&self) {
        if !self.backing.tear_down() {
            return;
        }
        zls::destroy(self.layer_surface);
        self.backing.destroy_surface();
    }
}

impl Role for LayerSurface {
    fn backing(&self) -> &Backing {
        &self.backing
    }
    fn kind(&self) -> Kind {
        Kind::Layer
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
    fn pointer_left(&self) {
        if let Some(d) = self.delegate() {
            d.pointer_left(self)
        }
    }
    fn key_event(&self, ev: &KeyEvent) {
        if let Some(d) = self.delegate() {
            d.key_event(self, ev)
        }
    }
}

impl Drop for LayerSurface {
    fn drop(&mut self) {
        self.close()
    }
}
