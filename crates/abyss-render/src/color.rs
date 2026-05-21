// SPDX-License-Identifier: BSD-2-Clause

//! Colors and source-over compositing.

/// An 8-bit-per-channel RGBA color with straight (non-premultiplied) alpha.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Color {
    pub r: u8,
    pub g: u8,
    pub b: u8,
    pub a: u8,
}

impl Color {
    pub const TRANSPARENT: Color = Color {
        r: 0,
        g: 0,
        b: 0,
        a: 0,
    };
    pub const BLACK: Color = Color {
        r: 0,
        g: 0,
        b: 0,
        a: 255,
    };
    pub const WHITE: Color = Color {
        r: 255,
        g: 255,
        b: 255,
        a: 255,
    };

    #[must_use]
    pub const fn rgba(r: u8, g: u8, b: u8, a: u8) -> Color {
        Color { r, g, b, a }
    }

    #[must_use]
    pub const fn rgb(r: u8, g: u8, b: u8) -> Color {
        Color { r, g, b, a: 255 }
    }

    /// Per-channel linear interpolation; `t` is clamped to `0..=1`.
    #[must_use]
    pub fn lerp(self, other: Color, t: f32) -> Color {
        let t = t.clamp(0.0, 1.0);
        let mix = |a: u8, b: u8| -> u8 {
            (f32::from(a) + (f32::from(b) - f32::from(a)) * t).round() as u8
        };
        Color {
            r: mix(self.r, other.r),
            g: mix(self.g, other.g),
            b: mix(self.b, other.b),
            a: mix(self.a, other.a),
        }
    }

    /// Scale the alpha channel by `factor` (clamped to `0..=1`) — how a
    /// coverage value is applied to a paint sample.
    #[must_use]
    pub fn scale_alpha(self, factor: f32) -> Color {
        Color {
            a: (f32::from(self.a) * factor.clamp(0.0, 1.0)).round() as u8,
            ..self
        }
    }

    /// `self` composited over `dst` — Porter-Duff source-over.
    #[must_use]
    pub fn over(self, dst: Color) -> Color {
        if self.a == 255 {
            return self;
        }
        if self.a == 0 {
            return dst;
        }
        let sa = f32::from(self.a) / 255.0;
        let da = f32::from(dst.a) / 255.0;
        let out_a = sa + da * (1.0 - sa);
        if out_a <= 0.0 {
            return Color::TRANSPARENT;
        }
        let blend = |s: u8, d: u8| -> u8 {
            let s = f32::from(s) / 255.0;
            let d = f32::from(d) / 255.0;
            let premul = s * sa + d * da * (1.0 - sa);
            (premul / out_a * 255.0).round().clamp(0.0, 255.0) as u8
        };
        Color {
            r: blend(self.r, dst.r),
            g: blend(self.g, dst.g),
            b: blend(self.b, dst.b),
            a: (out_a * 255.0).round().clamp(0.0, 255.0) as u8,
        }
    }
}
