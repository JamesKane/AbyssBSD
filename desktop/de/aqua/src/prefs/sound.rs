//! The Sound pane (SoundPane.swift, P14.6c).
//!
//! - **Levels and mute** of the default device's controls: straight to
//!   `/dev/mixerN`, the person's, as the slider moves.
//! - **The output device** (`hw.snd.default_unit`): root's, through the
//!   settings helper.
//!
//! And what it only shows: **which applications are playing**, at the level
//! each set, from `/dev/sndstat`; OSS lets another process read a channel's
//! volume and not set it, and the page says so. Read, not remembered: again
//! every second while it shows.

use super::settings_client::{self as client, Apply};
use super::{at, log, Pane, PrefsHost};
use aquadraw::canvas::Canvas;
use aquadraw::drawlist::Role;
use aquadraw::runner::Rect;
use aquadraw::text::Style;
use settings::{SettingsPlan, SoundPlan};
use std::cell::{Cell, RefCell};
use std::rc::{Rc, Weak};
use vents::sound::{self, Channel, Control, Device};

#[derive(Clone, Debug, Default, PartialEq)]
pub struct SoundPaneState {
    pub devices: Vec<Device>,
    /// The unit `/dev/dsp` means now.
    pub default_unit: Option<i64>,
    /// The default device's controls.
    pub controls: Vec<Control>,
    pub note: String,
    pub busy: bool,
}

impl SoundPaneState {
    /// The machine, now.
    pub fn read() -> SoundPaneState {
        let devices = sound::devices();
        let unit = sound::default_unit().filter(|u| devices.iter().any(|d| d.unit == *u)).or(devices.first().map(|d| d.unit));
        SoundPaneState { controls: unit.map_or(vec![], sound::controls), devices, default_unit: unit, ..SoundPaneState::default() }
    }

    pub fn outputs(&self) -> Vec<&Device> {
        self.devices.iter().filter(|d| d.playback).collect()
    }
    pub fn default_device(&self) -> Option<&Device> {
        self.devices.iter().find(|d| Some(d.unit) == self.default_unit)
    }
    /// Every application playing, on any device.
    pub fn playing(&self) -> Vec<&Channel> {
        self.devices.iter().flat_map(|d| d.playing()).collect()
    }

    /// A fixed machine, for the golden picture.
    pub fn sample() -> SoundPaneState {
        let ch = |name: &str, pid, command: &str, v| Channel { name: name.into(), pid: Some(pid), command: command.into(), left: v, right: v };
        let ctl = |name: &str, v, muted, recordable| Control { name: name.into(), left: v, right: v, muted, recordable };
        let dev = |unit, name: &str, description: &str, devnode: &str, channels| Device { unit, name: name.into(), description: description.into(), devnode: devnode.into(), playback: true, recording: true, from_user: false, channels };
        SoundPaneState {
            devices: vec![dev(0, "pcm0", "Realtek ALC897 (Rear Analog)", "dsp0", vec![ch("dsp0.virtual_play.0", 2211, "firefox", 100), ch("dsp0.virtual_play.1", 3104, "mpv", 45)]), dev(1, "pcm1", "USB Headset", "dsp1", vec![])],
            default_unit: Some(0),
            controls: vec![ctl("vol", 60, false, false), ctl("pcm", 75, false, false), ctl("rec", 50, true, true)],
            ..SoundPaneState::default()
        }
    }
}

/// A control as a person reads it.
pub fn label(control: &str) -> &str {
    match control {
        "vol" => "Output volume",
        "pcm" => "Applications",
        "rec" => "Input",
        "mic" => "Microphone",
        "line" => "Line in",
        "speaker" => "Speaker",
        "cd" => "CD",
        c => c,
    }
}

/// The page as one line, in `ventsctl sound`'s terms.
pub fn status_line(s: &SoundPaneState) -> String {
    let Some(d) = s.default_device() else { return "no devices".into() };
    let mut parts = vec![format!("default {}", d.name)];
    parts.extend(s.controls.iter().map(|c| format!("{} {}:{}{}", c.name, c.left, c.right, if c.muted { " muted" } else { "" })));
    let p = s.playing();
    parts.push(format!("playing {}", if p.is_empty() { "none".into() } else { p.iter().map(|c| format!("{} {} {}:{}", c.pid.unwrap_or(-1), c.command, c.left, c.right)).collect::<Vec<_>>().join(", ") }));
    parts.join("; ")
}

/// An application's line in the read-only list.
pub fn player(c: &Channel) -> String {
    format!("{} (pid {}) — {}%{}", c.command, c.pid.unwrap_or(-1), c.left.max(c.right), if c.left != c.right { format!(" ({}:{})", c.left, c.right) } else { String::new() })
}

#[derive(Clone, Debug, PartialEq)]
pub struct Row {
    /// A unit, or a control's name.
    pub value: String,
    pub hit: Rect,
    /// The radio, the slider's track, or the checkbox.
    pub control: Rect,
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct SoundLayout {
    pub outputs: Vec<Row>,
    pub levels: Vec<Row>,
    pub mutes: Vec<Row>,
    pub levels_box: Rect,
    pub label_right: f64,
    pub output_baseline: f64,
    pub playing_baseline: f64,
    pub note_baseline: f64,
}

pub fn sound_layout(body: Rect, s: &SoundPaneState) -> SoundLayout {
    let label_right = body.x + 170.0;
    let x = label_right + 12.0;
    let mut y = body.y + 24.0;
    let mut l = SoundLayout { label_right, output_baseline: y + 15.0, ..SoundLayout::default() };
    for d in s.outputs() {
        l.outputs.push(Row { value: d.unit.to_string(), hit: Rect::new(x, y, 420.0, 22.0), control: Rect::new(x, y + 3.0, 16.0, 16.0) });
        y += 22.0
    }
    if s.outputs().is_empty() {
        y += 22.0
    }
    y += 16.0;
    l.levels_box = Rect::new(body.x + 40.0, y, body.w - 80.0, s.controls.len().max(1) as f64 * 32.0 + 30.0);
    let mut ry = y + 28.0;
    for c in &s.controls {
        l.levels.push(Row { value: c.name.clone(), hit: Rect::new(x, ry, 240.0, 24.0), control: Rect::new(x + 4.0, ry + 2.0, 232.0, 20.0) });
        l.mutes.push(Row { value: c.name.clone(), hit: Rect::new(x + 290.0, ry, 80.0, 24.0), control: Rect::new(x + 290.0, ry + 4.0, 16.0, 16.0) });
        ry += 32.0
    }
    l.playing_baseline = l.levels_box.y + l.levels_box.h + 28.0;
    l.note_baseline = l.playing_baseline + s.playing().len().max(1) as f64 * 20.0 + 48.0;
    l
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum SoundHit {
    Output(i64),
    /// A control, and the level the pointer's x means on its track.
    Level(String, i64),
    Mute(String),
}

pub fn sound_hit(l: &SoundLayout, x: f64, y: f64) -> Option<SoundHit> {
    if let Some(u) = l.outputs.iter().find(|r| r.hit.contains(x, y)).and_then(|r| r.value.parse().ok()) {
        return Some(SoundHit::Output(u));
    }
    if let Some(r) = l.levels.iter().find(|r| r.hit.contains(x, y)) {
        return Some(SoundHit::Level(r.value.clone(), sound_level(r.control, x)));
    }
    l.mutes.iter().find(|r| r.hit.contains(x, y)).map(|r| SoundHit::Mute(r.value.clone()))
}

/// The level at `x` on a track, 0…100.
pub fn sound_level(track: Rect, x: f64) -> i64 {
    (((x - track.x) / track.w.max(1.0)).clamp(0.0, 1.0) * 100.0).round() as i64
}

pub fn paint_sound(c: &mut Canvas, l: &SoundLayout, s: &SoundPaneState) {
    let t = c.theme.tokens.clone();
    let left = |c: &mut Canvas, s: &str, x: f64, y: f64, k, size| c.text_left(s, x, y, k, size, Style::Regular, Role::Interface);
    let heading = |c: &mut Canvas, text: &str, baseline: f64| {
        let w = c.text_width(text, 13.0, Style::Regular, Role::Interface);
        left(c, text, l.label_right - w, baseline, t.body_text, 13.0)
    };
    heading(c, "Output device:", l.output_baseline);
    if s.devices.is_empty() {
        return left(c, "This machine has no sound devices — /dev/sndstat lists none.", l.label_right + 12.0, l.output_baseline, t.secondary_text, 13.0);
    }
    for r in &l.outputs {
        let Some(d) = s.devices.iter().find(|d| d.unit.to_string() == r.value) else { continue };
        c.radio_button(r.control.x + 8.0, r.control.y + 8.0, 7.0, Some(d.unit) == s.default_unit);
        left(c, &format!("{}  ({})", d.description, d.name), r.control.x + 24.0, r.control.y + 12.0, t.body_text, 13.0)
    }
    c.group_box(l.levels_box, &format!("Levels{}", s.default_device().map_or(String::new(), |d| format!(" — {}", d.name))));
    for (r, m) in l.levels.iter().zip(&l.mutes) {
        let Some(ctl) = s.controls.iter().find(|x| x.name == r.value) else { continue };
        heading(c, &format!("{}:", label(&ctl.name)), r.hit.y + 16.0);
        c.slider(r.control, ctl.level() as f64 / 100.0);
        left(c, &format!("{}%", ctl.level()), r.hit.x + r.hit.w + 8.0, r.hit.y + 16.0, t.secondary_text, 11.0);
        c.checkbox(m.control, ctl.muted);
        left(c, "Mute", m.control.x + 22.0, m.control.y + 12.0, t.body_text, 13.0)
    }
    heading(c, "Playing now:", l.playing_baseline);
    let mut y = l.playing_baseline;
    let p = s.playing();
    if p.is_empty() {
        left(c, "No application is playing.", l.label_right + 12.0, y, t.secondary_text, 13.0);
        y += 20.0
    }
    for ch in p {
        left(c, &player(ch), l.label_right + 12.0, y, t.body_text, 13.0);
        y += 20.0
    }
    left(c, "Each application sets its own level. Changing it from here comes with", l.label_right + 12.0, y + 4.0, t.secondary_text, 11.0);
    left(c, "per-application sound, which needs each application on a device of its own.", l.label_right + 12.0, y + 18.0, t.secondary_text, 11.0);
    if !s.note.is_empty() {
        left(c, &s.note, l.levels_box.x, l.note_baseline, t.body_text, 12.0)
    }
}

fn slog(s: &str) {
    log(&format!("sound: {s}"))
}

pub struct SoundPane {
    me: Weak<SoundPane>,
    state: RefCell<SoundPaneState>,
    layout: RefCell<Option<SoundLayout>>,
    drag: RefCell<Option<String>>,
    applying: RefCell<Option<Rc<Apply>>>,
    timer: Cell<Option<u64>>,
    dumped: RefCell<Option<SoundLayout>>,
}

impl SoundPane {
    pub fn new(state: SoundPaneState) -> Rc<SoundPane> {
        Rc::new_cyclic(|me| SoundPane { me: me.clone(), state: RefCell::new(state), layout: RefCell::new(None), drag: RefCell::new(None), applying: RefCell::new(None), timer: Cell::new(None), dumped: RefCell::new(None) })
    }

    /// Read the machine, keeping what the page says and whether it waits.
    fn reread(&self) -> SoundPaneState {
        let s = self.state.borrow();
        SoundPaneState { note: s.note.clone(), busy: s.busy, ..SoundPaneState::read() }
    }

    fn load(&self, h: &Rc<PrefsHost>, read_configured: bool) {
        let fresh = self.reread();
        slog(&format!("status {}", status_line(&fresh)));
        let has = !fresh.devices.is_empty();
        let unit = fresh.default_unit;
        *self.state.borrow_mut() = fresh;
        if read_configured && has {
            // What the next boot chooses, which is not always what
            // /dev/dsp means now.
            match client::read("sound", None) {
                Ok(SettingsPlan::Sound(p)) => {
                    slog(&format!("read default pcm{}", p.default_unit));
                    if Some(p.default_unit) != unit {
                        self.state.borrow_mut().note = format!("At the next start, the output will be pcm{}.", p.default_unit)
                    }
                }
                Ok(_) => {}
                Err(why) => {
                    self.state.borrow_mut().note = format!("The settings helper says: {}", why.message);
                    slog(&format!("cannot read: {}", why.message))
                }
            }
        }
        h.redraw()
    }

    /// Nothing says a level changed: read again once a second.
    fn tick(&self, h: &Rc<PrefsHost>) {
        if self.drag.borrow().is_some() {
            return;
        }
        let fresh = self.reread();
        if fresh == *self.state.borrow() {
            return;
        }
        slog(&format!("changed {}", status_line(&fresh)));
        *self.state.borrow_mut() = fresh;
        h.redraw()
    }

    /// Set a level, and show it at once.
    fn set_level(&self, h: &Rc<PrefsHost>, name: &str, level: i64) {
        let Some(unit) = self.state.borrow().default_unit else { return };
        match sound::set(unit, name, level, level) {
            Some(why) => {
                let note = format!("Could not set {}: {why}", label(name));
                slog(&note);
                self.state.borrow_mut().note = note
            }
            None => {
                if let Some(c) = self.state.borrow_mut().controls.iter_mut().find(|c| c.name == name) {
                    (c.left, c.right) = (level, level)
                }
            }
        }
        h.redraw()
    }
}

impl Pane for SoundPane {
    fn id(&self) -> &'static str {
        "sound"
    }
    fn shown(&self, h: &Rc<PrefsHost>) {
        self.load(h, true);
        if let (None, Some(d)) = (self.timer.get(), &h.display) {
            let (me, host) = (self.me.clone(), h.clone());
            self.timer.set(Some(d.add_timer(1000, move || {
                if let Some(p) = me.upgrade() {
                    p.tick(&host)
                }
            })))
        }
    }
    fn hidden(&self, h: &Rc<PrefsHost>) {
        if let (Some(t), Some(d)) = (self.timer.take(), &h.display) {
            d.remove_timer(t)
        }
    }
    fn paint(&self, c: &mut Canvas, body: Rect) {
        let s = self.state.borrow().clone();
        let l = sound_layout(body, &s);
        paint_sound(c, &l, &s);
        *self.layout.borrow_mut() = Some(l)
    }
    /// `output.<unit>` at the radio, `level.<control>=x0-x1,y` along the
    /// track, `mute.<control>` at the checkbox.
    fn dump(&self) -> Vec<String> {
        let Some(l) = self.layout.borrow().clone() else { return vec![] };
        if self.dumped.borrow().as_ref() == Some(&l) {
            return vec![];
        }
        let mut line = "sound layout".to_string();
        for r in &l.outputs {
            line += &format!(" output.{}={}", r.value, at(&r.hit))
        }
        for r in &l.levels {
            line += &format!(" level.{}={}-{},{}", r.value, r.control.x as i64, (r.control.x + r.control.w) as i64, (r.control.y + r.control.h / 2.0) as i64)
        }
        for r in &l.mutes {
            line += &format!(" mute.{}={}", r.value, at(&r.hit))
        }
        *self.dumped.borrow_mut() = Some(l);
        vec![line]
    }
    fn pointer_moved(&self, h: &Rc<PrefsHost>, x: f64, _y: f64) {
        let Some(name) = self.drag.borrow().clone() else { return };
        let Some(tr) = self.layout.borrow().as_ref().and_then(|l| l.levels.iter().find(|r| r.value == name).map(|r| r.control)) else { return };
        let v = sound_level(tr, x);
        if self.state.borrow().controls.iter().find(|c| c.name == name).map(|c| c.level()) != Some(v) {
            self.set_level(h, &name, v)
        }
    }
    fn press(&self, h: &Rc<PrefsHost>, x: f64, y: f64) -> bool {
        let Some(hit) = self.layout.borrow().as_ref().and_then(|l| sound_hit(l, x, y)) else { return false };
        match hit {
            SoundHit::Level(name, v) => {
                *self.drag.borrow_mut() = Some(name.clone());
                self.set_level(h, &name, v)
            }
            SoundHit::Mute(name) => {
                let (unit, muted) = { let s = self.state.borrow(); (s.default_unit, s.controls.iter().find(|c| c.name == name).map(|c| c.muted)) };
                let (Some(unit), Some(muted)) = (unit, muted) else { return true };
                match sound::set_muted(unit, &name, !muted) {
                    Some(why) => self.state.borrow_mut().note = format!("Could not mute {}: {why}", label(&name)),
                    None => slog(&format!("{name} {}", if muted { "unmuted" } else { "muted" })),
                }
                self.load(h, false)
            }
            SoundHit::Output(unit) => {
                if Some(unit) == self.state.borrow().default_unit || self.applying.borrow().is_some() {
                    return true;
                }
                let Some(d) = &h.display else { return true };
                slog(&format!("apply default pcm{unit}"));
                let (me, host) = (self.me.clone(), h.clone());
                let a = Apply::begin(d, &client::apply_request(&SettingsPlan::Sound(SoundPlan { default_unit: unit })), slog, move |ok, said| {
                    let Some(p) = me.upgrade() else { return };
                    *p.applying.borrow_mut() = None;
                    {
                        let mut s = p.state.borrow_mut();
                        s.busy = false;
                        s.note = said.clone();
                    }
                    slog(&format!("{} — {said}", if ok { "applied" } else { "not applied" }));
                    p.load(&host, false)
                });
                match a {
                    Some(a) => {
                        self.state.borrow_mut().busy = true;
                        *self.applying.borrow_mut() = Some(a)
                    }
                    None => {
                        let note = "Not changed: the settings helper is not running on this machine".to_string();
                        slog(&note);
                        self.state.borrow_mut().note = note
                    }
                }
            }
        }
        h.redraw();
        true
    }
    fn release(&self, _h: &Rc<PrefsHost>) -> bool {
        let Some(name) = self.drag.borrow_mut().take() else { return false };
        slog(&format!("{name} set to {}", self.state.borrow().controls.iter().find(|c| c.name == name).map_or(-1, |c| c.level())));
        true
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_page_reads_as_one_line_and_every_control_is_hit_where_drawn() {
        let s = SoundPaneState::sample();
        assert_eq!(status_line(&s), "default pcm0; vol 60:60; pcm 75:75; rec 50:50 muted; playing 2211 firefox 100:100, 3104 mpv 45:45");
        let l = sound_layout(Rect::new(0.0, 100.0, 760.0, 500.0), &s);
        assert_eq!(l.outputs.len(), 2);
        let (o, m) = (&l.outputs[1].hit, &l.mutes[2].hit);
        assert_eq!(sound_hit(&l, o.x + 5.0, o.y + 5.0), Some(SoundHit::Output(1)));
        assert_eq!(sound_hit(&l, m.x + 5.0, m.y + 5.0), Some(SoundHit::Mute("rec".into())));
        let tr = l.levels[0].control;
        assert_eq!(sound_hit(&l, tr.x + tr.w, tr.y + 2.0), Some(SoundHit::Level("vol".into(), 100)));
        assert_eq!(player(&Channel { name: "x".into(), pid: Some(7), command: "mpv".into(), left: 40, right: 50 }), "mpv (pid 7) — 50% (40:50)");
    }

    // SoundPaneTests and VolumeExtraTests, the parts the test above leaves out.

    #[test]
    fn the_page_in_one_line_with_nothing_or_nobody_playing() {
        assert_eq!(status_line(&SoundPaneState::default()), "no devices");
        let mut quiet = SoundPaneState::sample();
        quiet.devices.iter_mut().for_each(|d| d.channels.clear());
        assert!(status_line(&quiet).ends_with("; playing none"), "{}", status_line(&quiet));
    }

    #[test]
    fn a_player_and_a_control_are_said_as_a_person_reads_them() {
        let c = |l, r| Channel { name: "x".into(), pid: Some(7), command: "mpv".into(), left: l, right: r };
        assert_eq!(player(&c(45, 45)), "mpv (pid 7) — 45%");
        assert_eq!(player(&c(80, 40)), "mpv (pid 7) — 80% (80:40)", "an unbalanced level says both sides");
        assert_eq!(label("vol"), "Output volume");
        assert_eq!(label("ogain"), "ogain", "an unknown control keeps its name");
    }

    #[test]
    fn one_layout_for_paint_and_hit() {
        let body = Rect::new(0.0, 80.0, 760.0, 540.0);
        let l = sound_layout(body, &SoundPaneState::sample());
        assert_eq!(l.outputs.iter().map(|r| r.value.as_str()).collect::<Vec<_>>(), ["0", "1"]);
        assert_eq!(l.levels.iter().map(|r| r.value.as_str()).collect::<Vec<_>>(), ["vol", "pcm", "rec"]);
        let tr = l.levels[0].control;
        assert_eq!(sound_hit(&l, tr.x, tr.y + 5.0), Some(SoundHit::Level("vol".into(), 0)));
        assert_eq!(sound_hit(&l, tr.x + tr.w / 4.0, tr.y + 5.0), Some(SoundHit::Level("vol".into(), 25)));
        assert_eq!(sound_level(tr, tr.x - 50.0), 0, "past the end is the end");
        assert!(l.note_baseline < body.y + body.h);
        let rects: Vec<Rect> = l.outputs.iter().chain(&l.levels).chain(&l.mutes).map(|r| r.hit).collect();
        for (i, a) in rects.iter().enumerate() {
            for b in &rects[i + 1..] {
                assert!(!(a.x < b.x + b.w && b.x < a.x + a.w && a.y < b.y + b.h && b.y < a.y + a.h), "{a:?} overlaps {b:?}");
            }
        }
        assert!(sound_layout(body, &SoundPaneState::default()).outputs.is_empty(), "no devices, no controls");
    }

    #[test]
    fn choosing_an_output_asks_the_helper_for_exactly_that() {
        let m = client::apply_request(&settings::SettingsPlan::Sound(settings::SoundPlan { default_unit: 1 }));
        assert_eq!(m.string("method"), Some("apply"));
        assert_eq!(settings_wire::decode_plan(&m), Ok(settings::SettingsPlan::Sound(settings::SoundPlan { default_unit: 1 })));
    }
}
