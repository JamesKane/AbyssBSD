//! `abyss-font` tests — open a real system font and exercise metrics,
//! shaping, and rasterization.

use std::path::Path;

use abyss_font::Font;

/// Candidate font paths across the development platforms.
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
fn metrics_are_sane() {
    let font = test_font();
    let m = font.metrics(16.0);
    assert!(m.ascent > 0.0, "ascent should be positive");
    assert!(m.descent > 0.0, "descent should be positive");
    assert!(
        m.line_height >= m.ascent + m.descent,
        "line height covers ascent + descent"
    );
}

#[test]
fn metrics_scale_with_size() {
    let font = test_font();
    let small = font.metrics(16.0);
    let large = font.metrics(32.0);
    assert!(large.ascent > small.ascent * 1.5, "ascent grows with size");
}

#[test]
fn shaping_produces_one_glyph_per_letter() {
    let font = test_font();
    let glyphs = font.shape("Hi", 16.0);
    assert_eq!(glyphs.len(), 2);
    assert!(glyphs.iter().all(|g| g.glyph != 0), "no .notdef glyphs");
    assert!(glyphs[0].x_advance > 0.0, "letters advance the pen");
}

#[test]
fn shaping_an_empty_string_yields_nothing() {
    let font = test_font();
    assert!(font.shape("", 16.0).is_empty());
}

#[test]
fn measure_grows_with_text_length() {
    let font = test_font();
    let one = font.measure("x", 16.0);
    let three = font.measure("xxx", 16.0);
    assert!(one > 0.0);
    assert!(
        three > one * 2.5 && three < one * 3.5,
        "three letters ~= 3x one, got {one} and {three}"
    );
}

#[test]
fn rasterizing_a_glyph_produces_ink() {
    let font = test_font();
    let glyphs = font.shape("H", 32.0);
    let mask = font
        .rasterize(glyphs[0].glyph, 32.0)
        .expect("rasterize 'H'");
    assert!(mask.width > 0 && mask.height > 0, "'H' has a visible mask");
    assert_eq!(
        mask.coverage.len(),
        mask.width as usize * mask.height as usize
    );
    assert!(mask.coverage.iter().any(|&c| c > 0), "the mask has ink");
    assert!(mask.advance > 0.0);
}
