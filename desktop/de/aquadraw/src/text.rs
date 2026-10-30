//! Text.swift and Draw's text calls (Drawing.swift), over CText: shaped
//! HarfBuzz runs painted with cairo-ft. The Swift statics (render scale,
//! shape cache, face cache) live in `Text`, owned by the renderer.
//!
//! Not ported: the toy-text fallback (no font at all), and a theme's role
//! case/tracking (`[fonts]` upper/tracking), which the aqua theme sets for
//! no role.

use crate::color::Color;
use crate::drawlist::Role;
use abyss_sys::{self as ffi, AtGlyph, Context, FontFace, Glyph};
use std::collections::HashMap;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Style {
    Regular = 0,
    Bold = 1,
}

pub struct Metrics {
    pub ascent: f64,
    pub descent: f64,
}

pub struct Text {
    pub render_scale: i32,
    shape_cache: HashMap<(String, i32, i32, i32), Vec<AtGlyph>>,
    face_cache: HashMap<i32, FontFace>,
}

const SHAPE_CACHE_CAP: usize = 1024;

impl Text {
    /// None when no font could be opened (Text.available false).
    pub fn new(render_scale: i32) -> Option<Text> {
        if !ffi::font_init() {
            return None;
        }
        Some(Text { render_scale, shape_cache: HashMap::new(), face_cache: HashMap::new() })
    }

    /// Text.useRoles, for one theme's `[fonts]`: a mono role not found falls
    /// back to fontconfig's `monospace`.
    pub fn use_roles(&mut self, families: &[(Role, &str)]) {
        for &(r, f) in families {
            if !ffi::font_set_role(r as i32, f) && r == Role::Mono {
                ffi::font_set_role(r as i32, "monospace");
            }
            self.shape_cache.clear();
        }
    }

    pub fn px(&self, size: f64) -> i32 {
        (size * self.render_scale as f64).round() as i32
    }

    pub fn shape(&mut self, s: &str, px: i32, style: Style, role: Role) -> Vec<AtGlyph> {
        if s.is_empty() || px <= 0 {
            return Vec::new();
        }
        let key = (s.to_string(), px, style as i32, role as i32);
        if let Some(g) = self.shape_cache.get(&key) {
            return g.clone();
        }
        let glyphs = ffi::font_shape_role(s, px, style as i32, role as i32).unwrap_or_default();
        if self.shape_cache.len() >= SHAPE_CACHE_CAP {
            self.shape_cache.clear();
        }
        self.shape_cache.insert(key, glyphs.clone());
        glyphs
    }

    pub fn width(glyphs: &[AtGlyph]) -> f64 {
        glyphs.iter().fold(0.0, |acc, g| acc + g.x_advance)
    }

    pub fn metrics(px: i32, role: Role) -> Metrics {
        Metrics { ascent: ffi::font_ascent_role(px, role as i32), descent: ffi::font_descent_role(px, role as i32) }
    }

    fn cairo_face(&mut self, idx: i32) -> Option<FontFace> {
        if let Some(f) = self.face_cache.get(&idx) {
            return Some(*f);
        }
        let f = FontFace::for_ctext_face(idx)?;
        self.face_cache.insert(idx, f);
        Some(f)
    }

    /// Text.drawShaped: consecutive glyphs from one face batched.
    pub fn draw_shaped(&mut self, cr: &Context, glyphs: &[AtGlyph], x: f64, baseline_y: f64, px: i32) {
        let s = self.render_scale as f64;
        let (mut pen_x, mut pen_y, mut i) = (x, baseline_y, 0);
        while i < glyphs.len() {
            let face = glyphs[i].face;
            let mut batch: Vec<Glyph> = Vec::new();
            while i < glyphs.len() && glyphs[i].face == face {
                let g = glyphs[i];
                batch.push(Glyph { index: g.index, x: pen_x + g.x_offset / s, y: pen_y - g.y_offset / s });
                pen_x += g.x_advance / s;
                pen_y -= g.y_advance / s;
                i += 1;
            }
            let Some(cf) = self.cairo_face(face) else { continue };
            cr.set_font_face(cf);
            cr.set_font_size(px as f64 / s);
            cr.show_glyphs(&batch);
        }
    }

    /// Draw.text(centerX:centerY:).
    #[allow(clippy::too_many_arguments)]
    pub fn draw_centered(&mut self, cr: &Context, s: &str, center_x: f64, center_y: f64, color: Color, size: f64, style: Style, role: Role) {
        let px = self.px(size);
        let glyphs = self.shape(s, px, style, role);
        let m = Text::metrics(px, role);
        let sc = self.render_scale as f64;
        let w = Text::width(&glyphs) / sc;
        let ascent = m.ascent / sc;
        let descent = m.descent / sc;
        cr.set_source_rgba(color.r, color.g, color.b, color.a);
        self.draw_shaped(cr, &glyphs, center_x - w / 2.0, center_y + (ascent - descent) / 2.0, px);
    }

    /// Draw.textLeft(x:baselineY:).
    #[allow(clippy::too_many_arguments)]
    pub fn draw_left(&mut self, cr: &Context, s: &str, x: f64, baseline_y: f64, color: Color, size: f64, style: Style, role: Role) {
        let px = self.px(size);
        cr.set_source_rgba(color.r, color.g, color.b, color.a);
        let glyphs = self.shape(s, px, style, role);
        self.draw_shaped(cr, &glyphs, x, baseline_y, px);
    }

    /// Draw.textWidth.
    pub fn text_width(&mut self, s: &str, size: f64, style: Style, role: Role) -> f64 {
        let px = self.px(size);
        Text::width(&self.shape(s, px, style, role)) / self.render_scale as f64
    }
}
