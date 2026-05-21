//! AbyssBSD 2D renderer.
//!
//! A NanoVG-style immediate-mode vector drawing API ([`Canvas`]) over a
//! [`RenderBackend`] seam, with a software [`CpuBackend`]. Implements the
//! geometry half of `docs/design/toolkit.md` §3 — paths, fills, gradients,
//! and clipping, all anti-aliased.
//!
//! Text — the font-stack FFI and the glyph atlas — is a later Phase-3
//! increment; this crate is pure, dependency-free, and host-testable.

#![forbid(unsafe_code)]

mod backend;
mod canvas;
mod color;
mod cpu;
mod geometry;
mod paint;
mod path;
mod pixmap;
mod text;

pub use abyss_font::{Font, FontMetrics};
pub use backend::{CoverageMask, RenderBackend};
pub use canvas::Canvas;
pub use color::Color;
pub use cpu::CpuBackend;
pub use geometry::{Point, Rect, Size, Transform};
pub use paint::{FillRule, GradientStop, Paint};
pub use path::Path;
pub use pixmap::Pixmap;
pub use text::GlyphCache;
