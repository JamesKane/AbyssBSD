//! Activity Monitor: what is running, and quitting it
//! (ActivityMonitorApp.swift, P15.7).
//!
//! The process table every two seconds, %CPU measured between samples,
//! sorted by any column, filtered to My Processes or All, and narrowed by a
//! name typed into the filter field. Quit Process asks first, as Jaguar's
//! did (Quit, Force Quit, Cancel), and then:
//!
//! - **one's own process** is signalled from here, after checking the pid
//!   is still the process chosen (its start and name: a pid freed and
//!   reused since is somebody else);
//! - **another user's** goes to the privileged helper as a `signal` plan
//!   (administrators only, the same check made again as root, a kernel
//!   process refused): this program never gains privilege.
//!
//! What a test reads (`ABYSS_ACTIVITY_DUMP=1`): the rows shown and where
//! each is drawn, the toolbar's and the sheet's buttons, what was quit.

use crate::commands::key_equivalent_of;
use crate::prefs::settings_client::{self as client, Apply};
use crate::toolkit::Toolkit;
use aquadraw::canvas::Canvas;
use aquadraw::chrome::{chrome_hit, window_chrome, ChromeEdge, ChromeHit, Gadget};
use aquadraw::color::Color;
use aquadraw::draw::paint_window_chrome;
use aquadraw::drawlist::Role;
use aquadraw::runner::Rect;
use aquadraw::text::Style;
use aquadraw::tokens::ThemeTokens;
use menu_model::{Command, CommandResult, Enablement, KeyEquivalent, Menu, MenuBarModel, MenuItem, Modifiers};
use menu_wire::{MenuProvider, MenuService};
use settings::{SettingsPlan, SignalPlan};
use std::cell::{Cell, RefCell};
use std::collections::BTreeMap;
use std::rc::{Rc, Weak};
use surface::{Display, KeyEvent, KeyModifiers, KeySym, RenderTarget, ResizeEdge, Window, WindowDelegate};
use vents::processes::{self as procs, Column, Filter, ProcessTable, Row, Sample};

// MARK: - The vocabulary

pub const VERB_ABOUT: &str = "app.about";
pub const VERB_QUIT: &str = "app.quit";
pub const VERB_CLOSE: &str = "window.close";
pub const VERB_MINIMIZE: &str = "window.minimize";
pub const VERB_QUIT_PROCESS: &str = "process.quit";
pub const VERB_MINE: &str = "view.mine";
pub const VERB_ALL: &str = "view.all";
pub const VERB_REFRESH: &str = "view.refresh";

pub fn activity_menu_bar() -> MenuBarModel {
    let c = |v: &str, t: &str, k: Option<(char, Modifiers)>, s: &str| {
        let cmd = Command::new(v, t, s);
        MenuItem::Command(match k {
            Some((ch, m)) => cmd.with_key(KeyEquivalent::cmd(ch, m)),
            None => cmd,
        })
    };
    let n = Modifiers::NONE;
    MenuBarModel::new(
        "Activity Monitor",
        vec![
            Menu::new("Activity Monitor", vec![c(VERB_ABOUT, "About Activity Monitor", None, "Show Activity Monitor's version."), MenuItem::Separator, c(VERB_QUIT, "Quit Activity Monitor", Some(('q', n)), "Close Activity Monitor.")]),
            Menu::new("File", vec![c(VERB_CLOSE, "Close", Some(('w', n)), "Close the window.")]),
            Menu::new(
                "View",
                vec![
                    c(VERB_MINE, "My Processes", Some(('1', n)), "Show only your processes."),
                    c(VERB_ALL, "All Processes", Some(('2', n)), "Show every process."),
                    MenuItem::Separator,
                    c(VERB_QUIT_PROCESS, "Quit Process…", Some(('q', Modifiers::OPTION)), "Quit the selected process."),
                    c(VERB_REFRESH, "Update Now", Some(('r', n)), "Read the process table again."),
                ],
            ),
            Menu::new("Window", vec![c(VERB_MINIMIZE, "Minimize", Some(('m', n)), "Put the window in the Dock.")]),
        ],
    )
}

// MARK: - Layout and painting

/// The columns: what each shows, its title and width, numbers on the right.
pub const COLUMNS: [(Column, &str, f64, bool); 6] = [(Column::Pid, "PID", 60.0, true), (Column::Name, "Process Name", 190.0, false), (Column::User, "User", 90.0, false), (Column::Cpu, "% CPU", 64.0, true), (Column::Threads, "Threads", 62.0, true), (Column::Memory, "Real Memory", 96.0, true)];

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ActivityLayout {
    pub quit_button: Rect,
    pub mine: Rect,
    pub all: Rect,
    pub filter: Rect,
    pub header: Rect,
    pub table: Rect,
    pub footer: Rect,
    pub row_height: f64,
}

impl ActivityLayout {
    pub fn new(t: &ThemeTokens, w: f64, h: f64) -> ActivityLayout {
        let top = t.title_bar_height;
        let header = Rect::new(0.0, top + 50.0, w, 20.0);
        let footer = Rect::new(0.0, h - 28.0 - t.chrome_resize_band, w, 28.0);
        ActivityLayout {
            quit_button: Rect::new(12.0, top + 12.0, 110.0, 26.0),
            mine: Rect::new(136.0, top + 12.0, 110.0, 26.0),
            all: Rect::new(250.0, top + 12.0, 110.0, 26.0),
            filter: Rect::new(372.0f64.max(w - 200.0), top + 14.0, 180.0, 22.0),
            table: Rect::new(0.0, header.y + header.h, w, (footer.y - header.y - header.h).max(0.0)),
            header,
            footer,
            row_height: 18.0,
        }
    }

    fn visible(&self) -> usize {
        (self.table.h / self.row_height) as usize
    }
}

#[derive(Clone, Debug)]
pub struct ActivityView {
    pub rows: Vec<Row>,
    pub sort_by: Column,
    pub ascending: bool,
    pub mine_only: bool,
    pub filter: String,
    pub selected: Option<(i32, i64)>,
    pub scroll: usize,
    pub memory_total: u64,
    pub memory_available: u64,
    pub cpu_total: f64,
    pub status: String,
}

impl Default for ActivityView {
    fn default() -> ActivityView {
        ActivityView { rows: vec![], sort_by: Column::Cpu, ascending: false, mine_only: true, filter: String::new(), selected: None, scroll: 0, memory_total: 0, memory_available: 0, cpu_total: 0.0, status: String::new() }
    }
}

pub fn paint_activity(c: &mut Canvas, w: f64, h: f64, v: &ActivityView, user_name: &dyn Fn(u32) -> String) -> ActivityLayout {
    paint_window_chrome(c.runner, c.theme, c.cr, w, h, &format!("Activity Monitor — {} Processes", if v.mine_only { "My" } else { "All" }), false, true);
    let t = c.theme.tokens.clone();
    let l = ActivityLayout::new(&t, w, h);
    let text = |c: &mut Canvas, s: &str, x: f64, y: f64, k, style| c.text_left(s, x, y, k, 11.0, style, Role::Interface);
    let fill = |c: &mut Canvas, k: Color, r: Rect| {
        c.set_color(k);
        c.cr.rectangle(r.x, r.y, r.w, r.h);
        c.cr.fill()
    };
    fill(c, t.content_background, Rect::new(0.0, t.title_bar_height, w, h - t.title_bar_height));
    c.gel_button(l.quit_button, "Quit Process", false, false);
    c.gel_button(l.mine, "My Processes", v.mine_only, false);
    c.gel_button(l.all, "All Processes", !v.mine_only, false);
    c.text_field(l.filter, &v.filter, false, "Filter");
    // The header, with the sorted column's arrow.
    fill(c, Color::hex(0xE4E4E4, 1.0), l.header);
    let mut x = 8.0;
    for (col, title, width, right) in COLUMNS {
        let s = format!("{title}{}", if col == v.sort_by { if v.ascending { " ▲" } else { " ▼" } } else { "" });
        // Measured as it is drawn, bold, so a right-aligned title ends
        // where the numbers under it end.
        let tx = if right { x + width - 8.0 - c.text_width(&s, 11.0, Style::Bold, Role::Interface) } else { x };
        text(c, &s, tx, l.header.y + 14.0, t.body_text, Style::Bold);
        x += width
    }
    // The rows: striped, the selection blue.
    for (i, r) in v.rows.iter().skip(v.scroll).take(l.visible()).enumerate() {
        let y = l.table.y + i as f64 * l.row_height;
        let sel = v.selected == Some(r.info.identity());
        fill(c, if sel { Color::hex(0x3875D7, 1.0) } else if i % 2 == 0 { Color::hex(0xFFFFFF, 1.0) } else { Color::hex(0xEDF3FE, 1.0) }, Rect::new(0.0, y, w, l.row_height));
        let fg = if sel { Color::new(1.0, 1.0, 1.0, 1.0) } else if r.info.system { t.body_text.with_a(0.55) } else { t.body_text };
        let cells = [r.info.pid.to_string(), r.info.name.clone(), user_name(r.info.uid), ProcessTable::format_percent(r.cpu_percent), r.info.threads.to_string(), ProcessTable::format_bytes(r.info.resident_bytes)];
        let mut cx = 8.0;
        for ((_, _, width, right), s) in COLUMNS.iter().zip(cells) {
            let tx = if *right { cx + width - 8.0 - c.text_width(&s, 11.0, Style::Regular, Role::Interface) } else { cx };
            c.cr.save();
            c.cr.rectangle(cx, y, width - 4.0, l.row_height);
            c.cr.clip();
            text(c, &s, tx, y + 13.0, fg, Style::Regular);
            c.cr.restore();
            cx += width
        }
    }
    // The machine, along the bottom.
    fill(c, Color::hex(0xE4E4E4, 1.0), l.footer);
    let used = v.memory_total.saturating_sub(v.memory_available);
    let mut foot = format!("{} processes    CPU: {}%    Memory: {} used of {}", v.rows.len(), ProcessTable::format_percent(v.cpu_total), ProcessTable::format_bytes(used), ProcessTable::format_bytes(v.memory_total));
    if !v.status.is_empty() {
        foot += &format!("    {}", v.status)
    }
    text(c, &foot, 12.0, l.footer.y + 18.0, t.body_text, Style::Regular);
    l
}

/// "Are you sure you want to quit this process?": Jaguar's, from the title bar.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct QuitSheetLayout {
    pub panel: Rect,
    pub quit: Rect,
    pub force: Rect,
    pub cancel: Rect,
}

impl QuitSheetLayout {
    pub fn new(title_bar: f64, w: f64) -> QuitSheetLayout {
        let (pw, ph) = (440.0f64.min(w - 40.0), 116.0);
        let panel = Rect::new((w - pw) / 2.0, title_bar, pw, ph);
        let by = panel.y + ph - 40.0;
        let quit = Rect::new(panel.x + pw - 92.0, by, 78.0, 26.0);
        QuitSheetLayout { panel, quit, force: Rect::new(quit.x - 104.0, by, 96.0, 26.0), cancel: Rect::new(panel.x + 16.0, by, 78.0, 26.0) }
    }
}

fn paint_quit_sheet(c: &mut Canvas, w: f64, name: &str) -> QuitSheetLayout {
    let t = c.theme.tokens.clone();
    let l = QuitSheetLayout::new(t.title_bar_height, w);
    let p = l.panel;
    c.set_color(Color::new(0.0, 0.0, 0.0, 0.18));
    c.cr.rectangle(p.x + 2.0, p.y, p.w, p.h + 3.0);
    c.cr.fill();
    c.set_color(Color::hex(0xECECEC, 1.0));
    c.cr.rectangle(p.x, p.y, p.w, p.h);
    c.cr.fill();
    c.text_left(&format!("Are you sure you want to quit \"{name}\"?"), p.x + 18.0, p.y + 30.0, t.body_text, t.font_size, Style::Bold, Role::Interface);
    c.text_left("Force Quit ends it at once; anything it has not saved is lost.", p.x + 18.0, p.y + 50.0, t.body_text, t.font_size - 1.0, Style::Regular, Role::Interface);
    c.gel_button(l.cancel, "Cancel", false, false);
    c.gel_button(l.force, "Force Quit", false, false);
    c.gel_button(l.quit, "Quit", true, false);
    l
}

/// The golden scene's table: names, users and numbers that do not change.
pub fn sample_view() -> ActivityView {
    let p = |pid, name: &str, uid, rss, threads, system| procs::Info { pid, ppid: 0, uid, threads, resident_bytes: rss, virtual_bytes: 0, cpu_microseconds: 0, started: 100, state: 'S', system, name: name.into() };
    let all = vec![p(1, "init", 0, 1_200_000, 1, false), p(14, "kernel", 0, 0, 230, true), p(812, "undertow", 1001, 96_000_000, 6, false), p(840, "AquaDemo", 1001, 58_000_000, 3, false), p(901, "firefox", 1001, 412_000_000, 64, false), p(1203, "sh", 1001, 2_400_000, 1, false)];
    let cpu = |pid| match pid {
        812 => 120_000,
        840 => 40_000,
        901 => 310_000,
        _ => 0,
    };
    let before = Sample { processes: all.clone(), at: 0, memory_total: 0, memory_available: 0 };
    let after = Sample { processes: all.into_iter().map(|q| procs::Info { cpu_microseconds: cpu(q.pid), ..q }).collect(), at: 1_000_000, memory_total: 16 << 30, memory_available: 9 << 30 };
    let rows = ProcessTable::new(&after, Some(&before)).view(Filter::All, Column::Cpu, false, &sample_user);
    let selected = rows.iter().find(|r| r.info.pid == 840).map(|r| r.info.identity());
    ActivityView { rows, mine_only: false, selected, memory_total: 16 << 30, memory_available: 9 << 30, cpu_total: 11.8, ..ActivityView::default() }
}

pub fn sample_user(uid: u32) -> String {
    if uid == 0 { "root".into() } else { "abyss".into() }
}

fn log(s: &str) {
    eprintln!("Activity Monitor: {s}")
}

fn ok() -> CommandResult {
    CommandResult::Ok(None)
}

// MARK: - The application

pub struct ActivityMonitor {
    me: Weak<ActivityMonitor>,
    display: Rc<Display>,
    toolkit: Rc<Toolkit>,
    window: RefCell<Option<Rc<Window>>>,
    view: RefCell<ActivityView>,
    table: RefCell<ProcessTable>,
    last: RefCell<Option<Sample>>,
    menu_service: RefCell<Option<MenuService>>,
    pointer: Cell<(f64, f64)>,
    asking: RefCell<Option<Row>>,
    helper: RefCell<Option<Rc<Apply>>>,
    uid: u32,
    dump: bool,
    last_dump: RefCell<String>,
    logged: Cell<bool>,
}

struct Provider<'a>(&'a ActivityMonitor);

impl MenuProvider for Provider<'_> {
    fn menu_model(&self) -> MenuBarModel {
        activity_menu_bar()
    }
    fn menu_validate(&self, c: &Command) -> Enablement {
        self.0.validate(&c.verb)
    }
    fn menu_perform(&mut self, c: &Command, _a: &BTreeMap<String, String>) -> CommandResult {
        if let Enablement::Disabled(why) = self.0.validate(&c.verb) {
            return CommandResult::Refused(why);
        }
        self.0.perform(&c.verb)
    }
}

impl ActivityMonitor {
    pub fn new(display: &Rc<Display>, toolkit: &Rc<Toolkit>) -> Option<Rc<ActivityMonitor>> {
        let app = Rc::new_cyclic(|me| ActivityMonitor {
            me: me.clone(),
            display: display.clone(),
            toolkit: toolkit.clone(),
            window: RefCell::new(None),
            view: RefCell::default(),
            table: RefCell::default(),
            last: RefCell::new(None),
            menu_service: RefCell::new(None),
            pointer: Cell::new((0.0, 0.0)),
            asking: RefCell::new(None),
            helper: RefCell::new(None),
            uid: abyss_sys::users::uid(),
            dump: std::env::var_os("ABYSS_ACTIVITY_DUMP").is_some(),
            last_dump: RefCell::default(),
            logged: Cell::new(false),
        });
        let pinned = std::env::var("AQUA_SCALE").ok().and_then(|s| s.parse::<i32>().ok()).filter(|v| *v > 0);
        let win = Window::new(display, "Activity Monitor", "org.abyssbsd.activitymonitor", 620, 460, pinned.unwrap_or(1), pinned.is_none(), Rc::downgrade(&app) as Weak<dyn WindowDelegate>)?;
        let name = menu_wire::service_name("ActivityMonitor", std::process::id() as i32);
        if let Ok(s) = MenuService::new(&name) {
            let me = app.me.clone();
            display.add_fd(s.fd(), move || {
                if let Some(a) = me.upgrade() {
                    a.serve()
                }
            });
            *app.menu_service.borrow_mut() = Some(s);
            win.publish_menus(&name);
        }
        *app.window.borrow_mut() = Some(win);
        app.refresh();
        let me = app.me.clone();
        display.add_timer(2000, move || {
            if let Some(a) = me.upgrade() {
                a.refresh()
            }
        });
        Some(app)
    }

    fn serve(&self) {
        let svc = self.menu_service.borrow_mut().take();
        let Some(mut svc) = svc else { return };
        svc.service_readable(&mut Provider(self));
        *self.menu_service.borrow_mut() = Some(svc)
    }

    fn redraw(&self) {
        if let Some(w) = self.window.borrow().as_ref() {
            w.set_needs_display()
        }
    }

    fn layout(&self) -> ActivityLayout {
        let (w, h) = self.window.borrow().as_ref().map_or((620, 460), |w| w.size());
        ActivityLayout::new(&self.toolkit.theme.borrow().tokens, w as f64, h as f64)
    }

    // MARK: the table

    fn refresh(&self) {
        let Some(now) = procs::sample() else {
            self.view.borrow_mut().status = "The process table could not be read.".into();
            return;
        };
        let table = ProcessTable::new(&now, self.last.borrow().as_ref());
        {
            let mut v = self.view.borrow_mut();
            (v.memory_total, v.memory_available) = (now.memory_total, now.memory_available);
            let cpus = std::thread::available_parallelism().map_or(1, |n| n.get());
            v.cpu_total = table.rows.iter().map(|r| r.cpu_percent).sum::<f64>() / cpus as f64;
        }
        *self.table.borrow_mut() = table;
        *self.last.borrow_mut() = Some(now);
        self.rebuild()
    }

    /// Filter, sort, and keep the selection on the same process.
    fn rebuild(&self) {
        let l = self.layout();
        {
            let mut v = self.view.borrow_mut();
            let filter = if v.mine_only { Filter::Mine(self.uid) } else { Filter::All };
            let mut rows = self.table.borrow().view(filter, v.sort_by, v.ascending, &procs::user_name);
            let f = v.filter.to_lowercase();
            if !f.is_empty() {
                rows.retain(|r| r.info.name.to_lowercase().contains(&f))
            }
            if v.selected.is_some_and(|s| !rows.iter().any(|r| r.info.identity() == s)) {
                v.selected = None
            }
            v.scroll = v.scroll.min(rows.len().saturating_sub(l.visible()));
            v.rows = rows;
        }
        self.redraw();
        if self.dump {
            self.dump_rows(&l)
        }
    }

    fn dump_rows(&self, l: &ActivityLayout) {
        let v = self.view.borrow();
        let parts: Vec<String> = v.rows.iter().skip(v.scroll).take(l.visible()).enumerate().map(|(i, r)| format!("{}@{}", r.info.pid, (l.table.y + i as f64 * l.row_height + l.row_height / 2.0) as i64)).collect();
        let line = format!("rows {}: {}", v.rows.len(), parts.join(" "));
        if *self.last_dump.borrow() != line {
            log(&line);
            *self.last_dump.borrow_mut() = line
        }
    }

    fn row_at(&self, y: f64) -> Option<Row> {
        let l = self.layout();
        if y < l.table.y || y >= l.table.y + l.table.h {
            return None;
        }
        let v = self.view.borrow();
        v.rows.get(((y - l.table.y) / l.row_height) as usize + v.scroll).cloned()
    }

    fn selected_row(&self) -> Option<Row> {
        let v = self.view.borrow();
        v.rows.iter().find(|r| Some(r.info.identity()) == v.selected).cloned()
    }

    fn set_status(&self, s: String) {
        self.view.borrow_mut().status = s;
        self.redraw()
    }

    // MARK: quitting

    fn ask_to_quit(&self) -> CommandResult {
        let Some(r) = self.selected_row() else { return CommandResult::Refused("no process is selected".into()) };
        if r.info.system {
            return CommandResult::Refused(format!("{} is part of the kernel, and is not quit", r.info.name));
        }
        log(&format!("asked to quit {} (pid {})", r.info.name, r.info.pid));
        *self.asking.borrow_mut() = Some(r);
        self.redraw();
        ok()
    }

    /// `Some(force)` to quit, None to cancel.
    fn answer(&self, force: Option<bool>) {
        let Some(r) = self.asking.borrow_mut().take() else { return };
        self.redraw();
        let Some(force) = force else { return log("quit cancelled") };
        let what = if force { "force quit" } else { "quit" };
        let (name, pid) = (r.info.name.clone(), r.info.pid);
        if r.info.uid == self.uid {
            // Still the process that was chosen? A pid freed and reused since
            // would be somebody else's program.
            let still = procs::sample().and_then(|s| s.processes.into_iter().find(|p| p.pid == pid)).is_some_and(|p| p.identity() == r.info.identity() && p.name == name);
            if !still {
                log(&format!("{what} {name}: it has already quit"));
                return self.set_status(format!("{name} has already quit."));
            }
            match abyss_sys::proc::kill_pid(pid, if force { libc::SIGKILL } else { libc::SIGTERM }) {
                Ok(()) => {
                    log(&format!("{what} {name} (pid {pid}): sent {}", if force { "SIGKILL" } else { "SIGTERM" }));
                    self.view.borrow_mut().status = format!("Sent {} to {name}.", if force { "Force Quit" } else { "Quit" })
                }
                Err(e) => {
                    log(&format!("{what} {name}: {e}"));
                    self.view.borrow_mut().status = format!("Could not quit {name}: {e}.")
                }
            }
            return self.refresh();
        }
        // Another user's: the helper decides, as root, with the same checks.
        let plan = SettingsPlan::Signal(SignalPlan { pid, force, started: r.info.started, name: name.clone() });
        let me = self.me.clone();
        let started = Apply::begin(&self.display, &client::apply_request(&plan), |_| {}, move |ok, said| {
            let Some(a) = me.upgrade() else { return };
            *a.helper.borrow_mut() = None;
            let err = said.strip_prefix("Not applied: ").unwrap_or(&said).to_string();
            log(&format!("helper: {}", if ok { "done".into() } else { format!("refused: {err}") }));
            a.view.borrow_mut().status = if ok { format!("Quit {name}.") } else { format!("Not quit: {err}") };
            a.refresh()
        });
        match started {
            Some(h) => {
                log(&format!("{what} {} (pid {pid}, uid {}): asked the helper", r.info.name, r.info.uid));
                *self.helper.borrow_mut() = Some(h)
            }
            None => {
                log(&format!("{what} {}: no settings helper", r.info.name));
                self.set_status("The settings helper is not running, so another user's process cannot be quit.".into())
            }
        }
    }

    // MARK: verbs

    fn validate(&self, verb: &str) -> Enablement {
        match verb {
            VERB_ABOUT => Enablement::Disabled("Activity Monitor has no About box yet".into()),
            VERB_QUIT_PROCESS => match self.selected_row() {
                None => Enablement::Disabled("no process is selected".into()),
                Some(r) if r.info.system => Enablement::Disabled("a kernel process is not quit".into()),
                Some(_) => Enablement::Enabled,
            },
            _ => Enablement::Enabled,
        }
    }

    fn show_mine(&self, mine: bool) {
        self.view.borrow_mut().mine_only = mine;
        self.rebuild()
    }

    fn perform(&self, verb: &str) -> CommandResult {
        match verb {
            VERB_QUIT | VERB_CLOSE => std::process::exit(0),
            VERB_MINIMIZE => {
                if let Some(w) = self.window.borrow().as_ref() {
                    w.minimize();
                }
                ok()
            }
            VERB_MINE => {
                self.show_mine(true);
                ok()
            }
            VERB_ALL => {
                self.show_mine(false);
                ok()
            }
            VERB_REFRESH => {
                self.refresh();
                ok()
            }
            VERB_QUIT_PROCESS => self.ask_to_quit(),
            v => CommandResult::Refused(format!("Activity Monitor has no verb {v}")),
        }
    }
}

impl WindowDelegate for ActivityMonitor {
    fn render(&self, _w: &Window, target: &RenderTarget) {
        let v = self.view.borrow().clone();
        let asking = self.asking.borrow().as_ref().map(|r| r.info.name.clone());
        let (l, sheet) = self.toolkit.draw(target, |c, w, h| {
            let l = paint_activity(c, w, h, &v, &procs::user_name);
            (l, asking.map(|n| paint_quit_sheet(c, w, &n)))
        });
        if self.dump {
            let at = |r: Rect| format!("{},{}", (r.x + r.w / 2.0) as i64, (r.y + r.h / 2.0) as i64);
            if !self.logged.replace(true) {
                log(&format!("toolbar quit={} mine={} all={} filter={} header={}", at(l.quit_button), at(l.mine), at(l.all), at(l.filter), (l.header.y + l.header.h / 2.0) as i64))
            }
            if let Some(s) = sheet {
                log(&format!("sheet quit={} force={} cancel={}", at(s.quit), at(s.force), at(s.cancel)))
            }
        }
    }

    fn pointer_moved(&self, _w: &Window, x: f64, y: f64) {
        self.pointer.set((x, y))
    }

    fn pointer_button(&self, w: &Window, button: u32, pressed: bool) {
        if !pressed {
            return;
        }
        let (x, y) = self.pointer.get();
        let (sw, sh) = w.size();
        let t = self.toolkit.theme.borrow().tokens.clone();
        match chrome_hit(&t, &window_chrome(&t, sw as f64, sh as f64, false), x, y) {
            ChromeHit::Gadget(Gadget::Close) => std::process::exit(0),
            ChromeHit::Gadget(Gadget::Minimize) => {
                w.minimize();
                return;
            }
            ChromeHit::Gadget(Gadget::Zoom) => return w.set_maximized(!w.is_maximized()),
            ChromeHit::Gadget(Gadget::Depth) => {
                w.lower();
                return;
            }
            ChromeHit::Title => return w.begin_move(),
            ChromeHit::Resize(e) => {
                return w.begin_resize(match e {
                    ChromeEdge::Bottom => ResizeEdge::BOTTOM,
                    ChromeEdge::BottomLeft => ResizeEdge::BOTTOM_LEFT,
                    ChromeEdge::BottomRight => ResizeEdge::BOTTOM_RIGHT,
                })
            }
            ChromeHit::Gadget(Gadget::Pill) | ChromeHit::Content => {}
        }
        if button != 0x110 {
            return;
        }
        if self.asking.borrow().is_some() {
            let s = QuitSheetLayout::new(t.title_bar_height, sw as f64);
            if s.quit.contains(x, y) {
                self.answer(Some(false))
            } else if s.force.contains(x, y) {
                self.answer(Some(true))
            } else if s.cancel.contains(x, y) {
                self.answer(None)
            }
            return;
        }
        let l = ActivityLayout::new(&t, sw as f64, sh as f64);
        if l.quit_button.contains(x, y) {
            if let CommandResult::Refused(why) = self.ask_to_quit() {
                self.set_status(why)
            }
            return;
        }
        if l.mine.contains(x, y) || l.all.contains(x, y) {
            return self.show_mine(l.mine.contains(x, y));
        }
        if l.header.contains(x, y) {
            let mut cx = 8.0;
            for (col, _, width, _) in COLUMNS {
                if x >= cx && x < cx + width {
                    {
                        let mut v = self.view.borrow_mut();
                        if v.sort_by == col {
                            v.ascending = !v.ascending
                        } else {
                            v.sort_by = col;
                            v.ascending = matches!(col, Column::Name | Column::User | Column::Pid)
                        }
                    }
                    return self.rebuild();
                }
                cx += width
            }
            return;
        }
        if let Some(r) = self.row_at(y) {
            self.view.borrow_mut().selected = Some(r.info.identity());
            if self.dump {
                log(&format!("selected {} (pid {})", r.info.name, r.info.pid))
            }
            self.redraw()
        }
    }

    fn pointer_axis(&self, _w: &Window, axis: u32, value: f64) {
        if axis != 0 {
            return;
        }
        {
            let mut v = self.view.borrow_mut();
            v.scroll = (v.scroll as i64 + (value / 10.0 * 3.0).round() as i64).max(0) as usize
        }
        self.rebuild()
    }

    fn key_event(&self, _w: &Window, e: &KeyEvent) {
        if !e.pressed {
            return;
        }
        if self.asking.borrow().is_some() {
            match e.keysym {
                KeySym::ENTER => self.answer(Some(false)),
                KeySym::ESCAPE => self.answer(None),
                _ => {}
            }
            return;
        }
        if e.modifiers.contains(KeyModifiers::COMMAND) {
            if let Some(verb) = key_equivalent_of(e).and_then(|k| activity_menu_bar().verb_for(&k).map(String::from))
                && let CommandResult::Refused(why) = self.perform(&verb)
            {
                log(&format!("{verb} refused: {why}"))
            }
            return;
        }
        match e.keysym {
            KeySym::UP | KeySym::DOWN => {
                let mut v = self.view.borrow_mut();
                let i = v.rows.iter().position(|r| Some(r.info.identity()) == v.selected).map_or(-1, |i| i as i64);
                let j = (i + if e.keysym == KeySym::UP { -1 } else { 1 }).clamp(0, v.rows.len() as i64 - 1);
                if j >= 0 {
                    v.selected = Some(v.rows[j as usize].info.identity())
                }
            }
            KeySym::BACKSPACE => {
                if self.view.borrow_mut().filter.pop().is_some() {
                    self.rebuild()
                }
            }
            KeySym::ESCAPE => {
                self.view.borrow_mut().filter.clear();
                self.rebuild()
            }
            // Typing narrows the table by name, as the toolbar's filter field.
            _ => {
                if e.text.is_empty() || !e.text.chars().all(|c| c as u32 >= 0x20 && c as u32 != 0x7f) {
                    return;
                }
                self.view.borrow_mut().filter.push_str(&e.text);
                self.rebuild()
            }
        }
        self.redraw()
    }

    fn should_close(&self, _w: &Window) {
        std::process::exit(0)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_sample_sorts_by_cpu_and_selects_aquademo() {
        let v = sample_view();
        assert_eq!(v.rows.iter().map(|r| r.info.pid).take(3).collect::<Vec<_>>(), [901, 812, 840]);
        assert_eq!(v.selected, Some((840, 100)));
    }

    #[test]
    fn the_sheets_buttons_sit_inside_it() {
        let l = QuitSheetLayout::new(22.0, 620.0);
        for b in [l.quit, l.force, l.cancel] {
            assert!(l.panel.contains(b.x + 1.0, b.y + 1.0))
        }
    }
}
