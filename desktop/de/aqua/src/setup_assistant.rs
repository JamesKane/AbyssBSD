//! An account's first login (SetupAssistant.swift, P16.7, §6.5). The
//! installer asked for the keyboard, the time zone and the account; this
//! is the rest, small, once, and skippable, on the installer's shape: the
//! steps down the left, a page on the right.
//!
//! ```text
//! Welcome     who this desktop thinks you are
//! Network     whether this computer is connected, and where to change it
//! Appearance  the theme, written where the General pane reads it
//! All Set     and done
//! ```
//!
//! Finishing or skipping writes `setup.ini`, so the next login goes straight
//! to the desktop; closing the window without either asks again next time.

use crate::appearance::{self, InstalledTheme};
use crate::toolkit::Toolkit;
use aquadraw::canvas::Canvas;
use aquadraw::chrome::{chrome_hit, window_chrome, ChromeHit, Gadget};
use aquadraw::color::Color;
use aquadraw::draw::paint_window_chrome;
use aquadraw::drawlist::Role;
use aquadraw::runner::Rect;
use aquadraw::text::Style;
use std::cell::RefCell;
use std::collections::BTreeMap;
use std::rc::{Rc, Weak};
use surface::{Display, KeyEvent, KeySym, RenderTarget, Window, WindowDelegate};

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub enum SetupPage {
    Welcome,
    Network,
    Appearance,
    Done,
}

impl SetupPage {
    pub const ALL: [SetupPage; 4] = [SetupPage::Welcome, SetupPage::Network, SetupPage::Appearance, SetupPage::Done];
    pub fn title(self) -> &'static str {
        match self {
            SetupPage::Welcome => "Welcome",
            SetupPage::Network => "Network",
            SetupPage::Appearance => "Appearance",
            SetupPage::Done => "All Set",
        }
    }
}

/// The assistant's state, without a window.
#[derive(Clone, Debug, PartialEq)]
pub struct SetupModel {
    pub page: SetupPage,
    pub themes: Vec<InstalledTheme>,
    pub theme: String,
    pub full_name: String,
    pub connection: String,
}

impl SetupModel {
    pub fn new(themes: Vec<InstalledTheme>, theme: &str, full_name: &str, connection: &str) -> SetupModel {
        SetupModel { page: SetupPage::Welcome, themes, theme: theme.into(), full_name: full_name.into(), connection: connection.into() }
    }
    pub fn forward(&mut self) {
        self.page = SetupPage::ALL[(self.page as usize + 1).min(3)]
    }
    pub fn back(&mut self) {
        self.page = SetupPage::ALL[(self.page as usize).saturating_sub(1)]
    }
    pub fn continue_label(&self) -> &'static str {
        if self.page == SetupPage::Done { "Start Using AbyssBSD" } else { "Continue" }
    }
    pub fn can_go_back(&self) -> bool {
        self.page != SetupPage::Welcome
    }

    /// The connection in a sentence: the first interface up with an address.
    pub fn connection(ifs: &[vents::network::Interface]) -> String {
        match ifs.iter().find(|i| !i.loopback && i.up && !i.ipv4.is_empty()) {
            Some(i) => format!("This computer is connected through {} ({}).", i.name, i.ipv4[0].address),
            None => "This computer is not connected to a network.".into(),
        }
    }
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct SetupLayout {
    pub steps: Vec<Rect>,
    pub page: Rect,
    pub theme_rows: Vec<Rect>,
    pub skip: Rect,
    pub back: Rect,
    pub next: Rect,
    pub open_network: Rect,
}

impl SetupLayout {
    pub fn new(title_bar: f64, w: f64, h: f64, themes: usize) -> SetupLayout {
        let page = Rect::new(190.0, title_bar + 16.0, w - 210.0, h - title_bar - 76.0);
        let by = h - 44.0;
        let next = Rect::new(w - 190.0, by, 170.0, 22.0);
        SetupLayout {
            steps: (0..4).map(|i| Rect::new(16.0, title_bar + 24.0 + i as f64 * 32.0, 150.0, 26.0)).collect(),
            theme_rows: (0..themes).map(|i| Rect::new(page.x + 8.0, page.y + 100.0 + i as f64 * 30.0, page.w - 16.0, 26.0)).collect(),
            open_network: Rect::new(page.x + 8.0, page.y + 120.0, 210.0, 22.0),
            skip: Rect::new(16.0, by, 110.0, 22.0),
            back: Rect::new(next.x - 112.0, by, 100.0, 22.0),
            next,
            page,
        }
    }
}

pub fn paint_setup_assistant(c: &mut Canvas, w: f64, h: f64, m: &SetupModel) -> SetupLayout {
    let t = c.theme.tokens.clone();
    paint_window_chrome(c.runner, c.theme, c.cr, w, h, "Setup Assistant", false, true);
    c.set_color(t.content_background);
    c.cr.rectangle(0.0, t.title_bar_height, w, h - t.title_bar_height);
    c.cr.fill();
    let l = SetupLayout::new(t.title_bar_height, w, h, m.themes.len());
    for (p, r) in SetupPage::ALL.iter().zip(&l.steps) {
        let (here, past) = (*p == m.page, *p < m.page);
        if here {
            c.rounded_rect(*r, 6.0);
            c.set_color(Color::new(0.22, 0.46, 0.84, 1.0));
            c.cr.fill()
        }
        let k = if here { Color::new(1.0, 1.0, 1.0, 1.0) } else if past { t.body_text } else { t.secondary_text };
        c.text_left(&format!("{}{}", if past { "✓ " } else { "  " }, p.title()), r.x + 10.0, r.y + 17.0, k, 13.0, if here { Style::Bold } else { Style::Regular }, Role::Interface)
    }
    c.set_color(Color::new(0.7, 0.7, 0.7, 1.0));
    c.cr.set_line_width(1.0);
    c.cr.move_to(178.5, t.title_bar_height + 16.0);
    c.cr.line_to(178.5, h - 60.0);
    c.cr.stroke();
    let p = l.page;
    let heading = |c: &mut Canvas, s: &str| c.text_left(s, p.x + 8.0, p.y + 30.0, t.body_text, 20.0, Style::Bold, Role::Interface);
    let body = |c: &mut Canvas, s: &str, line: f64| c.text_left(s, p.x + 8.0, p.y + 64.0 + line * 20.0, t.body_text, 13.0, Style::Regular, Role::Interface);
    match m.page {
        SetupPage::Welcome => {
            heading(c, "Welcome to AbyssBSD");
            body(c, &format!("Hello, {}.", m.full_name), 0.0);
            body(c, "A few things to set up, and each can be changed later", 2.0);
            body(c, "in System Preferences.", 3.0)
        }
        SetupPage::Network => {
            heading(c, "Network");
            body(c, &m.connection, 0.0);
            body(c, "Wi-Fi networks and addresses are in the Network pane.", 1.0);
            c.gel_button(l.open_network, "Open Network Preferences…", false, false)
        }
        SetupPage::Appearance => {
            heading(c, "Appearance");
            body(c, "Choose how windows, menus and controls look:", 0.0);
            for (th, r) in m.themes.iter().zip(&l.theme_rows) {
                c.radio_button(r.x + 10.0, r.y + 13.0, 7.0, th.id == m.theme);
                c.text_left(&th.name, r.x + 26.0, r.y + 17.0, t.body_text, 13.0, Style::Regular, Role::Interface)
            }
        }
        SetupPage::Done => {
            heading(c, "You're All Set");
            body(c, "Your desktop is ready.", 0.0);
            body(c, "To change any of this later, open System Preferences.", 2.0)
        }
    }
    c.gel_button(l.skip, "Skip Setup", false, false);
    if m.can_go_back() {
        c.gel_button(l.back, "Go Back", false, false)
    }
    c.gel_button(l.next, m.continue_label(), true, false);
    l
}

fn log(s: &str) {
    eprintln!("Setup Assistant: {s}")
}

pub struct SetupAssistant {
    toolkit: Rc<Toolkit>,
    window: RefCell<Option<Rc<Window>>>,
    model: RefCell<SetupModel>,
    pointer: RefCell<(f64, f64)>,
    logged_page: RefCell<Option<SetupPage>>,
    on_quit: RefCell<Option<Rc<dyn Fn()>>>,
}

impl SetupAssistant {
    pub fn new(display: &Rc<Display>, toolkit: &Rc<Toolkit>) -> Option<Rc<SetupAssistant>> {
        let acct = abyss_sys::users::by_uid(abyss_sys::users::uid());
        let name = acct.as_ref().map_or("you".into(), |a| a.name.clone());
        let full = acct.map(|a| a.gecos.split(',').next().unwrap_or("").to_string()).unwrap_or_default();
        let model = SetupModel::new(appearance::installed(), &appearance::current().name, if full.is_empty() { &name } else { &full }, &SetupModel::connection(&vents::network::interfaces()));
        log(&format!("up for {name} — themes: {}", model.themes.iter().map(|t| t.id.as_str()).collect::<Vec<_>>().join(" ")));
        let app = Rc::new(SetupAssistant { toolkit: toolkit.clone(), window: RefCell::new(None), model: RefCell::new(model), pointer: RefCell::new((0.0, 0.0)), logged_page: RefCell::new(None), on_quit: RefCell::new(None) });
        let w = Window::new(display, "Setup Assistant", "org.abyssbsd.setupassistant", 640, 400, 1, true, Rc::downgrade(&app) as Weak<dyn WindowDelegate>)?;
        *app.window.borrow_mut() = Some(w);
        Some(app)
    }

    pub fn on_quit(&self, f: impl Fn() + 'static) {
        *self.on_quit.borrow_mut() = Some(Rc::new(f))
    }

    fn quit(&self) {
        let f = self.on_quit.borrow().clone();
        match f {
            Some(f) => f(),
            None => std::process::exit(0),
        }
    }

    fn redraw(&self) {
        let w = self.window.borrow().clone();
        if let Some(w) = w {
            w.set_needs_display()
        }
    }

    fn next(&self) {
        if self.model.borrow().page == SetupPage::Done {
            return self.finish(false);
        }
        self.model.borrow_mut().forward();
        self.redraw()
    }

    fn choose(&self, id: &str) {
        if id == self.model.borrow().theme {
            return;
        }
        match aquadraw::theme::store(id, None, &BTreeMap::new(), None) {
            Ok(()) => {
                self.model.borrow_mut().theme = id.into();
                log(&format!("theme {id} chosen"))
            }
            Err(e) => log(&format!("could not save the theme: {e}")),
        }
        self.redraw()
    }

    fn open_network(&self) {
        let exe = crate::launcher::self_executable().unwrap_or_else(|| "AquaDemo".into());
        let ok = crate::launcher::launch_detached(&[exe], &[("AQUA_SCENE", "sysprefs"), ("ABYSS_PREFS_PANE", "network")]);
        log(&format!("open Network Preferences — {}", if ok { "started" } else { "could not start" }))
    }

    fn finish(&self, skipped: bool) {
        match pool_config::SetupState::mark_done(skipped, None) {
            Ok(()) => log(&format!("done ({}) — not again at this account's logins", if skipped { "skipped" } else { "finished" })),
            Err(e) => log(&format!("could not say it is done: {e}")),
        }
        self.quit()
    }
}

impl WindowDelegate for SetupAssistant {
    fn render(&self, _w: &Window, target: &RenderTarget) {
        let m = self.model.borrow().clone();
        let l = self.toolkit.draw(target, |c, w, h| paint_setup_assistant(c, w, h, &m));
        if *self.logged_page.borrow() != Some(m.page) {
            *self.logged_page.borrow_mut() = Some(m.page);
            let c = |r: &Rect| format!("{},{}", (r.x + r.w / 2.0) as i64, (r.y + r.h / 2.0) as i64);
            let mut line = format!("page {} skip={} back={} next={}", m.page.title(), c(&l.skip), c(&l.back), c(&l.next));
            if m.page == SetupPage::Appearance {
                for (t, r) in m.themes.iter().zip(&l.theme_rows) {
                    line += &format!(" theme.{}={}", t.id, c(r))
                }
            }
            if m.page == SetupPage::Network {
                line += &format!(" open-network={}", c(&l.open_network))
            }
            log(&line)
        }
    }

    fn pointer_moved(&self, _w: &Window, x: f64, y: f64) {
        *self.pointer.borrow_mut() = (x, y)
    }

    fn pointer_button(&self, w: &Window, _button: u32, pressed: bool) {
        if !pressed {
            return;
        }
        let (x, y) = *self.pointer.borrow();
        let (sw, sh) = w.size();
        let t = self.toolkit.theme.borrow().tokens.clone();
        match chrome_hit(&t, &window_chrome(&t, sw as f64, sh as f64, false), x, y) {
            ChromeHit::Gadget(Gadget::Close) => {
                log("closed — it asks again next time");
                return self.quit();
            }
            ChromeHit::Title => return w.begin_move(),
            _ => {}
        }
        let m = self.model.borrow().clone();
        let l = SetupLayout::new(t.title_bar_height, sw as f64, sh as f64, m.themes.len());
        if l.skip.contains(x, y) {
            return self.finish(true);
        }
        if l.next.contains(x, y) {
            return self.next();
        }
        if m.can_go_back() && l.back.contains(x, y) {
            self.model.borrow_mut().back();
            return self.redraw();
        }
        if m.page == SetupPage::Network && l.open_network.contains(x, y) {
            return self.open_network();
        }
        if m.page == SetupPage::Appearance
            && let Some(th) = m.themes.iter().zip(&l.theme_rows).find(|(_, r)| r.contains(x, y)).map(|(t, _)| t.id.clone())
        {
            self.choose(&th)
        }
    }

    fn key_event(&self, _w: &Window, e: &KeyEvent) {
        if !e.pressed {
            return;
        }
        if e.keysym == KeySym::ENTER || e.keysym == 0xff8d {
            self.next()
        } else if e.keysym == KeySym::ESCAPE && self.model.borrow().can_go_back() {
            self.model.borrow_mut().back();
            self.redraw()
        }
    }

    fn should_close(&self, _w: &Window) {
        log("closed — it asks again next time");
        self.quit()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use vents::network::{Address, Interface, Link};

    #[test]
    fn the_pages_in_order_and_their_buttons() {
        let mut m = SetupModel::new(vec![], "aqua", "Ada", "");
        assert!(!m.can_go_back(), "nothing before Welcome");
        assert_eq!(m.continue_label(), "Continue");
        m.forward();
        m.forward();
        m.forward();
        assert_eq!((m.page, m.continue_label()), (SetupPage::Done, "Start Using AbyssBSD"));
        m.forward();
        assert_eq!(m.page, SetupPage::Done, "nothing after All Set");
        m.back();
        assert_eq!(m.page, SetupPage::Appearance);
    }

    #[test]
    fn the_connection_in_a_sentence() {
        let iface = |name: &str, lo: bool, a: &str, p: u32| Interface { name: name.into(), up: true, loopback: lo, link: if lo { Link::Unknown } else { Link::Up }, ipv4: vec![Address { address: a.into(), prefix: p }], mac: None };
        let (lo, em) = (iface("lo0", true, "127.0.0.1", 8), iface("em0", false, "192.168.1.5", 24));
        assert_eq!(SetupModel::connection(&[lo.clone(), em]), "This computer is connected through em0 (192.168.1.5).");
        assert_eq!(SetupModel::connection(&[lo]), "This computer is not connected to a network.");
    }

    #[test]
    fn setup_is_done_once_said() {
        let d = std::env::temp_dir().join(format!("abyss-setup.{}", std::process::id()));
        std::fs::create_dir_all(&d).unwrap();
        let d = d.to_str().unwrap();
        assert!(!pool_config::SetupState::done(Some(d)), "a new account has not been through it");
        pool_config::SetupState::mark_done(true, Some(d)).unwrap();
        assert!(pool_config::SetupState::done(Some(d)), "skipped counts as said");
        let _ = std::fs::remove_dir_all(d);
    }
}
