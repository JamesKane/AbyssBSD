//! TextEdit: plain text, opened and saved (TextEditApp.swift, P15.5).
//!
//! A document per window: a `TextView` under Aqua chrome, the file it came
//! from, and a find bar. Files come and go through the portal (P7): Open…
//! and Save As… ask it for a descriptor, so a sandboxed TextEdit is
//! possible later; or by path, when the Finder or a command line names one.
//! The portal's answer arrives in the run loop, so the window keeps drawing
//! while the person chooses in the Finder.
//!
//! **Bytes are kept.** A file that is not UTF-8 is refused rather than
//! opened, since saving the replacement characters back would destroy it;
//! a save is a temporary file and a rename, so a crash mid-write leaves the
//! old file whole.
//!
//! What a test reads (`ABYSS_TEXTEDIT_DUMP=1`): where the text and its
//! cells are, what was opened, saved and found.

use crate::commands::key_equivalent_of;
use crate::prefs::two_places;
use crate::text_view::{TextView, INSET};
use crate::toolkit::Toolkit;
use aquadraw::canvas::Canvas;
use aquadraw::chrome::{chrome_hit, window_chrome, ChromeEdge, ChromeHit, Gadget};
use aquadraw::color::Color;
use aquadraw::draw::paint_window_chrome;
use aquadraw::drawlist::Role;
use aquadraw::runner::Rect;
use aquadraw::text::Style;
use current_ipc::Msg;
use menu_model::{Command, CommandResult, Enablement, KeyEquivalent, Menu, MenuBarModel, MenuItem, Modifiers};
use menu_wire::{MenuProvider, MenuService};
use std::cell::{Cell, RefCell};
use std::collections::{BTreeMap, HashMap};
use std::fs::File;
use std::io::{Read, Write};
use std::os::fd::{AsRawFd, OwnedFd};
use std::os::unix::fs::PermissionsExt;
use std::rc::{Rc, Weak};
use surface::clipboard::mime;
use surface::{Display, KeyEvent, KeyModifiers, KeySym, RenderTarget, ResizeEdge, Window, WindowDelegate};
use text_model::{EditKind, TextModel};

// MARK: - The vocabulary

pub const VERB_ABOUT: &str = "app.about";
pub const VERB_QUIT: &str = "app.quit";
pub const VERB_NEW: &str = "file.new";
pub const VERB_OPEN: &str = "file.open";
pub const VERB_CLOSE: &str = "file.close";
pub const VERB_SAVE: &str = "file.save";
pub const VERB_SAVE_AS: &str = "file.save-as";
pub const VERB_UNDO: &str = "edit.undo";
pub const VERB_REDO: &str = "edit.redo";
pub const VERB_CUT: &str = "edit.cut";
pub const VERB_COPY: &str = "edit.copy";
pub const VERB_PASTE: &str = "edit.paste";
pub const VERB_SELECT_ALL: &str = "edit.select-all";
pub const VERB_FIND: &str = "edit.find";
pub const VERB_FIND_NEXT: &str = "edit.find-next";
pub const VERB_FIND_PREVIOUS: &str = "edit.find-previous";
pub const VERB_MINIMIZE: &str = "window.minimize";

pub fn textedit_menu_bar() -> MenuBarModel {
    // Save and Save As… write the person's file: an agent's first in a
    // session asks the person first (P18.11).
    let c = |v: &str, t: &str, k: Option<(char, Modifiers)>, s: &str| {
        let mut cmd = Command::new(v, t, s);
        if let Some((ch, m)) = k {
            cmd = cmd.with_key(KeyEquivalent::cmd(ch, m))
        }
        if v == VERB_SAVE || v == VERB_SAVE_AS {
            cmd = cmd.writing()
        }
        MenuItem::Command(cmd)
    };
    let (n, sh) = (Modifiers::NONE, Modifiers::SHIFT);
    MenuBarModel::new(
        "TextEdit",
        vec![
            Menu::new("TextEdit", vec![c(VERB_ABOUT, "About TextEdit", None, "Show TextEdit's version."), MenuItem::Separator, c(VERB_QUIT, "Quit TextEdit", Some(('q', n)), "Close every document and quit.")]),
            Menu::new(
                "File",
                vec![
                    c(VERB_NEW, "New", Some(('n', n)), "Open an empty document."),
                    c(VERB_OPEN, "Open…", Some(('o', n)), "Choose a text file in the Finder."),
                    MenuItem::Separator,
                    c(VERB_CLOSE, "Close", Some(('w', n)), "Close this document."),
                    c(VERB_SAVE, "Save", Some(('s', n)), "Save this document."),
                    c(VERB_SAVE_AS, "Save As…", Some(('s', sh)), "Save this document under another name."),
                ],
            ),
            Menu::new(
                "Edit",
                vec![
                    c(VERB_UNDO, "Undo", Some(('z', n)), "Take back the last change."),
                    c(VERB_REDO, "Redo", Some(('z', sh)), "Put back what was undone."),
                    MenuItem::Separator,
                    c(VERB_CUT, "Cut", Some(('x', n)), "Remove the selection to the clipboard."),
                    c(VERB_COPY, "Copy", Some(('c', n)), "Copy the selection."),
                    c(VERB_PASTE, "Paste", Some(('v', n)), "Put the clipboard's text in."),
                    c(VERB_SELECT_ALL, "Select All", Some(('a', n)), "Select the whole document."),
                    MenuItem::Separator,
                    c(VERB_FIND, "Find…", Some(('f', n)), "Find text in the document."),
                    c(VERB_FIND_NEXT, "Find Next", Some(('g', n)), "Find the next occurrence."),
                    c(VERB_FIND_PREVIOUS, "Find Previous", Some(('g', sh)), "Find the one before."),
                ],
            ),
            Menu::new("Window", vec![c(VERB_MINIMIZE, "Minimize", Some(('m', n)), "Put the window in the Dock.")]),
        ],
    )
}

// MARK: - Files

/// The text in `bytes`, or why it cannot be edited as plain text.
pub fn decode(bytes: Vec<u8>) -> Result<String, &'static str> {
    if bytes.contains(&0) {
        return Err("it holds NUL bytes — it is not a text file");
    }
    String::from_utf8(bytes).map_err(|_| "it is not UTF-8 text, and saving it would change it")
}

/// Save over `path` through a temporary file beside it and a rename,
/// keeping the file's mode: a crash mid-write leaves the old file, never
/// half a new one.
pub fn save_to(bytes: &[u8], path: &str) -> Result<(), String> {
    let p = std::path::Path::new(path);
    let dir = p.parent().filter(|d| !d.as_os_str().is_empty()).unwrap_or(std::path::Path::new("."));
    let name = p.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
    let mode = std::fs::metadata(p).map_or(0o644, |m| m.permissions().mode() & 0o7777);
    let (mut f, tmp) = (0..100)
        .find_map(|i| {
            let tmp = dir.join(format!(".{name}.{}.{i}", std::process::id()));
            File::options().write(true).create_new(true).open(&tmp).ok().map(|f| (f, tmp))
        })
        .ok_or_else(|| format!("cannot write in {}", dir.display()))?;
    let written = f.write_all(bytes).and_then(|_| f.set_permissions(std::fs::Permissions::from_mode(mode))).and_then(|_| f.sync_all());
    if let Err(e) = written {
        let _ = std::fs::remove_file(&tmp);
        return Err(format!("could not write {path}: {e}"));
    }
    std::fs::rename(&tmp, p).map_err(|e| {
        let _ = std::fs::remove_file(&tmp);
        format!("could not replace {path}: {e}")
    })
}

/// Write through a descriptor the portal opened for us (Save As).
pub fn save_fd(bytes: &[u8], fd: OwnedFd) -> Result<(), String> {
    let mut f = File::from(fd);
    f.write_all(bytes).and_then(|_| f.set_len(bytes.len() as u64)).and_then(|_| f.sync_all()).map_err(|e| format!("could not write: {e}"))
}

/// One question to the portal, answered in the run loop.
pub(crate) fn ask_portal(display: &Rc<Display>, msg: &Msg, done: impl FnOnce(Option<Msg>) + 'static) {
    let service = std::env::var("ABYSS_PORTAL_SERVICE").unwrap_or_else(|_| "portal".into());
    let Ok(sock) = current_ipc::connect(&service) else { return done(None) };
    if current_ipc::send(msg, &sock).is_err() {
        return done(None);
    }
    let fd = sock.as_raw_fd();
    let (d, done) = (Rc::downgrade(display), RefCell::new(Some(done)));
    display.add_fd(fd, move || {
        if let Some(d) = d.upgrade() {
            d.remove_fd(fd)
        }
        if let Some(f) = done.borrow_mut().take() {
            f(current_ipc::receive(&sock).ok())
        }
    })
}

// MARK: - Painting

pub const FIND_BAR_HEIGHT: f64 = 30.0;

/// The text view's place in a window, under the title bar and the find bar.
pub fn text_rect(title_bar: f64, resize_band: f64, w: f64, h: f64, find_bar: bool) -> Rect {
    let top = title_bar + if find_bar { FIND_BAR_HEIGHT } else { 0.0 };
    Rect::new(0.0, top, w, (h - top - resize_band).max(0.0))
}

#[allow(clippy::too_many_arguments)]
pub fn paint_textedit(c: &mut Canvas, w: f64, h: f64, title: &str, view: &mut TextView, find_bar: Option<&str>, find_focused: bool, caret_on: bool) {
    paint_window_chrome(c.runner, c.theme, c.cr, w, h, title, false, true);
    let t = c.theme.tokens.clone();
    if let Some(find) = find_bar {
        let bar = Rect::new(0.0, t.title_bar_height, w, FIND_BAR_HEIGHT);
        c.set_color(Color::hex(0xE8E8E8, 1.0));
        c.cr.rectangle(bar.x, bar.y, bar.w, bar.h);
        c.cr.fill();
        c.text_left("Find:", 10.0, bar.y + 19.0, t.body_text, t.font_size, Style::Regular, Role::Interface);
        c.text_field(Rect::new(48.0, bar.y + 4.0, 260.0f64.min(w - 60.0), 22.0), find, find_focused && caret_on, "")
    }
    view.set_frame(text_rect(t.title_bar_height, t.chrome_resize_band, w, h, find_bar.is_some()));
    view.caret_on = caret_on;
    view.paint(c, !find_focused)
}

/// "Do you want to save changes?": the sheet a document shows when closed
/// with edits, from the title bar down.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SaveSheetLayout {
    pub panel: Rect,
    pub save: Rect,
    pub dont_save: Rect,
    pub cancel: Rect,
}

impl SaveSheetLayout {
    pub fn new(title_bar: f64, w: f64) -> SaveSheetLayout {
        let (pw, ph) = (420.0f64.min(w - 40.0), 116.0);
        let panel = Rect::new((w - pw) / 2.0, title_bar, pw, ph);
        let (by, bh) = (panel.y + ph - 40.0, 26.0);
        let save = Rect::new(panel.x + pw - 96.0, by, 82.0, bh);
        SaveSheetLayout { panel, save, cancel: Rect::new(save.x - 92.0, by, 82.0, bh), dont_save: Rect::new(panel.x + 16.0, by, 104.0, bh) }
    }
}

fn paint_save_sheet(c: &mut Canvas, w: f64, name: &str) -> SaveSheetLayout {
    let t = c.theme.tokens.clone();
    let l = SaveSheetLayout::new(t.title_bar_height, w);
    let p = l.panel;
    c.set_color(Color::new(0.0, 0.0, 0.0, 0.18));
    c.cr.rectangle(p.x + 2.0, p.y, p.w, p.h + 3.0);
    c.cr.fill();
    c.set_color(Color::hex(0xECECEC, 1.0));
    c.cr.rectangle(p.x, p.y, p.w, p.h);
    c.cr.fill();
    c.text_left(&format!("Do you want to save changes to \"{name}\" before closing?"), p.x + 18.0, p.y + 30.0, t.body_text, t.font_size, Style::Bold, Role::Interface);
    c.text_left("If you don't save, your changes will be lost.", p.x + 18.0, p.y + 50.0, t.body_text, t.font_size - 1.0, Style::Regular, Role::Interface);
    c.gel_button(l.dont_save, "Don't Save", false, false);
    c.gel_button(l.cancel, "Cancel", false, false);
    c.gel_button(l.save, "Save", true, false);
    l
}

/// The golden scene's document: wrapped lines, a tab, a selection across a
/// line break.
pub fn sample_text() -> &'static str {
    "Welcome to TextEdit.\n\nPlain text, opened and saved through the Finder, with undo and find. A long line wraps at the window's edge, after the last space that fits.\n\tIndented with a tab.\nThe end."
}

fn log(s: &str) {
    eprintln!("TextEdit: {s}")
}

fn ok() -> CommandResult {
    CommandResult::Ok(None)
}
fn refused(s: &str) -> CommandResult {
    CommandResult::Refused(s.into())
}

// MARK: - A document

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Answer {
    Save,
    DontSave,
    Cancel,
}

pub struct Document {
    me: Weak<Document>,
    app: Weak<TextEditApp>,
    window: RefCell<Option<Rc<Window>>>,
    pub view: RefCell<TextView>,
    path: RefCell<Option<String>>,
    /// The find bar: its text when shown, and whether keys go to it.
    find_text: RefCell<Option<String>>,
    find_focused: Cell<bool>,
    last_find: RefCell<String>,
    pointer: Cell<(f64, f64)>,
    shift_held: Cell<bool>,
    announced: Cell<(i64, i64)>,
    dump: bool,
    shown_title: RefCell<String>,
    /// The save sheet is up: the document was asked to close with edits.
    asking: Cell<bool>,
    sheet_logged: Cell<bool>,
    /// Close once a save (perhaps through the portal) has gone through.
    close_after_save: Cell<bool>,
    closed: Cell<bool>,
}

impl Document {
    fn new(app: &Rc<TextEditApp>, path: Option<String>, text: &str) -> Option<Rc<Document>> {
        let view = TextView::new(text, &mut app.toolkit.runner.borrow_mut().text);
        let d = Rc::new_cyclic(|me| Document {
            me: me.clone(),
            app: Rc::downgrade(app),
            window: RefCell::new(None),
            view: RefCell::new(view),
            path: RefCell::new(path),
            find_text: RefCell::new(None),
            find_focused: Cell::new(false),
            last_find: RefCell::default(),
            pointer: Cell::new((0.0, 0.0)),
            shift_held: Cell::new(false),
            announced: Cell::new((0, 0)),
            dump: std::env::var_os("ABYSS_TEXTEDIT_DUMP").is_some(),
            shown_title: RefCell::default(),
            asking: Cell::new(false),
            sheet_logged: Cell::new(false),
            close_after_save: Cell::new(false),
            closed: Cell::new(false),
        });
        let pinned = std::env::var("AQUA_SCALE").ok().and_then(|s| s.parse::<i32>().ok()).filter(|v| *v > 0);
        let win = Window::new(&app.display, "", "org.abyssbsd.textedit", 560, 440, pinned.unwrap_or(1), pinned.is_none(), Rc::downgrade(&d) as Weak<dyn WindowDelegate>)?;
        *d.window.borrow_mut() = Some(win);
        d.update_title();
        Some(d)
    }

    fn window(&self) -> Option<Rc<Window>> {
        self.window.borrow().clone()
    }

    fn redraw(&self) {
        if let Some(w) = self.window() {
            w.set_needs_display()
        }
    }

    fn name(&self) -> String {
        self.path.borrow().as_deref().map_or("Untitled".into(), |p| p.rsplit('/').next().unwrap_or(p).to_string())
    }

    fn is_dirty(&self) -> bool {
        self.view.borrow().model.is_dirty()
    }

    fn update_title(&self) {
        let t = format!("{}{}", self.name(), if self.is_dirty() { " — Edited" } else { "" });
        if *self.shown_title.borrow() != t {
            if let Some(w) = self.window() {
                w.set_title(&t)
            }
            *self.shown_title.borrow_mut() = t
        }
    }

    /// The text or the selection moved: the title, the menus, the picture.
    fn changed(&self) {
        self.update_title();
        if let Some(a) = self.app.upgrade() {
            a.menus_may_have_changed()
        }
        self.redraw()
    }

    /// Change the view, then say so.
    fn edit(&self, f: impl FnOnce(&mut TextModel)) {
        self.view.borrow_mut().edit(f);
        self.changed()
    }

    fn load(&self, path: &str, text: &str) {
        *self.path.borrow_mut() = Some(path.into());
        self.view.borrow_mut().set_text(text);
        self.changed()
    }

    fn blink(&self) {
        if !self.window().is_some_and(|w| w.is_activated()) {
            return;
        }
        let mut v = self.view.borrow_mut();
        v.caret_on = !v.caret_on;
        drop(v);
        self.redraw()
    }

    fn bytes(&self) -> Vec<u8> {
        self.view.borrow().model.text().into_bytes()
    }

    /// Save to the file it came from; refused when it has none.
    fn save(&self) -> CommandResult {
        let Some(p) = self.path.borrow().clone() else { return refused("it has no file yet — Save As") };
        let bytes = self.bytes();
        if let Err(why) = save_to(&bytes, &p) {
            log(&format!("could not save {p}: {why}"));
            return CommandResult::Refused(why);
        }
        self.edit(|m| m.mark_saved());
        log(&format!("saved {p} ({} bytes)", bytes.len()));
        CommandResult::Ok(Some(p))
    }

    fn saved_through_portal(&self, p: &str, fd: OwnedFd) {
        let bytes = self.bytes();
        if let Err(why) = save_fd(&bytes, fd) {
            return log(&format!("could not save {p}: {why}"));
        }
        *self.path.borrow_mut() = Some(p.into());
        self.edit(|m| m.mark_saved());
        log(&format!("saved {p} ({} bytes)", bytes.len()));
        if self.close_after_save.get() {
            self.close()
        }
    }

    fn show_find(&self) {
        let last = self.last_find.borrow().clone();
        self.find_text.borrow_mut().get_or_insert(last);
        self.find_focused.set(true);
        self.redraw()
    }

    fn needle(&self) -> String {
        self.find_text.borrow().clone().unwrap_or_else(|| self.last_find.borrow().clone())
    }

    fn find(&self, backward: bool) -> CommandResult {
        let needle = self.needle();
        if needle.is_empty() {
            return refused("nothing to find");
        }
        *self.last_find.borrow_mut() = needle.clone();
        let Some(r) = self.view.borrow().model.find(&needle, backward, true) else {
            log(&format!("not found: {needle}"));
            return CommandResult::Refused(format!("'{needle}' is not in the document"));
        };
        self.edit(|m| m.select(r));
        log(&format!("found {}:{}-{}:{}", r.start.line + 1, r.start.column + 1, r.end.line + 1, r.end.column + 1));
        ok()
    }

    fn close_find(&self) {
        *self.find_text.borrow_mut() = None;
        self.find_focused.set(false);
        self.redraw()
    }

    /// Closed with edits: ask first.
    fn ask_to_close(&self) {
        self.asking.set(true);
        log(&format!("asked to save changes to {}", self.name()));
        self.redraw()
    }

    fn answer(&self, a: Answer) {
        self.asking.set(false);
        self.redraw();
        match a {
            Answer::Cancel => {
                log("close cancelled");
                if let Some(app) = self.app.upgrade() {
                    app.quitting.set(false)
                }
            }
            Answer::DontSave => {
                log(&format!("closed {} without saving", self.name()));
                self.close()
            }
            Answer::Save => {
                self.close_after_save.set(true);
                if self.path.borrow().is_some() {
                    match self.save() {
                        CommandResult::Ok(_) => self.close(),
                        _ => self.close_after_save.set(false),
                    }
                } else if let Some(app) = self.app.upgrade() {
                    app.perform(VERB_SAVE_AS, self.me.upgrade());
                }
            }
        }
    }

    fn close(&self) {
        if self.closed.replace(true) {
            return;
        }
        if let Some(w) = self.window.borrow_mut().take() {
            w.close()
        }
        if let (Some(app), Some(me)) = (self.app.upgrade(), self.me.upgrade()) {
            app.document_closed(&me)
        }
    }

    fn perform(&self, verb: &str) -> CommandResult {
        self.app.upgrade().map_or(refused("no application"), |a| a.perform(verb, self.me.upgrade()))
    }
}

impl WindowDelegate for Document {
    fn render(&self, w: &Window, target: &RenderTarget) {
        let Some(app) = self.app.upgrade() else { return };
        let find = self.find_text.borrow().clone();
        let (title, name) = (self.shown_title.borrow().clone(), self.name());
        let caret_on = self.view.borrow().caret_on;
        let _ = w;
        app.toolkit.draw(target, |c, w, h| {
            let mut v = self.view.borrow_mut();
            paint_textedit(c, w, h, &title, &mut v, find.as_deref(), self.find_focused.get(), caret_on);
            if self.asking.get() {
                let l = paint_save_sheet(c, w, &name);
                if self.dump && !self.sheet_logged.replace(true) {
                    let at = |r: Rect| format!("{},{}", (r.x + r.w / 2.0) as i64, (r.y + r.h / 2.0) as i64);
                    log(&format!("sheet save={} dontsave={} cancel={}", at(l.save), at(l.dont_save), at(l.cancel)))
                }
            } else {
                self.sheet_logged.set(false)
            }
            if self.dump && self.announced.get() != (w as i64, h as i64) {
                self.announced.set((w as i64, h as i64));
                let t = c.theme.tokens.clone();
                let (r, (cw, ch)) = (v.frame(), v.cell_size());
                let gadgets: Vec<String> = window_chrome(&t, w, h, false).gadgets.iter().map(|p| format!("{}={},{}", p.gadget.name(), (p.rect.x + p.rect.w / 2.0) as i64, (p.rect.y + p.rect.h / 2.0) as i64)).collect();
                log(&format!("chrome {}x{} {} text={},{},{},{} inset={} cell={}x{}", w as i64, h as i64, gadgets.join(" "), r.x as i64, r.y as i64, r.w as i64, r.h as i64, INSET as i64, two_places(cw), two_places(ch)))
            }
        })
    }

    fn pointer_moved(&self, _w: &Window, x: f64, y: f64) {
        self.pointer.set((x, y));
        if self.view.borrow_mut().pointer_moved(x, y) {
            self.changed()
        }
    }

    fn pointer_button(&self, w: &Window, button: u32, pressed: bool) {
        if !pressed {
            return self.view.borrow_mut().pointer_released();
        }
        let Some(app) = self.app.upgrade() else { return };
        let (x, y) = self.pointer.get();
        let (sw, sh) = w.size();
        let t = app.toolkit.theme.borrow().tokens.clone();
        match chrome_hit(&t, &window_chrome(&t, sw as f64, sh as f64, false), x, y) {
            ChromeHit::Gadget(Gadget::Close) => {
                self.perform(VERB_CLOSE);
                return;
            }
            ChromeHit::Gadget(Gadget::Minimize) => {
                w.minimize();
                return;
            }
            ChromeHit::Gadget(Gadget::Zoom) => return w.set_maximized(!w.is_maximized()),
            ChromeHit::Gadget(Gadget::Depth) => {
                w.lower();
                return;
            }
            ChromeHit::Title => return w.begin_move(),
            ChromeHit::Resize(e) => {
                return w.begin_resize(match e {
                    ChromeEdge::Bottom => ResizeEdge::BOTTOM,
                    ChromeEdge::BottomLeft => ResizeEdge::BOTTOM_LEFT,
                    ChromeEdge::BottomRight => ResizeEdge::BOTTOM_RIGHT,
                })
            }
            ChromeHit::Gadget(Gadget::Pill) | ChromeHit::Content => {}
        }
        if button != 0x110 {
            return;
        }
        if self.asking.get() {
            let l = SaveSheetLayout::new(t.title_bar_height, sw as f64);
            if l.save.contains(x, y) {
                self.answer(Answer::Save)
            } else if l.dont_save.contains(x, y) {
                self.answer(Answer::DontSave)
            } else if l.cancel.contains(x, y) {
                self.answer(Answer::Cancel)
            }
            return;
        }
        if self.view.borrow().contains(x, y) {
            self.find_focused.set(false);
            self.view.borrow_mut().pointer_pressed(x, y, self.shift_held.get());
            self.changed()
        } else if self.find_text.borrow().is_some() && y < t.title_bar_height + FIND_BAR_HEIGHT {
            self.find_focused.set(true);
            self.redraw()
        }
    }

    fn pointer_axis(&self, _w: &Window, axis: u32, value: f64) {
        if axis == 0 {
            self.view.borrow_mut().scroll_by(value * 2.0);
            self.redraw()
        }
    }

    fn key_event(&self, _w: &Window, e: &KeyEvent) {
        self.shift_held.set(e.modifiers.contains(KeyModifiers::SHIFT));
        if !e.pressed {
            return;
        }
        let cmd = e.modifiers.contains(KeyModifiers::COMMAND);
        if self.asking.get() {
            // Return saves, Escape cancels, ⌘D is Don't Save: Jaguar's keys.
            match e.keysym {
                KeySym::ENTER => self.answer(Answer::Save),
                KeySym::ESCAPE => self.answer(Answer::Cancel),
                0x64 if cmd => self.answer(Answer::DontSave),
                _ => {}
            }
            return;
        }
        if cmd {
            match key_equivalent_of(e).and_then(|k| textedit_menu_bar().verb_for(&k).map(String::from)) {
                Some(verb) => {
                    if let CommandResult::Refused(why) = self.perform(&verb) {
                        log(&format!("{verb} refused: {why}"))
                    }
                }
                // Command-arrows are the view's.
                None => {
                    if self.view.borrow_mut().key(e).is_some() {
                        self.changed()
                    }
                }
            }
            return;
        }
        if self.find_focused.get() && self.find_text.borrow().is_some() {
            match e.keysym {
                KeySym::ESCAPE => return self.close_find(),
                KeySym::ENTER => {
                    self.find(e.modifiers.contains(KeyModifiers::SHIFT));
                }
                KeySym::BACKSPACE => {
                    if let Some(t) = self.find_text.borrow_mut().as_mut() {
                        t.pop();
                    }
                }
                _ => {
                    if !e.text.is_empty() && e.text.chars().all(|c| c as u32 >= 0x20 && c as u32 != 0x7f)
                        && let Some(t) = self.find_text.borrow_mut().as_mut()
                    {
                        t.push_str(&e.text)
                    }
                }
            }
            return self.redraw();
        }
        if e.keysym == KeySym::ESCAPE && self.find_text.borrow().is_some() {
            return self.close_find();
        }
        if self.view.borrow_mut().key(e).is_some() {
            self.changed()
        }
    }

    fn should_close(&self, _w: &Window) {
        self.perform(VERB_CLOSE);
    }

    fn state_changed(&self, w: &Window) {
        self.view.borrow_mut().caret_on = true;
        w.set_needs_display()
    }
}

// MARK: - The application

pub struct TextEditApp {
    me: Weak<TextEditApp>,
    display: Rc<Display>,
    toolkit: Rc<Toolkit>,
    documents: RefCell<Vec<Rc<Document>>>,
    menu_service: RefCell<Option<MenuService>>,
    menu_name: String,
    last_menu_state: RefCell<String>,
    changed_pending: Cell<bool>,
    /// Quit: close every document, asking about each with edits in turn.
    quitting: Cell<bool>,
    /// What this process last copied: the clipboard will not read back a
    /// selection its own process owns.
    last_copied: RefCell<Option<String>>,
}

struct Provider<'a>(&'a TextEditApp);

impl MenuProvider for Provider<'_> {
    /// The Edit menu says what Undo would take back ("Undo Typing").
    fn menu_model(&self) -> MenuBarModel {
        let bar = textedit_menu_bar();
        let Some(d) = self.0.front() else { return bar };
        let v = d.view.borrow();
        let titles: HashMap<String, String> = [(VERB_UNDO.to_string(), v.model.undo_name().map_or("Undo".into(), |n| format!("Undo {n}"))), (VERB_REDO.to_string(), v.model.redo_name().map_or("Redo".into(), |n| format!("Redo {n}")))].into();
        bar.retitled(&titles)
    }
    fn menu_validate(&self, c: &Command) -> Enablement {
        self.0.validate(&c.verb)
    }
    fn menu_perform(&mut self, c: &Command, _a: &BTreeMap<String, String>) -> CommandResult {
        if let Enablement::Disabled(why) = self.0.validate(&c.verb) {
            return CommandResult::Refused(why);
        }
        self.0.perform(&c.verb, self.0.front())
    }
}

impl TextEditApp {
    pub fn new(display: &Rc<Display>, toolkit: &Rc<Toolkit>) -> Rc<TextEditApp> {
        let menu_name = menu_wire::service_name("TextEdit", std::process::id() as i32);
        let app = Rc::new_cyclic(|me| TextEditApp {
            me: me.clone(),
            display: display.clone(),
            toolkit: toolkit.clone(),
            documents: RefCell::default(),
            menu_service: RefCell::new(MenuService::new(&menu_name).ok()),
            menu_name,
            last_menu_state: RefCell::default(),
            changed_pending: Cell::new(false),
            quitting: Cell::new(false),
            last_copied: RefCell::new(None),
        });
        if let Some(fd) = app.menu_service.borrow().as_ref().map(|s| s.fd()) {
            let me = app.me.clone();
            display.add_fd(fd, move || {
                if let Some(a) = me.upgrade() {
                    a.serve()
                }
            });
        }
        let me = app.me.clone();
        display.add_timer(500, move || {
            if let Some(a) = me.upgrade() {
                let ds = a.documents.borrow().clone();
                ds.iter().for_each(|d| d.blink())
            }
        });
        app
    }

    /// The service is out of its cell while it answers, so a command that
    /// changes the menus says so after.
    fn serve(&self) {
        let svc = self.menu_service.borrow_mut().take();
        let Some(mut svc) = svc else { return };
        svc.service_readable(&mut Provider(self));
        if self.changed_pending.take() {
            svc.changed()
        }
        *self.menu_service.borrow_mut() = Some(svc)
    }

    /// A window for `path`, or an empty one. False if the file cannot be
    /// edited as text (and says why) or no window could be made. A name
    /// that does not exist yet is a new document that will be saved there.
    pub fn open(&self, path: Option<&str>) -> bool {
        let mut text = String::new();
        if let Some(p) = path {
            match File::open(p) {
                Ok(mut f) => {
                    let mut bytes = vec![];
                    if let Err(e) = f.read_to_end(&mut bytes) {
                        log(&format!("cannot open {p}: {e}"));
                        return false;
                    }
                    match decode(bytes) {
                        Ok(t) => text = t,
                        Err(why) => {
                            log(&format!("cannot open {p}: {why}"));
                            return false;
                        }
                    }
                }
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
                Err(e) => {
                    log(&format!("cannot open {p}: {e}"));
                    return false;
                }
            }
        }
        self.add_document(path.map(String::from), &text)
    }

    fn add_document(&self, path: Option<String>, text: &str) -> bool {
        let Some(me) = self.me.upgrade() else { return false };
        let Some(d) = Document::new(&me, path.clone(), text) else { return false };
        if let Some(win) = d.window()
            && win.publish_menus(&self.menu_name)
        {
            log(&format!("menus on {}", self.menu_name))
        }
        log(&format!("opened {} ({} lines)", path.as_deref().unwrap_or("a new document"), d.view.borrow().model.line_count()));
        self.documents.borrow_mut().push(d);
        true
    }

    fn document_closed(&self, d: &Rc<Document>) {
        self.documents.borrow_mut().retain(|x| !Rc::ptr_eq(x, d));
        if self.documents.borrow().is_empty() {
            log("the last document closed");
            std::process::exit(0)
        }
        if self.quitting.get() {
            self.continue_quit()
        }
    }

    fn continue_quit(&self) {
        if !self.quitting.get() || self.documents.borrow().iter().any(|d| d.asking.get()) {
            return;
        }
        let dirty = self.documents.borrow().iter().find(|d| d.is_dirty()).cloned();
        match dirty {
            Some(d) => d.ask_to_close(),
            None => {
                log("quitting");
                std::process::exit(0)
            }
        }
    }

    /// Tell the bar only when what its Edit and File menus say has changed:
    /// not on every keystroke.
    fn menus_may_have_changed(&self) {
        let Some(d) = self.front() else { return };
        let state = {
            let m = &d.view.borrow().model;
            format!("{}|{}|{}|{}", m.undo_name().unwrap_or_default(), m.redo_name().unwrap_or_default(), m.selection().is_empty(), m.is_dirty())
        };
        if *self.last_menu_state.borrow() == state {
            return;
        }
        *self.last_menu_state.borrow_mut() = state;
        match &mut *self.menu_service.borrow_mut() {
            Some(s) => s.changed(),
            None => self.changed_pending.set(true),
        }
    }

    fn front(&self) -> Option<Rc<Document>> {
        let ds = self.documents.borrow();
        ds.iter().find(|d| d.window().is_some_and(|w| w.is_activated())).or(ds.last()).cloned()
    }

    fn validate(&self, verb: &str) -> Enablement {
        let front = self.front();
        let model = |f: &dyn Fn(&TextModel) -> bool| front.as_ref().is_some_and(|d| f(&d.view.borrow().model));
        let on = |b: bool, why: &str| if b { Enablement::Enabled } else { Enablement::Disabled(why.into()) };
        match verb {
            VERB_ABOUT => Enablement::Disabled("TextEdit has no About box yet".into()),
            VERB_QUIT | VERB_NEW | VERB_OPEN => Enablement::Enabled,
            VERB_UNDO => on(model(&|m| m.can_undo()), "nothing to undo"),
            VERB_REDO => on(model(&|m| m.can_redo()), "nothing to redo"),
            VERB_CUT | VERB_COPY => on(model(&|m| !m.selection().is_empty()), "nothing is selected"),
            VERB_PASTE => on(self.display.clipboard().is_some_and(|c| c.offers(&[mime::TEXT])) || self.last_copied.borrow().is_some(), "the clipboard holds no text"),
            VERB_FIND_NEXT | VERB_FIND_PREVIOUS => on(front.as_ref().is_some_and(|d| !d.needle().is_empty()), "nothing to find"),
            _ => on(!self.documents.borrow().is_empty(), "no document"),
        }
    }

    fn perform(&self, verb: &str, d: Option<Rc<Document>>) -> CommandResult {
        let doc = d.or_else(|| self.front());
        let Some(me) = self.me.upgrade() else { return refused("no application") };
        match verb {
            VERB_QUIT => {
                self.quitting.set(true);
                self.continue_quit();
                ok()
            }
            VERB_NEW if self.add_document(None, "") => ok(),
            VERB_NEW => refused("no window could be made"),
            VERB_OPEN => {
                let mut m = Msg::new();
                m.set_string("method", "file.open");
                if let Some(dir) = doc.as_ref().and_then(|d| d.path.borrow().clone()).and_then(|p| p.rsplit_once('/').map(|(d, _)| d.to_string())) {
                    m.set_string("dir", &dir)
                }
                let a = Rc::downgrade(&me);
                ask_portal(&self.display, &m, move |reply| {
                    if let Some(a) = a.upgrade() {
                        a.opened(reply)
                    }
                });
                CommandResult::Ok(Some("asked the portal".into()))
            }
            VERB_CLOSE => {
                let Some(doc) = doc else { return refused("no document") };
                if doc.is_dirty() {
                    if !doc.asking.get() {
                        doc.ask_to_close()
                    }
                    return CommandResult::Ok(Some("asked".into()));
                }
                doc.close();
                ok()
            }
            VERB_SAVE => match doc {
                None => refused("no document"),
                Some(d) if d.path.borrow().is_none() => self.perform(VERB_SAVE_AS, Some(d)),
                Some(d) => d.save(),
            },
            VERB_SAVE_AS => {
                let Some(doc) = doc else { return refused("no document") };
                let mut m = Msg::new();
                m.set_string("method", "file.save");
                let name = doc.name();
                m.set_string("name", if name == "Untitled" { "Untitled.txt" } else { &name });
                let dw = Rc::downgrade(&doc);
                ask_portal(&self.display, &m, move |reply| {
                    if let Some(d) = dw.upgrade() {
                        saved_as(reply, &d)
                    }
                });
                CommandResult::Ok(Some("asked the portal".into()))
            }
            VERB_UNDO => {
                let Some(doc) = doc.filter(|d| d.view.borrow().model.can_undo()) else { return refused("nothing to undo") };
                let name = doc.view.borrow().model.undo_name().unwrap_or_default();
                doc.edit(|m| m.undo());
                log(&format!("undid {name}"));
                ok()
            }
            VERB_REDO => {
                let Some(doc) = doc.filter(|d| d.view.borrow().model.can_redo()) else { return refused("nothing to redo") };
                doc.edit(|m| m.redo());
                ok()
            }
            VERB_COPY | VERB_CUT => {
                let Some(doc) = doc.filter(|d| !d.view.borrow().model.selection().is_empty()) else { return refused("nothing is selected") };
                let t = doc.view.borrow().model.selected_text();
                if !self.display.clipboard().is_some_and(|c| c.write_text(&t)) {
                    return refused("the clipboard would not take it");
                }
                *self.last_copied.borrow_mut() = Some(t);
                if verb == VERB_CUT {
                    doc.edit(|m| m.insert("", EditKind::Cut))
                }
                ok()
            }
            VERB_PASTE => {
                let Some(doc) = doc else { return refused("no document") };
                let t = match self.display.clipboard() {
                    Some(c) if !c.owns_selection() => c.read_text().or_else(|| self.last_copied.borrow().clone()),
                    _ => self.last_copied.borrow().clone(),
                };
                let Some(t) = t.filter(|t| !t.is_empty()) else { return refused("the clipboard holds no text") };
                doc.edit(|m| m.insert(&t, EditKind::Paste));
                ok()
            }
            VERB_SELECT_ALL => {
                if let Some(d) = doc {
                    d.edit(|m| m.select_all())
                }
                ok()
            }
            VERB_FIND => {
                if let Some(d) = doc {
                    d.show_find()
                }
                ok()
            }
            VERB_FIND_NEXT | VERB_FIND_PREVIOUS => doc.map_or(refused("no document"), |d| d.find(verb == VERB_FIND_PREVIOUS)),
            VERB_MINIMIZE => {
                if let Some(w) = doc.and_then(|d| d.window()) {
                    w.minimize();
                }
                ok()
            }
            v => CommandResult::Refused(format!("TextEdit has no verb {v}")),
        }
    }

    fn opened(&self, reply: Option<Msg>) {
        let mut reply = match reply {
            Some(r) if r.bool("ok") == Some(true) => r,
            other => return log(&format!("open: {}", reply_error(other.as_ref()))),
        };
        let Some(fd) = reply.take_fd("file") else { return log("open: the portal sent no file") };
        let mut bytes = vec![];
        let _ = File::from(fd).read_to_end(&mut bytes);
        let path = reply.string("path").map(String::from);
        let text = match decode(bytes) {
            Ok(t) => t,
            Err(why) => return log(&format!("cannot open {}: {why}", path.as_deref().unwrap_or("it"))),
        };
        // An empty, untouched Untitled window is reused, as TextEdit does.
        let reuse = self.front().filter(|d| d.path.borrow().is_none() && !d.is_dirty() && d.view.borrow().model.text().is_empty());
        match reuse {
            Some(d) => {
                d.load(path.as_deref().unwrap_or("Untitled"), &text);
                log(&format!("opened {} ({} lines)", path.as_deref().unwrap_or("a file"), d.view.borrow().model.line_count()))
            }
            None => {
                self.add_document(path, &text);
            }
        }
    }
}

fn reply_error(reply: Option<&Msg>) -> String {
    reply.and_then(|r| r.string("error")).unwrap_or("the portal did not answer").to_string()
}

fn saved_as(reply: Option<Msg>, doc: &Rc<Document>) {
    let refused = reply.as_ref().is_none_or(|r| r.bool("ok") != Some(true));
    if refused {
        return log(&format!("save as: {}", reply_error(reply.as_ref())));
    }
    let mut reply = reply.expect("checked above");
    let (Some(fd), Some(path)) = (reply.take_fd("file"), reply.string("path").map(String::from)) else { return log("save as: the portal sent no file") };
    doc.saved_through_portal(&path, fd)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bytes_are_kept_or_refused() {
        assert_eq!(decode(b"caf\xc3\xa9\n".to_vec()), Ok("café\n".into()));
        assert!(decode(b"caf\xe9".to_vec()).is_err(), "Latin-1 is refused, not mangled");
        assert!(decode(b"a\0b".to_vec()).is_err());
    }

    #[test]
    fn a_save_replaces_the_file_whole_and_keeps_its_mode() {
        let dir = std::env::temp_dir().join(format!("textedit-test-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let p = dir.join("notes.txt");
        std::fs::write(&p, "old").unwrap();
        std::fs::set_permissions(&p, std::fs::Permissions::from_mode(0o600)).unwrap();
        save_to(b"new text", p.to_str().unwrap()).unwrap();
        assert_eq!(std::fs::read_to_string(&p).unwrap(), "new text");
        assert_eq!(std::fs::metadata(&p).unwrap().permissions().mode() & 0o777, 0o600);
        assert_eq!(std::fs::read_dir(&dir).unwrap().count(), 1, "no temporary file left behind");
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn the_save_sheets_buttons_sit_inside_it() {
        let l = SaveSheetLayout::new(22.0, 560.0);
        for b in [l.save, l.dont_save, l.cancel] {
            assert!(l.panel.contains(b.x + 1.0, b.y + 1.0))
        }
        assert!(l.cancel.x + l.cancel.w < l.save.x);
    }
}
