//! Terminal: a shell in a window (TerminalApp.swift, P15.4b).
//!
//! Each window is a `Pty` running the person's shell and a `Screen` its
//! output drives; this draws the screen in the theme's `mono` role, turns
//! keys into bytes, blinks a caret, and gives the shell a new size when the
//! window gets one. When the shell exits its window closes: Mac Terminal's
//! "close if the shell exited cleanly", without the question.
//!
//! **What the tests read** (`ABYSS_TERMINAL_DUMP=1`): each row as it
//! changes, `Terminal: row N |text|`, and the size the shell was given.

use crate::commands::key_equivalent_of;
use crate::prefs::two_places;
use crate::toolkit::Toolkit;
use aquadraw::canvas::Canvas;
use aquadraw::chrome::{chrome_hit, window_chrome, ChromeEdge, ChromeHit, Gadget};
use aquadraw::color::Color;
use aquadraw::draw::paint_window_chrome;
use aquadraw::drawlist::Role;
use aquadraw::runner::Rect;
use aquadraw::text::{Style, Text};
use aquadraw::tokens::ThemeTokens;
use menu_model::{Command, CommandResult, Enablement, KeyEquivalent, Menu, MenuBarModel, MenuItem, Modifiers};
use menu_wire::{MenuProvider, MenuService};
use pty::Pty;
use std::cell::{Cell as StdCell, RefCell};
use std::collections::BTreeMap;
use std::os::fd::AsRawFd;
use std::rc::{Rc, Weak};
use std::time::Instant;
use surface::clipboard::mime;
use surface::{Display, KeyEvent, KeyModifiers, RenderTarget, ResizeEdge, Window, WindowDelegate};
use terminal::keys::sym;
use terminal::{encode, paste_bytes, CellAttributes, KeyMods, Screen, TermColor, TextPoint};

// MARK: - The vocabulary

pub const VERB_ABOUT: &str = "app.about";
pub const VERB_QUIT: &str = "app.quit";
pub const VERB_NEW_WINDOW: &str = "shell.new-window";
pub const VERB_CLOSE: &str = "window.close";
pub const VERB_MINIMIZE: &str = "window.minimize";
pub const VERB_COPY: &str = "edit.copy";
pub const VERB_PASTE: &str = "edit.paste";
pub const VERB_SELECT_ALL: &str = "edit.select-all";
pub const VERB_CLEAR_SCROLLBACK: &str = "edit.clear-scrollback";

pub fn terminal_menu_bar() -> MenuBarModel {
    let c = |v: &str, t: &str, k: Option<char>, s: &str| {
        let cmd = Command::new(v, t, s);
        MenuItem::Command(match k {
            Some(k) => cmd.with_key(KeyEquivalent::cmd(k, Modifiers::NONE)),
            None => cmd,
        })
    };
    MenuBarModel::new(
        "Terminal",
        vec![
            Menu::new("Terminal", vec![c(VERB_ABOUT, "About Terminal", None, "Show Terminal's version."), MenuItem::Separator, c(VERB_QUIT, "Quit Terminal", Some('q'), "Close every Terminal window.")]),
            Menu::new(
                "Edit",
                vec![
                    c(VERB_COPY, "Copy", Some('c'), "Copy the selected text."),
                    c(VERB_PASTE, "Paste", Some('v'), "Type the clipboard's text into the shell."),
                    c(VERB_SELECT_ALL, "Select All", Some('a'), "Select everything, history too."),
                    MenuItem::Separator,
                    c(VERB_CLEAR_SCROLLBACK, "Clear Scrollback", Some('k'), "Forget the lines scrolled away."),
                ],
            ),
            Menu::new("Shell", vec![c(VERB_NEW_WINDOW, "New Window", Some('n'), "Open another window with a new shell."), MenuItem::Separator, c(VERB_CLOSE, "Close Window", Some('w'), "Close this window and its shell.")]),
            Menu::new("Window", vec![c(VERB_MINIMIZE, "Minimize", Some('m'), "Put the window in the Dock.")]),
        ],
    )
}

// MARK: - Look

/// The grid's text size. The default pen is Jaguar Terminal's: black on white.
pub const FONT_SIZE: f64 = 12.0;
pub const PADDING: f64 = 4.0;
const FOREGROUND: Color = Color::new(0.0, 0.0, 0.0, 1.0);
const BACKGROUND: Color = Color::new(1.0, 1.0, 1.0, 1.0);
fn caret() -> Color {
    Color::hex(0x3875D7, 1.0)
}
/// Jaguar's text highlight.
fn selection_color() -> Color {
    Color::hex(0xB5D5FF, 1.0)
}

/// xterm's sixteen, then its 6×6×6 cube and 24 greys.
pub fn term_color(c: TermColor, default: Color) -> Color {
    const BASIC: [u32; 16] = [0x000000, 0xCD0000, 0x00CD00, 0xCDCD00, 0x0000EE, 0xCD00CD, 0x00CDCD, 0xE5E5E5, 0x7F7F7F, 0xFF0000, 0x00FF00, 0xFFFF00, 0x5C5CFF, 0xFF00FF, 0x00FFFF, 0xFFFFFF];
    match c {
        TermColor::Default => default,
        TermColor::Rgb(r, g, b) => Color::new(f64::from(r) / 255.0, f64::from(g) / 255.0, f64::from(b) / 255.0, 1.0),
        TermColor::Indexed(i) if i < 16 => Color::hex(BASIC[i as usize], 1.0),
        TermColor::Indexed(i) if i < 232 => {
            let n = i32::from(i) - 16;
            let level = |v: i32| if v == 0 { 0.0 } else { f64::from(55 + v * 40) / 255.0 };
            Color::new(level(n / 36), level((n / 6) % 6), level(n % 6), 1.0)
        }
        TermColor::Indexed(i) => {
            let g = f64::from(8 + (i32::from(i) - 232) * 10) / 255.0;
            Color::new(g, g, g, 1.0)
        }
    }
}

/// One character cell in the `mono` role, in points, at the text's current
/// render scale.
pub fn cell_size(text: &mut Text) -> (f64, f64) {
    let scale = f64::from(text.render_scale);
    let w = text.text_width("M", FONT_SIZE, Style::Regular, Role::Mono);
    let m = Text::metrics(text.px(FONT_SIZE), Role::Mono);
    (w.max(1.0), (((m.ascent + m.descent) / scale).ceil() + 1.0).max(1.0))
}

fn ascent(text: &Text) -> f64 {
    Text::metrics(text.px(FONT_SIZE), Role::Mono).ascent / f64::from(text.render_scale)
}

/// The grid inside a window of `w` × `h`: under the title bar, above the
/// resize band.
pub fn grid_rect(t: &ThemeTokens, w: f64, h: f64) -> Rect {
    let top = t.title_bar_height + PADDING;
    Rect::new(PADDING, top, (w - 2.0 * PADDING).max(0.0), (h - top - PADDING.max(t.chrome_resize_band)).max(0.0))
}

fn colors(a: &CellAttributes) -> (Color, Color) {
    let mut fg = term_color(a.fg, FOREGROUND);
    let mut bg = term_color(a.bg, BACKGROUND);
    if let (true, TermColor::Indexed(i @ 0..8)) = (a.bold, a.fg) {
        fg = term_color(TermColor::Indexed(i + 8), fg)
    }
    if a.inverse {
        std::mem::swap(&mut fg, &mut bg)
    }
    if a.dim {
        fg = fg.with_a(0.6)
    }
    (fg, bg)
}

/// The light box-drawing characters, drawn edge to edge rather than from
/// the font: a glyph is shorter than a cell, and a box of them has gaps
/// (xterm draws these itself for the same reason). Up, down, left, right.
fn box_arms(c: char) -> Option<(bool, bool, bool, bool)> {
    Some(match c {
        '─' => (false, false, true, true),
        '│' => (true, true, false, false),
        '┌' => (false, true, false, true),
        '┐' => (false, true, true, false),
        '└' => (true, false, false, true),
        '┘' => (true, false, true, false),
        '├' => (true, true, false, true),
        '┤' => (true, true, true, false),
        '┬' => (false, true, true, true),
        '┴' => (true, false, true, true),
        '┼' => (true, true, true, true),
        _ => return None,
    })
}

fn draw_box_character(c: &mut Canvas, ch: char, x: f64, y: f64, w: f64, h: f64, color: Color) -> bool {
    let Some((up, down, left, right)) = box_arms(ch) else { return false };
    // The centre on a pixel boundary plus half, so a 1-px line is crisp.
    let (cx, cy) = ((x + w / 2.0).floor() + 0.5, (y + h / 2.0).floor() + 0.5);
    c.set_color(color);
    c.cr.set_line_width(1.0);
    c.cr.set_line_cap(abyss_sys::LINE_CAP_SQUARE);
    let seg = |x0, y0, x1, y1| {
        c.cr.move_to(x0, y0);
        c.cr.line_to(x1, y1)
    };
    if up {
        seg(cx, y, cx, cy)
    }
    if down {
        seg(cx, cy, cx, y + h)
    }
    if left {
        seg(x, cy, cx, cy)
    }
    if right {
        seg(cx, cy, x + w, cy)
    }
    c.cr.stroke();
    true
}

/// Paint a screen: chrome, cells, caret. `view_offset` lines back into the
/// scrollback; `selection` in either order.
#[allow(clippy::too_many_arguments)]
pub fn paint_terminal(c: &mut Canvas, w: f64, h: f64, title: &str, screen: &Screen, caret_on: bool, focused: bool, view_offset: usize, selection: Option<(TextPoint, TextPoint)>) {
    paint_window_chrome(c.runner, c.theme, c.cr, w, h, title, false, true);
    let t = c.theme.tokens.clone();
    let grid = grid_rect(&t, w, h);
    c.set_color(BACKGROUND);
    c.cr.rectangle(0.0, t.title_bar_height, w, h - t.title_bar_height);
    c.cr.fill();
    let (cw, ch) = cell_size(&mut c.runner.text);
    let asc = ascent(&c.runner.text);
    let rows = screen.rows().min((grid.h / ch) as usize);
    let cols = screen.cols().min((grid.w / cw) as usize);
    // The first line shown: the screen's first, or that far back.
    let back = screen.scrollback().len();
    let top = back - view_offset.min(back);
    let sel = selection.map(|(a, b)| if a <= b { (a, b) } else { (b, a) });
    let selected = |line: usize, col: usize| sel.is_some_and(|(a, b)| (a..=b).contains(&TextPoint::new(line as i64, col as i64)));
    for r in 0..rows {
        let absolute = top + r;
        let mut line = screen.line(absolute).to_vec();
        line.resize(line.len().max(cols), terminal::Cell::default());
        let y = grid.y + r as f64 * ch;
        let mut col = 0;
        while col < cols {
            // A run: the cells from here with the same attributes.
            let (attrs, is_sel) = (line[col].attrs, selected(absolute, col));
            let mut end = col + 1;
            while end < cols && line[end].attrs == attrs && selected(absolute, end) == is_sel {
                end += 1
            }
            let (mut fg, mut bg) = colors(&attrs);
            if is_sel {
                bg = selection_color();
                if attrs.inverse {
                    fg = FOREGROUND
                }
            }
            let x = grid.x + col as f64 * cw;
            if bg != BACKGROUND {
                c.set_color(bg);
                c.cr.rectangle(x, y, (end - col) as f64 * cw, ch);
                c.cr.fill()
            }
            if !attrs.invisible {
                // Cell by cell, so a glyph wider or narrower than its cell
                // never moves the rest of the line.
                let style = match (attrs.bold, attrs.italic) {
                    (true, true) => Style::BoldItalic,
                    (true, false) => Style::Bold,
                    (false, true) => Style::Italic,
                    (false, false) => Style::Regular,
                };
                for (i, cell) in line.iter().enumerate().take(end).skip(col) {
                    let cx = grid.x + i as f64 * cw;
                    if cell.ch == ' ' || draw_box_character(c, cell.ch, cx, y, cw, ch, fg) {
                        continue;
                    }
                    c.text_left(&cell.ch.to_string(), cx, y + asc, fg, FONT_SIZE, style, Role::Mono)
                }
                if attrs.underline || attrs.strike {
                    c.set_color(fg);
                    c.cr.set_line_width(1.0);
                    let ly = if attrs.underline { y + asc + 1.5 } else { y + ch / 2.0 };
                    c.cr.move_to(x, ly);
                    c.cr.line_to(x + (end - col) as f64 * cw, ly);
                    c.cr.stroke()
                }
            }
            col = end
        }
    }
    // The caret: a block with focus and the blink on, an outline without
    // focus: where the next character goes.
    let (cr_row, cr_col) = (screen.cursor_row(), screen.cursor_col());
    if view_offset == 0 && screen.cursor_visible() && cr_row < rows && cr_col < cols {
        let (x, y) = (grid.x + cr_col as f64 * cw, grid.y + cr_row as f64 * ch);
        if focused {
            if caret_on {
                c.set_color(caret());
                c.cr.rectangle(x, y, cw, ch);
                c.cr.fill();
                let cell = screen.cell(cr_row, cr_col);
                if cell.ch != ' ' {
                    c.text_left(&cell.ch.to_string(), x, y + asc, BACKGROUND, FONT_SIZE, Style::Regular, Role::Mono)
                }
            }
        } else {
            c.set_color(caret());
            c.cr.set_line_width(1.0);
            c.cr.rectangle(x + 0.5, y + 0.5, cw - 1.0, ch - 1.0);
            c.cr.stroke()
        }
    }
}

/// The golden scene's transcript, through the real screen model: a prompt,
/// colours, bold, inverse, a line-drawing box, the caret on the last line.
pub fn sample_screen() -> Screen {
    let mut s = Screen::new(20, 70);
    s.feed_str("$ ls --color\r\n\x1b[1;34mDocuments\x1b[0m  \x1b[1;32mbuild.sh\x1b[0m  notes.txt  \x1b[7m inverse \x1b[m\r\n");
    s.feed_str("$ printf '\\e(0lqqqk\\nx   x\\nmqqqj\\e(B\\n'\r\n\x1b(0lqqqk\r\nx   x\r\nmqqqj\x1b(B\r\n");
    s.feed_str("\x1b[31mred\x1b[m \x1b[42;30m green bg \x1b[m \x1b[4munderlined\x1b[m \x1b[38;5;208m208\x1b[m\r\n$ ");
    s
}

fn log(s: &str) {
    eprintln!("Terminal: {s}")
}

// MARK: - A window

struct Press {
    at: Instant,
    point: TextPoint,
    count: u32,
}

pub struct TerminalWindow {
    me: Weak<TerminalWindow>,
    app: Weak<TerminalApp>,
    window: RefCell<Option<Rc<Window>>>,
    pty: RefCell<Pty>,
    pty_fd: i32,
    screen: RefCell<Screen>,
    caret_on: StdCell<bool>,
    pointer: StdCell<(f64, f64)>,
    program: String,
    dumped: RefCell<Vec<String>>,
    dump: bool,
    title: RefCell<String>,
    /// The window size last said.
    announced: StdCell<(i64, i64)>,
    /// How many lines back into the scrollback the view is (0: live).
    view_offset: StdCell<usize>,
    /// Where the press was, and where the pointer is now.
    selection: StdCell<Option<(TextPoint, TextPoint)>>,
    selecting: StdCell<bool>,
    last_press: RefCell<Option<Press>>,
    grid: StdCell<Rect>,
    cell: StdCell<(f64, f64)>,
    /// The shell has gone and its window with it.
    closed: StdCell<bool>,
}

impl TerminalWindow {
    fn new(app: &Rc<TerminalApp>, command: &[String]) -> Option<Rc<TerminalWindow>> {
        let (rows, cols) = (24, 80);
        let env: BTreeMap<String, String> = [("TERM_PROGRAM".to_string(), "AbyssBSD Terminal".to_string())].into();
        let home = std::env::var("HOME").ok();
        let argv: Vec<&str> = command.iter().map(String::as_str).collect();
        let pty = Pty::spawn(&argv, rows, cols, &env, home.as_deref())?;
        let pty_fd = pty.fd().as_raw_fd();
        let pid = pty.pid();
        let (cw, ch) = cell_size(&mut app.toolkit.runner.borrow_mut().text);
        let t = app.toolkit.theme.borrow().tokens.clone();
        let width = (cols as f64 * cw + 2.0 * PADDING).ceil() as i32;
        let height = (t.title_bar_height + PADDING + rows as f64 * ch + PADDING.max(t.chrome_resize_band)).ceil() as i32;
        let w = Rc::new_cyclic(|me| TerminalWindow {
            me: me.clone(),
            app: Rc::downgrade(app),
            window: RefCell::new(None),
            pty: RefCell::new(pty),
            pty_fd,
            screen: RefCell::new(Screen::new(rows, cols)),
            caret_on: StdCell::new(true),
            pointer: StdCell::new((0.0, 0.0)),
            program: command[0].rsplit('/').next().unwrap_or(&command[0]).to_string(),
            dumped: RefCell::default(),
            dump: std::env::var_os("ABYSS_TERMINAL_DUMP").is_some(),
            title: RefCell::default(),
            announced: StdCell::new((0, 0)),
            view_offset: StdCell::new(0),
            selection: StdCell::new(None),
            selecting: StdCell::new(false),
            last_press: RefCell::new(None),
            grid: StdCell::new(Rect::default()),
            cell: StdCell::new((cw, ch)),
            closed: StdCell::new(false),
        });
        let pinned = std::env::var("AQUA_SCALE").ok().and_then(|s| s.parse::<i32>().ok()).filter(|v| *v > 0);
        let win = Window::new(&app.display, "", "org.abyssbsd.terminal", width, height, pinned.unwrap_or(1), pinned.is_none(), Rc::downgrade(&w) as Weak<dyn WindowDelegate>)?;
        *w.window.borrow_mut() = Some(win);
        w.update_title();
        let me = w.me.clone();
        app.display.add_fd(pty_fd, move || {
            if let Some(w) = me.upgrade() {
                w.pty_readable()
            }
        });
        log(&format!("window: {} (pid {pid}) {cols}x{rows}, cell {}x{}", command.join(" "), two_places(cw), two_places(ch)));
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

    fn update_title(&self) {
        let s = self.screen.borrow();
        let t = format!("{} — {}×{}", if s.title().is_empty() { &self.program } else { s.title() }, s.cols(), s.rows());
        if *self.title.borrow() != t {
            if let Some(w) = self.window() {
                w.set_title(&t)
            }
            *self.title.borrow_mut() = t
        }
    }

    fn pty_readable(&self) {
        let read = self.pty.borrow_mut().read();
        let Some(bytes) = read else { return self.shell_exited() };
        if bytes.is_empty() {
            return;
        }
        let responses = {
            let mut s = self.screen.borrow_mut();
            let before = s.scrollback().len();
            s.feed(&bytes);
            // Scrolled back, the view stays on the lines being read while
            // new ones arrive below.
            let v = self.view_offset.get();
            if v > 0 {
                let after = s.scrollback().len();
                self.view_offset.set(after.min(v + after.saturating_sub(before)))
            }
            std::mem::take(&mut s.responses)
        };
        if !responses.is_empty() {
            self.pty.borrow_mut().write(&responses);
        }
        self.caret_on.set(true);
        self.update_title();
        if self.dump {
            self.dump_rows()
        }
        self.redraw()
    }

    fn shell_exited(&self) {
        let status = self.pty.borrow_mut().reap();
        log(&format!("the shell exited{}", status.map_or(String::new(), |s| format!(" (status {s})"))));
        self.close()
    }

    pub fn close(&self) {
        if self.closed.replace(true) {
            return;
        }
        if let Some(app) = self.app.upgrade() {
            app.display.remove_fd(self.pty_fd)
        }
        if let Some(w) = self.window.borrow_mut().take() {
            w.close()
        }
        if let (Some(app), Some(me)) = (self.app.upgrade(), self.me.upgrade()) {
            app.window_closed(&me)
        }
    }

    fn dump_rows(&self) {
        let now = self.screen.borrow().lines();
        let mut dumped = self.dumped.borrow_mut();
        for (i, line) in now.iter().enumerate() {
            if dumped.get(i) != Some(line) {
                log(&format!("row {} |{line}|", i + 1))
            }
        }
        *dumped = now
    }

    fn blink(&self) {
        if !self.screen.borrow().cursor_visible() || !self.window().is_some_and(|w| w.is_activated()) {
            return;
        }
        self.caret_on.set(!self.caret_on.get());
        self.redraw()
    }

    /// The text position under a window point: its row in the view, its column.
    fn point(&self, x: f64, y: f64) -> TextPoint {
        let (cw, ch) = self.cell.get();
        let g = self.grid.get();
        let s = self.screen.borrow();
        let col = (((x - g.x) / cw) as i64).clamp(0, s.cols() as i64 - 1);
        let row = (((y - g.y) / ch) as i64).clamp(0, s.rows() as i64 - 1);
        TextPoint::new((s.scrollback().len() - self.view_offset.get()) as i64 + row, col)
    }

    /// Move the view back into the scrollback, or toward the live screen.
    fn scroll_view(&self, offset: i64) {
        let s = self.screen.borrow();
        let n = offset.clamp(0, s.scrollback().len() as i64) as usize;
        if n == self.view_offset.get() {
            return;
        }
        self.view_offset.set(n);
        if self.dump {
            let text: String = s.line(s.scrollback().len() - n).iter().map(|c| c.ch).collect();
            log(&format!("view back {n} top |{}|", text.trim_end_matches(' ')))
        }
        drop(s);
        self.redraw()
    }

    fn selected_text(&self) -> Option<String> {
        let (a, b) = self.selection.get()?;
        Some(self.screen.borrow().text_between(a, b)).filter(|t| !t.is_empty())
    }

    fn select_all(&self) {
        let s = self.screen.borrow();
        let last = s.total_lines().saturating_sub(1);
        self.selection.set(Some((TextPoint::new(0, 0), TextPoint::new(last as i64, s.line(last).len().saturating_sub(1) as i64))));
        drop(s);
        self.redraw()
    }

    fn paste(&self, text: &str) {
        let bracketed = self.screen.borrow().bracketed_paste();
        self.pty.borrow_mut().write(&paste_bytes(text, bracketed));
        self.scroll_view(0);
        if self.dump {
            log(&format!("pasted {} characters{}", text.chars().count(), if bracketed { " (bracketed)" } else { "" }))
        }
    }

    fn clear_scrollback(&self) {
        self.screen.borrow_mut().clear_scrollback();
        self.view_offset.set(0);
        self.selection.set(None);
        log("scrollback cleared");
        self.redraw()
    }
}

impl WindowDelegate for TerminalWindow {
    fn render(&self, w: &Window, target: &RenderTarget) {
        let Some(app) = self.app.upgrade() else { return };
        let focused = w.is_activated();
        let (caret_on, view, sel) = (self.caret_on.get(), self.view_offset.get(), self.selection.get());
        app.toolkit.draw(target, |c, w, h| {
            // The window's size is the shell's: the rows and columns that fit.
            let (cw, ch) = cell_size(&mut c.runner.text);
            self.cell.set((cw, ch));
            let t = c.theme.tokens.clone();
            let g = grid_rect(&t, w, h);
            self.grid.set(g);
            let (cols, rows) = (((g.w / cw) as usize).max(2), ((g.h / ch) as usize).max(1));
            let changed = {
                let mut s = self.screen.borrow_mut();
                let changed = rows != s.rows() || cols != s.cols();
                if changed {
                    s.resize(rows, cols);
                    self.pty.borrow().resize(rows, cols)
                }
                changed
            };
            if changed {
                self.selection.set(None);
                self.view_offset.set(0);
                self.update_title();
                if self.dump {
                    self.dump_rows()
                }
            }
            if self.announced.get() != (w as i64, h as i64) {
                self.announced.set((w as i64, h as i64));
                log(&format!("size {cols}x{rows}"));
                if self.dump {
                    // Where the frame's buttons were drawn, for a test to press.
                    let gadgets: Vec<String> = window_chrome(&t, w, h, false).gadgets.iter().map(|p| format!("{}={},{}", p.gadget.name(), (p.rect.x + p.rect.w / 2.0) as i64, (p.rect.y + p.rect.h / 2.0) as i64)).collect();
                    log(&format!("chrome {}x{} {} grid={},{} cell={}x{}", w as i64, h as i64, gadgets.join(" "), two_places(g.x), two_places(g.y), two_places(cw), two_places(ch)))
                }
            }
            let (view, sel) = if changed { (0, None) } else { (view, sel) };
            let title = self.title.borrow().clone();
            paint_terminal(c, w, h, &title, &self.screen.borrow(), caret_on, focused, view, sel)
        })
    }

    fn pointer_moved(&self, _w: &Window, x: f64, y: f64) {
        self.pointer.set((x, y));
        let (true, Some((a, _))) = (self.selecting.get(), self.selection.get()) else { return };
        let p = self.point(x, y);
        let sel = if self.last_press.borrow().as_ref().is_some_and(|l| l.count == 2) {
            // A double-click drag grows by words.
            let s = self.screen.borrow();
            let ((s0, e0), (s1, e1)) = (s.word_range(a), s.word_range(p));
            if p < a { (e0, s1) } else { (s0, e1) }
        } else {
            (a, p)
        };
        self.selection.set(Some(sel));
        self.redraw()
    }

    fn pointer_button(&self, w: &Window, button: u32, pressed: bool) {
        if !pressed {
            if let (true, Some((a, b))) = (self.selecting.get(), self.selection.get()) {
                if self.dump {
                    log(&format!("selection {}:{}-{}:{} ({} characters)", a.line, a.col, b.line, b.col, self.screen.borrow().text_between(a, b).chars().count()))
                }
                if a == b && self.last_press.borrow().as_ref().is_some_and(|l| l.count == 1) {
                    self.selection.set(None)
                }
            }
            self.selecting.set(false);
            return self.redraw();
        }
        let Some(app) = self.app.upgrade() else { return };
        let (x, y) = self.pointer.get();
        let (sw, sh) = w.size();
        let t = app.toolkit.theme.borrow().tokens.clone();
        match chrome_hit(&t, &window_chrome(&t, sw as f64, sh as f64, false), x, y) {
            ChromeHit::Gadget(Gadget::Close) => return self.close(),
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
            return; // BTN_LEFT
        }
        // Clicks within half a second on the same place count up: a word, a line.
        let p = self.point(x, y);
        let count = match &*self.last_press.borrow() {
            Some(l) if l.at.elapsed().as_millis() < 500 && l.point.line == p.line && (l.point.col - p.col).abs() <= 1 => l.count % 3 + 1,
            _ => 1,
        };
        *self.last_press.borrow_mut() = Some(Press { at: Instant::now(), point: p, count });
        let sel = {
            let s = self.screen.borrow();
            match count {
                2 => s.word_range(p),
                3 => s.line_range(p),
                _ => (p, p),
            }
        };
        self.selection.set(Some(sel));
        self.selecting.set(true);
        if count > 1 && self.dump {
            log(&format!("selected {} |{}|", if count == 2 { "word" } else { "line" }, self.screen.borrow().text_between(sel.0, sel.1)))
        }
        self.redraw()
    }

    /// Vertical only, and only where there is history: the alternate
    /// screen (vi, less) has none.
    fn pointer_axis(&self, _w: &Window, axis: u32, value: f64) {
        if axis != 0 || self.screen.borrow().using_alternate() {
            return;
        }
        let lines = (value / 10.0 * 3.0).round() as i64;
        if lines != 0 {
            self.scroll_view(self.view_offset.get() as i64 - lines)
        }
    }

    fn key_event(&self, _w: &Window, e: &KeyEvent) {
        if !e.pressed {
            return;
        }
        if e.modifiers.contains(KeyModifiers::COMMAND) {
            if let Some(app) = self.app.upgrade()
                && let Some(verb) = key_equivalent_of(e).and_then(|k| terminal_menu_bar().verb_for(&k).map(String::from))
                && let CommandResult::Refused(why) = app.perform(&verb, self.me.upgrade())
            {
                log(&format!("{verb} refused: {why}"))
            }
            return;
        }
        let shift = e.modifiers.contains(KeyModifiers::SHIFT);
        // Mac Terminal: Page Up/Down, Home and End move through the history;
        // with Shift, or on the alternate screen, they go to the program.
        let (alternate, rows, back) = { let s = self.screen.borrow(); (s.using_alternate(), s.rows(), s.scrollback().len()) };
        if !alternate && !shift {
            let (page, v) = (rows.saturating_sub(1).max(1) as i64, self.view_offset.get() as i64);
            match e.keysym {
                sym::PAGE_UP => return self.scroll_view(v + page),
                sym::PAGE_DOWN => return self.scroll_view(v - page),
                sym::HOME => return self.scroll_view(back as i64),
                sym::END => return self.scroll_view(0),
                _ => {}
            }
        }
        let mods = KeyMods { shift, option: e.modifiers.contains(KeyModifiers::ALT), control: e.modifiers.contains(KeyModifiers::CONTROL) };
        let bytes = encode(e.keysym, &e.text, mods, self.screen.borrow().application_cursor_keys());
        if self.dump {
            log(&format!("key 0x{:x} text={:?} mods={} -> {bytes:?}", e.keysym, e.text.as_bytes(), e.modifiers.0))
        }
        if bytes.is_empty() {
            return;
        }
        self.pty.borrow_mut().write(&bytes);
        self.scroll_view(0); // typing returns to the live screen
        self.caret_on.set(true);
        self.redraw()
    }

    fn should_close(&self, _w: &Window) {
        self.close()
    }

    fn state_changed(&self, w: &Window) {
        self.caret_on.set(true);
        w.set_needs_display()
    }
}

// MARK: - The application

pub struct TerminalApp {
    me: Weak<TerminalApp>,
    display: Rc<Display>,
    toolkit: Rc<Toolkit>,
    windows: RefCell<Vec<Rc<TerminalWindow>>>,
    menu_service: RefCell<Option<MenuService>>,
    menu_name: String,
    command: Vec<String>,
    /// What this process last copied: the clipboard will not read back a
    /// selection its own process owns, so a paste of our own copy uses this.
    last_copied: RefCell<Option<String>>,
}

struct Provider<'a>(&'a TerminalApp);

impl MenuProvider for Provider<'_> {
    fn menu_model(&self) -> MenuBarModel {
        terminal_menu_bar()
    }
    fn menu_validate(&self, c: &Command) -> Enablement {
        self.0.validate(&c.verb)
    }
    fn menu_perform(&mut self, c: &Command, _a: &BTreeMap<String, String>) -> CommandResult {
        if let Enablement::Disabled(why) = self.0.validate(&c.verb) {
            return CommandResult::Refused(why);
        }
        let front = self.0.front(true);
        self.0.perform(&c.verb, front)
    }
}

impl TerminalApp {
    /// The person's shell (`$SHELL`, else /bin/sh), or `command` when
    /// given: a bundle whose program needs a terminal runs in one.
    pub fn new(display: &Rc<Display>, toolkit: &Rc<Toolkit>, command: Option<Vec<String>>) -> Rc<TerminalApp> {
        let shell = std::env::var("SHELL").ok().filter(|s| !s.is_empty()).unwrap_or_else(|| "/bin/sh".into());
        let menu_name = menu_wire::service_name("Terminal", std::process::id() as i32);
        let service = MenuService::new(&menu_name).ok();
        let app = Rc::new_cyclic(|me| TerminalApp {
            me: me.clone(),
            display: display.clone(),
            toolkit: toolkit.clone(),
            windows: RefCell::default(),
            menu_service: RefCell::new(service),
            menu_name,
            command: command.filter(|c| !c.is_empty()).unwrap_or_else(|| vec![shell]),
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
                let ws = a.windows.borrow().clone();
                ws.iter().for_each(|w| w.blink())
            }
        });
        app
    }

    fn serve(&self) {
        let svc = self.menu_service.borrow_mut().take();
        let Some(mut svc) = svc else { return };
        svc.service_readable(&mut Provider(self));
        *self.menu_service.borrow_mut() = Some(svc)
    }

    /// Open a window with a new shell; false if neither could be started.
    pub fn open_window(&self) -> bool {
        let Some(me) = self.me.upgrade() else { return false };
        let Some(w) = TerminalWindow::new(&me, &self.command) else {
            log(&format!("could not start {} on a new terminal", self.command.join(" ")));
            return false;
        };
        if let Some(win) = w.window()
            && win.publish_menus(&self.menu_name)
        {
            log(&format!("menus on {}", self.menu_name))
        }
        self.windows.borrow_mut().push(w);
        true
    }

    fn window_closed(&self, w: &Rc<TerminalWindow>) {
        self.windows.borrow_mut().retain(|x| !Rc::ptr_eq(x, w));
        if self.windows.borrow().is_empty() {
            log("the last window closed");
            std::process::exit(0)
        }
    }

    /// The window in front: the activated one, else (unless `active_only`)
    /// the newest.
    fn front(&self, active_only: bool) -> Option<Rc<TerminalWindow>> {
        let ws = self.windows.borrow();
        ws.iter().find(|w| w.window().is_some_and(|x| x.is_activated())).cloned().or(if active_only { None } else { ws.last().cloned() })
    }

    fn clipboard_text(&self) -> Option<String> {
        match self.display.clipboard() {
            Some(c) if !c.owns_selection() => c.read_text(),
            _ => self.last_copied.borrow().clone(),
        }
    }

    fn validate(&self, verb: &str) -> Enablement {
        let none = self.windows.borrow().is_empty();
        match verb {
            VERB_ABOUT => Enablement::Disabled("Terminal has no About box yet".into()),
            VERB_QUIT | VERB_NEW_WINDOW => Enablement::Enabled,
            VERB_CLOSE | VERB_MINIMIZE | VERB_SELECT_ALL | VERB_CLEAR_SCROLLBACK if none => Enablement::Disabled("no window".into()),
            VERB_CLOSE | VERB_MINIMIZE | VERB_SELECT_ALL | VERB_CLEAR_SCROLLBACK => Enablement::Enabled,
            VERB_COPY if self.front(false).and_then(|w| w.selected_text()).is_none() => Enablement::Disabled("nothing is selected".into()),
            VERB_COPY => Enablement::Enabled,
            VERB_PASTE if self.display.clipboard().is_some_and(|c| c.offers(&[mime::TEXT])) || self.last_copied.borrow().is_some() => Enablement::Enabled,
            VERB_PASTE => Enablement::Disabled("the clipboard holds no text".into()),
            v => Enablement::Disabled(format!("Terminal has no verb {v}")),
        }
    }

    fn perform(&self, verb: &str, w: Option<Rc<TerminalWindow>>) -> CommandResult {
        let front = w.clone().or_else(|| self.front(false));
        let ok = || CommandResult::Ok(None);
        match verb {
            VERB_COPY => {
                let Some(t) = front.and_then(|f| f.selected_text()) else { return CommandResult::Refused("nothing is selected".into()) };
                if !self.display.clipboard().is_some_and(|c| c.write_text(&t)) {
                    return CommandResult::Refused("the clipboard would not take it".into());
                }
                log(&format!("copied {} characters", t.chars().count()));
                *self.last_copied.borrow_mut() = Some(t);
                ok()
            }
            VERB_PASTE => match (front, self.clipboard_text().filter(|t| !t.is_empty())) {
                (Some(f), Some(t)) => {
                    f.paste(&t);
                    ok()
                }
                _ => CommandResult::Refused("the clipboard holds no text".into()),
            },
            VERB_SELECT_ALL => {
                front.inspect(|f| f.select_all());
                ok()
            }
            VERB_CLEAR_SCROLLBACK => {
                front.inspect(|f| f.clear_scrollback());
                ok()
            }
            VERB_QUIT => std::process::exit(0),
            VERB_NEW_WINDOW if self.open_window() => ok(),
            VERB_NEW_WINDOW => CommandResult::Refused("no new shell could be started".into()),
            VERB_CLOSE => match front {
                Some(f) => {
                    f.close();
                    ok()
                }
                None => CommandResult::Refused("no window".into()),
            },
            VERB_MINIMIZE => match front.and_then(|f| f.window()) {
                Some(win) => {
                    win.minimize();
                    ok()
                }
                None => CommandResult::Refused("no window".into()),
            },
            v => CommandResult::Refused(format!("Terminal has no verb {v}")),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn xterms_colours() {
        assert_eq!(term_color(TermColor::Indexed(1), FOREGROUND), Color::hex(0xCD0000, 1.0));
        assert_eq!(term_color(TermColor::Indexed(16), FOREGROUND), Color::new(0.0, 0.0, 0.0, 1.0));
        assert_eq!(term_color(TermColor::Indexed(231), FOREGROUND), Color::new(1.0, 1.0, 1.0, 1.0));
        assert_eq!(term_color(TermColor::Indexed(232), FOREGROUND), Color::new(8.0 / 255.0, 8.0 / 255.0, 8.0 / 255.0, 1.0));
        let bold_red = CellAttributes { bold: true, fg: TermColor::Indexed(1), ..CellAttributes::default() };
        assert_eq!(colors(&bold_red).0, Color::hex(0xFF0000, 1.0), "bold brightens the first eight");
    }

    #[test]
    fn the_menus_say_their_keys() {
        let bar = terminal_menu_bar();
        assert_eq!(bar.verb_for(&KeyEquivalent::cmd('k', Modifiers::NONE)), Some(VERB_CLEAR_SCROLLBACK));
        assert_eq!(bar.verb_for(&KeyEquivalent::cmd('n', Modifiers::NONE)), Some(VERB_NEW_WINDOW));
    }
}
