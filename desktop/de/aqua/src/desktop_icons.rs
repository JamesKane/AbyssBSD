//! The icons on the desktop itself (DesktopIcons.swift): the boot volume
//! and what is in ~/Desktop, drawn on the wallpaper. Jaguar's arrangement,
//! not the Finder's: **from the top-right corner down**, then a new column
//! to the left, so the volume sits under the menu bar's right end. One pure
//! layout feeds paint and hit-test (HANDOFF §2.9).
//!
//! Labels are white on a dark shadow: they sit on any wallpaper, pale
//! gradient or photograph.

use crate::app_icon;
use crate::finder_model::{finder_sort, read_directory, FinderEntry, FinderItemKind};
use aquadraw::canvas::Canvas;
use aquadraw::drawlist::{DrawState, Role};
use aquadraw::runner::Rect;
use aquadraw::text::Style;
use aquadraw::tokens::ThemeTokens;

/// Rows of icons that fit `bounds`, at least one.
pub fn desktop_rows(t: &ThemeTokens, bounds: Rect) -> usize {
    (((bounds.h - 2.0 * t.desktop_margin) / t.desktop_cell_h) as i64).max(1) as usize
}

/// Icon `i`'s cell: down the right-hand column, then the one to its left.
pub fn desktop_icon_rect(t: &ThemeTokens, i: usize, bounds: Rect) -> Rect {
    let rows = desktop_rows(t, bounds);
    let (col, row) = (i / rows, i % rows);
    Rect::new(bounds.x + bounds.w - t.desktop_margin - (col + 1) as f64 * t.desktop_cell_w, bounds.y + t.desktop_margin + row as f64 * t.desktop_cell_h, t.desktop_cell_w, t.desktop_cell_h)
}

/// Where the art sits in a cell; the label goes under it.
pub fn desktop_icon_box(t: &ThemeTokens, cell: Rect) -> Rect {
    Rect::new(cell.x + (cell.w - t.desktop_icon_size) / 2.0, cell.y + 4.0, t.desktop_icon_size, t.desktop_icon_size)
}

/// The icon under a point. Only the icon and its label are hit: the blank
/// rest of a cell is the desktop's, as on a Mac.
pub fn desktop_index(t: &ThemeTokens, x: f64, y: f64, count: usize, bounds: Rect) -> Option<usize> {
    (0..count).find(|&i| {
        let cell = desktop_icon_rect(t, i, bounds);
        let icon = desktop_icon_box(t, cell);
        let label = Rect::new(cell.x + 4.0, icon.y + icon.h + 2.0, cell.w - 8.0, 16.0);
        icon.contains(x, y) || label.contains(x, y)
    })
}

/// The boot volume first (so it lands top-right), then the Desktop folder
/// in Finder order.
pub fn desktop_entries(volume_name: &str, desktop_folder: Option<&str>, show_hidden: bool) -> Vec<FinderEntry> {
    let mut v = vec![FinderEntry::new(volume_name, FinderItemKind::Disk)];
    if let Some(dir) = desktop_folder {
        v.extend(read_directory(dir, show_hidden))
    }
    v
}

/// A fixed desktop for the PNG scene.
pub fn desktop_sample_entries() -> Vec<FinderEntry> {
    let mut v = vec![FinderEntry::new("AbyssBSD HD", FinderItemKind::Disk)];
    v.extend(finder_sort(vec![FinderEntry::new("Projects", FinderItemKind::Folder), FinderEntry::sized("Screenshot.png", FinderItemKind::Document, 148_000), FinderEntry::sized("Notes.rtf", FinderItemKind::Document, 3_200)]));
    v
}

/// An entry's icon: the bundle's own art when it has some, else the
/// theme's glyph for its kind. Everything that draws a listed item comes
/// here, so the Finder and the desktop agree.
pub fn draw_finder_icon(c: &mut Canvas, entry: &FinderEntry, r: Rect) {
    if let Some(p) = &entry.icon_path
        && app_icon::draw(c, p, r)
    {
        return;
    }
    let name = match entry.kind {
        FinderItemKind::Folder => "icon.folder",
        FinderItemKind::Application => "icon.application",
        FinderItemKind::Document => "icon.document",
        FinderItemKind::Disk => "icon.disk",
    };
    c.icon(name, r)
}

/// Shorten with an ellipsis until it fits: the desktop has no column to
/// widen.
fn truncated(c: &mut Canvas, s: &str, max_width: f64, size: f64) -> String {
    let w = |c: &mut Canvas, s: &str| c.text_width(s, size, Style::Regular, Role::Interface);
    if max_width <= 0.0 || w(c, s) <= max_width {
        return s.into();
    }
    let mut out: Vec<char> = s.chars().collect();
    while !out.is_empty() && w(c, &format!("{}…", out.iter().collect::<String>())) > max_width {
        out.pop();
    }
    format!("{}…", out.into_iter().collect::<String>())
}

/// The icons, over a wallpaper already painted.
pub fn paint_desktop_icons(c: &mut Canvas, bounds: Rect, entries: &[FinderEntry], selection: Option<usize>) {
    let t = c.theme.tokens.clone();
    for (i, entry) in entries.iter().enumerate() {
        let cell = desktop_icon_rect(&t, i, bounds);
        // Off the left edge: the rest would be too.
        if cell.x + cell.w <= bounds.x {
            break;
        }
        let icon = desktop_icon_box(&t, cell);
        let selected = selection == Some(i);
        if selected {
            c.paint_simple("desktop.selection", icon, DrawState::NORMAL)
        }
        draw_finder_icon(c, entry, icon);
        let label = truncated(c, &entry.name, cell.w - 10.0, 11.0);
        let tw = c.text_width(&label, 11.0, Style::Regular, Role::Interface);
        let (cx, ly) = (cell.x + cell.w / 2.0, icon.y + icon.h + 3.0);
        if selected {
            c.paint_simple("iconlabel.selected", Rect::new(cx - tw / 2.0 - 4.0, ly, tw + 8.0, 14.0), DrawState::NORMAL);
            c.text(&label, cx, ly + 7.0, t.menu_text_on_highlight, 11.0, Style::Regular, Role::Interface)
        } else {
            c.text(&label, cx + 1.0, ly + 8.0, t.desktop_label_shadow, 11.0, Style::Regular, Role::Interface);
            c.text(&label, cx, ly + 7.0, t.desktop_label_text, 11.0, Style::Regular, Role::Interface)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn setup() -> (ThemeTokens, Rect) {
        let t = ThemeTokens::default();
        let b = Rect::new(0.0, t.desktop_top_inset, 800.0, 600.0 - t.desktop_top_inset);
        (t, b)
    }

    #[test]
    fn icons_stack_from_the_top_right() {
        let (t, b) = setup();
        let rows = desktop_rows(&t, b);
        assert!(rows > 1);
        let first = desktop_icon_rect(&t, 0, b);
        assert_eq!(first.x + first.w, b.x + b.w - t.desktop_margin);
        assert_eq!(first.y, b.y + t.desktop_margin);
        let second = desktop_icon_rect(&t, 1, b);
        assert_eq!((second.x, second.y), (first.x, first.y + t.desktop_cell_h));
        let wrapped = desktop_icon_rect(&t, rows, b);
        assert_eq!((wrapped.x, wrapped.y), (first.x - t.desktop_cell_w, first.y));
        for i in 0..rows * 2 {
            let r = desktop_icon_rect(&t, i, b);
            assert!(r.x >= b.x && r.y + r.h <= b.y + b.h)
        }
    }

    #[test]
    fn icon_hit_test_round_trips() {
        let (t, b) = setup();
        for i in 0..5 {
            let icon = desktop_icon_box(&t, desktop_icon_rect(&t, i, b));
            assert_eq!(desktop_index(&t, icon.x + icon.w / 2.0, icon.y + icon.h / 2.0, 5, b), Some(i));
        }
        assert_eq!(desktop_index(&t, 100.0, 300.0, 5, b), None);
        assert_eq!(desktop_index(&t, 400.0, 500.0, 5, b), None);
    }

    #[test]
    fn entries_lead_with_the_volume() {
        let dir = std::env::temp_dir().join(format!("desktop.{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(dir.join("Projects")).unwrap();
        std::fs::write(dir.join("notes.txt"), "").unwrap();
        let e = desktop_entries("AbyssBSD HD", dir.to_str(), false);
        assert_eq!(e[0].kind, FinderItemKind::Disk);
        assert_eq!(e.iter().map(|e| e.name.as_str()).collect::<Vec<_>>(), ["AbyssBSD HD", "notes.txt", "Projects"]);
        assert_eq!(desktop_entries("AbyssBSD HD", None, false).len(), 1);
        let _ = std::fs::remove_dir_all(&dir);
    }
}
