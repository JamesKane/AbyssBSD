//! `abyss-toolkit` tests — the arena, layout, widgets, input, and damage,
//! proven end to end (`docs/design/toolkit.md` §12).

use std::path::Path;

use abyss_toolkit::{
    Button, Canvas, Color, CpuBackend, Font, GlyphCache, InputEvent, Label, Linear, MeasureCtx,
    PaintCtx, Pixmap, Size, Theme, UiEvent, ViewTree, Widget,
};

const FONT_CANDIDATES: &[&str] = &[
    "/System/Library/Fonts/Monaco.ttf",
    "/System/Library/Fonts/Geneva.ttf",
    "/usr/local/share/fonts/dejavu/DejaVuSans.ttf",
    "/usr/share/fonts/dejavu/DejaVuSans.ttf",
];

fn test_font() -> Font {
    for candidate in FONT_CANDIDATES {
        if Path::new(candidate).exists() {
            return Font::open(Path::new(candidate)).expect("open the test font");
        }
    }
    panic!("no test font found — add a path to FONT_CANDIDATES for this platform");
}

fn near(a: Color, b: Color, tol: u8) -> bool {
    a.r.abs_diff(b.r) <= tol
        && a.g.abs_diff(b.g) <= tol
        && a.b.abs_diff(b.b) <= tol
        && a.a.abs_diff(b.a) <= tol
}

/// Lay out and paint `tree` onto a fresh `w`×`h` target.
fn render(tree: &mut ViewTree, font: &Font, theme: &Theme, w: u32, h: u32) -> Pixmap {
    tree.layout(Size::new(w as f32, h as f32), &MeasureCtx { font, theme });
    let mut cache = GlyphCache::new();
    let mut backend = CpuBackend::new(w, h);
    {
        let mut canvas = Canvas::new(&mut backend);
        tree.paint(
            &mut canvas,
            &mut PaintCtx {
                theme,
                font,
                cache: &mut cache,
            },
        );
    }
    backend.into_pixmap()
}

#[test]
fn generational_handles_resolve_safely() {
    let mut tree = ViewTree::new(Linear::column());
    let button = tree.add_child(tree.root(), Button::new("x")).unwrap();
    assert!(tree.widget::<Button>(button).is_some());

    tree.remove(button);
    assert!(
        tree.widget::<Button>(button).is_none(),
        "a removed view is None"
    );
    assert!(tree.bounds(button).is_none());

    // the slot is reused, but the stale handle still does not resolve
    let fresh = tree.add_child(tree.root(), Button::new("y")).unwrap();
    assert_ne!(fresh, button);
    assert!(tree.widget::<Button>(button).is_none());
    assert!(tree.widget::<Button>(fresh).is_some());
}

#[test]
fn a_column_stacks_its_children() {
    let font = test_font();
    let theme = Theme::default();
    let mut tree = ViewTree::new(Linear::column());
    let a = tree.add_child(tree.root(), Label::new("one")).unwrap();
    let b = tree.add_child(tree.root(), Label::new("two")).unwrap();
    let c = tree.add_child(tree.root(), Label::new("three")).unwrap();

    tree.layout(
        Size::new(300.0, 200.0),
        &MeasureCtx {
            font: &font,
            theme: &theme,
        },
    );
    let (ra, rb, rc) = (
        tree.bounds(a).unwrap(),
        tree.bounds(b).unwrap(),
        tree.bounds(c).unwrap(),
    );
    assert_eq!(ra.y, 0.0, "the first child is at the top");
    assert!(ra.h > 0.0);
    assert!(
        (rb.y - (ra.y + ra.h)).abs() < 0.01,
        "the second is below the first"
    );
    assert!(
        (rc.y - (rb.y + rb.h)).abs() < 0.01,
        "the third is below the second"
    );
}

#[test]
fn a_label_measures_to_its_text_width() {
    let font = test_font();
    let theme = Theme::default();
    let ctx = MeasureCtx {
        font: &font,
        theme: &theme,
    };
    let short = Label::new("i").measure(&[], &ctx);
    let long = Label::new("a much longer label").measure(&[], &ctx);
    assert!(long.w > short.w, "more text measures wider");
    assert!(
        (long.h - short.h).abs() < 0.01,
        "one line of text, the same height"
    );
    assert!(short.h > 0.0);
}

#[test]
fn the_toolkit_paints_ink() {
    let font = test_font();
    let theme = Theme::default();
    let mut tree = ViewTree::new(Linear::column());
    tree.add_child(tree.root(), Label::new("Hello")).unwrap();
    tree.add_child(tree.root(), Button::new("OK")).unwrap();

    let pm = render(&mut tree, &font, &theme, 200, 80);
    let inked = pm.data().iter().filter(|p| p.a > 0).count();
    assert!(
        inked > 100,
        "a label and a button should paint, got {inked} pixels"
    );
}

#[test]
fn clicking_a_button_emits_clicked() {
    let font = test_font();
    let theme = Theme::default();
    let mut tree = ViewTree::new(Linear::column());
    let button = tree.add_child(tree.root(), Button::new("Press")).unwrap();
    tree.layout(
        Size::new(200.0, 80.0),
        &MeasureCtx {
            font: &font,
            theme: &theme,
        },
    );

    let b = tree.bounds(button).unwrap();
    let (cx, cy) = (b.x + b.w / 2.0, b.y + b.h / 2.0);
    assert!(
        tree.dispatch_input(&InputEvent::PointerDown { x: cx, y: cy })
            .is_empty(),
        "a press alone emits nothing"
    );
    let events = tree.dispatch_input(&InputEvent::PointerUp { x: cx, y: cy });
    assert_eq!(events, vec![UiEvent::Clicked(button)]);
}

#[test]
fn clicking_off_a_button_emits_nothing() {
    let font = test_font();
    let theme = Theme::default();
    let mut tree = ViewTree::new(Linear::column());
    let button = tree.add_child(tree.root(), Button::new("Press")).unwrap();
    tree.layout(
        Size::new(200.0, 200.0),
        &MeasureCtx {
            font: &font,
            theme: &theme,
        },
    );

    // a point inside the column but well below the button
    let y = tree.bounds(button).unwrap().bottom() + 50.0;
    assert!(
        tree.dispatch_input(&InputEvent::PointerDown { x: 50.0, y })
            .is_empty()
    );
    assert!(
        tree.dispatch_input(&InputEvent::PointerUp { x: 50.0, y })
            .is_empty()
    );
}

#[test]
fn a_button_press_marks_damage() {
    let font = test_font();
    let theme = Theme::default();
    let mut tree = ViewTree::new(Linear::column());
    let button = tree.add_child(tree.root(), Button::new("Press")).unwrap();

    let _ = render(&mut tree, &font, &theme, 200, 80);
    assert!(tree.damage().is_none(), "painting clears all damage");

    let b = tree.bounds(button).unwrap();
    tree.dispatch_input(&InputEvent::PointerDown {
        x: b.x + b.w / 2.0,
        y: b.y + b.h / 2.0,
    });
    assert_eq!(
        tree.damage(),
        Some(b),
        "the pressed button is the damaged region"
    );
}

#[test]
fn typed_widget_access() {
    let mut tree = ViewTree::new(Linear::column());
    let label = tree.add_child(tree.root(), Label::new("before")).unwrap();
    assert_eq!(tree.widget::<Label>(label).unwrap().text(), "before");
    assert!(
        tree.widget::<Button>(label).is_none(),
        "the wrong type resolves to None"
    );

    tree.widget_mut::<Label>(label).unwrap().set_text("after");
    assert_eq!(tree.widget::<Label>(label).unwrap().text(), "after");
}

#[test]
fn a_button_changes_color_when_pressed() {
    let font = test_font();
    let theme = Theme::default();
    let mut tree = ViewTree::new(Linear::column());
    let button = tree.add_child(tree.root(), Button::new("OK")).unwrap();
    tree.layout(
        Size::new(200.0, 60.0),
        &MeasureCtx {
            font: &font,
            theme: &theme,
        },
    );

    let b = tree.bounds(button).unwrap();
    // a face pixel — well inside the button, clear of the text at the left
    let px = (b.right() - 8.0) as u32;
    let py = (b.y + b.h / 2.0) as u32;

    let before = render(&mut tree, &font, &theme, 200, 60).pixel(px, py);
    tree.dispatch_input(&InputEvent::PointerDown {
        x: b.x + b.w / 2.0,
        y: b.y + b.h / 2.0,
    });
    let after = render(&mut tree, &font, &theme, 200, 60).pixel(px, py);

    assert_ne!(before, after, "the button face changes on press");
    assert!(
        near(after, theme.surface_active, 4),
        "the pressed face is the active color"
    );
}

#[test]
fn needs_layout_tracks_changes() {
    let font = test_font();
    let theme = Theme::default();
    let mut tree = ViewTree::new(Linear::column());
    assert!(tree.needs_layout(), "a fresh tree needs layout");
    tree.layout(
        Size::new(100.0, 100.0),
        &MeasureCtx {
            font: &font,
            theme: &theme,
        },
    );
    assert!(!tree.needs_layout(), "layout clears the flag");
    tree.add_child(tree.root(), Label::new("new")).unwrap();
    assert!(tree.needs_layout(), "adding a view dirties layout again");
}
