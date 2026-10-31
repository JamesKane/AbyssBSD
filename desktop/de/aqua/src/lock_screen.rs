//! The Aqua lock screen (LockScreen.swift, P16.2b): an ext-session-lock
//! client. It locks, covers every display, and on the first shows who is
//! logged in, with a password field. Return asks the authenticator; only
//! its yes unlocks. A no clears the field and **shakes** the panel; too
//! many and the field counts down, asking nothing until it is over.
//!
//! It fails closed: no authenticator, or no PAM, and the screen says so
//! and stays locked. If this process dies the session stays locked too
//! (undertow, P16.2a), and a new lock screen can take over.
//!
//! The password is bytes, wiped when sent or cleared, and never logged.

use crate::toolkit::Toolkit;
use crate::wallpaper::{paint_desktop, DesktopFill};
use aquadraw::color::Color;
use aquadraw::drawlist::Role;
use aquadraw::runner::Rect;
use aquadraw::text::Style;
use login::Verdict;
use std::cell::{Cell, RefCell};
use std::os::fd::AsRawFd;
use std::os::unix::net::UnixStream;
use std::rc::{Rc, Weak};
use std::time::Instant;
use surface::{Display, KeyEvent, KeyModifiers, KeySym, LockSurface, RenderTarget, SessionLock, SessionLockDelegate};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum LockPhase {
    Typing,
    Asking,
    /// Closed until this monotonic nanosecond.
    Waiting(u64),
    Unlocked,
}

/// What the lock screen shows and does, without a display.
#[derive(Debug)]
pub struct LockModel {
    pub phase: LockPhase,
    /// The typed password, as bytes: never logged, wiped on every clear.
    typed: Vec<u8>,
    pub status: String,
    /// When the shake began (monotonic ns).
    shake_start: Option<u64>,
}

pub const SHAKE_NS: u64 = 500_000_000;
const KEYPAD_ENTER: u32 = 0xff8d;

impl Default for LockModel {
    fn default() -> LockModel {
        LockModel { phase: LockPhase::Typing, typed: vec![], status: String::new(), shake_start: None }
    }
}

impl LockModel {
    pub fn typed(&self) -> &[u8] {
        &self.typed
    }

    /// One bullet a character, not a byte.
    pub fn bullets(&self) -> String {
        "•".repeat(String::from_utf8_lossy(&self.typed).chars().count())
    }

    fn wipe(&mut self) {
        abyss_sys::pam::wipe(&mut self.typed);
        self.typed.clear()
    }

    /// A key while the field is open; true for Return with something to
    /// ask.
    pub fn key(&mut self, e: &KeyEvent) -> bool {
        if !e.pressed || self.phase != LockPhase::Typing {
            return false;
        }
        match e.keysym {
            KeySym::ENTER | KEYPAD_ENTER => return true,
            // A whole character, not a byte of one.
            KeySym::BACKSPACE => {
                let mut s = String::from_utf8_lossy(&self.typed).into_owned();
                s.pop();
                self.wipe();
                self.typed = s.into_bytes()
            }
            KeySym::ESCAPE => self.wipe(),
            _ => {
                let typable = !e.text.is_empty() && !e.modifiers.contains(KeyModifiers::CONTROL) && !e.modifiers.contains(KeyModifiers::COMMAND) && e.text.chars().all(|c| c >= ' ' && c != '\u{7f}');
                if typable {
                    self.typed.extend_from_slice(e.text.as_bytes());
                    self.status.clear()
                }
            }
        }
        false
    }

    /// The password, handed over to be asked; the model's copy is wiped.
    pub fn take_for_asking(&mut self) -> Vec<u8> {
        let p = self.typed.clone();
        self.wipe();
        self.phase = LockPhase::Asking;
        self.status.clear();
        p
    }

    /// The authenticator's answer, or why there was none.
    pub fn answer(&mut self, v: Option<&Verdict>, error: Option<&str>, now: u64) {
        match v {
            Some(Verdict::Accepted) => self.phase = LockPhase::Unlocked,
            Some(Verdict::Refused) => {
                self.phase = LockPhase::Typing;
                self.status = "The password is incorrect.".into();
                self.shake_start = Some(now)
            }
            Some(Verdict::Wait(ms)) => {
                self.phase = LockPhase::Waiting(now.wrapping_add(ms.wrapping_mul(1_000_000)));
                self.shake_start = Some(now);
                self.status = wait_text(*ms)
            }
            Some(Verdict::Unavailable(why)) => {
                self.phase = LockPhase::Typing;
                self.status = format!("Your password cannot be checked: {why}")
            }
            None => {
                self.phase = LockPhase::Typing;
                self.status = error.unwrap_or("Your password cannot be checked.").into()
            }
        }
    }

    /// Time passed: count down, and open the field when it is over.
    pub fn tick(&mut self, now: u64) {
        let LockPhase::Waiting(until) = self.phase else { return };
        if now >= until {
            self.phase = LockPhase::Typing;
            self.status.clear()
        } else {
            self.status = wait_text((until - now) / 1_000_000)
        }
    }

    /// The panel's sideways offset: a decaying shake, then still for good.
    pub fn shake_offset(&mut self, now: u64) -> f64 {
        let Some(start) = self.shake_start else { return 0.0 };
        let t = now.wrapping_sub(start);
        if t >= SHAKE_NS {
            self.shake_start = None;
            return 0.0;
        }
        let f = t as f64 / SHAKE_NS as f64;
        14.0 * (1.0 - f) * (f * 6.0 * std::f64::consts::PI).sin()
    }

    pub fn shaking(&self) -> bool {
        self.shake_start.is_some()
    }
}

fn wait_text(ms: u64) -> String {
    let s = ms.div_ceil(1000);
    format!("Too many attempts. Try again in {s} second{}.", if s == 1 { "" } else { "s" })
}

/// The login window's look, which the lock screen shares: a pinstriped
/// sheet with a soft edge.
pub fn paint_sheet(c: &mut aquadraw::canvas::Canvas, p: Rect) {
    c.rounded_rect(p, 10.0);
    c.set_color(Color::new(0.93, 0.93, 0.93, 0.97));
    c.cr.fill_preserve();
    c.set_color(Color::new(0.0, 0.0, 0.0, 0.35));
    c.cr.set_line_width(1.0);
    c.cr.stroke();
    c.cr.save();
    c.rounded_rect(p, 10.0);
    c.cr.clip();
    c.pinstripe(p, Color::new(1.0, 1.0, 1.0, 0.5));
    c.cr.restore();
}

/// The note under the field, red for a refusal or a wait.
pub fn note_color(note: &str) -> Color {
    if note.starts_with("The password") || note.starts_with("Too many") { Color::new(0.65, 0.05, 0.05, 1.0) } else { Color::new(0.25, 0.25, 0.25, 1.0) }
}

/// The panel on a display this size, before any shake.
pub fn panel_rect(w: f64, h: f64) -> Rect {
    Rect::new(((w - 320.0) / 2.0).round(), ((h - 250.0) / 2.0).round(), 320.0, 250.0)
}

fn log(s: &str) {
    eprintln!("LockScreen: {s}")
}

type Done = Rc<dyn Fn(bool)>;

pub struct LockScreen {
    me: Weak<LockScreen>,
    display: Rc<Display>,
    toolkit: Rc<Toolkit>,
    lock: RefCell<Option<Rc<SessionLock>>>,
    model: RefCell<LockModel>,
    full_name: String,
    socket: String,
    asking: RefCell<Option<UnixStream>>,
    timer: Cell<Option<u64>>,
    fill: DesktopFill,
    epoch: Instant,
    on_done: RefCell<Option<Done>>,
    on_locked: RefCell<Option<Rc<dyn Fn()>>>,
}

impl LockScreen {
    /// Lock; None when the compositor offers no session lock.
    pub fn new(display: &Rc<Display>, toolkit: &Rc<Toolkit>) -> Option<Rc<LockScreen>> {
        let acct = abyss_sys::users::by_uid(abyss_sys::users::uid());
        let user = acct.as_ref().map_or("user".into(), |a| a.name.clone());
        // GECOS's first field is the full name; empty, the account's.
        let full = acct.map(|a| a.gecos.split(',').next().unwrap_or("").to_string()).unwrap_or_default();
        if display.globals().session_lock_manager.is_none() {
            log("the compositor offers no session lock — cannot lock");
            return None;
        }
        let ls = Rc::new_cyclic(|me| LockScreen {
            me: me.clone(),
            display: display.clone(),
            toolkit: toolkit.clone(),
            lock: RefCell::new(None),
            model: RefCell::default(),
            full_name: if full.is_empty() { user.clone() } else { full },
            socket: login::client::socket(),
            asking: RefCell::new(None),
            timer: Cell::new(None),
            fill: DesktopFill::from(&pool_config::load("desktop", None).unwrap_or_default()),
            epoch: Instant::now(),
            on_done: RefCell::new(None),
            on_locked: RefCell::new(None),
        });
        let l = SessionLock::new(display, Rc::downgrade(&ls) as Weak<dyn SessionLockDelegate>)?;
        log(&format!("locking for {user} ({} display(s)); asking {}", l.surfaces().len(), ls.socket));
        *ls.lock.borrow_mut() = Some(l);
        Some(ls)
    }

    /// Told true once unlocked, false if the compositor refused or ended it.
    pub fn on_done(&self, f: impl Fn(bool) + 'static) {
        *self.on_done.borrow_mut() = Some(Rc::new(f))
    }
    /// The desktop is hidden: "locked" means locked (P16.3).
    pub fn on_locked(&self, f: impl Fn() + 'static) {
        *self.on_locked.borrow_mut() = Some(Rc::new(f))
    }

    fn now(&self) -> u64 {
        self.epoch.elapsed().as_nanos() as u64
    }

    fn redraw(&self) {
        let l = self.lock.borrow().clone();
        if let Some(l) = l {
            l.set_needs_display()
        }
    }

    fn done(&self, ok: bool) {
        let f = self.on_done.borrow().clone();
        if let Some(f) = f {
            f(ok)
        }
    }

    fn ask(&self) {
        if self.asking.borrow().is_some() {
            return;
        }
        let mut password = self.model.borrow_mut().take_for_asking();
        log("asking the authenticator");
        let began = login::client::begin(&password, &self.socket);
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
                self.model.borrow_mut().answer(None, Some("The authenticator is not running, so your password cannot be checked."), now)
            }
        }
        self.redraw()
    }

    fn answered(&self) {
        let Some(s) = self.asking.borrow_mut().take() else { return };
        self.display.remove_fd(s.as_raw_fd());
        let got = login::client::finish(&s);
        let now = self.now();
        let (verdict, why) = match got {
            Ok(v) => (Some(v), None),
            Err(e) => (None, Some(e.to_string())),
        };
        self.model.borrow_mut().answer(verdict.as_ref(), why.as_ref().map(|w| format!("Your password cannot be checked: {w}")).as_deref(), now);
        match &verdict {
            Some(Verdict::Accepted) => {
                log("accepted — unlocking");
                if let Some(l) = self.lock.borrow_mut().take() {
                    l.unlock()
                }
                return self.done(true);
            }
            Some(Verdict::Refused) => log("refused — shake"),
            Some(Verdict::Wait(ms)) => {
                log(&format!("wait {ms} ms — the field is closed"));
                self.start_timer()
            }
            Some(Verdict::Unavailable(w)) => log(&format!("unavailable: {w}")),
            None => log(&format!("no answer: {}", why.unwrap_or_default())),
        }
        self.redraw()
    }

    fn start_timer(&self) {
        if self.timer.get().is_some() {
            return;
        }
        let me = self.me.clone();
        self.timer.set(Some(self.display.add_timer(250, move || {
            if let Some(l) = me.upgrade() {
                l.tick()
            }
        })))
    }

    fn tick(&self) {
        let now = self.now();
        self.model.borrow_mut().tick(now);
        if self.model.borrow().phase == LockPhase::Typing {
            log("the wait is over — the field is open");
            if let Some(t) = self.timer.take() {
                self.display.remove_timer(t)
            }
        }
        self.redraw()
    }

    fn paint_panel(&self, c: &mut aquadraw::canvas::Canvas, w: f64, h: f64) {
        let now = self.now();
        let mut m = self.model.borrow_mut();
        let mut p = panel_rect(w, h);
        p.x += m.shake_offset(now).round();
        paint_sheet(c, p);
        c.icon("icon.myAccount", Rect::new(p.x + 128.0, p.y + 22.0, 64.0, 64.0));
        c.text(&self.full_name, p.x + p.w / 2.0, p.y + 104.0, Color::new(0.0, 0.0, 0.0, 1.0), 15.0, Style::Bold, Role::Interface);
        let open = m.phase == LockPhase::Typing;
        c.text_field(Rect::new(p.x + 40.0, p.y + 132.0, p.w - 80.0, 24.0), &m.bullets(), open, if open { "Password" } else { "" });
        let note = match m.phase {
            LockPhase::Asking => "Checking…".to_string(),
            LockPhase::Unlocked => String::new(),
            _ if m.status.is_empty() => "Enter your password to unlock.".into(),
            _ => m.status.clone(),
        };
        // Red by the status, not the note: "Checking…" is never red.
        c.text(&note, p.x + p.w / 2.0, p.y + 180.0, note_color(&m.status), 11.0, Style::Regular, Role::Interface);
        c.text("This computer is locked.", p.x + p.w / 2.0, p.y + 220.0, Color::new(0.35, 0.35, 0.35, 1.0), 10.0, Style::Regular, Role::Interface)
    }
}

impl SessionLockDelegate for LockScreen {
    fn render(&self, s: &LockSurface, target: &RenderTarget) {
        self.toolkit.draw(target, |c, w, h| {
            paint_desktop(c, w, h, &self.fill);
            // Dimmed: this is not the desktop, and must not look as if it
            // waits for a click.
            c.cr.set_source_rgba(0.0, 0.0, 0.0, 0.45);
            c.cr.rectangle(0.0, 0.0, w, h);
            c.cr.fill();
            if s.index == 0 {
                self.paint_panel(c, w, h)
            }
        });
        // Still shaking: again next frame.
        if self.model.borrow().shaking() {
            s.set_needs_display()
        }
    }

    fn key_event(&self, e: &KeyEvent) {
        if self.model.borrow_mut().key(e) {
            self.ask()
        }
        self.redraw()
    }

    fn locked(&self) {
        log("locked");
        let f = self.on_locked.borrow().clone();
        if let Some(f) = f {
            f()
        }
    }

    fn finished(&self) {
        log(if self.model.borrow().phase == LockPhase::Unlocked { "finished" } else { "the compositor refused the lock or ended it" });
        self.done(false)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn key(text: &str, sym: u32, mods: KeyModifiers) -> KeyEvent {
        KeyEvent { keysym: if sym == 0 { text.chars().next().map_or(0, |c| c as u32) } else { sym }, text: text.into(), pressed: true, modifiers: mods }
    }
    fn k(text: &str) -> KeyEvent {
        key(text, 0, KeyModifiers::default())
    }
    fn typ(m: &mut LockModel, s: &str) {
        for c in s.chars() {
            m.key(&k(&c.to_string()));
        }
    }

    #[test]
    fn typing_fills_the_field_with_bullets_per_character_and_return_asks() {
        let mut m = LockModel::default();
        typ(&mut m, "pässwd");
        assert_eq!(m.bullets(), "••••••", "one bullet per character, not per byte");
        assert_eq!(m.typed(), "pässwd".as_bytes());
        assert!(!m.key(&key("", KeySym::BACKSPACE, KeyModifiers::default())));
        assert_eq!(m.typed(), "pässw".as_bytes());
        assert!(m.key(&key("\r", KeySym::ENTER, KeyModifiers::default())));
        assert!(m.key(&key("\r", KEYPAD_ENTER, KeyModifiers::default())), "so does the keypad's Enter");
    }

    #[test]
    fn backspace_takes_a_whole_character_and_escape_clears() {
        let mut m = LockModel::default();
        typ(&mut m, "aé");
        m.key(&key("", KeySym::BACKSPACE, KeyModifiers::default()));
        assert_eq!(m.typed(), b"a", "é is two bytes and one character");
        typ(&mut m, "bc");
        m.key(&key("", KeySym::ESCAPE, KeyModifiers::default()));
        assert!(m.typed().is_empty());
    }

    #[test]
    fn shortcuts_and_control_characters_are_not_typed() {
        let mut m = LockModel::default();
        m.key(&key("c", 0, KeyModifiers::CONTROL));
        m.key(&key("q", 0, KeyModifiers::COMMAND));
        m.key(&key("\t", KeySym::TAB, KeyModifiers::default()));
        m.key(&KeyEvent { keysym: 0x61, text: "a".into(), pressed: false, modifiers: KeyModifiers::default() });
        assert!(m.typed().is_empty(), "⌃C, ⌘Q, Tab and a release type nothing");
    }

    #[test]
    fn asking_takes_the_password_and_closes_the_field() {
        let mut m = LockModel::default();
        typ(&mut m, "secret");
        assert_eq!(m.take_for_asking(), b"secret");
        assert!(m.typed().is_empty(), "the model's copy is gone");
        assert_eq!(m.phase, LockPhase::Asking);
        typ(&mut m, "more");
        assert!(m.typed().is_empty(), "nothing typed while the answer is awaited");
        assert!(!m.key(&key("\r", KeySym::ENTER, KeyModifiers::default())), "Return asks nothing twice");
    }

    #[test]
    fn a_refusal_shakes_and_reopens_the_field() {
        let mut m = LockModel::default();
        m.take_for_asking();
        m.answer(Some(&Verdict::Refused), None, 1_000);
        assert_eq!(m.phase, LockPhase::Typing);
        assert_eq!(m.status, "The password is incorrect.");
        assert_ne!(m.shake_offset(1_000 + 100_000_000), 0.0, "it is shaking");
        assert_eq!(m.shake_offset(1_000 + SHAKE_NS), 0.0, "then still");
        assert_eq!(m.shake_offset(1_000 + 100_000_000), 0.0, "for good");
        typ(&mut m, "x");
        assert_eq!(m.status, "", "typing again clears the complaint");
    }

    #[test]
    fn a_wait_closes_the_field_and_counts_down() {
        let mut m = LockModel::default();
        m.take_for_asking();
        m.answer(Some(&Verdict::Wait(4_000)), None, 0);
        assert_eq!(m.phase, LockPhase::Waiting(4_000_000_000));
        assert_eq!(m.status, "Too many attempts. Try again in 4 seconds.");
        typ(&mut m, "abc");
        assert!(!m.key(&key("\r", KeySym::ENTER, KeyModifiers::default())));
        assert!(m.typed().is_empty(), "the field is closed while waiting");
        m.tick(3_100_000_000);
        assert_eq!(m.status, "Too many attempts. Try again in 1 second.");
        m.tick(4_000_000_000);
        assert_eq!((m.phase, m.status.as_str()), (LockPhase::Typing, ""));
    }

    #[test]
    fn it_fails_closed() {
        let mut m = LockModel::default();
        m.take_for_asking();
        m.answer(Some(&Verdict::Unavailable("PAM is broken".into())), None, 0);
        assert_eq!(m.phase, LockPhase::Typing);
        assert_eq!(m.status, "Your password cannot be checked: PAM is broken");
        m.take_for_asking();
        m.answer(None, Some("The authenticator is not running."), 0);
        assert_eq!((m.phase, m.status.as_str()), (LockPhase::Typing, "The authenticator is not running."), "no answer is not a yes");
        m.take_for_asking();
        m.answer(Some(&Verdict::Accepted), None, 0);
        assert_eq!(m.phase, LockPhase::Unlocked, "only an accepted answer unlocks");
    }
}
