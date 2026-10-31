//! The theme's cursors, as textures (CursorImages.swift, BACKLOG U.7).
//!
//! A cursor is a draw list (aquadraw's `cursor`); here it becomes pixels,
//! once per shape, per display scale, per theme: the frames' caching
//! policy. Nothing is rasterised on the frame path unless the shape, the
//! scale or the theme has just changed, and a scale-2 display gets a cursor
//! drawn at scale 2, not a 1x one stretched.

use aquadraw::cursor;
use aquadraw::runner::Runner;
use aquadraw::theme::Theme;
use abyss_sys::wlr::{Renderer, Texture};
use std::collections::HashMap;

/// DRM_FORMAT_ARGB8888: cairo's premultiplied ARGB32, as the frames are.
pub const ARGB8888: u32 = 0x3432_5241;

/// One shape at one scale, on the GPU (or pixman's idea of it).
pub struct CursorTexture {
    pub texture: Texture,
    /// Where the pointer's position is in the picture, in points.
    pub hot_x: f64,
    pub hot_y: f64,
    theme_generation: u64,
}

impl Drop for CursorTexture {
    fn drop(&mut self) {
        self.texture.destroy()
    }
}

#[derive(Default)]
pub struct CursorImages {
    cache: HashMap<String, CursorTexture>,
    /// How many cursors have been drawn: once per shape and scale, which a
    /// test can hold undertow to.
    pub rasterisations: u64,
}

impl CursorImages {
    /// The shape `name` (after the theme's fallbacks) at `scale`.
    pub fn image(&mut self, name: &str, scale: f64, renderer: Renderer, runner: &mut Runner, theme: &Theme) -> Option<&CursorTexture> {
        let shape = cursor::resolve(theme, name);
        let key = format!("{shape}@{scale:?}");
        if self.cache.get(&key).is_some_and(|c| c.theme_generation == theme.generation) {
            return self.cache.get(&key);
        }
        // The one rasteriser: the XCursor theme a toolkit loads (U.7b) is
        // these same pixels.
        let im = cursor::rasterise(runner, theme, &shape, scale)?;
        let bytes: Vec<u8> = im.pixels.iter().flat_map(|p| p.to_ne_bytes()).collect();
        let n = im.size as u32;
        let texture = renderer.texture_from_pixels(ARGB8888, n * 4, n, n, &bytes)?;
        let (hot_x, hot_y) = cursor::hotspot(runner, theme, &shape);
        self.rasterisations += 1;
        self.cache.insert(key.clone(), CursorTexture { texture, hot_x, hot_y, theme_generation: theme.generation });
        self.cache.get(&key)
    }

    pub fn release(&mut self) {
        self.cache.clear()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::backend::WlrootsSession;

    /// Once per shape and scale, and again only for a new theme; a name the
    /// theme does not draw shares its fallback's texture.
    #[test]
    fn each_shape_is_drawn_once_per_scale_and_theme() {
        let s = WlrootsSession::headless(1, 64, 48, 60_000, false).unwrap();
        let Some(mut runner) = aquadraw::scene::runner(1) else { return };
        let mut theme = Theme::default();
        let mut c = CursorImages::default();
        let first = c.image("text", 1.0, s.renderer(), &mut runner, &theme).map(|t| (t.texture, t.hot_x, t.hot_y)).unwrap();
        assert_eq!(c.image("text", 1.0, s.renderer(), &mut runner, &theme).unwrap().texture, first.0);
        assert_eq!(c.image("vertical-text", 1.0, s.renderer(), &mut runner, &theme).unwrap().texture, first.0, "its fallback's");
        assert_eq!(c.rasterisations, 1);
        c.image("text", 2.0, s.renderer(), &mut runner, &theme).unwrap();
        assert_eq!(c.rasterisations, 2, "a scale-2 display gets its own");
        let tokens = theme.tokens.clone();
        theme.use_theme(tokens, None, Default::default(), Some(&mut runner));
        c.image("text", 1.0, s.renderer(), &mut runner, &theme).unwrap();
        assert_eq!(c.rasterisations, 3, "a new theme draws again");
        assert_eq!((first.1, first.2), cursor::hotspot(&mut runner, &theme, "text"));
        c.release();
    }
}
