//! AquaTests.swift's toolkit tests, ported: the widget, tab, sheet and
//! scroll scenes' geometry, the drawn menu's rows, and the Finder's command
//! model as the menus show it.

use crate::commands::{aqua_menu_height, aqua_menu_items, aqua_menu_row_at, aqua_menu_rows, aqua_menu_step, AquaMenuItem};
use crate::finder_commands::{context, finder_menu_bar, static_enablement, FinderVerb};
use crate::scroll::{content_height, max_offset, scroll_layout, thumb_rect};
use crate::sheet::{sheet_base_button, sheet_layout};
use crate::tabs::{tabs_layout, SEGMENT_LABELS};
use crate::widgets::{widgets_layout, WidgetFocus, CHECK_LABELS, FOCUS_ORDER, RADIO_LABELS};
use aquadraw::drawlist::Role;
use aquadraw::runner::Rect;
use aquadraw::text::Style;
use aquadraw::tokens::ThemeTokens;
use std::collections::BTreeSet;

const TITLE_BAR: f64 = 22.0;

fn in_bounds(r: &Rect, w: f64, h: f64) -> bool {
    r.x >= 0.0 && r.y >= 0.0 && r.x + r.w <= w && r.y + r.h <= h
}

#[test]
fn widgets_layout_is_sane_and_in_bounds() {
    let (w, h) = (460.0, 360.0);
    let l = widgets_layout(w, h, TITLE_BAR);
    assert_eq!(l.checks.len(), CHECK_LABELS.len());
    assert_eq!(l.check_boxes.len(), CHECK_LABELS.len());
    assert_eq!(l.radios.len(), RADIO_LABELS.len());
    assert_eq!(l.radio_centers.len(), RADIO_LABELS.len());
    for r in l.checks.iter().chain(&l.check_boxes).chain(&l.radios) {
        assert!(in_bounds(r, w, h), "{r:?}");
    }
    for r in [l.slider_track, l.progress, l.popup, l.ok_button, l.cancel_button] {
        assert!(in_bounds(&r, w, h) && r.w > 0.0, "{r:?}");
    }
    for b in &l.check_boxes {
        assert!((b.w - 14.0).abs() < 0.01 && (b.h - 14.0).abs() < 0.01, "the standard 14 px squares");
    }
    assert!(l.check_boxes[0].y < l.check_boxes[1].y && l.check_boxes[1].y < l.check_boxes[2].y, "stacked top to bottom");
    assert!(l.cancel_button.x + l.cancel_button.w < l.ok_button.x + l.ok_button.w, "Cancel left of OK");
    assert!((l.cancel_button.y - l.ok_button.y).abs() < 0.01);
    assert!(l.ok_button.y > h / 2.0, "both pinned to the bottom band");
}

#[test]
fn widget_focus_order_covers_every_control() {
    assert_eq!(FOCUS_ORDER.len(), CHECK_LABELS.len() + 5);
    for (i, f) in FOCUS_ORDER.iter().take(CHECK_LABELS.len()).enumerate() {
        assert_eq!(*f, WidgetFocus::Check(i));
    }
    assert_eq!(FOCUS_ORDER[CHECK_LABELS.len()..], [WidgetFocus::Radio, WidgetFocus::Slider, WidgetFocus::Popup, WidgetFocus::Cancel, WidgetFocus::Ok]);
    // The default button last, so a fresh scene rings OK and Tab wraps to the first box.
    assert_eq!((FOCUS_ORDER[0], FOCUS_ORDER[FOCUS_ORDER.len() - 1]), (WidgetFocus::Check(0), WidgetFocus::Ok));
}

#[test]
fn the_tabs_scene_stays_in_bounds() {
    let (w, h) = (480.0, 380.0);
    let l = tabs_layout(w, h, TITLE_BAR);
    assert_eq!(l.segments.len(), SEGMENT_LABELS.len());
    assert!(in_bounds(&l.pane, w, h) && l.pane.h > 0.0);
    assert!(l.segments.iter().all(|s| in_bounds(s, w, h)));
}

#[test]
fn sheet_layout_in_bounds() {
    let w = 440.0;
    let (panel, cancel, ok) = sheet_layout(w, TITLE_BAR);
    assert!((panel.y - TITLE_BAR).abs() < 0.01, "the panel hangs from the title bar");
    assert!((panel.x + panel.w / 2.0 - w / 2.0).abs() <= 0.5, "centred");
    assert!(panel.x + panel.w <= w);
    for b in [cancel, ok] {
        assert!(b.x >= panel.x && b.x + b.w <= panel.x + panel.w && b.y + b.h <= panel.y + panel.h, "{b:?} inside {panel:?}");
    }
    assert!(cancel.x + cancel.w < ok.x + ok.w, "Cancel left of the default");
    assert!(sheet_base_button(w).y > panel.y + panel.h - 20.0, "the base button clears the extended panel");
}

#[test]
fn scroll_layout_and_thumb() {
    let (w, h) = (360.0, 420.0);
    let l = scroll_layout(w, h, TITLE_BAR);
    let vp = l.list.h;
    let max = max_offset(vp);
    assert!(max > 0.0, "the content overflows");
    assert!(l.up_arrow.y < l.down_arrow.y, "paired arrows, up above down");
    assert!((l.up_arrow.x - l.track.x).abs() < 0.01);
    assert!(l.down_arrow.y + l.down_arrow.h <= h);
    let top = thumb_rect(l.track, 0.0, vp, content_height()).expect("a thumb when content overflows");
    let bot = thumb_rect(l.track, max, vp, content_height()).expect("a thumb at the end");
    assert!(top.y >= l.track.y - 0.01 && top.y < bot.y);
    assert!(bot.y + bot.h <= l.track.y + l.track.h + 0.01);
    assert!((top.h - bot.h).abs() < 0.01, "the thumb's length is offset-independent");
    assert_eq!(thumb_rect(l.track, 0.0, content_height() + 10.0, content_height()), None, "a viewport taller than the content has no thumb");
}

// MARK: a drawn menu (Commands.swift)

#[test]
fn menu_rows_and_hit_test_agree_across_separators() {
    let t = ThemeTokens::default();
    let items = [AquaMenuItem::new("A"), AquaMenuItem::separator(), AquaMenuItem::new("B"), AquaMenuItem::new("C").disabled(), AquaMenuItem::new("D")];
    let rows = aqua_menu_rows(&items, &t);
    assert_eq!(rows[1].1, t.menu_separator_height);
    assert_eq!(rows[2].0, rows[1].0 + rows[1].1, "rows stack with no gap");
    let last = rows[rows.len() - 1];
    assert_eq!(aqua_menu_height(&items, &t), last.0 + last.1 + t.menu_pad_v);
    assert_eq!(aqua_menu_row_at(rows[2].0 + rows[2].1 / 2.0, &items, &t), Some(2), "B's row, not the row a uniform height would say");
    assert_eq!(aqua_menu_row_at(rows[1].0 + 1.0, &items, &t), None, "a separator is not a choice");
    assert_eq!(aqua_menu_row_at(rows[3].0 + 1.0, &items, &t), None, "a disabled row is not a choice");
}

#[test]
fn menu_arrow_keys_skip_what_cannot_be_chosen() {
    let items = [AquaMenuItem::new("A").disabled(), AquaMenuItem::new("B"), AquaMenuItem::separator(), AquaMenuItem::new("C").disabled(), AquaMenuItem::new("D")];
    assert_eq!(aqua_menu_step(None, 1, &items), Some(1), "Down starts at the first choosable");
    assert_eq!(aqua_menu_step(Some(1), 1, &items), Some(4));
    assert_eq!(aqua_menu_step(Some(4), 1, &items), Some(1), "and wraps");
    assert_eq!(aqua_menu_step(None, -1, &items), Some(4), "Up starts at the last");
    assert_eq!(aqua_menu_step(None, 1, &[AquaMenuItem::new("x").disabled()]), None, "nothing enabled, nothing highlighted");
}

#[test]
fn unimplemented_finder_verbs_are_drawn_disabled_not_hidden() {
    let items = aqua_menu_items(&finder_menu_bar().menus[0], &static_enablement);
    let row = |verb: &str| items.iter().find(|i| i.verb.as_deref() == Some(verb));
    assert_eq!(row("finder.about").map(|i| i.enabled), Some(false), "About Finder is in the menu, disabled");
    let empty = row("finder.empty-trash").expect("Empty Trash");
    assert_eq!((empty.key_text.as_str(), empty.enabled), ("⇧⌘⌫", true));
}

/// The key column is ⌘ ⇧ ⌫ and friends; without a face that has them they
/// draw as empty boxes, which no "was something drawn" test can see. CText
/// shapes a codepoint no face covers as glyph 0.
#[test]
fn the_loaded_fonts_can_draw_every_menu_glyph() {
    let mut runner = aquadraw::scene::runner(1).expect("no fonts");
    let glyphs: BTreeSet<char> = finder_menu_bar().commands().iter().flat_map(|c| c.all_keys()).flat_map(|k| k.display().chars().collect::<Vec<_>>()).filter(|c| !c.is_ascii()).collect();
    assert!(glyphs.contains(&'⌘') && glyphs.contains(&'⇧') && glyphs.contains(&'⌫'), "{glyphs:?}");
    for c in &glyphs {
        let g = runner.text.shape(&c.to_string(), 13, Style::Regular, Role::Interface);
        assert!(g.iter().all(|g| g.index != 0), "{c} would draw as a box");
    }
    let g = runner.text.shape("\u{0378}", 13, Style::Regular, Role::Interface);
    assert!(g.iter().any(|g| g.index == 0), "an unassigned codepoint is covered by nothing: the check can fail");
}

// MARK: one definition of a command (P10.1) and contextual menus (P10.8)

/// Every verb the Finder's switch handles is in the menus exactly once, and
/// the menus carry nothing the switch does not handle.
#[test]
fn finder_verbs_and_menus_agree() {
    let model = finder_menu_bar();
    assert!(model.duplicate_verbs().is_empty(), "{:?}", model.duplicate_verbs());
    let shown: BTreeSet<&str> = model.commands().iter().map(|c| c.verb.as_str()).collect();
    let handled: BTreeSet<&str> = FinderVerb::ALL.iter().map(|v| v.raw()).collect();
    assert_eq!(shown, handled);
}

#[test]
fn finder_context_menus_are_the_menu_bars_commands() {
    let model = finder_menu_bar();
    for verbs in [&context::ITEM[..], &context::BACKGROUND[..]] {
        let menu = context::menu(verbs, &model);
        assert_eq!(menu.commands().len(), verbs.iter().flatten().count(), "every verb in a contextual menu is in the model");
        for c in menu.commands() {
            assert_eq!(Some(c), model.command(&c.verb));
        }
    }
    assert_eq!(context::menu(&context::ITEM, &model).commands()[0].verb, "file.open", "Open first, as the Finder has it");
}

#[test]
fn the_desktops_menu_is_its_own_few_commands() {
    let verbs: Vec<String> = crate::wallpaper::desktop_context_menu().commands().iter().map(|c| c.verb.clone()).collect();
    assert_eq!(verbs, ["desktop.new-folder", "desktop.change-background"]);
}

/// Save and Save As…, Move to Trash and Empty Trash: what writes a person's
/// files, and so what an agent asks before doing (P18.11).
#[test]
fn writes_are_marked() {
    let te: Vec<String> = crate::textedit::textedit_menu_bar().commands().iter().filter(|c| c.writes).map(|c| c.verb.clone()).collect();
    assert_eq!(te, [crate::textedit::VERB_SAVE, crate::textedit::VERB_SAVE_AS]);
    let finder: BTreeSet<String> = finder_menu_bar().commands().iter().filter(|c| c.writes).map(|c| c.verb.clone()).collect();
    assert_eq!(finder, BTreeSet::from(["file.move-to-trash".to_owned(), "finder.empty-trash".to_owned()]));
}
