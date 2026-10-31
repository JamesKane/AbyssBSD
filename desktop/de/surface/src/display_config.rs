//! wlr-output-management-v1, the client side (DisplayConfigurator.swift,
//! P14.7b): what every display is (name, modes, current mode, position,
//! scale), and asking the compositor to test or apply a new arrangement.
//! The Displays pane speaks it, and `abyss-displays`, which is how the
//! protocol is tested on both platforms.
//!
//! The manager announces a head per output and each head its modes;
//! `done(serial)` closes a batch. A configuration is made against a serial
//! (outputs that changed meanwhile cancel it rather than apply something
//! stale) and is answered succeeded, failed or cancelled.
//!
//! **Its own connection.** A request pumps a bounded loop until its answer,
//! so a CLI is a straight-line program and a silent compositor a timeout.
//! On an application's own connection that pump would dispatch the
//! application's other events from inside its handlers. An application
//! polls `fd()` and calls `dispatch()`, and hears through `on_change` when
//! someone else (wlr-randr, kanshi) rearranged the displays.

use crate::screencopy::pump;
use abyss_sys::proc::{poll, poll_fd};
use abyss_sys::wlc::{wl_registry, wl_registry_bind::bind, zwlr_output_configuration_head_v1 as chead, zwlr_output_configuration_v1 as config, zwlr_output_head_v1 as head, zwlr_output_manager_v1 as manager, zwlr_output_mode_v1 as mode, Connection, Obj};
use std::cell::{Cell, RefCell};
use std::rc::Rc;
use std::time::Duration;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
pub struct Mode {
    pub width: i32,
    pub height: i32,
    /// mHz, as the protocol gives it; 0 when the output did not say.
    pub refresh_mhz: i32,
    pub preferred: bool,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Head {
    pub name: String,
    pub description: String,
    pub enabled: bool,
    pub modes: Vec<Mode>,
    pub current: Option<Mode>,
    pub x: i32,
    pub y: i32,
    pub scale: f64,
}

impl Head {
    /// Its size in the layout: its mode over its scale.
    pub fn layout_size(&self) -> (i32, i32) {
        let c = self.current.unwrap_or_default();
        ((c.width as f64 / self.scale).round() as i32, (c.height as f64 / self.scale).round() as i32)
    }
}

/// What to ask for, for one display.
#[derive(Clone, Debug, PartialEq)]
pub struct Setting {
    pub name: String,
    pub width: i32,
    pub height: i32,
    /// 0: any refresh at that size.
    pub refresh_mhz: i32,
    pub x: i32,
    pub y: i32,
    pub scale: f64,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Outcome {
    Succeeded,
    Failed,
    Cancelled,
    TimedOut,
}

struct HeadState {
    proxy: Obj,
    name: String,
    description: String,
    enabled: bool,
    modes: Vec<Obj>,
    current: Option<Obj>,
    x: i32,
    y: i32,
    scale: f64,
}

#[derive(Default)]
struct State {
    manager: Cell<Option<(Obj, u32)>>,
    heads: RefCell<Vec<HeadState>>,
    modes: RefCell<Vec<(Obj, Mode)>>,
    serial: Cell<u32>,
    batches: Cell<u32>,
    outcome: Cell<Option<Outcome>>,
    on_change: RefCell<Option<Rc<dyn Fn()>>>,
}

impl State {
    fn head(&self, h: Obj, f: impl FnOnce(&mut HeadState)) {
        if let Some(s) = self.heads.borrow_mut().iter_mut().find(|s| s.proxy == h) {
            f(s)
        }
    }
    fn mode(&self, m: Obj, f: impl FnOnce(&mut Mode)) {
        if let Some((_, s)) = self.modes.borrow_mut().iter_mut().find(|(o, _)| *o == m) {
            f(s)
        }
    }
    /// Release a head or mode: v3's destructor, else only the proxy.
    fn release(&self, o: Obj, release: fn(Obj), destroy: fn(Obj)) {
        if self.manager.get().is_some_and(|(_, v)| v >= 3) { release(o) } else { destroy(o) }
    }
}

pub struct DisplayConfigurator {
    conn: Connection,
    registry: Obj,
    state: Rc<State>,
}

impl DisplayConfigurator {
    /// Connect (to `$WAYLAND_DISPLAY`), bind the manager, and wait for the
    /// first complete description. None without a compositor, without the
    /// protocol, or if it never finishes saying.
    pub fn new(timeout: Duration) -> Option<DisplayConfigurator> {
        let conn = Connection::connect(None)?;
        let registry = conn.registry()?;
        let state = Rc::new(State::default());
        let st = Rc::downgrade(&state);
        wl_registry::listen(registry, move |e| {
            let (Some(s), wl_registry::Event::Global { name, interface, version }) = (st.upgrade(), e) else { return };
            if interface != "zwlr_output_manager_v1" || s.manager.get().is_some() {
                return;
            }
            let v = version.min(4);
            let Some(m) = bind(registry, name, manager::interface(), v) else { return };
            s.manager.set(Some((m, v)));
            let st = Rc::downgrade(&s);
            manager::listen(m, move |e| {
                let Some(s) = st.upgrade() else { return };
                match e {
                    manager::Event::Head { head: Some(h) } => DisplayConfigurator::add_head(&s, h),
                    manager::Event::Done { serial } => {
                        s.serial.set(serial);
                        s.batches.set(s.batches.get() + 1);
                        let f = s.on_change.borrow().clone();
                        if let Some(f) = f {
                            f()
                        }
                    }
                    _ => {}
                }
            });
        });
        let c = DisplayConfigurator { conn, registry, state };
        c.conn.roundtrip();
        if c.state.manager.get().is_none() || !pump(&c.conn, || c.state.batches.get() > 0, timeout) {
            return None;
        }
        Some(c)
    }

    fn add_head(s: &Rc<State>, h: Obj) {
        s.heads.borrow_mut().push(HeadState { proxy: h, name: String::new(), description: String::new(), enabled: false, modes: vec![], current: None, x: 0, y: 0, scale: 1.0 });
        let st = Rc::downgrade(s);
        head::listen(h, move |e| {
            let Some(s) = st.upgrade() else { return };
            match e {
                head::Event::Name { name } => s.head(h, |x| x.name = name),
                head::Event::Description { description } => s.head(h, |x| x.description = description),
                head::Event::Mode { mode: Some(m) } => {
                    s.head(h, |x| x.modes.push(m));
                    s.modes.borrow_mut().push((m, Mode::default()));
                    let st = Rc::downgrade(&s);
                    mode::listen(m, move |e| {
                        let Some(s) = st.upgrade() else { return };
                        match e {
                            mode::Event::Size { width, height } => s.mode(m, |x| (x.width, x.height) = (width, height)),
                            mode::Event::Refresh { refresh } => s.mode(m, |x| x.refresh_mhz = refresh),
                            mode::Event::Preferred {} => s.mode(m, |x| x.preferred = true),
                            mode::Event::Finished {} => {
                                s.modes.borrow_mut().retain(|(o, _)| *o != m);
                                for x in s.heads.borrow_mut().iter_mut() {
                                    x.modes.retain(|o| *o != m);
                                    if x.current == Some(m) {
                                        x.current = None
                                    }
                                }
                                s.release(m, mode::release, mode::destroy)
                            }
                        }
                    });
                }
                head::Event::Enabled { enabled } => s.head(h, |x| x.enabled = enabled != 0),
                head::Event::CurrentMode { mode } => s.head(h, |x| x.current = mode),
                head::Event::Position { x: px, y: py } => s.head(h, |x| (x.x, x.y) = (px, py)),
                head::Event::Scale { scale } => s.head(h, |x| x.scale = scale),
                head::Event::Finished {} => {
                    s.heads.borrow_mut().retain(|x| x.proxy != h);
                    s.release(h, head::release, head::destroy)
                }
                _ => {}
            }
        });
    }

    /// Called after each complete description: an apply of ours, or anyone's.
    pub fn on_change(&self, f: impl Fn() + 'static) {
        *self.state.on_change.borrow_mut() = Some(Rc::new(f))
    }

    /// Every display, as of the last `done`.
    pub fn displays(&self) -> Vec<Head> {
        let modes = self.state.modes.borrow();
        let mode = |o: &Obj| modes.iter().find(|(m, _)| m == o).map(|(_, m)| *m);
        self.state
            .heads
            .borrow()
            .iter()
            .map(|h| Head { name: h.name.clone(), description: h.description.clone(), enabled: h.enabled, modes: h.modes.iter().filter_map(mode).collect(), current: h.current.as_ref().and_then(mode), x: h.x, y: h.y, scale: h.scale })
            .collect()
    }

    /// For an application's run loop: readable when the compositor spoke.
    pub fn fd(&self) -> i32 {
        self.conn.fd()
    }

    /// Read and dispatch what arrived, without blocking, then flush.
    pub fn dispatch(&self) {
        if self.conn.prepare_read() == 0 {
            let mut p = [poll_fd(self.conn.fd(), libc::POLLIN)];
            if poll(&mut p, 0).unwrap_or(0) > 0 { self.conn.read_events() } else { self.conn.cancel_read(); 0 };
        }
        self.conn.dispatch_pending();
        self.conn.flush();
    }

    /// Wait until the compositor describes the displays again (after an
    /// apply, it does). False on the timeout.
    pub fn await_update(&self, timeout: Duration) -> bool {
        let before = self.state.batches.get();
        pump(&self.conn, || self.state.batches.get() > before, timeout)
    }

    /// Ask for `settings` to be tested (nothing changes) or applied. Name
    /// every display: one left out is one the protocol turns off.
    pub fn request(&self, settings: &[Setting], test_only: bool, timeout: Duration) -> Outcome {
        let Some((m, _)) = self.state.manager.get() else { return Outcome::Failed };
        let Some(cfg) = manager::create_configuration(m, self.state.serial.get()) else { return Outcome::Failed };
        self.state.outcome.set(None);
        let st = Rc::downgrade(&self.state);
        config::listen(cfg, move |e| {
            if let Some(s) = st.upgrade() {
                s.outcome.set(Some(match e {
                    config::Event::Succeeded {} => Outcome::Succeeded,
                    config::Event::Failed {} => Outcome::Failed,
                    config::Event::Cancelled {} => Outcome::Cancelled,
                }))
            }
        });
        let modes = self.state.modes.borrow().clone();
        for s in settings {
            let found = self.state.heads.borrow().iter().find(|h| h.name == s.name).map(|h| (h.proxy, h.modes.clone()));
            let Some((h, hm)) = found else { continue };
            let Some(ch) = config::enable_head(cfg, h) else { continue };
            // A named mode of that size (and rate) when the output has one;
            // a custom one otherwise, which a headless output always takes.
            let named = hm.iter().find(|o| modes.iter().any(|(m, x)| m == *o && x.width == s.width && x.height == s.height && (s.refresh_mhz == 0 || x.refresh_mhz == s.refresh_mhz)));
            match named {
                Some(o) => chead::set_mode(ch, *o),
                None => chead::set_custom_mode(ch, s.width, s.height, s.refresh_mhz),
            }
            chead::set_position(ch, s.x, s.y);
            chead::set_scale(ch, s.scale);
        }
        if test_only { config::test(cfg) } else { config::apply(cfg) }
        let answered = pump(&self.conn, || self.state.outcome.get().is_some(), timeout);
        config::destroy(cfg);
        self.conn.flush();
        if answered { self.state.outcome.get().unwrap_or(Outcome::TimedOut) } else { Outcome::TimedOut }
    }
}

impl Drop for DisplayConfigurator {
    fn drop(&mut self) {
        let heads: Vec<Obj> = self.state.heads.borrow_mut().drain(..).map(|h| h.proxy).collect();
        for h in heads {
            self.state.release(h, head::release, head::destroy)
        }
        let modes: Vec<Obj> = self.state.modes.borrow_mut().drain(..).map(|(m, _)| m).collect();
        for m in modes {
            self.state.release(m, mode::release, mode::destroy)
        }
        if let Some((m, _)) = self.state.manager.take() {
            manager::stop(m);
            manager::destroy(m)
        }
        wl_registry::destroy(self.registry);
        self.conn.flush();
    }
}
