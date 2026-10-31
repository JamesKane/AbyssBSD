//! The displays sleep when nobody is using them, unless something on screen
//! asks them not to (DisplaySleep.swift, BACKLOG U.9). The clock is R4a's
//! `IdleClock`; this is its compositor half.
//!
//! After energy.ini's `display_sleep_minutes` without input every output is
//! turned off, and the first key or motion turns them back on. While off,
//! clients get the slow clock a minimized window gets. **idle-inhibit-v1**
//! is how a video player says "not now": while a surface holding an
//! inhibitor is visible, the clock does not run. **ext-idle-notify-v1**
//! carries the same activity and inhibition to clients that want to know,
//! so there is one idea of idle on the desktop.

use crate::compositor::Compositor;
use crate::idle::{IdleChange, IdleClock};
use abyss_sys::mono;
use abyss_sys::wlr::{globals, IdleNotifier, Listener, Seat, Surface};
use pool_config::EnergyPrefs;
use std::cell::{Cell, RefCell};
use std::rc::Rc;

pub type SleepHook = Box<dyn Fn(bool)>;
/// The surfaces holding an inhibitor, each with its destroy listener.
type Inhibitors = Rc<RefCell<Vec<(Surface, Option<Listener>)>>>;

pub struct DisplaySleep {
    notifier: Option<IdleNotifier>,
    inhibitors: Inhibitors,
    _listeners: Vec<Listener>,
    pub clock: RefCell<IdleClock>,
    override_seconds: Option<f64>,
    prefs_checked_at: Cell<u64>,
    inhibited_now: Cell<bool>,
    /// true when the displays should go off, false when on.
    on_change: RefCell<Option<SleepHook>>,
    pub sleeps: Cell<u64>,
    pub wakes: Cell<u64>,
}

impl DisplaySleep {
    pub fn asleep(&self) -> bool {
        self.clock.borrow().asleep
    }
    pub fn inhibited(&self) -> bool {
        self.inhibited_now.get()
    }
    pub fn on_change(&self, f: impl Fn(bool) + 'static) {
        *self.on_change.borrow_mut() = Some(Box::new(f));
    }
    fn changed(&self, asleep: bool) {
        if let Some(f) = &*self.on_change.borrow() {
            f(asleep)
        }
    }
}

impl Compositor {
    /// Display sleep for this session; `--display-sleep SECONDS` overrides
    /// energy.ini for a test.
    pub fn start_display_sleep(&self, override_seconds: Option<f64>) {
        let d = self.session.display();
        let now = mono::now();
        let prefs = EnergyPrefs::load(self.config_dir.as_deref());
        let inhibitors: Inhibitors = Rc::default();
        let mut ls = vec![];
        if let Some(im) = globals::idle_inhibit(d) {
            let list = Rc::downgrade(&inhibitors);
            ls.extend(im.on_new_inhibitor(move |i| {
                let (Some(list), Some(s)) = (list.upgrade(), i.surface()) else { return };
                let gone = Rc::downgrade(&list);
                // Dropped with the entry, from inside its own callback.
                let l = i.on_destroy(move || {
                    if let Some(list) = gone.upgrade() {
                        let mut v = list.borrow_mut();
                        if let Some(p) = v.iter().position(|(o, _)| *o == s) {
                            let e = v.remove(p);
                            drop(v);
                            drop(e);
                        }
                    }
                });
                list.borrow_mut().push((s, l));
            }));
        }
        *self.display_sleep.borrow_mut() = Some(DisplaySleep {
            notifier: globals::idle_notifier(d),
            inhibitors,
            _listeners: ls,
            clock: RefCell::new(IdleClock::new(IdleClock::timeout_ns_for(&prefs, override_seconds), now)),
            override_seconds,
            prefs_checked_at: Cell::new(now),
            inhibited_now: Cell::new(false),
            on_change: RefCell::default(),
            sleeps: Cell::new(0),
            wakes: Cell::new(0),
        });
    }

    /// A key, a motion, a button, a wheel: from the seat, which passes its
    /// wlr_seat for ext-idle-notify.
    pub fn activity(&self, seat: Option<Seat>) {
        let ds = self.display_sleep.borrow();
        let Some(ds) = ds.as_ref() else { return };
        if let (Some(n), Some(s)) = (ds.notifier, seat) {
            n.notify_activity(s)
        }
        let woke = ds.clock.borrow_mut().activity(mono::now()) == Some(IdleChange::Wake);
        if woke {
            ds.wakes.set(ds.wakes.get() + 1);
            ds.changed(false);
        }
    }

    /// Once per loop iteration: is anything on screen holding the displays
    /// awake, has the timeout changed, and is it time to sleep.
    pub fn display_sleep_tick(&self) {
        let ds = self.display_sleep.borrow();
        let Some(ds) = ds.as_ref() else { return };
        let now = mono::now();
        if ds.override_seconds.is_none() && now.saturating_sub(ds.prefs_checked_at.get()) >= 1_000_000_000 {
            ds.prefs_checked_at.set(now);
            let prefs = EnergyPrefs::load(self.config_dir.as_deref());
            ds.clock.borrow_mut().timeout_ns = IdleClock::timeout_ns_for(&prefs, None);
        }
        let held: Vec<Surface> = ds.inhibitors.borrow().iter().map(|(s, _)| *s).collect();
        let inhibited = held.into_iter().any(|s| self.inhibitor_visible(s));
        if inhibited != ds.inhibited_now.get() {
            ds.inhibited_now.set(inhibited);
            if let Some(n) = ds.notifier {
                n.set_inhibited(inhibited)
            }
        }
        let slept = ds.clock.borrow_mut().tick(now, inhibited) == Some(IdleChange::Sleep);
        if slept {
            ds.sleeps.set(ds.sleeps.get() + 1);
            ds.changed(true);
        }
    }

    /// An inhibitor counts while its surface can be seen: part of a mapped,
    /// unminimized window, or of a mapped layer surface.
    fn inhibitor_visible(&self, s: Surface) -> bool {
        let root = s.root();
        self.toplevels.borrow().iter().any(|t| t.mapped.get() && !t.minimized.get() && t.surface == root) || self.mapped_layers().iter().any(|l| l.surface == root)
    }

    pub fn displays_asleep(&self) -> bool {
        self.display_sleep.borrow().as_ref().is_some_and(DisplaySleep::asleep)
    }

    // MARK: which outputs a surface is on (SurfaceOutputs.swift, U.10)

    /// Tell every visible surface which outputs it is on (wl_surface.enter
    /// and leave, which undertow never sent: HANDOFF §2.71), and the scale
    /// to draw at: the largest of its displays'. Both wlroots calls do
    /// nothing when nothing changed, so this runs every loop iteration, off
    /// the present path. Subsurfaces are told what their root is.
    pub fn update_surface_outputs(&self) {
        let outs: Vec<(crate::geometry::Rect, abyss_sys::wlr::Output, f64)> = self.layout.borrow().displays.iter().filter_map(|d| self.session.output_named(&d.name).map(|o| (d.rect(), o, d.scale))).collect();
        if outs.is_empty() {
            return;
        }
        let tell = |root: Surface, r: Option<crate::geometry::Rect>| {
            let mut best = 0.0f64;
            for (d, o, scale) in &outs {
                let on = r.is_some_and(|r| (r.x + r.width).min(d.x + d.width) > r.x.max(d.x) && (r.y + r.height).min(d.y + d.height) > r.y.max(d.y));
                if on {
                    best = best.max(*scale)
                }
                root.for_each_surface(|s, _, _| if on { s.send_enter(*o) } else { s.send_leave(*o) });
            }
            // On none (minimized): the last scale it was told stands. Both
            // ways a client can hear it: fractional-scale-v1, and wl_surface
            // v6's integer preferred_buffer_scale.
            if best > 0.0 {
                root.for_each_surface(|s, _, _| {
                    s.notify_fractional_scale(best);
                    s.set_preferred_buffer_scale(best.ceil() as i32);
                });
            }
        };
        let ts = self.toplevels.borrow().clone();
        for t in ts.iter().filter(|t| t.mapped.get()) {
            // Minimized: on no output, being shown nowhere.
            tell(t.surface, (!t.minimized.get()).then(|| t.rect()));
        }
        for l in self.mapped_layers() {
            tell(l.surface, Some(l.rect.get()));
        }
        for (p, (x, y)) in self.mapped_popups() {
            tell(p.surface, Some(crate::geometry::Rect::new(x, y, p.surface.width(), p.surface.height())));
        }
    }
}
