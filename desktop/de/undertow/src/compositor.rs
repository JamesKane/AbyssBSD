//! The compositor proper: real clients, a real scene (Compositor.swift,
//! LayerShell.swift's LayerSurface, Popups.swift; PHASE6.md P6.3).
//!
//! The `wl_compositor` and `xdg_shell` globals and a socket to reach them;
//! toplevels, layer surfaces and popups; and the scene's `World`.
//!
//! **We do not use `wlr_scene`**, the line DESKTOP.md §2 draws: wlroots owns
//! the plumbing, we own the scene, the scheduler and the present path.
//!
//! Swift's classes point at each other (a window at its compositor, the
//! compositor at its windows) and wlroots calls back into them from inside
//! its own calls. So these are `Rc`s with `Cell` and `RefCell` fields, each
//! borrowed only for a moment and never across a call into wlroots, which
//! keeps them reentrant as Swift's are, and destroy signals synchronous.
//!
//! This pass is the core. Decorations, islands' switching, Ebb, shoals, the
//! menus, the session lock, explicit sync, output management and the seat
//! (keyboard focus, move and resize) join it in the passes after.

use crate::backend::{log, BackendError, WlrootsSession};
use crate::decorations::Frames;
use crate::ebb::Ebb;
use crate::geometry::IslandSlide;
use crate::shoals::ShoalBook;
use crate::tide::OwnedLabel;
use pool_config::IslandsConfig;
use aquadraw::runner::Runner;
use aquadraw::theme::Theme;
use crate::displays::DisplayLayout;
use crate::frame::FrameMetrics;
use crate::geometry::{place_layer, LayerAnchor, LayerRequest, Rect};
use crate::places::{WindowPlace, WindowPlaces};
use crate::scene::{Label, SceneLayer, SceneWindow, World};
use abyss_sys::mono;
use abyss_sys::wlr::{self, globals, Decoration, ForeignHandle, ForeignManager, LayerSurface, Listener, OutputLayout, Surface, Texture, Timeline, XdgPopup, XdgToplevel};
use std::cell::{Cell, RefCell};
use std::collections::HashMap;
use std::rc::{Rc, Weak};

/// How often a window nobody can see is told to draw: once a second (U.2).
pub const HIDDEN_FRAME_PERIOD_NS: u64 = 1_000_000_000;
pub const MINIMUM_WINDOW_WIDTH: i32 = 120;
pub const MINIMUM_WINDOW_HEIGHT: i32 = 40;

/// One toplevel window.
pub struct Toplevel {
    pub xdg: XdgToplevel,
    pub surface: Surface,
    /// Who this window is, for the menu bar's island menu (P13.4): never
    /// reused while undertow runs.
    pub id: u32,
    /// Position in layout coordinates, chosen by us: a client cannot place
    /// its own window (HANDOFF §2.22).
    pub x: Cell<i32>,
    pub y: Cell<i32>,
    pub mapped: Cell<bool>,
    /// **Minimized windows are not on screen and not under the pointer**:
    /// everything that asks what is showing asks through `mapped_toplevels`.
    pub minimized: Cell<bool>,
    pub maximized: Cell<bool>,
    /// As undertow last said (BACKLOG F.1): leaving a state the window is
    /// not in changes nothing.
    pub fullscreen: Cell<bool>,
    /// Whether the compositor draws its frame (P9.6).
    pub decorated: Cell<bool>,
    /// A decoration request waiting for the window's first commit: answering
    /// before it is an assertion inside wlroots.
    decoration: Cell<Option<Decoration>>,
    /// The island it is on (PHASE13 P13.1), of the display it lives on.
    pub island: Cell<i32>,
    pub island_display: RefCell<String>,
    suspended_said: Cell<bool>,
    hidden_frame_at: Cell<u64>,
    /// Where it was before it was maximized, snapped or made fullscreen.
    pub restore_box: Cell<Option<Rect>>,
    /// Its place key as it last was: what a position is remembered under
    /// when it closes, after wlroots has let go of its title.
    last_key: RefCell<Option<String>>,
    /// Its entry in wlr-foreign-toplevel-management: how the Dock sees it.
    foreign: Cell<Option<ForeignHandle>>,
    foreign_listeners: RefCell<Vec<Listener>>,
    listeners: RefCell<Vec<Listener>>,
}

impl Toplevel {
    pub fn width(&self) -> i32 {
        self.surface.width()
    }
    pub fn height(&self) -> i32 {
        self.surface.height()
    }
    pub fn rect(&self) -> Rect {
        Rect::new(self.x.get(), self.y.get(), self.width(), self.height())
    }
    pub fn app_id(&self) -> Option<String> {
        self.xdg.app_id()
    }
    pub fn title(&self) -> Option<String> {
        self.xdg.title()
    }
    /// What a remembered position is stored under.
    pub fn place_key(&self) -> Option<String> {
        WindowPlaces::key(self.app_id().as_deref(), self.title().as_deref())
    }

    fn note_key(&self) {
        if let Some(k) = self.place_key() {
            *self.last_key.borrow_mut() = Some(k);
        }
    }

    /// Keep the Dock tile's label honest.
    fn describe(&self) {
        if let Some(h) = self.foreign.get() {
            h.set_title(&self.title().unwrap_or_default());
            h.set_app_id(&self.app_id().unwrap_or_default());
        }
    }

    /// Tell the shell what this window now is.
    fn republish(&self) {
        if let Some(h) = self.foreign.get() {
            h.set_minimized(self.minimized.get());
            h.set_maximized(self.maximized.get());
        }
    }

    pub fn set_foreign_activated(&self, on: bool) {
        if let Some(h) = self.foreign.get() {
            h.set_activated(on)
        }
    }

    /// The window is gone from view: take its tile with it, listeners first.
    fn withdraw(&self) {
        self.foreign_listeners.borrow_mut().clear();
        if let Some(h) = self.foreign.take() {
            h.destroy()
        }
    }

    fn teardown(&self) {
        self.withdraw();
        self.listeners.borrow_mut().clear();
    }
}

/// One layer-shell surface: wallpaper, menu bar, Dock, toast.
pub struct Layer {
    pub handle: LayerSurface,
    pub surface: Surface,
    pub mapped: Cell<bool>,
    pub rect: Cell<Rect>,
    listeners: RefCell<Vec<Listener>>,
}

impl Layer {
    pub fn layer(&self) -> u32 {
        self.handle.layer()
    }
    pub fn namespace(&self) -> String {
        self.handle.namespace()
    }
    /// A click hands it the keyboard: `on_demand` or `exclusive` (P10.4).
    pub fn takes_keyboard_on_click(&self) -> bool {
        self.handle.keyboard_interactive() != 0
    }
    /// `exclusive` on the top or overlay layer: it receives all keyboard
    /// input as it maps (a lock screen, Grab's overlay; P15.6).
    pub fn wants_exclusive_keyboard(&self) -> bool {
        self.handle.keyboard_interactive() == 1 && self.layer() >= 2
    }
    /// What it asks for, out of the protocol state.
    pub fn request(&self) -> LayerRequest {
        let r = self.handle.request();
        LayerRequest {
            anchor: LayerAnchor(r.anchor),
            desired_width: r.desired_width as i32,
            desired_height: r.desired_height as i32,
            margin_top: r.margin_top,
            margin_right: r.margin_right,
            margin_bottom: r.margin_bottom,
            margin_left: r.margin_left,
            exclusive_zone: r.exclusive_zone,
        }
    }
    /// Tell the client the size we decided on.
    fn configure(&self, r: Rect) {
        self.rect.set(r);
        self.handle.configure(r.width.max(0) as u32, r.height.max(0) as u32);
    }
    /// The output it is on, by name ("" before one is assigned).
    pub fn output_name(&self) -> String {
        self.handle.output().map(|o| o.name()).unwrap_or_default()
    }
}

/// One xdg_popup: a menu.
///
/// **undertow had never handled one** (P10.4): wlroots speaks the protocol
/// and configures it, so a client's menu mapped, and undertow neither drew
/// it, nor hit-tested it, nor sent it frame callbacks. What a compositor
/// owes a popup is a box to stay inside, a place on screen, a place in the
/// paint order and the hit-test, and frame callbacks.
pub struct Popup {
    pub popup: XdgPopup,
    pub surface: Surface,
    pub mapped: Cell<bool>,
    listeners: RefCell<Vec<Listener>>,
}

/// Where a popup's surface goes (§2.9): xdg-shell positions it relative to
/// its parent's window geometry, and its own surface may carry a geometry
/// offset of its own.
pub fn popup_surface_origin(parent: (i32, i32), parent_geometry: (i32, i32), position: (i32, i32), own_geometry: (i32, i32)) -> (i32, i32) {
    (parent.0 + parent_geometry.0 + position.0 - own_geometry.0, parent.1 + parent_geometry.1 + position.1 - own_geometry.1)
}

type FocusHook = Box<dyn Fn(Option<&Rc<Toplevel>>)>;

/// The compositor: globals, a socket, and the lists of surfaces.
pub struct Compositor {
    pub session: Rc<WlrootsSession>,
    me: Weak<Compositor>,
    pub layout: RefCell<DisplayLayout>,
    /// Each display's usable area: what is left once layer surfaces have
    /// reserved theirs.
    pub usable: RefCell<HashMap<String, Rect>>,
    /// Bottom to top: the stacking order and the paint order are one list.
    pub toplevels: RefCell<Vec<Rc<Toplevel>>>,
    pub layers: RefCell<Vec<Rc<Layer>>>,
    /// Creation order: a child after its parent, the order they paint in.
    pub popups: RefCell<Vec<Rc<Popup>>>,
    pub places: RefCell<WindowPlaces>,
    pub socket_name: String,
    output_layout: Option<OutputLayout>,
    foreign_manager: Option<ForeignManager>,
    pub dmabuf_offered: bool,
    /// The frame's size around a window: the theme's.
    pub metrics: Cell<FrameMetrics>,
    /// What draws: the theme (Swift's global) and the runner its lists run
    /// on, None when no font could be opened (no frames are drawn then).
    pub theme: RefCell<Theme>,
    pub runner: RefCell<Option<Runner>>,
    /// The frames undertow draws (P9.6).
    pub frames: RefCell<Frames>,
    /// The window with the keyboard. The seat says so to the client (R4e).
    pub focused: RefCell<Option<Weak<Toplevel>>>,
    focus_hook: RefCell<Option<FocusHook>>,
    pub config_dir: Option<String>,
    /// The seat's pointer, once a seat exists: the display a keystroke
    /// means when nothing is focused.
    pub cursor: Cell<Option<(f64, f64)>>,
    /// The window being dragged, by the seat (R4e).
    pub moving: RefCell<Option<Weak<Toplevel>>>,
    pub islands: RefCell<IslandsConfig>,
    pub active_islands: RefCell<HashMap<String, i32>>,
    pub island_inputs: RefCell<HashMap<String, u64>>,
    pub island_slides: RefCell<HashMap<String, IslandSlide>>,
    pub island_switches: Cell<u64>,
    pub ebb: RefCell<Option<Ebb>>,
    pub ebb_opens: Cell<u64>,
    pub ebb_labels: RefCell<HashMap<u32, OwnedLabel>>,
    pub shoal_book: RefCell<ShoalBook>,
    pub strip_shown: Cell<bool>,
    pub strip_labels: RefCell<HashMap<String, OwnedLabel>>,
    pub recalls: Cell<u64>,
    last_id: Cell<u32>,
    cascade: Cell<i32>,
    orphaned_layers: RefCell<Vec<(Weak<Layer>, String)>>,
    // Counters, for the tests and the logs.
    pub surfaces_created: Cell<u64>,
    pub restored_count: Cell<u64>,
    pub maximize_count: Cell<u64>,
    pub minimize_count: Cell<u64>,
    pub lower_count: Cell<u64>,
    pub popups_mapped: Cell<u64>,
    /// A window nobody can see drew anyway (T.3).
    pub hidden_commits: Cell<u64>,
    pub ever_mapped: RefCell<Vec<String>>,
    listeners: RefCell<Vec<Listener>>,
}

impl Compositor {
    pub fn new(session: Rc<WlrootsSession>, layout: DisplayLayout, config_dir: Option<&str>, socket_name: Option<&str>, theme: Theme, runner: Option<Runner>) -> Result<Rc<Compositor>, BackendError> {
        let metrics = frame_metrics(&theme);
        let d = session.display();
        let renderer = session.renderer();
        // The same arrangement, told to wlroots, and through it to clients.
        let output_layout = globals::output_layout(d);
        if let Some(ol) = output_layout {
            for b in &layout.displays {
                if let Some(o) = session.output_named(&b.name) {
                    ol.add(o, b.x, b.y);
                }
            }
            globals::xdg_output_manager(d, ol);
        }
        // wl_compositor at version 6, with a renderer: what makes wlroots
        // turn client buffers into textures on commit.
        let comp = globals::compositor(d, 6, renderer).ok_or_else(|| BackendError::NoGlobals("wl_compositor".into()))?;
        globals::subcompositor(d);
        globals::data_device_manager(d);
        // viewporter and fractional-scale (U.8): the crop is the scene's.
        globals::viewporter(d);
        globals::fractional_scale(d, 1);
        // **wl_shm, without which no client can attach a buffer**, and
        // which wlr_compositor_create does not make.
        globals::shm(d, 1, renderer);
        // presentation-time (U.4): when a client's frame reached the display.
        if !globals::presentation(d, session.backend(), 1) {
            return Err(BackendError::NoGlobals("wp_presentation".into()));
        }
        // linux-dmabuf, without which a GPU client does not survive (U.3);
        // pixman imports none, so headless runs are shm-only, as before.
        let dmabuf_offered = globals::linux_dmabuf(d, 5, renderer);
        log(if dmabuf_offered {
            "linux-dmabuf offered — GPU clients can hand us their buffers"
        } else {
            "linux-dmabuf not offered — this renderer imports no dma-bufs (pixman?); GPU clients will fail, shm clients are unaffected"
        });
        // v6, for `suspended` (U.2); wm_capabilities answered per window.
        let shell = globals::xdg_shell(d, 6).ok_or_else(|| BackendError::NoGlobals("xdg_wm_base".into()))?;
        let layer_shell = globals::layer_shell(d, 4).ok_or_else(|| BackendError::NoGlobals("zwlr_layer_shell_v1".into()))?;
        let foreign_manager = globals::foreign_toplevel_manager(d);
        // wlr-screencopy, server side: abyssgrab and the screenshot portal.
        globals::screencopy(d);
        let activation = globals::xdg_activation(d);
        // Who draws the frames (P9.6): always us.
        let decoration_manager = globals::xdg_decoration_manager(d);

        // The socket last of the globals, as Swift adds it; nothing is
        // dispatched before `new` returns, so no client arrives early.
        let socket_name = match socket_name {
            Some(wanted) => {
                if !d.add_socket(wanted) {
                    return Err(BackendError::SocketTaken(wanted.into()));
                }
                wanted.to_owned()
            }
            None => d.add_socket_auto().ok_or(BackendError::NoSocket)?,
        };
        let usable = layout.displays.iter().map(|b| (b.name.clone(), b.rect())).collect();
        let c = Rc::new_cyclic(|me| Compositor {
            session: session.clone(),
            me: me.clone(),
            layout: RefCell::new(layout),
            usable: RefCell::new(usable),
            toplevels: RefCell::default(),
            layers: RefCell::default(),
            popups: RefCell::default(),
            places: RefCell::new(WindowPlaces::new(config_dir)),
            socket_name,
            output_layout,
            foreign_manager,
            dmabuf_offered,
            metrics: Cell::new(metrics),
            theme: RefCell::new(theme),
            runner: RefCell::new(runner),
            frames: RefCell::default(),
            focused: RefCell::default(),
            focus_hook: RefCell::default(),
            config_dir: config_dir.map(str::to_owned),
            cursor: Cell::new(None),
            moving: RefCell::default(),
            islands: RefCell::new(IslandsConfig::load(config_dir)),
            active_islands: RefCell::default(),
            island_inputs: RefCell::default(),
            island_slides: RefCell::default(),
            island_switches: Cell::new(0),
            ebb: RefCell::default(),
            ebb_opens: Cell::new(0),
            ebb_labels: RefCell::default(),
            shoal_book: RefCell::new(ShoalBook::load(config_dir)),
            strip_shown: Cell::new(false),
            strip_labels: RefCell::default(),
            recalls: Cell::new(0),
            last_id: Cell::new(0),
            cascade: Cell::new(0),
            orphaned_layers: RefCell::default(),
            surfaces_created: Cell::new(0),
            restored_count: Cell::new(0),
            maximize_count: Cell::new(0),
            minimize_count: Cell::new(0),
            lower_count: Cell::new(0),
            popups_mapped: Cell::new(0),
            hidden_commits: Cell::new(0),
            ever_mapped: RefCell::default(),
            listeners: RefCell::default(),
        });

        let mut ls = vec![];
        // Every surface any client creates: the positive control for
        // adversarial load (P6.5), which a bench that only counts missed
        // frames would pass with the adversaries never connected.
        let w = Rc::downgrade(&c);
        ls.extend(comp.on_new_surface(move || {
            if let Some(c) = w.upgrade() {
                c.surfaces_created.set(c.surfaces_created.get() + 1)
            }
        }));
        let w = Rc::downgrade(&c);
        ls.extend(shell.on_new_toplevel(move |t| {
            if let Some(c) = w.upgrade() {
                let t = c.adopt_toplevel(t);
                c.toplevels.borrow_mut().push(t);
            }
        }));
        let w = Rc::downgrade(&c);
        ls.extend(shell.on_new_popup(move |p| {
            if let Some(c) = w.upgrade() {
                let p = c.adopt_popup(p);
                c.popups.borrow_mut().push(p);
            }
        }));
        let w = Rc::downgrade(&c);
        ls.extend(layer_shell.on_new_surface(move |l| {
            let Some(c) = w.upgrade() else { return };
            // A layer surface may name no output; ours to choose, and the
            // choice is the main display, where a Mac keeps its menu bar.
            if l.output().is_none() {
                let main = c.layout.borrow().main().map(|m| m.name.clone());
                let o = main.and_then(|n| c.session.output_named(&n)).or_else(|| c.session.outputs().first().copied());
                l.set_output(o);
            }
            let l = c.adopt_layer(l);
            c.layers.borrow_mut().push(l);
        }));
        if let Some(m) = decoration_manager {
            let w = Rc::downgrade(&c);
            ls.extend(m.on_new_toplevel_decoration(move |dec| {
                if let Some(c) = w.upgrade() {
                    c.take_decoration(dec)
                }
            }));
        }
        if let Some(a) = activation {
            // The sanctioned "raise my own window": the spatial Finder brings
            // an open folder's window forward rather than opening a second.
            let w = Rc::downgrade(&c);
            ls.extend(a.on_request_activate(move |s| {
                let (Some(c), Some(s)) = (w.upgrade(), s) else { return };
                let found: Vec<Rc<Toplevel>> = c.toplevels.borrow().iter().filter(|t| t.surface == s).cloned().collect();
                for t in found {
                    c.raise(&t)
                }
            }));
        }
        *c.listeners.borrow_mut() = ls;

        Ok(c)
    }

    fn rc(&self) -> Rc<Compositor> {
        self.me.upgrade().expect("the compositor is alive while its methods run")
    }

    /// Who is told when focus moves: the seat, once it exists (R4e).
    pub fn on_focus(&self, f: impl Fn(Option<&Rc<Toplevel>>) + 'static) {
        *self.focus_hook.borrow_mut() = Some(Box::new(f));
    }

    pub fn focused(&self) -> Option<Rc<Toplevel>> {
        self.focused.borrow().as_ref().and_then(Weak::upgrade)
    }

    pub fn moving(&self) -> Option<Rc<Toplevel>> {
        self.moving.borrow().as_ref().and_then(Weak::upgrade)
    }

    // MARK: windows

    fn adopt_toplevel(&self, xdg: XdgToplevel) -> Rc<Toplevel> {
        self.last_id.set(self.last_id.get() + 1);
        let t = Rc::new(Toplevel {
            xdg,
            surface: xdg.surface(),
            id: self.last_id.get(),
            x: Cell::new(0),
            y: Cell::new(0),
            mapped: Cell::new(false),
            minimized: Cell::new(false),
            maximized: Cell::new(false),
            fullscreen: Cell::new(false),
            decorated: Cell::new(false),
            decoration: Cell::new(None),
            island: Cell::new(1),
            island_display: RefCell::default(),
            suspended_said: Cell::new(false),
            hidden_frame_at: Cell::new(0),
            restore_box: Cell::new(None),
            last_key: RefCell::default(),
            foreign: Cell::new(None),
            foreign_listeners: RefCell::default(),
            listeners: RefCell::default(),
        });
        let s = t.surface;
        let both = || (self.me.clone(), Rc::downgrade(&t));
        let mut ls = vec![];
        let (wc, wt) = both();
        ls.extend(s.on_map(move || {
            let (Some(c), Some(t)) = (wc.upgrade(), wt.upgrade()) else { return };
            t.mapped.set(true);
            t.note_key();
            c.place(&t);
            c.settle_island(&t, true);
            c.shoal_rejoined(&t);
            c.publish(&t);
        }));
        let (_, wt) = both();
        ls.extend(s.on_unmap(move || {
            if let Some(t) = wt.upgrade() {
                t.mapped.set(false);
                t.withdraw();
            }
        }));
        let (wc, wt) = both();
        ls.extend(s.on_commit(move || {
            let (Some(c), Some(t)) = (wc.upgrade(), wt.upgrade()) else { return };
            c.toplevel_committed(&t);
        }));
        let (wc, wt) = both();
        ls.extend(xdg.on_destroy(move || {
            let (Some(c), Some(t)) = (wc.upgrade(), wt.upgrade()) else { return };
            // Remember where it was, under the key it last had: by the time
            // wlroots says a toplevel is destroyed its title and app_id are
            // gone (wlroots 0.20; Swift reads them here, BACKLOG §5).
            c.remember_place(&t);
            t.mapped.set(false);
            c.forget(&t);
        }));
        // **The client's own pending state is the request**: there is no
        // "unmaximize" event, and answering is mandatory even to refuse.
        // **Not before the first commit**: a configure scheduled then is an
        // assertion inside wlroots, and the initial commit answers it.
        let (wc, wt) = both();
        ls.extend(xdg.on_request_maximize(move || {
            let (Some(c), Some(t)) = (wc.upgrade(), wt.upgrade()) else { return };
            if t.xdg.initialized() {
                c.set_maximized(&t, t.xdg.requested().maximized)
            }
        }));
        let (wc, wt) = both();
        ls.extend(xdg.on_request_minimize(move || {
            let (Some(c), Some(t)) = (wc.upgrade(), wt.upgrade()) else { return };
            if t.xdg.initialized() {
                c.set_minimized(&t, t.xdg.requested().minimized)
            }
        }));
        // Firefox's --kiosk asks before its first commit (PHASE15 §4.2).
        let (wc, wt) = both();
        ls.extend(xdg.on_request_fullscreen(move || {
            let (Some(c), Some(t)) = (wc.upgrade(), wt.upgrade()) else { return };
            if t.xdg.initialized() {
                c.set_fullscreen(&t, t.xdg.requested().fullscreen)
            }
        }));
        // A window that renames itself renames its Dock tile.
        let (_, wt) = both();
        ls.extend(xdg.on_set_title(move || {
            if let Some(t) = wt.upgrade() {
                t.note_key();
                t.describe()
            }
        }));
        let (_, wt) = both();
        ls.extend(xdg.on_set_app_id(move || {
            if let Some(t) = wt.upgrade() {
                t.note_key();
                t.describe()
            }
        }));
        *t.listeners.borrow_mut() = ls;
        t
    }

    fn toplevel_committed(&self, t: &Rc<Toplevel>) {
        // xdg-shell requires a configure in answer to the first commit
        // before the client may attach a buffer: miss it and the client
        // waits for ever having done nothing wrong.
        if t.xdg.initial_commit() {
            t.xdg.set_size(0, 0); // you choose
            // What this compositor will do if asked, and not the window
            // menu, which it does not draw. Here, not at creation: before the
            // first commit it is an assertion inside wlroots (P9.6).
            t.xdg.offer_capabilities();
            // And the decoration mode, which could not be answered before
            // this commit (P9.6).
            self.answer_decoration(t);
            // The most room a window can have (T.3).
            let u = self.usable_area();
            t.xdg.set_bounds(u.width, u.height);
            // What it asked for before this commit, which its handlers could
            // not answer then (PHASE15 §4.2).
            let asked = t.xdg.requested();
            if asked.fullscreen {
                self.set_fullscreen(t, true)
            } else if asked.maximized {
                self.set_maximized(t, true)
            }
        }
        // **A window nobody can see drew anyway** (T.3): counted, so a test
        // can hold a client to xdg-shell's `suspended`.
        if (t.minimized.get() || !self.is_on_active_island(t)) && t.surface.committed_buffer() {
            self.hidden_commits.set(self.hidden_commits.get() + 1);
        }
    }

    /// Announce a window to the shell, and listen for what the shell asks.
    /// The manager global existed long before any handle did, so under our
    /// own compositor the Dock showed no running applications.
    fn publish(&self, t: &Rc<Toplevel>) {
        if t.foreign.get().is_some() {
            return;
        }
        let Some(h) = self.foreign_manager.and_then(|m| m.create_handle()) else { return };
        t.foreign.set(Some(h));
        t.describe();
        let both = || (self.me.clone(), Rc::downgrade(t));
        let mut ls = vec![];
        let (wc, wt) = both();
        // A click on a Dock tile: its island first, then un-minimize.
        ls.extend(h.on_request_activate(move || {
            if let (Some(c), Some(t)) = (wc.upgrade(), wt.upgrade()) {
                c.bring_to_front(&t)
            }
        }));
        let (_, wt) = both();
        ls.extend(h.on_request_close(move || {
            if let Some(t) = wt.upgrade() {
                t.xdg.send_close()
            }
        }));
        let (wc, wt) = both();
        ls.extend(h.on_request_minimize(move |on| {
            if let (Some(c), Some(t)) = (wc.upgrade(), wt.upgrade()) {
                c.set_minimized(&t, on)
            }
        }));
        let (wc, wt) = both();
        ls.extend(h.on_request_maximize(move |on| {
            if let (Some(c), Some(t)) = (wc.upgrade(), wt.upgrade()) {
                c.set_maximized(&t, on)
            }
        }));
        *t.foreign_listeners.borrow_mut() = ls;
    }

    fn forget(&self, t: &Rc<Toplevel>) {
        self.frames.borrow_mut().forget(t.id);
        if let Some(e) = self.ebb.borrow_mut().as_mut() {
            e.forget(t.id)
        }
        self.ebb_labels.borrow_mut().remove(&t.id);
        t.teardown();
        self.toplevels.borrow_mut().retain(|o| !Rc::ptr_eq(o, t));
        // **Closing the focused window used to leave focus on nothing**:
        // the next one down is told it is active.
        if self.focused().is_some_and(|f| Rc::ptr_eq(&f, t)) {
            self.focus_topmost();
        }
    }

    /// Where a newly mapped window goes: centred, then cascaded, the Mac's
    /// rule, and a decision only a compositor can make.
    fn place(&self, t: &Rc<Toplevel>) {
        self.ever_mapped.borrow_mut().push(t.place_key().unwrap_or_else(|| "?".into()));
        // **A window that appears takes the keyboard**: until somebody
        // clicked, every application was deaf (P9.2).
        self.focus(t);
        // Fullscreen or maximized: already placed by the state it asked for.
        if t.fullscreen.get() || t.maximized.get() {
            return;
        }
        // A remembered position wins: the spatial Finder's whole behaviour.
        if let Some(key) = t.place_key()
            && let Some(p) = self.places.borrow().place(&key)
        {
            t.x.set(p.x);
            t.y.set(p.y);
            self.restored_count.set(self.restored_count.get() + 1);
            return;
        }
        let (w, h) = (t.width(), t.height());
        let offset = self.cascade.get() * 24;
        self.cascade.set((self.cascade.get() + 1) % 8);
        // Centred in the USABLE area: a window under the menu bar would be
        // an exclusive zone computed and never honoured.
        let area = self.usable_area();
        t.x.set(area.x.max(area.x + (area.width - w) / 2 + offset));
        t.y.set(area.y.max(area.y + (area.height - h) / 2 + offset));
        // A decorated window is centred by its frame, its title bar kept
        // clear of the menu bar.
        if t.decorated.get() {
            let m = self.metrics.get();
            let (sx, sy) = m.surface(t.x.get(), t.y.get());
            t.x.set(sx);
            t.y.set(sy.max(area.y + m.title_height as i32));
        }
    }

    pub fn remember_place(&self, t: &Toplevel) {
        if let Some(key) = t.place_key().or_else(|| t.last_key.borrow().clone()) {
            self.places.borrow_mut().remember(WindowPlace { x: t.x.get(), y: t.y.get() }, &key);
        }
    }

    /// Move a window to the top of the stack: the end of the list.
    pub fn raise(&self, t: &Rc<Toplevel>) {
        let mut ts = self.toplevels.borrow_mut();
        if let Some(i) = ts.iter().position(|o| Rc::ptr_eq(o, t))
            && i != ts.len() - 1
        {
            let t = ts.remove(i);
            ts.push(t);
        }
    }

    /// Send a window to the back (the depth gadget, P11.6). The keyboard
    /// goes with the front.
    pub fn lower(&self, t: &Rc<Toplevel>) {
        {
            let mut ts = self.toplevels.borrow_mut();
            let Some(i) = ts.iter().position(|o| Rc::ptr_eq(o, t)) else { return };
            self.lower_count.set(self.lower_count.get() + 1);
            let t = ts.remove(i);
            ts.insert(0, t);
        }
        if self.focused().is_some_and(|f| Rc::ptr_eq(&f, t)) {
            self.focus_topmost();
        }
    }

    /// Windows with something to show, bottom to top: mapped, not
    /// minimized, on their display's island, with a buffer.
    pub fn mapped_toplevels(&self) -> Vec<Rc<Toplevel>> {
        self.toplevels.borrow().iter().filter(|t| t.mapped.get() && !t.minimized.get() && self.is_on_active_island(t) && t.surface.has_buffer()).cloned().collect()
    }

    /// The topmost window at (x, y), and its box as drawn, frame included
    /// (P15.6).
    pub fn window_box(&self, x: f64, y: f64) -> Option<(Rc<Toplevel>, Rect)> {
        let m = self.metrics.get();
        self.mapped_toplevels().into_iter().rev().find_map(|t| {
            let b = if t.decorated.get() {
                let (bx, by, bw, bh) = m.frame(t.x.get(), t.y.get(), t.width(), t.height());
                Rect::new(bx, by, bw, bh)
            } else {
                t.rect()
            };
            (x >= b.x as f64 && y >= b.y as f64 && x < (b.x + b.width) as f64 && y < (b.y + b.height) as f64).then_some((t, b))
        })
    }

    /// Give `t` the keyboard: raised, told it is active, its tile lit, and
    /// the seat told (R4e).
    pub fn focus(&self, t: &Rc<Toplevel>) {
        self.raise(t);
        if self.focused().is_some_and(|f| Rc::ptr_eq(&f, t)) {
            return;
        }
        // **Tell the windows, not just the shell**: the activated state is
        // what a client draws with (a live caret, an active title bar), and
        // undertow set it on nobody until P9.5.
        if let Some(old) = self.focused() {
            old.xdg.set_activated(false);
            old.set_foreign_activated(false);
        }
        *self.focused.borrow_mut() = Some(Rc::downgrade(t));
        t.xdg.set_activated(true);
        t.set_foreign_activated(true);
        if let Some(f) = &*self.focus_hook.borrow() {
            f(Some(t));
        }
    }

    /// The topmost showing window gets the keyboard, or nobody does.
    pub fn focus_topmost(&self) {
        match self.mapped_toplevels().pop() {
            Some(t) => self.focus(&t),
            None => {
                if let Some(old) = self.focused.borrow_mut().take().and_then(|w| w.upgrade()) {
                    old.set_foreign_activated(false);
                }
                if let Some(f) = &*self.focus_hook.borrow() {
                    f(None);
                }
            }
        }
    }

    /// Bring a window back to the person: its island, un-minimized, raised,
    /// focused (PHASE13 §6.3: a window is never lost).
    pub fn bring_to_front(&self, t: &Rc<Toplevel>) {
        if !self.is_on_active_island(t) {
            let d = t.island_display.borrow().clone();
            self.switch_island(t.island.get(), Some(&d));
        }
        self.set_minimized(t, false);
        self.raise(t);
        self.focus(t);
    }

    /// Cmd-Tab: the window under the top, every island's (PHASE13 §6.3).
    pub fn cycle_window(&self, forward: bool) {
        let ws: Vec<Rc<Toplevel>> = self.toplevels.borrow().iter().filter(|t| t.mapped.get() && !t.minimized.get() && t.surface.has_buffer()).cloned().collect();
        match ws.len() {
            0 => {}
            1 => self.bring_to_front(&ws[0]),
            n => self.bring_to_front(if forward { &ws[n - 2] } else { &ws[0] }),
        }
    }

    /// Ask the focused window to close: the client decides what that means.
    pub fn close_focused_window(&self) {
        if let Some(t) = self.focused() {
            t.xdg.send_close()
        }
    }

    /// Cmd-Q: every window of the focused application, not just this one.
    pub fn quit_focused_application(&self) {
        let Some(t) = self.focused() else { return };
        let Some(app) = t.app_id().filter(|a| !a.is_empty()) else { return self.close_focused_window() };
        let all: Vec<Rc<Toplevel>> = self.toplevels.borrow().iter().filter(|w| w.app_id().as_deref() == Some(&app)).cloned().collect();
        for w in all {
            w.xdg.send_close()
        }
    }

    // MARK: decorations (P9.6)

    /// A client asked who decorates: we do, always, but **not yet** if its
    /// first commit has not happened: the request is kept and answered
    /// with the initial configure it belongs in.
    fn take_decoration(&self, dec: Decoration) {
        let Some(xdg) = dec.toplevel() else { return };
        let found: Vec<Rc<Toplevel>> = self.toplevels.borrow().iter().filter(|t| t.xdg == xdg).cloned().collect();
        for t in found {
            t.decoration.set(Some(dec));
            t.decorated.set(true);
            // A client may drop the object before its first commit: then
            // there is nothing to answer. (Swift kept the pointer.)
            let wt = Rc::downgrade(&t);
            t.listeners.borrow_mut().extend(dec.on_destroy(move || {
                if let Some(t) = wt.upgrade() {
                    t.decoration.set(None)
                }
            }));
            if t.xdg.initialized() {
                self.answer_decoration(&t)
            }
        }
    }

    /// Tell a window we draw its frame, and make room for it: the surface
    /// moves down and right by the frame's own metrics. Safe to repeat.
    fn answer_decoration(&self, t: &Toplevel) {
        let Some(dec) = t.decoration.take() else { return };
        dec.set_server_side();
        let (x, y) = self.metrics.get().surface(t.x.get(), t.y.get());
        t.x.set(x);
        t.y.set(y);
    }

    /// The frame texture for a decorated window as it is now.
    pub fn frame_texture(&self, t: &Toplevel) -> Option<Texture> {
        if !t.decorated.get() {
            return None;
        }
        let (_, _, w, h) = self.metrics.get().frame(t.x.get(), t.y.get(), t.width(), t.height());
        let active = self.focused().is_some_and(|f| f.id == t.id);
        let mut runner = self.runner.borrow_mut();
        let runner = runner.as_mut()?;
        self.frames.borrow_mut().texture(t.id, w, h, active, &t.title().unwrap_or_default(), self.session.renderer(), runner, &self.theme.borrow())
    }

    // MARK: maximize, minimize, fullscreen

    /// Zoom to the **usable area**, not the output; a decorated window's
    /// frame has to fit too.
    pub fn set_maximized(&self, t: &Rc<Toplevel>, on: bool) {
        // **Leaving a state you are not in changes nothing** (BACKLOG F.1).
        if !on && !t.maximized.get() {
            t.xdg.set_maximized(false);
            return;
        }
        if on {
            if t.restore_box.get().is_none() {
                t.restore_box.set(Some(t.rect()));
            }
            let mut b = {
                let layout = self.layout.borrow();
                let usable = self.usable.borrow();
                layout.display_for(t.rect()).and_then(|d| usable.get(&d.name).copied())
            }
            .unwrap_or_else(|| self.usable_area());
            if t.decorated.get() {
                let m = self.metrics.get();
                let (sx, sy) = m.surface(b.x, b.y);
                b = Rect::new(sx, sy, b.width - 2 * m.border as i32, b.height - m.title_height as i32 - m.border as i32);
            }
            t.x.set(b.x);
            t.y.set(b.y);
            t.xdg.set_size(b.width.max(0), b.height.max(0));
            self.maximize_count.set(self.maximize_count.get() + 1);
        } else if let Some(b) = t.restore_box.take() {
            t.x.set(b.x);
            t.y.set(b.y);
            t.xdg.set_size(b.width.max(0), b.height.max(0));
        }
        t.maximized.set(on);
        // **The configure is not optional**, including when the answer is no.
        t.xdg.set_maximized(on);
        t.republish();
    }

    /// Minimize to the Dock tile.
    pub fn set_minimized(&self, t: &Rc<Toplevel>, on: bool) {
        if t.minimized.get() == on {
            return;
        }
        t.minimized.set(on);
        self.refresh_suspended(t);
        if on {
            self.minimize_count.set(self.minimize_count.get() + 1);
            // A minimized window must not keep the keyboard.
            if self.focused().is_some_and(|f| Rc::ptr_eq(&f, t)) {
                self.focus_topmost();
            }
        } else {
            self.raise(t);
            self.focus(t);
        }
        t.republish();
    }

    /// The whole display the window is on.
    pub fn set_fullscreen(&self, t: &Rc<Toplevel>, on: bool) {
        if !on && !t.fullscreen.get() {
            t.xdg.set_fullscreen(false);
            return;
        }
        t.fullscreen.set(on);
        if on {
            if t.restore_box.get().is_none() {
                t.restore_box.set(Some(t.rect()));
            }
            let d = self.layout.borrow().display_for(t.rect()).map(|d| d.rect()).unwrap_or_default();
            t.x.set(d.x);
            t.y.set(d.y);
            t.xdg.set_size(d.width, d.height);
        } else if let Some(b) = t.restore_box.take() {
            t.x.set(b.x);
            t.y.set(b.y);
            t.xdg.set_size(b.width.max(0), b.height.max(0));
        }
        t.xdg.set_fullscreen(on);
    }

    // MARK: islands, as far as the core needs them

    /// The island display `d` is showing (1 until somebody switches).
    pub fn active_island(&self, d: &str) -> i32 {
        self.active_islands.borrow().get(d).copied().unwrap_or(1)
    }

    pub fn is_on_active_island(&self, t: &Toplevel) -> bool {
        self.active_island(&t.island_display.borrow()) == t.island.get()
    }

    /// Say so to the client: hidden is xdg-shell v6's `suspended`, and the
    /// hidden clock starts at once.
    pub fn refresh_suspended(&self, t: &Toplevel) {
        let hidden = t.minimized.get() || !self.is_on_active_island(t);
        if hidden == t.suspended_said.get() {
            return;
        }
        t.suspended_said.set(hidden);
        t.xdg.set_suspended(hidden);
        t.hidden_frame_at.set(0);
    }

    /// Which display a window lives on, and so which island it can be on:
    /// settled when it maps (`fresh`) and when a drag ends.
    pub fn settle_island(&self, t: &Toplevel, fresh: bool) {
        let d = {
            let l = self.layout.borrow();
            l.display_for(t.rect()).or_else(|| l.main()).map(|d| d.name.clone()).unwrap_or_default()
        };
        if !fresh && d == *t.island_display.borrow() {
            return;
        }
        t.island.set(self.active_island(&d));
        *t.island_display.borrow_mut() = d;
        self.refresh_suspended(t);
    }

    // MARK: layer shell

    fn adopt_layer(&self, handle: LayerSurface) -> Rc<Layer> {
        let l = Rc::new(Layer { handle, surface: handle.surface(), mapped: Cell::new(false), rect: Cell::new(Rect::default()), listeners: RefCell::default() });
        let both = || (self.me.clone(), Rc::downgrade(&l));
        let mut ls = vec![];
        let (wc, wl) = both();
        ls.extend(l.surface.on_map(move || {
            let (Some(c), Some(l)) = (wc.upgrade(), wl.upgrade()) else { return };
            l.mapped.set(true);
            c.arrange_layers();
        }));
        let (wc, wl) = both();
        ls.extend(l.surface.on_unmap(move || {
            let (Some(c), Some(l)) = (wc.upgrade(), wl.upgrade()) else { return };
            l.mapped.set(false);
            c.arrange_layers();
        }));
        // Same rule as xdg-shell: the first commit is answered with a
        // configure. And again on every commit: a client may change its
        // anchors or zone at any time (the menu bar does, opening a menu).
        let wc = self.me.clone();
        ls.extend(l.surface.on_commit(move || {
            if let Some(c) = wc.upgrade() {
                c.arrange_layers()
            }
        }));
        let (wc, wl) = both();
        ls.extend(handle.on_destroy(move || {
            let (Some(c), Some(l)) = (wc.upgrade(), wl.upgrade()) else { return };
            l.mapped.set(false);
            l.listeners.borrow_mut().clear();
            c.layers.borrow_mut().retain(|o| !Rc::ptr_eq(o, &l));
            c.arrange_layers();
        }));
        *l.listeners.borrow_mut() = ls;
        l
    }

    /// Place every layer surface and recompute the usable areas. **By
    /// layer, bottom to top**, each exclusive zone shrinking the area for
    /// everyone after it: why the menu bar reserves its strip and the Dock
    /// overlaps. **Configure every surface, reserve for mapped ones only**:
    /// an initialized surface that is not yet mapped still needs the
    /// configure it maps with (the menu bar that never appeared).
    pub fn arrange_layers(&self) {
        let mut layers = self.layers.borrow().clone();
        layers.sort_by_key(|l| l.layer());
        let displays = self.layout.borrow().displays.clone();
        for d in &displays {
            let full = d.rect();
            let mut area = full;
            for l in layers.iter().filter(|l| l.output_name() == d.name) {
                let (rect, remaining) = place_layer(&l.request(), area, full);
                l.configure(rect);
                if l.mapped.get() {
                    area = remaining;
                }
            }
            self.usable.borrow_mut().insert(d.name.clone(), area);
        }
        // On an output not in the layout (it went away): still owed a
        // configure, the main display's box, reserving nothing.
        let main = self.layout.borrow().main().map(|m| m.rect());
        for l in &layers {
            let name = l.output_name();
            if displays.iter().all(|d| d.name != name)
                && let Some(m) = main
            {
                l.configure(place_layer(&l.request(), m, m).0);
            }
        }
    }

    /// Mapped layer surfaces with buffers, in paint order.
    pub fn mapped_layers(&self) -> Vec<Rc<Layer>> {
        let mut v: Vec<Rc<Layer>> = self.layers.borrow().iter().filter(|l| l.mapped.get() && l.surface.has_buffer()).cloned().collect();
        v.sort_by_key(|l| l.layer());
        v
    }

    /// An output is being destroyed (a VT switched away): wlroots leaves a
    /// layer surface pointing at it, so the menu bar, Dock and desktop are
    /// parked until it is back. Their clients never hear of it.
    pub fn output_lost(&self, o: wlr::Output) {
        let name = o.name();
        let mut parked = 0;
        for l in self.layers.borrow().iter().filter(|l| l.handle.output() == Some(o)) {
            self.orphaned_layers.borrow_mut().push((Rc::downgrade(l), name.clone()));
            l.handle.set_output(None);
            parked += 1;
        }
        log(&format!("output {name} gone — {parked} layer surface(s) wait for it"));
    }

    /// An output of a name we had is back: where the layout has it, with
    /// the layer surfaces that were on it.
    pub fn output_returned(&self, o: wlr::Output) {
        let name = o.name();
        if let (Some(ol), Some(d)) = (self.output_layout, self.layout.borrow().named(&name)) {
            ol.add(o, d.x, d.y);
        }
        let mut back = 0;
        self.orphaned_layers.borrow_mut().retain(|(l, n)| {
            let Some(l) = l.upgrade() else { return false };
            if *n != name {
                return true;
            }
            l.handle.set_output(Some(o));
            back += 1;
            false
        });
        self.arrange_layers();
        log(&format!("output {name} back — {back} layer surface(s) on it again"));
    }

    /// A new arrangement of the displays (P14.7b): a window left on no
    /// display is brought to the main one, since a window nobody can reach
    /// is lost.
    pub fn apply_layout(&self, new: DisplayLayout) {
        if let Some(ol) = self.output_layout {
            for d in &new.displays {
                if let Some(o) = self.session.output_named(&d.name) {
                    ol.add(o, d.x, d.y);
                }
            }
        }
        {
            let mut u = self.usable.borrow_mut();
            for d in &new.displays {
                u.entry(d.name.clone()).or_insert(d.rect());
            }
        }
        *self.layout.borrow_mut() = new;
        self.arrange_layers();
        let area = self.usable_area();
        let ts = self.toplevels.borrow().clone();
        for t in ts.iter().filter(|t| t.mapped.get()) {
            let r = t.rect();
            let on_some = self.layout.borrow().displays.iter().any(|d| (r.x + r.width).min(d.x + d.width) > r.x.max(d.x) && (r.y + r.height).min(d.y + d.height) > r.y.max(d.y));
            if on_some {
                continue;
            }
            t.x.set(area.x + 0.max((area.width - t.width()) / 2));
            t.y.set(area.y + 0.max((area.height - t.height()) / 2));
            log(&format!("window {} was on no display; brought to the main one", t.place_key().unwrap_or_else(|| "?".into())));
            self.settle_island(t, false);
        }
    }

    /// The main display's usable area: where new windows open.
    pub fn usable_area(&self) -> Rect {
        let l = self.layout.borrow();
        let Some(m) = l.main() else { return Rect::default() };
        self.usable.borrow().get(&m.name).copied().unwrap_or(m.rect())
    }

    /// The usable area of the display a point is on, or the nearest.
    pub fn usable_area_at(&self, x: f64, y: f64) -> Rect {
        let l = self.layout.borrow();
        let (cx, cy) = l.clamp(x, y);
        let Some(d) = l.display_at(cx, cy) else {
            drop(l);
            return self.usable_area();
        };
        self.usable.borrow().get(&d.name).copied().unwrap_or(d.rect())
    }

    // MARK: popups

    fn adopt_popup(&self, popup: XdgPopup) -> Rc<Popup> {
        let p = Rc::new(Popup { popup, surface: popup.surface(), mapped: Cell::new(false), listeners: RefCell::default() });
        let both = || (self.me.clone(), Rc::downgrade(&p));
        let mut ls = vec![];
        // Keep it on its display: wlroots sends the initial configure on its
        // own; unconstraining schedules another, before anything is drawn.
        let (wc, wp) = both();
        ls.extend(p.surface.on_commit(move || {
            let (Some(c), Some(p)) = (wc.upgrade(), wp.upgrade()) else { return };
            if p.popup.initial_commit() {
                c.unconstrain(&p)
            }
        }));
        let (wc, wp) = both();
        ls.extend(p.surface.on_map(move || {
            let (Some(c), Some(p)) = (wc.upgrade(), wp.upgrade()) else { return };
            p.mapped.set(true);
            c.popups_mapped.set(c.popups_mapped.get() + 1);
            // Where it actually landed, so a test can click a row without
            // computing placement itself (§2.46).
            if let Some((x, y)) = c.popup_origin(&p) {
                log(&format!("popup mapped at {x},{y} {}x{}", p.surface.width(), p.surface.height()));
            }
        }));
        let (_, wp) = both();
        ls.extend(p.surface.on_unmap(move || {
            if let Some(p) = wp.upgrade() {
                p.mapped.set(false)
            }
        }));
        let (wc, wp) = both();
        ls.extend(popup.on_destroy(move || {
            let (Some(c), Some(p)) = (wc.upgrade(), wp.upgrade()) else { return };
            p.mapped.set(false);
            p.listeners.borrow_mut().clear();
            c.popups.borrow_mut().retain(|o| !Rc::ptr_eq(o, &p));
        }));
        *p.listeners.borrow_mut() = ls;
        p
    }

    /// The parent's surface origin and window-geometry offset, in layout
    /// coordinates: a window, a layer surface, or another popup.
    fn parent_frame(&self, p: &Popup) -> Option<(i32, i32, i32, i32)> {
        let parent = p.popup.parent()?;
        if let Some(t) = self.toplevels.borrow().iter().find(|t| t.surface == parent) {
            let (gx, gy) = t.xdg.geometry_offset();
            return Some((t.x.get(), t.y.get(), gx, gy));
        }
        if let Some(l) = self.layers.borrow().iter().find(|l| l.surface == parent) {
            let r = l.rect.get();
            return Some((r.x, r.y, 0, 0)); // a layer surface is its geometry
        }
        let up = self.popups.borrow().iter().find(|o| o.surface == parent).cloned()?;
        let (ox, oy) = self.popup_origin(&up)?;
        let (_, (gx, gy)) = up.popup.geometry();
        Some((ox, oy, gx, gy))
    }

    /// A popup's surface origin in layout coordinates, or None while its
    /// parent is not one we know.
    pub fn popup_origin(&self, p: &Popup) -> Option<(i32, i32)> {
        let (fx, fy, gx, gy) = self.parent_frame(p)?;
        let (pos, own) = p.popup.geometry();
        Some(popup_surface_origin((fx, fy), (gx, gy), pos, own))
    }

    /// The frame of the toplevel or layer surface at the top of the popup's
    /// chain: wlroots wants the box in the ROOT's coordinates (P10.8), or a
    /// submenu that fitted flips to the wrong side.
    fn root_frame(&self, p: &Rc<Popup>) -> Option<(i32, i32, i32, i32)> {
        let mut at = p.clone();
        for _ in 0..16 {
            let parent = at.popup.parent()?;
            let up = self.popups.borrow().iter().find(|o| o.surface == parent).cloned();
            match up {
                Some(u) => at = u,
                None => return self.parent_frame(&at),
            }
        }
        None
    }

    /// Keep it on its display: a menu opened near the right edge flips or
    /// slides, as its positioner asked, instead of hanging off the screen.
    fn unconstrain(&self, p: &Rc<Popup>) {
        let Some((fx, fy, gx, gy)) = self.root_frame(p) else { return };
        let d = self.layout.borrow().display_for(Rect::new(fx, fy, 1, 1)).map(|d| d.rect()).unwrap_or_default();
        p.popup.unconstrain(d.x - (fx + gx), d.y - (fy + gy), d.width, d.height);
    }

    /// Popups that can be seen, a child after its parent.
    pub fn mapped_popups(&self) -> Vec<(Rc<Popup>, (i32, i32))> {
        let ps = self.popups.borrow().clone();
        ps.into_iter().filter(|p| p.mapped.get() && p.surface.has_buffer()).filter_map(|p| self.popup_origin(&p).map(|o| (p, o))).collect()
    }

    // MARK: the frame's end

    /// Tell every mapped client the frame is done, so it draws the next.
    /// Without it a client renders one frame and waits for ever.
    pub fn send_frame_done(&self) {
        let now = mono::now();
        for t in self.mapped_toplevels() {
            t.surface.frame_done_tree();
        }
        // **A window nobody can see keeps a clock, a slow one** (U.2): a
        // FIFO client blocks in its swap until the callback comes. Once a
        // second keeps it alive and costs nothing.
        let hidden: Vec<Rc<Toplevel>> = self.toplevels.borrow().iter().filter(|t| t.mapped.get() && (t.minimized.get() || !self.is_on_active_island(t)) && t.surface.has_buffer()).cloned().collect();
        for t in hidden {
            if now.saturating_sub(t.hidden_frame_at.get()) >= HIDDEN_FRAME_PERIOD_NS {
                t.hidden_frame_at.set(now);
                t.surface.frame_done_tree();
            }
        }
        for l in self.mapped_layers() {
            l.surface.frame_done_tree();
        }
        // Or a menu draws once and never shows its hover.
        for (p, _) in self.mapped_popups() {
            p.surface.frame_done_tree();
        }
    }

    /// Close out a frame: release clients to draw the next, then push the
    /// queued events down their sockets. One call, so a caller cannot do
    /// half of it: a frame-done never flushed is a hang with no fingerprints.
    pub fn end_frame(&self) {
        self.send_frame_done();
        self.session.display().flush_clients();
    }

    /// The scene's view of this compositor.
    pub fn world(&self) -> CompositorWorld {
        CompositorWorld(self.rc())
    }
}

impl Drop for Compositor {
    fn drop(&mut self) {
        self.frames.borrow_mut().release();
        self.ebb_labels.borrow_mut().clear();
        self.strip_labels.borrow_mut().clear();
        self.listeners.borrow_mut().clear();
        for p in self.popups.borrow().iter() {
            p.listeners.borrow_mut().clear();
        }
        for t in self.toplevels.borrow().iter() {
            t.teardown();
        }
        for l in self.layers.borrow().iter() {
            l.listeners.borrow_mut().clear();
        }
    }
}

/// The scene's side of the seam (`scene::World`), over the compositor.
pub struct CompositorWorld(pub Rc<Compositor>);

impl World for CompositorWorld {
    fn take_island_input(&mut self, display: &str) -> u64 {
        self.0.island_inputs.borrow_mut().remove(display).unwrap_or(0)
    }
    fn is_locked(&self) -> bool {
        false
    }
    fn lock_surfaces(&self) -> Vec<(Surface, i32, i32)> {
        vec![]
    }
    fn mapped_layers(&self) -> Vec<SceneLayer> {
        self.0.mapped_layers().iter().map(|l| SceneLayer { layer: l.layer(), surface: l.surface, rect: l.rect.get() }).collect()
    }
    fn toplevels(&self) -> Vec<SceneWindow> {
        self.0
            .toplevels
            .borrow()
            .iter()
            .map(|t| SceneWindow {
                id: t.id,
                surface: t.surface,
                x: t.x.get(),
                y: t.y.get(),
                width: t.width(),
                height: t.height(),
                mapped: t.mapped.get(),
                minimized: t.minimized.get(),
                decorated: t.decorated.get(),
                island_display: Rc::from(t.island_display.borrow().as_str()),
                island: t.island.get() as u32,
                place_key: Rc::from(t.place_key().unwrap_or_default().as_str()),
            })
            .collect()
    }
    fn is_on_active_island(&self, w: &SceneWindow) -> bool {
        self.0.active_island(&w.island_display) == w.island as i32
    }
    fn ebb_frame(&mut self, d: &str, now: u64) -> Option<Ebb> {
        self.0.ebb_frame(d, now)
    }
    fn island_view(&mut self, d: &str, now: u64) -> Option<f64> {
        self.0.island_view(d, now)
    }
    fn strip_tiles(&self, d: &str) -> Vec<(usize, Rect)> {
        self.0.strip_tiles(d)
    }
    fn shoal(&self, i: usize) -> (String, Vec<String>) {
        self.0.shoal_book.borrow().shoals.get(i).map(|s| (s.name.clone(), s.members.clone())).unwrap_or_default()
    }
    fn frame_texture(&mut self, w: &SceneWindow) -> Option<Texture> {
        let t = self.0.toplevels.borrow().iter().find(|t| t.id == w.id).cloned()?;
        self.0.frame_texture(&t)
    }
    fn ebb_label(&mut self, w: &SceneWindow) -> Option<Label> {
        let t = self.0.toplevels.borrow().iter().find(|t| t.id == w.id).cloned()?;
        self.0.ebb_label(&t)
    }
    fn strip_label(&mut self, name: &str) -> Option<Label> {
        self.0.strip_label(name)
    }
    fn mapped_popups(&self) -> Vec<(Surface, i32, i32)> {
        self.0.mapped_popups().into_iter().map(|(p, (x, y))| (p.surface, x, y)).collect()
    }
    fn input_method_popups(&self) -> Vec<(Surface, i32, i32)> {
        vec![]
    }
    fn acquire(&self, _: Surface) -> Option<(Timeline, u64)> {
        None
    }
    fn cursor_signature(&self) -> u64 {
        0
    }
    fn theme_generation(&self) -> u64 {
        self.0.theme.borrow().generation
    }
}

/// The frame's size around a window, from the theme: the title bar and the
/// border (`chrome.border`), so undertow's frames and an Aqua window's own
/// are one height.
pub fn frame_metrics(theme: &Theme) -> FrameMetrics {
    FrameMetrics { title_height: theme.tokens.title_bar_height, border: theme.tokens.chrome_border }
}

#[cfg(test)]
#[path = "compositor_tests.rs"]
mod tests;
