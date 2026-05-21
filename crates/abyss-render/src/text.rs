//! Text rendering — a per-font glyph cache (`docs/design/toolkit.md` §3.3).

use std::collections::HashMap;

use abyss_font::Font;

/// A rasterized glyph held in the cache.
pub(crate) struct CachedGlyph {
    pub width: u32,
    pub height: u32,
    pub left: i32,
    pub top: i32,
    pub coverage: Vec<u8>,
}

/// A per-font cache of rasterized glyph masks, keyed by pixel size and
/// glyph index.
///
/// One `GlyphCache` pairs with one [`Font`]. For the CPU backend the cache
/// *is* the glyph atlas; the GLES backend will later pack the masks into
/// an atlas texture behind the same interface.
#[derive(Default)]
pub struct GlyphCache {
    glyphs: HashMap<(u32, u32), CachedGlyph>,
}

impl GlyphCache {
    /// An empty cache.
    #[must_use]
    pub fn new() -> GlyphCache {
        GlyphCache::default()
    }

    /// How many distinct glyphs are cached.
    #[must_use]
    pub fn len(&self) -> usize {
        self.glyphs.len()
    }

    /// Whether the cache holds no glyphs.
    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.glyphs.is_empty()
    }

    /// The cached mask for `glyph` at `size_px`, rasterizing it through
    /// `font` on first use. A glyph that fails to rasterize is cached as
    /// empty, so it is attempted only once.
    pub(crate) fn entry(&mut self, font: &Font, glyph: u32, size_px: f32) -> &CachedGlyph {
        self.glyphs
            .entry((size_px.to_bits(), glyph))
            .or_insert_with(|| match font.rasterize(glyph, size_px) {
                Some(mask) => CachedGlyph {
                    width: mask.width,
                    height: mask.height,
                    left: mask.left,
                    top: mask.top,
                    coverage: mask.coverage,
                },
                None => CachedGlyph {
                    width: 0,
                    height: 0,
                    left: 0,
                    top: 0,
                    coverage: Vec::new(),
                },
            })
    }
}
