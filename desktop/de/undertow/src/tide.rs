//! Islands, Ebb and shoals: the compositor's half (Islands.swift, Ebb.swift,
//! Shoals.swift; PHASE13). The pure rules are R4a's (`geometry`, `shoals`,
//! `ebb`); this is where they meet the windows.
//!
//! **An island is a number on a window and a predicate in the latch**: each
//! display shows one at a time, and a window on an island nobody is looking
//! at is treated as a minimized one is. **A switch is a commit, not an
//! animation** (C6): the active island, the focused window and the keyboard
//! all change here, before the next latch; the slide is decoration.

use crate::backend::log;
use crate::compositor::{Compositor, Toplevel};
use crate::cursor_images::ARGB8888;
use crate::ebb::{Ebb, EbbSlot};
use crate::geometry::{ebb_arrange, EbbItem, EbbScope, IslandSlide, Rect};
use crate::scene::Label;
use aquadraw::drawlist::Role;
use aquadraw::text::Style;
use abyss_sys::mono;
use abyss_sys::wlr::Texture;
use abyss_sys::{self as ffi, Context, Surface};
use std::f64::consts::PI;
use std::rc::Rc;

/// A label the compositor drew (Ebb's title under the hovered window, a
/// shoal's name plate), kept until its text changes.
pub struct OwnedLabel {
    pub label: Label,
    pub title: String,
}

impl Drop for OwnedLabel {
    fn drop(&mut self) {
        self.label.texture.destroy()
    }
}

/// The strip's tiles (P13.6).
pub const STRIP_TILE_WIDTH: i32 = 160;
pub const STRIP_TILE_HEIGHT: i32 = 110;

impl Compositor {
    // MARK: islands (P13.1, P13.3)

    /// Where display `d`'s view is mid-slide, or None when it is still.
    /// Free when nobody is switching: one emptiness test per display per
    /// frame.
    pub fn island_view(&self, d: &str, now: u64) -> Option<f64> {
        let mut slides = self.island_slides.borrow_mut();
        let s = slides.get(d)?;
        let v = s.view(now);
        if v.is_none() {
            slides.remove(d);
        }
        v
    }

    /// The display a keystroke means: the focused window's, else the one
    /// under the pointer, else the main one.
    pub fn command_display(&self) -> String {
        if let Some(f) = self.focused()
            && f.mapped.get()
        {
            return f.island_display.borrow().clone();
        }
        let l = self.layout.borrow();
        if let Some((x, y)) = self.cursor.get()
            && let Some(d) = l.display_at(x, y)
        {
            return d.name.clone();
        }
        l.main().map(|m| m.name.clone()).unwrap_or_default()
    }

    /// The topmost window showing on display `d`.
    pub fn topmost_showing(&self, d: &str) -> Option<Rc<Toplevel>> {
        self.mapped_toplevels().into_iter().rev().find(|t| *t.island_display.borrow() == d)
    }

    /// Show island `n` on display `d` (the command display if None). **The
    /// commit**: what is drawn, what is under the pointer, and who has the
    /// keyboard all change now.
    pub fn switch_island(&self, n: i32, display: Option<&str>) {
        let d = display.map_or_else(|| self.command_display(), str::to_owned);
        let (count, animate, slide_ms) = {
            let i = self.islands.borrow();
            (i.count as i32, i.animate, i.slide_ms)
        };
        if n < 1 || n > count || self.active_island(&d) == n {
            return;
        }
        let now = mono::now();
        // An island switch puts the tide back: Ebb showed the one you left.
        if let Some(e) = self.ebb.borrow_mut().as_mut()
            && e.display == d
            && !e.closing()
            && e.scope == EbbScope::Island
        {
            e.close(now)
        }
        // The slide starts from wherever the view is, so asking again
        // re-targets; it never queues (PRODUCT §7.2 rule 2).
        if animate && slide_ms > 0 {
            let from = self.island_view(&d, now).unwrap_or(self.active_island(&d) as f64);
            self.island_slides.borrow_mut().insert(d.clone(), IslandSlide { from, to: n, start: now, duration_ns: slide_ms as u64 * 1_000_000 });
        }
        self.active_islands.borrow_mut().insert(d.clone(), n);
        self.island_switches.set(self.island_switches.get() + 1);
        // Stamped for C6: the earliest unshown request is what a person is
        // waiting on.
        self.island_inputs.borrow_mut().entry(d.clone()).or_insert(now);
        // A window being dragged goes with you: it is in your hand.
        if let Some(carried) = self.moving()
            && *carried.island_display.borrow() == d
        {
            carried.island.set(n)
        }
        let on_d: Vec<Rc<Toplevel>> = self.toplevels.borrow().iter().filter(|t| t.mapped.get() && *t.island_display.borrow() == d).cloned().collect();
        for t in &on_d {
            self.refresh_suspended(t)
        }
        if let Some(w) = self.topmost_showing(&d) {
            self.focus(&w)
        } else if self.focused().is_some_and(|f| !self.is_on_active_island(&f)) {
            self.focus_topmost()
        }
        self.menus_send_island(&d, None);
        log(&format!("island {d} {n} ({})", self.islands.borrow().name(n as i64)));
    }

    /// Ctrl-← / Ctrl-→: the next island on the command display, wrapping.
    pub fn step_island(&self, by: i32) {
        let d = self.command_display();
        let n = self.islands.borrow().step(self.active_island(&d) as i64, by as i64) as i32;
        self.switch_island(n, Some(&d));
    }

    /// The focused window to island `n` (§6.2): it goes and you stay,
    /// unless `follow`.
    pub fn move_focused_window_to_island(&self, n: i32, follow: bool) {
        let Some(t) = self.focused() else { return };
        if n < 1 || n > self.islands.borrow().count as i32 || t.island.get() == n {
            return;
        }
        t.island.set(n);
        self.refresh_suspended(&t);
        log(&format!("window {} to island {n}{}", t.place_key().unwrap_or_else(|| "?".into()), if follow { ", followed" } else { "" }));
        let d = t.island_display.borrow().clone();
        if follow {
            self.switch_island(n, Some(&d));
            self.focus(&t);
        } else if let Some(w) = self.topmost_showing(&d) {
            self.focus(&w)
        } else {
            self.focus_topmost()
        }
    }

    /// Take islands.ini again. Fewer islands than a display shows, or a
    /// window is on: they come to the last that is left; nothing is lost.
    pub fn reload_islands(&self) {
        let next = pool_config::IslandsConfig::load(self.config_dir.as_deref());
        if next == *self.islands.borrow() {
            return;
        }
        let count = next.count as i32;
        for v in self.active_islands.borrow_mut().values_mut() {
            *v = (*v).min(count)
        }
        let ts = self.toplevels.borrow().clone();
        for t in &ts {
            if t.island.get() > count {
                t.island.set(count)
            }
        }
        *self.islands.borrow_mut() = next.clone();
        for t in ts.iter().filter(|t| t.mapped.get()) {
            self.refresh_suspended(t)
        }
        let names: Vec<String> = self.layout.borrow().displays.iter().map(|d| d.name.clone()).collect();
        for d in names {
            self.menus_send_island(&d, None)
        }
        let names = if next.names.is_empty() { String::new() } else { format!(", named {}", next.names.join(",")) };
        log(&format!("islands.ini: {count} island(s), slide {}{names}", if next.animate { "on" } else { "off" }));
    }

    // MARK: Ebb (P13.5)

    /// F3, Ctrl-↑, Ctrl-↓ (§6.4): open Ebb on the command display in
    /// `scope`, or, with one open, put the tide back.
    pub fn toggle_ebb(&self, scope: EbbScope) {
        let now = mono::now();
        if let Some(e) = self.ebb.borrow_mut().as_mut()
            && !e.closing()
        {
            e.close(now);
            log(&format!("ebb {} off", e.display));
            return;
        }
        let d = self.command_display();
        let app = self.focused().and_then(|f| f.app_id());
        let mut windows: Vec<Rc<Toplevel>> = self
            .toplevels
            .borrow()
            .iter()
            .filter(|t| {
                t.mapped.get()
                    && !t.minimized.get()
                    && *t.island_display.borrow() == d
                    && t.surface.has_buffer()
                    && match scope {
                        EbbScope::Island => self.is_on_active_island(t),
                        EbbScope::Archipelago => true,
                        EbbScope::App => app.is_some() && t.app_id() == app,
                    }
            })
            .cloned()
            .collect();
        windows.sort_by_key(|t| (t.island.get(), t.id));
        let area = {
            let l = self.layout.borrow();
            l.named(&d).map(|b| self.usable.borrow().get(&d).copied().unwrap_or(b.rect()))
        };
        let (Some(area), false) = (area, windows.is_empty()) else {
            log(&format!("ebb {d}: nothing to show for {}", scope.as_str()));
            return;
        };
        let items: Vec<EbbItem> = windows.iter().map(|t| EbbItem { id: t.id, width: t.width(), height: t.height() }).collect();
        let placed = ebb_arrange(&items, area, 24);
        let slots: Vec<EbbSlot> = windows.iter().filter_map(|t| placed.iter().find(|(id, _)| *id == t.id).map(|(_, r)| EbbSlot { window: t.id, home: t.rect(), slot: *r })).collect();
        let ms = {
            let i = self.islands.borrow();
            if i.animate { i.slide_ms.min(2000) as u64 } else { 0 }
        };
        log(&format!("ebb {d} on {}: {} window(s)", scope.as_str(), slots.len()));
        for s in &slots {
            let key = windows.iter().find(|t| t.id == s.window).and_then(|t| t.place_key()).unwrap_or_else(|| "?".into());
            log(&format!("ebb-slot {key} {},{} {}x{}", s.slot.x, s.slot.y, s.slot.width, s.slot.height));
        }
        *self.ebb.borrow_mut() = Some(Ebb::new(&d, scope, slots, now, ms * 1_000_000));
        self.ebb_opens.set(self.ebb_opens.get() + 1);
    }

    /// The pointer moved, with Ebb open: which window it is over.
    pub fn ebb_hover(&self, x: f64, y: f64) {
        if let Some(e) = self.ebb.borrow_mut().as_mut() {
            e.hovered = e.slot_at(x, y).map(|s| s.window)
        }
    }

    /// A click, with Ebb open: on a window, go to it (its island first) and
    /// put the tide back; anywhere else, just put it back.
    pub fn ebb_click(&self, x: f64, y: f64) {
        let picked = {
            let e = self.ebb.borrow();
            let Some(e) = e.as_ref().filter(|e| !e.closing()) else { return };
            e.slot_at(x, y).map(|s| s.window)
        };
        // Bound first: a borrow in an `if let` lives through its body, and
        // bringing a window to front raises it (a mutable borrow).
        let window = picked.and_then(|id| self.toplevels.borrow().iter().find(|t| t.id == id).cloned());
        if let Some(t) = window {
            log(&format!("ebb picked {}", t.place_key().unwrap_or_else(|| "?".into())));
            self.bring_to_front(&t);
        }
        self.ebb_dismiss();
    }

    /// Escape, with Ebb open.
    pub fn ebb_dismiss(&self) {
        if let Some(e) = self.ebb.borrow_mut().as_mut()
            && !e.closing()
        {
            e.close(mono::now());
            log(&format!("ebb {} off", e.display));
        }
    }

    /// Ebb as display `d`'s scene should draw it at `now`; a finished close
    /// is forgotten here.
    pub fn ebb_frame(&self, d: &str, now: u64) -> Option<Ebb> {
        let mut ebb = self.ebb.borrow_mut();
        if ebb.as_ref().is_some_and(|e| e.finished(now)) {
            *ebb = None;
        }
        ebb.as_ref().filter(|e| e.display == d).cloned()
    }

    /// A window's Ebb label: its title (or app id), drawn when first asked
    /// and again when it changes.
    pub fn ebb_label(&self, t: &Toplevel) -> Option<Label> {
        let title = t.title().filter(|s| !s.is_empty()).or_else(|| t.app_id()).unwrap_or_default();
        if title.is_empty() {
            return None;
        }
        if let Some(l) = self.ebb_labels.borrow().get(&t.id)
            && l.title == title
        {
            return Some(l.label);
        }
        let l = self.draw_label(&title)?;
        let label = l.label;
        self.ebb_labels.borrow_mut().insert(t.id, l);
        Some(label)
    }

    /// White on a dark rounded plate, Exposé's way of saying which is which.
    fn draw_label(&self, title: &str) -> Option<OwnedLabel> {
        let mut runner = self.runner.borrow_mut();
        let runner = runner.as_mut()?;
        let size = 12.0;
        let tw = runner.text.text_width(title, size, Style::Bold, Role::Chrome);
        let (w, h) = ((tw + 24.0).min(480.0) as i32, 22);
        let cs = Surface::image(ffi::FORMAT_ARGB32, w, h);
        {
            let cr = Context::new(&cs);
            let r = h as f64 / 2.0;
            cr.new_path();
            cr.arc(r, r, r, PI / 2.0, 3.0 * PI / 2.0);
            cr.arc(w as f64 - r, r, r, 3.0 * PI / 2.0, PI / 2.0);
            cr.close_path();
            cr.set_source_rgba(0.0, 0.0, 0.0, 0.7);
            cr.fill();
            let fg = self.theme.borrow().tokens.menu_text_on_highlight;
            runner.text.draw_left(&cr, title, 12.0, 15.0, fg, size, Style::Bold, Role::Chrome);
        }
        cs.flush();
        let bytes: Vec<u8> = cs.argb_pixels(w, h).iter().flat_map(|p| p.to_ne_bytes()).collect();
        let texture: Texture = self.session.renderer().texture_from_pixels(ARGB8888, w as u32 * 4, w as u32, h as u32, &bytes)?;
        Some(OwnedLabel { label: Label { texture, width: w, height: h }, title: title.into() })
    }

    // MARK: shoals (P13.6)

    fn save_shoals(&self) {
        let _ = self.shoal_book.borrow().config().store("shoals", self.config_dir.as_deref());
    }

    fn focused_key(&self) -> Option<(Rc<Toplevel>, String)> {
        let t = self.focused()?;
        let k = t.place_key()?;
        Some((t, k))
    }

    /// Ctrl-Alt-N: a new shoal, of the focused window.
    pub fn new_shoal(&self) {
        let Some((t, k)) = self.focused_key() else { return };
        let d = t.island_display.borrow().clone();
        let i = self.shoal_book.borrow_mut().create(&k, &d, t.island.get() as i64);
        self.save_shoals();
        log(&format!("shoal {} made of {k} on {d} island {}", self.shoal_book.borrow().shoals[i].name, t.island.get()));
    }

    /// Ctrl-Alt-=: the focused window joins the current shoal (or `i`).
    pub fn add_focused_to_shoal(&self, i: Option<usize>) {
        let Some((_, k)) = self.focused_key() else { return };
        let mut book = self.shoal_book.borrow_mut();
        let Some(target) = i.or(book.current) else { return };
        if !book.add(&k, target) {
            return;
        }
        let Some(j) = book.shoal_of(&k) else { return };
        let (name, n) = (book.shoals[j].name.clone(), book.shoals[j].members.len());
        drop(book);
        self.save_shoals();
        log(&format!("shoal {name} + {k} ({n})"));
    }

    /// Ctrl-Alt--: the focused window leaves its shoal.
    pub fn remove_focused_from_shoal(&self) {
        let Some((_, k)) = self.focused_key() else { return };
        let mut book = self.shoal_book.borrow_mut();
        let Some(j) = book.shoal_of(&k) else { return };
        let name = book.shoals[j].name.clone();
        book.leave(&k);
        drop(book);
        self.save_shoals();
        log(&format!("shoal {name} − {k}"));
    }

    /// Ctrl-Shift-N: recall this island's Nth shoal (1-based).
    pub fn recall_shoal_number(&self, n: usize) {
        let d = self.command_display();
        let list = self.shoal_book.borrow().on_island(&d, self.active_island(&d) as i64);
        if n >= 1 && n <= list.len() {
            self.recall_shoal(list[n - 1])
        }
    }

    /// Bring a shoal back: its island, then every member that is open, back
    /// on that island, out of the Dock, at the place it was last left,
    /// raised together, the last focused. **Nothing else moves.**
    pub fn recall_shoal(&self, i: usize) {
        let Some(s) = self.shoal_book.borrow().shoals.get(i).cloned() else { return };
        if self.active_island(&s.display) as i64 != s.island {
            self.switch_island(s.island as i32, Some(&s.display));
        }
        let mut raised = vec![];
        for key in &s.members {
            let Some(t) = self.toplevels.borrow().iter().find(|t| t.mapped.get() && t.place_key().as_deref() == Some(key)).cloned() else { continue };
            if *t.island_display.borrow() == s.display && t.island.get() as i64 != s.island {
                t.island.set(s.island as i32);
                self.refresh_suspended(&t);
            }
            self.set_minimized(&t, false);
            if let Some(p) = self.places.borrow().place(key) {
                t.x.set(p.x);
                t.y.set(p.y);
            }
            self.raise(&t);
            raised.push(t);
        }
        if let Some(last) = raised.last() {
            self.focus(last)
        }
        self.shoal_book.borrow_mut().recalled(i);
        self.recalls.set(self.recalls.get() + 1);
        let keys: Vec<String> = raised.iter().filter_map(|t| t.place_key()).collect();
        log(&format!("shoal {} recalled: {}", s.name, keys.join(" ")));
    }

    /// A window mapped: if it is a member, its shoal has it back.
    pub fn shoal_rejoined(&self, t: &Toplevel) {
        let Some(k) = t.place_key() else { return };
        let book = self.shoal_book.borrow();
        if let Some(j) = book.shoal_of(&k) {
            log(&format!("shoal {} has {k} again", book.shoals[j].name));
        }
    }

    /// A shoal's name plate, drawn once per name.
    pub fn strip_label(&self, name: &str) -> Option<Label> {
        if let Some(l) = self.strip_labels.borrow().get(name) {
            return Some(l.label);
        }
        let l = self.draw_label(name)?;
        let label = l.label;
        self.strip_labels.borrow_mut().insert(name.into(), l);
        Some(label)
    }

    /// Ctrl-F3: show or hide the strip. Pinned, it stays; otherwise it goes
    /// when a shoal is recalled from it.
    pub fn toggle_shoal_strip(&self) {
        self.strip_shown.set(!self.strip_shown.get());
        log(&format!("shoal strip {}", if self.strip_shown.get() { "on" } else { "off" }));
        if self.strip_shown.get() {
            for (i, r) in self.strip_tiles(&self.command_display()) {
                let name = self.shoal_book.borrow().shoals[i].name.replace(' ', "_");
                log(&format!("shoal-tile {name} {},{} {}x{}", r.x, r.y, r.width, r.height));
            }
        }
    }

    /// The strip's tiles on display `d`: one per shoal of its island, top
    /// to bottom down the left edge.
    pub fn strip_tiles(&self, d: &str) -> Vec<(usize, Rect)> {
        let book = self.shoal_book.borrow();
        if !(self.strip_shown.get() || book.pinned) {
            return vec![];
        }
        let l = self.layout.borrow();
        let Some(b) = l.named(d) else { return vec![] };
        let area = self.usable.borrow().get(d).copied().unwrap_or(b.rect());
        book.on_island(d, self.active_island(d) as i64)
            .into_iter()
            .enumerate()
            .map(|(n, i)| (i, Rect::new(area.x + 12, area.y + 12 + n as i32 * (STRIP_TILE_HEIGHT + 16), STRIP_TILE_WIDTH, STRIP_TILE_HEIGHT)))
            .collect()
    }

    /// A click: on a tile, recall that shoal (and the strip goes, unless
    /// pinned). True if the strip took the click.
    pub fn strip_click(&self, x: f64, y: f64) -> bool {
        if !(self.strip_shown.get() || self.shoal_book.borrow().pinned) {
            return false;
        }
        let d = self.layout.borrow().display_at(x, y).map(|d| d.name.clone()).unwrap_or_default();
        for (i, r) in self.strip_tiles(&d) {
            if x >= r.x as f64 && x < (r.x + r.width) as f64 && y >= r.y as f64 && y < (r.y + r.height) as f64 {
                if !self.shoal_book.borrow().pinned {
                    self.strip_shown.set(false)
                }
                self.recall_shoal(i);
                return true;
            }
        }
        false
    }
}
