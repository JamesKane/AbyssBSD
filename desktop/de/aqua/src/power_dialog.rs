//! The power dialog: "Are you sure…?" (PowerDialog.swift, PHASE16 P16.4b).
//!
//! Jaguar asks before it restarts or shuts down, and its power key asks
//! what you meant. One small window, three questions:
//!
//! - System > Restart…    "Are you sure you want to restart the computer now?"
//!   Cancel · **Restart**
//! - System > Shut Down…  "Are you sure you want to shut down the computer now?"
//!   Cancel · **Shut Down**
//! - the power key        "Are you sure you want to shut down your computer now?"
//!   Restart · Sleep          Cancel · **Shut Down**
//!
//! The bold one is the default (Return); Escape is Cancel. The choice goes
//! to the root daemon (`login::client::power`), which decides who may: a
//! refusal is shown in the dialog, in the daemon's words, with an OK, never
//! a silent nothing.

use crate::toolkit::Toolkit;
use aquadraw::canvas::Canvas;
use aquadraw::chrome::{chrome_hit, window_chrome, ChromeHit, Gadget};
use aquadraw::color::Color;
use aquadraw::draw::paint_window_chrome;
use aquadraw::drawlist::Role;
use aquadraw::runner::Rect;
use aquadraw::text::Style;
use login::PowerAction;
use std::cell::{Cell, RefCell};
use std::rc::{Rc, Weak};
use surface::{Display, KeyEvent, KeySym, RenderTarget, Window, WindowDelegate};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PowerAsk {
    Restart,
    ShutDown,
    PowerKey,
}

impl PowerAsk {
    /// `ABYSS_POWER_ASK`'s words.
    pub fn from_name(s: &str) -> Option<PowerAsk> {
        match s {
            "restart" => Some(PowerAsk::Restart),
            "shut-down" => Some(PowerAsk::ShutDown),
            "power-key" => Some(PowerAsk::PowerKey),
            _ => None,
        }
    }

    pub fn name(self) -> &'static str {
        match self {
            PowerAsk::Restart => "restart",
            PowerAsk::ShutDown => "shut-down",
            PowerAsk::PowerKey => "power-key",
        }
    }

    pub fn question(self) -> &'static str {
        match self {
            PowerAsk::Restart => "Are you sure you want to restart the computer now?",
            PowerAsk::ShutDown => "Are you sure you want to shut down the computer now?",
            PowerAsk::PowerKey => "Are you sure you want to shut down your computer now?",
        }
    }

    /// The buttons, left to right; the last is the default.
    pub fn choices(self) -> Vec<PowerChoice> {
        use PowerChoice::*;
        match self {
            PowerAsk::Restart => vec![Cancel, Restart],
            PowerAsk::ShutDown => vec![Cancel, ShutDown],
            PowerAsk::PowerKey => vec![Restart, Sleep, Cancel, ShutDown],
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PowerChoice {
    Restart,
    Sleep,
    Cancel,
    ShutDown,
    Ok,
}

impl PowerChoice {
    pub fn label(self) -> &'static str {
        match self {
            PowerChoice::Restart => "Restart",
            PowerChoice::Sleep => "Sleep",
            PowerChoice::Cancel => "Cancel",
            PowerChoice::ShutDown => "Shut Down",
            PowerChoice::Ok => "OK",
        }
    }

    pub fn action(self) -> Option<PowerAction> {
        match self {
            PowerChoice::Restart => Some(PowerAction::Restart),
            PowerChoice::Sleep => Some(PowerAction::Sleep),
            PowerChoice::ShutDown => Some(PowerAction::ShutDown),
            PowerChoice::Cancel | PowerChoice::Ok => None,
        }
    }
}

/// Where everything is: pure, so paint, hit and the test's log agree.
#[derive(Clone, Debug, PartialEq)]
pub struct PowerDialogLayout {
    pub icon: Rect,
    pub text_x: f64,
    pub buttons: Vec<(PowerChoice, Rect)>,
}

impl PowerDialogLayout {
    pub fn new(title_bar: f64, choices: &[PowerChoice], w: f64, h: f64) -> PowerDialogLayout {
        let (bw, bh, gap) = (92.0, 22.0, 12.0);
        let y = h - bh - 18.0;
        // Jaguar's arrangement: Cancel and the default on the right, the
        // choices that are not "stop" on the left, under the icon.
        let last = choices.last().copied();
        let is_right = |c: PowerChoice| c == PowerChoice::Cancel || c == PowerChoice::Ok || Some(c) == last;
        let mut buttons = vec![];
        let right: Vec<PowerChoice> = choices.iter().copied().filter(|c| is_right(*c)).collect();
        let mut x = w - 20.0 - right.len() as f64 * bw - right.len().saturating_sub(1) as f64 * gap;
        for c in right {
            buttons.push((c, Rect::new(x, y, bw, bh)));
            x += bw + gap
        }
        x = 20.0;
        for c in choices.iter().copied().filter(|c| !is_right(*c)) {
            buttons.push((c, Rect::new(x, y, bw, bh)));
            x += bw + gap
        }
        PowerDialogLayout { icon: Rect::new(20.0, title_bar + 16.0, 64.0, 64.0), text_x: 100.0, buttons }
    }

    pub fn hit(&self, x: f64, y: f64) -> Option<PowerChoice> {
        self.buttons.iter().find(|(_, r)| r.contains(x, y)).map(|(c, _)| *c)
    }
}

pub fn paint_power_dialog(c: &mut Canvas, w: f64, h: f64, message: &str, refusal: Option<&str>, choices: &[PowerChoice]) -> PowerDialogLayout {
    paint_window_chrome(c.runner, c.theme, c.cr, w, h, "", false, true);
    let t = c.theme.tokens.clone();
    c.set_color(t.content_background);
    c.cr.rectangle(0.0, t.title_bar_height, w, h - t.title_bar_height);
    c.cr.fill();
    let l = PowerDialogLayout::new(t.title_bar_height, choices, w, h);
    c.icon("icon.displays", l.icon);
    // The question in bold, wrapped to the room beside the icon, as
    // Jaguar's alerts set it; a refusal under it in the daemon's words.
    let width = w - l.text_x - 20.0;
    let mut y = t.title_bar_height + 30.0;
    for line in c.wrap_words(message, width, 13.0, Style::Bold) {
        c.text_left(&line, l.text_x, y, t.body_text, 13.0, Style::Bold, Role::Interface);
        y += 18.0
    }
    if let Some(r) = refusal {
        for line in c.wrap_words(r, width, 11.0, Style::Regular) {
            c.text_left(&line, l.text_x, y + 4.0, Color::new(0.65, 0.05, 0.05, 1.0), 11.0, Style::Regular, Role::Interface);
            y += 15.0
        }
    }
    for (choice, r) in &l.buttons {
        c.gel_button(*r, choice.label(), Some(choice) == choices.last(), false)
    }
    l
}

fn log(s: &str) {
    eprintln!("PowerDialog: {s}")
}

pub struct PowerDialog {
    toolkit: Rc<Toolkit>,
    window: RefCell<Option<Rc<Window>>>,
    pub ask: PowerAsk,
    choices: RefCell<Vec<PowerChoice>>,
    refusal: RefCell<Option<String>>,
    pointer: Cell<(f64, f64)>,
    logged: Cell<bool>,
    socket: String,
    /// What happens when the dialog is done; by default, the process ends.
    pub on_done: RefCell<Box<dyn Fn()>>,
}

impl PowerDialog {
    pub fn new(display: &Rc<Display>, toolkit: &Rc<Toolkit>, ask: PowerAsk) -> Option<Rc<PowerDialog>> {
        let app = Rc::new(PowerDialog {
            toolkit: toolkit.clone(),
            window: RefCell::new(None),
            ask,
            choices: RefCell::new(ask.choices()),
            refusal: RefCell::new(None),
            pointer: Cell::new((0.0, 0.0)),
            logged: Cell::new(false),
            socket: login::client::socket(),
            on_done: RefCell::new(Box::new(|| std::process::exit(0))),
        });
        let pinned = std::env::var("AQUA_SCALE").ok().and_then(|s| s.parse::<i32>().ok()).filter(|v| *v > 0);
        let win = Window::new(display, "", "org.abyssbsd.power", 460, 150, pinned.unwrap_or(1), pinned.is_none(), Rc::downgrade(&app) as Weak<dyn WindowDelegate>)?;
        *app.window.borrow_mut() = Some(win);
        log(&format!("up ({})", ask.name()));
        Some(app)
    }

    fn choose(&self, c: PowerChoice) {
        let Some(action) = c.action() else {
            log(&format!("chose {}", c.label()));
            return self.finish();
        };
        match login::client::power(action, &self.socket) {
            Ok(r) if r.bool("ok") == Some(true) => {
                log(&format!("chose {} → ok", c.label()));
                self.finish()
            }
            Ok(r) => self.refuse(c, r.string("error").unwrap_or("the computer said no")),
            // The client's error carries the daemon's words when it gave any.
            Err(login::LoginError::Service(why)) => self.refuse(c, &why),
            Err(e) => self.refuse(c, &format!("nobody to ask: {e}")),
        }
    }

    fn refuse(&self, c: PowerChoice, why: &str) {
        log(&format!("chose {} → refused: {why}", c.label()));
        *self.refusal.borrow_mut() = Some(why.into());
        *self.choices.borrow_mut() = vec![PowerChoice::Ok];
        self.logged.set(false);
        if let Some(w) = self.window.borrow().as_ref() {
            w.set_needs_display()
        }
    }

    fn finish(&self) {
        let w = self.window.borrow_mut().take();
        drop(w);
        (self.on_done.borrow())()
    }
}

impl WindowDelegate for PowerDialog {
    fn render(&self, _w: &Window, target: &RenderTarget) {
        let (refusal, choices) = (self.refusal.borrow().clone(), self.choices.borrow().clone());
        let l = self.toolkit.draw(target, |c, w, h| paint_power_dialog(c, w, h, self.ask.question(), refusal.as_deref(), &choices));
        if !self.logged.replace(true) {
            let at: Vec<String> = l.buttons.iter().map(|(c, r)| format!("{}={},{}", c.label().replace(' ', "_"), (r.x + r.w / 2.0) as i64, (r.y + r.h / 2.0) as i64)).collect();
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
            ChromeHit::Gadget(Gadget::Close) => return self.choose(PowerChoice::Cancel),
            ChromeHit::Title => return w.begin_move(),
            _ => {}
        }
        let hit = PowerDialogLayout::new(t.title_bar_height, &self.choices.borrow(), sw as f64, sh as f64).hit(x, y);
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
            let refused = self.refusal.borrow().is_some();
            self.choose(if refused { PowerChoice::Ok } else { PowerChoice::Cancel })
        }
    }

    fn should_close(&self, _w: &Window) {
        self.choose(PowerChoice::Cancel)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use PowerChoice::*;

    #[test]
    fn the_menus_ask_cancel_or_the_thing() {
        assert_eq!(PowerAsk::Restart.choices(), [Cancel, Restart]);
        assert_eq!(PowerAsk::ShutDown.choices(), [Cancel, ShutDown]);
        assert_eq!(PowerAsk::from_name("shut-down"), Some(PowerAsk::ShutDown));
        assert_eq!(PowerAsk::from_name("reboot"), None);
        assert_eq!(Cancel.action(), None);
        assert_eq!(ShutDown.action(), Some(PowerAction::ShutDown));
    }

    /// The power key: Restart and Sleep on the left from the edge, Cancel
    /// and the default Shut Down on the right.
    #[test]
    fn the_power_key_puts_stop_on_the_right() {
        let l = PowerDialogLayout::new(22.0, &PowerAsk::PowerKey.choices(), 460.0, 150.0);
        let at = |c: PowerChoice| l.buttons.iter().find(|b| b.0 == c).unwrap().1;
        assert_eq!(at(ShutDown).x + at(ShutDown).w, 440.0);
        assert!(at(Cancel).x < at(ShutDown).x);
        assert_eq!(at(Restart).x, 20.0);
        assert_eq!(at(Sleep).x, 20.0 + 92.0 + 12.0);
        assert!(at(Sleep).x + at(Sleep).w < at(Cancel).x, "the two sides do not meet");
        assert_eq!(l.hit(at(Sleep).x + 3.0, at(Sleep).y + 3.0), Some(Sleep));
        assert_eq!(l.hit(5.0, 5.0), None);
    }

    #[test]
    fn a_refusal_leaves_only_ok() {
        let l = PowerDialogLayout::new(22.0, &[Ok], 460.0, 150.0);
        assert_eq!(l.buttons.len(), 1);
        assert_eq!(l.buttons[0].1.x + l.buttons[0].1.w, 440.0);
    }
}
