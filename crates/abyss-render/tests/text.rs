// SPDX-License-Identifier: BSD-2-Clause

//! `abyss-render` text tests — `Canvas::text` proven against a real font.

use std::path::Path;

use abyss_render::{Canvas, Color, CpuBackend, Font, GlyphCache, Point, Rect};

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

#[test]
fn text_leaves_ink() {
    let font = test_font();
    let mut cache = GlyphCache::new();
    let mut backend = CpuBackend::new(160, 48);
    {
        let mut canvas = Canvas::new(&mut backend);
        canvas.text(
            Point::new(8.0, 32.0),
            "Hello",
            &font,
            24.0,
            Color::BLACK,
            &mut cache,
        );
    }
    let pm = backend.into_pixmap();
    let inked = pm.data().iter().filter(|p| p.a > 0).count();
    assert!(
        inked > 50,
        "rendered text should leave ink, got {inked} pixels"
    );
    assert_eq!(
        pm.pixel(0, 0),
        Color::TRANSPARENT,
        "the corner before the text is clear"
    );
    assert!(!cache.is_empty(), "glyphs were cached");
}

#[test]
fn empty_text_draws_nothing() {
    let font = test_font();
    let mut cache = GlyphCache::new();
    let mut backend = CpuBackend::new(40, 40);
    {
        let mut canvas = Canvas::new(&mut backend);
        canvas.text(
            Point::new(4.0, 20.0),
            "",
            &font,
            16.0,
            Color::BLACK,
            &mut cache,
        );
    }
    assert!(backend.into_pixmap().data().iter().all(|p| p.a == 0));
}

#[test]
fn text_is_confined_by_the_clip() {
    let font = test_font();
    let mut cache = GlyphCache::new();
    let mut backend = CpuBackend::new(160, 48);
    {
        let mut canvas = Canvas::new(&mut backend);
        // a tiny clip in the corner; the text is drawn far from it
        canvas.clip_rect(Rect::new(0.0, 0.0, 4.0, 4.0));
        canvas.text(
            Point::new(40.0, 32.0),
            "Hello",
            &font,
            24.0,
            Color::BLACK,
            &mut cache,
        );
    }
    let pm = backend.into_pixmap();
    assert!(
        pm.data().iter().all(|p| p.a == 0),
        "text outside the clip leaves nothing"
    );
}

#[test]
fn the_cache_reuses_repeated_glyphs() {
    let font = test_font();
    let mut cache = GlyphCache::new();
    let mut backend = CpuBackend::new(220, 48);
    {
        let mut canvas = Canvas::new(&mut backend);
        canvas.text(
            Point::new(8.0, 32.0),
            "aaaaa",
            &font,
            24.0,
            Color::BLACK,
            &mut cache,
        );
    }
    assert_eq!(cache.len(), 1, "five 'a's are one cached glyph");
}
