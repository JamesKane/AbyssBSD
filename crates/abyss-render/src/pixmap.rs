// SPDX-License-Identifier: BSD-2-Clause

//! A CPU pixel buffer — the [`CpuBackend`](crate::CpuBackend)'s target.

use crate::color::Color;

/// A rectangular buffer of [`Color`] pixels, row-major.
#[derive(Debug, Clone)]
pub struct Pixmap {
    width: u32,
    height: u32,
    data: Vec<Color>,
}

impl Pixmap {
    /// A new pixmap, every pixel transparent.
    #[must_use]
    pub fn new(width: u32, height: u32) -> Pixmap {
        let len = width as usize * height as usize;
        Pixmap {
            width,
            height,
            data: vec![Color::TRANSPARENT; len],
        }
    }

    #[must_use]
    pub fn width(&self) -> u32 {
        self.width
    }

    #[must_use]
    pub fn height(&self) -> u32 {
        self.height
    }

    /// The pixels, row-major, top-left first.
    #[must_use]
    pub fn data(&self) -> &[Color] {
        &self.data
    }

    /// The pixel at `(x, y)`.
    ///
    /// # Panics
    ///
    /// Panics if `(x, y)` is outside the pixmap.
    #[must_use]
    pub fn pixel(&self, x: u32, y: u32) -> Color {
        assert!(x < self.width && y < self.height, "pixel out of bounds");
        self.data[y as usize * self.width as usize + x as usize]
    }

    /// Set the pixel at `(x, y)`.
    ///
    /// # Panics
    ///
    /// Panics if `(x, y)` is outside the pixmap.
    pub fn set_pixel(&mut self, x: u32, y: u32, color: Color) {
        assert!(x < self.width && y < self.height, "pixel out of bounds");
        self.data[y as usize * self.width as usize + x as usize] = color;
    }

    /// Fill every pixel with `color`.
    pub fn clear(&mut self, color: Color) {
        self.data.fill(color);
    }
}
