// SPDX-License-Identifier: BSD-2-Clause

//! AbyssBSD font crate — text shaping and glyph rasterization.
//!
//! Binds the FreeBSD-port font stack — freetype (rasterization) and
//! harfbuzz (shaping) — through a small C shim (`c/font_shim.c`), so
//! freetype's struct layouts never cross into Rust: the C compiler owns
//! them. `fontconfig` — font *selection* by name — is a later increment;
//! this crate loads a font by file path.
//!
//! `unsafe` is confined to FFI calls into the shim. The workspace
//! `unsafe_code` lint is deliberately opted out of here, for exactly that
//! — the contained, audited cost of binding a C library
//! (`docs/design/toolkit.md` §3.3).

#![allow(unsafe_code)]

mod ffi;

use std::ffi::CString;
use std::fmt;
use std::os::unix::ffi::OsStrExt;
use std::path::Path;

pub use ffi::{FontMetrics, ShapedGlyph};

/// A font could not be opened.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FontError(String);

impl fmt::Display for FontError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for FontError {}

/// A rasterized glyph — an 8-bit coverage mask and its placement.
#[derive(Debug, Clone)]
pub struct GlyphMask {
    /// Mask width in pixels.
    pub width: u32,
    /// Mask height in pixels.
    pub height: u32,
    /// Pixels from the pen to the mask's left edge.
    pub left: i32,
    /// Pixels from the baseline up to the mask's top edge.
    pub top: i32,
    /// The glyph's own advance width, in pixels.
    pub advance: f32,
    /// `width * height` coverage bytes, row-major.
    pub coverage: Vec<u8>,
}

/// A loaded font face — its own freetype library, freetype face, and
/// harfbuzz font.
///
/// `Font` holds a raw handle to C state, so it is neither `Send` nor
/// `Sync`: a font is used on the thread (the looper) that opened it.
/// Distinct fonts share no state, so opening and using fonts on different
/// threads is race-free.
pub struct Font {
    handle: *mut ffi::AbyssFont,
}

impl Font {
    /// Open the font face at `path` (face 0 of the file).
    ///
    /// # Errors
    ///
    /// Fails if the path cannot be opened as a font.
    pub fn open(path: &Path) -> Result<Font, FontError> {
        let c_path = CString::new(path.as_os_str().as_bytes())
            .map_err(|_| FontError("font path contains a NUL byte".to_owned()))?;
        // SAFETY: `c_path` is a valid NUL-terminated string, live for the call.
        let handle = unsafe { ffi::abyss_font_open(c_path.as_ptr(), 0) };
        if handle.is_null() {
            return Err(FontError(format!(
                "could not open font: {}",
                path.display()
            )));
        }
        Ok(Font { handle })
    }

    /// Vertical metrics at `size_px`.
    #[must_use]
    pub fn metrics(&self, size_px: f32) -> FontMetrics {
        // SAFETY: `self.handle` is a live handle from `abyss_font_open`.
        unsafe { ffi::abyss_font_metrics(self.handle, size_px) }
    }

    /// Shape `text` at `size_px` into positioned glyphs.
    #[must_use]
    pub fn shape(&self, text: &str, size_px: f32) -> Vec<ShapedGlyph> {
        let mut glyphs = vec![ShapedGlyph::default(); text.len().max(8)];
        let count = self.shape_into(text, size_px, &mut glyphs);
        if count > glyphs.len() {
            // The first buffer was too small — retry sized to the exact count.
            glyphs = vec![ShapedGlyph::default(); count];
            let count = self.shape_into(text, size_px, &mut glyphs);
            glyphs.truncate(count);
        } else {
            glyphs.truncate(count);
        }
        glyphs
    }

    fn shape_into(&self, text: &str, size_px: f32, out: &mut [ShapedGlyph]) -> usize {
        // SAFETY: `self.handle` is live; `text` is a valid `len`-byte run;
        // `out` has `out.len()` writable `ShapedGlyph` slots.
        unsafe {
            ffi::abyss_font_shape(
                self.handle,
                text.as_ptr().cast(),
                text.len(),
                size_px,
                out.as_mut_ptr(),
                out.len(),
            )
        }
    }

    /// The advance width of `text` at `size_px`, in pixels.
    #[must_use]
    pub fn measure(&self, text: &str, size_px: f32) -> f32 {
        self.shape(text, size_px).iter().map(|g| g.x_advance).sum()
    }

    /// Rasterize one glyph (by glyph index, as returned by [`shape`]) to an
    /// 8-bit coverage mask.
    ///
    /// Returns `None` if the glyph cannot be loaded. A blank glyph — a
    /// space — yields an empty mask with a non-zero `advance`.
    ///
    /// [`shape`]: Font::shape
    #[must_use]
    pub fn rasterize(&self, glyph: u32, size_px: f32) -> Option<GlyphMask> {
        let mut info = ffi::GlyphInfo::default();
        // SAFETY: `self.handle` is live; `info` is a valid out-pointer.
        let ok = unsafe { ffi::abyss_font_rasterize(self.handle, glyph, size_px, &raw mut info) };
        if ok == 0 {
            return None;
        }
        let width = info.width.max(0) as u32;
        let height = info.rows.max(0) as u32;
        let len = width as usize * height as usize;
        let mut coverage = vec![0_u8; len];
        if len > 0 {
            // SAFETY: `self.handle` is live; `coverage` has exactly `len`
            // bytes, matching the glyph the shim still holds in its slot.
            unsafe { ffi::abyss_font_copy_coverage(self.handle, coverage.as_mut_ptr(), len) };
        }
        Some(GlyphMask {
            width,
            height,
            left: info.left,
            top: info.top,
            advance: info.advance,
            coverage,
        })
    }
}

impl Drop for Font {
    fn drop(&mut self) {
        // SAFETY: `self.handle` came from `abyss_font_open` and is closed
        // exactly once, here.
        unsafe { ffi::abyss_font_close(self.handle) };
    }
}
