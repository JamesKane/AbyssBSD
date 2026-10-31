//! Crash Reporter: "The application … has unexpectedly quit"
//! (CrashReport.swift, PHASE18 P18.9b).
//!
//! Jaguar told you when an application died, and said the rest of the
//! system was fine. A confined application's crash is said the same way,
//! with what is true of a jail: nothing else was affected. The keeper
//! starts this dialog when a program it launched dies of a signal
//! (`AQUA_SCENE=crashreport`, `ABYSS_CRASH_*`). If the crash left a core,
//! **Ask the Agent…** asks the keeper for a `debug` session on that crash
//! alone (its core and binary, read-only), and opens the Agent window on it
//! with the question asked.
//!
//! Nothing here waits: the keeper's answer comes through the display's poll
//! loop. A refusal is shown in the keeper's words, with an OK.

use crate::commands::key_equivalent_of;
use crate::launcher::{launch_detached, self_executable};
use crate::toolkit::Toolkit;
use aquadraw::canvas::Canvas;
use aquadraw::chrome::{chrome_hit, window_chrome, ChromeHit};
use aquadraw::color::Color;
use aquadraw::draw::paint_window_chrome;
use aquadraw::drawlist::Role;
use aquadraw::runner::Rect;
use aquadraw::text::Style;
use current_ipc::Msg;
use menu_model::{Command, CommandResult, Enablement, KeyEquivalent, Menu, MenuBarModel, MenuItem, Modifiers};
use menu_wire::{MenuProvider, MenuService};
use std::cell::{Cell, RefCell};
use std::collections::BTreeMap;
use std::os::fd::AsRawFd;
use std::rc::{Rc, Weak};
use surface::{Display, KeyEvent, KeyModifiers, KeySym, RenderTarget, Window, WindowDelegate};

pub const VERB_ASK: &str = "crash.ask";
pub const VERB_CLOSE: &str = "crash.close";

/// What crashed, as the keeper said it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CrashNotice {
    pub id: u64,
    pub app: String,
    pub signal: String,
    pub core: bool,
    /// Whether agents are on (P18.13): off, there is no Ask the Agent.
    pub agents: bool,
}

impl CrashNotice {
    pub fn new(id: u64, app: &str, signal: &str, core: bool) -> CrashNotice {
        CrashNotice { id, app: app.into(), signal: signal.into(), core, agents: true }
    }

    /// From the keeper's environment (`ABYSS_CRASH_ID`, `_APP`, `_SIGNAL`,
    /// `_CORE`) and `ABYSS_AGENTS`.
    pub fn from_environment() -> CrashNotice {
        let e = |n: &str| std::env::var(n).ok();
        CrashNotice {
            id: e("ABYSS_CRASH_ID").and_then(|s| s.parse().ok()).unwrap_or(0),
            app: e("ABYSS_CRASH_APP").unwrap_or_else(|| "An application".into()),
            signal: e("ABYSS_CRASH_SIGNAL").unwrap_or_else(|| "a signal".into()),
            core: e("ABYSS_CRASH_CORE").as_deref() == Some("1"),
            agents: e("ABYSS_AGENTS").as_deref() == Some("1"),
        }
    }

    pub fn headline(&self) -> String {
        format!("The application {} has unexpectedly quit.", self.app)
    }

    pub fn detail(&self) -> String {
        let tail = if !self.core {
            ", and left nothing to read."
        } else if self.agents {
            "; an agent can read what it left and say why."
        } else {
            "."
        };
        format!("It ran confined, so nothing else was affected. It was killed by {}{tail}", self.signal)
    }

    /// Whether to offer Ask the Agent: a core to read, and agents on.
    pub fn can_ask(&self) -> bool {
        self.core && self.agents
    }

    /// The question the Agent window is opened with.
    pub fn question(&self) -> String {
        format!("Why did {} crash?", self.app)
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CrashChoice {
    Close,
    Ask,
    Ok,
}

impl CrashChoice {
    pub fn label(self) -> &'static str {
        match self {
            CrashChoice::Close => "Close",
            CrashChoice::Ask => "Ask the Agent…",
            CrashChoice::Ok => "OK",
        }
    }

    /// The name a test reads it by.
    fn key(self) -> &'static str {
        match self {
            CrashChoice::Close => "close",
            CrashChoice::Ask => "ask",
            CrashChoice::Ok => "ok",
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct CrashReportLayout {
    pub icon: Rect,
    pub text_x: f64,
    pub buttons: Vec<(CrashChoice, Rect)>,
}

impl CrashReportLayout {
    /// The buttons right-aligned, the last the default; Ask is wider.
    pub fn new(title_bar: f64, choices: &[CrashChoice], w: f64, h: f64) -> CrashReportLayout {
        let (bh, gap) = (22.0, 12.0);
        let y = h - bh - 18.0;
        let widths: Vec<f64> = choices.iter().map(|c| if *c == CrashChoice::Ask { 128.0 } else { 92.0 }).collect();
        let mut x = w - 20.0 - widths.iter().sum::<f64>() - gap * choices.len().saturating_sub(1) as f64;
        let mut buttons = vec![];
        for (c, bw) in choices.iter().zip(widths) {
            buttons.push((*c, Rect::new(x, y, bw, bh)));
            x += bw + gap
        }
        CrashReportLayout { icon: Rect::new(20.0, title_bar + 16.0, 64.0, 64.0), text_x: 100.0, buttons }
    }

    pub fn hit(&self, x: f64, y: f64) -> Option<CrashChoice> {
        self.buttons.iter().find(|(_, r)| r.contains(x, y)).map(|(c, _)| *c)
    }
}

pub fn paint_crash_report(c: &mut Canvas, w: f64, h: f64, notice: &CrashNotice, refusal: Option<&str>, choices: &[CrashChoice]) -> CrashReportLayout {
    paint_window_chrome(c.runner, c.theme, c.cr, w, h, "", false, true);
    let t = c.theme.tokens.clone();
    c.set_color(t.content_background);
    c.cr.rectangle(0.0, t.title_bar_height, w, h - t.title_bar_height);
    c.cr.fill();
    let l = CrashReportLayout::new(t.title_bar_height, choices, w, h);
    c.icon("dock.icon.genericApp", l.icon);
    let width = w - l.text_x - 20.0;
    let mut y = t.title_bar_height + 30.0;
    for line in c.wrap_words(&notice.headline(), width, 13.0, Style::Bold) {
        c.text_left(&line, l.text_x, y, t.body_text, 13.0, Style::Bold, Role::Interface);
        y += 18.0
    }
    y += 4.0;
    let (said, color) = match refusal {
        Some(r) => (r.to_string(), Color::new(0.65, 0.05, 0.05, 1.0)),
        None => (notice.detail(), t.body_text),
    };
    for line in c.wrap_words(&said, width, 11.0, Style::Regular) {
        c.text_left(&line, l.text_x, y, color, 11.0, Style::Regular, Role::Interface);
        y += 15.0
    }
    for (choice, r) in &l.buttons {
        c.gel_button(*r, choice.label(), Some(choice) == choices.last(), false)
    }
    l
}

pub fn crash_report_menu_bar() -> MenuBarModel {
    MenuBarModel::new(
        "Crash Reporter",
        vec![Menu::new(
            "Crash Reporter",
            vec![
                MenuItem::Command(Command::new(VERB_ASK, "Ask the Agent…", "Start an agent on this crash, and ask it why.")),
                MenuItem::Separator,
                MenuItem::Command(Command::new(VERB_CLOSE, "Close", "Close this report.").with_key(KeyEquivalent::cmd('w', Modifiers::NONE))),
            ],
        )],
    )
}

fn log(s: &str) {
    eprintln!("CrashReport: {s}")
}

// MARK: - The dialog

pub struct CrashReport {
    me: Weak<CrashReport>,
    display: Rc<Display>,
    toolkit: Rc<Toolkit>,
    window: RefCell<Option<Rc<Window>>>,
    pub notice: CrashNotice,
    choices: RefCell<Vec<CrashChoice>>,
    refusal: RefCell<Option<String>>,
    asking: Cell<bool>,
    pointer: Cell<(f64, f64)>,
    logged: Cell<bool>,
    menu_service: RefCell<Option<MenuService>>,
    /// What happens when the report is done; by default, the process ends.
    pub on_done: RefCell<Box<dyn Fn()>>,
}

struct Provider<'a>(&'a CrashReport);

impl MenuProvider for Provider<'_> {
    fn menu_model(&self) -> MenuBarModel {
        crash_report_menu_bar()
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

impl CrashReport {
    pub fn new(display: &Rc<Display>, toolkit: &Rc<Toolkit>, notice: CrashNotice) -> Option<Rc<CrashReport>> {
        let choices = if notice.can_ask() { vec![CrashChoice::Close, CrashChoice::Ask] } else { vec![CrashChoice::Ok] };
        let app = Rc::new_cyclic(|me| CrashReport {
            me: me.clone(),
            display: display.clone(),
            toolkit: toolkit.clone(),
            window: RefCell::new(None),
            notice,
            choices: RefCell::new(choices),
            refusal: RefCell::new(None),
            asking: Cell::new(false),
            pointer: Cell::new((0.0, 0.0)),
            logged: Cell::new(false),
            menu_service: RefCell::new(None),
            on_done: RefCell::new(Box::new(|| std::process::exit(0))),
        });
        let name = menu_wire::service_name("Crash Reporter", std::process::id() as i32);
        if let Ok(s) = MenuService::new(&name) {
            let me = app.me.clone();
            display.add_fd(s.fd(), move || {
                if let Some(a) = me.upgrade() {
                    a.serve()
                }
            });
            *app.menu_service.borrow_mut() = Some(s);
        }
        let pinned = std::env::var("AQUA_SCALE").ok().and_then(|s| s.parse::<i32>().ok()).filter(|v| *v > 0);
        let win = Window::new(display, "", "org.abyssbsd.crashreport", 480, 180, pinned.unwrap_or(1), pinned.is_none(), Rc::downgrade(&app) as Weak<dyn WindowDelegate>)?;
        if app.menu_service.borrow().is_some() && win.publish_menus(&name) {
            log(&format!("menus on {name}"))
        }
        *app.window.borrow_mut() = Some(win);
        let n = &app.notice;
        log(&format!("up: crash {}, {}, {}, core {}", n.id, n.app, n.signal, if n.core { "yes" } else { "no" }));
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

    // MARK: Ask the Agent

    fn ask(&self) {
        if !self.notice.can_ask() || self.asking.get() {
            return;
        }
        let Ok(sock) = current_ipc::connect("jails") else { return self.refuse("The session's jails are not running.") };
        let mut m = Msg::new();
        m.set_string("method", "debug");
        m.set_u64("crash", self.notice.id);
        if current_ipc::send(&m, &sock).is_err() {
            return self.refuse("The session's jails did not answer.");
        }
        self.asking.set(true);
        log(&format!("asked for a debug session on crash {}", self.notice.id));
        let fd = sock.as_raw_fd();
        let (me, sock) = (self.me.clone(), RefCell::new(Some(sock)));
        self.display.add_fd(fd, move || {
            let Some(a) = me.upgrade() else { return };
            a.display.remove_fd(fd);
            let Some(sock) = sock.borrow_mut().take() else { return };
            let r = current_ipc::receive(&sock).ok();
            drop(sock);
            a.asking.set(false);
            a.answered(r)
        })
    }

    fn answered(&self, r: Option<Msg>) {
        let Some(r) = r else { return self.refuse("The session's jails did not answer.") };
        let Some(socket) = r.string("socket").filter(|_| r.bool("ok") == Some(true)) else {
            return self.refuse(r.string("error").unwrap_or("The session's jails did not answer."));
        };
        log(&format!("debug session {} at {socket}", r.string("session").unwrap_or("")));
        // The Agent window, on that session, with the question asked.
        let question = self.notice.question();
        let env = [("AQUA_SCENE", "agent"), ("ABYSS_AGENT_SOCKET", socket), ("ABYSS_AGENT_CLASS", "debug"), ("ABYSS_AGENT_ASK", question.as_str())];
        if !self_executable().is_some_and(|exe| launch_detached(&[exe], &env)) {
            return self.refuse("The Agent window could not be opened.");
        }
        self.finish()
    }

    fn refuse(&self, why: &str) {
        log(&format!("refused: {why}"));
        *self.refusal.borrow_mut() = Some(why.into());
        *self.choices.borrow_mut() = vec![CrashChoice::Ok];
        self.logged.set(false);
        self.redraw()
    }

    fn finish(&self) {
        log("closed");
        // Dropped after the borrow ends: closing may call back into us.
        let w = self.window.borrow_mut().take();
        drop(w);
        (self.on_done.borrow())()
    }

    fn choose(&self, c: CrashChoice) {
        match c {
            CrashChoice::Ask => self.ask(),
            CrashChoice::Close | CrashChoice::Ok => self.finish(),
        }
    }

    // MARK: the menu

    fn validate(&self, verb: &str) -> Enablement {
        match verb {
            VERB_ASK if !self.notice.core => Enablement::Disabled("it left nothing to read".into()),
            VERB_ASK if !self.notice.agents => Enablement::Disabled("agents are off".into()),
            VERB_ASK if self.asking.get() => Enablement::Disabled("an agent is being started".into()),
            VERB_ASK if !self.choices.borrow().contains(&CrashChoice::Ask) => Enablement::Disabled("this report was answered".into()),
            _ => Enablement::Enabled,
        }
    }

    fn perform(&self, verb: &str) -> CommandResult {
        match verb {
            VERB_ASK => self.ask(),
            VERB_CLOSE => self.finish(),
            _ => return CommandResult::Refused(format!("Crash Reporter has no verb {verb}")),
        }
        CommandResult::Ok(None)
    }
}

impl WindowDelegate for CrashReport {
    fn render(&self, _w: &Window, target: &RenderTarget) {
        let (notice, refusal, choices) = (&self.notice, self.refusal.borrow().clone(), self.choices.borrow().clone());
        let l = self.toolkit.draw(target, |c, w, h| paint_crash_report(c, w, h, notice, refusal.as_deref(), &choices));
        if !self.logged.replace(true) {
            let at: Vec<String> = l.buttons.iter().map(|(c, r)| format!("{}={},{}", c.key(), (r.x + r.w / 2.0) as i64, (r.y + r.h / 2.0) as i64)).collect();
            log(&format!("buttons {}", at.join(" ")))
        }
    }

    fn pointer_moved(&self, _w: &Window, x: f64, y: f64) {
        self.pointer.set((x, y))
    }

    fn pointer_button(&self, w: &Window, _button: u32, pressed: bool) {
        if !pressed {
            return;
        }
        let (x, y) = self.pointer.get();
        let (sw, sh) = w.size();
        let t = self.toolkit.theme.borrow().tokens.clone();
        match chrome_hit(&t, &window_chrome(&t, sw as f64, sh as f64, false), x, y) {
            ChromeHit::Gadget(aquadraw::chrome::Gadget::Close) => return self.finish(),
            ChromeHit::Title => return w.begin_move(),
            _ => {}
        }
        let hit = CrashReportLayout::new(t.title_bar_height, &self.choices.borrow(), sw as f64, sh as f64).hit(x, y);
        if let Some(c) = hit {
            self.choose(c)
        }
    }

    fn key_event(&self, _w: &Window, e: &KeyEvent) {
        if !e.pressed {
            return;
        }
        if e.keysym == KeySym::ENTER || e.keysym == 0xff8d {
            let default = self.choices.borrow().last().copied();
            if let Some(d) = default {
                self.choose(d)
            }
        } else if e.keysym == KeySym::ESCAPE {
            self.finish()
        } else if e.modifiers.contains(KeyModifiers::COMMAND)
            && let Some(verb) = key_equivalent_of(e).and_then(|k| crash_report_menu_bar().verb_for(&k).map(String::from))
            && self.validate(&verb) == Enablement::Enabled
        {
            self.perform(&verb);
        }
    }

    fn should_close(&self, _w: &Window) {
        self.finish()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn it_says_what_happened_and_what_can_be_done() {
        let n = CrashNotice::new(2, "galculator", "SIGSEGV", true);
        assert_eq!(n.headline(), "The application galculator has unexpectedly quit.");
        assert_eq!(n.detail(), "It ran confined, so nothing else was affected. It was killed by SIGSEGV; an agent can read what it left and say why.");
        assert_eq!(n.question(), "Why did galculator crash?");
        let none = CrashNotice::new(3, "sh", "SIGKILL", false);
        assert_eq!(none.detail(), "It ran confined, so nothing else was affected. It was killed by SIGKILL, and left nothing to read.");
    }

    /// Agents off (P18.13): a core, but no Ask the Agent, and no promise of one.
    #[test]
    fn with_agents_off_there_is_no_ask() {
        let n = CrashNotice { agents: false, ..CrashNotice::new(1, "galculator", "SIGSEGV", true) };
        assert!(!n.can_ask());
        assert_eq!(n.detail(), "It ran confined, so nothing else was affected. It was killed by SIGSEGV.");
        assert!(CrashNotice::new(1, "g", "SIGSEGV", true).can_ask());
    }

    #[test]
    fn ask_is_the_default_when_there_is_a_core() {
        let l = CrashReportLayout::new(22.0, &[CrashChoice::Close, CrashChoice::Ask], 480.0, 180.0);
        assert_eq!(l.buttons.iter().map(|b| b.0).collect::<Vec<_>>(), [CrashChoice::Close, CrashChoice::Ask]);
        let ask = l.buttons[1].1;
        assert_eq!(ask.x + ask.w, 460.0, "right-aligned, 20 from the edge");
        assert_eq!(l.hit(ask.x + 5.0, ask.y + 5.0), Some(CrashChoice::Ask));
        let close = l.buttons[0].1;
        assert_eq!(l.hit(close.x + 5.0, close.y + 5.0), Some(CrashChoice::Close));
        assert_eq!(l.hit(5.0, 5.0), None);
        assert!(close.x + close.w < ask.x, "the buttons do not overlap");
    }

    #[test]
    fn the_menu_offers_the_same_two_things() {
        let verbs: Vec<String> = crash_report_menu_bar().menus.iter().flat_map(|m| m.items.iter()).filter_map(|i| if let MenuItem::Command(c) = i { Some(c.verb.clone()) } else { None }).collect();
        assert_eq!(verbs, [VERB_ASK, VERB_CLOSE]);
    }
}
