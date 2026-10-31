//! Input (Seat.swift, PHASE6.md P6.4): a `wl_seat`, a cursor, focus, and the
//! routing that decides which surface a click belongs to.
//!
//! **Devices arrive through the virtual-input protocols** as well as the
//! backend: `abyss/tests/vpointer.c` and `vkeyboard.c` drive undertow as
//! they drive sway. **The cursor is compositor-drawn**: the pointer must not
//! round-trip to a client, and a headless capture shows where it is. What it
//! looks like (U.7) is the client's to say while it has the pointer, and the
//! theme's otherwise.

use crate::backend::{log as clog, BackendError};
use crate::compositor::{Compositor, Layer, Popup, Toplevel};
use crate::cursor_images::CursorImages;
use crate::frame::{cursor_name, FrameHit, EDGE_BOTTOM, EDGE_LEFT, EDGE_RIGHT};
use crate::geometry::Rect;
use crate::keys::{self, KeyAction, KeyBindings, KeyModifiers};
use crate::scene::{FrameHash, SurfaceScene, World};
use crate::session_lock::LockEvent;
use aquadraw::chrome::{chrome_hit, window_chrome, ChromeEdge, ChromeHit, Gadget};
use abyss_sys::wlr::{self, globals, DeviceKind, DragIcon, InputDevice, Keyboard, KeymapGiven, Listener, Pointer, Press, RenderPass, Surface, TextureDraw, CAP_KEYBOARD, CAP_POINTER};
use abyss_sys::mono;
use pool_config::{Config, KeyboardPrefs};
use std::cell::{Cell, RefCell};
use std::collections::{BTreeMap, HashMap, HashSet};
use std::os::unix::io::AsRawFd;
use std::rc::{Rc, Weak};

fn log(s: &str) {
    eprintln!("undertow: keyboard: {s}");
}

/// What the pointer looks like (U.7).
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum CursorImage {
    /// A theme shape, by cursor-shape-v1's (CSS's) name.
    Shape(String),
    /// A surface the client with the pointer gave us.
    Client,
    /// The client with the pointer asked for none.
    Hidden,
}

/// What the pointer is over.
#[derive(Clone)]
pub enum PointerTarget {
    Toplevel(Rc<Toplevel>, f64, f64),
    Layer(Rc<Layer>, f64, f64),
    /// A menu (P10.4): drawn over everything, so hit before everything.
    Popup(Rc<Popup>, f64, f64),
    /// The compositor's own frame (P9.6), in frame-local coordinates. **No
    /// client owns these pixels**: a press here is forwarded to nobody.
    Frame(Rc<Toplevel>, f64, f64),
    /// A lock surface (P16.2): while locked, the only thing there is.
    Lock(Surface, f64, f64),
}

impl PointerTarget {
    fn surface(&self) -> Option<Surface> {
        match self {
            PointerTarget::Toplevel(t, ..) => Some(t.surface),
            PointerTarget::Layer(l, ..) => Some(l.surface),
            PointerTarget::Popup(p, ..) => Some(p.surface),
            PointerTarget::Lock(s, ..) => Some(*s),
            PointerTarget::Frame(..) => None,
        }
    }
    fn local(&self) -> (f64, f64) {
        match self {
            PointerTarget::Toplevel(_, x, y) | PointerTarget::Layer(_, x, y) | PointerTarget::Popup(_, x, y) | PointerTarget::Frame(_, x, y) | PointerTarget::Lock(_, x, y) => (*x, *y),
        }
    }
}

/// The seat: pointer, keyboard, focus, and the routing between them.
pub struct Seat {
    pub seat: wlr::Seat,
    c: Weak<Compositor>,
    pub(crate) me: Weak<Seat>,
    /// relative-pointer and pointer-constraints (U.6).
    pub pointer_constraints: Option<crate::pointer_constraints::PointerConstraints>,
    /// text-input-v3 and input-method-v2 (U.5), made just after the seat.
    pub text_input: Option<crate::text_input::TextInputRelay>,
    keyboard: Cell<Option<Keyboard>>,
    listeners: RefCell<Vec<Listener>>,
    /// Listeners belonging to **one device**, by its address: a virtual
    /// pointer is a client resource, and wlroots asserts nothing still
    /// listens when it destroys it (HANDOFF §2.41).
    device_listeners: RefCell<HashMap<usize, Vec<Listener>>>,
    pub cursor: Cell<(f64, f64)>,
    pub cursor_visible: Cell<bool>,
    pub cursor_image: RefCell<CursorImage>,
    cursor_surface: Cell<Option<Surface>>,
    cursor_hot: Cell<(i32, i32)>,
    cursor_surface_listeners: RefCell<Vec<Listener>>,
    pub cursor_images: RefCell<CursorImages>,
    pub cursor_requests: Cell<u64>,
    pub cursor_refused: Cell<u64>,
    /// The session's layout (T.2): keyboard.ini's kbdmap, or "" for rc.conf's.
    pub session_kbdmap: RefCell<String>,
    /// The keyboards whose keymap is ours to change: those that had none.
    keymapped: RefCell<Vec<Keyboard>>,
    keyboard_watch: RefCell<Option<(pool_config::Watcher, wlr::Source)>>,
    stand_in: RefCell<Option<(Keyboard, wlr::Source)>>,
    pub layout_description: RefCell<String>,
    pub layout_changes: Cell<u64>,
    pub capabilities: Cell<u32>,
    /// The positive controls (§2.37): a copy dropped and a copy never made
    /// look the same from outside.
    pub selections_accepted: Cell<u64>,
    pub primary_selections_accepted: Cell<u64>,
    pub drags_started: Cell<u64>,
    drag_icon: Cell<Option<DragIcon>>,
    drag_icon_listener: RefCell<Option<Listener>>,
    /// The layer surface holding the keyboard (the menu bar, P10.4).
    keyboard_layer: RefCell<Option<Weak<Layer>>>,
    /// **A release must follow its press or not exist**: keys whose press
    /// the desktop took.
    consumed_keys: RefCell<HashSet<u32>>,
    strip_pressed: Cell<bool>,
    bindings: RefCell<KeyBindings>,
    bindings_loaded_at: Cell<i64>,
    bindings_checked: Cell<u64>,
    pub keybinds_fired: Cell<u64>,
    pub frame_clicks: Cell<u64>,
    pub grabs_broken: Cell<u64>,
}

impl Seat {
    pub fn new(c: &Rc<Compositor>) -> Result<Rc<Seat>, BackendError> {
        let d = c.session.display();
        let seat = globals::seat(d, "seat0").ok_or_else(|| BackendError::NoGlobals("wl_seat".into()))?;
        // The middle of the main display.
        let m = c.layout.borrow().main().map(|m| m.rect()).unwrap_or(Rect::new(0, 0, 2, 2));
        let start = (m.x as f64 + m.width as f64 / 2.0, m.y as f64 + m.height as f64 / 2.0);
        let s = Rc::new_cyclic(|me| Seat {
            seat,
            c: Rc::downgrade(c),
            me: me.clone(),
            pointer_constraints: crate::pointer_constraints::PointerConstraints::new(d, me.clone()),
            text_input: crate::text_input::TextInputRelay::new(d, seat, me.clone()),
            keyboard: Cell::new(None),
            listeners: RefCell::default(),
            device_listeners: RefCell::default(),
            cursor: Cell::new(start),
            cursor_visible: Cell::new(true),
            cursor_image: RefCell::new(CursorImage::Shape("default".into())),
            cursor_surface: Cell::new(None),
            cursor_hot: Cell::new((0, 0)),
            cursor_surface_listeners: RefCell::default(),
            cursor_images: RefCell::default(),
            cursor_requests: Cell::new(0),
            cursor_refused: Cell::new(0),
            session_kbdmap: RefCell::default(),
            keymapped: RefCell::default(),
            keyboard_watch: RefCell::default(),
            stand_in: RefCell::default(),
            layout_description: RefCell::default(),
            layout_changes: Cell::new(0),
            capabilities: Cell::new(0),
            selections_accepted: Cell::new(0),
            primary_selections_accepted: Cell::new(0),
            drags_started: Cell::new(0),
            drag_icon: Cell::new(None),
            drag_icon_listener: RefCell::default(),
            keyboard_layer: RefCell::default(),
            consumed_keys: RefCell::default(),
            strip_pressed: Cell::new(false),
            bindings: RefCell::default(),
            bindings_loaded_at: Cell::new(0),
            bindings_checked: Cell::new(0),
            keybinds_fired: Cell::new(0),
            frame_clicks: Cell::new(0),
            grabs_broken: Cell::new(0),
        });
        c.cursor.set(Some(start));
        *c.seat.borrow_mut() = Rc::downgrade(&s);
        // Focus as the compositor moves it, and the lock as it changes: the
        // keyboard's half is ours.
        let w = Rc::downgrade(&s);
        c.on_focus(move |t| {
            if let Some(s) = w.upgrade() {
                s.focus_moved(t)
            }
        });
        let w = Rc::downgrade(&s);
        c.on_lock(move |e| {
            if let Some(s) = w.upgrade() {
                s.lock_event(e)
            }
        });

        let mut ls = vec![];
        let me = || Rc::downgrade(&s);
        // Real devices, when there are any; and those there before the seat.
        let w = me();
        ls.extend(c.session.backend().on_new_input(move |d| {
            if let Some(s) = w.upgrade() {
                s.attach_device(d)
            }
        }));
        for d in c.session.take_startup_inputs() {
            s.attach_device(d)
        }
        // Virtual devices: how the harness drives us, exactly as sway.
        let vp = globals::virtual_pointer_manager(d).ok_or_else(|| BackendError::NoGlobals("zwlr_virtual_pointer_manager_v1".into()))?;
        let w = me();
        ls.extend(vp.on_new_virtual_pointer(move |p| {
            if let (Some(s), Some(p)) = (w.upgrade(), p) {
                s.attach_pointer(p)
            }
        }));
        let vk = globals::virtual_keyboard_manager(d).ok_or_else(|| BackendError::NoGlobals("zwp_virtual_keyboard_manager_v1".into()))?;
        let w = me();
        ls.extend(vk.on_new_virtual_keyboard(move |k| {
            if let (Some(s), Some(k)) = (w.upgrade(), k) {
                s.attach_keyboard(k)
            }
        }));
        // **The clipboard, which never worked for anybody**: the data device
        // manager publishes the global and nothing else, and wlroots' header
        // says to accept `set_selection` ourselves. The serial is checked by
        // wlroots: a client cannot set the clipboard from one it never got.
        let w = me();
        ls.extend(seat.on_request_set_selection(move |r| {
            if let Some(s) = w.upgrade() {
                s.seat.accept_selection(r, false);
                s.selections_accepted.set(s.selections_accepted.get() + 1);
            }
        }));
        // **The primary selection (U.9)**: select, middle-click to paste.
        globals::primary_selection(d);
        let w = me();
        ls.extend(seat.on_request_set_primary_selection(move |r| {
            if let Some(s) = w.upgrade() {
                s.seat.accept_selection(r, true);
                s.primary_selections_accepted.set(s.primary_selections_accepted.get() + 1);
            }
        }));
        // **Drag and drop (P9.3)**, the selection with a grab on it: only
        // from a press the client really received.
        let w = me();
        ls.extend(seat.on_request_start_drag(move |r| {
            if let Some(s) = w.upgrade() {
                s.seat.accept_drag(r);
            }
        }));
        let w = me();
        ls.extend(seat.on_start_drag(move |icon| {
            let Some(s) = w.upgrade() else { return };
            s.drags_started.set(s.drags_started.get() + 1);
            s.drag_icon.set(icon);
            // The icon dies with the drag: a freed surface on the next frame
            // is a crash, not a missing picture.
            if let Some(i) = icon {
                let w2 = s.me.clone();
                *s.drag_icon_listener.borrow_mut() = i.on_destroy(move || {
                    if let Some(s) = w2.upgrade() {
                        s.drag_icon.set(None);
                        let l = s.drag_icon_listener.borrow_mut().take();
                        drop(l);
                    }
                });
            }
        }));
        // **The pointer's picture (U.7)**: a client may set it only while
        // it has the pointer. wlroots says who asked; the check is ours.
        let w = me();
        ls.extend(seat.on_request_set_cursor(move |r| {
            let Some(s) = w.upgrade() else { return };
            if r.client != s.seat.pointer_focused_client() {
                return s.cursor_refused.set(s.cursor_refused.get() + 1);
            }
            s.cursor_requests.set(s.cursor_requests.get() + 1);
            match r.surface {
                Some(sf) => s.set_cursor_surface(sf, r.hot_x, r.hot_y),
                None => s.set_cursor(CursorImage::Hidden),
            }
        }));
        if let Some(shapes) = globals::cursor_shape_manager(d, 1) {
            let w = me();
            ls.extend(shapes.on_request_set_shape(move |(name, client)| {
                let Some(s) = w.upgrade() else { return };
                match name.filter(|_| client == s.seat.pointer_focused_client()) {
                    Some(n) => {
                        s.cursor_requests.set(s.cursor_requests.get() + 1);
                        s.set_cursor(CursorImage::Shape(n));
                    }
                    None => s.cursor_refused.set(s.cursor_refused.get() + 1),
                }
            }));
        }
        // The pointer went elsewhere: the arrow, until whoever has it says.
        let w = me();
        ls.extend(seat.on_pointer_focus_change(move |changed| {
            if let (Some(s), true) = (w.upgrade(), changed) {
                s.set_cursor(CursorImage::Shape("default".into()))
            }
        }));
        *s.listeners.borrow_mut() = ls;
        Ok(s)
    }

    pub(crate) fn c(&self) -> Rc<Compositor> {
        self.c.upgrade().expect("the compositor outlives its seat")
    }

    pub fn cursor_signature(&self) -> u64 {
        let mut h = FrameHash::default();
        let (x, y) = self.cursor.get();
        h.add(x.floor() as i64 as u64);
        h.add(y.floor() as i64 as u64);
        match &*self.cursor_image.borrow() {
            CursorImage::Hidden => h.add(1),
            CursorImage::Client => {
                h.add(2);
                if let Some(s) = self.cursor_surface.get() {
                    h.add(s.addr() as u64);
                    h.add(s.seq() as u64);
                }
            }
            CursorImage::Shape(n) => {
                h.add(3);
                for b in n.bytes() {
                    h.add(b as u64)
                }
            }
        }
        if let Some(s) = self.drag_icon.get().and_then(|i| i.surface()) {
            h.add(s.addr() as u64);
            h.add(s.seq() as u64);
        }
        h.0
    }

    fn set_cursor_pos(&self, x: f64, y: f64) {
        let (x, y) = self.c().layout.borrow().clamp(x, y);
        self.cursor.set((x, y));
        self.c().cursor.set(Some((x, y)));
    }

    // MARK: devices

    fn add_capability(&self, cap: u32) {
        self.capabilities.set(self.capabilities.get() | cap);
        self.seat.set_capabilities(self.capabilities.get());
    }

    fn attach_device(&self, d: InputDevice) {
        match d.kind() {
            DeviceKind::Pointer(p) => self.attach_pointer(p),
            DeviceKind::Keyboard(k) => {
                // Before attaching: setting the seat's keyboard is what sends
                // clients its keymap.
                if self.give_keymap(k) {
                    self.keymapped.borrow_mut().push(k)
                }
                self.attach_keyboard(k)
            }
            DeviceKind::Other => {}
        }
    }

    /// The seat's keyboard, the last attached that still exists.
    pub(crate) fn keyboard(&self) -> Option<Keyboard> {
        self.keyboard.get()
    }

    fn forget_device(&self, d: InputDevice, key: usize) {
        if self.keyboard.get().is_some_and(|k| k.device() == d) {
            self.keyboard.set(None)
        }
        self.keymapped.borrow_mut().retain(|k| k.device() != d);
        // This device's listeners, dropped from inside one of them.
        let gone = self.device_listeners.borrow_mut().remove(&key);
        drop(gone);
    }

    fn attach_pointer(&self, p: Pointer) {
        let me = || self.me.clone();
        let mut g = vec![];
        let w = me();
        g.extend(p.on_motion_absolute(move |(x, y, t)| {
            let Some(s) = w.upgrade() else { return };
            // Absolute devices (a tablet, the virtual pointer) span the
            // layout, and their delta is from where the pointer is: locked,
            // the pointer stays and each report is a fresh delta from there.
            let b = s.c().layout.borrow().bounds();
            let (cx, cy) = s.cursor.get();
            let (dx, dy) = (b.x as f64 + x * b.width as f64 - cx, b.y as f64 + y * b.height as f64 - cy);
            s.motion((dx, dy), (dx, dy), t);
        }));
        let w = me();
        g.extend(p.on_motion(move |m| {
            if let Some(s) = w.upgrade() {
                s.motion((m.dx, m.dy), (m.unaccel_dx, m.unaccel_dy), m.time_msec)
            }
        }));
        let w = me();
        g.extend(p.on_button(move |b| {
            if let Some(s) = w.upgrade() {
                s.c().activity(Some(s.seat));
                s.button(b)
            }
        }));
        let w = me();
        g.extend(p.on_axis(move |e| {
            if let Some(s) = w.upgrade() {
                s.c().activity(Some(s.seat));
                s.seat.pointer_axis(e)
            }
        }));
        let (w, dev, key) = (me(), p.device(), p.addr());
        g.extend(dev.on_destroy(move || {
            if let Some(s) = w.upgrade() {
                s.forget_device(dev, key)
            }
        }));
        self.device_listeners.borrow_mut().insert(key, g);
        self.add_capability(CAP_POINTER);
    }

    fn attach_keyboard(&self, k: Keyboard) {
        let me = || self.me.clone();
        let mut g = vec![];
        let w = me();
        g.extend(k.on_key(move |e| {
            if let Some(s) = w.upgrade() {
                s.key(k, e)
            }
        }));
        let w = me();
        g.extend(k.on_modifiers(move || {
            let Some(s) = w.upgrade() else { return };
            if !s.c().is_locked() && s.route_modifiers_to_method(k) {
                return;
            }
            s.seat.keyboard_modifiers(k)
        }));
        let (w, dev, key) = (me(), k.device(), k.addr());
        g.extend(dev.on_destroy(move || {
            if let Some(s) = w.upgrade() {
                s.forget_device(dev, key)
            }
        }));
        self.device_listeners.borrow_mut().insert(key, g);
        // The seat carries one active keyboard; its keymap is what clients
        // are told. wlroots drops it from the seat when it is destroyed.
        self.seat.set_keyboard(k);
        self.keyboard.set(Some(k));
        self.add_capability(CAP_KEYBOARD);
        // **Deliver the focus recorded before there was a keyboard**: a
        // window focused first was deaf for the rest of its life (P9.2).
        let c = self.c();
        let target = if c.is_locked() { c.lock_keyboard_target() } else { c.focused().map(|t| t.surface) };
        if let Some(sf) = target {
            self.seat.keyboard_enter(sf);
        }
    }

    // MARK: keymaps (T.2)

    /// The layout a keyboard with none of its own gets, in order: (1)
    /// `XKB_DEFAULT_LAYOUT`, which xkbcommon reads itself; (2) the session's
    /// keyboard.ini kbdmap; (3) rc.conf's `keymap=`, translated, so the
    /// desktop types what the console types; (4) xkbcommon's default, US.
    pub fn keymap_choice(rc_conf: &[&str], session: &str) -> Option<(String, String)> {
        if std::env::var_os("XKB_DEFAULT_LAYOUT").is_some() {
            return None;
        }
        if !session.is_empty() {
            if let Some((k, _)) = install::keymaps::xkb(session)
                && wlr::keymap_compiles(&k.layout, &k.variant)
            {
                log(&format!("the session's keymap {session} is XKB {}{}", k.layout, if k.variant.is_empty() { String::new() } else { format!("({})", k.variant) }));
                return Some((k.layout, k.variant));
            }
            log(&format!("the session's keymap {session} has no XKB layout that compiles; trying rc.conf's"));
        }
        if let Some(kbdmap) = install::keymaps::configured(rc_conf) {
            if let Some((k, exact)) = install::keymaps::xkb(&kbdmap)
                && wlr::keymap_compiles(&k.layout, &k.variant)
            {
                log(&format!("rc.conf's keymap {kbdmap} is XKB {}{}{}", k.layout, if k.variant.is_empty() { String::new() } else { format!("({})", k.variant) }, if exact { "" } else { ", guessed from its name" }));
                return Some((k.layout, k.variant));
            }
            log(&format!("rc.conf's keymap {kbdmap} has no XKB layout that compiles; using the default"));
        }
        None
    }

    const RC_CONF: [&'static str; 2] = ["/etc/rc.conf", "/etc/rc.conf.local"];

    /// **A backend keyboard can arrive with no keymap** (libinput's never
    /// has one): without it, keycodes reach clients that nobody can read.
    fn give_keymap(&self, k: Keyboard) -> bool {
        let name = k.device().name();
        let choice = Seat::keymap_choice(&Seat::RC_CONF, &self.session_kbdmap.borrow());
        match k.give_keymap(choice.as_ref().map(|(l, v)| (l.as_str(), v.as_str()))) {
            KeymapGiven::HadOne => {
                log(&format!("{name} came with keymap {}; keeping it", k.layout_name().unwrap_or_else(|| "(unnamed)".into())));
                false
            }
            KeymapGiven::NoneCompiled => {
                log("no keymap compiled (are the xkeyboard-config layouts installed?) — this keyboard's keys will reach clients as codes nobody can read");
                false
            }
            KeymapGiven::Refused => {
                log("wlroots refused the keymap");
                false
            }
            KeymapGiven::Given => {
                log(&format!("{name} had no keymap; gave it {}", k.layout_name().unwrap_or_else(|| "(unnamed)".into())));
                true
            }
        }
    }

    /// Read keyboard.ini now, and follow it: a change re-keys every
    /// keyboard whose keymap is ours, and the seat sends the focused client
    /// the new keymap.
    pub fn follow_session_layout(&self) {
        let c = self.c();
        *self.session_kbdmap.borrow_mut() = KeyboardPrefs::load(c.config_dir.as_deref()).kbdmap;
        self.describe_layout();
        if self.keyboard_watch.borrow().is_some() {
            return;
        }
        let Ok(watch) = pool_config::Watcher::new(c.config_dir.as_deref()) else { return };
        let w = self.me.clone();
        let Some(src) = c.session.event_loop().add_fd(watch.as_raw_fd(), move || {
            let Some(s) = w.upgrade() else { return };
            if let Some((watch, _)) = &*s.keyboard_watch.borrow() {
                watch.drain();
            }
            let now = KeyboardPrefs::load(s.c().config_dir.as_deref()).kbdmap;
            if now != *s.session_kbdmap.borrow() {
                s.apply_session_layout(&now)
            }
        }) else {
            return;
        };
        *self.keyboard_watch.borrow_mut() = Some((watch, src));
    }

    fn apply_session_layout(&self, kbdmap: &str) {
        *self.session_kbdmap.borrow_mut() = kbdmap.into();
        self.layout_changes.set(self.layout_changes.get() + 1);
        let choice = Seat::keymap_choice(&Seat::RC_CONF, kbdmap).unwrap_or_default();
        let ks = self.keymapped.borrow().clone();
        for k in &ks {
            k.set_layout(&choice.0, &choice.1);
        }
        self.describe_layout();
        log(&format!("keyboard layout is now {}, on {} keyboard(s)", self.layout_description.borrow(), ks.len()));
    }

    fn describe_layout(&self) {
        let session = self.session_kbdmap.borrow().clone();
        let (source, name) = if let Ok(l) = std::env::var("XKB_DEFAULT_LAYOUT") {
            ("environment".to_owned(), l)
        } else if !session.is_empty() {
            ("keyboard.ini".into(), install::keymaps::display_name(&session))
        } else if let Some(k) = install::keymaps::configured(&Seat::RC_CONF) {
            ("rc.conf".into(), install::keymaps::display_name(&k))
        } else {
            ("default".into(), "U.S.".into())
        };
        *self.layout_description.borrow_mut() = format!("{name} ({source})");
    }

    /// A stand-in for a hardware keyboard, fed from `fifo` (lines of
    /// `k CODE`: press and release), so a headless run has what metal has.
    pub fn add_stand_in_keyboard(&self, fifo: &str) -> bool {
        use std::os::unix::fs::OpenOptionsExt;
        if self.stand_in.borrow().is_some() {
            return false;
        }
        let Some(k) = Keyboard::stand_in() else { return false };
        // Read-write: never sees EOF between writers.
        let Ok(file) = std::fs::OpenOptions::new().read(true).write(true).custom_flags(libc::O_NONBLOCK).open(fifo) else { return false };
        if self.give_keymap(k) {
            self.keymapped.borrow_mut().push(k)
        }
        self.attach_keyboard(k);
        let fd = file.as_raw_fd();
        let mut buffer = Vec::new();
        let Some(src) = self.c().session.event_loop().add_fd(fd, move || {
            use std::io::Read;
            let mut buf = [0u8; 512];
            let n = (&file).read(&mut buf).unwrap_or(0);
            buffer.extend_from_slice(&buf[..n]);
            while let Some(nl) = buffer.iter().position(|&b| b == b'\n') {
                let line: Vec<u8> = buffer.drain(..=nl).collect();
                let line = String::from_utf8_lossy(&line[..nl]).into_owned();
                let f: Vec<&str> = line.split(' ').collect();
                if let ["k", code] = f[..]
                    && let Ok(code) = code.parse::<u32>()
                {
                    let ms = (mono::now() / 1_000_000) as u32;
                    k.stand_in_key(code, true, ms);
                    k.stand_in_key(code, false, ms);
                }
            }
        }) else {
            return false;
        };
        *self.stand_in.borrow_mut() = Some((k, src));
        true
    }

    // MARK: routing

    /// Hit-test everything the pointer can address, in paint order: lock;
    /// popups; top and overlay layers; windows top to bottom, **each with its
    /// frame** before the one underneath; bottom and background layers.
    /// (Layer surfaces were never in this search under undertow, P9.3.)
    pub fn target(&self, x: f64, y: f64) -> Option<PointerTarget> {
        let c = self.c();
        if c.is_locked() {
            for (s, d) in c.lock_mapped() {
                let (lx, ly) = (x - d.x as f64, y - d.y as f64);
                if lx >= 0.0 && ly >= 0.0 && lx < d.width as f64 && ly < d.height as f64 && s.surface_at(lx, ly).is_some() {
                    return Some(PointerTarget::Lock(s, lx, ly));
                }
            }
            return None;
        }
        for (p, (ox, oy)) in c.mapped_popups().into_iter().rev() {
            let (lx, ly) = (x - ox as f64, y - oy as f64);
            if p.surface.surface_at(lx, ly).is_some() {
                return Some(PointerTarget::Popup(p, lx, ly));
            }
        }
        let layers = c.mapped_layers();
        if let Some(h) = hit_layer(layers.iter().filter(|l| l.layer() >= 2), x, y) {
            return Some(h);
        }
        let m = c.metrics.get();
        for t in c.mapped_toplevels().into_iter().rev() {
            let (lx, ly) = (x - t.x.get() as f64, y - t.y.get() as f64);
            if t.surface.surface_at(lx, ly).is_some() {
                return Some(PointerTarget::Toplevel(t, lx, ly));
            }
            if !t.decorated.get() {
                continue;
            }
            let (bx, by, bw, bh) = m.frame(t.x.get(), t.y.get(), t.width(), t.height());
            let (fx, fy) = (x - bx as f64, y - by as f64);
            if fx >= 0.0 && fy >= 0.0 && fx < bw as f64 && fy < bh as f64 {
                return Some(PointerTarget::Frame(t, fx, fy));
            }
        }
        hit_layer(layers.iter().filter(|l| l.layer() < 2), x, y)
    }

    /// What a press on the compositor's own frame means: **the same answer
    /// the painter drew from** (P11.6), the foreign frame's layout.
    pub fn frame_hit(&self, t: &Toplevel, x: f64, y: f64) -> FrameHit {
        let c = self.c();
        let (_, _, w, h) = c.metrics.get().frame(t.x.get(), t.y.get(), t.width(), t.height());
        let theme = c.theme.borrow();
        let l = window_chrome(&theme.tokens, w as f64, h as f64, true);
        match chrome_hit(&theme.tokens, &l, x, y) {
            ChromeHit::Gadget(Gadget::Close) => FrameHit::Close,
            ChromeHit::Gadget(Gadget::Minimize) => FrameHit::Minimize,
            ChromeHit::Gadget(Gadget::Zoom) => FrameHit::Zoom,
            ChromeHit::Gadget(Gadget::Depth) => FrameHit::Depth,
            ChromeHit::Gadget(Gadget::Pill) | ChromeHit::Title => FrameHit::Title,
            ChromeHit::Resize(ChromeEdge::Bottom) => FrameHit::Resize(EDGE_BOTTOM),
            ChromeHit::Resize(ChromeEdge::BottomLeft) => FrameHit::Resize(EDGE_BOTTOM | EDGE_LEFT),
            ChromeHit::Resize(ChromeEdge::BottomRight) => FrameHit::Resize(EDGE_BOTTOM | EDGE_RIGHT),
            ChromeHit::Content => FrameHit::Body,
        }
    }

    /// The displays moved (P14.7b): keep the pointer on one of them.
    pub fn keep_cursor_on_displays(&self) {
        let (x, y) = self.cursor.get();
        self.set_cursor_pos(x, y);
    }

    /// A motion, from any pointer: the delta goes to the client with the
    /// pointer, then a constraint decides where the pointer itself goes.
    fn motion(&self, d: (f64, f64), unaccel: (f64, f64), time_msec: u32) {
        let c = self.c();
        // Any input is a person, and wakes sleeping displays (U.9).
        c.activity(Some(self.seat));
        let (x, y) = self.cursor.get();
        let to = (x + d.0, y + d.1);
        if self.pointer_constraints.is_none() {
            return self.move_cursor(to.0, to.1, time_msec);
        }
        self.send_relative(time_msec, d, unaccel);
        // A move or resize grab owns the pointer, constraint or not.
        if c.moving().is_some() || c.resizing().is_some() {
            return self.move_cursor(to.0, to.1, time_msec);
        }
        match self.constrain((x, y), to) {
            // Locked: the pointer stays, and the delta's frame closes here.
            None => self.seat.pointer_frame(),
            Some((nx, ny)) => {
                self.move_cursor(nx, ny, time_msec);
                self.refresh_constraints();
            }
        }
    }

    /// Put the pointer somewhere without telling the client it moved.
    pub fn warp_cursor(&self, x: f64, y: f64, sx: f64, sy: f64) {
        self.set_cursor_pos(x, y);
        self.seat.pointer_warp(sx, sy);
    }

    pub fn move_cursor(&self, x: f64, y: f64, time_msec: u32) {
        let c = self.c();
        if c.is_locked() {
            self.break_grabs();
        }
        self.set_cursor_pos(x, y);
        let (cx, cy) = self.cursor.get();
        // A move or resize owns the pointer: no client is told it moved,
        // which is what stops a drag falling through onto what it passes.
        if c.moving().is_some() {
            return c.update_move(cx, cy);
        }
        if c.resizing().is_some() {
            return c.update_resize(cx, cy);
        }
        // Ebb open: the pointer is Ebb's (P13.5).
        if c.ebb.borrow().is_some() {
            c.ebb_hover(cx, cy);
            self.seat.pointer_clear_focus();
            return self.set_cursor(CursorImage::Shape("default".into()));
        }
        let Some(hit) = self.target(cx, cy) else {
            // Off every surface: the pointer is the desktop's.
            self.seat.pointer_clear_focus();
            return self.set_cursor(CursorImage::Shape("default".into()));
        };
        // A frame has no client: nobody is told the pointer is there, and
        // its picture is ours (sizing arrows on the edges that size).
        let Some(surface) = hit.surface() else {
            self.seat.pointer_clear_focus();
            if let PointerTarget::Frame(t, fx, fy) = &hit {
                self.set_cursor(CursorImage::Shape(cursor_name(self.frame_hit(t, *fx, *fy)).into()));
            }
            return;
        };
        let (rx, ry) = hit.local();
        // The leaf, in its own coordinates: a subsurface is a surface.
        let (leaf, lx, ly) = surface.surface_at(rx, ry).unwrap_or((surface, rx, ry));
        // Idempotent: wlroots sends enter only when the surface changes.
        self.seat.pointer_enter(leaf, lx, ly);
        self.seat.pointer_motion(time_msec, lx, ly);
        self.seat.pointer_frame();
    }

    fn set_cursor(&self, image: CursorImage) {
        self.drop_cursor_surface();
        *self.cursor_image.borrow_mut() = image;
    }

    /// The client's own surface, its hotspot `hx, hy` in from its corner.
    fn set_cursor_surface(&self, s: Surface, hx: i32, hy: i32) {
        if self.cursor_surface.get() != Some(s) {
            self.drop_cursor_surface();
            self.cursor_surface.set(Some(s));
            let (w1, w2) = (self.me.clone(), self.me.clone());
            // The surface may go before the pointer moves: the arrow then.
            let ls: Vec<Listener> = [
                s.on_destroy(move || {
                    if let Some(s) = w1.upgrade() {
                        s.set_cursor(CursorImage::Shape("default".into()))
                    }
                }),
                // An attach offset moves the hotspot the other way.
                s.on_commit(move || {
                    if let Some(st) = w2.upgrade() {
                        let (dx, dy) = s.offset();
                        let (hx, hy) = st.cursor_hot.get();
                        st.cursor_hot.set((hx - dx, hy - dy));
                    }
                }),
            ]
            .into_iter()
            .flatten()
            .collect();
            *self.cursor_surface_listeners.borrow_mut() = ls;
        }
        self.cursor_hot.set((hx, hy));
        *self.cursor_image.borrow_mut() = CursorImage::Client;
    }

    /// Off the client's surface's signals, from inside one of them if need
    /// be (§2.82).
    fn drop_cursor_surface(&self) {
        let gone = std::mem::take(&mut *self.cursor_surface_listeners.borrow_mut());
        drop(gone);
        self.cursor_surface.set(None);
    }

    fn button(&self, b: Press) {
        let c = self.c();
        let (cx, cy) = self.cursor.get();
        if c.is_locked() {
            self.break_grabs();
        }
        // Ebb open: a click picks a window or puts the tide back.
        if c.ebb.borrow().is_some() && !c.is_locked() {
            if b.pressed {
                c.ebb_click(cx, cy)
            }
            return;
        }
        // The Shoals strip takes a click on its tiles (P13.6).
        if b.pressed && !c.is_locked() && c.strip_click(cx, cy) {
            return self.strip_pressed.set(true);
        }
        if !b.pressed && self.strip_pressed.replace(false) {
            return;
        }
        // Releasing ends a move or resize; the window's place is remembered.
        if !b.pressed && (c.moving().is_some() || c.resizing().is_some()) {
            c.end_move();
            c.end_resize();
            self.seat.pointer_button(b.time_msec, b.code, false);
            return self.seat.pointer_frame();
        }
        // Click to focus and raise before the click is delivered, so the
        // client receives the press already focused. Only a window takes
        // focus: a click on the Dock must not steal the keyboard.
        let hit = self.target(cx, cy);
        if b.pressed {
            match &hit {
                Some(PointerTarget::Toplevel(t, ..)) => c.focus(t),
                // **A layer surface that asked for the keyboard gets it on
                // a click** (`on_demand`: the menu bar, P10.4). The window
                // stays active: the bar is not an application.
                Some(PointerTarget::Layer(l, ..)) if l.takes_keyboard_on_click() => self.give_keyboard(l),
                // A press on the compositor's own frame: answered here, and
                // forwarded to nobody.
                Some(PointerTarget::Frame(t, fx, fy)) => {
                    c.focus(t);
                    match self.frame_hit(t, *fx, *fy) {
                        FrameHit::Close => t.xdg.send_close(),
                        FrameHit::Minimize => c.set_minimized(t, true),
                        FrameHit::Zoom => c.set_maximized(t, !t.maximized.get()),
                        FrameHit::Depth => c.lower(t),
                        FrameHit::Title => c.begin_move(t),
                        FrameHit::Resize(edges) => c.begin_resize(t, edges),
                        FrameHit::Body => {}
                    }
                    return self.frame_clicks.set(self.frame_clicks.get() + 1);
                }
                _ => {}
            }
        }
        self.seat.pointer_button(b.time_msec, b.code, b.pressed);
        self.seat.pointer_frame();
    }

    /// The layer surface holding the keyboard, if one does.
    pub fn keyboard_layer(&self) -> Option<Rc<Layer>> {
        self.keyboard_layer.borrow().as_ref().and_then(Weak::upgrade)
    }

    pub fn give_keyboard(&self, l: &Rc<Layer>) {
        if self.c().is_locked() || self.keyboard_layer().is_some_and(|k| Rc::ptr_eq(&k, l)) {
            return;
        }
        if self.seat.keyboard_enter(l.surface) {
            *self.keyboard_layer.borrow_mut() = Some(Rc::downgrade(l));
        }
    }

    /// Hand the keyboard back to the active window: when the bar's menu
    /// closes, or the layer that had it goes. The keys go back to the
    /// application you were in, which never stopped being frontmost.
    pub fn restore_keyboard(&self) {
        let c = self.c();
        if c.is_locked() || self.keyboard_layer.borrow_mut().take().is_none() {
            return;
        }
        match c.focused() {
            Some(t) => {
                self.seat.keyboard_enter(t.surface);
            }
            None => self.seat.keyboard_clear_focus(),
        }
    }

    /// Focus moved in the compositor: the keyboard follows, unless a
    /// layer surface has it, in which case clicking the active window again
    /// gives it back.
    fn focus_moved(&self, t: Option<&Rc<Toplevel>>) {
        // A constraint holds only for the focused window: ⌘-Tab ends a lock.
        let Some(t) = t else {
            self.seat.keyboard_clear_focus();
            return self.refresh_constraints();
        };
        *self.keyboard_layer.borrow_mut() = None;
        // No keyboard yet: the focus is recorded, and told when one arrives.
        self.seat.keyboard_enter(t.surface);
        self.refresh_constraints();
    }

    // MARK: the session lock (P16.2)

    /// **No grab survives a lock**: a client behind it with a grabbing
    /// popup would be handed the keys typed into the lock screen.
    pub fn break_grabs(&self) {
        let n = self.seat.break_grabs(self.c().lock_keyboard_target());
        self.grabs_broken.set(self.grabs_broken.get() + n as u64);
    }

    fn lock_event(&self, e: LockEvent) {
        let c = self.c();
        match e {
            // Nothing behind the lock keeps the pointer, the keys, a grab or
            // the bar's keyboard.
            LockEvent::Locked => {
                self.break_grabs();
                *self.keyboard_layer.borrow_mut() = None;
                c.end_move();
                c.end_resize();
                self.seat.pointer_clear_focus();
                self.seat.keyboard_clear_focus();
                if let Some(s) = c.lock_keyboard_target() {
                    self.lock_surface_committed(s)
                }
            }
            LockEvent::SurfaceCommitted(s) => self.lock_surface_committed(s),
            // The keys back to the window that was frontmost; the pointer
            // to whatever is under it.
            LockEvent::Unlocked => {
                self.seat.keyboard_clear_focus();
                self.seat.pointer_clear_focus();
                match c.focused() {
                    Some(t) => {
                        self.seat.keyboard_enter(t.surface);
                    }
                    None => c.focus_topmost(),
                }
                self.rehover();
            }
        }
    }

    /// A lock surface drew: it takes the keyboard if no lock surface has
    /// it, and the pointer if the pointer is over it.
    fn lock_surface_committed(&self, s: Surface) {
        let c = self.c();
        if !c.is_locked() || !s.has_buffer() {
            return;
        }
        let on_lock = self.seat.keyboard_focused().is_some_and(|f| c.lock.borrow().surfaces.iter().any(|e| e.surface == f));
        if !on_lock && let Some(t) = c.lock_keyboard_target() {
            self.seat.keyboard_enter(t);
        }
        self.rehover();
    }

    /// Tell whatever is under the pointer that it is, without it moving.
    fn rehover(&self) {
        let (x, y) = self.cursor.get();
        self.move_cursor(x, y, (mono::now() / 1_000_000) as u32);
    }

    // MARK: keybinds (P9.5)

    fn key(&self, k: Keyboard, e: Press) {
        let c = self.c();
        c.activity(Some(self.seat));
        // **The desktop hears it first**: after this the focused client has
        // it, and the compositor never sees it again. **Locked: the lock
        // screen's, and nobody else's**: no keybind fires behind it.
        let locked = c.is_locked();
        if locked {
            self.break_grabs();
        }
        if !locked && self.intercept(k, e) {
            return;
        }
        // An input method holding the keyboard composes with it (U.5).
        if !locked && self.route_key_to_method(k, e) {
            return;
        }
        self.seat.keyboard_key(e.time_msec, e.code, e.pressed);
    }

    /// Answer a key ourselves, or say we did not.
    fn intercept(&self, k: Keyboard, e: Press) -> bool {
        if !e.pressed {
            return self.consumed_keys.borrow_mut().remove(&e.code);
        }
        let c = self.c();
        let syms = k.syms(e.code);
        // Ctrl-Alt-Fn, before any table: leaving for a console is not the
        // desktop's to rebind. With no session to ask, the client has it.
        if let Some(vt) = keys::vt_switch(&syms)
            && c.session.change_vt(vt)
        {
            self.consumed_keys.borrow_mut().insert(e.code);
            println!("undertow: switching to VT {vt}");
            return true;
        }
        self.reload_bindings_if_stale();
        let mods = KeyModifiers(k.modifiers()).normalized();
        // **Ebb has the keyboard while open** (P13.5): Escape puts the tide
        // back, an Ebb or island key acts; nothing reaches a window under it.
        if c.ebb.borrow().as_ref().is_some_and(|e| !e.closing()) {
            self.consumed_keys.borrow_mut().insert(e.code);
            if syms.contains(&0xff1b) {
                c.ebb_dismiss();
                return true;
            }
            let found = syms.iter().find_map(|&s| self.bindings.borrow().matching(s, mods, None).cloned());
            if let Some(a @ (KeyAction::Ebb(_) | KeyAction::Island(_) | KeyAction::IslandStep(_))) = found {
                self.perform(a)
            }
            return true;
        }
        let app = c.focused().and_then(|t| t.app_id());
        // Both symbols: the translated one (Cmd-Shift-3 is `numbersign`)
        // and the one printed on the key ("Cmd, Shift and the 3 key").
        let Some(act) = syms.iter().find_map(|&s| self.bindings.borrow().matching(s, mods, app.as_deref()).cloned()) else { return false };
        // **No chord while agents are off** (P18.13).
        if act == KeyAction::Agent && !pool_config::Agents::on(c.config_dir.as_deref()) {
            return false;
        }
        self.consumed_keys.borrow_mut().insert(e.code);
        self.perform(act);
        true
    }

    fn perform(&self, a: KeyAction) {
        let c = self.c();
        match a {
            KeyAction::NextWindow => c.cycle_window(true),
            KeyAction::PreviousWindow => c.cycle_window(false),
            KeyAction::CloseWindow => c.close_focused_window(),
            KeyAction::QuitApplication => c.quit_focused_application(),
            KeyAction::Island(n) => c.switch_island(n as i32, None),
            KeyAction::Ebb(scope) => c.toggle_ebb(scope),
            KeyAction::ShoalNew => c.new_shoal(),
            KeyAction::ShoalAdd => c.add_focused_to_shoal(None),
            KeyAction::ShoalRemove => c.remove_focused_from_shoal(),
            KeyAction::ShoalRecall(n) => c.recall_shoal_number(n.max(0) as usize),
            KeyAction::ShoalStrip => c.toggle_shoal_strip(),
            KeyAction::IslandStep(d) => c.step_island(d as i32),
            KeyAction::MoveToIsland { island, follow } => c.move_focused_window_to_island(island as i32, follow),
            KeyAction::Agent => {
                if spawn::detached(&["AquaDemo"], &BTreeMap::from([("AQUA_SCENE".to_owned(), "agent".to_owned())])) {
                    clog("keybind: Agent")
                } else {
                    clog("keybind: could not open Agent — AquaDemo not found on PATH")
                }
            }
            // Said, not swallowed: a binding whose program is not on PATH did
            // nothing at all, and nothing said so (HANDOFF §2.115).
            KeyAction::Run(words) => {
                let argv: Vec<&str> = words.iter().map(String::as_str).collect();
                if !spawn::detached(&argv, &BTreeMap::new()) {
                    clog(&format!("keybind: could not run {} — not found on PATH ({})", words.join(" "), std::env::var("PATH").unwrap_or_else(|_| "no PATH".into())));
                }
            }
        }
        self.keybinds_fired.set(self.keybinds_fired.get() + 1);
    }

    /// The table, keys.ini over the defaults, re-read when its timestamp
    /// moves, looked at no more than once a second and only on a keystroke.
    fn reload_bindings_if_stale(&self) {
        let now = mono::now();
        if self.bindings_loaded_at.get() != 0 && now.saturating_sub(self.bindings_checked.get()) < 1_000_000_000 {
            return;
        }
        self.bindings_checked.set(now);
        let c = self.c();
        let dir = c.config_dir.clone().or_else(|| pool_config::config_dir().ok()).unwrap_or_else(|| "/tmp".into());
        let mtime = std::fs::metadata(format!("{dir}/keys.ini")).and_then(|m| m.modified()).ok().and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok()).map_or(0, |d| d.as_secs() as i64);
        if self.bindings_loaded_at.get() != 0 && mtime == self.bindings_loaded_at.get() {
            return;
        }
        self.bindings_loaded_at.set(if mtime == 0 { -1 } else { mtime });
        let mut config = Config::new();
        for (spec, action) in pool_config::DesktopKeys::defaults() {
            config.set("keys", &spec, &action);
        }
        if let Ok(disk) = pool_config::load("keys", c.config_dir.as_deref()) {
            // Row by row: a file binding one key keeps the other defaults.
            for (spec, action) in disk.pairs("keys") {
                config.set("keys", spec, action);
            }
            for (app, specs) in disk.pairs("passthrough") {
                config.set("passthrough", app, specs);
            }
        }
        *self.bindings.borrow_mut() = keys::table(&config, &wlr::keysym_from_name);
    }

    // MARK: drawing the cursor

    /// Draw the cursor, after the scene, so it is over everything; a drag's
    /// icon under it, or a drag is invisible.
    pub fn render_cursor<W: World>(&self, pass: &mut RenderPass, scene: &SurfaceScene<W>) {
        let (x, y) = self.cursor.get();
        if let Some(s) = self.drag_icon.get().and_then(|i| i.surface())
            && let Some(tex) = s.texture()
        {
            let r = scene.project(Rect::new(x as i32, y as i32, s.width(), s.height()));
            pass.add_texture(&TextureDraw::new(tex, (r.x, r.y, r.width, r.height)));
        }
        if !self.cursor_visible.get() {
            return;
        }
        let (cx, cy) = (x.floor() as i32, y.floor() as i32);
        let image = self.cursor_image.borrow().clone();
        match image {
            CursorImage::Hidden => {}
            CursorImage::Client => {
                let Some(cs) = self.cursor_surface.get() else { return };
                // Its clock too: an animated cursor draws on frame callbacks.
                cs.frame_done_tree();
                let Some(tex) = cs.texture() else { return };
                let (hx, hy) = self.cursor_hot.get();
                let r = scene.project(Rect::new(cx - hx, cy - hy, cs.width(), cs.height()));
                pass.add_texture(&TextureDraw::new(tex, (r.x, r.y, r.width, r.height)));
            }
            CursorImage::Shape(name) => {
                let c = self.c();
                let mut runner = c.runner.borrow_mut();
                let Some(runner) = runner.as_mut() else { return };
                let theme = c.theme.borrow();
                let mut images = self.cursor_images.borrow_mut();
                let Some(img) = images.image(&name, scene.scale, c.session.renderer(), runner, &theme) else { return };
                let size = theme.tokens.cursor_size.ceil() as i32;
                let r = scene.project(Rect::new(cx - img.hot_x.round() as i32, cy - img.hot_y.round() as i32, size, size));
                pass.add_texture(&TextureDraw::new(img.texture, (r.x, r.y, r.width, r.height)));
            }
        }
    }
}

fn hit_layer<'a>(layers: impl DoubleEndedIterator<Item = &'a Rc<Layer>>, x: f64, y: f64) -> Option<PointerTarget> {
    for l in layers.rev() {
        let r = l.rect.get();
        let (lx, ly) = (x - r.x as f64, y - r.y as f64);
        if l.surface.surface_at(lx, ly).is_some() {
            return Some(PointerTarget::Layer(l.clone(), lx, ly));
        }
    }
    None
}

impl Drop for Seat {
    fn drop(&mut self) {
        if let Some(r) = &self.text_input {
            r.clear()
        }
        if let Some(pc) = &self.pointer_constraints {
            pc.listener.borrow_mut().take();
            pc.entries.borrow_mut().clear();
        }
        self.listeners.borrow_mut().clear();
        self.cursor_surface_listeners.borrow_mut().clear();
        self.drag_icon_listener.borrow_mut().take();
        self.device_listeners.borrow_mut().clear();
        self.keyboard_watch.borrow_mut().take();
        self.stand_in.borrow_mut().take();
        self.cursor_images.borrow_mut().release();
    }
}

/// What draws an output: the scene, then the seat's cursor over it.
pub struct Desktop<W: World> {
    pub scene: SurfaceScene<W>,
    pub seat: Option<Rc<Seat>>,
}

impl<W: World> crate::backend::Painter for Desktop<W> {
    fn render(&mut self, pass: &mut RenderPass, out: wlr::Output, background: (f32, f32, f32, f32)) {
        self.scene.render(pass, out, background);
        if let Some(s) = &self.seat {
            s.render_cursor(pass, &self.scene)
        }
    }
    fn mark_presented(&mut self, out: wlr::Output) {
        self.scene.mark_presented(out)
    }
    fn latch_now(&mut self, now: u64) {
        self.scene.latch_now(now)
    }
    fn dirty(&self) -> Rc<Cell<bool>> {
        self.scene.dirty()
    }
}
