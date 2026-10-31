//! The Jaguar menu bar (MenuBar.swift): a TOP layer strip across the screen
//! with its exclusive zone, the system menu in the Apple menu's place, the
//! bold application menu and the application's others, the status items,
//! the island and Agent items, and the clock. A title clicked opens a real
//! menu in a grabbing popup.
//!
//! The `panel` domain: `show_clock` (default true), `menubar_height`
//! (default 22). The clock ticks on a Display timer.
//!
//! The system glyph is an original water drop, not Apple's apple.

use crate::agent_presence::{self, agent_menu, agent_menu_pid, menu_bar_agent_label, AgentPresence, AgentState};
use crate::commands::{aqua_menu_items, aqua_menu_rows, AquaMenuItem};
use crate::finder_commands::{finder_menu_bar, FinderVerb};
use crate::island_menu::{island_action, island_menu, IslandAction};
use crate::launcher::{self, recent};
use crate::live_menu::LiveMenu;
use crate::menu::AquaMenu;
use crate::menubar_status::{menu_bar_status_layout, paint_menu_bar_status, MenuBarStatus, VolumeSlider, SLIDER_HEIGHT, SLIDER_WIDTH};
use crate::toolkit::Toolkit;
use aquadraw::canvas::{Canvas, Paint};
use aquadraw::drawlist::{DrawState, Role};
use aquadraw::runner::Rect;
use aquadraw::text::Style;
use current_ipc::Msg;
use menu_model::{Command, CommandResult, Enablement, Key, KeyEquivalent, Menu, MenuBarModel, MenuItem, Modifiers};
use std::cell::RefCell;
use std::collections::{BTreeMap, HashMap};
use std::os::fd::AsRawFd;
use std::os::unix::net::UnixStream;
use std::rc::{Rc, Weak};
use std::time::Instant;
use surface::layer::{anchor, KeyboardInteractivity, Layer};
use surface::menubar_focus::{Focus, MenuKind};
use surface::{Display, KeyEvent, KeySym, LayerConfig, LayerSurface, LayerSurfaceDelegate, MenuBarFocus, PopupDelegate, RenderTarget};

const BTN_LEFT: u32 = 0x110;

/// A title in the bar and what opens under it.
#[derive(Clone, Debug, PartialEq)]
pub struct MenuBarMenu {
    pub menu: Menu,
    /// The drop-glyph slot (the Apple menu's place).
    pub is_system: bool,
    /// The application's menu is bold.
    pub bold: bool,
}

impl MenuBarMenu {
    pub fn title(&self) -> &str {
        if self.is_system { "" } else { &self.menu.title }
    }
    fn name(&self) -> String {
        if self.is_system { "System".into() } else { self.menu.title.clone() }
    }
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct MenuBarLayout {
    /// With the menus.
    pub title_rects: Vec<Rect>,
    pub clock_rect: Rect,
    /// The status items, None when the machine cannot feed them.
    pub volume_rect: Option<Rect>,
    pub battery_rect: Option<Rect>,
    /// The island item (P13.4), left of the status items: None with one
    /// island.
    pub island_rect: Option<Rect>,
    /// The Agent item (P18.13b): None with no session open.
    pub agent_rect: Option<Rect>,
}

/// "Mon 9:41 AM": no leading zero on the hour.
pub fn format_menu_clock(hour24: i32, minute: i32, wday: i32) -> String {
    const DAYS: [&str; 7] = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
    let ampm = if hour24 < 12 { "AM" } else { "PM" };
    let h = match hour24 % 12 {
        0 => 12,
        h => h,
    };
    let day = usize::try_from(wday).ok().and_then(|d| DAYS.get(d)).map_or(String::new(), |d| format!("{d} "));
    format!("{day}{h}:{minute:02} {ampm}")
}

/// Room for the Agent item's dot, there whatever the state, so the words do
/// not move when a session starts waiting.
const AGENT_DOT_ROOM: f64 = 12.0;
const AGENT_DOT: f64 = 8.0;

/// What the bar shows besides its titles.
#[derive(Clone, Debug, Default)]
pub struct BarState<'a> {
    pub clock: &'a str,
    pub show_clock: bool,
    pub open_index: Option<usize>,
    pub status: MenuBarStatus,
    pub island: Option<&'a str>,
    pub island_open: bool,
    pub agent: Option<&'a str>,
    pub agent_waiting: bool,
    pub agent_open: bool,
}

/// Where everything is. Title widths are shaped text, so it needs the
/// canvas; the bar keeps the result and hit-tests against it.
pub fn menu_bar_layout(c: &mut Canvas, w: f64, h: f64, menus: &[MenuBarMenu], s: &BarState) -> MenuBarLayout {
    let t = c.theme.tokens.clone();
    let mut x = t.menu_bar_left_margin;
    let mut title_rects = Vec::new();
    for m in menus {
        let width = if m.is_system {
            t.menu_bar_system_slot
        } else {
            let style = if m.bold { Style::Bold } else { Style::Regular };
            c.text_width(m.title(), t.menu_bar_font_size, style, Role::Chrome) + 2.0 * t.menu_bar_title_pad_x
        };
        title_rects.push(Rect::new(x, 0.0, width, h));
        x += width;
    }
    let mut clock_rect = Rect::default();
    if s.show_clock && !s.clock.is_empty() {
        let cw = c.text_width(s.clock, t.menu_bar_font_size, Style::Regular, Role::Readout) + 4.0;
        clock_rect = Rect::new(w - cw - t.menu_bar_clock_margin_right, 0.0, cw, h);
    }
    // The status items sit against what the clock left free.
    let status_right = if clock_rect.w > 0.0 { clock_rect.x } else { w - t.menu_bar_clock_margin_right };
    let (volume_rect, battery_rect) = menu_bar_status_layout(&t, &s.status, h, status_right);
    let mut left = [volume_rect, battery_rect].iter().flatten().map(|r| r.x).fold(status_right, f64::min);
    let mut agent_rect = None;
    if let Some(a) = s.agent.filter(|a| !a.is_empty()) {
        let aw = c.text_width(a, t.menu_bar_font_size, Style::Regular, Role::Chrome) + 2.0 * t.menu_bar_title_pad_x + AGENT_DOT_ROOM;
        agent_rect = Some(Rect::new(left - aw - 4.0, 0.0, aw, h));
        left -= aw + 4.0;
    }
    let island_rect = s.island.filter(|i| !i.is_empty()).map(|i| {
        let iw = c.text_width(i, t.menu_bar_font_size, Style::Regular, Role::Chrome) + 2.0 * t.menu_bar_title_pad_x;
        Rect::new(left - iw - 4.0, 0.0, iw, h)
    });
    MenuBarLayout { title_rects, clock_rect, volume_rect, battery_rect, island_rect, agent_rect }
}

/// Paint the bar, the open title in menu blue; the layout, for hit-testing.
pub fn paint_menu_bar(c: &mut Canvas, w: f64, h: f64, menus: &[MenuBarMenu], s: &BarState) -> MenuBarLayout {
    let t = c.theme.tokens.clone();
    c.paint_simple("menubar", Rect::new(0.0, 0.0, w, h), DrawState::NORMAL);
    let l = menu_bar_layout(c, w, h, menus, s);
    let text = |open: bool| if open { t.menu_text_on_highlight } else { t.menu_bar_text };
    let item = |c: &mut Canvas, r: Rect, label: &str, open: bool, dot: f64| {
        if open {
            c.paint_simple("menubar.highlight", Rect::new(r.x, 0.0, r.w, h), DrawState::NORMAL)
        }
        c.text_left(label, r.x + t.menu_bar_title_pad_x + dot, h - 6.5, text(open), t.menu_bar_font_size, Style::Regular, Role::Chrome)
    };
    if let (Some(r), Some(a)) = (l.agent_rect, s.agent) {
        if s.agent_waiting {
            let d = Rect::new(r.x + t.menu_bar_title_pad_x, (h - AGENT_DOT) / 2.0, AGENT_DOT, AGENT_DOT);
            // Under the words' highlight, the dot first: as Swift orders it.
            if s.agent_open {
                c.paint_simple("menubar.highlight", Rect::new(r.x, 0.0, r.w, h), DrawState::NORMAL)
            }
            c.paint("dock.badge", d, Paint { colors: &[("c", t.dock_badge_waiting)], ..Paint::default() });
            c.text_left(a, r.x + t.menu_bar_title_pad_x + AGENT_DOT_ROOM, h - 6.5, text(s.agent_open), t.menu_bar_font_size, Style::Regular, Role::Chrome)
        } else {
            item(c, r, a, s.agent_open, AGENT_DOT_ROOM)
        }
    }
    if let (Some(r), Some(i)) = (l.island_rect, s.island) {
        item(c, r, i, s.island_open, 0.0)
    }
    for (i, (m, r)) in menus.iter().zip(&l.title_rects).enumerate() {
        let open = s.open_index == Some(i);
        if open {
            c.paint_simple("menubar.highlight", Rect::new(r.x, 0.0, r.w, h), DrawState::NORMAL)
        }
        if m.is_system {
            c.paint_simple("menubar.system", Rect::new(r.x + (r.w - 14.0) / 2.0, (h - 14.0) / 2.0, 14.0, 14.0), if open { DrawState::SELECTED } else { DrawState::NORMAL })
        } else {
            let style = if m.bold { Style::Bold } else { Style::Regular };
            c.text_left(m.title(), r.x + t.menu_bar_title_pad_x, h - 6.5, text(open), t.menu_bar_font_size, style, Role::Chrome)
        }
    }
    if s.show_clock && !s.clock.is_empty() {
        c.paint("menubar.clock", Rect::new(l.clock_rect.x, 0.0, l.clock_rect.w, h), Paint { label: s.clock, parameters: &[("size", t.menu_bar_font_size)], ..Paint::default() })
    }
    if !s.status.is_empty() {
        let right = if l.clock_rect.w > 0.0 { l.clock_rect.x } else { w - t.menu_bar_clock_margin_right };
        paint_menu_bar_status(c, &s.status, h, right, t.menu_bar_text)
    }
    l
}

fn cmd(verb: &str, title: &str, summary: &str) -> MenuItem {
    MenuItem::Command(Command::new(verb, title, summary))
}

fn keyed(verb: &str, title: &str, key: KeyEquivalent, summary: &str) -> MenuItem {
    MenuItem::Command(Command::new(verb, title, summary).with_key(key))
}

/// The system menu: the bar's own, whoever is frontmost (P10.8). What can
/// be done here is real; the rest is drawn disabled with the reason.
pub fn system_menu() -> Menu {
    use MenuItem::Separator as S;
    Menu::new(
        "System",
        vec![
            cmd("system.about", "About This Computer", "Describe this machine."),
            S,
            cmd("system.preferences", "System Preferences…", "Open System Preferences."),
            // Shown only while agents are on (P18.13).
            keyed("system.agent", "Agent…", KeyEquivalent::cmd('a', Modifiers::OPTION), "Open the Agent window."),
            cmd("system.dock", "Dock", "Change the Dock."),
            cmd("system.location", "Location", "Change network location."),
            S,
            cmd("system.recent", "Recent Items", "Reopen something recent."),
            S,
            keyed("system.force-quit", "Force Quit…", KeyEquivalent::cmd_key(Key::Escape, Modifiers::OPTION), "End an application that has stopped responding."),
            S,
            cmd("system.sleep", "Sleep", "Put the computer to sleep."),
            cmd("system.restart", "Restart…", "Restart the computer."),
            cmd("system.shut-down", "Shut Down…", "Turn the computer off."),
            S,
            // Fast user switching (P16.6b): this session locks and stays.
            cmd("system.login-window", "Login Window…", "Let someone else log in; your session stays, locked."),
            keyed("system.lock", "Lock Screen", KeyEquivalent::cmd('q', Modifiers::CONTROL), "Lock the screen; your password opens it."),
            // No "…": no confirmation sheet yet, so this is Jaguar's Option
            // variant, Log Out now, and its title says so.
            keyed("system.log-out", "Log Out", KeyEquivalent::cmd('q', Modifiers::SHIFT), "End this session."),
        ],
    )
}

/// The system menu as it stands: no Agent… while agents are off (P18.13).
pub fn system_menu_for(agents_on: bool) -> Menu {
    let m = system_menu();
    if agents_on {
        return m;
    }
    let items = m.items.into_iter().filter(|i| !matches!(i, MenuItem::Command(c) if c.verb == "system.agent")).collect();
    Menu::new(&m.title, items)
}

/// The bar for an application: the system menu, then its menus, the first
/// bold.
pub fn menus_for(app: &MenuBarModel) -> Vec<MenuBarMenu> {
    std::iter::once(MenuBarMenu { menu: system_menu(), is_system: true, bold: false }).chain(app.menus.iter().enumerate().map(|(i, m)| MenuBarMenu { menu: m.clone(), is_system: false, bold: i == 0 })).collect()
}

/// With no application to ask, from the definition alone: a Finder verb
/// the Finder implements is offered.
pub fn static_enablement(c: &Command) -> Enablement {
    match FinderVerb::from_raw(&c.verb) {
        Some(v) if v.is_implemented() => Enablement::Enabled,
        Some(_) => Enablement::Disabled("the Finder cannot do this yet".into()),
        None => Enablement::Disabled("not available yet".into()),
    }
}

const CONFINED_VERB: &str = "app.confined";

/// First in the application's menu when its window came from a jail
/// (P18.6): a status, not a command, which no toolkit's menus can hide.
fn with_confinement(menus: Vec<MenuBarMenu>, jail: &str) -> Vec<MenuBarMenu> {
    menus
        .into_iter()
        .map(|mut m| {
            if !m.bold {
                return m;
            }
            let mut items = m.menu.items.clone();
            if matches!(items.first(), Some(MenuItem::Command(c)) if c.verb == CONFINED_VERB) {
                items.remove(0);
                if matches!(items.first(), Some(MenuItem::Separator)) {
                    items.remove(0);
                }
            }
            if !jail.is_empty() {
                let row = cmd(CONFINED_VERB, &format!("Confined ({jail})"), &format!("This application runs in a jail of class {jail}: it sees only the files you give it."));
                let rest = std::mem::take(&mut items);
                items = std::iter::once(row).chain((!rest.is_empty()).then_some(MenuItem::Separator)).chain(rest).collect();
            }
            m.menu = Menu::new(&m.menu.title, items);
            m
        })
        .collect()
}

fn log(msg: &str) {
    eprintln!("MenuBar: {msg}")
}

fn clock_now() -> String {
    abyss_sys::platform::local_clock().map_or(String::new(), |(h, m, d)| format_menu_clock(h, m, d))
}

/// The display applications go on: anchor's, never the bar's privileged one.
fn app_display() -> Option<String> {
    std::env::var("ABYSS_APP_WAYLAND_DISPLAY").ok().filter(|d| !d.is_empty())
}

/// What the bar launches: this program, in another scene.
fn shell_binary() -> String {
    std::env::var("ABYSS_APP_BINARY").ok().or_else(launcher::self_executable).unwrap_or_else(|| "AquaDemo".into())
}

/// Start a scene of this program on the ordinary display. **Never on our
/// own socket**: the bar is on the privileged one, and a child inheriting it
/// could watch focus and force-quit anything (P10.8).
fn launch_scene(scene: &str, extra: &[(&str, &str)], what: &str) -> CommandResult {
    let Some(d) = app_display() else { return CommandResult::Refused("the bar does not know the ordinary display to launch on".into()) };
    let mut env = vec![("AQUA_SCENE", scene), ("WAYLAND_DISPLAY", d.as_str())];
    env.extend_from_slice(extra);
    if launcher::launch_detached(&[shell_binary()], &env) { CommandResult::Ok((!what.is_empty()).then(|| what.into())) } else { CommandResult::Refused(format!("could not start {}", if what.is_empty() { scene } else { what })) }
}

fn result_words(r: &CommandResult) -> String {
    match r {
        CommandResult::Ok(v) => format!("ok{}", v.as_ref().map_or(String::new(), |v| format!(" {v}"))),
        CommandResult::Refused(w) => format!("refused: {w}"),
    }
}

/// Every row of a menu whose popup's top-left is (x, y) on the output,
/// where it will be if the compositor puts it where it was asked (§2.46).
fn log_rows(rows: &[AquaMenuItem], t: &aquadraw::tokens::ThemeTokens, x: i32, y: i32) {
    for (row, (ry, rh)) in rows.iter().zip(aqua_menu_rows(rows, t)) {
        if row.is_separator {
            continue;
        }
        let key = if row.key_text.is_empty() { String::new() } else { format!("{} ", row.key_text) };
        let verb = row.verb.as_ref().map_or(String::new(), |v| format!(" {v}"));
        log(&format!("item '{}' {key}at {},{} {}{verb}{}", row.title, x + 30, y + (ry + rh / 2.0) as i32, if row.enabled { "enabled" } else { "disabled" }, if row.has_submenu { " submenu" } else { "" }))
    }
}

struct State {
    menus: Vec<MenuBarMenu>,
    /// The frontmost window's jail class, or "" (P18.6).
    confined_in: String,
    clock: String,
    layout: MenuBarLayout,
    open_index: Option<usize>,
    menu: Option<Rc<LiveMenu>>,
    pointer_x: f64,
    status: MenuBarStatus,
    island_label: Option<String>,
    island_open: bool,
    logged_island: Option<String>,
    agents: Vec<AgentPresence>,
    agent_open: bool,
    logged_agent: Option<String>,
    logged_volume: Option<Option<Rect>>,
    /// The frontmost application's menu service (P10.4), and with it which
    /// application it answers for (the GTK bridge serves them all, P10.6).
    service: Option<String>,
    target: Option<String>,
    /// Enablement pulled as the open menu opened (P10 §6.4).
    enablement: HashMap<String, Enablement>,
    /// What the open system menu's Recent Items were built from.
    recent_shown: Vec<String>,
    /// The held subscription to `service`.
    changes: Option<UnixStream>,
    titles_dirty: bool,
    slider: Option<Rc<VolumeSlider>>,
}

pub struct MenuBar {
    me: Weak<MenuBar>,
    display: Rc<Display>,
    toolkit: Rc<Toolkit>,
    layer: RefCell<Option<Rc<LayerSurface>>>,
    show_clock: bool,
    focus: RefCell<Option<Rc<MenuBarFocus>>>,
    state: RefCell<State>,
    presence: RefCell<Option<pool_config::Watcher>>,
}

impl MenuBar {
    pub fn new(display: &Rc<Display>, toolkit: &Rc<Toolkit>) -> Option<Rc<MenuBar>> {
        let config = pool_config::load("panel", None).unwrap_or_default();
        let height = config.uint64("panel", "menubar_height").unwrap_or(22) as i32;
        let status = MenuBarStatus::read();
        let bar = Rc::new_cyclic(|me| MenuBar {
            me: me.clone(),
            display: display.clone(),
            toolkit: toolkit.clone(),
            layer: RefCell::new(None),
            show_clock: config.bool("panel", "show_clock").unwrap_or(true),
            focus: RefCell::new(None),
            presence: RefCell::new(None),
            // Until the compositor says who is frontmost, the Finder's
            // definition: all a bar with no view of focus ever has.
            state: RefCell::new(State {
                menus: menus_for(&finder_menu_bar()),
                confined_in: String::new(),
                clock: clock_now(),
                layout: MenuBarLayout::default(),
                open_index: None,
                menu: None,
                pointer_x: 0.0,
                status,
                island_label: None,
                island_open: false,
                logged_island: None,
                agents: vec![],
                agent_open: false,
                logged_agent: None,
                logged_volume: None,
                service: None,
                target: None,
                enablement: HashMap::new(),
                recent_shown: vec![],
                changes: None,
                titles_dirty: true,
                slider: None,
            }),
        });
        let pinned = std::env::var("AQUA_SCALE").ok().and_then(|s| s.parse::<i32>().ok()).filter(|v| *v > 0);
        // ON_DEMAND: the compositor gives the bar the keyboard when it is
        // clicked, and takes it back, which is the Mac's rule (HANDOFF §2.27).
        let lc = LayerConfig { layer: Layer::Top, namespace: "abyss.menubar".into(), height, anchor: anchor::TOP | anchor::LEFT | anchor::RIGHT, exclusive_zone: height, keyboard: KeyboardInteractivity::OnDemand, ..LayerConfig::default() };
        let ls = LayerSurface::new(display, &lc, pinned.unwrap_or(1), pinned.is_none(), Rc::downgrade(&bar) as Weak<dyn LayerSurfaceDelegate>)?;
        *bar.layer.borrow_mut() = Some(ls);
        log(&format!("status {}", bar.state.borrow().status.describe()));
        match MenuBarFocus::new(display) {
            Some(f) => {
                let me = bar.me.clone();
                f.on_focus(move |f| {
                    if let Some(b) = me.upgrade() {
                        b.focused(f)
                    }
                });
                let me = bar.me.clone();
                f.on_island(move |i| {
                    let Some(b) = me.upgrade() else { return };
                    if !i.is_main {
                        return;
                    }
                    log(&format!("island {} {} of {} ({})", i.display, i.island, i.count, i.name));
                    let label = (i.count > 1).then(|| i.name.clone());
                    let changed = std::mem::replace(&mut b.state.borrow_mut().island_label, label.clone()) != label;
                    if changed {
                        b.redraw()
                    }
                });
                *bar.focus.borrow_mut() = Some(f);
            }
            None => log("not on the compositor's privileged socket: no view of focus"),
        }
        let me = bar.me.clone();
        display.add_timer(1000, move || {
            if let Some(b) = me.upgrade() {
                b.tick()
            }
        });
        if let Some(dir) = agent_presence::io::dir()
            && let Ok(w) = pool_config::Watcher::new(Some(&dir))
        {
            let fd = w.as_raw_fd();
            *bar.presence.borrow_mut() = Some(w);
            let me = bar.me.clone();
            display.add_fd(fd, move || {
                if let Some(b) = me.upgrade() {
                    b.presence_changed()
                }
            });
        }
        bar.presence_changed();
        Some(bar)
    }

    fn layer(&self) -> Option<Rc<LayerSurface>> {
        self.layer.borrow().clone()
    }

    fn redraw(&self) {
        if let Some(l) = self.layer() {
            l.set_needs_display()
        }
    }

    fn set_menus(&self, menus: Vec<MenuBarMenu>) {
        let mut s = self.state.borrow_mut();
        s.menus = with_confinement(menus, &s.confined_in.clone());
    }

    /// Re-read the agents' presence; redraw if it moved. Off, no item.
    fn presence_changed(&self) {
        if let Some(w) = &*self.presence.borrow() {
            w.drain();
        }
        let now = if pool_config::Agents::on(None) { agent_presence::io::read() } else { vec![] };
        if now == self.state.borrow().agents {
            return;
        }
        log(&format!("agents: {}", if now.is_empty() { "none".into() } else { now.iter().map(|a| format!("{}={}", a.pid, a.state.name())).collect::<Vec<_>>().join(" ") }));
        self.state.borrow_mut().agents = now;
        self.redraw()
    }

    fn focused(&self, f: &Focus) {
        match f.kind {
            MenuKind::None => log(&format!("frontmost: {}", if f.app_id.is_empty() { "nothing".into() } else { format!("{} (no menus)", f.app_id) })),
            k => log(&format!("frontmost: {} at {} [{}]", f.app_id, f.address, if k == MenuKind::Gtk { "gtk" } else { "abyss" })),
        }
        if !f.jail.is_empty() {
            log(&format!("frontmost is confined in {}", f.jail))
        }
        self.state.borrow_mut().confined_in = f.jail.clone();
        self.follow(f)
    }

    // MARK: the frontmost application (P10.4)

    /// Show whoever the compositor says is frontmost.
    fn follow(&self, f: &Focus) {
        self.close_menu();
        self.unsubscribe();
        self.state.borrow_mut().enablement.clear();
        match f.kind {
            MenuKind::Abyss | MenuKind::Gtk => {
                // Ours serve their menus themselves; a GTK application's are
                // the bridge's, told which by target; a confined one's are
                // its jail's own bridge (P18).
                let (svc, tgt, from) = match f.kind {
                    MenuKind::Gtk if !f.jail.is_empty() => (format!("menus-dbus-{}", f.jail), Some(f.address.clone()), format!("menus-dbus-{} (GTK, confined)", f.jail)),
                    MenuKind::Gtk => ("menus-dbus".into(), Some(f.address.clone()), "menus-dbus (GTK)".into()),
                    _ => (f.address.clone(), None, f.address.clone()),
                };
                let t0 = Instant::now();
                match menu_wire::client::describe(&svc, tgt.as_deref()) {
                    Ok((model, _)) => {
                        {
                            let mut s = self.state.borrow_mut();
                            s.service = Some(svc.clone());
                            s.target = tgt.clone();
                        }
                        self.set_menus(menus_for(&model));
                        log(&format!("showing {}'s menus from {from} ({} commands, described in {} us)", model.app_name, model.commands().len(), t0.elapsed().as_micros()));
                        // Told when they change (P10.9).
                        self.subscribe(&svc, tgt.as_deref())
                    }
                    // Going, or stuck: the bar must still be a bar.
                    Err(e) => {
                        log(&format!("could not describe {from}: {e}"));
                        self.show_name_only(&f.app_id)
                    }
                }
            }
            // A window with no menus still has a name, where Jaguar put it.
            MenuKind::None => self.show_name_only(&f.app_id),
        }
        self.state.borrow_mut().titles_dirty = true;
        self.redraw()
    }

    fn show_name_only(&self, app_id: &str) {
        {
            let mut s = self.state.borrow_mut();
            s.service = None;
            s.target = None;
        }
        let name = app_id.rsplit('.').next().unwrap_or("");
        let mut menus = vec![MenuBarMenu { menu: system_menu(), is_system: true, bold: false }];
        if !name.is_empty() {
            menus.push(MenuBarMenu { menu: Menu::new(name, vec![]), is_system: false, bold: true })
        }
        self.set_menus(menus)
    }

    fn subscribe(&self, svc: &str, target: Option<&str>) {
        let Ok(s) = menu_wire::client::subscribe(svc, target) else { return log(&format!("could not subscribe to {svc}'s changes")) };
        let fd = s.as_raw_fd();
        self.state.borrow_mut().changes = Some(s);
        let me = self.me.clone();
        self.display.add_fd(fd, move || {
            if let Some(b) = me.upgrade() {
                b.vocabulary_changed()
            }
        });
    }

    fn unsubscribe(&self) {
        if let Some(s) = self.state.borrow_mut().changes.take() {
            self.display.remove_fd(s.as_raw_fd())
        }
    }

    /// The application said its vocabulary changed, or went away, which
    /// reads the same until the read says which.
    fn vocabulary_changed(&self) {
        let (said, svc, tgt) = {
            let s = self.state.borrow();
            let Some(c) = &s.changes else { return };
            (current_ipc::receive(c).ok().and_then(|m| m.string("method").map(String::from)), s.service.clone(), s.target.clone())
        };
        let Some(svc) = svc else { return };
        if said.as_deref() != Some("changed") {
            log(&format!("{svc} went away"));
            return self.unsubscribe();
        }
        if let Ok((model, _)) = menu_wire::client::describe(&svc, tgt.as_deref()) {
            self.close_menu();
            self.set_menus(menus_for(&model));
            log(&format!("{}'s vocabulary changed; redescribed", model.app_name));
            self.state.borrow_mut().titles_dirty = true;
            self.redraw()
        }
    }

    /// Whether `c` can be chosen: as the application answered when its menu
    /// opened, or from the definition with no application to ask. The
    /// system menu, the island and Agent rows are the bar's own.
    fn enabled(&self, c: &Command) -> Enablement {
        if c.verb.starts_with("system.") {
            return self.system_enablement(&c.verb);
        }
        if c.verb == CONFINED_VERB {
            return Enablement::Disabled("a status: this application runs in a jail".into());
        }
        if island_action(&c.verb).is_some() || agent_menu_pid(&c.verb).is_some() {
            return Enablement::Enabled;
        }
        let s = self.state.borrow();
        if s.service.is_none() {
            return static_enablement(c);
        }
        s.enablement.get(&c.verb).cloned().unwrap_or(Enablement::Disabled("the application did not say".into()))
    }

    // MARK: the system menu's commands (P10.8)

    /// The frontmost application Force Quit can mean: not the desktop.
    fn force_quit_target(&self) -> Option<String> {
        let f = self.focus.borrow().as_ref()?.current()?;
        (!f.app_id.is_empty() && !f.app_id.starts_with("abyss.")).then_some(f.app_id)
    }

    fn system_enablement(&self, verb: &str) -> Enablement {
        let no = |w: &str| Enablement::Disabled(w.into());
        match verb {
            "system.about" | "system.preferences" | "system.log-out" | "system.lock" | "system.sleep" | "system.login-window" | "system.restart" | "system.shut-down" => Enablement::Enabled,
            "system.force-quit" if self.focus.borrow().is_none() => no("the bar cannot see which application is frontmost"),
            "system.force-quit" if self.force_quit_target().is_none() => no("no application is frontmost"),
            "system.force-quit" => Enablement::Enabled,
            "system.agent" if pool_config::Agents::on(None) => Enablement::Enabled,
            "system.agent" => no("agents are off"),
            "system.recent.clear" if self.state.borrow().recent_shown.is_empty() => no("nothing has been opened yet"),
            v if v.starts_with("system.recent.") => Enablement::Enabled,
            _ => no("not available yet"),
        }
    }

    fn perform_system(&self, verb: &str) -> CommandResult {
        let refuse = |w: String| CommandResult::Refused(w);
        match verb {
            "system.agent" if !pool_config::Agents::on(None) => refuse("agents are off: there is no agents.ini".into()),
            "system.agent" => launch_scene("agent", &[], "Agent"),
            // About This Computer: System Profiler, the machine's report.
            "system.about" => launch_scene("systemprofiler", &[], "System Profiler"),
            "system.preferences" => match launch_scene("sysprefs", &[], "") {
                CommandResult::Refused(w) if w.starts_with("could not") => refuse("could not start System Preferences".into()),
                r => r,
            },
            "system.force-quit" => {
                let Some(app) = self.force_quit_target() else { return refuse("no application is frontmost".into()) };
                if self.focus.borrow().as_ref().is_some_and(|f| f.force_quit(&app)) { CommandResult::Ok(Some(app)) } else { refuse("the compositor cannot be asked to force quit".into()) }
            }
            "system.recent.clear" => {
                recent::save(&[], None);
                CommandResult::Ok(None)
            }
            v if v.starts_with("system.recent.") => {
                let shown = self.state.borrow().recent_shown.clone();
                let Some(bundle) = v["system.recent.".len()..].parse::<usize>().ok().and_then(|i| shown.get(i).cloned()) else { return refuse("no such recent item".into()) };
                let Some(exe) = launcher::bundle_executable(&bundle) else { return refuse(format!("{bundle} is not there any more")) };
                let Some(d) = app_display() else { return refuse("the bar does not know the ordinary display to launch on".into()) };
                if !launcher::launch_detached(std::slice::from_ref(&exe), &[("WAYLAND_DISPLAY", &d)]) {
                    return refuse(format!("could not start {exe}"));
                }
                recent::record(&bundle);
                CommandResult::Ok(Some(bundle))
            }
            "system.login-window" => {
                let mut m = Msg::new();
                m.set_string("method", "switch-user");
                match login::client::call(m, &login::client::socket()) {
                    Ok(r) if r.bool("ok") == Some(true) => CommandResult::Ok(Some("the login window".into())),
                    Ok(r) => refuse(r.string("error").unwrap_or("not switched").into()),
                    Err(e) => refuse(format!("nobody to ask for the login window: {e}")),
                }
            }
            // "…": the power dialog asks first (P16.4b).
            "system.restart" | "system.shut-down" => match launch_scene("powerdialog", &[("ABYSS_POWER_ASK", if verb == "system.restart" { "restart" } else { "shut-down" })], "asking") {
                CommandResult::Refused(w) if w.starts_with("could not") => refuse("could not open the dialog".into()),
                r => r,
            },
            // The root daemon sleeps the machine once every session on it
            // has said it is locked (P16.4a).
            "system.sleep" => match login::client::power(login::PowerAction::Sleep, &login::client::socket()) {
                Ok(r) if r.bool("ok") == Some(true) => CommandResult::Ok(Some("going to sleep".into())),
                Ok(r) => refuse(r.string("error").unwrap_or("the machine did not sleep").into()),
                Err(e) => refuse(format!("nobody to ask the machine to sleep: {e}")),
            },
            // anchor runs the lock screen, so the bar asks it to.
            "system.lock" | "system.log-out" => {
                let mut m = Msg::new();
                m.set_string("method", if verb == "system.lock" { "lock" } else { "quit" });
                match current_ipc::call("anchor", &m) {
                    Ok(r) if r.bool("ok") == Some(true) => CommandResult::Ok((verb == "system.lock" && r.bool("already") == Some(true)).then(|| "already locked".into())),
                    Ok(r) if verb == "system.lock" => refuse(r.string("error").unwrap_or("anchor said no").into()),
                    _ => refuse("no session supervisor answered".into()),
                }
            }
            _ => refuse("not available yet".into()),
        }
    }

    /// The system menu with Recent Items filled from `recent.ini`, now.
    fn system_menu_now(&self) -> Menu {
        let shown = recent::load(None);
        self.state.borrow_mut().recent_shown = shown.clone();
        let sys = system_menu_for(pool_config::Agents::on(None));
        let items = sys.items.into_iter().map(|i| match i {
            MenuItem::Command(c) if c.verb == "system.recent" => MenuItem::Submenu(recent::submenu(&shown)),
            other => other,
        });
        Menu::new(&sys.title, items.collect())
    }

    /// Run what the person chose, and say what came of it.
    fn choose(&self, c: &Command, in_menu: &str) {
        let what = format!("{in_menu} > {} ({})", c.title, c.verb);
        if let Some(pid) = agent_menu_pid(&c.verb) {
            return self.go_to_agent(pid, what);
        }
        if let Some(a) = island_action(&c.verb) {
            let f = self.focus.borrow().clone();
            let main = f.as_ref().and_then(|f| f.main_island()).map_or(String::new(), |i| i.display);
            let ok = f.is_some_and(|f| match a {
                IslandAction::SwitchTo(n) => f.switch_island(&main, n),
                IslandAction::Window(id) => f.activate_window(id),
                IslandAction::Shoal(v, arg) => f.shoal_command(&v, arg),
            });
            return log(&format!("chose {what} → {}", if ok { "ok" } else { "refused: no compositor to ask" }));
        }
        if c.verb.starts_with("system.") {
            return log(&format!("chose {what} → {}", result_words(&self.perform_system(&c.verb))));
        }
        let (svc, tgt) = {
            let s = self.state.borrow();
            (s.service.clone(), s.target.clone())
        };
        let Some(svc) = svc else { return log(&format!("chose {what}")) };
        match menu_wire::client::activate(&svc, &c.verb, &BTreeMap::new(), tgt.as_deref()) {
            Ok(r) => log(&format!("chose {what} → {}", result_words(&r))),
            Err(e) => log(&format!("chose {what} → {svc} did not answer: {e}")),
        }
    }

    /// Where every title is on the output, for a test to click (§2.46).
    fn log_titles(&self) {
        let s = self.state.borrow();
        if s.layout.title_rects.is_empty() {
            return;
        }
        let parts: Vec<String> = s.menus.iter().zip(&s.layout.title_rects).map(|(m, r)| format!("{}@{},{}", m.name(), (r.x + r.w / 2.0) as i32, (r.h / 2.0) as i32)).collect();
        log(&format!("titles {}", parts.join(" ")))
    }

    fn tick(&self) {
        // An Agent window killed outright cannot withdraw: a tick re-reads.
        self.presence_changed();
        let now = clock_now();
        let mut dirty = false;
        {
            let mut s = self.state.borrow_mut();
            if now != s.clock {
                s.clock = now;
                dirty = true
            }
        }
        // The hardware on the same tick: volume and charge move on a human
        // timescale.
        dirty |= self.reread_status();
        if dirty {
            self.redraw()
        }
    }

    /// Read the machine now; whether it changed. A level set elsewhere is
    /// said as it arrives.
    fn reread_status(&self) -> bool {
        let fresh = MenuBarStatus::read();
        let mut s = self.state.borrow_mut();
        if fresh == s.status {
            return false;
        }
        if fresh.volume != s.status.volume || fresh.muted != s.status.muted {
            log(&format!("status {}", fresh.describe()))
        }
        s.status = fresh;
        true
    }

    // MARK: menus

    fn title_at(&self, x: f64) -> Option<usize> {
        let s = self.state.borrow();
        s.layout.title_rects.iter().enumerate().find(|(i, r)| x >= r.x && x < r.x + r.w && !s.menus[*i].menu.items.is_empty()).map(|(i, _)| i)
    }

    /// The next title in `step`'s direction that has a menu, wrapping.
    fn neighbour_title(&self, from: usize, step: i64) -> usize {
        let s = self.state.borrow();
        let n = s.menus.len() as i64;
        let mut j = from as i64;
        for _ in 0..n {
            j = (j + step + n) % n;
            if !s.menus[j as usize].menu.items.is_empty() {
                return j as usize;
            }
        }
        from
    }

    /// One level of an open menu and, through `submenu_for`, every level
    /// under it (P10.8). `origin` is where its popup is asked to go on the
    /// output, for the rows a test reads.
    fn make_menu(&self, menu: Menu, name: String, origin: (i32, i32)) -> Rc<LiveMenu> {
        let rows = aqua_menu_items(&menu, &|c| self.enabled(c));
        let lm = LiveMenu::new(&self.toolkit, AquaMenu::new(rows.clone(), None));
        let width = lm.preferred_size(150.0).0;
        let t = self.toolkit.theme.borrow().tokens.clone();
        let geo = aqua_menu_rows(&rows, &t);
        let row_origin: Rc<dyn Fn(usize) -> (i32, i32)> = Rc::new(move |i| (origin.0 + width, origin.1 + geo[i].0 as i32 - t.menu_pad_v as i32));
        let (me, items, n) = (self.me.clone(), menu.items.clone(), name.clone());
        lm.on_choose(move |i| {
            let (Some(b), Some(MenuItem::Command(c))) = (me.upgrade(), items.get(i)) else { return };
            b.close_menu();
            b.choose(c, &n)
        });
        let (me, items, n, ro) = (self.me.clone(), menu.items.clone(), name.clone(), row_origin.clone());
        lm.submenu_for(move |i| {
            let (Some(b), Some(MenuItem::Submenu(sub))) = (me.upgrade(), items.get(i)) else { return None };
            Some(b.make_menu(sub.clone(), format!("{n} > {}", sub.title), ro(i)))
        });
        let (r1, n) = (rows.clone(), name.clone());
        let t2 = self.toolkit.theme.borrow().tokens.clone();
        lm.on_submenu_opened(move |i, child| {
            log(&format!("opened submenu {n} > {}", r1[i].title));
            let (x, y) = row_origin(i);
            log_rows(&child.menu.borrow().items, &t2, x, y)
        });
        let (r2, n) = (rows, name);
        lm.on_submenu_closed(move |i| {
            if let Some(r) = r2.get(i) {
                log(&format!("closed submenu {n} > {}", r.title))
            }
        });
        lm
    }

    /// Open `lm` under `r` and keep it as the open menu; logged by `name`.
    fn show_menu(&self, lm: Rc<LiveMenu>, r: Rect, name: &str) -> bool {
        let Some(layer) = self.layer() else { return false };
        let me = self.me.clone();
        lm.on_dismiss(move || {
            if let Some(b) = me.upgrade() {
                b.menu_dismissed()
            }
        });
        let (w, h) = lm.preferred_size(150.0);
        let Some(p) = layer.open_popup((r.x as i32, 0, r.w as i32, r.h as i32), w, h, Rc::downgrade(&lm) as Weak<dyn PopupDelegate>) else { return false };
        lm.set_popup(p);
        log(&format!("opened {name}"));
        let t = self.toolkit.theme.borrow().tokens.clone();
        log_rows(&lm.menu.borrow().items, &t, r.x as i32, r.h as i32);
        self.state.borrow_mut().menu = Some(lm);
        true
    }

    fn open_menu(&self, i: usize) {
        self.close_menu();
        let (m, r, svc, tgt) = {
            let s = self.state.borrow();
            (s.menus[i].clone(), s.layout.title_rects[i], s.service.clone(), s.target.clone())
        };
        // **Pulled, as it opens** (P10 §6.4): asked of the application now.
        if let (Some(svc), false) = (&svc, m.is_system) {
            let t0 = Instant::now();
            let got = menu_wire::client::validate(svc, tgt.as_deref());
            match &got {
                Ok(v) => log(&format!("validated {} commands in {} us", v.len(), t0.elapsed().as_micros())),
                Err(_) => log(&format!("{svc} did not answer validate")),
            }
            self.state.borrow_mut().enablement = got.unwrap_or_default();
        }
        // Force Quit names what it would quit.
        let shown = if m.is_system {
            let title = self.force_quit_target().map_or("Force Quit".into(), |a| format!("Force Quit {}", a.rsplit('.').next().unwrap_or(&a)));
            self.system_menu_now().retitled(&HashMap::from([("system.force-quit".to_string(), title)]))
        } else {
            m.menu.clone()
        };
        let lm = self.make_menu(shown, m.name(), (r.x as i32, r.h as i32));
        if self.show_menu(lm, r, &m.name()) {
            self.state.borrow_mut().open_index = Some(i);
            self.redraw()
        }
    }

    /// Close whatever is open, submenus first; not a dismissal.
    fn close_menu(&self) {
        let m = self.state.borrow_mut().menu.take();
        if let Some(m) = m {
            m.close_all()
        }
        let changed = {
            let mut s = self.state.borrow_mut();
            let c = s.open_index.is_some() || s.island_open || s.agent_open;
            (s.open_index, s.island_open, s.agent_open) = (None, false, false);
            c
        };
        if changed {
            self.redraw()
        }
    }

    /// A click outside, or Escape.
    fn menu_dismissed(&self) {
        let was = {
            let mut s = self.state.borrow_mut();
            s.menu = None;
            let was = s.open_index.is_some() || s.island_open || s.agent_open;
            (s.open_index, s.island_open, s.agent_open) = (None, false, false);
            was
        };
        if was {
            log("closed");
            self.redraw()
        }
    }

    // MARK: the volume slider (P14.6d)

    fn open_volume_slider(&self, r: Rect) {
        let (unit, control, level) = {
            let s = self.state.borrow();
            match (s.status.volume_unit, s.status.volume) {
                (Some(u), Some(l)) => (u, s.status.volume_control.clone(), l as i64),
                _ => return log(&format!("volume: nothing to set ({})", s.status.describe())),
            }
        };
        let Some(layer) = self.layer() else { return };
        let slider = VolumeSlider::new(&self.toolkit, unit, &control, level);
        let me = self.me.clone();
        *slider.on_done.borrow_mut() = Some(Box::new(move |v| {
            let Some(b) = me.upgrade() else { return };
            log(&format!("volume set to {v}% (pcm{unit} {control})"));
            b.close_volume_slider();
            if b.reread_status() {
                b.redraw()
            }
        }));
        let me = self.me.clone();
        *slider.on_dismiss.borrow_mut() = Some(Box::new(move |()| {
            if let Some(b) = me.upgrade() {
                b.state.borrow_mut().slider = None
            }
        }));
        let Some(p) = layer.open_popup((r.x as i32, 0, r.w as i32, r.h as i32), SLIDER_WIDTH as i32, SLIDER_HEIGHT as i32, Rc::downgrade(&slider) as Weak<dyn PopupDelegate>) else { return };
        *slider.popup.borrow_mut() = Some(p);
        self.state.borrow_mut().slider = Some(slider);
        // Where the track is on the output, for a test to press (§2.46).
        let t = crate::menubar_status::slider_track();
        log(&format!("volume slider x={} top={} bottom={}", (r.x + t.x + t.w / 2.0) as i32, (r.h + t.y) as i32, (r.h + t.y + t.h) as i32))
    }

    fn close_volume_slider(&self) {
        let s = self.state.borrow_mut().slider.take();
        if let Some(p) = s.and_then(|s| s.popup.borrow_mut().take()) {
            p.close()
        }
    }

    // MARK: the Agent and island items

    fn open_agent_menu(&self, r: Rect) {
        let agents = self.state.borrow().agents.clone();
        let lm = self.make_menu(agent_menu(&agents), "Agent".into(), (r.x as i32, r.h as i32));
        if self.show_menu(lm, r, "Agent") {
            self.state.borrow_mut().agent_open = true;
            self.redraw()
        }
    }

    /// Go to the window of the session whose Agent window is `pid`: the
    /// compositor says which window that process owns (v6).
    fn go_to_agent(&self, pid: i32, what: String) {
        let Some(f) = self.focus.borrow().clone() else { return log(&format!("chose {what} → refused: no compositor to ask")) };
        let fw = Rc::downgrade(&f);
        let w2 = what.clone();
        let asked = f.list_islands(move |list| {
            let Some(f) = fw.upgrade() else { return };
            let Some(w) = list.windows.iter().find(|w| w.pid == pid) else { return log(&format!("chose {w2} → refused: no window of process {pid}")) };
            let ok = f.activate_window(w.id);
            log(&format!("chose {w2} → {}", if ok { format!("ok, window {}", w.id) } else { "refused: the compositor cannot activate windows".into() }))
        });
        if !asked {
            log(&format!("chose {what} → refused: the compositor cannot list windows"))
        }
    }

    /// Where every window is, asked as the menu opens (§6.4).
    fn open_island_menu(&self, r: Rect) {
        let Some(f) = self.focus.borrow().clone() else { return };
        let Some(main) = f.main_island() else { return };
        let me = self.me.clone();
        let asked = f.list_islands(move |list| {
            let Some(b) = me.upgrade() else { return };
            if b.state.borrow().menu.is_some() {
                return;
            }
            log(&format!("windows {}", list.windows.iter().map(|w| format!("{}={}:{}", w.id, w.app_id, w.pid)).collect::<Vec<_>>().join(" ")));
            let agents = b.state.borrow().agents.clone();
            let m = island_menu(&main.display, main.island, main.count, &list.names, &list.windows, &list.shoals, &agents);
            let lm = b.make_menu(m, "Islands".into(), (r.x as i32, r.h as i32));
            if b.show_menu(lm, r, "Islands") {
                b.state.borrow_mut().island_open = true;
                b.redraw()
            }
        });
        if !asked {
            log("the compositor cannot list islands (abyss_menubar_v1 < 3)")
        }
    }
}

impl LayerSurfaceDelegate for MenuBar {
    fn render(&self, _l: &LayerSurface, target: &RenderTarget) {
        let titles_dirty = {
            let s = &mut *self.state.borrow_mut();
            let agent = menu_bar_agent_label(&s.agents);
            let bs = BarState {
                clock: &s.clock,
                show_clock: self.show_clock,
                open_index: s.open_index,
                status: s.status.clone(),
                island: s.island_label.as_deref(),
                island_open: s.island_open,
                agent: agent.as_deref(),
                agent_waiting: s.agents.iter().any(|a| a.state == AgentState::Waiting),
                agent_open: s.agent_open,
            };
            let layout = self.toolkit.draw(target, |c, w, h| paint_menu_bar(c, w, h, &s.menus, &bs));
            // Where the Agent, island and volume items are, for a test.
            let at = |r: Rect| format!("at {},{}", (r.x + r.w / 2.0) as i32, (r.y + r.h / 2.0) as i32);
            let agent_item = layout.agent_rect.map_or("none".into(), |r| format!("'{}' {}", agent.clone().unwrap_or_default(), at(r)));
            if s.logged_agent.as_ref() != Some(&agent_item) {
                log(&format!("agent item {agent_item}"));
                s.logged_agent = Some(agent_item)
            }
            let island_item = layout.island_rect.map_or("none".into(), |r| format!("'{}' {}", s.island_label.clone().unwrap_or_default(), at(r)));
            if s.logged_island.as_ref() != Some(&island_item) {
                log(&format!("island item {island_item}"));
                s.logged_island = Some(island_item)
            }
            if s.logged_volume != Some(layout.volume_rect) {
                log(&format!("volume item {}", layout.volume_rect.map_or("none".into(), at)));
                s.logged_volume = Some(layout.volume_rect)
            }
            s.layout = layout;
            std::mem::take(&mut s.titles_dirty)
        };
        if titles_dirty {
            self.log_titles()
        }
    }

    fn pointer_moved(&self, _l: &LayerSurface, x: f64, _y: f64) {
        self.state.borrow_mut().pointer_x = x
    }

    fn pointer_button(&self, _l: &LayerSurface, button: u32, pressed: bool) {
        if button != BTN_LEFT || !pressed {
            return;
        }
        let (x, volume, agent, island, agent_open, island_open, open_index, has_slider) = {
            let s = self.state.borrow();
            (s.pointer_x, s.layout.volume_rect, s.layout.agent_rect, s.layout.island_rect, s.agent_open, s.island_open, s.open_index, s.slider.is_some())
        };
        let hit = |r: Option<Rect>| r.filter(|r| x >= r.x && x < r.x + r.w);
        if let Some(r) = hit(volume) {
            self.close_menu();
            return if has_slider { self.close_volume_slider() } else { self.open_volume_slider(r) };
        }
        if let Some(r) = hit(agent) {
            self.close_menu();
            if !agent_open {
                self.open_agent_menu(r)
            }
            return;
        }
        if let Some(r) = hit(island) {
            self.close_menu();
            if !island_open {
                self.open_island_menu(r)
            }
            return;
        }
        match self.title_at(x) {
            Some(i) if open_index == Some(i) => self.close_menu(),
            Some(i) => self.open_menu(i),
            None => self.close_menu(),
        }
    }

    /// Keys while a menu is open: ← and → walk the *titles* from the top
    /// menu (inside a submenu they go in and out of it); the rest are the
    /// open menu's.
    fn key_event(&self, _l: &LayerSurface, e: &KeyEvent) {
        let (open, menu) = {
            let s = self.state.borrow();
            (s.open_index, s.menu.clone())
        };
        let (Some(open), true) = (open, e.pressed) else { return };
        let Some(m) = menu else { return };
        let at_top = Rc::ptr_eq(&m.key_menu(), &m);
        match e.keysym {
            KeySym::LEFT if at_top => self.open_menu(self.neighbour_title(open, -1)),
            KeySym::RIGHT if at_top && !m.highlight_opens_submenu() => self.open_menu(self.neighbour_title(open, 1)),
            k => {
                m.key_down(k);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn format_menu_clock_is_jaguars() {
        assert_eq!(format_menu_clock(9, 41, 1), "Mon 9:41 AM");
        assert_eq!(format_menu_clock(0, 5, 0), "Sun 12:05 AM");
        assert_eq!(format_menu_clock(12, 0, 6), "Sat 12:00 PM");
        assert_eq!(format_menu_clock(23, 59, 3), "Wed 11:59 PM");
    }

    #[test]
    fn the_bars_menus_come_from_the_finder_model() {
        let menus = menus_for(&finder_menu_bar());
        assert!(menus[0].is_system, "the system (drop) menu is first");
        assert!(menus[1].bold && menus[1].title() == "Finder");
        assert_eq!(menus.iter().map(|m| m.title()).collect::<Vec<_>>(), ["", "Finder", "File", "Edit", "View", "Go", "Window", "Help"]);
        assert!(menus.iter().all(|m| !m.menu.items.is_empty()));
        let bar: Vec<String> = menus[1..].iter().flat_map(|m| m.menu.commands().into_iter().map(|c| c.verb.clone())).collect();
        let model: Vec<String> = finder_menu_bar().commands().into_iter().map(|c| c.verb.clone()).collect();
        assert_eq!(bar, model, "the bar draws the Finder's definition, not a copy");
    }

    #[test]
    fn agent_is_out_of_the_system_menu_while_agents_are_off() {
        let on: Vec<String> = system_menu_for(true).commands().into_iter().map(|c| c.verb.clone()).collect();
        let off: Vec<String> = system_menu_for(false).commands().into_iter().map(|c| c.verb.clone()).collect();
        assert!(on.contains(&"system.agent".into()) && !off.contains(&"system.agent".into()));
        assert_eq!(on.len(), off.len() + 1);
    }

    #[test]
    fn confinement_is_the_first_row_of_the_application_menu_and_only_once() {
        let menus = with_confinement(menus_for(&finder_menu_bar()), "browser");
        let first = &menus[1].menu.items;
        assert!(matches!(&first[0], MenuItem::Command(c) if c.verb == CONFINED_VERB && c.title == "Confined (browser)"));
        assert!(matches!(first[1], MenuItem::Separator));
        let again = with_confinement(menus.clone(), "browser");
        assert_eq!(again, menus, "marking twice is marking once");
        let cleared = with_confinement(menus, "");
        assert_eq!(cleared, menus_for(&finder_menu_bar()));
    }

    fn layout_with(status: MenuBarStatus, show_clock: bool) -> MenuBarLayout {
        let mut runner = aquadraw::scene::runner(1).expect("fonts");
        let mut theme = aquadraw::theme::Theme::default();
        theme.load_current(None, Some(&mut runner));
        let s = abyss_sys::Surface::image(abyss_sys::FORMAT_ARGB32, 800, 22);
        let cr = abyss_sys::Context::new(&s);
        let mut c = Canvas::new(&cr, &mut runner, &theme);
        menu_bar_layout(&mut c, 800.0, 22.0, &menus_for(&finder_menu_bar()), &BarState { clock: "Mon 9:41 AM", show_clock, status, ..BarState::default() })
    }

    #[test]
    fn the_layout_marches_titles_and_puts_the_clock_right() {
        let t = aquadraw::tokens::ThemeTokens::default();
        let l = layout_with(MenuBarStatus::default(), true);
        assert_eq!(l.title_rects.len(), 8);
        let mut x = t.menu_bar_left_margin;
        for r in &l.title_rects {
            assert!((r.x - x).abs() < 0.01 && r.w > 0.0 && r.h == 22.0);
            x += r.w
        }
        let last = l.title_rects.last().unwrap();
        assert!(l.clock_rect.x > last.x + last.w && l.clock_rect.x + l.clock_rect.w <= 800.0);
        assert_eq!(layout_with(MenuBarStatus::default(), false).clock_rect.w, 0.0);
    }

    #[test]
    fn the_layout_reserves_space_for_status_items() {
        let with = layout_with(MenuBarStatus { volume: Some(60), battery_percent: Some(84), ..MenuBarStatus::default() }, true);
        let (v, b) = (with.volume_rect.unwrap(), with.battery_rect.unwrap());
        assert!(b.x + b.w <= with.clock_rect.x && v.x < b.x);
        let without = layout_with(MenuBarStatus::default(), true);
        assert!(without.volume_rect.is_none() && without.battery_rect.is_none());
        assert_eq!(without.clock_rect, with.clock_rect, "the clock does not move when items appear");
    }
}
