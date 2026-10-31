//! The magnifying Jaguar Dock (Dock.swift): a BOTTOM layer surface, a
//! translucent shelf of tiles that swell under the pointer, a running mark
//! under open applications, and the Trash at the right. The curve is a
//! pure function (`dock_magnify`) shared by paint and hit-test. Running
//! applications come from foreign toplevels; a click raises one, or starts
//! it. Icons are original glyphs from the theme, not Apple's art.
//!
//! The `dock` domain: `apps` (the pinned tiles, `;`-separated), `tile_size`
//! (default 48), `magnify` (default true).

use crate::agent_presence::{self, AgentBadge};
use crate::app_icon;
use crate::app_library::{self, InstalledApp};
use crate::context_menu::open_context_menu;
use crate::finder_model::finder_parent;
use crate::finder_ops::{finder_empty_trash, finder_exists, finder_is_directory, finder_move_to_trash, finder_trash_contents, finder_trash_directory, finder_trash_path};
use crate::launcher::{self, recent};
use crate::live_menu::LiveMenu;
use crate::toolkit::Toolkit;
use app_bundles::BUILTIN_APPS;
use aquadraw::canvas::{Canvas, Paint};
use aquadraw::drawlist::{DrawState, Role};
use aquadraw::runner::Rect;
use aquadraw::text::Style;
use aquadraw::tokens::ThemeTokens;
use menu_model::{Command, Enablement, Menu, MenuItem};
use std::cell::RefCell;
use std::os::fd::AsRawFd;
use std::rc::{Rc, Weak};
use surface::clipboard::mime;
use surface::layer::{anchor, KeyboardInteractivity, Layer};
use surface::{Display, ForeignToplevels, LayerConfig, LayerSurface, LayerSurfaceDelegate, PopupDelegate, RenderTarget, ToplevelInfo};

const BTN_LEFT: u32 = 0x110;
const BTN_RIGHT: u32 = 0x111;

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum DockIcon {
    /// The theme's `dock.icon.NAME`.
    Theme(String),
    /// An installed application's own icon (P15.2).
    Bundle(String),
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DockItem {
    pub icon: DockIcon,
    pub label: String,
    /// What a running toplevel's app_id matches; None for the Trash.
    pub app_id: Option<String>,
    /// Every app_id this tile's windows may carry: a bundle's
    /// `Contents/app-id`, or just `app_id`.
    pub app_ids: Vec<String>,
    /// The `dock.ini` entry that pinned it; None for a tile there only
    /// because its application runs.
    pub pin_token: Option<String>,
    /// The bundle it opens, for Recent Items.
    pub bundle: Option<String>,
    pub is_trash: bool,
    /// What to run when it is not running, and environment to add.
    pub command: Option<Vec<String>>,
    pub environment: Vec<(String, String)>,
}

impl DockItem {
    fn new(icon: DockIcon, label: &str, app_id: Option<&str>) -> DockItem {
        DockItem { icon, label: label.into(), app_id: app_id.map(String::from), app_ids: app_id.map_or(vec![], |a| vec![a.into()]), pin_token: None, bundle: None, is_trash: false, command: None, environment: vec![] }
    }

    pub fn trash(full: bool) -> DockItem {
        DockItem { is_trash: true, ..DockItem::new(DockIcon::Theme(if full { "trashFull" } else { "trash" }.into()), "Trash", None) }
    }

    /// An installed application's tile.
    pub fn app(app: &InstalledApp, pin_token: Option<&str>) -> DockItem {
        let ids = if app.app_ids.is_empty() { vec![app.name.clone()] } else { app.app_ids.clone() };
        DockItem {
            command: app.executable.clone().map(|e| vec![e]),
            app_ids: ids.clone(),
            pin_token: pin_token.map(String::from),
            bundle: Some(app.bundle.clone()),
            ..DockItem::new(DockIcon::Bundle(app.icon.clone().unwrap_or_default()), &app.name, Some(ids.first().unwrap_or(&app.name)))
        }
    }

    /// An installed application's own, not this program in a scene.
    pub fn is_bundle(&self) -> bool {
        matches!(self.icon, DockIcon::Bundle(_))
    }

    /// Whether a running window is this tile's.
    pub fn owns(&self, app_id: &str) -> bool {
        !self.is_trash && app_bundles::matches(app_id, &self.app_ids)
    }
}

/// One tile's place: its centre x, its (magnified) size and scale.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct DockTileFrame {
    pub center_x: f64,
    pub size: f64,
    pub scale: f64,
}

/// The surface's height: room for a fully magnified tile.
pub fn dock_surface_height(t: &ThemeTokens, tile: f64) -> f64 {
    (tile * t.dock_max_scale + 2.0 * t.dock_panel_pad_v + t.dock_bottom_margin + 20.0).ceil()
}

/// The magnification, the Dock's defining curve. Distances are measured on
/// the fixed rest layout, then the tiles are laid out again at their sizes,
/// centred on `center_x`. No pointer: at rest.
pub fn dock_magnify(count: usize, s: f64, g: f64, center_x: f64, pointer_x: Option<f64>, max_scale: f64, range: f64) -> Vec<DockTileFrame> {
    if count == 0 {
        return vec![];
    }
    let base_left = center_x - (count as f64 * s + (count - 1) as f64 * g) / 2.0;
    let scales: Vec<f64> = (0..count)
        .map(|i| {
            let Some(px) = pointer_x else { return 1.0 };
            let t = (base_left + i as f64 * (s + g) + s / 2.0 - px).abs() / range;
            if t < 1.0 { 1.0 + (max_scale - 1.0) * ((std::f64::consts::PI * t).cos() + 1.0) / 2.0 } else { 1.0 }
        })
        .collect();
    let total = scales.iter().map(|k| s * k).sum::<f64>() + (count - 1) as f64 * g;
    let mut left = center_x - total / 2.0;
    scales
        .into_iter()
        .map(|k| {
            let size = s * k;
            let f = DockTileFrame { center_x: left + size / 2.0, size, scale: k };
            left += size + g;
            f
        })
        .collect()
}

fn draw_dock_icon(c: &mut Canvas, icon: &DockIcon, r: Rect) {
    let name = match icon {
        DockIcon::Bundle(path) if !path.is_empty() && app_icon::draw(c, path, r) => return,
        DockIcon::Bundle(_) => "genericApp",
        DockIcon::Theme(n) => n,
    };
    // A tile never goes blank: the generic icon for one the theme lacks.
    let list = format!("dock.icon.{name}");
    let list = if c.theme.lists.get(&list).is_some() { list } else { "dock.icon.genericApp".into() };
    c.icon(&list, r)
}

/// The Agent tile's badge (P18.13b), Mail's: sessions waiting, or "…"
/// while one works.
fn paint_agent_badge(c: &mut Canvas, badge: AgentBadge, tile: Rect) {
    let t = c.theme.tokens.clone();
    let (text, color) = match badge {
        AgentBadge::None => return,
        AgentBadge::Working => ("…".to_string(), t.dock_badge_working),
        AgentBadge::Waiting(n) => (if n > 99 { "99+".into() } else { n.to_string() }, t.dock_badge_waiting),
    };
    let d = (tile.w * 0.38).max(18.0);
    let w = d.max(c.text_width(&text, d * 0.62, Style::Bold, Role::Interface) + d * 0.5);
    let r = Rect::new(tile.x + tile.w - w + d * 0.15, tile.y - d * 0.15, w, d);
    c.paint("dock.badge", r, Paint { colors: &[("c", color)], ..Paint::default() });
    c.text(&text, r.x + r.w / 2.0, r.y + r.h / 2.0, t.dock_badge_text, d * 0.62, Style::Bold, Role::Interface)
}

fn draw_dock_label(c: &mut Canvas, text: &str, cx: f64, bottom: f64) {
    let tw = c.text_width(text, 12.0, Style::Regular, Role::Interface);
    let (pad, h) = (8.0, 20.0);
    let b = Rect::new(cx - tw / 2.0 - pad, bottom - h, tw + 2.0 * pad, h);
    c.paint_simple("dock.label", b, DrawState::NORMAL);
    let k = c.theme.tokens.dock_label_text;
    c.text(text, cx, b.y + h / 2.0, k, 12.0, Style::Regular, Role::Interface)
}

/// Paint the Dock; the frames, for hit-testing.
#[allow(clippy::too_many_arguments)]
pub fn paint_dock(c: &mut Canvas, w: f64, h: f64, items: &[DockItem], running: &[bool], pointer_x: Option<f64>, tile: f64, magnify: bool, badge: AgentBadge) -> Vec<DockTileFrame> {
    let t = c.theme.tokens.clone();
    let frames = dock_magnify(items.len(), tile, t.dock_gap, w / 2.0, pointer_x.filter(|_| magnify), t.dock_max_scale, 2.2 * (tile + t.dock_gap));
    let (Some(first), Some(last)) = (frames.first(), frames.last()) else { return frames };
    let panel_bottom = h - t.dock_bottom_margin;
    let icon_bottom = panel_bottom - t.dock_panel_pad_v;
    let panel_h = tile + 2.0 * t.dock_panel_pad_v;
    let left = first.center_x - first.size / 2.0 - t.dock_panel_pad_h;
    let right = last.center_x + last.size / 2.0 + t.dock_panel_pad_h;
    let panel = Rect::new(left, panel_bottom - panel_h, right - left, panel_h);
    c.paint_simple("dock.shelf", panel, DrawState::NORMAL);
    // A separator just before the Trash.
    if let Some(ti) = items.iter().position(|i| i.is_trash).filter(|i| *i > 0) {
        let (a, b) = (frames[ti - 1], frames[ti]);
        let sx = (a.center_x + a.size / 2.0 + b.center_x - b.size / 2.0) / 2.0;
        c.paint("dock.separator", panel, Paint { parameters: &[("x", sx - panel.x)], ..Paint::default() });
    }
    for (i, item) in items.iter().enumerate() {
        let f = frames[i];
        let r = Rect::new(f.center_x - f.size / 2.0, icon_bottom - f.size, f.size, f.size);
        draw_dock_icon(c, &item.icon, r);
        if running[i] {
            // Jaguar's running mark: a small triangle under the tile.
            c.paint_simple("dock.running", Rect::new(f.center_x - 3.0, panel_bottom - 7.0, 6.0, 4.0), DrawState::NORMAL)
        }
        if item.app_id.as_deref() == Some("org.abyssbsd.agent") {
            paint_agent_badge(c, badge, r)
        }
    }
    // Label the most magnified tile, above it.
    if magnify
        && pointer_x.is_some()
        && let Some(hi) = (0..frames.len()).max_by(|a, b| frames[*a].scale.total_cmp(&frames[*b].scale))
        && frames[hi].scale > 1.15
    {
        draw_dock_label(c, &items[hi].label, frames[hi].center_x, icon_bottom - frames[hi].size - 8.0)
    }
    frames
}

// MARK: what is pinned

/// A built-in's tile, by its token: this program in a scene.
fn builtin_item(token: &str) -> Option<DockItem> {
    let b = BUILTIN_APPS.iter().find(|b| b.token == token)?;
    Some(DockItem {
        command: launcher::self_executable().map(|e| vec![e]),
        environment: vec![("AQUA_SCENE".into(), b.scene.into())],
        pin_token: Some(token.into()),
        ..DockItem::new(DockIcon::Theme(b.icon.into()), b.name, Some(b.app_id))
    })
}

/// The built-in tile a running window of the desktop's own wears when it
/// is not pinned, by app ID: no pin token, so it leaves when it quits.
pub fn builtin_running(app_id: &str) -> Option<DockItem> {
    let b = BUILTIN_APPS.iter().find(|b| b.app_id == app_id)?;
    builtin_item(b.token).map(|i| DockItem { pin_token: None, ..i })
}

/// `dock.ini`'s entries, or the default ones: the Finder, a browser if one
/// is installed, Terminal, Agent (left out while agents are off) and System
/// Preferences.
pub fn pin_tokens(setting: Option<&str>, library: &[InstalledApp]) -> Vec<String> {
    let Some(s) = setting else {
        let mut out = vec!["finder".to_string()];
        if let Some(b) = library.iter().find(|a| a.matches("firefox") || a.name.starts_with("Firefox")) {
            out.push(b.name.clone())
        }
        out.extend(["terminal", "agent", "sysprefs"].map(String::from));
        return out;
    };
    s.split(';').map(|t| t.trim_matches([' ', '\t']).to_string()).filter(|t| !t.is_empty()).collect()
}

/// The tiles for those entries. One naming a bundle not installed has no
/// tile but keeps its place, so a reinstalled application comes back where
/// it was. No Agent tile while agents are off.
pub fn items(tokens: &[String], library: &[InstalledApp], agents_on: bool) -> Vec<DockItem> {
    tokens
        .iter()
        .filter_map(|t| {
            if t == "agent" && !agents_on {
                return None;
            }
            if let Some(i) = builtin_item(t) {
                return Some(i);
            }
            match app_library::find(t, library) {
                Some(app) => Some(DockItem::app(app, Some(t))),
                None => {
                    log(&format!("dock.ini names {t}, which is not installed"));
                    None
                }
            }
        })
        .collect()
}

/// The entry that pins a bundle: its name when that finds it again (so one
/// regenerated or moved stays pinned), else its path. A built-in's bundle
/// pins the built-in.
pub fn pin_token_for_bundle(path: &str, library: &[InstalledApp]) -> String {
    if let Some(token) = app_library::marker(path).and_then(|m| m.strip_prefix("builtin:").map(|t| t.trim_end_matches('\n').to_string()))
        && BUILTIN_APPS.iter().any(|b| b.token == token)
    {
        return token;
    }
    let base = path.rsplit('/').next().unwrap_or(path);
    let name = base.strip_suffix(".app").unwrap_or(base);
    if app_library::find(name, library).is_some_and(|a| a.bundle == path) { name.into() } else { path.into() }
}

/// `tokens` with `token` before `before` (at the end without), moved, not
/// doubled.
pub fn pinning(token: &str, before: Option<&str>, tokens: &[String]) -> Vec<String> {
    let mut out: Vec<String> = tokens.iter().filter(|t| *t != token).cloned().collect();
    let at = before.and_then(|b| out.iter().position(|t| t == b)).unwrap_or(out.len());
    out.insert(at, token.into());
    out
}

/// The stock Dock: for the golden scene.
pub fn default_pinned(agents_on: bool) -> Vec<DockItem> {
    items(&pin_tokens(None, &[]), &[], agents_on)
}

/// A tile's menu: the Trash's two commands, or an application's: Open when
/// it is not running, Quit when it is (P10.8); a pinned tile removed (not
/// the Finder's), a running one kept (P15.2b).
pub fn tile_menu(is_trash: bool, running: bool, pinned: bool, removable: bool) -> Menu {
    let c = |v: &str, t: &str, s: &str| MenuItem::Command(Command::new(v, t, s));
    if is_trash {
        return Menu::new("Trash", vec![c("dock.open-trash", "Open", "Open the Trash in a Finder window."), c("dock.empty-trash", "Empty Trash", "Permanently delete everything in the Trash.")]);
    }
    let mut items = vec![if running { c("dock.quit", "Quit", "Ask this application to quit.") } else { c("dock.open", "Open", "Start this application.") }, MenuItem::Separator];
    match (pinned, removable) {
        (true, true) => items.push(c("dock.remove", "Remove from Dock", "Take this application's tile off the Dock.")),
        (false, true) => items.push(c("dock.keep", "Keep in Dock", "Leave this application's tile on the Dock when it quits.")),
        _ => {}
    }
    items.push(c("dock.show-in-finder", "Show In Finder", "Show where this application lives."));
    Menu::new("", items)
}

fn log(msg: &str) {
    eprintln!("Dock: {msg}")
}

struct State {
    pinned: Vec<DockItem>,
    pin_tokens: Vec<String>,
    /// Reread when windows come and go: at first login appgen may still be
    /// writing them.
    library: Vec<InstalledApp>,
    items: Vec<DockItem>,
    running: Vec<bool>,
    /// Running applications no pinned tile owns.
    extras: Vec<ToplevelInfo>,
    frames: Vec<DockTileFrame>,
    pointer: Option<(f64, f64)>,
    trash_full: bool,
    badge: AgentBadge,
    context: Option<Rc<LiveMenu>>,
    last_tiles: String,
}

pub struct Dock {
    me: Weak<Dock>,
    display: Rc<Display>,
    toolkit: Rc<Toolkit>,
    layer: RefCell<Option<Rc<LayerSurface>>>,
    toplevels: RefCell<Option<Rc<ForeignToplevels>>>,
    tile: f64,
    magnify: bool,
    state: RefCell<State>,
    watchers: RefCell<Vec<pool_config::Watcher>>,
}

impl Dock {
    pub fn new(display: &Rc<Display>, toolkit: &Rc<Toolkit>) -> Option<Rc<Dock>> {
        let config = pool_config::load("dock", None).unwrap_or_default();
        let tile = config.uint64("dock", "tile_size").unwrap_or(48) as f64;
        let library = app_library::all();
        let pin_tokens = pin_tokens(config.string("dock", "apps"), &library);
        let pinned = items(&pin_tokens, &library, pool_config::Agents::on(None));
        log(&format!("pinned {}", pinned.iter().map(|i| i.label.as_str()).collect::<Vec<_>>().join(", ")));
        let dock = Rc::new_cyclic(|me| Dock {
            me: me.clone(),
            display: display.clone(),
            toolkit: toolkit.clone(),
            layer: RefCell::new(None),
            toplevels: RefCell::new(None),
            tile,
            magnify: config.bool("dock", "magnify").unwrap_or(true),
            state: RefCell::new(State { pinned, pin_tokens, library, items: vec![], running: vec![], extras: vec![], frames: vec![], pointer: None, trash_full: !finder_trash_contents().is_empty(), badge: AgentBadge::None, context: None, last_tiles: String::new() }),
            watchers: RefCell::default(),
        });
        let height = dock_surface_height(&toolkit.theme.borrow().tokens, tile) as i32;
        let pinned_scale = std::env::var("AQUA_SCALE").ok().and_then(|s| s.parse::<i32>().ok()).filter(|v| *v > 0);
        let lc = LayerConfig { layer: Layer::Bottom, namespace: "abyss.dock".into(), height, anchor: anchor::BOTTOM | anchor::LEFT | anchor::RIGHT, exclusive_zone: 0, keyboard: KeyboardInteractivity::None, ..LayerConfig::default() };
        let ls = LayerSurface::new(display, &lc, pinned_scale.unwrap_or(1), pinned_scale.is_none(), Rc::downgrade(&dock) as Weak<dyn LayerSurfaceDelegate>)?;
        *dock.layer.borrow_mut() = Some(ls);
        log(&format!("Trash {}", if dock.state.borrow().trash_full { "full" } else { "empty" }));
        dock.rebuild();
        // Running applications, when the compositor offers them.
        let me = dock.me.clone();
        *dock.toplevels.borrow_mut() = ForeignToplevels::new(display, move |tops| {
            if let Some(d) = me.upgrade() {
                d.toplevels_changed(tops)
            }
        });
        // The Trash's tile follows ~/.Trash, with no polling.
        if let Some(dir) = finder_trash_path().filter(|d| finder_is_directory(d)) {
            dock.watch(Some(&dir), |d| d.trash_changed())
        }
        if let Some(dir) = agent_presence::io::dir() {
            dock.watch(Some(&dir), |d| d.presence_changed())
        }
        dock.presence_changed();
        dock.accept_drops();
        Some(dock)
    }

    fn watch(&self, dir: Option<&str>, f: fn(&Dock)) {
        let Ok(w) = pool_config::Watcher::new(dir) else { return };
        let fd = w.as_raw_fd();
        self.watchers.borrow_mut().push(w);
        let me = self.me.clone();
        self.display.add_fd(fd, move || {
            if let Some(d) = me.upgrade() {
                if let Some(w) = d.watchers.borrow().iter().find(|w| w.as_raw_fd() == fd) {
                    w.drain();
                }
                f(&d)
            }
        });
    }

    fn layer(&self) -> Option<Rc<LayerSurface>> {
        self.layer.borrow().clone()
    }

    fn redraw(&self) {
        if let Some(l) = self.layer() {
            l.set_needs_display()
        }
    }

    fn current(&self) -> Vec<ToplevelInfo> {
        self.toplevels.borrow().as_ref().map_or(vec![], |t| t.current())
    }

    /// Re-read the agents' presence; redraw if the badge moved.
    fn presence_changed(&self) {
        let badge = if pool_config::Agents::on(None) { AgentBadge::of(&agent_presence::io::read()) } else { AgentBadge::None };
        if badge == self.state.borrow().badge {
            return;
        }
        log(&format!("agent badge: {}", match badge {
            AgentBadge::None => "none".into(),
            AgentBadge::Working => "working".into(),
            AgentBadge::Waiting(n) => format!("waiting({n})"),
        }));
        self.state.borrow_mut().badge = badge;
        self.redraw()
    }

    fn trash_changed(&self) {
        let full = !finder_trash_contents().is_empty();
        if full == self.state.borrow().trash_full {
            return;
        }
        self.state.borrow_mut().trash_full = full;
        log(&format!("Trash is now {}", if full { "full" } else { "empty" }));
        self.rebuild();
        self.redraw()
    }

    fn toplevels_changed(&self, tops: &[ToplevelInfo]) {
        // A window gone may be an Agent window killed outright.
        self.presence_changed();
        let now = app_library::all();
        if now != self.state.borrow().library {
            let mut s = self.state.borrow_mut();
            s.library = now;
            s.pinned = items(&s.pin_tokens, &s.library, pool_config::Agents::on(None));
            log(&format!("pinned {}", s.pinned.iter().map(|i| i.label.as_str()).collect::<Vec<_>>().join(", ")));
        }
        {
            let mut s = self.state.borrow_mut();
            let mut seen = std::collections::HashSet::new();
            s.extras = tops.iter().filter(|t| !s.pinned.iter().any(|p| p.owns(&t.app_id)) && seen.insert(t.app_id.clone())).cloned().collect();
        }
        for t in tops {
            log(&format!("running {} '{}'", if t.app_id.is_empty() { "?" } else { &t.app_id }, t.title))
        }
        self.rebuild();
        self.redraw()
    }

    /// The tiles shown (pinned, running-unpinned, the Trash) and which run.
    fn rebuild(&self) {
        let current = self.current();
        let mut s = self.state.borrow_mut();
        let mut items = s.pinned.clone();
        let mut flags: Vec<bool> = s.pinned.iter().map(|i| current.iter().any(|t| i.owns(&t.app_id))).collect();
        for t in &s.extras {
            // A running application not pinned wears its bundle's icon and
            // name when it has one.
            let item = builtin_running(&t.app_id).unwrap_or_else(|| match app_library::owner(&t.app_id, &s.library) {
                Some(app) => DockItem { app_id: Some(t.app_id.clone()), app_ids: vec![t.app_id.clone()], pin_token: None, ..DockItem::app(app, None) },
                None => DockItem::new(DockIcon::Theme("genericApp".into()), if !t.title.is_empty() { &t.title } else if t.app_id.is_empty() { "App" } else { &t.app_id }, Some(&t.app_id)),
            });
            items.push(item);
            flags.push(true)
        }
        items.push(DockItem::trash(s.trash_full));
        flags.push(false);
        s.items = items;
        s.running = flags;
    }

    /// The tile under a point, by the frames the last paint drew:
    /// magnified tiles are not where the rest layout has them.
    fn tile_at(&self, x: f64, y: f64) -> Option<(usize, DockTileFrame)> {
        let h = self.layer().map_or(0, |l| l.size().1) as f64;
        let t = self.toolkit.theme.borrow().tokens.clone();
        let icon_bottom = h - t.dock_bottom_margin - t.dock_panel_pad_v;
        self.state.borrow().frames.iter().enumerate().find(|(_, f)| Rect::new(f.center_x - f.size / 2.0, icon_bottom - f.size, f.size, f.size).contains(x, y)).map(|(i, f)| (i, *f))
    }

    // MARK: drops (P9.3)

    /// Files dragged onto a tile. **A drag is a grab, so pointer events
    /// stop**: the drag's own motion feeds the magnification and the
    /// hit-test, so the tile that takes the drop is the one seen to grow.
    fn accept_drops(&self) {
        let Some(clip) = self.display.clipboard() else { return log("no data device — drops are off") };
        *clip.accepted_drag_types.borrow_mut() = vec![mime::URI_LIST.into(), mime::TEXT.into()];
        let ours = |d: &Dock, c: &surface::Clipboard| d.layer().is_some_and(|l| c.drag_position().0 == Some(l.surface));
        let (me, cw) = (self.me.clone(), Rc::downgrade(&clip));
        clip.on_drag_motion(move |x, y| {
            if let (Some(d), Some(c)) = (me.upgrade(), cw.upgrade())
                && ours(&d, &c)
            {
                d.pointer_at(Some((x, y)))
            }
        });
        let me = self.me.clone();
        clip.on_drag_leave(move || {
            if let Some(d) = me.upgrade() {
                d.pointer_at(None)
            }
        });
        let (me, cw) = (self.me.clone(), Rc::downgrade(&clip));
        clip.on_drop(move |_, bytes, x, y| {
            let (Some(d), Some(c)) = (me.upgrade(), cw.upgrade()) else { return };
            if !ours(&d, &c) {
                return;
            }
            let Some(path) = crate::finder_ops::finder_dropped_path(bytes).filter(|p| finder_exists(p)) else { return };
            let hit = d.tile_at(x, y);
            let item = hit.map(|(i, _)| d.state.borrow().items[i].clone());
            // An application dropped anywhere but the Trash is pinned
            // there, before the tile it landed on (P15.2b).
            if path.ends_with(".app") && finder_is_directory(&path) && !item.as_ref().is_some_and(|i| i.is_trash) {
                return d.pin(&path, item.and_then(|i| i.pin_token).as_deref());
            }
            match item {
                Some(i) => d.dropped(&path, &i),
                None => log(&format!("dropped {path} on no tile")),
            }
        });
    }

    /// The Trash takes anything; an application opens the document; the
    /// Finder opens its folder. Any other tile says it does not.
    fn dropped(&self, path: &str, item: &DockItem) {
        if item.is_trash {
            match finder_move_to_trash(path) {
                Some(dest) => log(&format!("threw away {path} -> {dest}")),
                None => return log(&format!("could not throw away {path}")),
            }
            return self.trash_changed();
        }
        if let (true, Some(cmd)) = (item.is_bundle(), &item.command) {
            // The bundle's launcher hands its arguments on as files to open.
            let mut argv = cmd.clone();
            argv.push(path.into());
            let env: Vec<(&str, &str)> = item.environment.iter().map(|(k, v)| (k.as_str(), v.as_str())).collect();
            if launcher::launch_detached(&argv, &env) {
                if let Some(b) = &item.bundle {
                    recent::record(b)
                }
                log(&format!("opened {path} with {}", item.label))
            } else {
                log(&format!("failed to open {path} with {}", item.label))
            }
            return;
        }
        let (Some("org.abyssbsd.finder"), Some(exe)) = (item.app_id.as_deref(), launcher::self_executable()) else { return log(&format!("{} does not open documents", item.label)) };
        // A folder opens itself; a file, the folder it is in.
        let dir = if finder_is_directory(path) { path.to_string() } else { finder_parent(path).unwrap_or_else(|| path.into()) };
        if launcher::launch_detached(&[exe], &[("AQUA_SCENE", "finder"), ("ABYSS_FINDER_DIR", &dir)]) {
            log(&format!("opened {dir} for {path}"))
        } else {
            log(&format!("failed to open {dir}"))
        }
    }

    // MARK: editing (P15.2b)

    fn pin(&self, bundle: &str, before: Option<&str>) {
        let token = {
            let mut s = self.state.borrow_mut();
            let token = pin_token_for_bundle(bundle, &s.library);
            if app_library::find(&token, &s.library).is_none() {
                s.library = app_library::all()
            }
            if app_library::find(&token, &s.library).is_none() {
                return log(&format!("{bundle} is not an application"));
            }
            s.pin_tokens = pinning(&token, before, &s.pin_tokens);
            token
        };
        log(&format!("kept {token} in the Dock"));
        self.pins_changed()
    }

    fn unpin(&self, item: &DockItem) {
        let Some(token) = &item.pin_token else { return };
        self.state.borrow_mut().pin_tokens.retain(|t| t != token);
        log(&format!("removed {} from the Dock", item.label));
        self.pins_changed()
    }

    /// Show the new tiles and write them to `dock.ini`, keeping its other
    /// keys.
    fn pins_changed(&self) {
        let tokens = {
            let mut s = self.state.borrow_mut();
            s.pinned = items(&s.pin_tokens, &s.library, pool_config::Agents::on(None));
            s.pin_tokens.join("; ")
        };
        let mut config = pool_config::load("dock", None).unwrap_or_default();
        config.set("dock", "apps", &tokens);
        match config.store("dock", None) {
            Ok(()) => log(&format!("saved apps = {tokens}")),
            Err(e) => log(&format!("could not save dock.ini: {e}")),
        }
        self.toplevels_changed(&self.current())
    }

    // MARK: actions

    fn is_running(&self, item: &DockItem) -> bool {
        self.current().iter().any(|t| item.owns(&t.app_id))
    }

    /// Open the Trash in a Finder window: a plain click on its tile.
    fn open_trash(&self) {
        let (Some(dir), Some(exe)) = (finder_trash_directory(), launcher::self_executable()) else { return log("cannot open the Trash (no HOME?)") };
        if launcher::launch_detached(&[exe], &[("AQUA_SCENE", "finder"), ("ABYSS_FINDER_DIR", &dir)]) {
            log(&format!("opened the Trash ({dir})"))
        } else {
            log("failed to open the Trash")
        }
    }

    /// The only place in the shell that permanently deletes.
    fn empty_trash(&self) {
        let (removed, failed) = finder_empty_trash();
        log(&format!("emptied Trash: {removed} removed, {failed} failed"));
        self.state.borrow_mut().trash_full = !finder_trash_contents().is_empty();
        self.rebuild();
        self.redraw()
    }

    /// Running: raise it. Not: start it, if the tile knows how.
    fn activate(&self, item: &DockItem) {
        if item.is_trash {
            return self.open_trash();
        }
        let Some(app_id) = &item.app_id else { return };
        if let Some(t) = self.current().into_iter().find(|t| item.owns(&t.app_id)) {
            if let Some(ft) = &*self.toplevels.borrow() {
                ft.activate(&t)
            }
            return log(&format!("activated {}", t.app_id));
        }
        let Some(cmd) = &item.command else { return log(&format!("no launcher for {app_id}")) };
        let env: Vec<(&str, &str)> = item.environment.iter().map(|(k, v)| (k.as_str(), v.as_str())).collect();
        if launcher::launch_detached(cmd, &env) {
            if let Some(b) = &item.bundle {
                recent::record(b)
            }
            log(&format!("launched {app_id}"))
        } else {
            log(&format!("launch failed for {app_id}"))
        }
    }

    fn close_menu(&self) {
        let m = self.state.borrow_mut().context.take();
        if let Some(m) = m {
            m.close_all()
        }
    }

    /// A tile's contextual menu, anchored to the tile: the positioner's
    /// flip puts it *above*, since the Dock leaves no room below.
    fn open_tile_menu(&self, item: DockItem, f: DockTileFrame, icon_bottom: f64) {
        self.close_menu();
        let running = self.is_running(&item);
        let removable = item.pin_token.as_ref().map_or(item.is_bundle(), |t| t != "finder");
        let menu = tile_menu(item.is_trash, running, item.pin_token.is_some(), removable);
        let full = self.state.borrow().trash_full;
        let Some(layer) = self.layer() else { return };
        let (me, me2, it) = (self.me.clone(), self.me.clone(), item.clone());
        let anchor = ((f.center_x - f.size / 2.0) as i32, (icon_bottom - f.size) as i32, f.size as i32, f.size as i32);
        let m = open_context_menu(
            &self.toolkit,
            &menu,
            if item.is_trash { "Trash" } else { &item.label },
            &|c| match c.verb.as_str() {
                "dock.empty-trash" if !full => Enablement::Disabled("the Trash is empty".into()),
                "dock.show-in-finder" => Enablement::Disabled("not available yet".into()),
                _ => Enablement::Enabled,
            },
            &log,
            |(w, h), lm| layer.open_popup(anchor, w, h, Rc::downgrade(lm) as Weak<dyn PopupDelegate>),
            move |c| {
                let Some(d) = me.upgrade() else { return };
                match c.verb.as_str() {
                    "dock.open-trash" => d.open_trash(),
                    "dock.empty-trash" => d.empty_trash(),
                    "dock.open" => d.activate(&it),
                    "dock.remove" => d.unpin(&it),
                    "dock.keep" => {
                        let bundle = app_library::owner(it.app_id.as_deref().unwrap_or(""), &d.state.borrow().library).map(|a| a.bundle.clone());
                        if let Some(b) = bundle {
                            d.pin(&b, None)
                        }
                    }
                    "dock.quit" => {
                        let mut ids: Vec<String> = d.current().into_iter().map(|t| t.app_id).filter(|a| it.owns(a)).collect();
                        ids.dedup();
                        let n: usize = d.toplevels.borrow().as_ref().map_or(0, |ft| ids.iter().map(|a| ft.close_app(a)).sum());
                        log(&format!("asked {} to quit ({n} window{})", it.label, if n == 1 { "" } else { "s" }))
                    }
                    _ => {}
                }
            },
            move || {
                if let Some(d) = me2.upgrade() {
                    d.state.borrow_mut().context = None
                }
            },
        );
        self.state.borrow_mut().context = m;
        if item.is_trash {
            log("opened Trash menu")
        } else {
            log(&format!("opened {} menu ({})", item.label, if running { "running" } else { "not running" }))
        }
    }

    fn pointer_at(&self, p: Option<(f64, f64)>) {
        let was = std::mem::replace(&mut self.state.borrow_mut().pointer, p);
        if was.is_some() || p.is_some() {
            self.redraw()
        }
    }

    /// Where each tile is at rest, when the set changes (P15.2): its centre
    /// x (the Dock spans the output) and its centre's height above the
    /// bottom edge. Hovering a tile's centre magnifies it in place, so the
    /// aim holds as it grows.
    fn log_tiles(&self, w: f64) {
        let t = self.toolkit.theme.borrow().tokens.clone();
        let mut s = self.state.borrow_mut();
        let base = dock_magnify(s.items.len(), self.tile, t.dock_gap, w / 2.0, None, 1.0, 1.0);
        let up = (t.dock_bottom_margin + t.dock_panel_pad_v + self.tile / 2.0) as i64;
        let line = s.items.iter().zip(base).map(|(i, f)| format!("{}={},{up}", i.label, f.center_x as i64)).collect::<Vec<_>>().join(" ");
        if line != s.last_tiles {
            log(&format!("tiles {line}"));
            s.last_tiles = line
        }
    }
}

impl LayerSurfaceDelegate for Dock {
    fn render(&self, _l: &LayerSurface, target: &RenderTarget) {
        let w = {
            let s = &mut *self.state.borrow_mut();
            let px = s.pointer.map(|p| p.0);
            let (frames, w) = self.toolkit.draw(target, |c, w, h| (paint_dock(c, w, h, &s.items, &s.running, px, self.tile, self.magnify, s.badge), w));
            s.frames = frames;
            w
        };
        self.log_tiles(w)
    }

    fn pointer_moved(&self, _l: &LayerSurface, x: f64, y: f64) {
        self.pointer_at(Some((x, y)))
    }

    fn pointer_left(&self, _l: &LayerSurface) {
        if self.state.borrow().pointer.is_some() {
            self.pointer_at(None)
        }
    }

    fn pointer_button(&self, _l: &LayerSurface, button: u32, pressed: bool) {
        let Some((px, py)) = self.state.borrow().pointer.filter(|_| pressed && (button == BTN_LEFT || button == BTN_RIGHT)) else { return };
        let Some((i, f)) = self.tile_at(px, py) else {
            if button == BTN_RIGHT {
                self.close_menu()
            }
            return;
        };
        let item = self.state.borrow().items[i].clone();
        if button == BTN_RIGHT {
            let h = self.layer().map_or(0, |l| l.size().1) as f64;
            let t = self.toolkit.theme.borrow().tokens.clone();
            self.open_tile_menu(item, f, h - t.dock_bottom_margin - t.dock_panel_pad_v)
        } else {
            self.activate(&item)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn verbs(m: &Menu) -> Vec<String> {
        m.commands().into_iter().map(|c| c.verb.clone()).collect()
    }

    #[test]
    fn a_tiles_menu_says_open_or_quit_by_whether_it_runs() {
        assert_eq!(verbs(&tile_menu(false, false, false, false))[0], "dock.open");
        assert_eq!(verbs(&tile_menu(false, true, false, false))[0], "dock.quit");
        // The Trash keeps its order: a test clicks those rows by position.
        assert_eq!(tile_menu(true, false, false, false).commands().iter().map(|c| c.title.as_str()).collect::<Vec<_>>(), ["Open", "Empty Trash"]);
    }

    #[test]
    fn the_dock_is_edited_by_pinning_and_removing() {
        assert_eq!(verbs(&tile_menu(false, false, true, true)), ["dock.open", "dock.remove", "dock.show-in-finder"]);
        assert_eq!(verbs(&tile_menu(false, true, true, false)), ["dock.quit", "dock.show-in-finder"], "the Finder cannot be removed");
        assert_eq!(verbs(&tile_menu(false, true, false, true)), ["dock.quit", "dock.keep", "dock.show-in-finder"]);
        let t: Vec<String> = ["finder", "Firefox", "sysprefs"].map(String::from).into();
        assert_eq!(pinning("Galculator", Some("sysprefs"), &t), ["finder", "Firefox", "Galculator", "sysprefs"]);
        assert_eq!(pinning("Galculator", None, &t), ["finder", "Firefox", "sysprefs", "Galculator"]);
        assert_eq!(pinning("sysprefs", Some("Firefox"), &t), ["finder", "sysprefs", "Firefox"], "moved, not doubled");
        let app = |name: &str, bundle: &str, ids: &[&str]| InstalledApp { name: name.into(), bundle: bundle.into(), executable: None, icon: None, app_ids: ids.iter().map(|s| s.to_string()).collect() };
        let lib = vec![app("Galculator", "/Applications/Galculator.app", &[]), app("Firefox", "/home/u/Applications/Firefox.app", &["firefox"])];
        assert_eq!(pin_token_for_bundle("/Applications/Galculator.app", &lib), "Galculator");
        assert_eq!(pin_token_for_bundle("/Applications/Firefox.app", &lib), "/Applications/Firefox.app", "shadowed: only the path means this one");
        assert_eq!(pin_tokens(None, &lib), ["finder", "Firefox", "terminal", "agent", "sysprefs"]);
        assert_eq!(pin_tokens(Some(" finder ;Gone; Galculator;"), &lib), ["finder", "Gone", "Galculator"]);
        let tokens: Vec<String> = ["finder", "Gone", "Galculator"].map(String::from).into();
        assert_eq!(items(&tokens, &lib, false).iter().map(|i| i.label.as_str()).collect::<Vec<_>>(), ["Finder", "Galculator"], "not installed: no tile, but its place kept");
    }

    #[test]
    fn off_hides_the_agent_tile() {
        let t: Vec<String> = ["agent", "finder"].map(String::from).into();
        assert_eq!(items(&t, &[], false).iter().map(|i| i.label.as_str()).collect::<Vec<_>>(), ["Finder"]);
        assert_eq!(items(&t, &[], true).iter().map(|i| i.label.as_str()).collect::<Vec<_>>(), ["Agent", "Finder"]);
    }

    #[test]
    fn the_dock_knows_agent_and_every_builtin() {
        let pinned = items(&["agent".into()], &[], true);
        assert_eq!((pinned[0].label.as_str(), pinned[0].app_id.as_deref(), pinned[0].pin_token.as_deref()), ("Agent", Some("org.abyssbsd.agent"), Some("agent")));
        assert!(pinned[0].environment.contains(&("AQUA_SCENE".into(), "agent".into())));
        let running = builtin_running("org.abyssbsd.agent").unwrap();
        assert_eq!((running.label.as_str(), running.pin_token.as_deref()), ("Agent", None), "running, not pinned");
        assert_eq!(running.icon, DockIcon::Theme("agent".into()));
        assert_eq!(builtin_running("org.mozilla.firefox"), None, "a bundle's app is the library's to name");
        for b in BUILTIN_APPS {
            let p = items(&[b.token.into()], &[], true);
            assert_eq!(p[0].label, b.name);
            assert!(p[0].environment.contains(&("AQUA_SCENE".into(), b.scene.into())));
            assert_eq!(builtin_running(b.app_id).unwrap().label, b.name);
        }
        assert_eq!(builtin_running("org.abyssbsd.preferences").unwrap().label, "System Preferences");
        assert_eq!(builtin_running("org.abyssbsd.prefs"), None);
    }

    #[test]
    fn magnify_at_rest() {
        let t = ThemeTokens::default();
        let (s, g) = (48.0, t.dock_gap);
        let f = dock_magnify(6, s, g, 400.0, None, t.dock_max_scale, 118.0);
        assert_eq!(f.len(), 6);
        assert!(f.iter().all(|t| (t.size - s).abs() < 1e-3 && (t.scale - 1.0).abs() < 1e-3));
        assert!(((f[0].center_x + f[5].center_x) / 2.0 - 400.0).abs() < 0.01);
        assert!((f[1].center_x - f[0].center_x - (s + g)).abs() < 0.01);
    }

    #[test]
    fn magnify_peaks_under_the_pointer() {
        let t = ThemeTokens::default();
        let (n, s, g, m, r, c) = (7, 48.0, t.dock_gap, 1.9, 118.0, 400.0);
        let base_left = c - (n as f64 * s + (n - 1) as f64 * g) / 2.0;
        let px = base_left + 2.0 * (s + g) + s / 2.0;
        let f = dock_magnify(n, s, g, c, Some(px), m, r);
        let max = (0..n).max_by(|a, b| f[*a].size.total_cmp(&f[*b].size)).unwrap();
        assert_eq!(max, 2);
        assert!((f[2].scale - m).abs() < 0.05);
        assert!(f.iter().all(|t| t.scale >= 1.0 - 1e-9 && t.scale <= m + 1e-9));
        assert!(f[2].size > f[1].size && f[2].size > f[3].size && f[1].size > f[0].size);
        for i in 1..n {
            assert!(f[i].center_x - f[i].size / 2.0 >= f[i - 1].center_x + f[i - 1].size / 2.0 - 0.01)
        }
    }

    #[test]
    fn the_surface_fits_a_magnified_tile() {
        let t = ThemeTokens::default();
        assert!(dock_surface_height(&t, 48.0) > 48.0 * t.dock_max_scale);
    }

    /// AgentWindowTests' built-in checks the Rust test leaves out: no two
    /// built-ins share a token or an app ID, a running one wears its own
    /// icon, and every theme draws each one's icon.
    #[test]
    fn every_builtin_has_a_tile_and_an_icon_in_every_theme() {
        let tokens: std::collections::BTreeSet<&str> = BUILTIN_APPS.iter().map(|b| b.token).collect();
        let ids: std::collections::BTreeSet<&str> = BUILTIN_APPS.iter().map(|b| b.app_id).collect();
        assert_eq!((tokens.len(), ids.len()), (BUILTIN_APPS.len(), BUILTIN_APPS.len()));
        let jaguar = aquadraw::theme::Theme::default();
        for b in BUILTIN_APPS {
            assert_eq!(builtin_running(b.app_id).unwrap().icon, DockIcon::Theme(b.icon.into()), "{} wears its own icon", b.name);
            assert!(jaguar.lists.get(&b.theme_icon()).is_some(), "{} has no icon in Jaguar", b.name);
        }
        let root = concat!(env!("CARGO_MANIFEST_DIR"), "/../..");
        let themes = format!("{root}/themes");
        let mut names: Vec<String> = std::fs::read_dir(&themes).unwrap().filter_map(|e| e.ok()).map(|e| e.file_name().to_string_lossy().into_owned()).filter(|n| std::path::Path::new(&format!("{themes}/{n}/theme.ini")).exists()).collect();
        names.sort();
        assert!(names.len() >= 2, "Aqua and a second theme: {names:?}");
        for theme in &names {
            let text = std::fs::read_to_string(format!("{root}/themes/{theme}/icons/dock.dl")).unwrap();
            let lists: std::collections::BTreeSet<&str> = text.lines().filter_map(|l| l.strip_prefix("list ")).map(|l| l.split_whitespace().next().unwrap_or("")).collect();
            for b in BUILTIN_APPS.iter().filter(|b| b.folder.is_some()) {
                assert!(lists.contains(b.theme_icon().as_str()), "{theme} has no {} for {}", b.theme_icon(), b.name);
            }
        }
    }
}
