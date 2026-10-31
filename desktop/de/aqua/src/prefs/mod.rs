//! System Preferences (SystemPreferences.swift, P14.1): an application. The
//! grid, the toolbar's favourites and Show All, a page per pane, the menus
//! a Jaguar application publishes, and for every pane a line saying what it
//! cannot do yet, or what failed, in words.
//!
//! **One layout, read by the painter and the hit-test** (§2.9). Where Swift
//! kept every pane's state and handlers in one class, here each pane is a
//! module behind [`Pane`]: its state, its paint, its input, and the line
//! it publishes for a test to click by (`ABYSS_PREFS_DUMP`).

pub mod app;
pub mod appearance_catalogue;
pub mod displays;
pub mod energy;
pub mod general;
pub mod islands;
pub mod settings_client;
pub mod sound;

use crate::toolkit::Toolkit;
use aquadraw::canvas::Canvas;
use aquadraw::draw::paint_window_chrome;
use aquadraw::drawlist::{DrawState, Role};
use aquadraw::runner::Rect;
use aquadraw::text::Style;
use menu_model::{Command, KeyEquivalent, Menu, MenuBarModel, MenuItem, Modifiers};
use std::cell::RefCell;
use std::rc::Rc;
use surface::{Display, KeyEvent};

/// One preference pane, as the grid shows it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct PrefPane {
    /// Stable: the icon set's name (`icon.<id>`).
    pub id: &'static str,
    pub title: &'static str,
    /// What it will do, for its page and a reader that cannot see it.
    pub purpose: &'static str,
}

const fn p(id: &'static str, title: &'static str, purpose: &'static str) -> PrefPane {
    PrefPane { id, title, purpose }
}

/// Jaguar's panes in Jaguar's sections, less the four with nothing to be
/// here (Classic, QuickTime, Speech, ColorSync), and with Islands.
pub const SECTIONS: [(&str, &[PrefPane]); 4] = [
    (
        "Personal",
        &[
            p("desktop", "Desktop", "The picture on your desktop."),
            p("dock", "Dock", "Where the Dock sits, and how it magnifies."),
            p("general", "General", "Appearance: the theme, its colours and its settings."),
            p("international", "International", "Languages, formats and input sources."),
            p("islands", "Islands", "Islands, Ebb and Shoals: how many, the slide, and the keys."),
            p("loginItems", "Login Items", "What opens when you log in."),
            p("myAccount", "My Account", "Your name, picture and password."),
            p("screenEffects", "Screen Effects", "What the screen shows while you are away."),
        ],
    ),
    (
        "Hardware",
        &[
            p("cdsDvds", "CDs & DVDs", "What happens when a disc is inserted."),
            p("displays", "Displays", "Resolution, arrangement and scale of each display."),
            p("energySaver", "Energy Saver", "When the display and the computer sleep."),
            p("keyboard", "Keyboard", "Key repeat, layouts and shortcuts."),
            p("mouse", "Mouse", "Tracking and scrolling speed."),
            p("sound", "Sound", "Output device, volume and alerts."),
        ],
    ),
    (
        "Internet & Network",
        &[p("internetIcon", "Internet", "Your default browser and mail."), p("network", "Network", "Wired and wireless connections, addresses and DNS."), p("sharing", "Sharing", "What this computer offers to others.")],
    ),
    (
        "System",
        &[
            p("accounts", "Accounts", "Who can log in to this computer."),
            p("agents", "Agents", "What agents did, and the files given to confined applications."),
            p("dateTime", "Date & Time", "The clock, the time zone and network time."),
            p("softwareUpdate", "Software Update", "Updates to AbyssBSD."),
            p("startupDisk", "Startup Disk", "The disk this computer starts from."),
            p("universalAccess", "Universal Access", "Seeing, hearing and typing help."),
        ],
    ),
];

/// The toolbar's favourites, after Show All.
pub const TOOLBAR: [&str; 4] = ["displays", "sound", "network", "startupDisk"];

pub fn all_panes() -> impl Iterator<Item = &'static PrefPane> {
    SECTIONS.iter().flat_map(|(_, ps)| ps.iter())
}

pub fn pane_info(id: &str) -> Option<&'static PrefPane> {
    all_panes().find(|p| p.id == id)
}

/// What a page says its pane does, until it says what failed.
pub fn default_note(id: &str) -> &'static str {
    match id {
        "general" => "Choose the theme, its scheme and its settings.",
        "network" => "A wired interface's address, by DHCP or by hand, and the name servers.",
        "sound" => "The output device, its levels and mute, and who is playing.",
        "displays" => "Arrange the displays, and choose each one's resolution and scale.",
        "energySaver" => "When the computer and the display sleep, and how the processor saves power.",
        "islands" => "How many islands each display has, whether a switch slides, and the keys.",
        "accounts" => "Who can log in, who administers this computer, and who logs in automatically.",
        "agents" => "What each agent session did, and the files given to confined applications, with Revoke.",
        _ => "This pane cannot change anything yet.",
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum PrefsView {
    All,
    Pane(String),
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PrefsModel {
    pub view: PrefsView,
    /// The grid cell the keyboard is on.
    pub focus: Option<String>,
}

impl Default for PrefsModel {
    fn default() -> PrefsModel {
        PrefsModel { view: PrefsView::All, focus: None }
    }
}

impl PrefsModel {
    pub fn title(&self) -> &'static str {
        match &self.view {
            PrefsView::Pane(id) => pane_info(id).map_or("System Preferences", |p| p.title),
            PrefsView::All => "System Preferences",
        }
    }

    /// Arrows on the grid: across a row, then into the next section, as if
    /// the sections were one list.
    pub fn move_focus(&mut self, delta: i64) {
        let ids: Vec<&str> = all_panes().map(|p| p.id).collect();
        let at = self.focus.as_deref().and_then(|f| ids.iter().position(|i| *i == f));
        self.focus = Some(match at {
            None => ids[if delta < 0 { ids.len() - 1 } else { 0 }],
            Some(i) => ids[(i as i64 + delta).clamp(0, ids.len() as i64 - 1) as usize],
        }
        .to_string())
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct PrefsCell {
    pub pane: &'static str,
    pub icon: Rect,
    /// The icon and its label.
    pub hit: Rect,
    pub label_cx: f64,
    pub label_top: f64,
    pub label_max: f64,
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct PrefsLayout {
    pub toolbar: Rect,
    pub show_all: Rect,
    pub toolbar_items: Vec<PrefsCell>,
    /// Title, x, baseline.
    pub section_titles: Vec<(&'static str, f64, f64)>,
    pub cells: Vec<PrefsCell>,
    pub rules: Vec<Rect>,
    pub body: Rect,
}

/// Where everything in the window goes, at `w`×`h`.
pub fn prefs_layout(title_bar: f64, w: f64, h: f64) -> PrefsLayout {
    let (tb_y, tb_h) = (title_bar, 58.0);
    let top = tb_y + 6.0;
    let item = |id: &'static str, cx: f64| PrefsCell { pane: id, icon: Rect::new(cx - 16.0, top, 32.0, 32.0), hit: Rect::new(cx - 32.0, top, 64.0, 50.0), label_cx: cx, label_top: top + 42.0, label_max: 64.0 };
    let mut l = PrefsLayout { toolbar: Rect::new(0.0, tb_y, w, tb_h), show_all: Rect::new(12.0, top, 64.0, 50.0), body: Rect::new(0.0, tb_y + tb_h, w, h - tb_y - tb_h), ..PrefsLayout::default() };
    l.toolbar_items = TOOLBAR.iter().enumerate().map(|(i, id)| item(id, 130.0 + i as f64 * 70.0)).collect();
    let (margin, cols, row_h) = (24.0, 7, 80.0);
    let cell_w = (w - 2.0 * margin) / cols as f64;
    let mut y = tb_y + tb_h + 16.0;
    for (title, panes) in SECTIONS {
        l.section_titles.push((title, margin, y + 12.0));
        y += 24.0;
        for (i, p) in panes.iter().enumerate() {
            let cx = margin + (i % cols) as f64 * cell_w + cell_w / 2.0;
            let iy = y + (i / cols) as f64 * row_h;
            // 1 pt apart: cells that touched overlapped by a rounding error,
            // and a click on the seam was anyone's.
            l.cells.push(PrefsCell { pane: p.id, icon: Rect::new(cx - 24.0, iy, 48.0, 48.0), hit: Rect::new(cx - cell_w / 2.0 + 1.0, iy, cell_w - 2.0, row_h - 8.0), label_cx: cx, label_top: iy + 54.0, label_max: cell_w - 6.0 });
        }
        y += panes.len().div_ceil(cols) as f64 * row_h + 6.0;
        if title != "System" {
            l.rules.push(Rect::new(margin, y, w - 2.0 * margin, 1.0));
            y += 14.0;
        }
    }
    l
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum PrefsHit {
    ShowAll,
    Pane(&'static str),
}

/// What a click means; the grid answers only while it shows.
pub fn prefs_hit(l: &PrefsLayout, m: &PrefsModel, x: f64, y: f64) -> Option<PrefsHit> {
    if l.show_all.contains(x, y) {
        return Some(PrefsHit::ShowAll);
    }
    if let Some(t) = l.toolbar_items.iter().find(|t| t.hit.contains(x, y)) {
        return Some(PrefsHit::Pane(t.pane));
    }
    if m.view != PrefsView::All {
        return None;
    }
    l.cells.iter().find(|c| c.hit.contains(x, y)).map(|c| PrefsHit::Pane(c.pane))
}

/// "0.60": a setting's value as the panes show it.
pub fn two_places(v: f64) -> String {
    let c = (v.abs() * 100.0).round() as i64;
    format!("{}{}.{:02}", if v < 0.0 { "-" } else { "" }, c / 100, c % 100)
}

/// The centre of a rect, as the layout lines say it.
pub fn at(r: &Rect) -> String {
    format!("{},{}", (r.x + r.w / 2.0) as i64, (r.y + r.h / 2.0) as i64)
}

/// A track as the layout lines say it: `x0-x1,y`.
pub fn track(r: &Rect) -> String {
    format!("{}-{},{}", r.x as i64, (r.x + r.w) as i64, (r.y + r.h / 2.0) as i64)
}

/// What a pane is given: the display (None in a PNG), the toolkit, and a
/// way to ask for a redraw.
pub struct PrefsHost {
    pub display: Option<Rc<Display>>,
    pub toolkit: Rc<Toolkit>,
    redraw: RefCell<Option<Rc<dyn Fn()>>>,
}

impl PrefsHost {
    pub fn new(display: Option<Rc<Display>>, toolkit: &Rc<Toolkit>) -> PrefsHost {
        PrefsHost { display, toolkit: toolkit.clone(), redraw: RefCell::new(None) }
    }
    pub fn on_redraw(&self, f: impl Fn() + 'static) {
        *self.redraw.borrow_mut() = Some(Rc::new(f))
    }
    pub fn redraw(&self) {
        let f = self.redraw.borrow().clone();
        if let Some(f) = f {
            f()
        }
    }
}

pub fn log(s: &str) {
    eprintln!("SystemPreferences: {s}")
}

/// A pane: its state, its page, its input. Methods take `&self`; a pane
/// keeps its state in cells. `press` says whether it took the click (else
/// the toolbar may); `release` whether a drag of its ended.
pub trait Pane {
    fn id(&self) -> &'static str;
    /// What failed, said on the page in place of its description.
    fn note(&self) -> Option<String> {
        None
    }
    /// Shown: read what it shows.
    fn shown(&self, _h: &Rc<PrefsHost>) {}
    /// Another view replaced it.
    fn hidden(&self, _h: &Rc<PrefsHost>) {}
    fn paint(&self, c: &mut Canvas, body: Rect);
    /// Its controls as a layout line, when they moved since last said.
    fn dump(&self) -> Vec<String> {
        vec![]
    }
    fn pointer_moved(&self, _h: &Rc<PrefsHost>, _x: f64, _y: f64) {}
    fn press(&self, _h: &Rc<PrefsHost>, _x: f64, _y: f64) -> bool {
        false
    }
    fn release(&self, _h: &Rc<PrefsHost>) -> bool {
        false
    }
    fn key(&self, _h: &Rc<PrefsHost>, _e: &KeyEvent) {}
    /// Escape is the pane's (a sheet is open), not Show All's.
    fn keeps_escape(&self) -> bool {
        false
    }
}

/// The window's contents: chrome, toolbar, then the grid or a pane.
pub fn paint_system_preferences(c: &mut Canvas, w: f64, h: f64, m: &PrefsModel, panes: &[Rc<dyn Pane>]) -> PrefsLayout {
    let t = c.theme.tokens.clone();
    let l = prefs_layout(t.title_bar_height, w, h);
    paint_window_chrome(c.runner, c.theme, c.cr, w, h, m.title(), false, true);
    c.paint_simple("prefs.toolbar", l.toolbar, DrawState::NORMAL);
    toolbar_item(c, "showAll", "Show All", 44.0, l.show_all.y);
    c.paint("prefs.toolbar.divider", l.toolbar, aquadraw::canvas::Paint { parameters: &[("x", 86.0)], ..Default::default() });
    for ti in &l.toolbar_items {
        if let Some(p) = pane_info(ti.pane) {
            toolbar_item(c, p.id, p.title, ti.label_cx, ti.icon.y)
        }
    }
    match &m.view {
        PrefsView::All => {
            for (title, x, baseline) in &l.section_titles {
                c.text_left(title, *x, *baseline, t.section_title_text, 13.0, Style::Regular, Role::Interface)
            }
            for cell in &l.cells {
                let Some(p) = pane_info(cell.pane) else { continue };
                if m.focus.as_deref() == Some(cell.pane) {
                    c.focus_ring(Rect::new(cell.icon.x - 4.0, cell.icon.y - 4.0, cell.icon.w + 8.0, cell.icon.h + 8.0), 8.0)
                }
                c.icon(&format!("icon.{}", p.id), cell.icon);
                centered_label(c, p.title, cell.label_cx, cell.label_top, cell.label_max)
            }
            for r in &l.rules {
                c.paint_simple("rule", *r, DrawState::NORMAL)
            }
        }
        PrefsView::Pane(id) => match panes.iter().find(|p| p.id() == id) {
            Some(pane) => pane.paint(c, l.body),
            None => paint_page(c, &l, id, None),
        },
    }
    l
}

/// A pane with nothing behind it yet: what it is for, and that it cannot
/// change anything, honestly.
pub fn paint_page(c: &mut Canvas, l: &PrefsLayout, id: &str, note: Option<String>) {
    let Some(p) = pane_info(id) else { return };
    let t = c.theme.tokens.clone();
    let (cx, top) = (l.body.x + l.body.w / 2.0, l.body.y + 40.0);
    c.icon(&format!("icon.{}", p.id), Rect::new(cx - 32.0, top, 64.0, 64.0));
    c.text(p.title, cx, top + 88.0, t.body_text, 15.0, Style::Bold, Role::Interface);
    c.text(p.purpose, cx, top + 114.0, t.secondary_text, 12.0, Style::Regular, Role::Interface);
    c.text(&note.unwrap_or_else(|| default_note(id).into()), cx, top + 144.0, t.body_text, 13.0, Style::Regular, Role::Interface)
}

fn toolbar_item(c: &mut Canvas, icon: &str, label: &str, cx: f64, top: f64) {
    c.icon(&format!("icon.{icon}"), Rect::new(cx - 16.0, top, 32.0, 32.0));
    let k = c.theme.tokens.toolbar_label_text;
    c.text(label, cx, top + 42.0, k, 10.0, Style::Regular, Role::Interface)
}

/// A centred label, in two balanced lines at a space when it does not fit.
fn centered_label(c: &mut Canvas, s: &str, cx: f64, top: f64, max: f64) {
    let size = 11.0;
    let k = c.theme.tokens.icon_label_text;
    if c.text_width(s, size, Style::Regular, Role::Interface) <= max {
        return c.text(s, cx, top + size / 2.0, k, size, Style::Regular, Role::Interface);
    }
    let words: Vec<&str> = s.split(' ').filter(|w| !w.is_empty()).collect();
    let (first, second) = if words.len() <= 1 {
        (s.to_string(), String::new())
    } else {
        let mid = words.len().div_ceil(2);
        (words[..mid].join(" "), words[mid..].join(" "))
    };
    c.text(&first, cx, top + size / 2.0, k, size, Style::Regular, Role::Interface);
    if !second.is_empty() {
        c.text(&second, cx, top + size * 1.5 + 1.0, k, size, Style::Regular, Role::Interface)
    }
}

// MARK: the vocabulary (Phase 10)

pub const VERB_ABOUT: &str = "app.about";
pub const VERB_QUIT: &str = "app.quit";
pub const VERB_SHOW_ALL: &str = "view.showAll";
pub const VERB_MINIMIZE: &str = "window.minimize";
pub const VERB_CLOSE: &str = "window.close";

/// `view.pane.<id>`: one per pane, as Jaguar's View menu lists them.
pub fn pane_verb(id: &str) -> String {
    format!("view.pane.{id}")
}

pub fn verb_pane(verb: &str) -> Option<&str> {
    verb.strip_prefix("view.pane.")
}

pub fn system_preferences_menu_bar() -> MenuBarModel {
    let c = |v: &str, t: &str, k: Option<KeyEquivalent>, s: &str| {
        let cmd = Command::new(v, t, s);
        MenuItem::Command(match k {
            Some(k) => cmd.with_key(k),
            None => cmd,
        })
    };
    let key = |ch| Some(KeyEquivalent::cmd(ch, Modifiers::NONE));
    let mut view = vec![c(VERB_SHOW_ALL, "Show All Preferences", key('l'), "Show every pane.")];
    for (_, panes) in SECTIONS {
        view.push(MenuItem::Separator);
        for p in panes {
            view.push(c(&pane_verb(p.id), p.title, None, &format!("Open the {} pane.", p.title)))
        }
    }
    MenuBarModel::new(
        "System Preferences",
        vec![
            Menu::new("System Preferences", vec![c(VERB_ABOUT, "About System Preferences", None, "Show System Preferences' version."), MenuItem::Separator, c(VERB_QUIT, "Quit System Preferences", key('q'), "Close System Preferences.")]),
            Menu::new("View", view),
            Menu::new("Window", vec![c(VERB_MINIMIZE, "Minimize", key('m'), "Put the window in the Dock."), c(VERB_CLOSE, "Close", key('w'), "Close the window.")]),
        ],
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_cell_is_hit_where_it_is_drawn_and_the_seams_are_nobodys() {
        let l = prefs_layout(22.0, 760.0, 620.0);
        let m = PrefsModel::default();
        assert_eq!(l.cells.len(), all_panes().count());
        for c in &l.cells {
            assert_eq!(prefs_hit(&l, &m, c.icon.x + c.icon.w / 2.0, c.icon.y + c.icon.h / 2.0), Some(PrefsHit::Pane(c.pane)))
        }
        let shown = PrefsModel { view: PrefsView::Pane("sound".into()), focus: None };
        let c = &l.cells[0];
        assert_eq!(prefs_hit(&l, &shown, c.icon.x + 1.0, c.icon.y + 1.0), None, "the grid answers only while it shows");
        assert_eq!(prefs_hit(&l, &shown, 44.0, l.show_all.y + 10.0), Some(PrefsHit::ShowAll));
    }

    #[test]
    fn focus_walks_the_sections_as_one_list() {
        let mut m = PrefsModel::default();
        m.move_focus(1);
        assert_eq!(m.focus.as_deref(), Some("desktop"));
        m.move_focus(-1);
        assert_eq!(m.focus.as_deref(), Some("desktop"), "clamped");
        m.move_focus(8);
        assert_eq!(m.focus.as_deref(), Some("cdsDvds"));
    }

    #[test]
    fn the_view_menu_has_every_pane() {
        let m = system_preferences_menu_bar();
        let verbs: Vec<String> = m.commands().into_iter().map(|c| c.verb.clone()).collect();
        for p in all_panes() {
            assert!(verbs.contains(&pane_verb(p.id)))
        }
        assert!(m.conflicting_keys().is_empty());
        assert_eq!(verb_pane("view.pane.sound"), Some("sound"));
    }

    #[test]
    fn a_value_is_shown_to_two_places() {
        assert_eq!(two_places(0.6), "0.60");
        assert_eq!(two_places(1.0), "1.00");
        assert_eq!(two_places(2.456), "2.46");
        assert_eq!(two_places(0.05), "0.05");
    }
}
