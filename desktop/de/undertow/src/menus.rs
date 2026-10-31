//! Whose menus belong to which window (Menus.swift, PHASE10.md P10.3).
//!
//! A global menu bar shows the focused application's menus, and only the
//! compositor knows which surface is focused. So applications tell undertow,
//! per surface, where their menus are published (`abyss_menu_manager_v1`),
//! and undertow tells the menu bar, and only the menu bar, where the focused
//! surface's menus are whenever that changes (`abyss_menubar_v1`).
//!
//! The binding is surface → address, set by the client that owns the
//! surface on the connection that proves it. Nothing trusts an app_id: any
//! client may claim any app_id it likes. The libwayland plumbing is C
//! (menus.c); the policy is here.

use crate::compositor::Compositor;
use abyss_sys::wlr::menus::{GtkProperties, MenuHooks, Menubar, WindowAtAnswer};
use abyss_sys::wlr::{Listener, Surface};
use menu_model::GtkMenuAddress;
use std::collections::HashMap;
use std::rc::{Rc, Weak};

/// `abyss_menubar_v1.kind`. 3 was Qt's dbusmenu, retired with Qt (one
/// toolkit), and is never reused.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Kind {
    None = 0,
    Abyss = 1,
    Gtk = 2,
}

/// What the bar is told: which kind, where, whose, and the jail's class.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Focus {
    pub kind: Kind,
    pub address: String,
    pub app_id: String,
    pub jail: String,
}

impl Focus {
    pub fn nothing() -> Focus {
        Focus { kind: Kind::None, address: String::new(), app_id: String::new(), jail: String::new() }
    }

    fn describe(&self) -> String {
        let base = match self.kind {
            Kind::None if self.app_id.is_empty() => "nothing".into(),
            Kind::None => format!("{}, which publishes no menus", self.app_id),
            Kind::Gtk => format!("{} at {} [gtk]", self.app_id, self.address.replace('\n', " ")),
            Kind::Abyss => format!("{} at {} [abyss]", self.app_id, self.address),
        };
        if self.jail.is_empty() { base } else { format!("{base} (confined in {})", self.jail) }
    }
}

struct Entry {
    address: String,
    kind: Kind,
    _destroy: Option<Listener>,
}

/// The menus' state: who published what, and what the bars were last told.
pub struct MenuState {
    addresses: HashMap<Surface, Entry>,
    /// So a focus change that changes nothing sends nothing.
    pub last_sent: Focus,
    /// Every `focused` sent, for tests and the log.
    pub sent_count: u64,
}

impl MenuState {
    pub(crate) fn addresses_clear(&mut self) {
        self.addresses.clear()
    }
}

impl Default for MenuState {
    fn default() -> MenuState {
        MenuState { addresses: HashMap::new(), last_sent: Focus::nothing(), sent_count: 0 }
    }
}

pub fn log(s: &str) {
    eprintln!("undertow: menus: {s}");
}

impl Compositor {
    /// The address a surface published, if any.
    pub fn menu_address(&self, s: Surface) -> Option<String> {
        self.menu_state.borrow().addresses.get(&s).map(|e| e.address.clone())
    }

    fn set_menu_address(&self, surface: Surface, address: &str, kind: Kind) {
        {
            let mut st = self.menu_state.borrow_mut();
            if address.is_empty() {
                st.addresses.remove(&surface);
            } else if let Some(e) = st.addresses.get_mut(&surface) {
                e.address = address.into();
                e.kind = kind;
            } else {
                // Forgotten with the surface: an address outliving its window
                // would point the bar at a menu for something not on screen.
                let w = self.me.clone();
                let destroy = surface.on_destroy(move || {
                    let Some(c) = w.upgrade() else { return };
                    let gone = c.menu_state.borrow_mut().addresses.remove(&surface);
                    drop(gone); // this listener, dropped from inside its callback
                    c.menus_focus_changed();
                });
                st.addresses.insert(surface, Entry { address: address.into(), kind, _destroy: destroy });
            }
        }
        log(&if address.is_empty() {
            "a surface withdrew its menus".to_owned()
        } else if kind == Kind::Gtk {
            format!("a surface published its menus at {} [gtk]", address.replace('\n', " "))
        } else {
            format!("a surface published its menus at {address}")
        });
        self.menus_focus_changed();
    }

    /// The focused window's jail class, or "": ours names the class as the
    /// context's app id; another engine is named for itself (P18.6).
    fn jail_class(&self, s: Surface) -> String {
        let menus = self.menus.borrow();
        let Some((engine, app, _)) = menus.as_ref().and_then(|m| m.jail(s)) else { return String::new() };
        if engine == "org.abyssbsd.jail" { app } else { engine }
    }

    /// What the bar should be showing now.
    pub fn menus_current(&self) -> Focus {
        let Some(t) = self.focused() else { return self.menus_desktop() };
        let app = t.app_id().unwrap_or_default();
        let jail = self.jail_class(t.surface);
        match self.menu_state.borrow().addresses.get(&t.surface) {
            Some(e) => Focus { kind: e.kind, address: e.address.clone(), app_id: app, jail },
            None => Focus { kind: Kind::None, address: String::new(), app_id: app, jail },
        }
    }

    /// With no window focused the desktop is frontmost, and in Jaguar the
    /// desktop *is* the Finder, whose menus the bar shows (P10.4): whatever a
    /// BACKGROUND layer surface published.
    fn menus_desktop(&self) -> Focus {
        let st = self.menu_state.borrow();
        for l in self.layers.borrow().iter().filter(|l| l.layer() == 0) {
            if let Some(e) = st.addresses.get(&l.surface) {
                return Focus { kind: e.kind, address: e.address.clone(), app_id: l.namespace(), jail: String::new() };
            }
        }
        Focus::nothing()
    }

    /// Focus moved, or the focused surface's address changed: tell the
    /// bars, unless nothing they would show is different.
    pub fn menus_focus_changed(&self) {
        let f = self.menus_current();
        {
            let mut st = self.menu_state.borrow_mut();
            if f == st.last_sent {
                return;
            }
            st.last_sent = f.clone();
            st.sent_count += 1;
        }
        let menus = self.menus.borrow();
        let Some(m) = menus.as_ref() else { return };
        m.send_focused_all(f.kind as u32, &f.address, &f.app_id, &f.jail);
        let n = m.menubar_count();
        log(&format!("focused {} ({n} bar{})", f.describe(), if n == 1 { "" } else { "s" }));
    }

    /// Display `d`'s island, to one bar or every bar.
    pub fn menus_send_island(&self, d: &str, to: Option<Menubar>) {
        let n = self.active_island(d);
        let (name, count) = {
            let i = self.islands.borrow();
            (i.name(n as i64), i.count as u32)
        };
        let main = self.layout.borrow().main().is_some_and(|m| m.name == d);
        match to {
            Some(bar) => bar.send_island(d, n as u32, &name, count, main),
            None => {
                if let Some(m) = self.menus.borrow().as_ref() {
                    m.send_island_all(d, n as u32, &name, count, main)
                }
            }
        }
    }

    /// Force Quit (P10.8): SIGKILL every process with a toplevel of
    /// `app_id`. Only the compositor knows which pid is behind a window,
    /// and only the bar, on the privileged socket, can ask. Never ourselves.
    pub fn force_quit(&self, app_id: &str) -> Vec<i32> {
        let me = std::process::id() as i32;
        let mut pids: Vec<i32> = self.toplevels.borrow().iter().filter(|t| t.app_id().as_deref() == Some(app_id)).filter_map(|t| t.surface.client_pid()).filter(|&p| p != me).collect();
        pids.sort_unstable();
        pids.dedup();
        for &p in &pids {
            let _ = abyss_sys::proc::kill_pid(p, libc::SIGKILL);
        }
        log(&format!("force quit {app_id}: {}", if pids.is_empty() { "no such application".into() } else { format!("killed {}", pids.iter().map(i32::to_string).collect::<Vec<_>>().join(" ")) }));
        pids
    }
}

/// The menus' requests, answered by the compositor.
pub struct Hooks(pub Weak<Compositor>);

impl Hooks {
    fn c(&self) -> Option<Rc<Compositor>> {
        self.0.upgrade()
    }
}

impl MenuHooks for Hooks {
    fn set_address(&self, surface: Surface, address: &str) {
        if let Some(c) = self.c() {
            c.set_menu_address(surface, address, Kind::Abyss)
        }
    }

    fn menubar_bound(&self, bar: Menubar) {
        let Some(c) = self.c() else { return };
        let f = c.menus_current();
        bar.send_focused(f.kind as u32, &f.address, &f.app_id, &f.jail);
        // And what every display shows (P13.4): the bar's island item.
        let names: Vec<String> = c.layout.borrow().displays.iter().map(|d| d.name.clone()).collect();
        for d in names {
            c.menus_send_island(&d, Some(bar))
        }
        log(&format!("a menu bar bound; told it {}", f.describe()));
    }

    fn set_gtk_properties(&self, surface: Surface, p: GtkProperties) {
        let Some(c) = self.c() else { return };
        let a = GtkMenuAddress { application_id: p.application_id, bus_name: p.unique_bus_name, application_path: p.application_object_path, menubar_path: p.menubar_path, app_menu_path: p.app_menu_path, window_path: p.window_object_path };
        // GTK says this for every window, menus or not; only one with
        // something to read is worth pointing the bar at.
        c.set_menu_address(surface, &if a.has_menus() { a.encoded() } else { String::new() }, Kind::Gtk);
    }

    fn force_quit(&self, app_id: &str) {
        if let Some(c) = self.c() {
            c.force_quit(app_id);
        }
    }

    fn lower(&self, surface: Surface) {
        let Some(c) = self.c() else { return };
        let t = c.toplevels.borrow().iter().find(|t| t.surface == surface).cloned();
        if let Some(t) = t {
            c.lower(&t)
        }
    }

    fn window_at(&self, x: i32, y: i32) -> Option<WindowAtAnswer> {
        let c = self.c()?;
        let (t, b) = c.window_box(x as f64, y as f64)?;
        Some(WindowAtAnswer { x: b.x, y: b.y, width: b.width, height: b.height, app_id: t.app_id().unwrap_or_default(), title: t.title().unwrap_or_default() })
    }

    fn list_islands(&self, bar: Menubar) {
        let Some(c) = self.c() else { return };
        let ts = c.toplevels.borrow().clone();
        for t in ts.iter().filter(|t| t.mapped.get() && !t.minimized.get()) {
            bar.send_window(t.id, &t.island_display.borrow(), t.island.get() as u32, &t.app_id().unwrap_or_default(), &t.title().unwrap_or_default(), t.surface.client_pid());
        }
        let shoals = c.shoal_book.borrow().shoals.clone();
        for (i, s) in shoals.iter().enumerate() {
            let open = s.members.iter().filter(|k| ts.iter().any(|t| t.mapped.get() && t.place_key().as_deref() == Some(k.as_str()))).count();
            bar.send_shoal(&s.display, s.island as u32, i as u32, &s.name, open as u32);
        }
        let names = {
            let i = c.islands.borrow();
            (1..=i.count).map(|n| i.name(n)).collect::<Vec<_>>().join("\t")
        };
        bar.send_islands_done(&names);
    }

    fn switch_island(&self, display: &str, island: u32) {
        let Some(c) = self.c() else { return };
        let d = if display.is_empty() { c.layout.borrow().main().map(|m| m.name.clone()).unwrap_or_default() } else { display.to_owned() };
        c.switch_island(island as i32, Some(&d));
    }

    fn activate_window(&self, id: u32) {
        let Some(c) = self.c() else { return };
        let t = c.toplevels.borrow().iter().find(|t| t.id == id && t.mapped.get()).cloned();
        if let Some(t) = t {
            c.bring_to_front(&t)
        }
    }

    fn shoal_command(&self, verb: &str, arg: u32) {
        let Some(c) = self.c() else { return };
        match verb {
            "recall" => c.recall_shoal(arg as usize),
            "new" => c.new_shoal(),
            "add" => c.add_focused_to_shoal(Some(arg as usize)),
            "remove" => c.remove_focused_from_shoal(),
            "strip" => c.toggle_shoal_strip(),
            _ => {}
        }
    }
}
