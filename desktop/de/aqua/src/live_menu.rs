//! A menu on a real popup (AquaMenu.swift's live half): an `AquaMenu` drawn
//! into a surface Popup, hovered by the pointer, walked by the keys, and
//! its choice reported to the owner.
//!
//! Since P10.8 a submenu **opens**: hovering its row, or → / Return on it,
//! opens a child beside the row. The menu keeps the chain: which child is
//! open, which menu has the keyboard (the deepest one the person moved
//! into), and closing children before parents, which xdg-shell requires
//! (destroying a popup that is not the topmost is a protocol error).

use crate::commands::{aqua_menu_rows, AquaMenuItem};
use crate::menu::AquaMenu;
use crate::toolkit::Toolkit;
use std::cell::{Cell, RefCell};
use std::rc::{Rc, Weak};
use surface::{KeySym, Popup, PopupDelegate, RenderTarget};

type Callback<A> = RefCell<Option<Rc<dyn Fn(A)>>>;
type SubmenuFor = RefCell<Option<Rc<dyn Fn(usize) -> Option<Rc<LiveMenu>>>>>;

pub struct LiveMenu {
    me: Weak<LiveMenu>,
    toolkit: Rc<Toolkit>,
    pub menu: RefCell<AquaMenu>,
    popup: RefCell<Option<Rc<Popup>>>,
    parent: RefCell<Weak<LiveMenu>>,
    /// The submenu open beside this one, and its row.
    child: RefCell<Option<(usize, Rc<LiveMenu>)>>,
    /// Whether the keyboard is in the child: set when the person moves the
    /// pointer into it or presses → on its row. Until then it stays here, as
    /// on a Mac, where hovering a submenu row opens it without taking keys.
    keys_in_child: Cell<bool>,
    on_choose: Callback<usize>,
    on_dismiss: Callback<()>,
    submenu_for: SubmenuFor,
    on_submenu_opened: Callback<(usize, Rc<LiveMenu>)>,
    on_submenu_closed: Callback<usize>,
}

fn call<A>(cb: &Callback<A>, a: A) {
    // Out of the cell first: a callback may set another.
    let f = cb.borrow().clone();
    if let Some(f) = f {
        f(a)
    }
}

impl LiveMenu {
    pub fn new(toolkit: &Rc<Toolkit>, menu: AquaMenu) -> Rc<LiveMenu> {
        Rc::new_cyclic(|me| LiveMenu {
            me: me.clone(),
            toolkit: toolkit.clone(),
            menu: RefCell::new(menu),
            popup: RefCell::new(None),
            parent: RefCell::new(Weak::new()),
            child: RefCell::new(None),
            keys_in_child: Cell::new(false),
            on_choose: RefCell::new(None),
            on_dismiss: RefCell::new(None),
            submenu_for: RefCell::new(None),
            on_submenu_opened: RefCell::new(None),
            on_submenu_closed: RefCell::new(None),
        })
    }

    /// Told the chosen row: only ever an enabled row that opens nothing.
    /// The owner closes the menu.
    pub fn on_choose(&self, f: impl Fn(usize) + 'static) {
        *self.on_choose.borrow_mut() = Some(Rc::new(f))
    }
    /// Told when it went without a choice: a click outside, or Escape.
    pub fn on_dismiss(&self, f: impl Fn() + 'static) {
        *self.on_dismiss.borrow_mut() = Some(Rc::new(move |()| f()))
    }
    /// The menu a submenu row opens, built by the owner (who wires its
    /// choice); None for a row with nothing to open.
    pub fn submenu_for(&self, f: impl Fn(usize) -> Option<Rc<LiveMenu>> + 'static) {
        *self.submenu_for.borrow_mut() = Some(Rc::new(f))
    }
    /// Told when a submenu opens, with its row (a test reads it, §2.46).
    pub fn on_submenu_opened(&self, f: impl Fn(usize, Rc<LiveMenu>) + 'static) {
        *self.on_submenu_opened.borrow_mut() = Some(Rc::new(move |(i, m)| f(i, m)))
    }
    pub fn on_submenu_closed(&self, f: impl Fn(usize) + 'static) {
        *self.on_submenu_closed.borrow_mut() = Some(Rc::new(f))
    }

    /// Its size in points: the longest row, at least `min_width`.
    pub fn preferred_size(&self, min_width: f64) -> (i32, i32) {
        let t = self.toolkit.theme.borrow().tokens.clone();
        let m = self.menu.borrow();
        let w = m.preferred_width(&mut self.toolkit.runner.borrow_mut(), &t).max(min_width);
        (w.ceil() as i32, m.preferred_height(&t).ceil() as i32)
    }

    /// The popup it draws on, once the owner opened one with this menu as
    /// its delegate.
    pub fn set_popup(&self, p: Rc<Popup>) {
        *self.popup.borrow_mut() = Some(p)
    }

    pub fn is_open(&self) -> bool {
        self.popup.borrow().as_ref().is_some_and(|p| p.is_open())
    }

    fn redraw(&self) {
        let p = self.popup.borrow().clone();
        if let Some(p) = p {
            p.set_needs_display()
        }
    }

    pub fn child(&self) -> Option<Rc<LiveMenu>> {
        self.child.borrow().as_ref().map(|(_, c)| c.clone())
    }

    /// The menu that has the keyboard: the deepest one the person moved
    /// into.
    pub fn key_menu(self: &Rc<Self>) -> Rc<LiveMenu> {
        match self.child() {
            Some(c) if self.keys_in_child.get() => c.key_menu(),
            _ => self.clone(),
        }
    }

    /// Whether the highlighted row opens a submenu: → goes into it, not to
    /// the next title in the bar.
    pub fn highlight_opens_submenu(&self) -> bool {
        let m = self.menu.borrow();
        m.hovered.is_some_and(|h| h < m.items.len() && m.items[h].has_submenu && m.items[h].enabled)
    }

    /// Open the submenu on row `i`, beside it. With `highlight_first` (the
    /// keyboard opened it) its first choosable row is highlighted and the
    /// keys go to it.
    pub fn open_child(self: &Rc<Self>, i: usize, highlight_first: bool) -> bool {
        self.close_child();
        let Some(pop) = self.popup.borrow().clone() else { return false };
        let f = self.submenu_for.borrow().clone();
        let Some(menu) = f.and_then(|f| f(i)) else { return false };
        let t = self.toolkit.theme.borrow().tokens.clone();
        let (ry, rh) = aqua_menu_rows(&self.menu.borrow().items, &t)[i];
        let (w, h) = menu.preferred_size(150.0);
        // Its first row level with this one: up by the menu's top padding.
        let Some(cp) = pop.submenu(ry as i32, rh as i32, t.menu_pad_v as i32, w, h, Rc::downgrade(&menu) as Weak<dyn PopupDelegate>) else { return false };
        menu.set_popup(cp);
        *menu.parent.borrow_mut() = Rc::downgrade(self);
        *self.child.borrow_mut() = Some((i, menu.clone()));
        if highlight_first {
            self.keys_in_child.set(true);
            menu.menu.borrow_mut().move_highlight(1);
        }
        call(&self.on_submenu_opened, (i, menu));
        true
    }

    /// Close the submenu, and any it opened, deepest first.
    pub fn close_child(&self) {
        let Some((row, c)) = self.child.borrow_mut().take() else { return };
        c.close_child();
        if let Some(p) = c.popup.borrow_mut().take() {
            p.close()
        }
        self.keys_in_child.set(false);
        call(&self.on_submenu_closed, row);
    }

    /// Close this menu and everything opened from it, children first: the
    /// one way to take a chain down without a protocol error.
    pub fn close_all(&self) {
        self.close_child();
        if let Some(p) = self.popup.borrow_mut().take() {
            p.close()
        }
    }

    fn root(self: &Rc<Self>) -> Rc<LiveMenu> {
        let mut r = self.clone();
        loop {
            let p = r.parent.borrow().upgrade();
            match p {
                Some(p) => r = p,
                None => return r,
            }
        }
    }

    /// A key while the menu is open (a grabbing popup does not take the
    /// keyboard: the window forwards it). ↑ ↓ move the highlight, Return or
    /// Space choose, → and ← go in and out of submenus, Escape dismisses
    /// the whole chain. Whether it was the menu's.
    pub fn key_down(self: &Rc<Self>, keysym: u32) -> bool {
        // The deepest menu the person is in takes the key.
        if self.keys_in_child.get()
            && let Some(c) = self.child()
        {
            return c.key_down(keysym);
        }
        let has_parent = self.parent.borrow().strong_count() > 0;
        let into = matches!(keysym, KeySym::RIGHT | KeySym::ENTER | KeySym::SPACE);
        if into && self.highlight_opens_submenu() {
            let h = self.menu.borrow().hovered.unwrap_or(0);
            match self.child.borrow().as_ref() {
                Some((row, c)) if *row == h => {
                    self.keys_in_child.set(true);
                    c.menu.borrow_mut().move_highlight(1);
                    c.redraw();
                    return true;
                }
                _ => {}
            }
            self.open_child(h, true);
            return true;
        }
        if keysym == KeySym::LEFT && has_parent {
            // Out of a submenu: ← closes it, and the keys go back up.
            if let Some(p) = self.parent.borrow().upgrade() {
                p.close_child()
            }
            return true;
        }
        // → on a plain row inside a submenu does nothing: walking the bar's
        // titles is the root's, and only there.
        if keysym == KeySym::RIGHT && has_parent {
            return true;
        }
        match keysym {
            KeySym::UP | KeySym::DOWN => {
                self.menu.borrow_mut().move_highlight(if keysym == KeySym::UP { -1 } else { 1 });
                self.redraw();
                true
            }
            KeySym::ENTER | KeySym::SPACE => {
                let pick = self.menu.borrow().hovered.filter(|&h| self.menu.borrow().items.get(h).is_some_and(AquaMenuItem::is_choosable));
                if let Some(i) = pick {
                    call(&self.on_choose, i)
                }
                true
            }
            KeySym::ESCAPE => {
                // A dismissal, so said: `close` alone reports nothing, and
                // the owner would think a menu that is gone still open.
                let root = self.root();
                root.close_all();
                call(&root.on_dismiss, ());
                true
            }
            _ => false,
        }
    }
}

impl PopupDelegate for LiveMenu {
    fn render(&self, _p: &Popup, target: &RenderTarget) {
        let m = self.menu.borrow();
        self.toolkit.draw(target, |c, w, h| m.render(c, w, h))
    }

    fn pointer_moved(&self, _p: &Popup, _x: f64, y: f64) {
        // The pointer is here: the keyboard follows it, and a parent's keys
        // come down the chain to this menu.
        if let Some(p) = self.parent.borrow().upgrade() {
            p.keys_in_child.set(true)
        }
        self.keys_in_child.set(false);
        let t = self.toolkit.theme.borrow().tokens.clone();
        if !self.menu.borrow_mut().pointer_moved(y, &t) {
            return;
        }
        self.redraw();
        // Hovering a submenu row opens it; hovering another closes it.
        let h = self.menu.borrow().hovered;
        let open_row = self.child.borrow().as_ref().map(|(r, _)| *r);
        let Some(me) = self.me.upgrade() else { return };
        match h {
            Some(i) if self.highlight_opens_submenu() => {
                if open_row != Some(i) {
                    me.open_child(i, false);
                }
            }
            _ => self.close_child(),
        }
    }

    /// Chosen on release over a row (click to open, click to choose); a
    /// submenu row opens on hover and chooses nothing.
    fn pointer_button(&self, _p: &Popup, pressed: bool) {
        if pressed {
            return;
        }
        let pick = self.menu.borrow().choice();
        if let Some(i) = pick {
            call(&self.on_choose, i)
        }
    }

    /// The compositor ended the chain (a click outside): forget the popup,
    /// and the child it had; the root tells the owner.
    fn dismissed(&self, _p: &Popup) {
        self.popup.borrow_mut().take();
        self.child.borrow_mut().take();
        self.keys_in_child.set(false);
        if self.parent.borrow().strong_count() == 0 {
            call(&self.on_dismiss, ())
        }
    }
}
