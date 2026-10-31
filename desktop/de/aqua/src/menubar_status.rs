//! The menu bar's status items (MenuBarStatus.swift), Jaguar's "menu
//! extras": volume and battery, between the menus and the clock, read
//! through Vents (sysctl, OSS). **An item you can't feed isn't drawn**: no
//! sound card hides the speaker rather than show a confident 0%, no battery
//! hides the battery rather than claim it full.
//!
//! The volume slider (P14.6d) is here too: a click on the speaker drops a
//! narrow popup with a vertical slider; dragging sets the level, letting go
//! closes it.

use crate::toolkit::Toolkit;
use aquadraw::canvas::{Canvas, Paint};
use aquadraw::color::Color;
use aquadraw::drawlist::{DrawState, Role};
use aquadraw::runner::Rect;
use aquadraw::text::Style;
use aquadraw::tokens::ThemeTokens;
use std::cell::{Cell, RefCell};
use std::rc::Rc;
use surface::{Popup, PopupDelegate, RenderTarget};

/// What the status area shows now. Empty is a state.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct MenuBarStatus {
    /// Master volume 0…100, or None with no mixer.
    pub volume: Option<u8>,
    /// The speaker is drawn dimmed (P14.6d).
    pub muted: bool,
    /// The unit and control the volume is: the default unit's `vol`.
    pub volume_unit: Option<i64>,
    pub volume_control: String,
    /// Charge 0…100, or None with no battery.
    pub battery_percent: Option<i64>,
    pub battery_charging: bool,
}

impl Default for MenuBarStatus {
    fn default() -> MenuBarStatus {
        MenuBarStatus { volume: None, muted: false, volume_unit: None, volume_control: "vol".into(), battery_percent: None, battery_charging: false }
    }
}

fn env_int(name: &str) -> Option<i64> {
    std::env::var(name).ok().filter(|v| !v.is_empty()).and_then(|v| v.parse().ok())
}

impl MenuBarStatus {
    pub fn is_empty(&self) -> bool {
        self.volume.is_none() && self.battery_percent.is_none()
    }

    /// Read the machine. `$ABYSS_FAKE_VOLUME` and `$ABYSS_FAKE_BATTERY`
    /// stand in, so the drawing is exercised where there is neither; read
    /// only here, never in Vents, so the bridges are never faked. The
    /// volume is the default unit's, read afresh each time, so a new
    /// default or a late card is followed on the next tick.
    pub fn read() -> MenuBarStatus {
        let mut s = MenuBarStatus::default();
        if let Some(v) = env_int("ABYSS_FAKE_VOLUME") {
            s.volume = Some(v.clamp(0, 255) as u8);
            s.muted = std::env::var_os("ABYSS_FAKE_MUTED").is_some();
        } else if let Some(unit) = vents::sound::default_unit() {
            let controls = vents::sound::controls(unit);
            if let Some(c) = controls.iter().find(|c| c.name == "vol").or(controls.first()) {
                s.volume = Some(c.level().clamp(0, 255) as u8);
                s.muted = c.muted;
                s.volume_unit = Some(unit);
                s.volume_control = c.name.clone();
            }
        }
        if let Some(b) = env_int("ABYSS_FAKE_BATTERY") {
            s.battery_percent = Some(b.clamp(0, 100));
            s.battery_charging = std::env::var_os("ABYSS_FAKE_BATTERY_CHARGING").is_some();
        } else if let Some(b) = vents::hardware::Battery::read()
            && let Some(p) = b.percent
        {
            s.battery_percent = Some(p);
            s.battery_charging = b.is_charging;
        }
        s
    }

    /// For the log: "volume 60%, no battery".
    pub fn describe(&self) -> String {
        let v = self.volume.map_or("no mixer".into(), |v| format!("volume {v}%{}", if self.muted { " muted" } else { "" }));
        let b = self.battery_percent.map_or("no battery".into(), |b| format!("battery {b}%"));
        format!("{v}, {b}")
    }
}

/// Where the items sit, right-aligned against `right_edge` (the clock's
/// left edge): the battery nearest the clock, then the volume. One layout
/// for paint and hit-test (§2.9).
pub fn menu_bar_status_layout(t: &ThemeTokens, status: &MenuBarStatus, h: f64, right_edge: f64) -> (Option<Rect>, Option<Rect>) {
    let mut x = right_edge - t.status_clock_gap;
    let mut battery = None;
    if status.battery_percent.is_some() {
        x -= t.status_battery_width;
        battery = Some(Rect::new(x, 0.0, t.status_battery_width, h));
        x -= t.status_gap;
    }
    let volume = status.volume.map(|_| Rect::new(x - t.status_volume_width, 0.0, t.status_volume_width, h));
    (volume, battery)
}

/// Draw the items.
pub fn paint_menu_bar_status(c: &mut Canvas, status: &MenuBarStatus, h: f64, right_edge: f64, color: Color) {
    let t = c.theme.tokens.clone();
    let (volume, battery) = menu_bar_status_layout(&t, status, h, right_edge);
    if let (Some(r), Some(level)) = (volume, status.volume) {
        // One arc per third of the range. Muted, the speaker is dimmed:
        // every theme has the four lists, none has to learn a fifth.
        let arcs = if level == 0 { 0 } else { (level as i64 - 1) / 34 + 1 };
        let k = if status.muted { color.with_a(color.a * 0.35) } else { color };
        c.paint(&format!("status.volume.{arcs}"), Rect::new(r.x + 2.0, (h - 12.0) / 2.0, 14.0, 12.0), Paint { colors: &[("color", k)], ..Paint::default() });
    }
    if let (Some(r), Some(pct)) = (battery, status.battery_percent) {
        let state = if status.battery_charging { DrawState::ACTIVE } else { DrawState::NORMAL };
        c.paint("status.battery", Rect::new(r.x, (h - 10.0) / 2.0, 22.0, 10.0), Paint { state, parameters: &[("charge", pct.clamp(0, 100) as f64 / 100.0)], colors: &[("color", color)], ..Paint::default() });
        c.text_left(&format!("{pct}%"), r.x + 26.0, h - 6.5, color, t.menu_bar_font_size - 1.0, Style::Regular, Role::Interface);
    }
}

pub const SLIDER_WIDTH: f64 = 34.0;
pub const SLIDER_HEIGHT: f64 = 132.0;

/// The slider's track, top to bottom, inside its popup.
pub fn slider_track() -> Rect {
    Rect::new(9.0, 12.0, 16.0, SLIDER_HEIGHT - 24.0)
}

/// The level (0…100) a pointer at `y` means: loud at the top.
pub fn slider_level(y: f64) -> i64 {
    let t = slider_track();
    (((t.y + t.h - y) / t.h).clamp(0.0, 1.0) * 100.0).round() as i64
}

type Hook<A> = RefCell<Option<Box<dyn Fn(A)>>>;

/// The speaker's popup: it sets `/dev/mixerN` as it is dragged.
pub struct VolumeSlider {
    toolkit: Rc<Toolkit>,
    pub popup: RefCell<Option<Rc<Popup>>>,
    level: Cell<i64>,
    dragging: Cell<bool>,
    last_y: Cell<f64>,
    unit: i64,
    control: String,
    /// The level set, when the button comes up.
    pub on_done: Hook<i64>,
    pub on_dismiss: Hook<()>,
}

impl VolumeSlider {
    pub fn new(toolkit: &Rc<Toolkit>, unit: i64, control: &str, level: i64) -> Rc<VolumeSlider> {
        Rc::new(VolumeSlider { toolkit: toolkit.clone(), popup: RefCell::new(None), level: Cell::new(level), dragging: Cell::new(false), last_y: Cell::new(0.0), unit, control: control.into(), on_done: RefCell::new(None), on_dismiss: RefCell::new(None) })
    }

    pub fn level(&self) -> i64 {
        self.level.get()
    }

    fn set(&self, v: i64) {
        if v == self.level.replace(v) {
            return;
        }
        let _ = vents::sound::set(self.unit, &self.control, v, v);
        let p = self.popup.borrow().clone();
        if let Some(p) = p {
            p.set_needs_display()
        }
    }
}

impl PopupDelegate for VolumeSlider {
    fn render(&self, _p: &Popup, target: &RenderTarget) {
        let level = self.level.get();
        self.toolkit.draw(target, |c, w, h| {
            c.paint_simple("menu", Rect::new(0.0, 0.0, w, h), DrawState::NORMAL);
            // The theme's slider is horizontal; a quarter turn makes this one.
            let t = slider_track();
            c.cr.save();
            c.cr.translate(t.x, t.y + t.h);
            c.cr.rotate(-std::f64::consts::FRAC_PI_2);
            c.slider(Rect::new(0.0, 0.0, t.h, t.w), level as f64 / 100.0);
            c.cr.restore();
        })
    }

    fn pointer_moved(&self, _p: &Popup, _x: f64, y: f64) {
        self.last_y.set(y);
        if self.dragging.get() {
            self.set(slider_level(y))
        }
    }

    fn pointer_button(&self, _p: &Popup, pressed: bool) {
        if pressed {
            self.dragging.set(true);
            self.set(slider_level(self.last_y.get()))
        } else if self.dragging.replace(false)
            && let Some(f) = &*self.on_done.borrow()
        {
            f(self.level.get())
        }
    }

    fn dismissed(&self, _p: &Popup) {
        if let Some(f) = &*self.on_dismiss.borrow() {
            f(())
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn st(volume: Option<u8>, battery: Option<i64>) -> MenuBarStatus {
        MenuBarStatus { volume, battery_percent: battery, ..MenuBarStatus::default() }
    }

    /// No mixer means no speaker, not a speaker at 0%.
    #[test]
    fn items_are_omitted_when_the_machine_cant_feed_them() {
        let t = ThemeTokens::default();
        let empty = MenuBarStatus::default();
        assert!(empty.is_empty());
        assert_eq!(menu_bar_status_layout(&t, &empty, 22.0, 800.0), (None, None));
    }

    #[test]
    fn items_lay_out_right_to_left_and_dont_overlap() {
        let t = ThemeTokens::default();
        let (v, b) = menu_bar_status_layout(&t, &st(Some(60), Some(84)), 22.0, 800.0);
        let (v, b) = (v.unwrap(), b.unwrap());
        assert!(v.x < b.x && v.x + v.w <= b.x);
        assert!(b.x + b.w <= 800.0);
        assert_eq!(v.h, 22.0);
    }

    /// One item's absence reserves no slot.
    #[test]
    fn a_single_item_still_hugs_the_clock() {
        let t = ThemeTokens::default();
        let (v, nb) = menu_bar_status_layout(&t, &st(Some(30), None), 22.0, 800.0);
        let (nv, b) = menu_bar_status_layout(&t, &st(None, Some(10)), 22.0, 800.0);
        assert!(nb.is_none() && nv.is_none());
        let (v, b) = (v.unwrap(), b.unwrap());
        assert_eq!(v.x + v.w, 800.0 - t.status_clock_gap);
        assert_eq!(b.x + b.w, 800.0 - t.status_clock_gap);
    }

    #[test]
    fn the_slider_is_loud_at_the_top() {
        let t = slider_track();
        assert_eq!(slider_level(t.y), 100);
        assert_eq!(slider_level(t.y + t.h), 0);
        assert_eq!(slider_level(-50.0), 100);
        assert_eq!(slider_level(t.y + t.h / 2.0), 50);
    }

    /// VolumeExtraTests: 70% of the way down is 30, and the track is inside
    /// the popup.
    #[test]
    fn the_slider_is_loud_at_the_top_and_inside_its_popup() {
        let t = slider_track();
        assert_eq!(slider_level(t.y + t.h * 0.7), 30);
        assert!(t.y + t.h <= SLIDER_HEIGHT, "the track is inside the popup");
    }

    #[test]
    fn the_bar_says_muted_and_hides_what_it_cannot_feed() {
        let mut s = st(Some(40), None);
        assert_eq!(s.describe(), "volume 40%, no battery");
        s.muted = true;
        assert_eq!(s.describe(), "volume 40% muted, no battery");
        assert_eq!(MenuBarStatus::default().describe(), "no mixer, no battery");
        assert_eq!(menu_bar_status_layout(&ThemeTokens::default(), &MenuBarStatus::default(), 22.0, 700.0).0, None, "no mixer, no speaker");
    }
}
