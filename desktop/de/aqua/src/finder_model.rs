//! The Finder's pure half (FinderModel.swift): listing, sorting, and every
//! piece of geometry (icon grid, list rows, scrolling). No cairo and no
//! Wayland, so paint and hit-test share one layout and it is testable with
//! no compositor (HANDOFF §2.9).
//!
//! The Mac OS X Finder interleaves folders and files in one
//! case-insensitive alphabetical run, and its default is the icon grid.

use crate::app_icon;
use aquadraw::runner::Rect;
use aquadraw::tokens::ThemeTokens;
use std::os::unix::fs::MetadataExt;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum FinderItemKind {
    Folder,
    /// A bundle directory: its name ends in `.app`.
    Application,
    Document,
    /// A volume root.
    Disk,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct FinderEntry {
    pub name: String,
    pub kind: FinderItemKind,
    /// Bytes; meaningless for folders.
    pub size: u64,
    /// An application bundle's own icon, resolved once per listing.
    pub icon_path: Option<String>,
}

impl FinderEntry {
    pub fn new(name: &str, kind: FinderItemKind) -> FinderEntry {
        FinderEntry { name: name.into(), kind, size: 0, icon_path: None }
    }
    pub fn sized(name: &str, kind: FinderItemKind, size: u64) -> FinderEntry {
        FinderEntry { size, ..FinderEntry::new(name, kind) }
    }
    /// Whether activating it navigates into it.
    pub fn is_container(&self) -> bool {
        matches!(self.kind, FinderItemKind::Folder | FinderItemKind::Disk)
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum FinderView {
    Icon,
    List,
}

// MARK: paths

/// A directory and a leaf, without doubling the root's slash.
pub fn finder_join(dir: &str, name: &str) -> String {
    match dir {
        "" => name.into(),
        "/" => format!("/{name}"),
        _ => format!("{dir}/{name}"),
    }
}

fn trim_slashes(path: &str) -> &str {
    let t = path.trim_end_matches('/');
    if t.is_empty() { "/" } else { t }
}

/// The containing directory, or None at the root.
pub fn finder_parent(path: &str) -> Option<String> {
    if path.is_empty() || path == "/" {
        return None;
    }
    let p = trim_slashes(path);
    let slash = p.rfind('/')?;
    Some(if slash == 0 { "/".into() } else { p[..slash].into() })
}

/// The name a window shows for a directory: its leaf, or "Computer" at the
/// volume root (Jaguar's title for the machine itself).
pub fn finder_display_name(path: &str) -> String {
    if path.is_empty() || path == "/" {
        return "Computer".into();
    }
    let p = trim_slashes(path);
    p.rsplit('/').next().unwrap_or(p).into()
}

// MARK: listing

/// A directory whose name ends in `.app` is an application bundle, shown
/// as one item rather than a folder.
pub fn finder_kind(name: &str, is_directory: bool) -> FinderItemKind {
    match (is_directory, name.ends_with(".app")) {
        (false, _) => FinderItemKind::Document,
        (true, true) => FinderItemKind::Application,
        (true, false) => FinderItemKind::Folder,
    }
}

/// One case-insensitive alphabetical run over every kind, ties broken by
/// the raw name so the order is total.
pub fn finder_sort(mut entries: Vec<FinderEntry>) -> Vec<FinderEntry> {
    entries.sort_by(|a, b| a.name.to_lowercase().cmp(&b.name.to_lowercase()).then_with(|| a.name.cmp(&b.name)));
    entries
}

/// Read and sort a directory. Dot-files are hidden unless `show_hidden`; an
/// unreadable directory lists as empty (the window still opens).
pub fn read_directory(path: &str, show_hidden: bool) -> Vec<FinderEntry> {
    let Ok(rd) = std::fs::read_dir(path) else { return vec![] };
    let mut out = Vec::new();
    for e in rd.flatten() {
        let name = e.file_name().to_string_lossy().into_owned();
        if !show_hidden && name.starts_with('.') {
            continue;
        }
        let full = finder_join(path, &name);
        // stat, not the entry's type: follow aliases to what they name.
        let md = std::fs::metadata(&full).ok();
        let is_dir = md.as_ref().is_some_and(|m| m.is_dir());
        let size = md.as_ref().filter(|_| !is_dir).map_or(0, |m| m.size());
        let kind = finder_kind(&name, is_dir);
        // An app bundle may carry its own icon: looked for once, here.
        let icon_path = (kind == FinderItemKind::Application).then(|| app_icon::icon_file(&full)).flatten();
        out.push(FinderEntry { name, kind, size, icon_path });
    }
    finder_sort(out)
}

/// A byte count in the Finder's decimal units ("1.4 MB").
pub fn finder_format_bytes(bytes: u64) -> String {
    let one = |v: f64| {
        let t = (v * 10.0).round() as u64;
        format!("{}.{}", t / 10, t % 10)
    };
    let b = bytes as f64;
    match bytes {
        1_000_000_000.. => format!("{} GB", one(b / 1e9)),
        1_000_000.. => format!("{} MB", one(b / 1e6)),
        1_000.. => format!("{} KB", one(b / 1e3)),
        1 => "1 byte".into(),
        _ => format!("{bytes} bytes"),
    }
}

/// The status line: the item count and the volume's free space.
pub fn finder_status_text(count: usize, free_bytes: u64) -> String {
    let items = if count == 1 { "1 item".into() } else { format!("{count} items") };
    if free_bytes == 0 { items } else { format!("{items}, {} available", finder_format_bytes(free_bytes)) }
}

/// Type-select: the next entry whose name starts with `prefix`
/// (case-insensitive), searching on from `after` and wrapping.
pub fn finder_type_select(entries: &[FinderEntry], prefix: &str, after: Option<usize>) -> Option<usize> {
    if prefix.is_empty() || entries.is_empty() {
        return None;
    }
    let needle = prefix.to_lowercase();
    let start = after.map_or(0, |a| a + 1) % entries.len();
    (0..entries.len()).map(|k| (start + k) % entries.len()).find(|&i| entries[i].name.to_lowercase().starts_with(&needle))
}

// MARK: window geometry

/// The rects of a Finder window `w`×`h`: paint draws them and the pointer
/// hit-tests the same.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct FinderLayout {
    pub toolbar: Rect,
    pub back_button: Rect,
    /// The two-segment icon/list switch.
    pub view_control: Rect,
    /// The clipped item viewport.
    pub content: Rect,
    pub track: Rect,
    pub up_arrow: Rect,
    pub down_arrow: Rect,
    pub status: Rect,
}

pub const LIST_HEADER_HEIGHT: f64 = 17.0;

pub fn finder_layout(t: &ThemeTokens, w: f64, h: f64, toolbar_visible: bool) -> FinderLayout {
    let top = t.title_bar_height;
    let bar_h = if toolbar_visible { t.finder_toolbar_height } else { 0.0 };
    let status_y = h - t.finder_status_height;
    let body_y = top + bar_h;
    let body_h = status_y - body_y;
    let sw = t.finder_scrollbar_width;
    let bar_x = w - sw;
    FinderLayout {
        toolbar: Rect::new(0.0, top, w, bar_h),
        back_button: Rect::new(12.0, top + 6.0, 30.0, 24.0),
        view_control: Rect::new(52.0, top + 6.0, 62.0, 24.0),
        content: Rect::new(0.0, body_y, w - sw, body_h),
        // Jaguar pairs both scroll arrows at the bottom of the bar.
        track: Rect::new(bar_x, body_y, sw, (body_h - 2.0 * sw).max(0.0)),
        up_arrow: Rect::new(bar_x, body_y + body_h - 2.0 * sw, sw, sw),
        down_arrow: Rect::new(bar_x, body_y + body_h - sw, sw, sw),
        status: Rect::new(0.0, status_y, w, t.finder_status_height),
    }
}

/// The scrolling item area: the content, less the list view's header.
pub fn finder_item_viewport(l: &FinderLayout, view: FinderView) -> Rect {
    match view {
        FinderView::Icon => l.content,
        FinderView::List => Rect::new(l.content.x, l.content.y + LIST_HEADER_HEIGHT, l.content.w, (l.content.h - LIST_HEADER_HEIGHT).max(0.0)),
    }
}

/// Icon columns that fit `viewport_w`, at least one.
pub fn finder_columns(t: &ThemeTokens, viewport_w: f64) -> usize {
    (((viewport_w - 2.0 * t.finder_grid_pad) / t.finder_cell_w) as i64).max(1) as usize
}

/// Item `i`'s cell, in surface coordinates.
pub fn finder_item_rect(t: &ThemeTokens, i: usize, view: FinderView, vp: Rect, scroll: f64) -> Rect {
    match view {
        FinderView::Icon => {
            let cols = finder_columns(t, vp.w);
            let (row, col) = (i / cols, i % cols);
            Rect::new(vp.x + t.finder_grid_pad + col as f64 * t.finder_cell_w, vp.y + t.finder_grid_pad + row as f64 * t.finder_cell_h - scroll, t.finder_cell_w, t.finder_cell_h)
        }
        FinderView::List => Rect::new(vp.x, vp.y + i as f64 * t.finder_row_height - scroll, vp.w, t.finder_row_height),
    }
}

/// The scrollable height of `count` items.
pub fn finder_content_height(t: &ThemeTokens, count: usize, view: FinderView, vp: Rect) -> f64 {
    match view {
        FinderView::Icon => {
            let cols = finder_columns(t, vp.w);
            count.div_ceil(cols) as f64 * t.finder_cell_h + 2.0 * t.finder_grid_pad
        }
        FinderView::List => count as f64 * t.finder_row_height,
    }
}

pub fn finder_max_scroll(t: &ThemeTokens, count: usize, view: FinderView, vp: Rect) -> f64 {
    (finder_content_height(t, count, view, vp) - vp.h).max(0.0)
}

/// The item under a point, or None (empty space, or past the last item).
pub fn finder_index(t: &ThemeTokens, x: f64, y: f64, count: usize, view: FinderView, vp: Rect, scroll: f64) -> Option<usize> {
    if !vp.contains(x, y) || count == 0 {
        return None;
    }
    let i = match view {
        FinderView::Icon => {
            let cols = finder_columns(t, vp.w);
            let (lx, ly) = (x - vp.x - t.finder_grid_pad, y - vp.y - t.finder_grid_pad + scroll);
            if lx < 0.0 || ly < 0.0 {
                return None;
            }
            let col = (lx / t.finder_cell_w) as usize;
            if col >= cols {
                return None;
            }
            (ly / t.finder_cell_h) as usize * cols + col
        }
        FinderView::List => {
            let ly = y - vp.y + scroll;
            if ly < 0.0 {
                return None;
            }
            (ly / t.finder_row_height) as usize
        }
    };
    (i < count).then_some(i)
}

/// The scroll that shows item `i` in full, moving as little as it can.
pub fn finder_scroll_to_show(t: &ThemeTokens, i: usize, scroll: f64, count: usize, view: FinderView, vp: Rect) -> f64 {
    if i >= count || vp.h <= 0.0 {
        return scroll;
    }
    let (top, height, margin) = match view {
        FinderView::Icon => (t.finder_grid_pad + (i / finder_columns(t, vp.w)) as f64 * t.finder_cell_h, t.finder_cell_h, t.finder_grid_pad),
        FinderView::List => (i as f64 * t.finder_row_height, t.finder_row_height, 0.0),
    };
    // The grid's margin comes into view with the item, so the first lands at
    // the very top and the last at the very bottom.
    let mut s = scroll;
    if top - margin < s {
        s = top - margin
    }
    if top + height + margin > s + vp.h {
        s = top + height + margin - vp.h
    }
    s.min(finder_max_scroll(t, count, view, vp)).max(0.0)
}

/// Where an arrow key moves the selection: a step across, a row down (a
/// column stride in the icon view); clamped, never wrapped.
pub fn finder_move(t: &ThemeTokens, from: Option<usize>, dx: i64, dy: i64, count: usize, view: FinderView, vp: Rect) -> Option<usize> {
    if count == 0 {
        return None;
    }
    let Some(i) = from else { return Some(0) };
    let stride = if view == FinderView::Icon { finder_columns(t, vp.w) as i64 } else { 1 };
    Some((i as i64 + dx + dy * stride).clamp(0, count as i64 - 1) as usize)
}

/// A fixed home folder for the PNG scene, the same on any machine.
pub fn finder_sample_entries() -> Vec<FinderEntry> {
    use FinderItemKind::*;
    let folders = ["Applications", "Desktop", "Documents", "Library", "Movies", "Music", "Pictures", "Public", "Sites"];
    let mut v: Vec<FinderEntry> = folders.iter().map(|n| FinderEntry::new(n, Folder)).collect();
    v.push(FinderEntry::new("TextEdit.app", Application));
    v.push(FinderEntry::sized("Read Me.txt", Document, 4_812));
    v.push(FinderEntry::sized("Aqua Notes.rtf", Document, 61_440));
    finder_sort(v)
}

#[cfg(test)]
mod tests {
    use super::*;
    use FinderItemKind::*;

    fn t() -> ThemeTokens {
        ThemeTokens::default()
    }

    /// Folders do not float to the top: one alphabetical run.
    #[test]
    fn sort_is_case_insensitive_and_interleaved() {
        let s = finder_sort(vec![FinderEntry::new("zebra.txt", Document), FinderEntry::new("Apps", Folder), FinderEntry::new("banana.txt", Document), FinderEntry::new("Cats", Folder)]);
        assert_eq!(s.iter().map(|e| e.name.as_str()).collect::<Vec<_>>(), ["Apps", "banana.txt", "Cats", "zebra.txt"]);
    }

    #[test]
    fn kind_detects_an_app_bundle() {
        assert_eq!(finder_kind("TextEdit.app", true), Application);
        assert_eq!(finder_kind("Documents", true), Folder);
        assert_eq!(finder_kind("notes.txt", false), Document);
        // A *file* called foo.app is a document.
        assert_eq!(finder_kind("foo.app", false), Document);
    }

    #[test]
    fn path_helpers() {
        assert_eq!(finder_join("/home/abyss", "Docs"), "/home/abyss/Docs");
        assert_eq!(finder_join("/", "usr"), "/usr");
        assert_eq!(finder_parent("/home/abyss/Docs").as_deref(), Some("/home/abyss"));
        assert_eq!(finder_parent("/home").as_deref(), Some("/"));
        assert_eq!(finder_parent("/"), None);
        assert_eq!(finder_display_name("/home/abyss/Docs"), "Docs");
        assert_eq!(finder_display_name("/home/abyss/"), "abyss");
        assert_eq!(finder_display_name("/"), "Computer");
    }

    #[test]
    fn format_bytes_and_status_text() {
        assert_eq!(finder_format_bytes(0), "0 bytes");
        assert_eq!(finder_format_bytes(1), "1 byte");
        assert_eq!(finder_format_bytes(4_812), "4.8 KB");
        assert_eq!(finder_format_bytes(61_440), "61.4 KB");
        assert_eq!(finder_format_bytes(39_600_000_000), "39.6 GB");
        assert_eq!(finder_status_text(1, 0), "1 item");
        assert_eq!(finder_status_text(12, 39_600_000_000), "12 items, 39.6 GB available");
    }

    #[test]
    fn type_select_wraps_and_is_case_insensitive() {
        let e = finder_sample_entries();
        let first = finder_type_select(&e, "m", None).unwrap();
        assert_eq!(e[first].name, "Movies");
        let second = finder_type_select(&e, "M", Some(first)).unwrap();
        assert_eq!(e[second].name, "Music");
        let third = finder_type_select(&e, "m", Some(second)).unwrap();
        assert_eq!(e[third].name, "Movies");
        assert_eq!(finder_type_select(&e, "q", None), None);
    }

    #[test]
    fn layout_splits_the_window() {
        let t = t();
        let l = finder_layout(&t, 520.0, 400.0, true);
        assert_eq!(l.toolbar.y, t.title_bar_height);
        assert_eq!(l.status.y + l.status.h, 400.0);
        assert_eq!(l.content.w, 520.0 - t.finder_scrollbar_width);
        assert!(l.content.y + l.content.h <= l.status.y + 0.001);
        assert!(l.up_arrow.y > l.track.y + l.track.h - 0.001);
        assert_eq!(l.down_arrow.y, l.up_arrow.y + l.up_arrow.h);
    }

    /// Without the toolbar the Finder is spatial (10.2): the well starts
    /// under the title bar, taller by the toolbar.
    #[test]
    fn layout_without_toolbar_is_spatial() {
        let t = t();
        let browser = finder_layout(&t, 520.0, 400.0, true);
        let spatial = finder_layout(&t, 520.0, 400.0, false);
        assert_eq!(spatial.toolbar.h, 0.0);
        assert_eq!(spatial.content.y, t.title_bar_height);
        assert_eq!(spatial.content.h - browser.content.h, t.finder_toolbar_height);
        assert_eq!(spatial.status, browser.status);
        assert_eq!(spatial.track.x, browser.track.x);
    }

    #[test]
    fn icon_grid_hit_test_round_trips() {
        let t = t();
        let vp = finder_item_viewport(&finder_layout(&t, 520.0, 400.0, true), FinderView::Icon);
        let count = 12;
        assert!(finder_columns(&t, vp.w) > 1);
        for i in 0..count {
            let r = finder_item_rect(&t, i, FinderView::Icon, vp, 0.0);
            assert_eq!(finder_index(&t, r.x + r.w / 2.0, r.y + r.h / 2.0, count, FinderView::Icon, vp, 0.0), Some(i));
        }
        let past = finder_item_rect(&t, count, FinderView::Icon, vp, 0.0);
        assert_eq!(finder_index(&t, past.x + 4.0, past.y + 4.0, count, FinderView::Icon, vp, 0.0), None);
    }

    #[test]
    fn list_hit_test_follows_scroll() {
        let t = t();
        let l = finder_layout(&t, 520.0, 400.0, true);
        let vp = finder_item_viewport(&l, FinderView::List);
        assert_eq!(vp.y, l.content.y + LIST_HEADER_HEIGHT);
        assert_eq!(finder_index(&t, vp.x + 10.0, vp.y + 1.0, 60, FinderView::List, vp, 5.0 * t.finder_row_height), Some(5));
    }

    #[test]
    fn scroll_to_show_reveals_offscreen_items() {
        let t = t();
        let vp = finder_item_viewport(&finder_layout(&t, 520.0, 400.0, true), FinderView::Icon);
        let count = 60;
        let max_s = finder_max_scroll(&t, count, FinderView::Icon, vp);
        assert!(max_s > 0.0);
        let s = finder_scroll_to_show(&t, count - 1, 0.0, count, FinderView::Icon, vp);
        assert!((s - max_s).abs() < 0.001);
        let last = finder_item_rect(&t, count - 1, FinderView::Icon, vp, s);
        assert!(last.y + last.h <= vp.y + vp.h + 0.001);
        assert_eq!(finder_scroll_to_show(&t, 0, s, count, FinderView::Icon, vp), 0.0);
        assert_eq!(finder_scroll_to_show(&t, 1, 0.0, count, FinderView::Icon, vp), 0.0);
    }

    #[test]
    fn arrow_motion_steps_rows_and_clamps() {
        let t = t();
        let vp = finder_item_viewport(&finder_layout(&t, 520.0, 400.0, true), FinderView::Icon);
        let cols = finder_columns(&t, vp.w);
        let count = 12;
        assert_eq!(finder_move(&t, None, 1, 0, count, FinderView::Icon, vp), Some(0));
        assert_eq!(finder_move(&t, Some(0), 0, 1, count, FinderView::Icon, vp), Some(cols));
        assert_eq!(finder_move(&t, Some(0), 0, 1, count, FinderView::List, vp), Some(1));
        assert_eq!(finder_move(&t, Some(0), -1, 0, count, FinderView::Icon, vp), Some(0));
        assert_eq!(finder_move(&t, Some(count - 1), 0, 1, count, FinderView::Icon, vp), Some(count - 1));
    }

    #[test]
    fn read_directory_sorts_and_hides_dotfiles() {
        let dir = std::env::temp_dir().join(format!("finder.{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(dir.join("Alpha")).unwrap();
        std::fs::create_dir_all(dir.join("TextEdit.app")).unwrap();
        std::fs::write(dir.join("beta.txt"), vec![b'A'; 1500]).unwrap();
        std::fs::write(dir.join(".hidden"), "abc").unwrap();
        let d = dir.to_str().unwrap();
        let e = read_directory(d, false);
        assert_eq!(e.iter().map(|e| e.name.as_str()).collect::<Vec<_>>(), ["Alpha", "beta.txt", "TextEdit.app"], "alphabetical, folders interleaved, dot-file hidden");
        assert_eq!((e[0].kind, e[1].kind, e[2].kind), (FinderItemKind::Folder, FinderItemKind::Document, FinderItemKind::Application));
        assert_eq!(e[1].size, 1500);
        assert_eq!(read_directory(d, true).len(), 4, "shown when asked for");
        assert!(read_directory(&format!("{d}/nope"), false).is_empty(), "an unreadable path lists as empty");
        let _ = std::fs::remove_dir_all(&dir);
    }
}
