//! An XCursor theme on disk, from the theme's cursor lists (U.7b), ported
//! from XCursorTheme in Cursors.swift.
//!
//! Toolkits that draw their own cursor (GTK 3, SDL, anything through
//! libwayland-cursor or libXcursor, X clients under Xwayland) load an
//! XCursor theme by name from `XCURSOR_PATH`. This writes the desktop's own
//! pointer as one, from the same rasteriser the compositor uses, so every
//! window shows the same arrow. `abyss-theme cursors` is the caller.

use crate::cursor::{self, CursorImage, SHAPE_NAMES};
use crate::runner::Runner;
use crate::theme::Theme;

/// The nominal sizes written: the cell at 1x, 1.33x, 2x and 2.67x.
pub const SIZES: [u32; 4] = [24, 32, 48, 64];

/// X11's names, and the CSS name each is. GTK 3, SDL and X clients ask for
/// these; a missing one falls back to a toolkit's own choice. Sorted.
pub const X11_NAMES: [(&str, &str); 44] = [
    ("arrow", "default"),
    ("bottom_left_corner", "sw-resize"),
    ("bottom_right_corner", "se-resize"),
    ("bottom_side", "s-resize"),
    ("circle", "not-allowed"),
    ("closedhand", "grabbing"),
    ("cross", "crosshair"),
    ("crossed_circle", "not-allowed"),
    ("dnd-copy", "copy"),
    ("dnd-link", "alias"),
    ("dnd-move", "grabbing"),
    ("dnd-none", "no-drop"),
    ("fleur", "move"),
    ("forbidden", "not-allowed"),
    ("h_double_arrow", "ew-resize"),
    ("half-busy", "progress"),
    ("hand1", "pointer"),
    ("hand2", "pointer"),
    ("ibeam", "text"),
    ("left_ptr", "default"),
    ("left_ptr_watch", "progress"),
    ("left_side", "w-resize"),
    ("openhand", "grab"),
    ("pointing_hand", "pointer"),
    ("question_arrow", "help"),
    ("right_side", "e-resize"),
    ("sb_h_double_arrow", "ew-resize"),
    ("sb_v_double_arrow", "ns-resize"),
    ("size_all", "move"),
    ("size_bdiag", "nesw-resize"),
    ("size_fdiag", "nwse-resize"),
    ("size_hor", "ew-resize"),
    ("size_ver", "ns-resize"),
    ("split_h", "col-resize"),
    ("split_v", "row-resize"),
    ("tcross", "crosshair"),
    ("top_left_arrow", "default"),
    ("top_left_corner", "nw-resize"),
    ("top_right_corner", "ne-resize"),
    ("top_side", "n-resize"),
    ("v_double_arrow", "ns-resize"),
    ("watch", "wait"),
    ("whats_this", "help"),
    ("xterm", "text"),
];

/// One XCursor file: an image per size, each with its hotspot. libXcursor's
/// format: a header, a table of contents, then image chunks of
/// premultiplied ARGB, all little-endian.
pub fn encode(images: &[CursorImage]) -> Vec<u8> {
    const IMAGE: u32 = 0xfffd_0002;
    let mut b = Vec::new();
    let u32 = |b: &mut Vec<u8>, v: u32| b.extend_from_slice(&v.to_le_bytes());
    u32(&mut b, 0x7275_6358); // "Xcur"
    u32(&mut b, 16); // header size
    u32(&mut b, 0x0001_0000); // version
    u32(&mut b, images.len() as u32);
    let mut at = 16 + 12 * images.len();
    for im in images {
        u32(&mut b, IMAGE);
        u32(&mut b, im.size as u32);
        u32(&mut b, at as u32);
        at += 36 + im.pixels.len() * 4;
    }
    for im in images {
        for v in [36, IMAGE, im.size as u32, 1, im.size as u32, im.size as u32, im.hot_x as u32, im.hot_y as u32, 0] {
            u32(&mut b, v);
        }
        for &p in &im.pixels {
            u32(&mut b, p);
        }
    }
    b
}

/// Whole, or not at all: written beside and renamed over.
fn put(path: &str, bytes: &[u8]) -> bool {
    let tmp = format!("{path}.tmp");
    std::fs::write(&tmp, bytes).is_ok() && std::fs::rename(&tmp, path).is_ok()
}

/// Write the theme `name` into `dir/name`: `index.theme`, `cursors/<css
/// name>` for every shape, and `cursors/<x11 name>` links. How many files
/// and links, or None if a write failed.
pub fn install(runner: &mut Runner, theme: &Theme, dir: &str, name: &str) -> Option<(usize, usize)> {
    let root = format!("{dir}/{name}");
    let cursors = format!("{root}/cursors");
    std::fs::create_dir_all(&cursors).ok()?;
    let index = format!("[Icon Theme]\nName={name}\nComment=The pointer, from the desktop's theme\n");
    if !put(&format!("{root}/index.theme"), index.as_bytes()) {
        return None;
    }
    let cell = cursor::size(theme);
    for n in SHAPE_NAMES {
        let images: Vec<CursorImage> = SIZES.iter().filter_map(|&s| cursor::rasterise(runner, theme, n, s as f64 / cell)).collect();
        if images.len() != SIZES.len() || !put(&format!("{cursors}/{n}"), &encode(&images)) {
            return None;
        }
    }
    for (x, css) in X11_NAMES {
        let p = format!("{cursors}/{x}");
        let _ = std::fs::remove_file(&p);
        std::os::unix::fs::symlink(css, &p).ok()?;
    }
    Some((SHAPE_NAMES.len(), X11_NAMES.len()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_x11_name_points_at_a_shape() {
        for (x, css) in X11_NAMES {
            assert!(SHAPE_NAMES.contains(&css), "{x} → {css} is no shape");
        }
    }

    #[test]
    fn the_table_of_contents_points_at_each_image() {
        let im = |s: usize| CursorImage { size: s, pixels: vec![0xff00_00ff; s * s], hot_x: 1, hot_y: 2 };
        let b = encode(&[im(2), im(3)]);
        let word = |i: usize| u32::from_le_bytes(b[i..i + 4].try_into().unwrap());
        assert_eq!((word(0), word(12)), (0x7275_6358, 2));
        assert_eq!(word(24), 40);
        assert_eq!(word(36), 40 + 36 + 16);
        assert_eq!(b.len(), 40 + 36 + 16 + 36 + 36);
        assert_eq!((word(40 + 24), word(40 + 28)), (1, 2));
    }
}
