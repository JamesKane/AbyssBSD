//! Energy Saver (EnergyPane.swift, P14.8), deliberately thin:
//!
//! - **sleep delays** for the computer and the display, the person's,
//!   written to energy.ini as the slider is let go; the display's is
//!   undertow's to act on, and the page says the computer's is not yet;
//! - **powerd**: whether the processor follows the work, and how on AC and
//!   on battery, rc.conf's, so through the settings helper;
//! - **the battery**, where Vents finds one, and the sleep states the
//!   machine says it supports;
//! - **the power mode** (P14.8b), where the base has power profiles: it
//!   replaces the per-source powerd modes.

use super::settings_client::{self as client, Apply};
use super::{at, log, track, Pane, PrefsHost};
use aquadraw::canvas::Canvas;
use aquadraw::drawlist::Role;
use aquadraw::runner::Rect;
use aquadraw::text::Style;
use pool_config::EnergyPrefs;
use settings::{EnergyPlan, PowerProfile, PowerdMode, SettingsPlan};
use std::cell::{Cell, RefCell};
use std::rc::Rc;
use vents::Battery;

#[derive(Clone, Debug, Default, PartialEq)]
pub struct EnergyPaneState {
    pub prefs: EnergyPrefs,
    /// rc.conf's powerd, through the helper; None when it could not be read.
    pub powerd: Option<EnergyPlan>,
    pub battery: Option<Battery>,
    /// `S3 S4 S5`, or None with no ACPI to ask.
    pub sleep_states: Option<String>,
    /// The base's power profile; None where there is none to show.
    pub profile: Option<PowerProfile>,
    pub note: String,
    pub busy: bool,
}

impl EnergyPaneState {
    pub fn sample() -> EnergyPaneState {
        EnergyPaneState {
            prefs: EnergyPrefs { display_sleep_minutes: 10, system_sleep_minutes: 30, ..EnergyPrefs::default() },
            powerd: Some(EnergyPlan { powerd: true, on_ac: PowerdMode::Hiadaptive, on_battery: PowerdMode::Adaptive, modes_from_profile: false }),
            battery: Some(Battery { percent: Some(83), minutes_remaining: Some(214), is_charging: false }),
            sleep_states: Some("S3 S4 S5".into()),
            ..EnergyPaneState::default()
        }
    }
}

pub fn profile_words(p: PowerProfile) -> &'static str {
    match p {
        PowerProfile::PowerSaver => "Power Saver",
        PowerProfile::Balanced => "Balanced",
        PowerProfile::Performance => "Performance",
    }
}

pub fn mode_words(m: PowerdMode) -> &'static str {
    match m {
        PowerdMode::Adaptive => "Adaptive",
        PowerdMode::Hiadaptive => "Responsive",
        PowerdMode::Minimum => "Slowest",
        PowerdMode::Maximum => "Fastest",
    }
}

/// What the machine says it can do, in words.
pub fn sleep_state_words(s: Option<&str>) -> String {
    let Some(s) = s.filter(|s| !s.is_empty()) else { return "This machine reports no sleep states.".into() };
    let can: Vec<&str> = [("S3", "sleep (S3)"), ("S4", "hibernate (S4)"), ("S5", "power off (S5)")].iter().filter(|(k, _)| s.contains(k)).map(|(_, w)| *w).collect();
    if can.is_empty() { "This machine reports no sleep states it can enter.".into() } else { format!("This machine can {}.", can.join(", ")) }
}

pub fn battery_words(b: Option<&Battery>) -> String {
    let Some(b) = b else { return "No battery".into() };
    let mut s = b.label();
    if b.is_charging {
        s += ", charging"
    } else if let Some(m) = b.minutes_remaining {
        s += &format!(", {} remaining", EnergyPrefs::words(m))
    }
    s
}

/// The page as one line, for the log a test reads.
pub fn status_line(s: &EnergyPaneState) -> String {
    let powerd = s.powerd.as_ref().map_or("unknown".into(), |p| if p.powerd { format!("on ac {} battery {}", p.on_ac.as_str(), p.on_battery.as_str()) } else { "off".into() });
    format!("computer {} display {} powerd {powerd}{} battery {}", s.prefs.system_sleep_minutes, s.prefs.display_sleep_minutes, s.profile.map_or(String::new(), |p| format!(" profile {}", p.as_str())), s.battery.and_then(|b| b.percent).map_or("none".into(), |p| p.to_string()))
}

/// The slider's stops, then Never.
pub fn positions() -> usize {
    EnergyPrefs::STOPS.len() + 1
}

pub fn slider_minutes(t: f64) -> i64 {
    let i = (t.clamp(0.0, 1.0) * (positions() - 1) as f64).round() as usize;
    EnergyPrefs::STOPS.get(i).copied().unwrap_or(0)
}

pub fn slider_position(minutes: i64) -> f64 {
    if minutes <= 0 {
        return 1.0;
    }
    let i = EnergyPrefs::STOPS.iter().position(|s| *s >= minutes).unwrap_or(EnergyPrefs::STOPS.len() - 1);
    i as f64 / (positions() - 1) as f64
}

#[derive(Clone, Debug, PartialEq)]
pub struct Row {
    pub value: &'static str,
    pub hit: Rect,
    pub control: Rect,
}

#[derive(Clone, Debug, PartialEq)]
pub struct EnergyLayout {
    pub computer: Rect,
    pub display: Rect,
    pub sleep_box: Rect,
    pub powerd_box: Rect,
    pub powerd: Row,
    /// "Require a password to wake…" (P16.3), in the Sleep box.
    pub password: Row,
    pub ac: Vec<Row>,
    pub battery: Vec<Row>,
    /// The power mode's radios, where the base has profiles; then `ac` and
    /// `battery` are empty, and the other way round.
    pub profile: Vec<Row>,
    pub label_right: f64,
    pub ac_baseline: f64,
    pub battery_baseline: f64,
    pub battery_line_baseline: f64,
    pub note_baseline: f64,
    pub profile_baseline: f64,
}

pub fn energy_layout(body: Rect, profiles: bool) -> EnergyLayout {
    let (left, w) = (body.x + 40.0, body.w - 80.0);
    let sleep_box = Rect::new(left, body.y + 18.0, w, 212.0);
    let mut y = sleep_box.y + sleep_box.h + 16.0;
    let powerd_box = Rect::new(left, y, w, 128.0);
    y += 26.0;
    let powerd = Row { value: "powerd", hit: Rect::new(left + 16.0, y, 420.0, 22.0), control: Rect::new(left + 16.0, y + 3.0, 16.0, 16.0) };
    y += 30.0;
    let label_right = left + 150.0;
    let battery_line_baseline = powerd_box.y + powerd_box.h + 28.0;
    let mut l = EnergyLayout {
        computer: Rect::new(left + 20.0, body.y + 70.0, w - 40.0, 20.0),
        display: Rect::new(left + 20.0, body.y + 140.0, w - 40.0, 20.0),
        password: Row { value: "password", hit: Rect::new(left + 16.0, body.y + 180.0, w - 32.0, 22.0), control: Rect::new(left + 16.0, body.y + 183.0, 16.0, 16.0) },
        sleep_box,
        powerd_box,
        powerd,
        ac: vec![],
        battery: vec![],
        profile: vec![],
        label_right,
        ac_baseline: 0.0,
        battery_baseline: 0.0,
        battery_line_baseline,
        note_baseline: battery_line_baseline + 26.0,
        profile_baseline: 0.0,
    };
    let radios = |y: f64, values: Vec<&'static str>, step: f64, width: f64| -> Vec<Row> { values.into_iter().enumerate().map(|(i, v)| { let x = label_right + 12.0 + i as f64 * step; Row { value: v, hit: Rect::new(x, y, width, 22.0), control: Rect::new(x, y + 3.0, 16.0, 16.0) } }).collect() };
    if profiles {
        l.profile_baseline = y + 15.0;
        l.profile = radios(y, PowerProfile::ALL.iter().map(|p| p.as_str()).collect(), 144.0, 140.0);
        return l;
    }
    let modes: Vec<&'static str> = PowerdMode::ALL.iter().map(|m| m.as_str()).collect();
    l.ac_baseline = y + 15.0;
    l.ac = radios(y, modes.clone(), 112.0, 108.0);
    y += 28.0;
    l.battery_baseline = y + 15.0;
    l.battery = radios(y, modes, 112.0, 108.0);
    l
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum EnergyHit {
    /// A sleep slider, the display's or the computer's, and the minutes the
    /// pointer's x means on it.
    Sleep { display: bool, minutes: i64 },
    Powerd,
    RequirePassword,
    Ac(PowerdMode),
    Battery(PowerdMode),
    Profile(PowerProfile),
}

pub fn energy_hit(l: &EnergyLayout, x: f64, y: f64) -> Option<EnergyHit> {
    let t = |r: &Rect| (x - r.x) / r.w.max(1.0);
    let near = |r: &Rect| x >= r.x - 8.0 && x <= r.x + r.w + 8.0 && y >= r.y - 6.0 && y <= r.y + r.h + 6.0;
    if near(&l.computer) {
        return Some(EnergyHit::Sleep { display: false, minutes: slider_minutes(t(&l.computer)) });
    }
    if near(&l.display) {
        return Some(EnergyHit::Sleep { display: true, minutes: slider_minutes(t(&l.display)) });
    }
    if l.password.hit.contains(x, y) {
        return Some(EnergyHit::RequirePassword);
    }
    if l.powerd.hit.contains(x, y) {
        return Some(EnergyHit::Powerd);
    }
    let find = |rows: &[Row]| rows.iter().find(|r| r.hit.contains(x, y)).map(|r| r.value);
    if let Some(m) = find(&l.ac).and_then(PowerdMode::from_name) {
        return Some(EnergyHit::Ac(m));
    }
    if let Some(m) = find(&l.battery).and_then(PowerdMode::from_name) {
        return Some(EnergyHit::Battery(m));
    }
    find(&l.profile).and_then(PowerProfile::from_name).map(EnergyHit::Profile)
}

pub fn paint_energy(c: &mut Canvas, l: &EnergyLayout, s: &EnergyPaneState) {
    let t = c.theme.tokens.clone();
    let left = |c: &mut Canvas, s: &str, x: f64, y: f64, k, size| c.text_left(s, x, y, k, size, Style::Regular, Role::Interface);
    let width = |c: &mut Canvas, s: &str, size| c.text_width(s, size, Style::Regular, Role::Interface);
    c.group_box(l.sleep_box, "Sleep");
    let slider = |c: &mut Canvas, tr: Rect, title: &str, minutes: i64| {
        left(c, title, tr.x, tr.y - 10.0, t.body_text, 13.0);
        c.slider(tr, slider_position(minutes));
        let words = EnergyPrefs::words(minutes);
        let w = width(c, &words, 12.0);
        left(c, &words, tr.x + tr.w - w, tr.y - 10.0, t.secondary_text, 12.0);
        left(c, "1 min", tr.x, tr.y + tr.h + 12.0, t.secondary_text, 10.0);
        let n = width(c, "Never", 10.0);
        left(c, "Never", tr.x + tr.w - n, tr.y + tr.h + 12.0, t.secondary_text, 10.0)
    };
    slider(c, l.computer, "Put the computer to sleep when it is inactive for:", s.prefs.system_sleep_minutes);
    slider(c, l.display, "Put the display to sleep when the computer is inactive for:", s.prefs.display_sleep_minutes);
    c.checkbox(l.password.control, s.prefs.require_password);
    left(c, "Require a password to wake this computer from sleep or the screen saver", l.password.control.x + 24.0, l.password.control.y + 12.0, t.body_text, 13.0);
    c.text(&format!("The display sleeps as set; the computer does not yet.  {}", sleep_state_words(s.sleep_states.as_deref())), l.sleep_box.x + l.sleep_box.w / 2.0, l.sleep_box.y + l.sleep_box.h - 12.0, t.secondary_text, 11.0, Style::Regular, Role::Interface);
    c.group_box(l.powerd_box, "Processor");
    let on = s.powerd.as_ref().is_some_and(|p| p.powerd);
    c.checkbox(l.powerd.control, on);
    left(c, "Adjust the processor's speed to the work (powerd)", l.powerd.control.x + 24.0, l.powerd.control.y + 12.0, t.body_text, 13.0);
    let dim = if on { t.body_text } else { t.secondary_text };
    let heading = |c: &mut Canvas, text: &str, baseline: f64, k| {
        let w = width(c, text, 13.0);
        left(c, text, l.label_right - w, baseline, k, 13.0)
    };
    if !l.profile.is_empty() {
        // The profile sets more than powerd, so its row is live either way.
        heading(c, "Power mode:", l.profile_baseline, t.body_text);
        for r in &l.profile {
            let Some(p) = PowerProfile::from_name(r.value) else { continue };
            c.radio_button(r.control.x + 8.0, r.control.y + 8.0, 7.0, Some(p) == s.profile);
            left(c, profile_words(p), r.control.x + 22.0, r.control.y + 12.0, t.body_text, 12.0)
        }
    }
    if !l.ac.is_empty() {
        heading(c, "On AC power:", l.ac_baseline, dim);
        heading(c, "On battery:", l.battery_baseline, dim)
    }
    for (rows, chosen) in [(&l.ac, s.powerd.as_ref().map(|p| p.on_ac)), (&l.battery, s.powerd.as_ref().map(|p| p.on_battery))] {
        for r in rows {
            let Some(m) = PowerdMode::from_name(r.value) else { continue };
            c.radio_button(r.control.x + 8.0, r.control.y + 8.0, 7.0, Some(m) == chosen);
            left(c, mode_words(m), r.control.x + 22.0, r.control.y + 12.0, dim, 12.0)
        }
    }
    left(c, &format!("Battery: {}", battery_words(s.battery.as_ref())), l.sleep_box.x, l.battery_line_baseline, t.body_text, 13.0);
    if !s.note.is_empty() {
        left(c, &s.note, l.sleep_box.x, l.note_baseline, t.body_text, 12.0)
    }
}

pub struct EnergyPane {
    me: std::rc::Weak<EnergyPane>,
    state: RefCell<EnergyPaneState>,
    layout: RefCell<Option<EnergyLayout>>,
    /// A slider being dragged: the display's (true) or the computer's.
    drag: Cell<Option<bool>>,
    applying: RefCell<Option<Rc<Apply>>>,
    dumped: RefCell<Option<EnergyLayout>>,
}

fn elog(s: &str) {
    log(&format!("energy: {s}"))
}

impl EnergyPane {
    pub fn new(state: EnergyPaneState) -> Rc<EnergyPane> {
        Rc::new_cyclic(|me| EnergyPane { me: me.clone(), state: RefCell::new(state), layout: RefCell::new(None), drag: Cell::new(None), applying: RefCell::new(None), dumped: RefCell::new(None) })
    }

    fn load(&self, h: &Rc<PrefsHost>) {
        let mut s = self.state.borrow_mut();
        s.prefs = EnergyPrefs::load(None);
        s.battery = Battery::read();
        s.sleep_states = vents::sysctl::string("hw.acpi.supported_sleep_state");
        match client::read("energy", None) {
            Ok(SettingsPlan::Energy(p)) => {
                s.powerd = Some(p);
                s.note.clear()
            }
            Ok(_) => {}
            Err(why) => {
                s.powerd = None;
                s.note = format!("The settings helper says: {}", why.message);
                elog(&format!("cannot read powerd: {}", why.message))
            }
        }
        // A refusal is usually the base saying it has no profiles: not a
        // fault; the page falls back to powerd's own modes.
        match client::read("power-profile", None) {
            Ok(SettingsPlan::PowerProfile(p)) => s.profile = Some(p),
            Ok(_) => {}
            Err(why) => {
                s.profile = None;
                elog(&format!("no power mode: {}", why.message))
            }
        }
        elog(&format!("status {}", status_line(&s)));
        drop(s);
        h.redraw()
    }

    fn set_sleep(&self, h: &Rc<PrefsHost>, display: bool, minutes: i64) {
        let mut s = self.state.borrow_mut();
        let mut p = s.prefs;
        if display {
            p.display_sleep_minutes = minutes
        } else {
            p.system_sleep_minutes = minutes
        }
        s.prefs = p.consistent(display);
        drop(s);
        h.redraw()
    }

    fn store_prefs(&self, what: &str) {
        let r = self.state.borrow().prefs.store(None);
        match r {
            Ok(()) => elog(&format!("stored {what}")),
            Err(e) => {
                let note = format!("Could not save: {e}");
                elog(&note);
                self.state.borrow_mut().note = note
            }
        }
    }

    /// Either plan, through the one helper connection.
    fn apply(&self, h: &Rc<PrefsHost>, plan: SettingsPlan, what: &str) {
        if self.applying.borrow().is_some() {
            return;
        }
        let Some(d) = &h.display else { return };
        elog(&format!("apply {what}"));
        let (me, host) = (self.me.clone(), h.clone());
        let a = Apply::begin(d, &client::apply_request(&plan), elog, move |ok, said| {
            let Some(p) = me.upgrade() else { return };
            elog(&format!("{} — {said}", if ok { "applied" } else { "not applied" }));
            *p.applying.borrow_mut() = None;
            p.state.borrow_mut().busy = false;
            p.load(&host);
            p.state.borrow_mut().note = said;
            host.redraw()
        });
        match a {
            Some(a) => {
                self.state.borrow_mut().busy = true;
                *self.applying.borrow_mut() = Some(a)
            }
            None => {
                let note = "Not changed: the settings helper is not running on this machine".to_string();
                elog(&note);
                self.state.borrow_mut().note = note
            }
        }
    }

    fn apply_powerd(&self, h: &Rc<PrefsHost>, p: EnergyPlan) {
        let what = format!("powerd {} ac {} battery {}{}", if p.powerd { "on" } else { "off" }, p.on_ac.as_str(), p.on_battery.as_str(), if p.modes_from_profile { " (modes from the power profile)" } else { "" });
        self.apply(h, SettingsPlan::Energy(p), &what)
    }
}

impl Pane for EnergyPane {
    fn id(&self) -> &'static str {
        "energySaver"
    }
    fn shown(&self, h: &Rc<PrefsHost>) {
        self.load(h)
    }
    fn paint(&self, c: &mut Canvas, body: Rect) {
        let s = self.state.borrow().clone();
        let l = energy_layout(body, s.profile.is_some());
        paint_energy(c, &l, &s);
        *self.layout.borrow_mut() = Some(l)
    }
    /// The `computer` and `display` tracks as `x0-x1,y`, the checkboxes,
    /// and `ac.<mode>`, `battery.<mode>`, `profile.<p>` at their radios.
    fn dump(&self) -> Vec<String> {
        let Some(l) = self.layout.borrow().clone() else { return vec![] };
        if self.dumped.borrow().as_ref() == Some(&l) {
            return vec![];
        }
        let mut line = format!("energy layout computer={} display={} powerd={} password={}", track(&l.computer), track(&l.display), at(&l.powerd.hit), at(&l.password.hit));
        for (name, rows) in [("ac", &l.ac), ("battery", &l.battery), ("profile", &l.profile)] {
            for r in rows {
                line += &format!(" {name}.{}={}", r.value, at(&r.hit))
            }
        }
        *self.dumped.borrow_mut() = Some(l);
        vec![line]
    }
    fn pointer_moved(&self, h: &Rc<PrefsHost>, x: f64, _y: f64) {
        let (Some(display), Some(l)) = (self.drag.get(), self.layout.borrow().clone()) else { return };
        let tr = if display { l.display } else { l.computer };
        let m = slider_minutes((x - tr.x) / tr.w.max(1.0));
        let now = { let p = &self.state.borrow().prefs; if display { p.display_sleep_minutes } else { p.system_sleep_minutes } };
        if m != now {
            self.set_sleep(h, display, m)
        }
    }
    fn press(&self, h: &Rc<PrefsHost>, x: f64, y: f64) -> bool {
        let Some(hit) = self.layout.borrow().as_ref().and_then(|l| energy_hit(l, x, y)) else { return false };
        let (powerd, profile) = { let s = self.state.borrow(); (s.powerd, s.profile) };
        match hit {
            EnergyHit::Sleep { display, minutes } => {
                self.drag.set(Some(display));
                self.set_sleep(h, display, minutes)
            }
            EnergyHit::Powerd => {
                if let Some(mut p) = powerd {
                    p.powerd = !p.powerd;
                    // With a power profile powerd runs with no flags, so the
                    // profile keeps choosing its mode (P14.8b).
                    p.modes_from_profile = profile.is_some();
                    self.apply_powerd(h, p)
                }
            }
            EnergyHit::RequirePassword => {
                let on = { let mut s = self.state.borrow_mut(); s.prefs.require_password = !s.prefs.require_password; s.prefs.require_password };
                self.store_prefs(&format!("require_password {on}"))
            }
            EnergyHit::Profile(p) if Some(p) != profile => self.apply(h, SettingsPlan::PowerProfile(p), &format!("power profile {}", p.as_str())),
            EnergyHit::Ac(m) => {
                if let Some(mut p) = powerd.filter(|p| p.on_ac != m) {
                    p.on_ac = m;
                    self.apply_powerd(h, p)
                }
            }
            EnergyHit::Battery(m) => {
                if let Some(mut p) = powerd.filter(|p| p.on_battery != m) {
                    p.on_battery = m;
                    self.apply_powerd(h, p)
                }
            }
            EnergyHit::Profile(_) => {}
        }
        h.redraw();
        true
    }
    /// A slider let go: one write, not one a step.
    fn release(&self, h: &Rc<PrefsHost>) -> bool {
        if self.drag.take().is_none() {
            return false;
        }
        let what = { let p = &self.state.borrow().prefs; format!("computer {} display {}", p.system_sleep_minutes, p.display_sleep_minutes) };
        self.store_prefs(&what);
        h.redraw();
        true
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_slider_maps_to_the_stops_then_never() {
        assert_eq!(slider_minutes(0.0), 1);
        assert_eq!(slider_minutes(1.0), 0, "the end is Never");
        assert_eq!(slider_position(0), 1.0);
        for m in EnergyPrefs::STOPS {
            assert_eq!(slider_minutes(slider_position(m)), m, "{m} round-trips")
        }
    }

    #[test]
    fn the_page_says_the_machine_in_words() {
        assert_eq!(sleep_state_words(Some("S3 S4 S5")), "This machine can sleep (S3), hibernate (S4), power off (S5).");
        assert_eq!(sleep_state_words(None), "This machine reports no sleep states.");
        assert_eq!(battery_words(None), "No battery");
        assert_eq!(battery_words(Some(&Battery { percent: Some(50), minutes_remaining: None, is_charging: true })), "50%, charging");
        assert!(status_line(&EnergyPaneState::sample()).starts_with("computer 30 display 10 powerd on ac hiadaptive battery adaptive battery 83"));
    }

    #[test]
    fn every_control_is_hit_where_it_is_drawn() {
        let l = energy_layout(Rect::new(0.0, 100.0, 760.0, 500.0), false);
        let mid = |r: &Rect| (r.x + r.w / 2.0, r.y + r.h / 2.0);
        for r in &l.ac {
            let (x, y) = mid(&r.hit);
            assert_eq!(energy_hit(&l, x, y), Some(EnergyHit::Ac(PowerdMode::from_name(r.value).unwrap())))
        }
        let (x, y) = mid(&l.powerd.hit);
        assert_eq!(energy_hit(&l, x, y), Some(EnergyHit::Powerd));
        assert_eq!(energy_hit(&l, l.computer.x, l.computer.y + 5.0), Some(EnergyHit::Sleep { display: false, minutes: 1 }));
    }

    #[test]
    fn one_layout_for_paint_and_hit() {
        let l = energy_layout(Rect::new(0.0, 80.0, 760.0, 540.0), false);
        assert_eq!(energy_hit(&l, l.computer.x, l.computer.y + 10.0), Some(EnergyHit::Sleep { display: false, minutes: 1 }));
        assert_eq!(energy_hit(&l, l.display.x + l.display.w, l.display.y + 10.0), Some(EnergyHit::Sleep { display: true, minutes: 0 }), "the far end is Never");
        assert_eq!(energy_hit(&l, l.powerd.hit.x + 5.0, l.powerd.hit.y + 5.0), Some(EnergyHit::Powerd));
        assert_eq!(energy_hit(&l, l.battery[2].hit.x + 5.0, l.battery[2].hit.y + 5.0), Some(EnergyHit::Battery(PowerdMode::Minimum)));
        assert_eq!(energy_hit(&l, l.ac[3].hit.x + 5.0, l.ac[3].hit.y + 5.0), Some(EnergyHit::Ac(PowerdMode::Maximum)));
        assert!(l.note_baseline < 620.0);
        assert!(l.profile.is_empty());
    }

    #[test]
    fn with_profiles_the_power_mode_replaces_the_per_source_modes() {
        let l = energy_layout(Rect::new(0.0, 80.0, 760.0, 540.0), true);
        assert!(l.ac.is_empty() && l.battery.is_empty());
        assert_eq!(l.profile.iter().map(|r| r.value).collect::<Vec<_>>(), ["power-saver", "balanced", "performance"]);
        assert_eq!(energy_hit(&l, l.profile[2].hit.x + 5.0, l.profile[2].hit.y + 5.0), Some(EnergyHit::Profile(PowerProfile::Performance)));
        assert_eq!(energy_hit(&l, l.powerd.hit.x + 5.0, l.powerd.hit.y + 5.0), Some(EnergyHit::Powerd));
        assert_eq!(profile_words(PowerProfile::PowerSaver), "Power Saver");
        let s = EnergyPaneState { profile: Some(PowerProfile::Balanced), ..EnergyPaneState::sample() };
        assert!(status_line(&s).contains(" profile balanced battery "), "{}", status_line(&s));
    }
}
