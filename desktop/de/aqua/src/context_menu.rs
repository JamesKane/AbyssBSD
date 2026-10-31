//! The menu under a right-click (ContextMenu.swift, P10.8). Not a second
//! list of what an application can do: **a selection of the same
//! Commands** its menus define, shown at the pointer, so a right-click and
//! the menu bar can never disagree about a name, a key or whether it runs.
//!
//! Every row is logged with its offset **inside the popup**; where the popup
//! lands is the compositor's to say (undertow logs it), and a test adds the
//! two (§2.46).

use crate::commands::{aqua_menu_items, aqua_menu_rows};
use crate::live_menu::LiveMenu;
use crate::menu::AquaMenu;
use crate::toolkit::Toolkit;
use menu_model::{Command, Enablement, Menu};
use std::rc::Rc;
use surface::Popup;

/// Open `menu` at the pointer. `open` makes the popup (a window's or a
/// layer surface's) at the click, `size` in points; `choose` runs a
/// command; `on_close` hears it go, chosen or not. None for a menu with no
/// rows, or no popup.
#[allow(clippy::too_many_arguments)]
pub fn open_context_menu(
    toolkit: &Rc<Toolkit>,
    menu: &Menu,
    name: &str,
    enablement: &dyn Fn(&Command) -> Enablement,
    log: &dyn Fn(&str),
    open: impl FnOnce((i32, i32), &Rc<LiveMenu>) -> Option<Rc<Popup>>,
    choose: impl Fn(&Command) + 'static,
    on_close: impl Fn() + 'static,
) -> Option<Rc<LiveMenu>> {
    let rows = aqua_menu_items(menu, enablement);
    if rows.is_empty() {
        return None;
    }
    let commands: Vec<Command> = menu.commands().into_iter().cloned().collect();
    let lm = LiveMenu::new(toolkit, AquaMenu::new(rows.clone(), None));
    let size = lm.preferred_size(150.0);
    let pop = open(size, &lm)?;
    lm.set_popup(pop);
    let on_close = Rc::new(on_close);
    let (close, verbs) = (on_close.clone(), rows.iter().map(|r| r.verb.clone()).collect::<Vec<_>>());
    let me = Rc::downgrade(&lm);
    lm.on_choose(move |i| {
        if let Some(m) = me.upgrade() {
            m.close_all()
        }
        close();
        if let Some(c) = verbs[i].as_ref().and_then(|v| commands.iter().find(|c| &c.verb == v)) {
            choose(c)
        }
    });
    lm.on_dismiss(move || on_close());
    log(&format!("context menu {name}"));
    let t = toolkit.theme.borrow().tokens.clone();
    for (row, (y, h)) in rows.iter().zip(aqua_menu_rows(&rows, &t)) {
        if row.is_separator {
            continue;
        }
        let state = if row.enabled { "enabled" } else { "disabled" };
        let verb = row.verb.as_ref().map_or(String::new(), |v| format!(" {v}"));
        log(&format!("context item '{}' at +30,+{} {state}{verb}", row.title, (y + h / 2.0) as i64));
    }
    Some(lm)
}
