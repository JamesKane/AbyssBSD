// SPDX-License-Identifier: BSD-2-Clause

//! Raw FFI to the C font shim (`c/font_shim.c`).
//!
//! The shim's structs are AbyssBSD-defined and flat — only primitives — so
//! these `#[repr(C)]` declarations match them exactly. No freetype or
//! harfbuzz struct layout is transcribed here; that stays in C.

use std::ffi::{c_char, c_int, c_uint, c_void};

/// An opaque shim `AbyssFont`.
pub(crate) type AbyssFont = c_void;

/// One shaped glyph — mirrors the shim's `AbyssShapedGlyph`.
#[repr(C)]
#[derive(Debug, Clone, Copy, Default)]
pub struct ShapedGlyph {
    /// The glyph index (into the font), not a Unicode code point.
    pub glyph: u32,
    /// How far the pen advances after this glyph, in pixels.
    pub x_advance: f32,
    /// Horizontal draw offset from the pen, in pixels.
    pub x_offset: f32,
    /// Vertical draw offset from the baseline, in pixels.
    pub y_offset: f32,
}

/// Vertical font metrics — mirrors the shim's `AbyssFontMetrics`.
#[repr(C)]
#[derive(Debug, Clone, Copy, Default)]
pub struct FontMetrics {
    /// Pixels from the baseline up to the typical glyph top.
    pub ascent: f32,
    /// Pixels from the baseline down to the typical glyph bottom.
    pub descent: f32,
    /// Recommended extra spacing between lines, in pixels.
    pub line_gap: f32,
    /// Baseline-to-baseline distance, in pixels.
    pub line_height: f32,
}

/// A rasterized glyph's placement — mirrors the shim's `AbyssGlyphInfo`.
#[repr(C)]
#[derive(Debug, Clone, Copy, Default)]
pub(crate) struct GlyphInfo {
    pub width: c_int,
    pub rows: c_int,
    pub left: c_int,
    pub top: c_int,
    pub advance: f32,
}

unsafe extern "C" {
    pub(crate) fn abyss_font_open(path: *const c_char, index: c_uint) -> *mut AbyssFont;
    pub(crate) fn abyss_font_close(font: *mut AbyssFont);
    pub(crate) fn abyss_font_metrics(font: *mut AbyssFont, size_px: f32) -> FontMetrics;
    pub(crate) fn abyss_font_shape(
        font: *mut AbyssFont,
        text: *const c_char,
        len: usize,
        size_px: f32,
        out: *mut ShapedGlyph,
        cap: usize,
    ) -> usize;
    pub(crate) fn abyss_font_rasterize(
        font: *mut AbyssFont,
        glyph: c_uint,
        size_px: f32,
        info: *mut GlyphInfo,
    ) -> c_int;
    pub(crate) fn abyss_font_copy_coverage(font: *mut AbyssFont, out: *mut u8, out_len: usize);
}
