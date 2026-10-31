//! The connection (Display.swift): the registry and the globals the toolkit
//! binds, the outputs' scales, the seat's pointer and keyboard routed to the
//! surface each event names (a window, a popup, a layer surface), key
//! repeat, and the run loop.
//!
//! Single-threaded, as the protocol's dispatch is: state is in Cells, and
//! no borrow is held across a call that may dispatch or reach a delegate.

use crate::backing::{Kind, Role};
use crate::clipboard::Clipboard;
use crate::keyboard::{KeyEvent, KeyboardState};
use abyss_sys::proc::{poll, poll_fd};
use abyss_sys::wlc::{self, wl_keyboard, wl_output, wl_pointer, wl_registry, wl_registry_bind::bind, wl_seat, xdg_wm_base, Connection, Obj};
use std::cell::{Cell, RefCell};
use std::rc::{Rc, Weak};
use std::time::Instant;

/// The newest version of each of our own protocols this client handles: its
/// bind cap (HANDOFF §2.117), held to the XML's `version` by a test.
pub const OUR_VERSIONS: [(&str, u32); 3] = [("abyss_menu_manager_v1", 1), ("abyss_window_manager_v1", 2), ("abyss_menubar_v1", 6)];

fn our_version(name: &str) -> u32 {
    OUR_VERSIONS.iter().find(|(n, _)| *n == name).map_or(1, |(_, v)| *v)
}

const SEAT_POINTER: u32 = 1;
const SEAT_KEYBOARD: u32 = 2;

/// A bound wl_output: its scale is staged until `done`.
struct OutputInfo {
    name: u32,
    proxy: Obj,
    scale: i32,
    pending_scale: i32,
}

/// The globals, bound as they are advertised.
#[derive(Default)]
pub struct Globals {
    pub compositor: Option<Obj>,
    pub shm: Option<Obj>,
    pub seat: Option<Obj>,
    pub wm_base: Option<Obj>,
    pub layer_shell: Option<Obj>,
    pub activation: Option<Obj>,
    pub screencopy: Option<(Obj, u32)>,
    pub session_lock_manager: Option<Obj>,
    pub idle_notifier: Option<Obj>,
    pub data_device_manager: Option<Obj>,
    /// Bound with its listener by whoever wants it (the Dock), by name.
    pub foreign_toplevel_manager: Option<(u32, u32)>,
    /// How a window says where its menus are published (P10.3).
    pub menu_manager: Option<Obj>,
    /// Window operations xdg-shell lacks (P11.6), and its version.
    pub window_manager: Option<(Obj, u32)>,
    /// Offered only on undertow's privileged socket (by name).
    pub menubar: Option<(u32, u32)>,
}

/// An extra descriptor the run loop polls, and what runs when it's ready.
type FdHandler = Rc<dyn Fn()>;

/// Told of a display that appears (its index) and one that goes (its
/// proxy): a lock must cover every display, one plugged in while locked too.
pub(crate) struct OutputHooks {
    pub(crate) added: Rc<dyn Fn(usize)>,
    pub(crate) removed: Rc<dyn Fn(Obj)>,
}

struct Repeat {
    evdev: u32,
    event: KeyEvent,
    next: u64,
}

pub struct Display {
    pub(crate) conn: Connection,
    pub(crate) registry: Obj,
    me: Weak<Display>,
    pub(crate) globals: RefCell<Globals>,
    outputs: RefCell<Vec<OutputInfo>>,
    pointer: Cell<Option<Obj>>,
    keyboard: Cell<Option<Obj>>,
    keyboard_state: RefCell<KeyboardState>,
    /// Every surface painted here, by its wl_surface, oldest first.
    surfaces: RefCell<Vec<(Obj, Weak<dyn Role>)>>,
    /// The surfaces the pointer and the keyboard last entered: **only the
    /// surface says where an event belongs**, since one process may own
    /// windows, popups and a layer surface at once.
    pointer_on: Cell<Option<Obj>>,
    keyboard_on: Cell<Option<Obj>>,
    /// The most recent pointer serial: a move, a resize, a popup grab and a
    /// drag each want specifically one of these, so a keystroke cannot
    /// start them.
    last_pointer_serial: Cell<u32>,
    /// The most recent serial of any input: what the clipboard quotes.
    last_input_serial: Cell<u32>,
    repeat: RefCell<Option<Repeat>>,
    extra_fds: RefCell<Vec<(i32, FdHandler)>>,
    pub(crate) output_hooks: RefCell<Option<OutputHooks>>,
    clipboard: RefCell<Option<Rc<Clipboard>>>,
    running: Cell<bool>,
    epoch: Instant,
}

impl Display {
    /// Connect to `WAYLAND_DISPLAY`, bind the globals, and hear the seat;
    /// None without a compositor, shm and xdg_wm_base.
    pub fn connect() -> Option<Rc<Display>> {
        let conn = Connection::connect(None)?;
        let registry = conn.registry()?;
        let d = Rc::new_cyclic(|me| Display {
            conn,
            registry,
            me: me.clone(),
            globals: RefCell::default(),
            outputs: RefCell::default(),
            pointer: Cell::new(None),
            keyboard: Cell::new(None),
            keyboard_state: RefCell::default(),
            surfaces: RefCell::default(),
            pointer_on: Cell::new(None),
            keyboard_on: Cell::new(None),
            last_pointer_serial: Cell::new(0),
            last_input_serial: Cell::new(0),
            repeat: RefCell::new(None),
            extra_fds: RefCell::default(),
            output_hooks: RefCell::new(None),
            clipboard: RefCell::new(None),
            running: Cell::new(true),
            epoch: Instant::now(),
        });
        let me = Rc::downgrade(&d);
        wl_registry::listen(registry, move |e| {
            let Some(d) = me.upgrade() else { return };
            match e {
                wl_registry::Event::Global { name, interface, version } => d.global(name, &interface, version),
                wl_registry::Event::GlobalRemove { name } => d.global_remove(name),
            }
        });
        // Globals, then what binding them brought (the seat's capabilities).
        d.conn.roundtrip();
        d.conn.roundtrip();
        let g = d.globals.borrow();
        if g.compositor.is_none() || g.shm.is_none() || g.wm_base.is_none() {
            return None;
        }
        // Without a data device there is no clipboard, and an application
        // goes without rather than refuse to start.
        let clip = g.data_device_manager.zip(g.seat);
        drop(g);
        if let Some((m, s)) = clip {
            *d.clipboard.borrow_mut() = Clipboard::new(&d, m, s)
        }
        Some(d)
    }

    /// The clipboard, when the compositor has a data device and a seat.
    pub fn clipboard(&self) -> Option<Rc<Clipboard>> {
        self.clipboard.borrow().clone()
    }

    pub fn globals(&self) -> std::cell::Ref<'_, Globals> {
        self.globals.borrow()
    }

    fn global(&self, name: u32, interface: &str, version: u32) {
        let mut g = self.globals.borrow_mut();
        let r = self.registry;
        match interface {
            "wl_compositor" => g.compositor = bind(r, name, wlc::wl_compositor::interface(), version.min(4)),
            "wl_shm" => g.shm = bind(r, name, wlc::wl_shm::interface(), 1),
            // v3 is where drag actions live (P9.3).
            "wl_data_device_manager" => g.data_device_manager = bind(r, name, wlc::wl_data_device_manager::interface(), version.min(3)),
            "wl_seat" => {
                let Some(s) = bind(r, name, wl_seat::interface(), version.min(5)) else { return };
                g.seat = Some(s);
                let me = self.me.clone();
                wl_seat::listen(s, move |e| {
                    if let (Some(d), wl_seat::Event::Capabilities { capabilities }) = (me.upgrade(), e) {
                        d.seat_capabilities(s, capabilities)
                    }
                });
            }
            // v6 (T.3): suspended, wm_capabilities and configure_bounds.
            "xdg_wm_base" => {
                let Some(b) = bind(r, name, xdg_wm_base::interface(), version.min(6)) else { return };
                g.wm_base = Some(b);
                xdg_wm_base::listen(b, move |e| {
                    let xdg_wm_base::Event::Ping { serial } = e;
                    xdg_wm_base::pong(b, serial)
                });
            }
            "zwlr_layer_shell_v1" => g.layer_shell = bind(r, name, wlc::zwlr_layer_shell_v1::interface(), version.min(4)),
            "zwlr_foreign_toplevel_manager_v1" => g.foreign_toplevel_manager = Some((name, version.min(3))),
            "abyss_menu_manager_v1" => g.menu_manager = bind(r, name, wlc::abyss_menu_manager_v1::interface(), our_version(interface)),
            "abyss_window_manager_v1" => {
                let v = version.min(our_version(interface));
                g.window_manager = bind(r, name, wlc::abyss_window_manager_v1::interface(), v).map(|o| (o, v));
            }
            "abyss_menubar_v1" => g.menubar = Some((name, version.min(our_version(interface)))),
            "xdg_activation_v1" => g.activation = bind(r, name, wlc::xdg_activation_v1::interface(), 1),
            // v1's notifications honour idle inhibitors (P16.3).
            "ext_idle_notifier_v1" => g.idle_notifier = bind(r, name, wlc::ext_idle_notifier_v1::interface(), 1),
            "ext_session_lock_manager_v1" => g.session_lock_manager = bind(r, name, wlc::ext_session_lock_manager_v1::interface(), 1),
            "zwlr_screencopy_manager_v1" => {
                let v = version.min(3);
                g.screencopy = bind(r, name, wlc::zwlr_screencopy_manager_v1::interface(), v).map(|o| (o, v));
            }
            "wl_output" => {
                drop(g);
                // v2: `scale`, and `done` batching.
                let Some(o) = bind(r, name, wl_output::interface(), version.min(2)) else { return };
                self.outputs.borrow_mut().push(OutputInfo { name, proxy: o, scale: 1, pending_scale: 1 });
                let me = self.me.clone();
                wl_output::listen(o, move |e| {
                    let Some(d) = me.upgrade() else { return };
                    match e {
                        wl_output::Event::Scale { factor } => {
                            for out in d.outputs.borrow_mut().iter_mut().filter(|x| x.proxy == o) {
                                out.pending_scale = factor.max(1)
                            }
                        }
                        wl_output::Event::Done {} => d.output_done(o),
                        _ => {}
                    }
                });
                let added = self.output_hooks.borrow().as_ref().map(|h| h.added.clone());
                if let Some(f) = added {
                    f(self.outputs.borrow().len() - 1)
                }
            }
            _ => {}
        }
    }

    fn global_remove(&self, name: u32) {
        let removed = {
            let mut outs = self.outputs.borrow_mut();
            let i = outs.iter().position(|o| o.name == name);
            i.map(|i| outs.remove(i))
        };
        if let Some(o) = &removed {
            let hook = self.output_hooks.borrow().as_ref().map(|h| h.removed.clone());
            if let Some(f) = hook {
                f(o.proxy)
            }
        }
        if removed.is_some() {
            self.rescale_windows()
        }
    }

    fn output_done(&self, o: Obj) {
        let changed = {
            let mut outs = self.outputs.borrow_mut();
            let mut changed = false;
            for out in outs.iter_mut().filter(|x| x.proxy == o && x.scale != x.pending_scale) {
                out.scale = out.pending_scale;
                changed = true;
            }
            changed
        };
        if changed {
            self.rescale_windows()
        }
    }

    fn rescale_windows(&self) {
        for r in self.live_surfaces() {
            r.backing().recompute_scale()
        }
    }

    /// The integer scale of a bound output, 1 if unknown.
    pub fn output_scale(&self, proxy: Obj) -> i32 {
        self.outputs.borrow().iter().find(|o| o.proxy == proxy).map_or(1, |o| o.scale)
    }

    pub fn output_count(&self) -> usize {
        self.outputs.borrow().len()
    }

    /// A bound output, in the order the registry advertised them.
    pub fn output(&self, index: usize) -> Option<Obj> {
        self.outputs.borrow().get(index).map(|o| o.proxy)
    }

    pub fn last_pointer_serial(&self) -> u32 {
        self.last_pointer_serial.get()
    }
    pub fn last_input_serial(&self) -> u32 {
        self.last_input_serial.get()
    }

    // MARK: surfaces

    pub(crate) fn register(&self, role: Weak<dyn Role>) {
        let Some(r) = role.upgrade() else { return };
        let surface = r.backing().surface;
        let mut v = self.surfaces.borrow_mut();
        v.retain(|(_, w)| w.strong_count() > 0);
        v.push((surface, role));
    }

    pub(crate) fn unregister(&self, surface: Obj) {
        self.surfaces.borrow_mut().retain(|(s, w)| *s != surface && w.strong_count() > 0);
        for slot in [&self.pointer_on, &self.keyboard_on] {
            if slot.get() == Some(surface) {
                slot.set(None)
            }
        }
    }

    fn live_surfaces(&self) -> Vec<Rc<dyn Role>> {
        self.surfaces.borrow().iter().filter_map(|(_, w)| w.upgrade()).collect()
    }

    fn surface(&self, surface: Option<Obj>) -> Option<Rc<dyn Role>> {
        let s = surface?;
        self.surfaces.borrow().iter().find(|(o, _)| *o == s).and_then(|(_, w)| w.upgrade())
    }

    /// Where input goes before any `enter` names a surface: the first
    /// window, else the first layer surface.
    fn primary(&self) -> Option<Rc<dyn Role>> {
        let all = self.live_surfaces();
        let first = |k| all.iter().find(|r| r.kind() == k).cloned();
        first(Kind::Window).or_else(|| first(Kind::Layer))
    }

    /// The surface an activation claims to come from: the one with the
    /// keyboard, else the primary.
    pub(crate) fn activation_source(&self) -> Option<Obj> {
        self.target(&self.keyboard_on).map(|r| r.backing().surface)
    }

    fn target(&self, slot: &Cell<Option<Obj>>) -> Option<Rc<dyn Role>> {
        self.surface(slot.get()).or_else(|| self.primary())
    }

    // MARK: the seat

    fn seat_capabilities(&self, seat: Obj, caps: u32) {
        if caps & SEAT_KEYBOARD != 0 && self.keyboard.get().is_none() {
            self.bind_keyboard(seat)
        }
        if caps & SEAT_POINTER != 0 && self.pointer.get().is_none() {
            let Some(p) = wl_seat::get_pointer(seat) else { return };
            self.pointer.set(Some(p));
            let me = self.me.clone();
            wl_pointer::listen(p, move |e| {
                let Some(d) = me.upgrade() else { return };
                d.pointer_event(e)
            });
        }
    }

    fn pointer_event(&self, e: wl_pointer::Event) {
        use wl_pointer::Event::*;
        match e {
            Enter { serial, surface, surface_x, surface_y } => {
                self.last_pointer_serial.set(serial);
                self.last_input_serial.set(serial);
                if self.surface(surface).is_some() {
                    self.pointer_on.set(surface)
                }
                self.route_motion(surface_x, surface_y)
            }
            Leave { surface, .. } => {
                if self.pointer_on.get() == surface {
                    self.pointer_on.set(None)
                }
                if let Some(r) = self.surface(surface) {
                    r.pointer_left()
                }
            }
            Motion { surface_x, surface_y, .. } => self.route_motion(surface_x, surface_y),
            Button { serial, button, state, .. } => {
                self.last_pointer_serial.set(serial);
                self.last_input_serial.set(serial);
                if let Some(r) = self.target(&self.pointer_on) {
                    r.pointer_button(button, state == 1)
                }
            }
            Axis { axis, value, .. } => {
                if let Some(r) = self.target(&self.pointer_on) {
                    r.pointer_axis(axis, value)
                }
            }
            _ => {}
        }
    }

    fn route_motion(&self, x: f64, y: f64) {
        if let Some(r) = self.target(&self.pointer_on) {
            r.pointer_moved(x, y)
        }
    }

    fn bind_keyboard(&self, seat: Obj) {
        let Some(k) = wl_seat::get_keyboard(seat) else { return };
        self.keyboard.set(Some(k));
        let me = self.me.clone();
        wl_keyboard::listen(k, move |e| {
            let Some(d) = me.upgrade() else { return };
            d.keyboard_event(e)
        });
    }

    fn keyboard_event(&self, e: wl_keyboard::Event) {
        use wl_keyboard::Event::*;
        match e {
            Keymap { format, fd, size } => self.keyboard_state.borrow_mut().load_keymap(fd, size, format),
            // Where typing goes, in a multi-window application. A grabbing
            // popup does not take the keyboard from its own client (HANDOFF
            // §2.12): the window under it forwards keys to its open menu.
            Enter { surface, .. } => {
                if self.surface(surface).is_some() {
                    self.keyboard_on.set(surface)
                }
            }
            Leave { surface, .. } => {
                if surface.is_some() && self.keyboard_on.get() == surface {
                    self.keyboard_on.set(None);
                    // Never repeat into a surface that lost focus.
                    *self.repeat.borrow_mut() = None;
                }
            }
            Key { serial, key, state, .. } => {
                // ⌘C is a key press: the serial a copy may quote (P9.1).
                self.last_input_serial.set(serial);
                let pressed = state == 1;
                let Some(ev) = self.keyboard_state.borrow().event(key, pressed) else { return };
                self.route_key(&ev);
                if pressed { self.start_repeat(key, ev) } else { self.stop_repeat(key) }
            }
            Modifiers { mods_depressed, mods_latched, mods_locked, group, .. } => self.keyboard_state.borrow().update_modifiers(mods_depressed, mods_latched, mods_locked, group),
            RepeatInfo { rate, delay } => {
                let mut ks = self.keyboard_state.borrow_mut();
                ks.repeat_rate = rate;
                ks.repeat_delay_ms = delay;
            }
        }
    }

    fn route_key(&self, ev: &KeyEvent) {
        if let Some(r) = self.target(&self.keyboard_on) {
            r.key_event(ev)
        }
    }

    // MARK: key repeat

    fn now_ms(&self) -> u64 {
        self.epoch.elapsed().as_millis() as u64
    }

    /// Only the latest key repeats, and only one the keymap says repeats.
    fn start_repeat(&self, evdev: u32, event: KeyEvent) {
        let ks = self.keyboard_state.borrow();
        *self.repeat.borrow_mut() = (ks.repeat_rate > 0 && ks.key_repeats(evdev)).then(|| Repeat { evdev, event, next: self.now_ms() + ks.repeat_delay_ms.max(0) as u64 });
    }

    fn stop_repeat(&self, evdev: u32) {
        let mut r = self.repeat.borrow_mut();
        if r.as_ref().is_some_and(|r| r.evdev == evdev) {
            *r = None
        }
    }

    fn repeat_timeout_ms(&self) -> Option<i32> {
        let r = self.repeat.borrow();
        let next = r.as_ref()?.next;
        Some(next.saturating_sub(self.now_ms()).min(1000) as i32)
    }

    fn fire_due_repeats(&self) {
        let rate = self.keyboard_state.borrow().repeat_rate;
        if rate <= 0 {
            return;
        }
        let interval = (1000 / rate as u64).max(1);
        loop {
            let now = self.now_ms();
            let ev = {
                let mut r = self.repeat.borrow_mut();
                let Some(rk) = r.as_mut() else { return };
                if now < rk.next {
                    return;
                }
                rk.next += interval;
                // No burst after a stall.
                if rk.next <= now {
                    rk.next = now + interval
                }
                rk.event.clone()
            };
            self.route_key(&ev)
        }
    }

    // MARK: the run loop

    /// Push queued requests now. The clipboard cannot wait for the loop: a
    /// paste blocks reading a pipe the other client writes only once it
    /// has heard the request.
    pub fn flush(&self) {
        self.conn.flush();
    }

    pub fn roundtrip(&self) {
        self.conn.roundtrip();
    }

    /// Poll `fd` with the connection; `on_readable` runs when it is. The
    /// caller owns the descriptor, and removes it before closing it.
    pub fn add_fd(&self, fd: i32, on_readable: impl Fn() + 'static) {
        self.extra_fds.borrow_mut().push((fd, Rc::new(on_readable)))
    }

    pub fn remove_fd(&self, fd: i32) {
        self.extra_fds.borrow_mut().retain(|(f, _)| *f != fd)
    }

    pub fn stop(&self) {
        self.running.set(false)
    }

    /// Dispatch until stopped or the connection fails: the Wayland fd and
    /// every extra one, waking for a key repeat's deadline too.
    pub fn run(&self) {
        let wlfd = self.conn.fd();
        while self.running.get() {
            while self.conn.prepare_read() != 0 {
                if self.conn.dispatch_pending() < 0 {
                    self.running.set(false);
                    break;
                }
            }
            if !self.running.get() {
                self.conn.cancel_read();
                break;
            }
            self.conn.flush();
            // **The set is snapshotted where it is polled**: a handler run by
            // the dispatch below may register a descriptor (Display.swift).
            let polled: Vec<(i32, FdHandler)> = self.extra_fds.borrow().clone();
            let mut pfds = vec![poll_fd(wlfd, libc::POLLIN)];
            pfds.extend(polled.iter().map(|(fd, _)| poll_fd(*fd, libc::POLLIN)));
            let n = poll(&mut pfds, self.repeat_timeout_ms().unwrap_or(-1)).unwrap_or(0);
            // Resolve the armed read before any handler issues requests.
            if n > 0 && pfds[0].revents & libc::POLLIN != 0 {
                if self.conn.read_events() < 0 || self.conn.dispatch_pending() < 0 {
                    break;
                }
            } else {
                self.conn.cancel_read()
            }
            if n > 0 {
                for (i, (fd, handler)) in polled.iter().enumerate() {
                    let revents = pfds[i + 1].revents;
                    // One removed since the snapshot must not run: it would
                    // read a descriptor already closed.
                    if revents == 0 || !self.extra_fds.borrow().iter().any(|(f, _)| f == fd) {
                        continue;
                    }
                    if revents & libc::POLLNVAL != 0 {
                        self.remove_fd(*fd);
                        continue;
                    }
                    if revents & (libc::POLLIN | libc::POLLHUP) != 0 {
                        handler()
                    }
                }
            }
            self.fire_due_repeats();
        }
    }

    /// Every surface draws again: for a change to how everything looks (the
    /// theme, P14.2).
    pub fn set_everything_needs_display(&self) {
        for r in self.live_surfaces() {
            r.backing().set_needs_display()
        }
    }
}

impl Drop for Display {
    /// What holds proxies goes before the connection: a proxy destroyed
    /// after `wl_display_disconnect` is a use of freed memory (the struct's
    /// fields drop in order, and `conn` is first).
    fn drop(&mut self) {
        self.clipboard.borrow_mut().take();
        self.output_hooks.borrow_mut().take();
    }
}

#[cfg(test)]
mod tests {
    use super::OUR_VERSIONS;

    /// Each of our protocols' bind cap is its XML's `version`: bumping the
    /// XML without this left the client on the old version, silently, twice
    /// (P13.4, P18.13b).
    #[test]
    fn each_of_our_protocols_is_bound_at_the_version_its_xml_says() {
        let root = concat!(env!("CARGO_MANIFEST_DIR"), "/../../protocols");
        for (name, ours) in OUR_VERSIONS {
            let file = if name == "abyss_menubar_v1" { "abyss-menu-v1.xml" } else { &format!("{}.xml", name.trim_end_matches("_manager_v1").replace('_', "-") + "-v1") };
            let xml = std::fs::read_to_string(format!("{root}/{file}")).unwrap_or_else(|e| panic!("{file}: {e}"));
            let at = xml.find(&format!("<interface name=\"{name}\"")).unwrap_or_else(|| panic!("{name} is not in {file}"));
            let rest = &xml[at..];
            let v = rest.split("version=\"").nth(1).and_then(|s| s.split('"').next()).and_then(|s| s.parse::<u32>().ok()).unwrap();
            assert_eq!(ours, v, "{name}: bound at {ours}, but {file} is at {v}");
        }
    }
}
