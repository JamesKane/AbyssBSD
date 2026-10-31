//! A pop-up menu's contents and behaviour (AquaMenu.swift): its rows, the
//! hovered row, the keyboard's highlight, and its drawing. Disabled rows
//! are grey and can be neither hovered nor chosen, separators are thin
//! rules, a key equivalent sits right-aligned in its own column, and a
//! submenu row carries its ▸.
//!
//! The popup it draws into, and the submenus it opens, come with the
//! Wayland half (surface, R5d).

use crate::commands::{aqua_menu_height, aqua_menu_row_at, aqua_menu_rows, aqua_menu_step, AquaMenuItem};
use aquadraw::canvas::{Canvas, Paint};
use aquadraw::drawlist::{DrawState, Role};
use aquadraw::runner::{Rect, Runner};
use aquadraw::text::Style;
use aquadraw::tokens::ThemeTokens;

pub struct AquaMenu {
    pub items: Vec<AquaMenuItem>,
    /// The row checked: a pop-up button's current value.
    pub selected: Option<usize>,
    pub hovered: Option<usize>,
}

impl AquaMenu {
    pub fn new(items: Vec<AquaMenuItem>, selected: Option<usize>) -> AquaMenu {
        AquaMenu { items, selected, hovered: None }
    }

    /// Plain titles, every one enabled: a pop-up button's choices.
    pub fn of_titles(titles: &[&str], selected: usize) -> AquaMenu {
        AquaMenu::new(titles.iter().map(|t| AquaMenuItem::new(t)).collect(), Some(selected))
    }

    /// The height that fits every row.
    pub fn preferred_height(&self, t: &ThemeTokens) -> f64 {
        aqua_menu_height(&self.items, t)
    }

    /// The width that fits the longest title, the key column and the
    /// submenu arrow.
    pub fn preferred_width(&self, runner: &mut Runner, t: &ThemeTokens) -> f64 {
        let rows: Vec<&AquaMenuItem> = self.items.iter().filter(|i| !i.is_separator).collect();
        let w = |runner: &mut Runner, s: &str| runner.text.text_width(s, t.font_size, Style::Regular, Role::Interface);
        let title = rows.iter().map(|i| w(runner, &i.title)).fold(0.0, f64::max);
        let key = rows.iter().map(|i| w(runner, &i.key_text)).fold(0.0, f64::max);
        let arrow = if rows.iter().any(|i| i.has_submenu) { 12.0 } else { 0.0 };
        let key_col = if key > 0.0 { t.menu_key_gap + key } else { 0.0 };
        (t.menu_title_x + title + key_col.max(arrow) + t.menu_right_inset).ceil()
    }

    /// Draw the menu, `w`×`h` points, on a cleared surface.
    pub fn render(&self, c: &mut Canvas, w: f64, h: f64) {
        let t = c.theme.tokens.clone();
        let whole = Rect::new(0.0, 0.0, w, h);
        c.paint_simple("menu", whole, DrawState::NORMAL);
        let rows = aqua_menu_rows(&self.items, &t);
        for (i, (item, (ry, rh))) in self.items.iter().zip(rows).enumerate() {
            if item.is_separator {
                c.paint_simple("menu.separator", Rect::new(0.0, (ry + rh / 2.0).floor(), w, 1.0), DrawState::NORMAL);
                continue;
            }
            let line = Rect::new(0.0, ry, w, rh);
            let color = if self.hovered == Some(i) {
                c.paint_simple("menu.highlight", line, DrawState::NORMAL);
                t.menu_text_on_highlight
            } else if item.enabled {
                t.menu_text
            } else {
                t.menu_text_disabled
            };
            let baseline = ry + rh - 6.0;
            if self.selected == Some(i) {
                c.paint("menu.check", line, Paint { colors: &[("color", color)], ..Paint::default() });
            }
            c.text_left(&item.title, t.menu_title_x, baseline, color, t.font_size, Style::Regular, Role::Interface);
            if !item.key_text.is_empty() {
                let kw = c.text_width(&item.key_text, t.font_size, Style::Regular, Role::Interface);
                c.text_left(&item.key_text, w - t.menu_right_inset - kw, baseline, color, t.font_size, Style::Regular, Role::Interface);
            }
            if item.has_submenu {
                c.paint("menu.submenu", line, Paint { colors: &[("color", color)], ..Paint::default() });
            }
        }
        c.paint_simple("menu.frame", whole, DrawState::NORMAL);
    }

    /// The pointer at (x, y) in the menu: the row under it is hovered.
    /// True if that changed (the popup redraws).
    pub fn pointer_moved(&mut self, y: f64, t: &ThemeTokens) -> bool {
        let idx = aqua_menu_row_at(y, &self.items, t);
        let changed = idx != self.hovered;
        self.hovered = idx;
        changed
    }

    /// Move the keyboard's highlight, from the checked row when nothing is
    /// hovered, so a pop-up button's arrows move from its value.
    pub fn move_highlight(&mut self, d: i64) {
        let start = self.hovered.or(self.selected.filter(|s| *s < self.items.len()));
        if let Some(n) = aqua_menu_step(start, d, &self.items) {
            self.hovered = Some(n)
        }
    }

    /// The hovered row, if it can be chosen and opens nothing.
    pub fn choice(&self) -> Option<usize> {
        self.hovered.filter(|&h| h < self.items.len() && self.items[h].is_choosable() && !self.items[h].has_submenu)
    }
}
