// SPDX-License-Identifier: BSD-2-Clause

//! The shared visual theme (`docs/design/toolkit.md` §9).

use abyss_render::Color;

/// Colors, metrics, and the font size widgets paint with.
///
/// One `Theme` is shared by the toolkit's widgets, the compositor's
/// server-side decorations, and the shell's furniture, so the desktop is
/// visually coherent (§9). The default is the GNOME-2 appearance.
#[derive(Debug, Clone)]
pub struct Theme {
    /// The window background.
    pub background: Color,
    /// A widget surface — a button face, a field.
    pub surface: Color,
    /// A widget surface while pressed or active.
    pub surface_active: Color,
    /// Text and foreground detail.
    pub text: Color,
    /// The selection / focus accent.
    pub accent: Color,
    /// Padding inside a widget, in pixels.
    pub padding: f32,
    /// Corner radius for rounded widgets, in pixels.
    pub corner_radius: f32,
    /// The text size widgets render at, in pixels.
    pub font_size: f32,
}

impl Default for Theme {
    fn default() -> Theme {
        Theme {
            background: Color::rgb(0xD6, 0xD3, 0xCD),
            surface: Color::rgb(0xE9, 0xE7, 0xE2),
            surface_active: Color::rgb(0xBC, 0xB9, 0xB1),
            text: Color::rgb(0x20, 0x20, 0x20),
            accent: Color::rgb(0x4A, 0x6B, 0x8A),
            padding: 6.0,
            corner_radius: 3.0,
            font_size: 13.0,
        }
    }
}
