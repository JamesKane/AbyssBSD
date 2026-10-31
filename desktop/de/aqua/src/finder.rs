//! The Finder (Finder.swift): the file browser in Jaguar dress, an ordinary
//! toplevel application. The 10.2 Finder is a *browser* by default (a
//! toolbar with Back and a view switch, folders opening in place); the
//! title bar's pill hides the toolbar, and that is what makes it
//! **spatial**: each folder its own window, a folder that already has one
//! raised instead of opened twice.
//!
//! One process owns every window: `FinderApp` holds them and routes open,
//! raise and close; each `FinderWindow` is one directory's view. The
//! geometry is FinderModel's, so paint and hit-test agree.
//!
//! The Mac's verbs: **Return renames**, ⌘O or ⌘↓ (or a double-click) opens,
//! ⌘⇧N makes a folder and renames it, ⌘D duplicates, ⌘C ⌘X ⌘V go through
//! the system clipboard, ⌘⌫ moves to the Trash (never an unlink).
//!
//! The `finder` domain: `view` (icon, list), `show_hidden`, `toolbar` (false
//! is spatial, remembered). It opens in `$ABYSS_FINDER_DIR`, else `$HOME`,
//! else "/".

use crate::commands::key_equivalent_of;
use crate::context_menu::open_context_menu;
use crate::desktop_icons::draw_finder_icon;
use crate::finder_commands::{context, finder_menu_bar, FinderVerb};
use crate::finder_model::*;
use crate::finder_ops::*;
use crate::finder_picker::{self as picker, finder_activation, FinderActivation};
use crate::launcher;
use crate::live_menu::LiveMenu;
use crate::scroll::thumb_rect;
use crate::toolkit::Toolkit;
use crate::undo::{UndoEntry, UndoStack};
use aquadraw::canvas::{segment_rects, Arrow, Canvas, Paint};
use aquadraw::chrome::{chrome_hit, window_chrome, ChromeEdge, ChromeHit, Gadget};
use aquadraw::draw::paint_window_chrome;
use aquadraw::drawlist::{DrawState, Role};
use aquadraw::runner::Rect;
use aquadraw::text::Style;
use menu_model::{Command, CommandResult, Enablement, MenuBarModel};
use menu_wire::{MenuProvider, MenuService};
use std::cell::{Cell, RefCell};
use std::collections::{BTreeMap, HashMap};
use std::rc::{Rc, Weak};
use std::time::Instant;
use surface::clipboard::mime;
use surface::{Display, KeyEvent, KeyModifiers, KeySym, PopupDelegate, RenderTarget, ResizeEdge, Window, WindowDelegate};

const BTN_LEFT: u32 = 0x110;
const BTN_RIGHT: u32 = 0x111;
const DOUBLE_CLICK_MS: u128 = 450;

/// Everything the painter needs: a value, so the PNG scene paints a fixed
/// listing and the live window the real one.
#[derive(Clone, Debug)]
pub struct FinderState {
    pub path: String,
    pub entries: Vec<FinderEntry>,
    pub selection: Option<usize>,
    pub scroll: f64,
    pub view: FinderView,
    pub can_go_back: bool,
    pub free_bytes: u64,
    pub back_pressed: bool,
    /// Shown: browser mode; hidden: spatial.
    pub toolbar_visible: bool,
    /// While an item's name is edited in place.
    pub edit: Option<FinderEdit>,
    /// A portal's picker says what the window is for.
    pub picker_title: Option<String>,
}

impl FinderState {
    pub fn new(path: &str, entries: Vec<FinderEntry>) -> FinderState {
        FinderState { path: path.into(), entries, selection: None, scroll: 0.0, view: FinderView::Icon, can_go_back: false, free_bytes: 0, back_pressed: false, toolbar_visible: true, edit: None, picker_title: None }
    }
}

/// An inline rename: which item, the text so far, and how many leading
/// characters are still selected. It opens with the base name selected
/// (the extension left out), so what is typed first replaces the name.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct FinderEdit {
    pub index: usize,
    pub text: String,
    pub selected_prefix: usize,
}

impl FinderEdit {
    pub fn renaming(index: usize, name: &str) -> FinderEdit {
        FinderEdit { index, text: name.into(), selected_prefix: finder_split_extension(name).0.chars().count() }
    }

    /// Replace the selection with `typed`, or append with none.
    pub fn typing(&self, typed: &str) -> FinderEdit {
        let rest: String = self.text.chars().skip(self.selected_prefix).collect();
        let text = if self.selected_prefix > 0 { format!("{typed}{rest}") } else { format!("{}{typed}", self.text) };
        FinderEdit { index: self.index, text, selected_prefix: 0 }
    }

    /// Backspace: the selection if there is one, else a character.
    pub fn deleting_backward(&self) -> FinderEdit {
        let text = if self.selected_prefix > 0 {
            self.text.chars().skip(self.selected_prefix).collect()
        } else {
            let mut t = self.text.clone();
            t.pop();
            t
        };
        FinderEdit { index: self.index, text, selected_prefix: 0 }
    }
}

pub fn finder_kind_label(kind: FinderItemKind) -> &'static str {
    match kind {
        FinderItemKind::Folder => "Folder",
        FinderItemKind::Application => "Application",
        FinderItemKind::Document => "Document",
        FinderItemKind::Disk => "Volume",
    }
}

// MARK: painting

fn width(c: &mut Canvas, s: &str, size: f64) -> f64 {
    c.text_width(s, size, Style::Regular, Role::Interface)
}

fn left(c: &mut Canvas, s: &str, x: f64, baseline: f64, color: aquadraw::color::Color, size: f64) {
    c.text_left(s, x, baseline, color, size, Style::Regular, Role::Interface)
}

/// Shorten with an ellipsis until it fits.
fn truncated(c: &mut Canvas, s: &str, max_width: f64, size: f64) -> String {
    if max_width <= 0.0 || width(c, s, size) <= max_width {
        return s.into();
    }
    let mut out: Vec<char> = s.chars().collect();
    while !out.is_empty() && width(c, &format!("{}…", out.iter().collect::<String>()), size) > max_width {
        out.pop();
    }
    format!("{}…", out.into_iter().collect::<String>())
}

/// A Finder window, and its layout: the truth for paint and hit-test.
pub fn paint_finder(c: &mut Canvas, w: f64, h: f64, s: &FinderState) -> FinderLayout {
    let t = c.theme.tokens.clone();
    let name = finder_display_name(&s.path);
    paint_window_chrome(c.runner, c.theme, c.cr, w, h, s.picker_title.as_deref().unwrap_or(&name), false, true);
    let l = finder_layout(&t, w, h, s.toolbar_visible);
    // The folder's proxy icon left of the centred title, measured as the
    // title is drawn: the chrome role, in its weight.
    let tw = c.text_width(&name, t.chrome_title_size, if t.title_bold { Style::Bold } else { Style::Regular }, Role::Chrome);
    draw_finder_icon(c, &FinderEntry::new("", FinderItemKind::Folder), Rect::new(w / 2.0 - tw / 2.0 - 19.0, (t.title_bar_height - 14.0) / 2.0, 14.0, 14.0));
    if l.toolbar.h > 0.0 {
        c.paint_simple("finder.toolbar", l.toolbar, DrawState::NORMAL);
        let mut st = if s.back_pressed && s.can_go_back { DrawState::PRESSED } else { DrawState::NORMAL };
        if !s.can_go_back {
            st = DrawState(st.0 | DrawState::DISABLED.0)
        }
        c.paint_simple("finder.back", l.back_button, st);
        let selected = if s.view == FinderView::Icon { 0 } else { 1 };
        c.segmented_control(l.view_control, &["", ""], selected);
        c.paint_simple("finder.viewswitch", l.view_control, if selected == 1 { DrawState::SELECTED } else { DrawState::NORMAL });
    }
    let vp = finder_item_viewport(&l, s.view);
    let count = s.entries.len();
    let content_h = finder_content_height(&t, count, s.view, vp);
    let max_scroll = (content_h - vp.h).max(0.0);
    let scroll = s.scroll.clamp(0.0, max_scroll);
    c.paint_simple("listview", l.content, DrawState::NORMAL);
    if s.view == FinderView::List {
        paint_list_header(c, &l)
    }
    c.cr.save();
    c.cr.rectangle(vp.x, vp.y, vp.w, vp.h);
    c.cr.clip();
    for (i, e) in s.entries.iter().enumerate() {
        let cell = finder_item_rect(&t, i, s.view, vp, scroll);
        if cell.y + cell.h < vp.y || cell.y > vp.y + vp.h {
            continue;
        }
        let editing = s.edit.as_ref().filter(|x| x.index == i);
        match s.view {
            FinderView::Icon => paint_icon_cell(c, e, cell, s.selection == Some(i), editing),
            FinderView::List => paint_list_row(c, e, cell, s.selection == Some(i), editing),
        }
    }
    c.cr.restore();
    c.paint_simple("finder.welledge", Rect::new(l.content.x, l.content.y, l.content.w, 1.0), DrawState::NORMAL);
    c.scroll_track(l.track);
    if let Some(th) = thumb_rect(l.track, scroll, vp.h, content_h) {
        c.scroll_thumb(th)
    }
    c.scroll_arrow(l.up_arrow, Arrow::Up, scroll > 0.5);
    c.scroll_arrow(l.down_arrow, Arrow::Down, scroll < max_scroll - 0.5);
    c.paint_simple("finder.status", l.status, DrawState::NORMAL);
    let k = t.body_text.with_a(0.75);
    c.text(&finder_status_text(count, s.free_bytes), l.status.x + l.status.w / 2.0, l.status.y + l.status.h / 2.0, k, 10.0, Style::Regular, Role::Interface);
    l
}

/// Name, Size and Kind columns of a row (or the header).
fn list_columns(row: Rect) -> [Rect; 3] {
    let (size_w, kind_w) = (70.0, 90.0);
    let name_w = (row.w - size_w - kind_w).max(60.0);
    [Rect::new(row.x, row.y, name_w, row.h), Rect::new(row.x + name_w, row.y, size_w, row.h), Rect::new(row.x + name_w + size_w, row.y, kind_w, row.h)]
}

fn paint_list_header(c: &mut Canvas, l: &FinderLayout) {
    let hdr = Rect::new(l.content.x, l.content.y, l.content.w, LIST_HEADER_HEIGHT);
    c.paint_simple("finder.header", hdr, DrawState::NORMAL);
    let cols = list_columns(hdr);
    for col in &cols[1..] {
        c.paint("finder.header.divider", hdr, Paint { parameters: &[("x", col.x - hdr.x)], ..Paint::default() })
    }
    let k = c.theme.tokens.body_text.with_a(0.8);
    for (col, title) in cols.iter().zip(["Name", "Size", "Kind"]) {
        left(c, title, col.x + 6.0, hdr.y + hdr.h - 5.0, k, 10.0)
    }
}

fn paint_icon_cell(c: &mut Canvas, e: &FinderEntry, cell: Rect, selected: bool, editing: Option<&FinderEdit>) {
    let t = c.theme.tokens.clone();
    let size = t.finder_icon_size;
    let icon = Rect::new(cell.x + (cell.w - size) / 2.0, cell.y + 4.0, size, size);
    if selected {
        // Jaguar's soft blue wash on the selected icon.
        c.paint_simple("finder.selection", icon, DrawState::NORMAL)
    }
    draw_finder_icon(c, e, icon);
    if let Some(ed) = editing {
        let tw = width(c, &ed.text, 11.0);
        let fw = (tw + 16.0).min(cell.w + 16.0).max(46.0);
        return name_field(c, Rect::new(cell.x + cell.w / 2.0 - fw / 2.0, icon.y + size + 2.0, fw, 16.0), ed, 11.0);
    }
    let label = truncated(c, &e.name, cell.w - 8.0, 11.0);
    let tw = width(c, &label, 11.0);
    let ly = icon.y + size + 4.0;
    if selected {
        c.paint_simple("iconlabel.selected", Rect::new(cell.x + cell.w / 2.0 - tw / 2.0 - 4.0, ly, tw + 8.0, 14.0), DrawState::NORMAL)
    }
    c.text(&label, cell.x + cell.w / 2.0, ly + 7.0, if selected { t.menu_text_on_highlight } else { t.body_text }, 11.0, Style::Regular, Role::Interface)
}

fn paint_list_row(c: &mut Canvas, e: &FinderEntry, row: Rect, selected: bool, editing: Option<&FinderEdit>) {
    let t = c.theme.tokens.clone();
    if selected {
        c.paint_simple("listview.selection", row, DrawState::NORMAL)
    }
    let fg = if selected { t.menu_text_on_highlight } else { t.body_text };
    let cols = list_columns(row);
    let side = t.finder_list_icon;
    let icon = Rect::new(cols[0].x + 4.0, row.y + (row.h - side) / 2.0, side, side);
    draw_finder_icon(c, e, icon);
    let baseline = row.y + row.h - 5.0;
    let name_x = icon.x + side + 5.0;
    let room = cols[0].w - (name_x - cols[0].x) - 6.0;
    if let Some(ed) = editing {
        let fw = room.min(width(c, &ed.text, 11.0) + 16.0).max(60.0);
        name_field(c, Rect::new(name_x - 2.0, row.y + 1.0, fw, row.h - 2.0), ed, 11.0)
    } else {
        let name = truncated(c, &e.name, room, 11.0);
        left(c, &name, name_x, baseline, fg, 11.0)
    }
    let size = if e.is_container() || e.kind == FinderItemKind::Application { "--".into() } else { finder_format_bytes(e.size) };
    left(c, &size, cols[1].x + 6.0, baseline, fg, 11.0);
    left(c, finder_kind_label(e.kind), cols[2].x + 6.0, baseline, fg, 11.0)
}

/// The rename field: a white well and its focus ring, the selected prefix
/// on the highlight, a caret at the end.
fn name_field(c: &mut Canvas, r: Rect, ed: &FinderEdit, size: f64) {
    let t = c.theme.tokens.clone();
    let inset = 4.0;
    let shown = truncated(c, &ed.text, r.w - 2.0 * inset - 2.0, size);
    let selected: String = shown.chars().take(ed.selected_prefix).collect();
    let sel_w = if ed.selected_prefix > 0 { width(c, &selected, size) } else { 0.0 };
    c.paint("finder.namefield", r, Paint { state: if ed.selected_prefix > 0 { DrawState::SELECTED } else { DrawState::NORMAL }, parameters: &[("sel", sel_w)], ..Paint::default() });
    left(c, &shown, r.x + inset, r.y + r.h - 4.0, t.field_text, size);
    if ed.selected_prefix > 0 {
        left(c, &selected, r.x + inset, r.y + r.h - 4.0, t.menu_text_on_highlight, size)
    }
    let caret = (r.x + inset + width(c, &shown, size) + 1.0).min(r.x + r.w - 3.0);
    c.paint("finder.namefield.caret", r, Paint { parameters: &[("caret", caret - r.x)], ..Paint::default() })
}

fn log(msg: &str) {
    eprintln!("Finder: {msg}")
}

/// Where a Finder window opens: `$ABYSS_FINDER_DIR`, else `$HOME`, else "/".
pub fn start_directory() -> String {
    ["ABYSS_FINDER_DIR", "HOME"].iter().find_map(|v| std::env::var(v).ok().filter(|s| !s.is_empty())).unwrap_or_else(|| "/".into())
}

fn home_directory() -> String {
    std::env::var("HOME").ok().filter(|s| !s.is_empty()).unwrap_or_else(|| "/".into())
}

fn applications_directory() -> String {
    finder_join(&home_directory(), "Applications")
}

/// Empty the Trash: the same from any window, or from none.
fn empty_trash() -> CommandResult {
    let (removed, failed) = finder_empty_trash();
    log(&format!("emptied the Trash ({removed} removed, {failed} failed)"));
    if failed == 0 { CommandResult::Ok(Some(format!("{removed} removed"))) } else { CommandResult::Refused(format!("{failed} items could not be removed")) }
}

fn refused(why: &str) -> CommandResult {
    CommandResult::Refused(why.into())
}

// MARK: the application

/// Owns every window and the mode they share.
pub struct FinderApp {
    me: Weak<FinderApp>,
    pub display: Rc<Display>,
    toolkit: Rc<Toolkit>,
    windows: RefCell<Vec<Rc<FinderWindow>>>,
    size: (i32, i32),
    /// Browser (toolbar) or spatial: windows share it, and it is remembered.
    toolbar_visible: Cell<bool>,
    /// What we last put on the clipboard, and whether it was a cut: a cache,
    /// since a cut has no representation on the wire.
    clipboard: RefCell<Option<(String, bool)>>,
    /// False when something else hosts the Finder (the desktop must outlive
    /// every window it opens).
    quits_with_last_window: bool,
    menu_service: RefCell<Option<MenuService>>,
    service_name: Option<String>,
    changed_pending: Cell<bool>,
    /// The window a command from outside means: the one the compositor last
    /// said was active.
    key_window: RefCell<Weak<FinderWindow>>,
}

/// The Finder's vocabulary as a menu service sees it.
struct Provider<'a>(&'a FinderApp);

impl MenuProvider for Provider<'_> {
    /// Undo and Redo named for what the key window would undo (§6.3).
    fn menu_model(&self) -> MenuBarModel {
        let model = finder_menu_bar();
        match self.0.target_window() {
            Some(w) => model.retitled(&HashMap::from([(FinderVerb::Undo.raw().to_string(), w.undo.undo_title()), (FinderVerb::Redo.raw().to_string(), w.undo.redo_title())])),
            None => model,
        }
    }
    fn menu_validate(&self, c: &Command) -> Enablement {
        FinderVerb::from_raw(&c.verb).map_or(Enablement::Disabled(format!("the Finder has no verb {}", c.verb)), |v| self.0.validate(v))
    }
    fn menu_perform(&mut self, c: &Command, arguments: &BTreeMap<String, String>) -> CommandResult {
        FinderVerb::from_raw(&c.verb).map_or(CommandResult::Refused(format!("the Finder has no verb {}", c.verb)), |v| self.0.perform(v, arguments))
    }
}

impl FinderApp {
    pub fn new(display: &Rc<Display>, toolkit: &Rc<Toolkit>, size: (i32, i32), quits_with_last_window: bool) -> Rc<FinderApp> {
        let config = pool_config::load("finder", None).unwrap_or_default();
        // Not when this Finder is a portal's picker: a vocabulary would let
        // any process on the plane choose for the person.
        let service = if picker::is_picking() {
            None
        } else {
            let name = menu_wire::service_name("Finder", std::process::id() as i32);
            match MenuService::new(&name) {
                Ok(s) => {
                    log(&format!("menus on {name}"));
                    Some(s)
                }
                Err(e) => {
                    log(&format!("no menu service ({e})"));
                    None
                }
            }
        };
        let app = Rc::new_cyclic(|me| FinderApp {
            me: me.clone(),
            display: display.clone(),
            toolkit: toolkit.clone(),
            windows: RefCell::default(),
            size,
            toolbar_visible: Cell::new(config.bool("finder", "toolbar").unwrap_or(true)),
            clipboard: RefCell::new(None),
            quits_with_last_window,
            service_name: service.as_ref().map(|s| s.name.clone()),
            menu_service: RefCell::new(service),
            changed_pending: Cell::new(false),
            key_window: RefCell::new(Weak::new()),
        });
        if let Some(fd) = app.menu_service.borrow().as_ref().map(|s| s.fd()) {
            let me = app.me.clone();
            display.add_fd(fd, move || {
                if let Some(a) = me.upgrade() {
                    a.serve()
                }
            });
        }
        app
    }

    /// Answer one request. The service is out of its cell while it runs,
    /// so a command that changes the menus says so after.
    fn serve(&self) {
        let svc = self.menu_service.borrow_mut().take();
        let Some(mut svc) = svc else { return };
        svc.service_readable(&mut Provider(self));
        if self.changed_pending.take() {
            svc.changed()
        }
        *self.menu_service.borrow_mut() = Some(svc);
    }

    /// What the menus say may have changed: Undo's title, most often.
    fn menus_changed(&self) {
        match &mut *self.menu_service.borrow_mut() {
            Some(s) => s.changed(),
            None => self.changed_pending.set(true),
        }
    }

    /// Where its menus are published, if anywhere.
    pub fn menu_service_name(&self) -> Option<String> {
        self.service_name.clone()
    }

    pub fn toolbar_visible(&self) -> bool {
        self.toolbar_visible.get()
    }

    pub fn window_count(&self) -> usize {
        self.windows.borrow().len()
    }

    fn target_window(&self) -> Option<Rc<FinderWindow>> {
        self.key_window.borrow().upgrade().or_else(|| self.windows.borrow().last().cloned())
    }

    fn window_became_key(&self, w: &Rc<FinderWindow>) {
        if Weak::ptr_eq(&self.key_window.borrow(), &Rc::downgrade(w)) {
            return;
        }
        *self.key_window.borrow_mut() = Rc::downgrade(w);
        self.menus_changed()
    }

    /// Verbs that need no window: the desktop's Finder often has none.
    fn validate(&self, v: FinderVerb) -> Enablement {
        if let Some(w) = self.target_window() {
            return w.validate(v);
        }
        if !v.is_implemented() {
            return Enablement::Disabled("the Finder cannot do this yet".into());
        }
        match v {
            FinderVerb::EmptyTrash if finder_trash_contents().is_empty() => Enablement::Disabled("the Trash is empty".into()),
            FinderVerb::EmptyTrash | FinderVerb::NewWindow => Enablement::Enabled,
            _ => Enablement::Disabled("no Finder window is open".into()),
        }
    }

    fn perform(&self, v: FinderVerb, arguments: &BTreeMap<String, String>) -> CommandResult {
        if let Some(w) = self.target_window() {
            return w.perform(v, arguments);
        }
        if let Enablement::Disabled(why) = self.validate(v) {
            return CommandResult::Refused(why);
        }
        match v {
            FinderVerb::EmptyTrash => empty_trash(),
            FinderVerb::NewWindow => {
                self.open_folder(&start_directory());
                CommandResult::Ok(Some(start_directory()))
            }
            _ => refused("no Finder window is open"),
        }
    }

    /// Put a path on the **system** clipboard (a `file://` URI and the bare
    /// path's types), and remember whether it was a cut.
    fn set_clipboard(&self, path: &str, cut: bool) {
        *self.clipboard.borrow_mut() = Some((path.into(), cut));
        let what = if cut { "cut" } else { "copied" };
        let offered = self.display.clipboard().is_some_and(|c| c.write(finder_file_uri(path).into_bytes(), &[mime::URI_LIST, mime::TEXT]));
        log(&format!("{what} {path}{}", if offered { " — offered to the desktop" } else { " — locally only" }))
    }

    fn has_clipboard(&self) -> bool {
        self.clipboard.borrow().is_some() || self.display.clipboard().is_some_and(|c| c.offers(&[mime::URI_LIST, mime::TEXT]))
    }

    /// What to paste: **the seat's**, since somebody else may have copied
    /// since; our cache answers for our own copy (reading that off the wire
    /// would be asking ourselves) and carries whether it was a cut.
    fn clipboard_path(&self) -> Option<(String, bool)> {
        let ours = self.clipboard.borrow().clone();
        let Some(clip) = self.display.clipboard() else { return ours };
        if clip.owns_selection() {
            return ours;
        }
        match clip.read(&[mime::URI_LIST, mime::TEXT]).and_then(|(_, b)| finder_dropped_path(&b)) {
            Some(p) if ours.as_ref().is_some_and(|(o, _)| *o == p) => ours,
            Some(p) => Some((p, false)),
            None => ours,
        }
    }

    /// Every window showing `directory` reads it again.
    fn refresh_windows(&self, directory: &str, selecting: Option<&str>) {
        let ws: Vec<Rc<FinderWindow>> = self.windows.borrow().iter().filter(|w| w.directory() == directory).cloned().collect();
        for w in ws {
            w.refresh(selecting)
        }
    }

    /// The window it starts with; false without a surface.
    pub fn open_initial_window(&self, path: Option<&str>) -> bool {
        let path = path.map_or_else(start_directory, String::from);
        let Some(w) = FinderWindow::new(self, &path) else { return false };
        self.windows.borrow_mut().push(w);
        self.accept_drops();
        true
    }

    /// Drops on any of our windows: one handler for the connection, the
    /// window found from the surface the drag entered.
    fn accept_drops(&self) {
        let Some(clip) = self.display.clipboard() else { return };
        *clip.accepted_drag_types.borrow_mut() = vec![mime::URI_LIST.into(), mime::TEXT.into()];
        let (me, cw) = (self.me.clone(), Rc::downgrade(&clip));
        clip.on_drop(move |_, bytes, _, _| {
            let (Some(app), Some(c)) = (me.upgrade(), cw.upgrade()) else { return };
            let Some(s) = finder_dropped_path(bytes).filter(|p| finder_exists(p)) else { return };
            let surface = c.drag_position().0;
            let target = app.windows.borrow().iter().find(|w| Some(w.surface()) == surface).cloned();
            if let Some(w) = target {
                w.receive_drop(&s)
            }
        });
    }

    /// Open a window on `path`, or raise the one it has: what the desktop
    /// calls on a double-click.
    pub fn open_folder(&self, path: &str) {
        let existing = self.windows.borrow().iter().find(|w| w.directory() == path).cloned();
        if let Some(w) = existing {
            log(&format!("raised {path}"));
            return w.raise();
        }
        let Some(w) = FinderWindow::new(self, path) else { return };
        self.windows.borrow_mut().push(w);
        log(&format!("new window {path} ({} open)", self.window_count()))
    }

    /// Close one; the last out ends the process, unless hosted.
    fn close(&self, w: &Rc<FinderWindow>) {
        self.windows.borrow_mut().retain(|x| !Rc::ptr_eq(x, w));
        if Weak::ptr_eq(&self.key_window.borrow(), &Rc::downgrade(w)) {
            *self.key_window.borrow_mut() = Weak::new();
            self.menus_changed()
        }
        w.tear_down();
        log(&format!("closed {} ({} open)", w.directory(), self.window_count()));
        if self.window_count() == 0 && self.quits_with_last_window {
            self.display.stop()
        }
    }

    /// A window switched mode: everywhere, and remembered.
    fn set_toolbar_visible(&self, visible: bool) {
        self.toolbar_visible.set(visible);
        let ws = self.windows.borrow().clone();
        for w in ws {
            w.apply_toolbar_visible(visible)
        }
        log(if visible { "toolbar shown (browser mode)" } else { "toolbar hidden (spatial mode)" });
        let mut config = pool_config::load("finder", None).unwrap_or_default();
        config.set_bool("finder", "toolbar", visible);
        let _ = config.store("finder", None);
    }
}

// MARK: the window

struct WinState {
    toolbar_visible: bool,
    path: String,
    entries: Vec<FinderEntry>,
    selection: Option<usize>,
    scroll: f64,
    view: FinderView,
    free_bytes: u64,
    back_stack: Vec<String>,
    layout: FinderLayout,
    pointer: (f64, f64),
    dragging_thumb: bool,
    thumb_grab_dy: f64,
    /// The row a press landed on, until it is a click or a drag.
    pressed_row: Option<usize>,
    press_at: (f64, f64),
    back_pressed: bool,
    last_click: Option<(usize, Instant)>,
    edit: Option<FinderEdit>,
    context: Option<Rc<LiveMenu>>,
}

pub struct FinderWindow {
    me: Weak<FinderWindow>,
    window: RefCell<Option<Rc<Window>>>,
    surface: Cell<Option<abyss_sys::wlc::Obj>>,
    app: Weak<FinderApp>,
    toolkit: Rc<Toolkit>,
    show_hidden: bool,
    state: RefCell<WinState>,
    /// Per window, held rather than owned (P10.5).
    undo: UndoStack,
}

impl FinderWindow {
    fn new(app: &FinderApp, path: &str) -> Option<Rc<FinderWindow>> {
        let config = pool_config::load("finder", None).unwrap_or_default();
        let w = Rc::new_cyclic(|me| FinderWindow {
            me: me.clone(),
            window: RefCell::new(None),
            surface: Cell::new(None),
            app: app.me.clone(),
            toolkit: app.toolkit.clone(),
            show_hidden: config.bool("finder", "show_hidden").unwrap_or(false),
            state: RefCell::new(WinState {
                toolbar_visible: app.toolbar_visible.get(),
                path: path.into(),
                entries: vec![],
                selection: None,
                scroll: 0.0,
                view: if config.string("finder", "view") == Some("list") { FinderView::List } else { FinderView::Icon },
                free_bytes: 0,
                back_stack: vec![],
                layout: FinderLayout::default(),
                pointer: (0.0, 0.0),
                dragging_thumb: false,
                thumb_grab_dy: 0.0,
                pressed_row: None,
                press_at: (0.0, 0.0),
                back_pressed: false,
                last_click: None,
                edit: None,
                context: None,
            }),
            undo: UndoStack::default(),
        });
        let pinned = std::env::var("AQUA_SCALE").ok().and_then(|s| s.parse::<i32>().ok()).filter(|v| *v > 0);
        let win = Window::new(&app.display, &finder_display_name(path), "org.abyssbsd.finder", app.size.0, app.size.1, pinned.unwrap_or(1), pinned.is_none(), Rc::downgrade(&w) as Weak<dyn WindowDelegate>)?;
        w.surface.set(Some(win.surface));
        // What Undo is called moves with this stack, and the bar is told.
        let a = app.me.clone();
        w.undo.on_change(move || {
            if let Some(a) = a.upgrade() {
                a.menus_changed()
            }
        });
        // Where this window's menus are (P10.3): bound to the surface, not
        // the app_id any client could claim.
        if let Some(name) = app.menu_service_name()
            && win.publish_menus(&name)
        {
            log(&format!("window publishes its menus at {name}"))
        }
        *w.window.borrow_mut() = Some(win);
        w.reload(None);
        Some(w)
    }

    fn window(&self) -> Option<Rc<Window>> {
        self.window.borrow().clone()
    }

    fn redraw(&self) {
        if let Some(w) = self.window() {
            w.set_needs_display()
        }
    }

    pub fn directory(&self) -> String {
        self.state.borrow().path.clone()
    }

    fn surface(&self) -> abyss_sys::wlc::Obj {
        self.surface.get().expect("a window has its surface")
    }

    fn is_spatial(&self) -> bool {
        !self.state.borrow().toolbar_visible
    }

    /// Bring it forward, by xdg-activation.
    fn raise(&self) {
        if !self.window().is_some_and(|w| w.activate()) {
            log("raise unavailable (no xdg-activation)")
        }
    }

    fn apply_toolbar_visible(&self, visible: bool) {
        let mut s = self.state.borrow_mut();
        if s.toolbar_visible == visible {
            return;
        }
        s.toolbar_visible = visible;
        s.scroll = 0.0;
        drop(s);
        self.redraw()
    }

    /// Read the directory again (after a file operation, maybe another
    /// window's), keeping `name` selected if it is still there.
    fn refresh(&self, name: Option<&str>) {
        let (keep, scroll) = {
            let s = self.state.borrow();
            (name.map(String::from).or_else(|| s.selection.and_then(|i| s.entries.get(i)).map(|e| e.name.clone())), s.scroll)
        };
        self.reload(keep.as_deref());
        {
            let max = self.max_scroll();
            self.state.borrow_mut().scroll = scroll.min(max);
        }
        self.reveal_selection();
        self.redraw()
    }

    fn tear_down(&self) {
        if let Some(w) = self.window.borrow_mut().take() {
            w.close()
        }
    }

    // MARK: navigation

    /// Read the directory; `name` stays selected (the folder just left).
    fn reload(&self, name: Option<&str>) {
        let path = self.directory();
        let entries = read_directory(&path, self.show_hidden);
        log(&format!("listed {path} ({} items)", entries.len()));
        {
            let mut s = self.state.borrow_mut();
            s.selection = name.and_then(|n| entries.iter().position(|e| e.name == n));
            s.free_bytes = statvfs_free(&path);
            s.entries = entries;
            s.scroll = 0.0;
        }
        self.reveal_selection();
        if let Some(w) = self.window() {
            w.set_title(&finder_display_name(&path))
        }
        self.redraw()
    }

    fn navigate(&self, dest: &str, selecting: Option<&str>) {
        {
            let mut s = self.state.borrow_mut();
            let from = std::mem::replace(&mut s.path, dest.into());
            s.back_stack.push(from);
        }
        log(&format!("opened {dest}"));
        self.reload(selecting)
    }

    fn go_back(&self) {
        let leaving = {
            let mut s = self.state.borrow_mut();
            let Some(prev) = s.back_stack.pop() else { return };
            let leaving = finder_display_name(&s.path);
            s.path = prev;
            leaving
        };
        log(&format!("back to {}", self.directory()));
        self.reload(Some(&leaving))
    }

    fn go_up(&self) {
        let path = self.directory();
        let Some(parent) = finder_parent(&path) else { return };
        if self.is_spatial() {
            if let Some(a) = self.app.upgrade() {
                a.open_folder(&parent)
            }
        } else {
            self.navigate(&parent, Some(&finder_display_name(&path)))
        }
    }

    /// A folder opens (in place, or its own window when spatial); a file is
    /// launched, or in a picker *chosen*.
    fn activate(&self, i: usize) {
        let Some(e) = self.state.borrow().entries.get(i).cloned() else { return };
        match finder_activation(&e, &self.directory(), picker::is_picking()) {
            FinderActivation::Choose(full) => {
                log(&format!("picked {full}"));
                picker::chose(&full)
            }
            FinderActivation::Launch(full) => log(&format!("{} ({full})", launcher::open(&full))),
            FinderActivation::Navigate(full) if self.is_spatial() => {
                if let Some(a) = self.app.upgrade() {
                    a.open_folder(&full)
                }
            }
            FinderActivation::Navigate(full) => self.navigate(&full, None),
        }
    }

    /// The pill: the toolbar, which is browser against spatial.
    fn toggle_toolbar(&self) {
        let v = !self.state.borrow().toolbar_visible;
        if let Some(a) = self.app.upgrade() {
            a.set_toolbar_visible(v)
        }
    }

    fn close_window(&self) {
        match (self.app.upgrade(), self.me.upgrade()) {
            (Some(a), Some(me)) => a.close(&me),
            _ => {
                if let Some(w) = self.window() {
                    w.close();
                    w.stop_display()
                }
            }
        }
    }

    // MARK: scrolling

    fn viewport(&self) -> Rect {
        let s = self.state.borrow();
        finder_item_viewport(&s.layout, s.view)
    }

    fn max_scroll(&self) -> f64 {
        let t = self.toolkit.theme.borrow().tokens.clone();
        let vp = self.viewport();
        let s = self.state.borrow();
        finder_max_scroll(&t, s.entries.len(), s.view, vp)
    }

    fn scroll_by(&self, dy: f64) {
        let max = self.max_scroll();
        let changed = {
            let mut s = self.state.borrow_mut();
            let old = s.scroll;
            s.scroll = (s.scroll + dy).clamp(0.0, max);
            s.scroll != old
        };
        if changed {
            self.redraw()
        }
    }

    fn reveal_selection(&self) {
        let t = self.toolkit.theme.borrow().tokens.clone();
        let vp = self.viewport();
        let mut s = self.state.borrow_mut();
        if let Some(i) = s.selection {
            s.scroll = finder_scroll_to_show(&t, i, s.scroll, s.entries.len(), s.view, vp)
        }
    }

    fn select(&self, i: Option<usize>) {
        {
            let mut s = self.state.borrow_mut();
            s.selection = i;
            if let Some(e) = i.and_then(|i| s.entries.get(i)) {
                log(&format!("selected {}", e.name))
            }
        }
        self.reveal_selection();
        self.redraw()
    }

    fn set_view(&self, v: FinderView) {
        {
            let mut s = self.state.borrow_mut();
            if s.view == v {
                return;
            }
            s.view = v;
            s.scroll = 0.0;
        }
        self.reveal_selection();
        log(&format!("view -> {}", if v == FinderView::Icon { "icon" } else { "list" }));
        self.redraw()
    }

    // MARK: file operations

    fn exists(&self, name: &str) -> bool {
        finder_exists(&finder_join(&self.directory(), name))
    }

    fn selected_entry(&self) -> Option<FinderEntry> {
        let s = self.state.borrow();
        s.selection.and_then(|i| s.entries.get(i)).cloned()
    }

    /// Every window on `dir` reads it again (this one when unhosted).
    fn refresh_all(&self, dir: &str, selecting: Option<&str>) {
        match self.app.upgrade() {
            Some(a) => a.refresh_windows(dir, selecting),
            None if dir == self.directory() => self.refresh(selecting),
            None => {}
        }
    }

    /// Move `src` to `dst` as an undo or redo: refused, with the reason, if
    /// the world has moved since (§6.3).
    fn undo_move(&self, src: &str, dst: &str) -> CommandResult {
        if !finder_exists(src) {
            return CommandResult::Refused(format!("{} is not where it was any more", finder_display_name(src)));
        }
        if finder_exists(dst) {
            return CommandResult::Refused(format!("something called {} is in the way", finder_display_name(dst)));
        }
        if !finder_rename_entry(src, dst) {
            return CommandResult::Refused(format!("could not move {} back", finder_display_name(src)));
        }
        log(&format!("moved {src} -> {dst}"));
        self.refresh_around(src, dst, Some(&finder_display_name(dst)));
        CommandResult::Ok(Some(dst.into()))
    }

    fn refresh_around(&self, a: &str, b: &str, selecting: Option<&str>) {
        let (pa, pb) = (finder_parent(a), finder_parent(b));
        let mut dirs: Vec<String> = [pa, pb.clone()].into_iter().flatten().collect();
        dirs.dedup();
        for d in dirs {
            self.refresh_all(&d, if Some(&d) == pb.as_ref() { selecting } else { None })
        }
    }

    /// Something moved from `a` to `b`: undo moves it back.
    fn push_move(&self, name: &str, a: &str, b: &str) {
        let (w1, w2) = (self.me.clone(), self.me.clone());
        let (a1, b1, a2, b2) = (a.to_string(), b.to_string(), a.to_string(), b.to_string());
        self.undo.push(UndoEntry::new(name, move || w1.upgrade().map_or(refused("the window has closed"), |w| w.undo_move(&b1, &a1)), move || w2.upgrade().map_or(refused("the window has closed"), |w| w.undo_move(&a2, &b2))));
    }

    /// Something was made at `made`: undo puts it in the Trash (never
    /// deletes it); redo takes it back out.
    fn push_creation(&self, name: &str, made: &str) {
        let trashed: Rc<RefCell<Option<String>>> = Rc::default();
        let (w1, w2, t1, t2, m1, m2, n) = (self.me.clone(), self.me.clone(), trashed.clone(), trashed, made.to_string(), made.to_string(), name.to_string());
        self.undo.push(UndoEntry::new(
            name,
            move || {
                let Some(w) = w1.upgrade() else { return refused("the window has closed") };
                if !finder_exists(&m1) {
                    return CommandResult::Refused(format!("{} is not there any more", finder_display_name(&m1)));
                }
                let Some(t) = finder_move_to_trash(&m1) else { return CommandResult::Refused(format!("could not move {} to the Trash", finder_display_name(&m1))) };
                log(&format!("undid {n}: {m1} -> {t}"));
                *t1.borrow_mut() = Some(t.clone());
                w.refresh_around(&m1, &m1, None);
                CommandResult::Ok(Some(t))
            },
            move || {
                let (Some(w), Some(t)) = (w2.upgrade(), t2.borrow().clone()) else { return refused("the window has closed") };
                w.undo_move(&t, &m2)
            },
        ));
    }

    /// ⌘⇧N: "untitled folder", straight into renaming it.
    fn new_folder(&self) -> CommandResult {
        let dir = self.directory();
        let name = finder_new_folder_name(|n| self.exists(n));
        let full = finder_join(&dir, &name);
        if !finder_create_directory(&full) {
            log(&format!("could not create {name} in {dir}"));
            return CommandResult::Refused(format!("could not create {name} in {dir}"));
        }
        log(&format!("new folder {full}"));
        self.push_creation("New Folder", &full);
        self.refresh_all(&dir, Some(&name));
        self.begin_rename();
        CommandResult::Ok(Some(full))
    }

    /// Return: edit the selected name in place.
    fn begin_rename(&self) {
        let Some(e) = self.selected_entry() else { return };
        let mut s = self.state.borrow_mut();
        s.edit = s.selection.map(|i| FinderEdit::renaming(i, &e.name));
        drop(s);
        self.redraw()
    }

    fn cancel_rename(&self) {
        if self.state.borrow_mut().edit.take().is_some() {
            self.redraw()
        }
    }

    fn commit_rename(&self) {
        let (e, old) = {
            let mut s = self.state.borrow_mut();
            let Some(e) = s.edit.take() else { return };
            let Some(old) = s.entries.get(e.index).map(|x| x.name.clone()) else {
                drop(s);
                return self.redraw();
            };
            (e, old)
        };
        let (dir, new) = (self.directory(), e.text);
        if new == old {
            return self.redraw();
        }
        if !finder_is_valid_name(&new) || self.exists(&new) {
            log(&format!("rename refused: '{new}' is taken or not a valid name"));
            return self.redraw();
        }
        let (from, to) = (finder_join(&dir, &old), finder_join(&dir, &new));
        if !finder_rename_entry(&from, &to) {
            log(&format!("rename failed: {old} -> {new}"));
            return self.redraw();
        }
        log(&format!("renamed {old} -> {new} in {dir}"));
        self.push_move("Rename", &from, &to);
        self.refresh_all(&dir, Some(&new))
    }

    /// ⌘D: a copy beside it ("Read Me copy.txt").
    fn duplicate_selection(&self) -> CommandResult {
        let Some(e) = self.selected_entry() else { return refused("nothing is selected") };
        let dir = self.directory();
        let name = finder_copy_name(&e.name, |n| self.exists(n));
        if !finder_copy_path(&finder_join(&dir, &e.name), &finder_join(&dir, &name)) {
            log(&format!("duplicate failed: {}", e.name));
            return CommandResult::Refused(format!("could not duplicate {}", e.name));
        }
        log(&format!("duplicated {} -> {name} in {dir}", e.name));
        self.push_creation("Duplicate", &finder_join(&dir, &name));
        self.refresh_all(&dir, Some(&name));
        CommandResult::Ok(Some(finder_join(&dir, &name)))
    }

    /// ⌘C, ⌘X.
    fn clip_selection(&self, cut: bool) -> CommandResult {
        let Some(e) = self.selected_entry() else { return refused("nothing is selected") };
        let full = finder_join(&self.directory(), &e.name);
        if let Some(a) = self.app.upgrade() {
            a.set_clipboard(&full, cut)
        }
        CommandResult::Ok(Some(full))
    }

    /// ⌘V: copy (or move, after a cut) the clipboard's item here.
    fn paste(&self) -> CommandResult {
        let Some(app) = self.app.upgrade() else { return refused("the clipboard is empty") };
        let Some((source, cut)) = app.clipboard_path() else { return refused("the clipboard is empty") };
        if !finder_exists(&source) {
            log(&format!("paste failed: {source} is gone"));
            *app.clipboard.borrow_mut() = None;
            return CommandResult::Refused(format!("{source} is gone"));
        }
        let dir = self.directory();
        let source_dir = finder_parent(&source).unwrap_or_default();
        let name = finder_paste_name(&finder_display_name(&source), |n| self.exists(n));
        let dest = finder_join(&dir, &name);
        let ok = if cut { finder_rename_entry(&source, &dest) } else { finder_copy_path(&source, &dest) };
        if !ok {
            log(&format!("paste failed: {source} -> {dest}"));
            return CommandResult::Refused(format!("could not paste {source} into {dir}"));
        }
        log(&format!("pasted {source} -> {dest}"));
        if cut {
            self.push_move("Move", &source, &dest);
            *app.clipboard.borrow_mut() = None;
            // A move empties the source's view too.
            if source_dir != dir {
                app.refresh_windows(&source_dir, None)
            }
        } else {
            self.push_creation("Paste", &dest)
        }
        app.refresh_windows(&dir, Some(&name));
        CommandResult::Ok(Some(dest))
    }

    /// ⌘⌫: to ~/.Trash, never an unlink.
    fn trash_selection(&self) -> CommandResult {
        let Some(e) = self.selected_entry() else { return refused("nothing is selected") };
        let dir = self.directory();
        let source = finder_join(&dir, &e.name);
        let Some(dest) = finder_move_to_trash(&source) else {
            log(&format!("could not move {source} to the Trash"));
            return CommandResult::Refused(format!("could not move {source} to the Trash"));
        };
        log(&format!("trashed {source} -> {dest}"));
        self.push_move("Move to Trash", &source, &dest);
        self.refresh_all(&dir, None);
        CommandResult::Ok(Some(dest))
    }

    /// A file dropped here: copied in, as ⌘V would.
    fn receive_drop(&self, path: &str) {
        let dir = self.directory();
        let name = finder_paste_name(&finder_display_name(path), |n| self.exists(n));
        let dest = finder_join(&dir, &name);
        if !finder_copy_path(path, &dest) {
            return log(&format!("drop failed: {path} -> {dest}"));
        }
        log(&format!("dropped {path} -> {dest}"));
        self.refresh_all(&dir, Some(&name))
    }

    /// Hand a file to the desktop: a press turned into movement. The serial
    /// is the press's, which the compositor checks.
    fn begin_drag(&self, i: usize) {
        self.state.borrow_mut().pressed_row = None;
        let Some(e) = self.state.borrow().entries.get(i).cloned() else { return };
        let Some(app) = self.app.upgrade() else { return };
        let Some(clip) = app.display.clipboard() else { return };
        let path = finder_join(&self.directory(), &e.name);
        let ok = clip.start_drag(finder_file_uri(&path).into_bytes(), self.surface(), app.display.last_pointer_serial(), &[mime::URI_LIST, mime::TEXT]);
        log(&if ok { format!("dragging {path}") } else { format!("could not start a drag of {path}") })
    }

    fn drag_thumb(&self, top: f64) {
        let t = self.toolkit.theme.borrow().tokens.clone();
        let vp = self.viewport();
        let max = self.max_scroll();
        let mut s = self.state.borrow_mut();
        let content_h = finder_content_height(&t, s.entries.len(), s.view, vp);
        let Some(th) = thumb_rect(s.layout.track, s.scroll, vp.h, content_h) else { return };
        let travel = s.layout.track.h - th.h;
        if travel > 0.0 {
            s.scroll = ((top - s.layout.track.y) / travel).clamp(0.0, 1.0) * max
        }
    }

    /// Right-click: select what is under the pointer, so the menu's
    /// commands mean it, and open the item's menu, or the folder's on
    /// nothing (P10.8).
    fn open_context(&self) {
        let old = self.state.borrow_mut().context.take();
        if let Some(m) = old {
            m.close_all()
        }
        if self.state.borrow().edit.is_some() {
            self.commit_rename()
        }
        let t = self.toolkit.theme.borrow().tokens.clone();
        let vp = self.viewport();
        let (px, py, hit) = {
            let s = self.state.borrow();
            (s.pointer.0, s.pointer.1, finder_index(&t, s.pointer.0, s.pointer.1, s.entries.len(), s.view, vp, s.scroll))
        };
        if !vp.contains(px, py) {
            return;
        }
        self.select(hit);
        let menu = context::menu(if hit.is_none() { &context::BACKGROUND } else { &context::ITEM }, &finder_menu_bar());
        let Some(win) = self.window() else { return };
        let (me, me2, me3) = (self.me.clone(), self.me.clone(), self.me.clone());
        let m = open_context_menu(
            &self.toolkit,
            &menu,
            if hit.is_none() { "folder" } else { "item" },
            &|c| match (me.upgrade(), FinderVerb::from_raw(&c.verb)) {
                (Some(w), Some(v)) => w.validate(v),
                _ => Enablement::Disabled("?".into()),
            },
            &log,
            |(w, h), lm| win.open_popup((px as i32, py as i32, 1, 1), w, h, Rc::downgrade(lm) as Weak<dyn PopupDelegate>),
            move |c| {
                let (Some(w), Some(v)) = (me2.upgrade(), FinderVerb::from_raw(&c.verb)) else { return };
                match w.perform(v, &BTreeMap::new()) {
                    CommandResult::Ok(x) => log(&format!("context chose {} ({}) → ok{}", c.title, c.verb, x.map_or(String::new(), |x| format!(" {x}")))),
                    CommandResult::Refused(why) => log(&format!("context chose {} ({}) → refused: {why}", c.title, c.verb)),
                }
            },
            move || {
                if let Some(w) = me3.upgrade() {
                    w.state.borrow_mut().context = None
                }
            },
        );
        self.state.borrow_mut().context = m;
    }

    /// ⌘S in a save picker: the folder on screen and the suggested name.
    fn save_here(&self) {
        let Some(name) = picker::save_name() else { return };
        let full = finder_join(&self.directory(), &name);
        log(&format!("picked {full}"));
        picker::chose(&full)
    }

    // MARK: commands (P10.1)

    /// Whether `v` can run in this window now, and why not: asked before a
    /// key runs one, and before the bar draws a menu.
    fn validate(&self, v: FinderVerb) -> Enablement {
        use FinderVerb::*;
        let no = |w: &str| Enablement::Disabled(w.into());
        if !v.is_implemented() {
            return no("the Finder cannot do this yet");
        }
        if matches!(v, Open | Duplicate | MoveToTrash | Cut | Copy) && self.selected_entry().is_none() {
            return no("nothing is selected");
        }
        match v {
            Undo => self.undo.undo_enablement(),
            Redo => self.undo.redo_enablement(),
            EmptyTrash if finder_trash_contents().is_empty() => no("the Trash is empty"),
            SaveHere if !picker::is_saving() => no("this is not a save dialog"),
            Paste if !self.app.upgrade().is_some_and(|a| a.has_clipboard()) => no("the clipboard is empty"),
            Back if self.state.borrow().back_stack.is_empty() => no("there is nowhere to go back to"),
            EnclosingFolder if finder_parent(&self.directory()).is_none() => no("this is the top of the disk"),
            Applications if !finder_is_directory(&applications_directory()) => no("there is no Applications folder"),
            _ => Enablement::Enabled,
        }
    }

    /// Run `v` here: the one place a Finder command is carried out, by key
    /// or by menu. **No catch-all**: a verb added does not compile until
    /// this says what it does.
    fn perform(&self, v: FinderVerb, arguments: &BTreeMap<String, String>) -> CommandResult {
        use FinderVerb::*;
        if let Enablement::Disabled(why) = self.validate(v) {
            log(&format!("refused {}: {why}", v.raw()));
            return CommandResult::Refused(why);
        }
        log(&format!("command {}", v.raw()));
        let win = self.window();
        match v {
            EmptyTrash => return empty_trash(),
            NewWindow => {
                if let Some(a) = self.app.upgrade() {
                    a.open_folder(&start_directory())
                }
                return CommandResult::Ok(Some(start_directory()));
            }
            NewFolder => return self.new_folder(),
            Open => {
                let s = self.state.borrow().selection;
                if let Some(i) = s {
                    self.activate(i)
                }
            }
            CloseWindow => self.close_window(),
            Duplicate => return self.duplicate_selection(),
            MoveToTrash => return self.trash_selection(),
            SaveHere => self.save_here(),
            Cut => return self.clip_selection(true),
            Copy => return self.clip_selection(false),
            Paste => return self.paste(),
            AsIcons => self.set_view(FinderView::Icon),
            AsList => self.set_view(FinderView::List),
            ToggleToolbar => self.toggle_toolbar(),
            Back => self.go_back(),
            EnclosingFolder => self.go_up(),
            // From a script this is the whole command; from a key it would
            // open a sheet to type into, and there is no sheet yet.
            GoToFolder => {
                let Some(dest) = arguments.get("path") else { return refused("Go to Folder needs a path, and there is no dialog to type one into yet") };
                if !finder_is_directory(dest) {
                    return CommandResult::Refused(format!("{dest} is not a folder"));
                }
                self.go(dest);
                return CommandResult::Ok(Some(dest.clone()));
            }
            Computer => self.go("/"),
            Home => self.go(&home_directory()),
            Applications => self.go(&applications_directory()),
            Undo => return self.undo.undo(),
            Redo => return self.undo.redo(),
            Minimize => {
                if let Some(w) = win {
                    w.minimize();
                }
            }
            Zoom => {
                if let Some(w) = win {
                    w.set_maximized(!w.is_maximized())
                }
            }
            // Unreachable: `validate` refuses them. Listed, so implementing
            // one is a visible edit here.
            About | Preferences | Hide | HideOthers | ShowAll | GetInfo | MakeAlias | Find | SelectAll | AsColumns | Help => return refused("the Finder cannot do this yet"),
        }
        CommandResult::Ok(None)
    }

    /// The Go menu: in place when browsing, its own window when spatial.
    fn go(&self, dest: &str) {
        if dest == self.directory() {
            return;
        }
        if self.is_spatial() {
            if let Some(a) = self.app.upgrade() {
                a.open_folder(dest)
            }
        } else {
            self.navigate(dest, None)
        }
    }

    /// A key that is a command; false when the model binds nothing to it.
    fn command_key(&self, e: &KeyEvent) -> bool {
        let model = finder_menu_bar();
        let Some(v) = key_equivalent_of(e).and_then(|k| model.verb_for(&k).and_then(FinderVerb::from_raw)) else { return false };
        self.perform(v, &BTreeMap::new());
        true
    }

    /// Keys while a rename is up: the field has the keyboard.
    fn edit_key(&self, e: &KeyEvent, ed: FinderEdit) {
        match e.keysym {
            KeySym::ENTER => self.commit_rename(),
            KeySym::ESCAPE => self.cancel_rename(),
            KeySym::BACKSPACE if !ed.text.is_empty() => {
                self.state.borrow_mut().edit = Some(ed.deleting_backward());
                self.redraw()
            }
            KeySym::BACKSPACE => {}
            _ if !e.text.is_empty() && !e.modifiers.contains(KeyModifiers::COMMAND) => {
                self.state.borrow_mut().edit = Some(ed.typing(&e.text));
                self.redraw()
            }
            _ => {}
        }
    }

    fn chrome_press(&self, w: &Window) -> bool {
        let (x, y) = self.state.borrow().pointer;
        let (sw, sh) = w.size();
        let t = self.toolkit.theme.borrow().tokens.clone();
        // The same rule every Aqua window uses (P9.4), but the pill is the
        // Finder's own: the toolbar, browser against spatial.
        match chrome_hit(&t, &window_chrome(&t, sw as f64, sh as f64, false), x, y) {
            ChromeHit::Gadget(Gadget::Pill) => self.toggle_toolbar(),
            ChromeHit::Gadget(Gadget::Close) => self.close_window(),
            ChromeHit::Gadget(Gadget::Minimize) => {
                w.minimize();
            }
            ChromeHit::Gadget(Gadget::Zoom) => w.set_maximized(!w.is_maximized()),
            ChromeHit::Gadget(Gadget::Depth) => {
                w.lower();
            }
            ChromeHit::Title => w.begin_move(),
            ChromeHit::Resize(e) => w.begin_resize(match e {
                ChromeEdge::Bottom => ResizeEdge::BOTTOM,
                ChromeEdge::BottomLeft => ResizeEdge::BOTTOM_LEFT,
                ChromeEdge::BottomRight => ResizeEdge::BOTTOM_RIGHT,
            }),
            ChromeHit::Content => return false,
        }
        true
    }

    /// A left press in the content: the toolbar, the scrollbar, or an item.
    fn content_press(&self) {
        let t = self.toolkit.theme.borrow().tokens.clone();
        let vp = self.viewport();
        let (x, y, l, toolbar, has_back, scroll, count, view) = {
            let s = self.state.borrow();
            (s.pointer.0, s.pointer.1, s.layout, s.toolbar_visible, !s.back_stack.is_empty(), s.scroll, s.entries.len(), s.view)
        };
        if toolbar {
            if l.back_button.contains(x, y) {
                if has_back {
                    self.state.borrow_mut().back_pressed = true;
                    self.redraw()
                }
                return;
            }
            let segs = segment_rects(l.view_control, 2);
            if segs[0].contains(x, y) {
                return self.set_view(FinderView::Icon);
            }
            if segs[1].contains(x, y) {
                return self.set_view(FinderView::List);
            }
        }
        // The scrollbar: the thumb, the arrows, a page toward the click.
        let content_h = finder_content_height(&t, count, view, vp);
        let thumb = thumb_rect(l.track, scroll, vp.h, content_h);
        if let Some(th) = thumb.filter(|th| th.contains(x, y)) {
            let mut s = self.state.borrow_mut();
            s.dragging_thumb = true;
            s.thumb_grab_dy = y - th.y;
            return;
        }
        if l.up_arrow.contains(x, y) {
            return self.scroll_by(-t.finder_row_height * 2.0);
        }
        if l.down_arrow.contains(x, y) {
            return self.scroll_by(t.finder_row_height * 2.0);
        }
        if l.track.contains(x, y) {
            if let Some(th) = thumb {
                self.scroll_by(if y < th.y { -vp.h * 0.9 } else { vp.h * 0.9 })
            }
            return;
        }
        // The well: a click selects, a second on the same item opens it.
        if !vp.contains(x, y) {
            return;
        }
        match finder_index(&t, x, y, count, view, vp, scroll) {
            Some(hit) => {
                let double = self.state.borrow().last_click.is_some_and(|(i, at)| i == hit && at.elapsed().as_millis() <= DOUBLE_CLICK_MS);
                if double {
                    // Not chained into a third click.
                    self.state.borrow_mut().last_click = None;
                    self.activate(hit)
                } else {
                    {
                        let mut s = self.state.borrow_mut();
                        s.last_click = Some((hit, Instant::now()));
                        // Armed, not started: motion decides click or drag.
                        s.pressed_row = Some(hit);
                        s.press_at = (x, y);
                    }
                    self.select(Some(hit))
                }
            }
            None => {
                self.state.borrow_mut().last_click = None;
                self.select(None)
            }
        }
    }
}

/// The volume's free space; 0 when it cannot be read.
fn statvfs_free(path: &str) -> u64 {
    abyss_sys::platform::free_space(path).unwrap_or(0)
}

impl WindowDelegate for FinderWindow {
    fn render(&self, _w: &Window, target: &RenderTarget) {
        let max = self.max_scroll();
        let state = {
            let mut s = self.state.borrow_mut();
            s.scroll = s.scroll.clamp(0.0, max);
            FinderState {
                path: s.path.clone(),
                entries: s.entries.clone(),
                selection: s.selection,
                scroll: s.scroll,
                view: s.view,
                can_go_back: !s.back_stack.is_empty(),
                free_bytes: s.free_bytes,
                back_pressed: s.back_pressed,
                toolbar_visible: s.toolbar_visible,
                edit: s.edit.clone(),
                picker_title: picker::is_picking().then(|| "Choose a File".into()),
            }
        };
        let l = self.toolkit.draw(target, |c, w, h| paint_finder(c, w, h, &state));
        self.state.borrow_mut().layout = l;
    }

    fn pointer_moved(&self, w: &Window, x: f64, y: f64) {
        let (dragging, grab, pressed, at) = {
            let mut s = self.state.borrow_mut();
            s.pointer = (x, y);
            (s.dragging_thumb, s.thumb_grab_dy, s.pressed_row, s.press_at)
        };
        if dragging {
            self.drag_thumb(y - grab);
            w.set_needs_display()
        }
        // **A drag begins when a press turns into movement**: four pixels,
        // so a click that wobbles is still a click.
        if let (Some(i), false) = (pressed, dragging)
            && (x - at.0).powi(2) + (y - at.1).powi(2) > 16.0
        {
            self.begin_drag(i)
        }
    }

    fn pointer_axis(&self, _w: &Window, axis: u32, value: f64) {
        if axis == 0 {
            self.scroll_by(value * 2.0)
        }
    }

    fn pointer_button(&self, w: &Window, button: u32, pressed: bool) {
        if button == BTN_RIGHT && pressed {
            return self.open_context();
        }
        if button != BTN_LEFT {
            return;
        }
        if pressed && self.state.borrow().edit.is_some() {
            self.commit_rename()
        }
        if !pressed {
            let (back, at_back) = {
                let mut s = self.state.borrow_mut();
                s.dragging_thumb = false;
                s.pressed_row = None;
                (std::mem::take(&mut s.back_pressed), s.layout.back_button.contains(s.pointer.0, s.pointer.1))
            };
            if back {
                if at_back {
                    self.go_back()
                }
                w.set_needs_display()
            }
            return;
        }
        if !self.chrome_press(w) {
            self.content_press()
        }
    }

    /// The compositor says which window is active: a command from outside
    /// the process goes to it.
    fn state_changed(&self, w: &Window) {
        if w.is_activated()
            && let (Some(a), Some(me)) = (self.app.upgrade(), self.me.upgrade())
        {
            a.window_became_key(&me)
        }
        w.set_needs_display()
    }

    /// Closing a picker is declining it: exit non-zero, so the portal can
    /// tell cancelled from chosen.
    fn should_close(&self, _w: &Window) {
        if picker::is_picking() {
            picker::cancelled()
        }
        self.close_window()
    }

    fn key_event(&self, _w: &Window, e: &KeyEvent) {
        if !e.pressed {
            return;
        }
        let edit = self.state.borrow().edit.clone();
        if let Some(ed) = edit {
            return self.edit_key(e, ed);
        }
        if e.modifiers.contains(KeyModifiers::COMMAND) && self.command_key(e) {
            return;
        }
        let t = self.toolkit.theme.borrow().tokens.clone();
        let vp = self.viewport();
        let (sel, count, view) = {
            let s = self.state.borrow();
            (s.selection, s.entries.len(), s.view)
        };
        let step = |dx, dy| finder_move(&t, sel, dx, dy, count, view, vp);
        match e.keysym {
            // The Mac's verbs: Return renames; ⌘O and ⌘↓ open.
            KeySym::ENTER => self.begin_rename(),
            KeySym::BACKSPACE => self.go_up(),
            // In a picker one Escape deselects and a second declines.
            KeySym::ESCAPE => {
                if picker::is_picking() && sel.is_none() {
                    picker::cancelled()
                }
                self.select(None)
            }
            KeySym::LEFT => self.select(step(-1, 0)),
            KeySym::RIGHT => self.select(step(1, 0)),
            KeySym::UP => self.select(step(0, -1)),
            KeySym::DOWN => self.select(step(0, 1)),
            KeySym::HOME => self.select((count > 0).then_some(0)),
            KeySym::END => self.select(count.checked_sub(1)),
            KeySym::PAGE_UP => self.scroll_by(-vp.h * 0.9),
            KeySym::PAGE_DOWN => self.scroll_by(vp.h * 0.9),
            KeySym::TAB => self.set_view(if view == FinderView::Icon { FinderView::List } else { FinderView::Icon }),
            // Type-ahead: a character jumps to the next matching name.
            _ if !e.text.is_empty() && e.text != " " && !e.modifiers.contains(KeyModifiers::COMMAND) && !e.modifiers.contains(KeyModifiers::CONTROL) => {
                let i = finder_type_select(&self.state.borrow().entries, &e.text, sel);
                if i.is_some() {
                    self.select(i)
                }
            }
            _ => {}
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::commands::key_equivalent;
    use menu_model::{Key, KeyEquivalent, Modifiers};

    #[test]
    fn a_rename_opens_with_the_base_selected_and_typing_replaces_it() {
        let e = FinderEdit::renaming(2, "Read Me.txt");
        assert_eq!(e.selected_prefix, 7);
        let t = e.typing("Notes");
        assert_eq!((t.text.as_str(), t.selected_prefix), ("Notes.txt", 0));
        assert_eq!(t.typing("!").text, "Notes.txt!");
        assert_eq!(e.deleting_backward().text, ".txt");
        assert_eq!(t.deleting_backward().text, "Notes.tx");
    }

    /// The keysym xkb delivers for a key equivalent: with Shift, a letter
    /// arrives uppercase.
    fn keysym(k: &KeyEquivalent) -> u32 {
        match k.key() {
            Key::Character(c) => (if k.modifiers().contains(Modifiers::SHIFT) { c.to_ascii_uppercase() } else { c }) as u32,
            Key::Backspace => KeySym::BACKSPACE,
            Key::ForwardDelete => KeySym::DELETE,
            Key::Up => KeySym::UP,
            Key::Down => KeySym::DOWN,
            Key::Left => KeySym::LEFT,
            Key::Right => KeySym::RIGHT,
            Key::Enter => KeySym::ENTER,
            Key::Escape => KeySym::ESCAPE,
            Key::Tab => KeySym::TAB,
        }
    }

    fn modifiers(k: &KeyEquivalent) -> KeyModifiers {
        let mut m = 0;
        for (mm, km) in [(Modifiers::COMMAND, KeyModifiers::COMMAND), (Modifiers::SHIFT, KeyModifiers::SHIFT), (Modifiers::OPTION, KeyModifiers::ALT), (Modifiers::CONTROL, KeyModifiers::CONTROL)] {
            if k.modifiers().contains(mm) {
                m |= km.0
            }
        }
        KeyModifiers(m)
    }

    /// **Walk the model and press every key in it**: each, as xkb delivers
    /// it, must come back as its own verb.
    #[test]
    fn every_finder_key_reaches_its_own_verb() {
        let model = finder_menu_bar();
        let mut pressed = 0;
        for c in model.commands() {
            for k in c.all_keys() {
                let press = key_equivalent(keysym(k), modifiers(k));
                assert_eq!(press.as_ref(), Some(k), "{} did not survive the keysym round trip", k.display());
                assert_eq!(press.as_ref().and_then(|p| model.verb_for(p)), Some(c.verb.as_str()));
                pressed += 1
            }
        }
        assert!(pressed > 25, "the walk pressed nothing");
    }

    #[test]
    fn key_equivalent_ignores_caps_lock() {
        assert_eq!(key_equivalent(0x64, KeyModifiers(KeyModifiers::COMMAND.0 | KeyModifiers::CAPS_LOCK.0)), Some(KeyEquivalent::cmd('d', Modifiers::NONE)));
        assert_eq!(key_equivalent(KeySym::HOME, KeyModifiers::COMMAND), None, "Home is not a key equivalent any model uses");
    }

    #[test]
    fn the_finders_keys_never_conflict_with_each_other_or_the_system_menu() {
        assert!(finder_menu_bar().conflicting_keys().is_empty());
        let mut menus = vec![crate::menubar::system_menu()];
        menus.extend(finder_menu_bar().menus);
        assert!(MenuBarModel::new("Finder", menus).conflicting_keys().is_empty());
    }
}
