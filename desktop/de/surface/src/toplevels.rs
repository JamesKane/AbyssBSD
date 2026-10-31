//! The compositor's open toplevels, over wlr-foreign-toplevel-management
//! (ForeignToplevels.swift): what the Dock shows running and activates.
//! Each handle's title, app id and state are mirrored, and the owner is
//! told on each atomic `done`.
//!
//! The manager is bound here, not with the other globals, so its listener
//! is there before the events for windows already open arrive.

use crate::display::Display;
use abyss_sys::wlc::{u32s, wl_registry_bind::bind, zwlr_foreign_toplevel_handle_v1 as handle, zwlr_foreign_toplevel_manager_v1 as manager, Obj};
use std::cell::RefCell;
use std::rc::{Rc, Weak};

#[derive(Clone, Debug, PartialEq)]
pub struct ToplevelInfo {
    pub handle: Obj,
    pub app_id: String,
    pub title: String,
    pub activated: bool,
}

type OnChange = Rc<dyn Fn(&[ToplevelInfo])>;

pub struct ForeignToplevels {
    display: Rc<Display>,
    me: Weak<ForeignToplevels>,
    /// The live toplevels, oldest first.
    toplevels: RefCell<Vec<ToplevelInfo>>,
    on_change: OnChange,
}

impl ForeignToplevels {
    /// Bind the manager; None if the compositor does not offer it.
    /// `on_change` hears the whole list after every change.
    pub fn new(display: &Rc<Display>, on_change: impl Fn(&[ToplevelInfo]) + 'static) -> Option<Rc<ForeignToplevels>> {
        let (name, version) = display.globals.borrow().foreign_toplevel_manager?;
        let mgr = bind(display.registry, name, manager::interface(), version)?;
        let ft = Rc::new_cyclic(|me| ForeignToplevels { display: display.clone(), me: me.clone(), toplevels: RefCell::default(), on_change: Rc::new(on_change) });
        let me = Rc::downgrade(&ft);
        manager::listen(mgr, move |e| {
            if let (Some(ft), manager::Event::Toplevel { toplevel: Some(h) }) = (me.upgrade(), e) {
                ft.add(h)
            }
        });
        Some(ft)
    }

    /// A snapshot of the open toplevels.
    pub fn current(&self) -> Vec<ToplevelInfo> {
        self.toplevels.borrow().clone()
    }

    fn seat(&self) -> Option<Obj> {
        self.display.globals.borrow().seat
    }

    /// Raise the first toplevel of `app_id`.
    pub fn activate_app(&self, app_id: &str) -> bool {
        let h = self.toplevels.borrow().iter().find(|t| t.app_id == app_id).map(|t| t.handle);
        match (h, self.seat()) {
            (Some(h), Some(seat)) => {
                handle::activate(h, seat);
                self.display.flush();
                true
            }
            _ => false,
        }
    }

    pub fn activate(&self, info: &ToplevelInfo) {
        if let Some(seat) = self.seat() {
            handle::activate(info.handle, seat);
            self.display.flush()
        }
    }

    /// Ask every window of `app_id` to close: Quit from a Dock tile (P10.8).
    /// A polite request each may refuse; Force Quit is the compositor's.
    /// How many were asked.
    pub fn close_app(&self, app_id: &str) -> usize {
        let mine: Vec<Obj> = self.toplevels.borrow().iter().filter(|t| t.app_id == app_id).map(|t| t.handle).collect();
        for h in &mine {
            handle::close(*h)
        }
        self.display.flush();
        mine.len()
    }

    fn add(&self, h: Obj) {
        self.toplevels.borrow_mut().push(ToplevelInfo { handle: h, app_id: String::new(), title: String::new(), activated: false });
        let me = self.me.clone();
        handle::listen(h, move |e| {
            let Some(ft) = me.upgrade() else { return };
            let edit = |f: &dyn Fn(&mut ToplevelInfo)| {
                if let Some(t) = ft.toplevels.borrow_mut().iter_mut().find(|t| t.handle == h) {
                    f(t)
                }
            };
            match e {
                handle::Event::Title { title } => edit(&|t| t.title = title.clone()),
                handle::Event::AppId { app_id } => edit(&|t| t.app_id = app_id.clone()),
                handle::Event::State { state } => {
                    let on = u32s(&state).contains(&handle::STATE_ACTIVATED);
                    edit(&|t| t.activated = on)
                }
                handle::Event::Done {} => ft.notify(),
                handle::Event::Closed {} => {
                    ft.toplevels.borrow_mut().retain(|t| t.handle != h);
                    handle::destroy(h);
                    ft.notify()
                }
                _ => {}
            }
        });
    }

    fn notify(&self) {
        let list = self.current();
        (self.on_change)(&list)
    }
}
