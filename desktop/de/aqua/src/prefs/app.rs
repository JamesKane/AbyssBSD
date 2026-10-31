//! The System Preferences window: navigation, the panes it hosts, its menu
//! service, and the layout lines a test clicks by (`ABYSS_PREFS_DUMP`,
//! §2.46).

use super::*;
use crate::commands::key_equivalent_of;
use aquadraw::chrome::{chrome_hit, window_chrome, ChromeEdge, ChromeHit, Gadget};
use menu_model::{CommandResult, Enablement};
use menu_wire::{MenuProvider, MenuService};
use std::cell::Cell;
use std::collections::BTreeMap;
use std::rc::Weak;
use surface::{KeySym, RenderTarget, ResizeEdge, Window, WindowDelegate};

/// The panes as the golden scene pictures them: fixed samples.
pub fn sample_panes() -> Vec<Rc<dyn Pane>> {
    vec![Rc::new(general::GeneralPane::default()), Rc::new(islands::IslandsPane::default()), energy::EnergyPane::new(energy::EnergyPaneState::sample()), sound::SoundPane::new(sound::SoundPaneState::sample()), displays::DisplaysPane::new(displays::DisplaysPaneState::sample()), network::NetworkPane::new(network::NetworkPaneState::sample())]
}

/// Every pane with something behind it, live.
pub fn live_panes() -> Vec<Rc<dyn Pane>> {
    vec![Rc::new(general::GeneralPane::default()), Rc::new(islands::IslandsPane::default()), energy::EnergyPane::new(energy::EnergyPaneState::default()), sound::SoundPane::new(sound::SoundPaneState::default()), displays::DisplaysPane::new(displays::DisplaysPaneState::default()), network::NetworkPane::new(network::NetworkPaneState::default())]
}

pub struct SystemPreferences {
    me: Weak<SystemPreferences>,
    host: Rc<PrefsHost>,
    window: RefCell<Option<Rc<Window>>>,
    pub model: RefCell<PrefsModel>,
    layout: RefCell<PrefsLayout>,
    panes: Vec<Rc<dyn Pane>>,
    pointer: Cell<(f64, f64)>,
    menu_service: RefCell<Option<MenuService>>,
    dump: bool,
    dumped_view: RefCell<Option<PrefsView>>,
    on_quit: RefCell<Option<Rc<dyn Fn()>>>,
}

struct Provider<'a>(&'a SystemPreferences);

impl MenuProvider for Provider<'_> {
    fn menu_model(&self) -> MenuBarModel {
        system_preferences_menu_bar()
    }
    fn menu_validate(&self, c: &Command) -> Enablement {
        self.0.validate(&c.verb)
    }
    fn menu_perform(&mut self, c: &Command, _a: &BTreeMap<String, String>) -> CommandResult {
        self.0.perform(&c.verb)
    }
}

impl SystemPreferences {
    pub fn new(display: &Rc<Display>, toolkit: &Rc<Toolkit>, size: (i32, i32)) -> Option<Rc<SystemPreferences>> {
        let app = Rc::new_cyclic(|me: &Weak<SystemPreferences>| SystemPreferences {
            me: me.clone(),
            host: Rc::new(PrefsHost::new(Some(display.clone()), toolkit)),
            window: RefCell::new(None),
            model: RefCell::default(),
            layout: RefCell::default(),
            panes: live_panes(),
            pointer: Cell::new((0.0, 0.0)),
            menu_service: RefCell::new(None),
            dump: std::env::var_os("ABYSS_PREFS_DUMP").is_some(),
            dumped_view: RefCell::new(None),
            on_quit: RefCell::new(None),
        });
        let me = app.me.clone();
        app.host.on_redraw(move || {
            if let Some(a) = me.upgrade() {
                a.redraw()
            }
        });
        let pinned = std::env::var("AQUA_SCALE").ok().and_then(|s| s.parse::<i32>().ok()).filter(|v| *v > 0);
        let w = Window::new(display, "System Preferences", "org.abyssbsd.preferences", size.0, size.1, pinned.unwrap_or(1), pinned.is_none(), Rc::downgrade(&app) as Weak<dyn WindowDelegate>)?;
        let name = menu_wire::service_name("SystemPreferences", std::process::id() as i32);
        if let Ok(s) = MenuService::new(&name) {
            let me = app.me.clone();
            display.add_fd(s.fd(), move || {
                if let Some(a) = me.upgrade() {
                    a.serve()
                }
            });
            *app.menu_service.borrow_mut() = Some(s);
            if w.publish_menus(&name) {
                log(&format!("menus on {name}"))
            }
        }
        *app.window.borrow_mut() = Some(w);
        // ABYSS_PREFS_PANE=<id>: open at that pane (the Setup Assistant's
        // "Open Network Preferences…", P16.7).
        if let Some(id) = std::env::var("ABYSS_PREFS_PANE").ok().filter(|id| pane_info(id).is_some()) {
            app.show(PrefsView::Pane(id))
        }
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

    fn serve(&self) {
        let svc = self.menu_service.borrow_mut().take();
        let Some(mut svc) = svc else { return };
        svc.service_readable(&mut Provider(self));
        *self.menu_service.borrow_mut() = Some(svc);
    }

    fn menus_changed(&self) {
        if let Some(s) = &mut *self.menu_service.borrow_mut() {
            s.changed()
        }
    }

    fn pane(&self, id: &str) -> Option<Rc<dyn Pane>> {
        self.panes.iter().find(|p| p.id() == id).cloned()
    }

    fn current(&self) -> Option<Rc<dyn Pane>> {
        match &self.model.borrow().view {
            PrefsView::Pane(id) => self.pane(id),
            PrefsView::All => None,
        }
    }

    pub fn show(&self, v: PrefsView) {
        if self.model.borrow().view == v {
            return;
        }
        if let Some(p) = self.current() {
            p.hidden(&self.host)
        }
        self.model.borrow_mut().view = v.clone();
        if let PrefsView::Pane(id) = &v
            && let Some(p) = self.pane(id)
        {
            p.shown(&self.host)
        }
        if let Some(w) = self.window.borrow().as_ref() {
            w.set_title(self.model.borrow().title())
        }
        match &v {
            PrefsView::All => log("showing all"),
            PrefsView::Pane(id) => log(&format!("showing {id} — {}", self.pane(id).and_then(|p| p.note()).unwrap_or_else(|| default_note(id).into()))),
        }
        self.menus_changed();
        self.redraw()
    }

    fn validate(&self, verb: &str) -> Enablement {
        let view = self.model.borrow().view.clone();
        match verb {
            VERB_ABOUT => Enablement::Disabled("System Preferences has no About box yet".into()),
            VERB_SHOW_ALL if view == PrefsView::All => Enablement::Disabled("every pane is showing".into()),
            VERB_SHOW_ALL | VERB_QUIT | VERB_MINIMIZE | VERB_CLOSE => Enablement::Enabled,
            v => match verb_pane(v).filter(|id| pane_info(id).is_some()) {
                None => Enablement::Disabled(format!("System Preferences has no verb {v}")),
                Some(id) if view == PrefsView::Pane(id.into()) => Enablement::Disabled("that pane is showing".into()),
                Some(_) => Enablement::Enabled,
            },
        }
    }

    fn perform(&self, verb: &str) -> CommandResult {
        if let Enablement::Disabled(why) = self.validate(verb) {
            return CommandResult::Refused(why);
        }
        match verb {
            VERB_QUIT | VERB_CLOSE => {
                self.quit();
                CommandResult::Ok(Some(String::new()))
            }
            VERB_MINIMIZE => {
                if let Some(w) = self.window.borrow().as_ref() {
                    w.minimize();
                }
                CommandResult::Ok(Some(String::new()))
            }
            VERB_SHOW_ALL => {
                self.show(PrefsView::All);
                CommandResult::Ok(Some("all".into()))
            }
            v => match verb_pane(v) {
                Some(id) => {
                    self.model.borrow_mut().focus = Some(id.into());
                    self.show(PrefsView::Pane(id.into()));
                    CommandResult::Ok(Some(id.into()))
                }
                None => CommandResult::Refused("no such verb".into()),
            },
        }
    }

    /// What was drawn, so a test clicks it rather than coordinates copied
    /// into a script (§2.46).
    fn dump_layout(&self) {
        if !self.dump {
            return;
        }
        let view = self.model.borrow().view.clone();
        if self.dumped_view.borrow().as_ref() != Some(&view) {
            *self.dumped_view.borrow_mut() = Some(view.clone());
            let l = self.layout.borrow();
            let mut line = format!("layout showAll={}", at(&l.show_all));
            for t in &l.toolbar_items {
                line += &format!(" tb.{}={}", t.pane, at(&t.hit))
            }
            if view == PrefsView::All {
                for c in &l.cells {
                    line += &format!(" {}={}", c.pane, at(&c.icon))
                }
            }
            log(&line)
        }
        if let Some(p) = self.current() {
            for line in p.dump() {
                log(&line)
            }
        }
    }
}

impl WindowDelegate for SystemPreferences {
    fn render(&self, _w: &Window, target: &RenderTarget) {
        let m = self.model.borrow().clone();
        let l = self.host.toolkit.draw(target, |c, w, h| paint_system_preferences(c, w, h, &m, &self.panes));
        *self.layout.borrow_mut() = l;
        self.dump_layout()
    }

    fn pointer_moved(&self, _w: &Window, x: f64, y: f64) {
        self.pointer.set((x, y));
        if let Some(p) = self.current() {
            p.pointer_moved(&self.host, x, y)
        }
    }

    fn pointer_button(&self, w: &Window, _button: u32, pressed: bool) {
        let current = self.current();
        if !pressed {
            if let Some(p) = current {
                p.release(&self.host);
            }
            return;
        }
        let (x, y) = self.pointer.get();
        let (sw, sh) = w.size();
        let t = self.host.toolkit.theme.borrow().tokens.clone();
        match chrome_hit(&t, &window_chrome(&t, sw as f64, sh as f64, false), x, y) {
            ChromeHit::Gadget(Gadget::Close) => return self.quit(),
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
        if self.dump {
            log(&format!("press at {},{}", x as i64, y as i64))
        }
        if let Some(p) = current
            && p.press(&self.host, x, y)
        {
            return;
        }
        let hit = prefs_hit(&self.layout.borrow(), &self.model.borrow(), x, y);
        match hit {
            Some(PrefsHit::ShowAll) => self.show(PrefsView::All),
            Some(PrefsHit::Pane(id)) => {
                self.model.borrow_mut().focus = Some(id.into());
                self.show(PrefsView::Pane(id.into()))
            }
            None => {}
        }
    }

    fn key_event(&self, _w: &Window, e: &KeyEvent) {
        if !e.pressed {
            return;
        }
        if e.modifiers.contains(surface::KeyModifiers::COMMAND)
            && let Some(verb) = key_equivalent_of(e).and_then(|k| system_preferences_menu_bar().verb_for(&k).map(String::from))
        {
            self.perform(&verb);
            return;
        }
        if self.model.borrow().view != PrefsView::All {
            let p = self.current();
            if e.keysym == KeySym::ESCAPE && !p.as_ref().is_some_and(|p| p.keeps_escape()) {
                return self.show(PrefsView::All);
            }
            if let Some(p) = p {
                p.key(&self.host, e)
            }
            return;
        }
        let d = match e.keysym {
            KeySym::LEFT => -1,
            KeySym::RIGHT | KeySym::TAB => 1,
            KeySym::UP => -7,
            KeySym::DOWN => 7,
            KeySym::ENTER | KeySym::SPACE => {
                let f = self.model.borrow().focus.clone();
                if let Some(f) = f {
                    self.show(PrefsView::Pane(f))
                }
                return;
            }
            _ => return,
        };
        self.model.borrow_mut().move_focus(d);
        log(&format!("focus {}", self.model.borrow().focus.as_deref().unwrap_or("none")));
        self.redraw()
    }

    fn should_close(&self, _w: &Window) {
        self.quit()
    }
}
