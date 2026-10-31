//! The menu bar's view of focus (MenuBarFocus.swift, P10.3):
//! `abyss_menubar_v1`, offered only on undertow's privileged socket, so it
//! binds only for the menu bar. Whenever focus moves it says which
//! application is frontmost and where its menus are published, once on bind
//! too, so a bar that starts after the windows it serves is not blank until
//! somebody clicks. Since v3, islands: what each display shows, and every
//! window on every island, for the island menu.

use crate::display::Display;
use abyss_sys::wlc::{abyss_menubar_v1 as bar, wl_registry_bind::bind, Obj};
use std::cell::{Cell, RefCell};
use std::collections::BTreeMap;
use std::rc::{Rc, Weak};

/// How the frontmost application publishes its menus.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
pub enum MenuKind {
    #[default]
    None,
    Abyss,
    Gtk,
}

impl MenuKind {
    fn from(k: u32) -> MenuKind {
        match k {
            bar::KIND_ABYSS => MenuKind::Abyss,
            bar::KIND_GTK => MenuKind::Gtk,
            // 3 was Qt's dbusmenu, retired with Qt (one toolkit); never reused.
            _ => MenuKind::None,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Default)]
pub struct Focus {
    pub kind: MenuKind,
    pub address: String,
    pub app_id: String,
    /// The window's jail class, or "" (v5, P18.6).
    pub jail: String,
}

/// What a display shows (v3, P13.4).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Island {
    pub display: String,
    pub island: u32,
    pub name: String,
    pub count: u32,
    pub is_main: bool,
}

/// A window, wherever it is, for the island menu.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct IslandWindow {
    pub id: u32,
    pub display: String,
    pub island: u32,
    pub app_id: String,
    pub title: String,
    /// The owning client's pid (v6, P18.13b); 0 when not known.
    pub pid: i32,
}

/// A shoal, as the island list tells it (v4, P13.6).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ShoalInfo {
    pub display: String,
    pub island: u32,
    pub index: u32,
    pub name: String,
    pub open: u32,
}

/// One `list_islands` answer.
#[derive(Clone, Debug, Default)]
pub struct IslandList {
    pub windows: Vec<IslandWindow>,
    pub names: Vec<String>,
    pub shoals: Vec<ShoalInfo>,
}

type Waiter = Box<dyn FnOnce(&IslandList)>;
type Hook<T> = RefCell<Option<Rc<dyn Fn(&T)>>>;

pub struct MenuBarFocus {
    display: Rc<Display>,
    proxy: Obj,
    version: u32,
    current: RefCell<Option<Focus>>,
    /// The `jail` event's class, until the `focused` it precedes (v5).
    pending_jail: RefCell<String>,
    on_focus: Hook<Focus>,
    /// Every display's island, as last told.
    islands: RefCell<BTreeMap<String, Island>>,
    on_island: Hook<Island>,
    listing: RefCell<IslandList>,
    waiters: RefCell<Vec<Waiter>>,
    asked: Cell<bool>,
}

impl MenuBarFocus {
    /// None when this connection was not offered the global: when this
    /// process is not the menu bar's.
    pub fn new(display: &Rc<Display>) -> Option<Rc<MenuBarFocus>> {
        let (name, version) = display.globals.borrow().menubar?;
        let proxy = bind(display.registry, name, bar::interface(), version)?;
        let m = Rc::new(MenuBarFocus {
            display: display.clone(),
            proxy,
            version,
            current: RefCell::new(None),
            pending_jail: RefCell::default(),
            on_focus: RefCell::new(None),
            islands: RefCell::default(),
            on_island: RefCell::new(None),
            listing: RefCell::default(),
            waiters: RefCell::default(),
            asked: Cell::new(false),
        });
        let me: Weak<MenuBarFocus> = Rc::downgrade(&m);
        bar::listen(proxy, move |e| {
            if let Some(m) = me.upgrade() {
                m.event(e)
            }
        });
        display.flush();
        Some(m)
    }

    fn event(&self, e: bar::Event) {
        use bar::Event::*;
        match e {
            Focused { kind, address, app_id } => {
                let f = Focus { kind: MenuKind::from(kind), address, app_id, jail: std::mem::take(&mut self.pending_jail.borrow_mut()) };
                *self.current.borrow_mut() = Some(f.clone());
                let cb = self.on_focus.borrow().clone();
                if let Some(cb) = cb {
                    cb(&f)
                }
            }
            Jail { class } => *self.pending_jail.borrow_mut() = class,
            Island { display, island, name, count, is_main } => {
                let i = self::Island { display: display.clone(), island, name, count, is_main: is_main != 0 };
                self.islands.borrow_mut().insert(display, i.clone());
                let cb = self.on_island.borrow().clone();
                if let Some(cb) = cb {
                    cb(&i)
                }
            }
            Window { id, display, island, app_id, title } => self.listing.borrow_mut().windows.push(IslandWindow { id, display, island, app_id, title, pid: 0 }),
            WindowPid { id, pid } => {
                if let Some(w) = self.listing.borrow_mut().windows.iter_mut().rev().find(|w| w.id == id) {
                    w.pid = pid as i32
                }
            }
            Shoal { display, island, index, name, open } => self.listing.borrow_mut().shoals.push(ShoalInfo { display, island, index, name, open }),
            IslandsDone { names } => {
                let mut got = std::mem::take(&mut *self.listing.borrow_mut());
                got.names = names.split('\t').map(String::from).collect();
                self.asked.set(false);
                let waiters = std::mem::take(&mut *self.waiters.borrow_mut());
                for w in waiters {
                    w(&got)
                }
            }
        }
    }

    /// Heard on every `focused`, the one sent on bind included.
    pub fn on_focus(&self, f: impl Fn(&Focus) + 'static) {
        *self.on_focus.borrow_mut() = Some(Rc::new(f))
    }
    pub fn on_island(&self, f: impl Fn(&Island) + 'static) {
        *self.on_island.borrow_mut() = Some(Rc::new(f))
    }

    pub fn current(&self) -> Option<Focus> {
        self.current.borrow().clone()
    }
    pub fn islands(&self) -> Vec<Island> {
        self.islands.borrow().values().cloned().collect()
    }
    /// The main display's island, if the compositor says.
    pub fn main_island(&self) -> Option<Island> {
        self.islands.borrow().values().find(|i| i.is_main).cloned()
    }

    /// Ask the compositor to kill `app_id` (P10.8); false when it is too old
    /// to be asked.
    pub fn force_quit(&self, app_id: &str) -> bool {
        self.send(2, |p| bar::force_quit(p, app_id))
    }

    /// Every island's windows and names, answered when `islands_done`
    /// arrives; one question in flight serves every caller waiting.
    pub fn list_islands(&self, done: impl FnOnce(&IslandList) + 'static) -> bool {
        if self.version < 3 {
            return false;
        }
        self.waiters.borrow_mut().push(Box::new(done));
        if !self.asked.replace(true) {
            bar::list_islands(self.proxy)
        }
        self.display.flush();
        true
    }

    pub fn switch_island(&self, display: &str, island: u32) -> bool {
        island >= 1 && self.send(3, |p| bar::switch_island(p, display, island))
    }

    /// A shoal command (v4): recall, new, add, remove, strip.
    pub fn shoal_command(&self, verb: &str, arg: u32) -> bool {
        self.send(4, |p| bar::shoal_command(p, verb, arg))
    }

    pub fn activate_window(&self, id: u32) -> bool {
        self.send(3, |p| bar::activate_window(p, id))
    }

    fn send(&self, since: u32, f: impl FnOnce(Obj)) -> bool {
        if self.version < since {
            return false;
        }
        f(self.proxy);
        self.display.flush();
        true
    }
}

impl Drop for MenuBarFocus {
    fn drop(&mut self) {
        bar::destroy(self.proxy)
    }
}
