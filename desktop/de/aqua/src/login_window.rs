//! The Aqua login window (LoginWindow.swift, P16.5a): with nobody logged
//! in, Jaguar's list of the people who can, each with a picture; choose one
//! and type their password. A refusal shakes the panel (the lock screen's
//! model); too many and the field counts down. Sleep, Restart and Shut Down
//! sit along the bottom and go straight to the root daemon.
//!
//! It runs as `_loginwindow`, in a session of its own (P16.5b), and asks
//! the daemon the one question only that account may: is this *that
//! account's* password? On a yes the daemon ends this session and starts
//! theirs; this window only says "Logging in…".

use crate::lock_screen::{note_color, paint_sheet, LockModel, LockPhase};
use crate::toolkit::Toolkit;
use crate::wallpaper::{paint_desktop, DesktopFill};
use aquadraw::color::Color;
use aquadraw::drawlist::Role;
use aquadraw::runner::Rect;
use aquadraw::text::Style;
use current_ipc::Msg;
use login::{LoginAccount, PowerAction, Verdict};
use std::cell::{Cell, RefCell};
use std::collections::BTreeSet;
use std::os::fd::AsRawFd;
use std::os::unix::net::UnixStream;
use std::rc::{Rc, Weak};
use std::time::Instant;
use surface::layer::{anchor, KeyboardInteractivity, Layer};
use surface::{Display, KeyEvent, KeySym, LayerConfig, LayerSurface, LayerSurfaceDelegate, RenderTarget};

pub const ROW_HEIGHT: f64 = 56.0;
pub const VISIBLE_ROWS: usize = 5;

/// Where everything is on a display this size: one layout for paint, hit
/// and the test's log.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct LoginWindowLayout {
    pub panel: Rect,
    pub rows: Vec<Rect>,
    pub field: Rect,
    pub back: Rect,
    pub log_in: Rect,
    pub sleep: Rect,
    pub restart: Rect,
    pub shut_down: Rect,
}

impl LoginWindowLayout {
    pub fn new(w: f64, h: f64, accounts: usize) -> LoginWindowLayout {
        let panel = Rect::new(((w - 420.0) / 2.0).round(), ((h - 400.0) / 2.0).round(), 420.0, 400.0);
        let top = panel.y + 70.0;
        let rows = (0..accounts.min(VISIBLE_ROWS)).map(|i| Rect::new(panel.x + 30.0, top + i as f64 * ROW_HEIGHT, panel.w - 60.0, ROW_HEIGHT - 4.0)).collect();
        let by = panel.y + panel.h - 40.0;
        LoginWindowLayout {
            rows,
            field: Rect::new(panel.x + 70.0, panel.y + 220.0, panel.w - 140.0, 24.0),
            back: Rect::new(panel.x + 70.0, panel.y + 268.0, 120.0, 22.0),
            log_in: Rect::new(panel.x + panel.w - 190.0, panel.y + 268.0, 120.0, 22.0),
            sleep: Rect::new(panel.x + 30.0, by, 100.0, 22.0),
            restart: Rect::new(panel.x + 160.0, by, 100.0, 22.0),
            shut_down: Rect::new(panel.x + 290.0, by, 100.0, 22.0),
            panel,
        }
    }
}

fn log(s: &str) {
    eprintln!("LoginWindow: {s}")
}

/// One request to the daemon, one reply.
fn call(socket: &str, method: &str, user: Option<&str>) -> Option<Msg> {
    let mut m = Msg::new();
    m.set_string("method", method);
    if let Some(u) = user {
        m.set_string("user", u)
    }
    login::client::call(m, socket).ok().filter(|r| r.bool("ok") == Some(true))
}

struct State {
    /// The account whose password is asked; None shows the list.
    chosen: Option<LoginAccount>,
    highlighted: usize,
    model: LockModel,
    pointer: (f64, f64),
    logged_layout: String,
}

pub struct LoginWindow {
    me: Weak<LoginWindow>,
    display: Rc<Display>,
    toolkit: Rc<Toolkit>,
    layer: RefCell<Option<Rc<LayerSurface>>>,
    pub accounts: Vec<LoginAccount>,
    /// Who already has a session (P16.6b): choosing them goes back to it,
    /// and its own lock screen asks.
    pub logged_in: BTreeSet<String>,
    socket: String,
    fill: DesktopFill,
    state: RefCell<State>,
    asking: RefCell<Option<UnixStream>>,
    timer: Cell<Option<u64>>,
    epoch: Instant,
}

impl LoginWindow {
    pub fn new(display: &Rc<Display>, toolkit: &Rc<Toolkit>, accounts: Vec<LoginAccount>) -> Option<Rc<LoginWindow>> {
        let socket = login::client::socket();
        let logged_in: BTreeSet<String> = call(&socket, "sessions", None).map(|r| r.string("users").unwrap_or("").split(' ').filter(|u| !u.is_empty()).map(String::from).collect()).unwrap_or_default();
        let lw = Rc::new_cyclic(|me| LoginWindow {
            me: me.clone(),
            display: display.clone(),
            toolkit: toolkit.clone(),
            layer: RefCell::new(None),
            accounts,
            logged_in,
            socket,
            fill: DesktopFill::from(&pool_config::load("desktop", None).unwrap_or_default()),
            state: RefCell::new(State { chosen: None, highlighted: 0, model: LockModel::default(), pointer: (0.0, 0.0), logged_layout: String::new() }),
            asking: RefCell::new(None),
            timer: Cell::new(None),
            epoch: Instant::now(),
        });
        let lc = LayerConfig { layer: Layer::Top, namespace: "abyss-loginwindow".into(), anchor: anchor::ALL, exclusive_zone: -1, keyboard: KeyboardInteractivity::Exclusive, ..LayerConfig::default() };
        let ls = LayerSurface::new(display, &lc, 1, true, Rc::downgrade(&lw) as Weak<dyn LayerSurfaceDelegate>)?;
        *lw.layer.borrow_mut() = Some(ls);
        if !lw.logged_in.is_empty() {
            log(&format!("logged in: {}", lw.logged_in.iter().cloned().collect::<Vec<_>>().join(" ")))
        }
        log(&format!("up: {}", if lw.accounts.is_empty() { "no accounts".into() } else { lw.accounts.iter().map(|a| a.name.as_str()).collect::<Vec<_>>().join(" ") }));
        Some(lw)
    }

    fn now(&self) -> u64 {
        self.epoch.elapsed().as_nanos() as u64
    }

    fn redraw(&self) {
        let l = self.layer.borrow().clone();
        if let Some(l) = l {
            l.set_needs_display()
        }
    }

    fn layout(&self) -> LoginWindowLayout {
        let (w, h) = self.layer.borrow().as_ref().map_or((0, 0), |l| l.size());
        LoginWindowLayout::new(w as f64, h as f64, self.accounts.len())
    }

    fn log_layout(&self, l: &LoginWindowLayout) {
        let c = |r: &Rect| format!("{},{}", (r.x + r.w / 2.0) as i64, (r.y + r.h / 2.0) as i64);
        let mut line = "layout".to_string();
        for (a, r) in self.accounts.iter().zip(&l.rows) {
            line += &format!(" {}={}", a.name, c(r))
        }
        line += &format!(" field={} back={} login={} sleep={} restart={} shutdown={}", c(&l.field), c(&l.back), c(&l.log_in), c(&l.sleep), c(&l.restart), c(&l.shut_down));
        let mut s = self.state.borrow_mut();
        if line != s.logged_layout {
            log(&line);
            s.logged_layout = line
        }
    }

    fn paint(&self, c: &mut aquadraw::canvas::Canvas, l: &LoginWindowLayout, dx: f64) {
        let s = self.state.borrow();
        let shift = |r: Rect| Rect { x: r.x + dx, ..r };
        let p = shift(l.panel);
        paint_sheet(c, p);
        let text = |c: &mut aquadraw::canvas::Canvas, t: &str, cy: f64, k: Color, size: f64, style: Style| c.text(t, p.x + p.w / 2.0, cy, k, size, style, Role::Interface);
        text(c, "AbyssBSD", p.y + 34.0, Color::new(0.1, 0.1, 0.1, 1.0), 20.0, Style::Bold);
        if let Some(who) = &s.chosen {
            c.icon("icon.myAccount", Rect::new(p.x + p.w / 2.0 - 40.0, p.y + 70.0, 80.0, 80.0));
            text(c, &who.full_name, p.y + 175.0, Color::new(0.0, 0.0, 0.0, 1.0), 15.0, Style::Bold);
            let open = s.model.phase == LockPhase::Typing;
            c.text_field(shift(l.field), &s.model.bullets(), open, if open { "Password" } else { "" });
            let note = match s.model.phase {
                LockPhase::Asking => "Checking…".to_string(),
                LockPhase::Unlocked => "Logging in…".into(),
                _ => s.model.status.clone(),
            };
            if !note.is_empty() {
                text(c, &note, p.y + 256.0, note_color(&note), 11.0, Style::Regular)
            }
            c.gel_button(shift(l.back), "Back", false, false);
            c.gel_button(shift(l.log_in), "Log In", true, false);
        } else if self.accounts.is_empty() {
            text(c, "There is nobody to log in as.", p.y + 160.0, Color::new(0.25, 0.25, 0.25, 1.0), 13.0, Style::Regular)
        } else {
            for (i, (a, r0)) in self.accounts.iter().zip(&l.rows).enumerate() {
                let r = shift(*r0);
                let hi = i == s.highlighted;
                if hi {
                    c.rounded_rect(r, 6.0);
                    c.set_color(Color::new(0.22, 0.46, 0.84, 0.9));
                    c.cr.fill()
                }
                c.icon("icon.myAccount", Rect::new(r.x + 8.0, r.y + 4.0, r.h - 8.0, r.h - 8.0));
                let on = self.logged_in.contains(&a.name);
                c.text_left(&a.full_name, r.x + r.h + 12.0, r.y + r.h / 2.0 + if on { -1.0 } else { 5.0 }, if hi { Color::new(1.0, 1.0, 1.0, 1.0) } else { Color::new(0.0, 0.0, 0.0, 1.0) }, 14.0, Style::Bold, Role::Interface);
                if on {
                    c.text_left("Logged in", r.x + r.h + 12.0, r.y + r.h / 2.0 + 14.0, if hi { Color::new(1.0, 1.0, 1.0, 1.0) } else { Color::new(0.35, 0.35, 0.35, 1.0) }, 11.0, Style::Regular, Role::Interface)
                }
            }
        }
        for (r, label) in [(l.sleep, "Sleep"), (l.restart, "Restart"), (l.shut_down, "Shut Down")] {
            c.gel_button(shift(r), label, false, false)
        }
    }

    fn choose(&self, a: &LoginAccount) {
        if self.logged_in.contains(&a.name) {
            // Theirs runs, locked: back to it, no password here. Said first:
            // the daemon ends this window as it goes.
            log(&format!("back to {}'s session", a.name));
            if call(&self.socket, "resume", Some(&a.name)).is_none() {
                log(&format!("going back to {}'s session was refused", a.name))
            }
            return;
        }
        {
            let mut s = self.state.borrow_mut();
            s.chosen = Some(a.clone());
            s.model = LockModel::default();
        }
        log(&format!("chose {}", a.name));
        self.redraw()
    }

    fn back_to_list(&self) {
        if self.asking.borrow().is_some() {
            return;
        }
        {
            let mut s = self.state.borrow_mut();
            s.chosen = None;
            s.model = LockModel::default();
        }
        log("back to the list");
        self.redraw()
    }

    fn ask(&self) {
        let who = {
            let s = self.state.borrow();
            match (&s.chosen, s.model.phase, self.asking.borrow().is_some()) {
                (Some(w), LockPhase::Typing, false) => w.name.clone(),
                _ => return,
            }
        };
        let mut password = self.state.borrow_mut().model.take_for_asking();
        log(&format!("asking for {who}"));
        let began = login::client::login(&who, &password, &self.socket);
        abyss_sys::pam::wipe(&mut password);
        match began {
            Ok(s) => {
                let fd = s.as_raw_fd();
                *self.asking.borrow_mut() = Some(s);
                let me = self.me.clone();
                self.display.add_fd(fd, move || {
                    if let Some(l) = me.upgrade() {
                        l.answered()
                    }
                });
            }
            Err(e) => {
                log(&format!("could not ask: {e}"));
                let now = self.now();
                self.state.borrow_mut().model.answer(None, Some("The login service is not running."), now)
            }
        }
        self.redraw()
    }

    fn answered(&self) {
        let Some(s) = self.asking.borrow_mut().take() else { return };
        self.display.remove_fd(s.as_raw_fd());
        let (verdict, why) = match login::client::finish(&s) {
            Ok(v) => (Some(v), None),
            Err(e) => (None, Some(e.to_string())),
        };
        let now = self.now();
        self.state.borrow_mut().model.answer(verdict.as_ref(), why.as_ref().map(|w| format!("Your password cannot be checked: {w}")).as_deref(), now);
        match &verdict {
            Some(Verdict::Accepted) => log(&format!("accepted {} — logging in", self.state.borrow().chosen.as_ref().map_or("?", |a| &a.name))),
            Some(Verdict::Refused) => log("refused — shake"),
            Some(Verdict::Wait(ms)) => {
                log(&format!("wait {ms} ms — the field is closed"));
                if self.timer.get().is_none() {
                    let me = self.me.clone();
                    self.timer.set(Some(self.display.add_timer(250, move || {
                        if let Some(l) = me.upgrade() {
                            l.tick()
                        }
                    })))
                }
            }
            Some(Verdict::Unavailable(w)) => log(&format!("unavailable: {w}")),
            None => log(&format!("no answer: {}", why.unwrap_or_default())),
        }
        self.redraw()
    }

    fn tick(&self) {
        let now = self.now();
        let open = {
            let mut s = self.state.borrow_mut();
            s.model.tick(now);
            s.model.phase == LockPhase::Typing
        };
        if open {
            log("the wait is over — the field is open");
            if let Some(t) = self.timer.take() {
                self.display.remove_timer(t)
            }
        }
        self.redraw()
    }

    fn power(&self, a: PowerAction) {
        match login::client::power(a, &self.socket) {
            Ok(r) if r.bool("ok") == Some(true) => log(&format!("{} → ok", a.as_str())),
            Ok(r) => log(&format!("{} → refused: {}", a.as_str(), r.string("error").unwrap_or("?"))),
            Err(e) => log(&format!("{} → nobody to ask: {e}", a.as_str())),
        }
    }
}

impl LayerSurfaceDelegate for LoginWindow {
    fn render(&self, surf: &LayerSurface, target: &RenderTarget) {
        let now = self.now();
        let l = self.layout();
        let dx = self.state.borrow_mut().model.shake_offset(now).round();
        self.toolkit.draw(target, |c, w, h| {
            paint_desktop(c, w, h, &self.fill);
            self.paint(c, &LoginWindowLayout::new(w, h, self.accounts.len()), dx)
        });
        self.log_layout(&l);
        if self.state.borrow().model.shaking() {
            surf.set_needs_display()
        }
    }

    fn pointer_moved(&self, _s: &LayerSurface, x: f64, y: f64) {
        self.state.borrow_mut().pointer = (x, y)
    }

    fn pointer_button(&self, _s: &LayerSurface, _button: u32, pressed: bool) {
        if !pressed {
            return;
        }
        let l = self.layout();
        let (x, y) = self.state.borrow().pointer;
        let at = |r: &Rect| r.contains(x, y);
        if at(&l.sleep) {
            return self.power(PowerAction::Sleep);
        }
        if at(&l.restart) {
            return self.power(PowerAction::Restart);
        }
        if at(&l.shut_down) {
            return self.power(PowerAction::ShutDown);
        }
        if self.state.borrow().chosen.is_some() {
            if at(&l.back) {
                self.back_to_list()
            } else if at(&l.log_in) {
                self.ask()
            }
            return;
        }
        if let Some(i) = l.rows.iter().position(at) {
            self.state.borrow_mut().highlighted = i;
            let a = self.accounts[i].clone();
            self.choose(&a)
        }
    }

    fn key_event(&self, _s: &LayerSurface, e: &KeyEvent) {
        if !e.pressed {
            return;
        }
        if self.state.borrow().chosen.is_none() {
            let h = self.state.borrow().highlighted;
            match e.keysym {
                KeySym::DOWN => self.state.borrow_mut().highlighted = (h + 1).min(self.accounts.len().saturating_sub(1)),
                KeySym::UP => self.state.borrow_mut().highlighted = h.saturating_sub(1),
                KeySym::ENTER | 0xff8d => {
                    if let Some(a) = self.accounts.get(h).cloned() {
                        self.choose(&a)
                    }
                }
                _ => {}
            }
            return self.redraw();
        }
        let back = {
            let s = self.state.borrow();
            e.keysym == KeySym::ESCAPE && s.model.typed().is_empty() && s.model.phase == LockPhase::Typing
        };
        if back {
            return self.back_to_list();
        }
        if self.state.borrow_mut().model.key(e) {
            self.ask()
        }
        self.redraw()
    }
}
