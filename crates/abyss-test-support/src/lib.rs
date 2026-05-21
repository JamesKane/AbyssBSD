// SPDX-License-Identifier: BSD-2-Clause

//! Shared test support for the AbyssBSD workspace.
//!
//! Several crates' tests open a real system font. The usable path differs
//! per platform — macOS, FreeBSD, the Debian/Ubuntu CI runner — so the
//! candidate list lives here, in one place: a new platform's path is added
//! once, not in every crate whose tests need a font.

use std::path::Path;

use abyss_font::Font;

/// Candidate paths to a real system font, across the development and CI
/// platforms. The first one that exists is used.
const FONT_CANDIDATES: &[&str] = &[
    "/System/Library/Fonts/Monaco.ttf",
    "/System/Library/Fonts/Geneva.ttf",
    "/usr/local/share/fonts/dejavu/DejaVuSans.ttf",
    "/usr/share/fonts/dejavu/DejaVuSans.ttf",
    "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
];

/// Open a real system font for use in tests.
///
/// # Panics
///
/// Panics if no font in `FONT_CANDIDATES` exists on this platform, or if
/// the font that does exist fails to open.
pub fn test_font() -> Font {
    for candidate in FONT_CANDIDATES {
        if Path::new(candidate).exists() {
            return Font::open(Path::new(candidate)).expect("open the test font");
        }
    }
    panic!("no test font found; add this platform's path to FONT_CANDIDATES in abyss-test-support");
}
