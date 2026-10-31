//! abyss-sys — every `unsafe` in ADE's Rust (RUST.md §6.4): cairo, the CText
//! shim (de/ctext) and the CDraw shim (de/cdraw), declared by hand and
//! wrapped in owning handles. Nothing outside a `-sys` crate touches a raw
//! pointer. More shims join as their callers are ported.

#![allow(non_camel_case_types)]

use libc::{c_char, c_double, c_int, c_uint, c_ulong, c_void};
use std::ffi::CString;

pub mod jail;
pub mod pam;
pub mod platform;
pub mod sandbox;
pub mod poolwatch;
pub mod proc;
pub mod spawn;
#[cfg(feature = "tls")]
pub mod tls;
pub mod users;
pub mod vents;
pub mod wl;

// MARK: raw declarations

#[repr(C)]
pub struct cairo_t {
    _p: [u8; 0],
}
#[repr(C)]
pub struct cairo_surface_t {
    _p: [u8; 0],
}
#[repr(C)]
pub struct cairo_pattern_t {
    _p: [u8; 0],
}
#[repr(C)]
pub struct cairo_font_face_t {
    _p: [u8; 0],
}

/// cairo_matrix_t: plain data, used by value.
#[repr(C)]
#[derive(Clone, Copy, Default, Debug)]
pub struct Matrix {
    pub xx: f64,
    pub yx: f64,
    pub xy: f64,
    pub yy: f64,
    pub x0: f64,
    pub y0: f64,
}

/// cairo_glyph_t.
#[repr(C)]
#[derive(Clone, Copy, Default, Debug)]
pub struct Glyph {
    pub index: c_ulong,
    pub x: f64,
    pub y: f64,
}

/// ctext.h `at_glyph`.
#[repr(C)]
#[derive(Clone, Copy, Default, Debug, PartialEq)]
pub struct AtGlyph {
    pub index: c_ulong,
    pub face: c_int,
    pub x_advance: f64,
    pub y_advance: f64,
    pub x_offset: f64,
    pub y_offset: f64,
    pub cluster: c_uint,
}

pub const FORMAT_ARGB32: c_int = 0;
pub const FORMAT_A8: c_int = 2;
const EXTEND_REPEAT: c_int = 1;
pub const LINE_CAP_BUTT: c_int = 0;
pub const LINE_CAP_ROUND: c_int = 1;
pub const LINE_JOIN_MITER: c_int = 0;
pub const LINE_JOIN_ROUND: c_int = 1;

unsafe extern "C" {
    fn cairo_image_surface_create(format: c_int, w: c_int, h: c_int) -> *mut cairo_surface_t;
    fn cairo_image_surface_get_data(s: *mut cairo_surface_t) -> *mut u8;
    fn cairo_image_surface_get_stride(s: *mut cairo_surface_t) -> c_int;
    fn cairo_surface_flush(s: *mut cairo_surface_t);
    fn cairo_surface_mark_dirty(s: *mut cairo_surface_t);
    fn cairo_surface_destroy(s: *mut cairo_surface_t);
    fn cairo_surface_write_to_png(s: *mut cairo_surface_t, path: *const c_char) -> c_int;

    fn cairo_create(s: *mut cairo_surface_t) -> *mut cairo_t;
    fn cairo_destroy(cr: *mut cairo_t);
    fn cairo_save(cr: *mut cairo_t);
    fn cairo_restore(cr: *mut cairo_t);
    fn cairo_translate(cr: *mut cairo_t, x: c_double, y: c_double);
    fn cairo_scale(cr: *mut cairo_t, x: c_double, y: c_double);
    fn cairo_rotate(cr: *mut cairo_t, a: c_double);
    fn cairo_set_source_rgb(cr: *mut cairo_t, r: c_double, g: c_double, b: c_double);
    fn cairo_set_source_rgba(cr: *mut cairo_t, r: c_double, g: c_double, b: c_double, a: c_double);
    fn cairo_set_source(cr: *mut cairo_t, p: *mut cairo_pattern_t);
    fn cairo_paint(cr: *mut cairo_t);
    fn cairo_fill(cr: *mut cairo_t);
    fn cairo_stroke(cr: *mut cairo_t);
    fn cairo_clip(cr: *mut cairo_t);
    fn cairo_mask(cr: *mut cairo_t, p: *mut cairo_pattern_t);
    fn cairo_mask_surface(cr: *mut cairo_t, s: *mut cairo_surface_t, x: c_double, y: c_double);
    fn cairo_new_path(cr: *mut cairo_t);
    fn cairo_new_sub_path(cr: *mut cairo_t);
    fn cairo_close_path(cr: *mut cairo_t);
    fn cairo_move_to(cr: *mut cairo_t, x: c_double, y: c_double);
    fn cairo_line_to(cr: *mut cairo_t, x: c_double, y: c_double);
    fn cairo_curve_to(cr: *mut cairo_t, x1: c_double, y1: c_double, x2: c_double, y2: c_double, x3: c_double, y3: c_double);
    fn cairo_arc(cr: *mut cairo_t, xc: c_double, yc: c_double, r: c_double, a1: c_double, a2: c_double);
    fn cairo_rectangle(cr: *mut cairo_t, x: c_double, y: c_double, w: c_double, h: c_double);
    fn cairo_set_line_width(cr: *mut cairo_t, w: c_double);
    fn cairo_set_line_cap(cr: *mut cairo_t, c: c_int);
    fn cairo_set_line_join(cr: *mut cairo_t, j: c_int);
    fn cairo_set_dash(cr: *mut cairo_t, d: *const c_double, n: c_int, off: c_double);
    fn cairo_set_font_face(cr: *mut cairo_t, f: *mut cairo_font_face_t);
    fn cairo_set_font_size(cr: *mut cairo_t, s: c_double);
    fn cairo_show_glyphs(cr: *mut cairo_t, g: *const Glyph, n: c_int);

    fn cairo_pattern_create_linear(x0: c_double, y0: c_double, x1: c_double, y1: c_double) -> *mut cairo_pattern_t;
    fn cairo_pattern_create_radial(x0: c_double, y0: c_double, r0: c_double, x1: c_double, y1: c_double, r1: c_double) -> *mut cairo_pattern_t;
    fn cairo_pattern_create_mesh() -> *mut cairo_pattern_t;
    fn cairo_pattern_create_for_surface(s: *mut cairo_surface_t) -> *mut cairo_pattern_t;
    fn cairo_pattern_add_color_stop_rgba(p: *mut cairo_pattern_t, o: c_double, r: c_double, g: c_double, b: c_double, a: c_double);
    fn cairo_pattern_set_extend(p: *mut cairo_pattern_t, e: c_int);
    fn cairo_pattern_set_matrix(p: *mut cairo_pattern_t, m: *const Matrix);
    fn cairo_pattern_destroy(p: *mut cairo_pattern_t);
    fn cairo_mesh_pattern_begin_patch(p: *mut cairo_pattern_t);
    fn cairo_mesh_pattern_end_patch(p: *mut cairo_pattern_t);
    fn cairo_mesh_pattern_move_to(p: *mut cairo_pattern_t, x: c_double, y: c_double);
    fn cairo_mesh_pattern_line_to(p: *mut cairo_pattern_t, x: c_double, y: c_double);
    fn cairo_mesh_pattern_curve_to(p: *mut cairo_pattern_t, x1: c_double, y1: c_double, x2: c_double, y2: c_double, x3: c_double, y3: c_double);
    fn cairo_mesh_pattern_set_corner_color_rgba(p: *mut cairo_pattern_t, corner: c_uint, r: c_double, g: c_double, b: c_double, a: c_double);

    fn cairo_matrix_init_scale(m: *mut Matrix, sx: c_double, sy: c_double);
    fn cairo_matrix_init_rotate(m: *mut Matrix, a: c_double);
    fn cairo_matrix_translate(m: *mut Matrix, tx: c_double, ty: c_double);

    fn cairo_ft_font_face_create_for_ft_face(face: *mut c_void, load_flags: c_int) -> *mut cairo_font_face_t;

    // de/ctext
    fn at_font_init() -> c_int;
    fn at_font_face(idx: c_int) -> *mut c_void;
    fn at_font_shape_role(text: *const c_char, len: c_int, px: c_int, style: c_int, role: c_int, out: *mut AtGlyph, cap: c_int) -> c_int;
    fn at_font_ascent_role(px: c_int, role: c_int) -> c_double;
    fn at_font_descent_role(px: c_int, role: c_int) -> c_double;
    fn at_font_set_role(role: c_int, family: *const c_char) -> c_int;

    // de/cdraw
    fn cd_blur_a8(a: *mut u8, scratch: *mut u8, w: c_int, h: c_int, stride: c_int, radius: c_int);
    fn cd_noise_a8(a: *mut u8, w: c_int, h: c_int, stride: c_int, seed: u32, alpha: c_int);
}

// MARK: surfaces

/// An owned reference to a cairo surface.
pub struct Surface(*mut cairo_surface_t);

impl Surface {
    pub fn image(format: c_int, w: i32, h: i32) -> Surface {
        Surface(unsafe { cairo_image_surface_create(format, w, h) })
    }
    pub fn stride(&self) -> i32 {
        unsafe { cairo_image_surface_get_stride(self.0) }
    }
    pub fn flush(&self) {
        unsafe { cairo_surface_flush(self.0) }
    }
    pub fn mark_dirty(&self) {
        unsafe { cairo_surface_mark_dirty(self.0) }
    }
    pub fn write_png(&self, path: &str) -> bool {
        let Ok(p) = CString::new(path) else { return false };
        unsafe { cairo_surface_write_to_png(self.0, p.as_ptr()) == 0 }
    }
    /// `cd_blur_a8` over this A8 surface's pixels, with a fresh scratch
    /// buffer of `w * h` bytes (as DrawList.swift allocates it).
    pub fn blur_a8(&self, w: i32, h: i32, radius: i32) {
        let data = unsafe { cairo_image_surface_get_data(self.0) };
        if data.is_null() {
            return;
        }
        let mut scratch = vec![0u8; (w.max(0) as usize) * (h.max(0) as usize)];
        unsafe { cd_blur_a8(data, scratch.as_mut_ptr(), w, h, self.stride(), radius) }
    }
    /// `cd_noise_a8` into this A8 surface's pixels.
    pub fn noise_a8(&self, w: i32, h: i32, seed: u32, alpha: i32) {
        let data = unsafe { cairo_image_surface_get_data(self.0) };
        if data.is_null() {
            return;
        }
        unsafe { cd_noise_a8(data, w, h, self.stride(), seed, alpha) }
    }
}

impl Drop for Surface {
    fn drop(&mut self) {
        unsafe { cairo_surface_destroy(self.0) }
    }
}

// MARK: patterns

pub struct Pattern(*mut cairo_pattern_t);

impl Pattern {
    pub fn linear(x0: f64, y0: f64, x1: f64, y1: f64) -> Pattern {
        Pattern(unsafe { cairo_pattern_create_linear(x0, y0, x1, y1) })
    }
    pub fn radial(x0: f64, y0: f64, r0: f64, x1: f64, y1: f64, r1: f64) -> Pattern {
        Pattern(unsafe { cairo_pattern_create_radial(x0, y0, r0, x1, y1, r1) })
    }
    pub fn mesh() -> Pattern {
        Pattern(unsafe { cairo_pattern_create_mesh() })
    }
    pub fn for_surface(s: &Surface) -> Pattern {
        Pattern(unsafe { cairo_pattern_create_for_surface(s.0) })
    }
    pub fn add_color_stop_rgba(&self, o: f64, r: f64, g: f64, b: f64, a: f64) {
        unsafe { cairo_pattern_add_color_stop_rgba(self.0, o, r, g, b, a) }
    }
    pub fn set_extend_repeat(&self) {
        unsafe { cairo_pattern_set_extend(self.0, EXTEND_REPEAT) }
    }
    pub fn set_matrix(&self, m: &Matrix) {
        unsafe { cairo_pattern_set_matrix(self.0, m) }
    }
    pub fn mesh_begin_patch(&self) {
        unsafe { cairo_mesh_pattern_begin_patch(self.0) }
    }
    pub fn mesh_end_patch(&self) {
        unsafe { cairo_mesh_pattern_end_patch(self.0) }
    }
    pub fn mesh_move_to(&self, x: f64, y: f64) {
        unsafe { cairo_mesh_pattern_move_to(self.0, x, y) }
    }
    pub fn mesh_line_to(&self, x: f64, y: f64) {
        unsafe { cairo_mesh_pattern_line_to(self.0, x, y) }
    }
    pub fn mesh_curve_to(&self, x1: f64, y1: f64, x2: f64, y2: f64, x3: f64, y3: f64) {
        unsafe { cairo_mesh_pattern_curve_to(self.0, x1, y1, x2, y2, x3, y3) }
    }
    pub fn mesh_set_corner_color_rgba(&self, corner: u32, r: f64, g: f64, b: f64, a: f64) {
        unsafe { cairo_mesh_pattern_set_corner_color_rgba(self.0, corner, r, g, b, a) }
    }
}

impl Drop for Pattern {
    fn drop(&mut self) {
        unsafe { cairo_pattern_destroy(self.0) }
    }
}

impl Matrix {
    pub fn scale(sx: f64, sy: f64) -> Matrix {
        let mut m = Matrix::default();
        unsafe { cairo_matrix_init_scale(&mut m, sx, sy) };
        m
    }
    pub fn rotate(a: f64) -> Matrix {
        let mut m = Matrix::default();
        unsafe { cairo_matrix_init_rotate(&mut m, a) };
        m
    }
    pub fn translate(&mut self, tx: f64, ty: f64) {
        unsafe { cairo_matrix_translate(self, tx, ty) }
    }
}

// MARK: font faces

/// A cairo-ft face over CText's render face `idx`; lives for the process,
/// as Text.swift's faceCache keeps its faces (never destroyed).
#[derive(Clone, Copy)]
pub struct FontFace(*mut cairo_font_face_t);

impl FontFace {
    pub fn for_ctext_face(idx: i32) -> Option<FontFace> {
        let raw = unsafe { at_font_face(idx) };
        if raw.is_null() {
            return None;
        }
        let f = unsafe { cairo_ft_font_face_create_for_ft_face(raw, 0) };
        if f.is_null() {
            None
        } else {
            Some(FontFace(f))
        }
    }
}

// MARK: the context

pub struct Context(*mut cairo_t);

impl Context {
    pub fn new(s: &Surface) -> Context {
        Context(unsafe { cairo_create(s.0) })
    }
    pub fn save(&self) {
        unsafe { cairo_save(self.0) }
    }
    pub fn restore(&self) {
        unsafe { cairo_restore(self.0) }
    }
    pub fn translate(&self, x: f64, y: f64) {
        unsafe { cairo_translate(self.0, x, y) }
    }
    pub fn scale(&self, x: f64, y: f64) {
        unsafe { cairo_scale(self.0, x, y) }
    }
    pub fn rotate(&self, a: f64) {
        unsafe { cairo_rotate(self.0, a) }
    }
    pub fn set_source_rgb(&self, r: f64, g: f64, b: f64) {
        unsafe { cairo_set_source_rgb(self.0, r, g, b) }
    }
    pub fn set_source_rgba(&self, r: f64, g: f64, b: f64, a: f64) {
        unsafe { cairo_set_source_rgba(self.0, r, g, b, a) }
    }
    pub fn set_source(&self, p: &Pattern) {
        unsafe { cairo_set_source(self.0, p.0) }
    }
    pub fn paint(&self) {
        unsafe { cairo_paint(self.0) }
    }
    pub fn fill(&self) {
        unsafe { cairo_fill(self.0) }
    }
    pub fn stroke(&self) {
        unsafe { cairo_stroke(self.0) }
    }
    pub fn clip(&self) {
        unsafe { cairo_clip(self.0) }
    }
    pub fn mask(&self, p: &Pattern) {
        unsafe { cairo_mask(self.0, p.0) }
    }
    pub fn mask_surface(&self, s: &Surface, x: f64, y: f64) {
        unsafe { cairo_mask_surface(self.0, s.0, x, y) }
    }
    pub fn new_path(&self) {
        unsafe { cairo_new_path(self.0) }
    }
    pub fn new_sub_path(&self) {
        unsafe { cairo_new_sub_path(self.0) }
    }
    pub fn close_path(&self) {
        unsafe { cairo_close_path(self.0) }
    }
    pub fn move_to(&self, x: f64, y: f64) {
        unsafe { cairo_move_to(self.0, x, y) }
    }
    pub fn line_to(&self, x: f64, y: f64) {
        unsafe { cairo_line_to(self.0, x, y) }
    }
    pub fn curve_to(&self, x1: f64, y1: f64, x2: f64, y2: f64, x3: f64, y3: f64) {
        unsafe { cairo_curve_to(self.0, x1, y1, x2, y2, x3, y3) }
    }
    pub fn arc(&self, xc: f64, yc: f64, r: f64, a1: f64, a2: f64) {
        unsafe { cairo_arc(self.0, xc, yc, r, a1, a2) }
    }
    pub fn rectangle(&self, x: f64, y: f64, w: f64, h: f64) {
        unsafe { cairo_rectangle(self.0, x, y, w, h) }
    }
    pub fn set_line_width(&self, w: f64) {
        unsafe { cairo_set_line_width(self.0, w) }
    }
    pub fn set_line_cap(&self, c: c_int) {
        unsafe { cairo_set_line_cap(self.0, c) }
    }
    pub fn set_line_join(&self, j: c_int) {
        unsafe { cairo_set_line_join(self.0, j) }
    }
    pub fn set_dash(&self, d: &[f64], off: f64) {
        unsafe { cairo_set_dash(self.0, d.as_ptr(), d.len() as c_int, off) }
    }
    pub fn set_font_face(&self, f: FontFace) {
        unsafe { cairo_set_font_face(self.0, f.0) }
    }
    pub fn set_font_size(&self, s: f64) {
        unsafe { cairo_set_font_size(self.0, s) }
    }
    pub fn show_glyphs(&self, g: &[Glyph]) {
        unsafe { cairo_show_glyphs(self.0, g.as_ptr(), g.len() as c_int) }
    }
}

impl Drop for Context {
    fn drop(&mut self) {
        unsafe { cairo_destroy(self.0) }
    }
}

// MARK: CText

pub fn font_init() -> bool {
    unsafe { at_font_init() != 0 }
}

/// at_font_set_role, as Theme.use reaches it through Text.useRoles.
pub fn font_set_role(role: i32, family: &str) -> bool {
    let Ok(f) = CString::new(family) else { return false };
    unsafe { at_font_set_role(role, f.as_ptr()) != 0 }
}

pub fn font_ascent_role(px: i32, role: i32) -> f64 {
    unsafe { at_font_ascent_role(px, role) }
}

pub fn font_descent_role(px: i32, role: i32) -> f64 {
    unsafe { at_font_descent_role(px, role) }
}

/// Shape `text` (up to its first NUL, as Swift's withCString + len -1 sees
/// it), retrying with a bigger buffer as Text.shape does. None on error.
pub fn font_shape_role(text: &str, px: i32, style: i32, role: i32) -> Option<Vec<AtGlyph>> {
    let bytes = text.as_bytes();
    let end = bytes.iter().position(|&b| b == 0).unwrap_or(bytes.len());
    let c = CString::new(&bytes[..end]).ok()?;
    let mut cap = text.len() as i32 + 16;
    loop {
        let mut buf = vec![AtGlyph::default(); cap as usize];
        let n = unsafe { at_font_shape_role(c.as_ptr(), -1, px, style, role, buf.as_mut_ptr(), cap) };
        if n < 0 {
            return None;
        }
        if n <= cap {
            buf.truncate(n as usize);
            return Some(buf);
        }
        cap = n;
    }
}
