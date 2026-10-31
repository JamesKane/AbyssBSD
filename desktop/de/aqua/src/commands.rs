//! A drawn menu's rows (Commands.swift's half that draws): what each row
//! says, and where it sits, one function for paint and hit-test (§2.9).

use aquadraw::tokens::ThemeTokens;
use menu_model::{Command, Enablement, Menu, MenuItem};

/// One row of a drawn menu.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AquaMenuItem {
    pub title: String,
    /// Right-aligned, as Jaguar draws it: `⇧⌘N`. Empty for none.
    pub key_text: String,
    pub enabled: bool,
    pub is_separator: bool,
    /// Draws the ▸ that says a submenu opens here.
    pub has_submenu: bool,
    /// The command this row runs, when it came from a `Menu`.
    pub verb: Option<String>,
}

impl AquaMenuItem {
    pub fn new(title: &str) -> AquaMenuItem {
        AquaMenuItem { title: title.into(), key_text: String::new(), enabled: true, is_separator: false, has_submenu: false, verb: None }
    }
    pub fn key(mut self, k: &str) -> AquaMenuItem {
        self.key_text = k.into();
        self
    }
    pub fn disabled(mut self) -> AquaMenuItem {
        self.enabled = false;
        self
    }
    pub fn submenu(mut self) -> AquaMenuItem {
        self.has_submenu = true;
        self
    }
    pub fn separator() -> AquaMenuItem {
        AquaMenuItem { is_separator: true, enabled: false, ..AquaMenuItem::new("") }
    }
    /// A row that can be highlighted and chosen.
    pub fn is_choosable(&self) -> bool {
        self.enabled && !self.is_separator
    }
}

/// A `Menu`'s rows, each command's enablement asked of `enablement`. A
/// submenu is a row with an arrow, enabled when anything inside it is.
pub fn aqua_menu_items(menu: &Menu, enablement: &dyn Fn(&Command) -> Enablement) -> Vec<AquaMenuItem> {
    menu.items
        .iter()
        .map(|item| match item {
            MenuItem::Command(c) => AquaMenuItem { key_text: c.key.as_ref().map(|k| k.display()).unwrap_or_default(), enabled: enablement(c).is_enabled(), verb: Some(c.verb.clone()), ..AquaMenuItem::new(&c.title) },
            MenuItem::Separator => AquaMenuItem::separator(),
            MenuItem::Submenu(m) => AquaMenuItem { enabled: m.commands().iter().any(|c| enablement(c).is_enabled()), has_submenu: true, ..AquaMenuItem::new(&m.title) },
        })
        .collect()
}

/// Where each row sits, top and height: separators make rows different
/// heights, and a hit-test that assumed otherwise would choose the row
/// below the one drawn.
pub fn aqua_menu_rows(items: &[AquaMenuItem], t: &ThemeTokens) -> Vec<(f64, f64)> {
    let mut y = t.menu_pad_v;
    items
        .iter()
        .map(|i| {
            let h = if i.is_separator { t.menu_separator_height } else { t.menu_item_height };
            let r = (y, h);
            y += h;
            r
        })
        .collect()
}

pub fn aqua_menu_height(items: &[AquaMenuItem], t: &ThemeTokens) -> f64 {
    let bottom = aqua_menu_rows(items, t).last().map_or(t.menu_pad_v, |(y, h)| y + h);
    bottom + t.menu_pad_v
}

/// The row under `y`, if it can be chosen.
pub fn aqua_menu_row_at(y: f64, items: &[AquaMenuItem], t: &ThemeTokens) -> Option<usize> {
    let rows = aqua_menu_rows(items, t);
    let i = rows.iter().position(|(ry, rh)| y >= *ry && y < ry + rh)?;
    items[i].is_choosable().then_some(i)
}

/// The next choosable row from `from` in `step`'s direction, wrapping;
/// None from nowhere starts before the first (or after the last).
/// Disabled rows and separators are skipped, as Jaguar skips them.
pub fn aqua_menu_step(from: Option<usize>, step: i64, items: &[AquaMenuItem]) -> Option<usize> {
    let n = items.len() as i64;
    if n == 0 {
        return None;
    }
    let mut i = from.map_or(if step > 0 { -1 } else { n }, |f| f as i64);
    for _ in 0..n {
        i = ((i + step) % n + n) % n;
        if items[i as usize].is_choosable() {
            return Some(i as usize);
        }
    }
    None
}
