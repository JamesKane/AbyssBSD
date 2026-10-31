//! The toolkit's multi-line text (TextView.swift, P15.5): a `TextModel` on
//! screen, wrapped by `TextLayout` to the view's width, scrolled, drawn,
//! and driven by keys and the pointer. A toolkit piece, not TextEdit's: it
//! knows nothing of files, menus or windows. Its owner gives it a rect,
//! forwards events, and learns from `edit` whether the text changed.
//!
//! **Fixed pitch, for now** (the theme's `mono` role): every cluster one
//! cell wide and a tab four, so caret, click and selection positions are
//! exact with no per-glyph measurement.

use aquadraw::canvas::Canvas;
use aquadraw::color::Color;
use aquadraw::drawlist::Role;
use aquadraw::runner::Rect;
use aquadraw::text::{Style, Text};
use std::time::Instant;
use surface::{KeyEvent, KeyModifiers, KeySym};
use text_model::{Motion, TextLayout, TextModel, TextPosition, VisualRow};

pub const FONT_SIZE: f64 = 12.0;
pub const TAB_CELLS: f64 = 4.0;
pub const INSET: f64 = 6.0;
const BACKGROUND: Color = Color::new(1.0, 1.0, 1.0, 1.0);
const TEXT: Color = Color::new(0.0, 0.0, 0.0, 1.0);
const CARET: Color = Color::new(0.0, 0.0, 0.0, 1.0);
fn selection_color() -> Color {
    Color::hex(0xB5D5FF, 1.0)
}

/// One cell of the `mono` role at the text's render scale: its width, and
/// a row's height.
pub fn cell(text: &mut Text) -> (f64, f64) {
    let scale = f64::from(text.render_scale);
    let w = text.text_width("M", FONT_SIZE, Style::Regular, Role::Mono);
    let m = Text::metrics(text.px(FONT_SIZE), Role::Mono);
    (w.max(1.0), (((m.ascent + m.descent) / scale).ceil() + 2.0).max(1.0))
}

struct Press {
    at: Instant,
    pos: TextPosition,
    count: u32,
}

pub struct TextView {
    pub model: TextModel,
    /// Where the view is in its owner, in the owner's coordinates.
    frame: Rect,
    /// How far down the text the view is scrolled, in points.
    scroll_y: f64,
    pub caret_on: bool,
    /// The wrapped rows, rebuilt when the text, the width or the cell
    /// changes.
    rows: Option<Vec<VisualRow>>,
    cell: (f64, f64),
    ascent: f64,
    dragging: bool,
    last_press: Option<Press>,
}

impl TextView {
    /// `cell` and `ascent` as `measure` gives them; a paint keeps them up.
    pub fn new(text: &str, measure: &mut Text) -> TextView {
        let mut v = TextView { model: TextModel::new(""), frame: Rect::default(), scroll_y: 0.0, caret_on: true, rows: None, cell: (7.0, 15.0), ascent: 11.0, dragging: false, last_press: None };
        v.measure(measure);
        v.set_text(text);
        v
    }

    fn measure(&mut self, text: &mut Text) {
        let c = cell(text);
        if c != self.cell {
            self.cell = c;
            self.rows = None
        }
        self.ascent = Text::metrics(text.px(FONT_SIZE), Role::Mono).ascent / f64::from(text.render_scale)
    }

    pub fn cell_size(&self) -> (f64, f64) {
        self.cell
    }
    pub fn frame(&self) -> Rect {
        self.frame
    }

    /// A new place. A new size means new rows, and the caret kept in sight
    /// in them.
    pub fn set_frame(&mut self, r: Rect) {
        let resized = r.w != self.frame.w || r.h != self.frame.h;
        self.frame = r;
        if resized {
            self.rows = None;
            if r.w > 1.0 && r.h > 1.0 {
                self.scroll_to_caret()
            }
        }
    }

    fn text_rect(&self) -> Rect {
        let f = self.frame;
        Rect::new(f.x + INSET, f.y + INSET / 2.0, (f.w - 2.0 * INSET).max(1.0), (f.h - INSET).max(1.0))
    }

    fn row_height(&self) -> f64 {
        self.cell.1
    }

    /// Ask the layout something, wrapping first if the rows are stale.
    fn with_layout<R>(&mut self, f: impl FnOnce(&TextLayout<'_, &dyn Fn(&str) -> f64>, &TextModel) -> R) -> R {
        let cw = self.cell.0;
        let advance = move |c: &str| if c == "\t" { cw * TAB_CELLS } else { cw };
        let adv: &dyn Fn(&str) -> f64 = &advance;
        let width = self.text_rect().w;
        let rows = match self.rows.take() {
            Some(r) => r,
            None => TextLayout::new(self.model.lines(), width, adv).rows,
        };
        let l = TextLayout::with_rows(self.model.lines(), width, rows, adv);
        let out = f(&l, &self.model);
        self.rows = Some(l.rows);
        out
    }

    // MARK: changing it

    /// Replace the whole text (a document just opened); history starts here.
    pub fn set_text(&mut self, s: &str) {
        self.model = TextModel::new(s);
        self.model.mark_saved();
        self.rows = None;
        self.scroll_y = 0.0
    }

    /// Do something to the model and keep the view in step: the layout,
    /// the caret in sight. Whether the text changed.
    pub fn edit(&mut self, f: impl FnOnce(&mut TextModel)) -> bool {
        let before = self.model.text();
        f(&mut self.model);
        let changed = self.model.text() != before;
        if changed {
            self.rows = None
        }
        self.caret_on = true;
        self.scroll_to_caret();
        changed
    }

    pub fn scroll_to_caret(&mut self) {
        let row = self.with_layout(|l, m| l.row_of(m.caret()));
        let (y, rh, h) = (row as f64 * self.row_height(), self.row_height(), self.text_rect().h);
        if y < self.scroll_y {
            self.scroll_y = y
        } else if y + rh > self.scroll_y + h {
            self.scroll_y = y + rh - h
        }
        self.clamp_scroll()
    }

    pub fn scroll_by(&mut self, dy: f64) {
        self.scroll_y += dy;
        self.clamp_scroll()
    }

    fn clamp_scroll(&mut self) {
        let content = self.with_layout(|l, _| l.rows.len()) as f64 * self.row_height();
        self.scroll_y = self.scroll_y.min((content - self.text_rect().h).max(0.0)).max(0.0)
    }

    // MARK: drawing

    pub fn paint(&mut self, c: &mut Canvas, focused: bool) {
        self.measure(&mut c.runner.text);
        let f = self.frame;
        c.set_color(BACKGROUND);
        c.cr.rectangle(f.x, f.y, f.w, f.h);
        c.cr.fill();
        c.cr.save();
        c.cr.rectangle(f.x, f.y, f.w, f.h);
        c.cr.clip();
        let (r, rh, cw, asc, scroll) = (self.text_rect(), self.row_height(), self.cell.0, self.ascent, self.scroll_y);
        let sel = self.model.selection();
        let rows = self.with_layout(|l, _| l.rows.clone());
        let first = (scroll / rh).max(0.0) as usize;
        let last = (((scroll + r.h) / rh) as usize + 1).min(rows.len().saturating_sub(1));
        let x_in = |row: &VisualRow, line: &text_model::Line, col: usize| -> f64 { (row.start..col.max(row.start).min(row.end)).map(|i| if line.cluster(i) == "\t" { cw * TAB_CELLS } else { cw }).sum() };
        for (i, row) in rows.iter().enumerate().take(last + 1).skip(first) {
            let line = &self.model.lines()[row.line];
            let y = r.y + i as f64 * rh - scroll;
            // The selection's part of this row, and past its end the newline
            // it includes, as a Mac draws it.
            if !sel.is_empty() {
                let (a, b) = (TextPosition::new(row.line, row.start), TextPosition::new(row.line, row.end));
                let (s, e) = (sel.start.max(a), sel.end.min(b));
                let newline = sel.end > b && row.end == line.len();
                if s < e || (newline && sel.start <= b) {
                    // x within *this* row: a position at a wrap belongs to the
                    // next row, but ends this one here.
                    let x0 = x_in(row, line, if s < e { s.column } else { row.end });
                    let x1 = if newline { r.w } else { x_in(row, line, e.column) };
                    c.set_color(selection_color());
                    c.cr.rectangle(r.x + x0, y, (x1 - x0).max(0.0), rh);
                    c.cr.fill()
                }
            }
            if row.end > row.start {
                // Each tab as four spaces: what fixed pitch shows for one.
                let s = line.text(row.start, row.end).replace('\t', "    ");
                c.text_left(&s, r.x, y + asc + 1.0, TEXT, FONT_SIZE, Style::Regular, Role::Mono)
            }
        }
        // The caret: a thin bar, where the next character goes.
        if focused && self.caret_on && sel.is_empty() {
            let (row, cx) = self.with_layout(|l, m| (l.row_of(m.caret()), l.x_of(m.caret())));
            let x = (r.x + cx).floor() + 0.5;
            let y = r.y + row as f64 * rh - scroll;
            c.set_color(CARET);
            c.cr.set_line_width(1.0);
            c.cr.move_to(x, y + 1.0);
            c.cr.line_to(x, y + rh - 1.0);
            c.cr.stroke()
        }
        c.cr.restore()
    }

    // MARK: keys

    /// Up or Down by `delta` rows, keeping the column a person was in.
    fn vertical(&mut self, delta: isize, shift: bool) -> bool {
        let (target, goal) = self.with_layout(|l, m| {
            let goal = m.goal_x.unwrap_or_else(|| l.x_of(m.caret()));
            (l.vertical(m.caret(), delta, goal), goal)
        });
        self.edit(|m| {
            let p = target.unwrap_or(if delta < 0 { TextPosition::START } else { m.end() });
            m.set_caret(p, shift, true);
            m.goal_x = Some(goal)
        })
    }

    /// Handle a key: whether it was the view's (Command chords the
    /// application's menus own are not), and whether the text changed.
    pub fn key(&mut self, e: &KeyEvent) -> Option<bool> {
        if !e.pressed {
            return None;
        }
        let shift = e.modifiers.contains(KeyModifiers::SHIFT);
        let cmd = e.modifiers.contains(KeyModifiers::COMMAND);
        let opt = e.modifiers.contains(KeyModifiers::ALT);
        let page = ((self.text_rect().h / self.row_height()) as isize - 1).max(1);
        Some(match e.keysym {
            KeySym::LEFT | KeySym::RIGHT => {
                let left = e.keysym == KeySym::LEFT;
                if cmd {
                    // The visual row's ends, as a Mac's Command-arrow.
                    let p = self.with_layout(|l, m| {
                        let row = l.rows[l.row_of(m.caret())];
                        let n = m.lines()[row.line].len();
                        TextPosition::new(row.line, if left { row.start } else if row.end < n { row.start.max(row.end - 1) } else { row.end })
                    });
                    self.edit(|m| m.set_caret(p, shift, false))
                } else {
                    let motion = match (opt, left) {
                        (true, true) => Motion::WordLeft,
                        (true, false) => Motion::WordRight,
                        (false, true) => Motion::Left,
                        (false, false) => Motion::Right,
                    };
                    self.edit(|m| m.move_caret(motion, shift))
                }
            }
            KeySym::UP if cmd => self.edit(|m| m.move_caret(Motion::DocumentStart, shift)),
            KeySym::UP => self.vertical(-1, shift),
            KeySym::DOWN if cmd => self.edit(|m| m.move_caret(Motion::DocumentEnd, shift)),
            KeySym::DOWN => self.vertical(1, shift),
            KeySym::HOME => self.edit(|m| m.move_caret(Motion::DocumentStart, shift)),
            KeySym::END => self.edit(|m| m.move_caret(Motion::DocumentEnd, shift)),
            KeySym::PAGE_UP => self.vertical(-page, shift),
            KeySym::PAGE_DOWN => self.vertical(page, shift),
            KeySym::BACKSPACE => self.edit(|m| m.delete_backward(opt)),
            KeySym::DELETE => self.edit(|m| m.delete_forward(opt)),
            KeySym::ENTER => self.edit(|m| m.insert("\n", text_model::EditKind::Typing)),
            KeySym::TAB => self.edit(|m| m.insert("\t", text_model::EditKind::Typing)),
            _ => {
                if cmd || e.modifiers.contains(KeyModifiers::CONTROL) || e.text.is_empty() || !e.text.chars().all(|c| c as u32 >= 0x20 && c as u32 != 0x7f) {
                    return None;
                }
                let t = e.text.clone();
                self.edit(|m| m.insert(&t, text_model::EditKind::Typing))
            }
        })
    }

    // MARK: the pointer

    pub fn contains(&self, x: f64, y: f64) -> bool {
        self.frame.contains(x, y)
    }

    fn position(&mut self, x: f64, y: f64) -> TextPosition {
        let r = self.text_rect();
        let row = ((y - r.y + self.scroll_y) / self.row_height()).floor() as isize;
        self.with_layout(|l, _| l.position(row, x - r.x))
    }

    /// Clicks within half a second on the same place count up: a word, a line.
    pub fn pointer_pressed(&mut self, x: f64, y: f64, shift: bool) {
        let p = self.position(x, y);
        let count = match &self.last_press {
            Some(l) if l.at.elapsed().as_millis() < 500 && l.pos.line == p.line && l.pos.column.abs_diff(p.column) <= 1 => l.count % 3 + 1,
            _ => 1,
        };
        self.last_press = Some(Press { at: Instant::now(), pos: p, count });
        self.dragging = true;
        self.edit(|m| match count {
            2 => m.select(m.word_range(p)),
            3 => m.select(m.line_range(p)),
            _ => m.set_caret(p, shift, false),
        });
    }

    pub fn pointer_moved(&mut self, x: f64, y: f64) -> bool {
        if !self.dragging {
            return false;
        }
        let p = self.position(x, y);
        self.edit(|m| m.set_caret(p, true, false));
        true
    }

    pub fn pointer_released(&mut self) {
        self.dragging = false
    }
}
