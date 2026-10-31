//! An application bundle's own icon (AppIcon.swift), instead of the
//! procedural glyph. A bundle's artwork lives in `Contents/Resources`, and
//! with no LaunchServices the lookup is a convention:
//!
//! ```text
//! Contents/Resources/<BundleName>.{png,icns}
//! Contents/Resources/{icon,Icon}.{png,icns}
//! Contents/Resources/<the first *.png, else the first *.icns>
//! ```
//!
//! An `.icns` is a container, not a codec: since 10.7 its large variants are
//! embedded PNGs, so the biggest one is used. Old RLE variants are not
//! decoded; an icon that cannot be read lets the glyph stand in.
//!
//! Decoded icons are cached by path for the process's life, failures too,
//! so a bad file is probed once.

use crate::finder_model::{finder_display_name, finder_join, read_directory};
use crate::finder_ops::{finder_is_directory, finder_split_extension};
use abyss_sys::Surface;
use aquadraw::canvas::Canvas;
use aquadraw::runner::Rect;
use std::cell::RefCell;
use std::collections::HashMap;
use std::rc::Rc;

/// What `icon_file` returns for a theme icon: never a path on disk.
pub const THEME_PREFIX: &str = "theme:";

thread_local! {
    static CACHE: RefCell<HashMap<String, Option<Rc<Surface>>>> = RefCell::default();
}

/// The icon file inside `bundle` (a `*.app`), by the convention above; None
/// when there is nothing usable, the common case for our own bundles.
pub fn icon_file(bundle: &str) -> Option<String> {
    // A theme icon the bundle names (`theme:NAME`), which follows the theme.
    if let Ok(line) = std::fs::read_to_string(finder_join(bundle, app_bundles::THEME_ICON_FILE)) {
        let name: String = line.lines().next().unwrap_or("").chars().filter(|c| *c != ' ').collect();
        if !name.is_empty() {
            return Some(format!("{THEME_PREFIX}{name}"));
        }
    }
    let resources = finder_join(&finder_join(bundle, "Contents"), "Resources");
    if !finder_is_directory(&resources) {
        return None;
    }
    let names: Vec<String> = read_directory(&resources, false).into_iter().map(|e| e.name).collect();
    let display = finder_display_name(bundle);
    let base = finder_split_extension(&display).0;
    let wanted = [format!("{base}.png"), "icon.png".into(), "Icon.png".into(), format!("{base}.icns"), "icon.icns".into(), "Icon.icns".into()];
    let pick = wanted
        .iter()
        .find(|c| names.contains(c))
        .or_else(|| names.iter().find(|n| n.to_lowercase().ends_with(".png")))
        .or_else(|| names.iter().find(|n| n.to_lowercase().ends_with(".icns")));
    pick.map(|n| finder_join(&resources, n))
}

/// The decoded icon for a path from `icon_file`, if it can be read.
pub fn surface(path: &str) -> Option<Rc<Surface>> {
    if let Some(hit) = CACHE.with(|c| c.borrow().get(path).cloned()) {
        return hit;
    }
    let loaded = decode(path).map(Rc::new);
    CACHE.with(|c| c.borrow_mut().insert(path.into(), loaded.clone()));
    loaded
}

fn decode(path: &str) -> Option<Surface> {
    if path.to_lowercase().ends_with(".icns") {
        return Surface::from_png_bytes(&largest_embedded_png(path)?);
    }
    Surface::from_png(path)
}

/// Draw the icon filling `r`, its aspect kept and centred; false when there
/// is nothing to draw, so the caller falls back.
pub fn draw(c: &mut Canvas, path: &str, r: Rect) -> bool {
    if let Some(name) = path.strip_prefix(THEME_PREFIX) {
        if c.theme.lists.get(name).is_none() {
            return false;
        }
        c.icon(name, r);
        return true;
    }
    let Some(img) = surface(path) else { return false };
    let (iw, ih) = (img.width() as f64, img.height() as f64);
    if iw <= 0.0 || ih <= 0.0 {
        return false;
    }
    let s = (r.w / iw).min(r.h / ih);
    let cr = c.cr;
    cr.save();
    cr.translate(r.x + (r.w - iw * s) / 2.0, r.y + (r.h - ih * s) / 2.0);
    cr.scale(s, s);
    cr.set_source_surface(&img, 0.0, 0.0, false, true);
    cr.paint();
    cr.restore();
    true
}

/// The biggest PNG chunk in an `.icns`: "icns" and the total length, then
/// chunks of a 4-byte type, a 4-byte big-endian length, and the payload. A
/// length that does not fit is a corrupt file: stop, don't guess.
pub fn largest_embedded_png(path: &str) -> Option<Vec<u8>> {
    let data = std::fs::read(path).ok()?;
    if data.len() <= 8 || &data[..4] != b"icns" {
        return None;
    }
    let be32 = |at: usize| u32::from_be_bytes([data[at], data[at + 1], data[at + 2], data[at + 3]]) as usize;
    let mut best: Option<&[u8]> = None;
    let mut off = 8;
    while off + 8 <= data.len() {
        let len = be32(off + 4);
        if len < 8 || off + len > data.len() {
            break;
        }
        let payload = &data[off + 8..off + len];
        if payload.len() > 8 && payload.starts_with(&[0x89, b'P', b'N', b'G']) && payload.len() > best.map_or(0, <[u8]>::len) {
            best = Some(payload)
        }
        off += len;
    }
    best.map(<[u8]>::to_vec)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::finder_model::FinderItemKind;
    use crate::finder_ops::finder_create_directory;
    use abyss_sys::{Context, FORMAT_ARGB32};

    fn scratch(tag: &str) -> String {
        let d = std::env::temp_dir().join(format!("{tag}.{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(&d).unwrap();
        d.to_str().unwrap().into()
    }

    fn write_png(path: &str, side: i32, rgb: (f64, f64, f64)) {
        let s = Surface::image(FORMAT_ARGB32, side, side);
        {
            let cr = Context::new(&s);
            cr.set_source_rgba(rgb.0, rgb.1, rgb.2, 1.0);
            cr.paint();
        }
        assert!(s.write_png(path));
    }

    #[test]
    fn bundle_icon_lookup_and_decode() {
        let root = scratch("appicon");
        let bundle = finder_join(&root, "Marker.app");
        let resources = finder_join(&bundle, "Contents/Resources");
        std::fs::create_dir_all(&resources).unwrap();
        // No artwork: the glyph stands in.
        assert_eq!(icon_file(&bundle), None);
        write_png(&finder_join(&resources, "zebra.png"), 8, (0.0, 0.0, 1.0));
        assert_eq!(icon_file(&bundle), Some(finder_join(&resources, "zebra.png")));
        // One named after the bundle wins.
        write_png(&finder_join(&resources, "Marker.png"), 16, (1.0, 0.0, 0.0));
        let marker = finder_join(&resources, "Marker.png");
        assert_eq!(icon_file(&bundle).as_deref(), Some(marker.as_str()));
        let img = surface(&marker).expect("it decodes");
        assert_eq!(img.width(), 16);
        // A listing marks the bundle with its icon, a folder with none.
        assert!(finder_create_directory(&finder_join(&root, "Documents")));
        let listed = read_directory(&root, false);
        let app = listed.iter().find(|e| e.name == "Marker.app").unwrap();
        assert_eq!(app.kind, FinderItemKind::Application);
        assert_eq!(app.icon_path.as_deref(), Some(marker.as_str()));
        assert_eq!(listed.iter().find(|e| e.name == "Documents").unwrap().icon_path, None);
        let _ = std::fs::remove_dir_all(&root);
    }

    /// The biggest variant is the sharpest; a file that is no ICNS is None.
    #[test]
    fn icns_embedded_png_extraction() {
        let root = scratch("icns");
        let png = |side: i32| {
            let p = finder_join(&root, &format!("tmp{side}.png"));
            write_png(&p, side, (0.0, 1.0, 0.0));
            std::fs::read(&p).unwrap()
        };
        let (small, large) = (png(8), png(64));
        assert!(large.len() > small.len());
        let chunk = |ty: &[u8], payload: &[u8]| [ty, &((payload.len() + 8) as u32).to_be_bytes(), payload].concat();
        let body = [chunk(b"ic07", &small), chunk(b"ic09", &large)].concat();
        let file = [b"icns".as_slice(), &((body.len() + 8) as u32).to_be_bytes(), &body].concat();
        let icns = finder_join(&root, "Marker.icns");
        std::fs::write(&icns, file).unwrap();
        assert_eq!(largest_embedded_png(&icns), Some(large));
        assert_eq!(surface(&icns).map(|s| s.width()), Some(64));
        let bogus = finder_join(&root, "bogus.icns");
        std::fs::write(&bogus, "not an icon at all").unwrap();
        assert_eq!(largest_embedded_png(&bogus), None);
        assert!(surface(&bogus).is_none());
        let _ = std::fs::remove_dir_all(&root);
    }
}
