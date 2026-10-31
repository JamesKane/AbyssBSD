//! Grab: pictures of the screen (GrabApp.swift, P15.6).
//!
//! Jaguar's Grab: Capture ▸ Selection (drag a rectangle), Window (click the
//! window you want), Screen, and Timed Screen; each picture opens in a
//! window of its own, to be saved through the portal (a PNG, through the
//! Finder's save picker) or copied. The picture is the output's pixels from
//! screencopy, cropped.
//!
//! **The overlay is never in the picture**: Selection and Window draw on a
//! layer surface over the output, closed (and the compositor told) before
//! the screen is copied. **The pointer is in it where the compositor draws
//! it in software**: screencopy can leave out only a hardware cursor.
//!
//! **Window mode asks the compositor which window is under the pointer**
//! (`abyss_window_manager_v1.window_at`): foreign-toplevel names windows
//! but does not place them. The box includes undertow's frame.
//!
//! Known limits: one output (the first); Grab's own windows are in a Screen
//! capture, as anything on screen is (Timed Screen keeps them out).
//!
//! What a test reads (`ABYSS_GRAB_DUMP=1`): where the panel's buttons are,
//! what was captured, and what was saved.

use crate::commands::key_equivalent_of;
use crate::textedit::{ask_portal, save_fd};
use crate::toolkit::Toolkit;
use abyss_sys::Surface;
use aquadraw::canvas::Canvas;
use aquadraw::chrome::{chrome_hit, window_chrome, ChromeEdge, ChromeHit, Gadget};
use aquadraw::color::Color;
use aquadraw::draw::paint_window_chrome;
use aquadraw::drawlist::Role;
use aquadraw::runner::Rect;
use aquadraw::text::Style;
use current_ipc::Msg;
use menu_model::{Command, CommandResult, Enablement, KeyEquivalent, Menu, MenuBarModel, MenuItem, Modifiers};
use menu_wire::{MenuProvider, MenuService};
use std::cell::{Cell, RefCell};
use std::collections::BTreeMap;
use std::rc::{Rc, Weak};
use std::time::Duration;
use surface::layer::{anchor, KeyboardInteractivity, Layer};
use surface::screencopy::ScreenCapture;
use surface::{Display, KeyEvent, KeyModifiers, KeySym, LayerConfig, LayerSurface, LayerSurfaceDelegate, RenderTarget, ResizeEdge, Window, WindowAt, WindowDelegate};

// MARK: - The vocabulary

pub const VERB_ABOUT: &str = "app.about";
pub const VERB_QUIT: &str = "app.quit";
pub const VERB_CLOSE: &str = "file.close";
pub const VERB_SAVE: &str = "file.save";
pub const VERB_COPY: &str = "edit.copy";
pub const VERB_SELECTION: &str = "capture.selection";
pub const VERB_WINDOW: &str = "capture.window";
pub const VERB_SCREEN: &str = "capture.screen";
pub const VERB_TIMED: &str = "capture.timed";
pub const VERB_MINIMIZE: &str = "window.minimize";

pub fn grab_menu_bar() -> MenuBarModel {
    let c = |v: &str, t: &str, k: Option<(char, Modifiers)>, s: &str| {
        let cmd = Command::new(v, t, s);
        MenuItem::Command(match k {
            Some((ch, m)) => cmd.with_key(KeyEquivalent::cmd(ch, m)),
            None => cmd,
        })
    };
    let (n, sh) = (Modifiers::NONE, Modifiers::SHIFT);
    MenuBarModel::new(
        "Grab",
        vec![
            Menu::new("Grab", vec![c(VERB_ABOUT, "About Grab", None, "Show Grab's version."), MenuItem::Separator, c(VERB_QUIT, "Quit Grab", Some(('q', n)), "Close Grab.")]),
            Menu::new("File", vec![c(VERB_CLOSE, "Close", Some(('w', n)), "Close this picture."), c(VERB_SAVE, "Save…", Some(('s', n)), "Save this picture as a PNG.")]),
            Menu::new("Edit", vec![c(VERB_COPY, "Copy", Some(('c', n)), "Copy this picture.")]),
            Menu::new(
                "Capture",
                vec![
                    c(VERB_SELECTION, "Selection", Some(('a', sh)), "Drag a rectangle to capture."),
                    c(VERB_WINDOW, "Window", Some(('w', sh)), "Click a window to capture it."),
                    c(VERB_SCREEN, "Screen", Some(('z', n)), "Capture the whole screen."),
                    c(VERB_TIMED, "Timed Screen", Some(('z', sh)), "Capture the screen in ten seconds."),
                ],
            ),
            Menu::new("Window", vec![c(VERB_MINIMIZE, "Minimize", Some(('m', n)), "Put the window in the Dock.")]),
        ],
    )
}

fn log(s: &str) {
    eprintln!("Grab: {s}")
}

fn dump() -> bool {
    std::env::var_os("ABYSS_GRAB_DUMP").is_some()
}

/// Timed Screen's wait, in seconds: ten, as Grab's; a test may shorten it.
fn timer_seconds() -> u32 {
    std::env::var("ABYSS_GRAB_TIMER").ok().and_then(|s| s.parse().ok()).unwrap_or(10)
}

fn ok() -> CommandResult {
    CommandResult::Ok(None)
}
fn refused(s: &str) -> CommandResult {
    CommandResult::Refused(s.into())
}

/// Ask the compositor to move or resize: a client cannot do either itself.
fn chrome_request(w: &Window, hit: ChromeHit) {
    match hit {
        ChromeHit::Gadget(Gadget::Minimize) => {
            w.minimize();
        }
        ChromeHit::Gadget(Gadget::Zoom) => w.set_maximized(!w.is_maximized()),
        ChromeHit::Gadget(Gadget::Depth) => {
            w.lower();
        }
        ChromeHit::Title => w.begin_move(),
        ChromeHit::Resize(e) => w.begin_resize(match e {
            ChromeEdge::Bottom => ResizeEdge::BOTTOM,
            ChromeEdge::BottomLeft => ResizeEdge::BOTTOM_LEFT,
            ChromeEdge::BottomRight => ResizeEdge::BOTTOM_RIGHT,
        }),
        _ => {}
    }
}

// MARK: - Pictures

/// A picture: pixels as the screen gave them (B, G, R, X), four bytes each.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct GrabImage {
    pub width: usize,
    pub height: usize,
    pub pixels: Vec<u8>,
}

impl GrabImage {
    /// The part of `capture` inside (x, y, w, h), clamped to it; None when
    /// nothing of the rectangle is on it.
    pub fn crop(capture: &ScreenCapture, x: i64, y: i64, w: i64, h: i64) -> Option<GrabImage> {
        let (x0, y0) = (x.max(0) as usize, y.max(0) as usize);
        let (x1, y1) = ((x + w).min(capture.width as i64).max(0) as usize, (y + h).min(capture.height as i64).max(0) as usize);
        if x1 <= x0 || y1 <= y0 {
            return None;
        }
        let stride = capture.stride();
        let pixels = (y0..y1).flat_map(|row| capture.pixels[row * stride + x0 * 4..row * stride + x1 * 4].iter().copied()).collect();
        Some(GrabImage { width: x1 - x0, height: y1 - y0, pixels })
    }

    fn surface(&self) -> Option<Surface> {
        Surface::rgb24(self.width as i32, self.height as i32, &self.pixels)
    }

    /// The picture as PNG bytes (opaque RGB).
    pub fn png(&self) -> Option<Vec<u8>> {
        self.surface()?.png_bytes()
    }
}

/// A picture in a window: grey around it, scaled down to fit, never up.
pub fn paint_grab_document(c: &mut Canvas, w: f64, h: f64, title: &str, image: &GrabImage) {
    paint_window_chrome(c.runner, c.theme, c.cr, w, h, title, false, true);
    let t = c.theme.tokens.clone();
    let area = Rect::new(0.0, t.title_bar_height, w, (h - t.title_bar_height - t.chrome_resize_band).max(0.0));
    c.set_color(Color::hex(0x9A9A9A, 1.0));
    c.cr.rectangle(area.x, area.y, area.w, area.h);
    c.cr.fill();
    let Some(s) = image.surface() else { return };
    let (iw, ih) = (image.width as f64, image.height as f64);
    let k = (area.w / iw).min(area.h / ih).min(1.0);
    c.cr.save();
    c.cr.translate(area.x + (area.w - iw * k) / 2.0, area.y + (area.h - ih * k) / 2.0);
    c.cr.scale(k, k);
    c.cr.set_source_surface(&s, 0.0, 0.0, false, false);
    c.cr.paint();
    c.cr.restore()
}

// MARK: - The overlay

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum OverlayMode {
    Selection,
    Window,
}

/// The chosen rectangle in the overlay's points, and the window it was.
type Done = Box<dyn FnOnce(Option<Rect>, Option<WindowAt>, (i32, i32))>;

/// Selection or Window, on a layer surface over the whole output.
struct Overlay {
    mode: OverlayMode,
    display: Rc<Display>,
    toolkit: Rc<Toolkit>,
    layer: RefCell<Option<Rc<LayerSurface>>>,
    start: Cell<Option<(f64, f64)>>,
    current: Cell<(f64, f64)>,
    hovered: RefCell<Option<WindowAt>>,
    last_query: Cell<Option<(i32, i32)>>,
    done: RefCell<Option<Done>>,
}

fn span(a: (f64, f64), b: (f64, f64)) -> Rect {
    Rect::new(a.0.min(b.0), a.1.min(b.1), (a.0 - b.0).abs(), (a.1 - b.1).abs())
}

impl Overlay {
    fn new(display: &Rc<Display>, toolkit: &Rc<Toolkit>, mode: OverlayMode, done: Done) -> Option<Rc<Overlay>> {
        let o = Rc::new(Overlay { mode, display: display.clone(), toolkit: toolkit.clone(), layer: RefCell::new(None), start: Cell::new(None), current: Cell::new((0.0, 0.0)), hovered: RefCell::new(None), last_query: Cell::new(None), done: RefCell::new(Some(done)) });
        let config = LayerConfig { layer: Layer::Overlay, namespace: "abyss.grab".into(), anchor: anchor::ALL, exclusive_zone: -1, keyboard: KeyboardInteractivity::Exclusive, ..LayerConfig::default() };
        let l = LayerSurface::new(display, &config, 1, true, Rc::downgrade(&o) as Weak<dyn LayerSurfaceDelegate>)?;
        *o.layer.borrow_mut() = Some(l);
        Some(o)
    }

    /// Close the overlay, then say what was chosen.
    fn finish(&self, rect: Option<Rect>, window: Option<WindowAt>) {
        let size = self.layer.borrow().as_ref().map_or((0, 0), |l| l.size());
        if let Some(l) = self.layer.borrow_mut().take() {
            l.close()
        }
        if let Some(f) = self.done.borrow_mut().take() {
            f(rect, window, size)
        }
    }

    fn redraw(&self) {
        if let Some(l) = self.layer.borrow().as_ref() {
            l.set_needs_display()
        }
    }
}

impl LayerSurfaceDelegate for Overlay {
    fn render(&self, _s: &LayerSurface, target: &RenderTarget) {
        let hovered = self.hovered.borrow().clone();
        self.toolkit.draw(target, |c, _w, _h| {
            let outline = |c: &mut Canvas, r: Rect, fill: bool| {
                if fill {
                    c.set_color(Color::new(0.22, 0.46, 0.84, 0.25));
                    c.cr.rectangle(r.x, r.y, r.w, r.h);
                    c.cr.fill()
                }
                c.cr.set_line_width(1.0);
                c.set_color(Color::new(0.0, 0.0, 0.0, 0.8));
                c.cr.rectangle(r.x + 0.5, r.y + 0.5, (r.w - 1.0).max(0.0), (r.h - 1.0).max(0.0));
                c.cr.stroke();
                c.set_color(Color::new(1.0, 1.0, 1.0, 0.9));
                c.cr.rectangle(r.x + 1.5, r.y + 1.5, (r.w - 3.0).max(0.0), (r.h - 3.0).max(0.0));
                c.cr.stroke()
            };
            match (self.mode, self.start.get(), hovered) {
                (OverlayMode::Selection, Some(s), _) => {
                    let r = span(s, self.current.get());
                    outline(c, r, false);
                    c.text_left(&format!("{} × {}", r.w as i64, r.h as i64), r.x + 4.0, r.y + r.h + 16.0, Color::new(1.0, 1.0, 1.0, 1.0), 11.0, Style::Regular, Role::Interface)
                }
                (OverlayMode::Window, _, Some(w)) => outline(c, Rect::new(f64::from(w.x), f64::from(w.y), f64::from(w.width), f64::from(w.height)), true),
                _ => {}
            }
        })
    }

    fn pointer_moved(&self, _s: &LayerSurface, x: f64, y: f64) {
        self.current.set((x, y));
        if self.mode == OverlayMode::Window {
            let p = (x as i32, y as i32);
            if self.last_query.get() != Some(p) {
                self.last_query.set(Some(p));
                *self.hovered.borrow_mut() = self.display.window_at(p.0, p.1)
            }
        }
        self.redraw()
    }

    fn pointer_button(&self, _s: &LayerSurface, button: u32, pressed: bool) {
        if button != 0x110 {
            return;
        }
        match self.mode {
            OverlayMode::Selection => {
                if pressed {
                    self.start.set(Some(self.current.get()));
                    return self.redraw();
                }
                let Some(s) = self.start.get() else { return };
                let r = span(s, self.current.get());
                if r.w < 1.0 || r.h < 1.0 {
                    return self.start.set(None);
                }
                self.finish(Some(r), None)
            }
            OverlayMode::Window => {
                if !pressed {
                    return;
                }
                let (x, y) = self.current.get();
                let w = self.display.window_at(x as i32, y as i32);
                *self.hovered.borrow_mut() = w.clone();
                if let Some(w) = w {
                    let r = Rect::new(f64::from(w.x), f64::from(w.y), f64::from(w.width), f64::from(w.height));
                    self.finish(Some(r), Some(w))
                }
            }
        }
    }

    fn key_event(&self, _s: &LayerSurface, e: &KeyEvent) {
        if e.pressed && e.keysym == KeySym::ESCAPE {
            self.finish(None, None)
        }
    }
}

// MARK: - A picture's window

pub struct GrabDocument {
    me: Weak<GrabDocument>,
    app: Weak<GrabApp>,
    window: RefCell<Option<Rc<Window>>>,
    pub image: GrabImage,
    path: RefCell<Option<String>>,
    pointer: Cell<(f64, f64)>,
    shown: RefCell<String>,
}

impl GrabDocument {
    fn new(app: &Rc<GrabApp>, image: GrabImage) -> Option<Rc<GrabDocument>> {
        let t = app.toolkit.theme.borrow().tokens.clone();
        // As big as the picture, up to most of a screen; it scales down.
        let w = image.width.clamp(240, 800) as i32;
        let h = t.title_bar_height as i32 + image.height.clamp(120, 600) as i32;
        let d = Rc::new_cyclic(|me| GrabDocument { me: me.clone(), app: Rc::downgrade(app), window: RefCell::new(None), image, path: RefCell::new(None), pointer: Cell::new((0.0, 0.0)), shown: RefCell::default() });
        let pinned = std::env::var("AQUA_SCALE").ok().and_then(|s| s.parse::<i32>().ok()).filter(|v| *v > 0);
        let win = Window::new(&app.display, "", "org.abyssbsd.grab", w, h + t.chrome_resize_band as i32, pinned.unwrap_or(1), pinned.is_none(), Rc::downgrade(&d) as Weak<dyn WindowDelegate>)?;
        *d.window.borrow_mut() = Some(win);
        d.update_title();
        Some(d)
    }

    fn window(&self) -> Option<Rc<Window>> {
        self.window.borrow().clone()
    }

    fn update_title(&self) {
        let name = self.path.borrow().as_deref().map_or("Untitled".into(), |p| p.rsplit('/').next().unwrap_or(p).to_string());
        let t = format!("{name} — {} × {}", self.image.width, self.image.height);
        if *self.shown.borrow() != t {
            if let Some(w) = self.window() {
                w.set_title(&t)
            }
            *self.shown.borrow_mut() = t
        }
    }

    fn saved(&self, p: &str) {
        *self.path.borrow_mut() = Some(p.into());
        self.update_title()
    }

    fn close(&self) {
        if let Some(w) = self.window.borrow_mut().take() {
            w.close()
        }
        if let (Some(a), Some(me)) = (self.app.upgrade(), self.me.upgrade()) {
            a.documents.borrow_mut().retain(|d| !Rc::ptr_eq(d, &me))
        }
    }
}

impl WindowDelegate for GrabDocument {
    fn render(&self, _w: &Window, target: &RenderTarget) {
        let Some(app) = self.app.upgrade() else { return };
        let title = self.shown.borrow().clone();
        app.toolkit.draw(target, |c, w, h| paint_grab_document(c, w, h, &title, &self.image))
    }
    fn pointer_moved(&self, _w: &Window, x: f64, y: f64) {
        self.pointer.set((x, y))
    }
    fn pointer_button(&self, w: &Window, _button: u32, pressed: bool) {
        let Some(app) = self.app.upgrade().filter(|_| pressed) else { return };
        let (x, y) = self.pointer.get();
        let (sw, sh) = w.size();
        let t = app.toolkit.theme.borrow().tokens.clone();
        match chrome_hit(&t, &window_chrome(&t, sw as f64, sh as f64, false), x, y) {
            ChromeHit::Gadget(Gadget::Close) => self.close(),
            hit => chrome_request(w, hit),
        }
    }
    fn key_event(&self, _w: &Window, e: &KeyEvent) {
        if let Some(a) = self.app.upgrade() {
            a.key(e, self.me.upgrade())
        }
    }
    fn should_close(&self, _w: &Window) {
        self.close()
    }
}

// MARK: - The panel

/// Grab's own small window: the four captures as buttons, along the bottom,
/// and where the menus live while there is no picture yet.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct GrabPanelLayout {
    pub selection: Rect,
    pub window: Rect,
    pub screen: Rect,
    pub timed: Rect,
}

impl GrabPanelLayout {
    pub fn new(w: f64, h: f64) -> GrabPanelLayout {
        let (top, bw) = (h - 38.0, (w - 50.0) / 4.0);
        let at = |i: f64| Rect::new(10.0 + i * (10.0 + bw), top, bw, 26.0);
        GrabPanelLayout { selection: at(0.0), window: at(1.0), screen: at(2.0), timed: at(3.0) }
    }
}

pub fn paint_grab_panel(c: &mut Canvas, w: f64, h: f64, status: &str) -> GrabPanelLayout {
    paint_window_chrome(c.runner, c.theme, c.cr, w, h, "Grab", false, true);
    let t = c.theme.tokens.clone();
    c.set_color(t.content_background);
    c.cr.rectangle(0.0, t.title_bar_height, w, h - t.title_bar_height);
    c.cr.fill();
    c.text_left(status, 12.0, t.title_bar_height + 24.0, t.body_text, t.font_size, Style::Regular, Role::Interface);
    let l = GrabPanelLayout::new(w, h);
    for (r, label) in [(l.selection, "Selection"), (l.window, "Window"), (l.screen, "Screen"), (l.timed, "Timed")] {
        c.gel_button(r, label, false, false)
    }
    l
}

struct Panel {
    app: Weak<GrabApp>,
    window: RefCell<Option<Rc<Window>>>,
    pointer: Cell<(f64, f64)>,
    status: RefCell<String>,
    logged: Cell<bool>,
}

impl Panel {
    fn set_status(&self, s: &str) {
        *self.status.borrow_mut() = s.into();
        if let Some(w) = self.window.borrow().as_ref() {
            w.set_needs_display()
        }
    }
}

impl WindowDelegate for Panel {
    fn render(&self, _w: &Window, target: &RenderTarget) {
        let Some(app) = self.app.upgrade() else { return };
        let status = self.status.borrow().clone();
        let l = app.toolkit.draw(target, |c, w, h| paint_grab_panel(c, w, h, &status));
        if dump() && !self.logged.replace(true) {
            let at = |r: Rect| format!("{},{}", (r.x + r.w / 2.0) as i64, (r.y + r.h / 2.0) as i64);
            log(&format!("panel selection={} window={} screen={} timed={}", at(l.selection), at(l.window), at(l.screen), at(l.timed)))
        }
    }
    fn pointer_moved(&self, _w: &Window, x: f64, y: f64) {
        self.pointer.set((x, y))
    }
    fn pointer_button(&self, w: &Window, _button: u32, pressed: bool) {
        let Some(app) = self.app.upgrade().filter(|_| pressed) else { return };
        let (x, y) = self.pointer.get();
        let (sw, sh) = w.size();
        let t = app.toolkit.theme.borrow().tokens.clone();
        match chrome_hit(&t, &window_chrome(&t, sw as f64, sh as f64, false), x, y) {
            ChromeHit::Gadget(Gadget::Close) => {
                app.perform(VERB_QUIT, None);
                return;
            }
            hit @ (ChromeHit::Gadget(Gadget::Minimize | Gadget::Depth) | ChromeHit::Title) => return chrome_request(w, hit),
            _ => {}
        }
        let l = GrabPanelLayout::new(sw as f64, sh as f64);
        let verb = [(l.selection, VERB_SELECTION), (l.window, VERB_WINDOW), (l.screen, VERB_SCREEN), (l.timed, VERB_TIMED)].into_iter().find(|(r, _)| r.contains(x, y)).map(|(_, v)| v);
        if let Some(v) = verb {
            app.perform(v, None);
        }
    }
    fn key_event(&self, _w: &Window, e: &KeyEvent) {
        if let Some(a) = self.app.upgrade() {
            a.key(e, None)
        }
    }
    fn should_close(&self, _w: &Window) {
        if let Some(a) = self.app.upgrade() {
            a.perform(VERB_QUIT, None);
        }
    }
}

// MARK: - The application

pub struct GrabApp {
    me: Weak<GrabApp>,
    display: Rc<Display>,
    toolkit: Rc<Toolkit>,
    panel: RefCell<Option<Rc<Panel>>>,
    documents: RefCell<Vec<Rc<GrabDocument>>>,
    overlay: RefCell<Option<Rc<Overlay>>>,
    menu_service: RefCell<Option<MenuService>>,
    menu_name: String,
    /// Timed Screen: its timer and the seconds left.
    countdown: Cell<Option<(u64, u32)>>,
}

struct Provider<'a>(&'a GrabApp);

impl MenuProvider for Provider<'_> {
    fn menu_model(&self) -> MenuBarModel {
        grab_menu_bar()
    }
    fn menu_validate(&self, c: &Command) -> Enablement {
        self.0.validate(&c.verb)
    }
    fn menu_perform(&mut self, c: &Command, _a: &BTreeMap<String, String>) -> CommandResult {
        if let Enablement::Disabled(why) = self.0.validate(&c.verb) {
            return CommandResult::Refused(why);
        }
        self.0.perform(&c.verb, self.0.front())
    }
}

impl GrabApp {
    pub fn new(display: &Rc<Display>, toolkit: &Rc<Toolkit>) -> Option<Rc<GrabApp>> {
        let menu_name = menu_wire::service_name("Grab", std::process::id() as i32);
        let app = Rc::new_cyclic(|me| GrabApp { me: me.clone(), display: display.clone(), toolkit: toolkit.clone(), panel: RefCell::new(None), documents: RefCell::default(), overlay: RefCell::new(None), menu_service: RefCell::new(MenuService::new(&menu_name).ok()), menu_name, countdown: Cell::new(None) });
        if let Some(fd) = app.menu_service.borrow().as_ref().map(|s| s.fd()) {
            let me = app.me.clone();
            display.add_fd(fd, move || {
                if let Some(a) = me.upgrade() {
                    a.serve()
                }
            });
        }
        let panel = Rc::new(Panel { app: app.me.clone(), window: RefCell::new(None), pointer: Cell::new((0.0, 0.0)), status: RefCell::new("Choose what to capture.".into()), logged: Cell::new(false) });
        let pinned = std::env::var("AQUA_SCALE").ok().and_then(|s| s.parse::<i32>().ok()).filter(|v| *v > 0);
        let w = Window::new(display, "Grab", "org.abyssbsd.grab", 420, 120, pinned.unwrap_or(1), pinned.is_none(), Rc::downgrade(&panel) as Weak<dyn WindowDelegate>)?;
        if w.publish_menus(&app.menu_name) {
            log(&format!("menus on {}", app.menu_name))
        }
        *panel.window.borrow_mut() = Some(w);
        *app.panel.borrow_mut() = Some(panel);
        Some(app)
    }

    fn serve(&self) {
        let svc = self.menu_service.borrow_mut().take();
        let Some(mut svc) = svc else { return };
        svc.service_readable(&mut Provider(self));
        *self.menu_service.borrow_mut() = Some(svc)
    }

    fn status(&self, s: &str) {
        if let Some(p) = self.panel.borrow().as_ref() {
            p.set_status(s)
        }
    }

    fn key(&self, e: &KeyEvent, doc: Option<Rc<GrabDocument>>) {
        if !e.pressed || !e.modifiers.contains(KeyModifiers::COMMAND) {
            return;
        }
        let Some(verb) = key_equivalent_of(e).and_then(|k| grab_menu_bar().verb_for(&k).map(String::from)) else { return };
        if let CommandResult::Refused(why) = self.perform(&verb, doc) {
            log(&format!("{verb} refused: {why}"))
        }
    }

    fn front(&self) -> Option<Rc<GrabDocument>> {
        let ds = self.documents.borrow();
        ds.iter().find(|d| d.window().is_some_and(|w| w.is_activated())).or(ds.last()).cloned()
    }

    // MARK: capturing

    fn start_overlay(&self, mode: OverlayMode) -> CommandResult {
        if self.overlay.borrow().is_some() {
            return refused("a capture is already under way");
        }
        if !self.display.can_capture_screen() {
            return refused("this compositor does not offer screencopy");
        }
        let me = self.me.clone();
        let done: Done = Box::new(move |rect, window, size| {
            let Some(a) = me.upgrade() else { return };
            *a.overlay.borrow_mut() = None;
            match rect {
                None => {
                    a.status("Cancelled.");
                    log("capture cancelled")
                }
                Some(r) => a.capture(Some(r), f64::from(size.0), window),
            }
        });
        let Some(o) = Overlay::new(&self.display, &self.toolkit, mode, done) else { return refused("no overlay could be made") };
        *self.overlay.borrow_mut() = Some(o);
        self.status(if mode == OverlayMode::Selection { "Drag across what you want. Escape cancels." } else { "Click the window you want. Escape cancels." });
        log(&format!("capturing a {}", if mode == OverlayMode::Selection { "selection" } else { "window" }));
        ok()
    }

    /// Copy the screen and keep `rect` of it (all of it when None). The
    /// overlay is already closed; round trips let the compositor draw a
    /// frame without it before the copy is taken.
    fn capture(&self, rect: Option<Rect>, overlay_width: f64, window: Option<WindowAt>) {
        self.display.roundtrip();
        self.display.roundtrip();
        std::thread::sleep(Duration::from_millis(50));
        let shot = match self.display.capture_output(0, false, Duration::from_secs(5)) {
            Ok(s) => s,
            Err(e) => {
                self.status("Could not capture the screen.");
                return log(&format!("capture failed: {e:?}"));
            }
        };
        let image = match rect {
            Some(r) => {
                // Points to pixels: the output may be scaled.
                let k = if overlay_width > 0.0 { shot.width as f64 / overlay_width } else { 1.0 };
                let px = |v: f64| (v * k).round() as i64;
                let (x, y, w, h) = (px(r.x), px(r.y), px(r.w), px(r.h));
                match &window {
                    Some(wnd) => log(&format!("captured window {} {x},{y} {w}x{h}", wnd.app_id)),
                    None => log(&format!("captured selection {x},{y} {w}x{h}")),
                }
                GrabImage::crop(&shot, x, y, w, h)
            }
            None => {
                log(&format!("captured screen {}x{}", shot.width, shot.height));
                Some(GrabImage { width: shot.width, height: shot.height, pixels: shot.pixels })
            }
        };
        let Some(image) = image else { return self.status("Nothing was captured.") };
        let (iw, ih) = (image.width, image.height);
        let Some(me) = self.me.upgrade() else { return };
        let Some(d) = GrabDocument::new(&me, image) else { return };
        if let Some(w) = d.window() {
            w.publish_menus(&self.menu_name);
        }
        self.documents.borrow_mut().push(d);
        self.status(&format!("Captured {iw} × {ih}."))
    }

    fn start_countdown(&self) -> CommandResult {
        if self.countdown.get().is_some() {
            return refused("a timed capture is already counting");
        }
        let n = timer_seconds();
        let me = self.me.clone();
        let id = self.display.add_timer(1000, move || {
            if let Some(a) = me.upgrade() {
                a.tick()
            }
        });
        self.countdown.set(Some((id, n)));
        self.status(&format!("Capturing the screen in {n} seconds…"));
        log(&format!("timed capture in {n} s"));
        ok()
    }

    fn tick(&self) {
        let Some((id, left)) = self.countdown.get() else { return };
        if left > 1 {
            self.countdown.set(Some((id, left - 1)));
            return self.status(&format!("Capturing the screen in {} seconds…", left - 1));
        }
        self.display.remove_timer(id);
        self.countdown.set(None);
        self.capture(None, 0.0, None)
    }

    // MARK: verbs

    fn validate(&self, verb: &str) -> Enablement {
        match verb {
            VERB_ABOUT => Enablement::Disabled("Grab has no About box yet".into()),
            VERB_CLOSE | VERB_SAVE | VERB_COPY if self.documents.borrow().is_empty() => Enablement::Disabled("no picture".into()),
            _ => Enablement::Enabled,
        }
    }

    fn perform(&self, verb: &str, doc: Option<Rc<GrabDocument>>) -> CommandResult {
        let d = doc.or_else(|| self.front());
        match verb {
            VERB_QUIT => std::process::exit(0),
            VERB_SELECTION => self.start_overlay(OverlayMode::Selection),
            VERB_WINDOW => self.start_overlay(OverlayMode::Window),
            VERB_SCREEN => {
                self.capture(None, 0.0, None);
                ok()
            }
            VERB_TIMED => self.start_countdown(),
            VERB_CLOSE => match d {
                Some(d) => {
                    d.close();
                    ok()
                }
                None => refused("no picture"),
            },
            VERB_COPY => {
                let Some((d, png)) = d.and_then(|d| d.image.png().map(|p| (d, p))) else { return refused("no picture") };
                if !self.display.clipboard().is_some_and(|c| c.write(png, &["image/png"])) {
                    return refused("the clipboard would not take it");
                }
                log(&format!("copied {}x{} as image/png", d.image.width, d.image.height));
                ok()
            }
            VERB_SAVE => {
                let Some(d) = d else { return refused("no picture") };
                let mut m = Msg::new();
                m.set_string("method", "file.save");
                m.set_string("name", "Untitled.png");
                let dw = Rc::downgrade(&d);
                ask_portal(&self.display, &m, move |reply| {
                    let Some(d) = dw.upgrade() else { return };
                    let mut reply = match reply {
                        Some(r) if r.bool("ok") == Some(true) => r,
                        other => return log(&format!("save: {}", other.as_ref().and_then(|r| r.string("error")).unwrap_or("the portal did not answer"))),
                    };
                    let (Some(fd), Some(path)) = (reply.take_fd("file"), reply.string("path").map(String::from)) else { return log("save: the portal sent no file") };
                    let Some(png) = d.image.png() else { return log("save: the picture would not encode") };
                    if let Err(why) = save_fd(&png, fd) {
                        return log(&format!("could not save {path}: {why}"));
                    }
                    d.saved(&path);
                    log(&format!("saved {path} ({}x{})", d.image.width, d.image.height))
                });
                CommandResult::Ok(Some("asked the portal".into()))
            }
            VERB_MINIMIZE => {
                let w = d.and_then(|d| d.window()).or_else(|| self.panel.borrow().as_ref().and_then(|p| p.window.borrow().clone()));
                if let Some(w) = w {
                    w.minimize();
                }
                ok()
            }
            v => CommandResult::Refused(format!("Grab has no verb {v}")),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_crop_is_clamped_to_the_screen_and_keeps_its_rows() {
        let shot = ScreenCapture { width: 4, height: 3, pixels: (0..48).collect() };
        let c = GrabImage::crop(&shot, 1, 1, 10, 10).unwrap();
        assert_eq!((c.width, c.height), (3, 2));
        assert_eq!(&c.pixels[..4], &[20, 21, 22, 23], "row 1, column 1");
        assert_eq!(&c.pixels[12..16], &[36, 37, 38, 39], "row 2, column 1");
        assert_eq!(GrabImage::crop(&shot, 5, 0, 2, 2), None, "nothing of it on the screen");
    }

    #[test]
    fn a_picture_encodes_as_png() {
        let img = GrabImage { width: 2, height: 2, pixels: vec![255; 16] };
        assert_eq!(&img.png().unwrap()[..8], b"\x89PNG\r\n\x1a\n");
    }

    #[test]
    fn the_panels_buttons_share_its_width() {
        let l = GrabPanelLayout::new(420.0, 120.0);
        assert_eq!(l.selection.y, 82.0);
        assert!((l.timed.x + l.timed.w - 410.0).abs() < 1e-9);
    }

    /// AquaTests' grab, with its own screen: every pixel says where it is
    /// (B = x, G = y), and a crop off the top-right corner is clamped to it.
    #[test]
    fn a_grab_is_the_screens_pixels_cropped() {
        let pixels = (0..3u8).flat_map(|y| (0..4u8).flat_map(move |x| [x, y, 0, 0xff])).collect();
        let screen = ScreenCapture { width: 4, height: 3, pixels };
        let c = GrabImage::crop(&screen, 1, 1, 2, 2).unwrap();
        assert_eq!((c.width, c.height), (2, 2));
        assert_eq!(c.pixels, [1, 1, 0, 0xff, 2, 1, 0, 0xff, 1, 2, 0, 0xff, 2, 2, 0, 0xff]);
        let edge = GrabImage::crop(&screen, 3, -5, 10, 7).unwrap();
        assert_eq!((edge.width, edge.height), (1, 2), "clamped to the screen's right edge and its top");
        assert_eq!(GrabImage::crop(&screen, 9, 0, 2, 2), None, "nothing of it on the screen");
    }
}
