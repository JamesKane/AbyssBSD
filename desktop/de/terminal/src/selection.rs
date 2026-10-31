//! The screen's text across its scrollback, for Copy (Selection.swift,
//! P15.4c): every line addressed as one sequence, oldest scrollback first,
//! so a selection can start in history and end on the screen. And what a
//! paste sends the program.

use crate::screen::{Cell, Screen};

/// A place in the text: `line` counts from the oldest line of scrollback
/// (0) through the screen's rows; `col` is a column in that line. Ordered
/// by line, then column.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct TextPoint {
    pub line: i64,
    pub col: i64,
}

impl TextPoint {
    pub fn new(line: i64, col: i64) -> TextPoint {
        TextPoint { line, col }
    }
}

/// Letters, digits, and what paths and URLs are made of.
fn in_word(c: char) -> bool {
    c.is_alphabetic() || c.is_ascii_digit() || "-_./~:@%+=?&#".contains(c)
}

impl Screen {
    /// Scrollback and screen, as one count.
    pub fn total_lines(&self) -> usize {
        self.scrollback().len() + self.rows()
    }

    /// Line `i` of the whole: scrollback, then the screen's rows.
    pub fn line(&self, i: usize) -> &[Cell] {
        let n = self.scrollback().len();
        if i < n { &self.scrollback()[i] } else { &self.grid()[i - n] }
    }

    /// The text from `a` to `b` inclusive, either order. A line that
    /// wrapped continues into the next with no newline (a long command
    /// copies as one line); any other ends with one and loses its trailing
    /// spaces, as xterm copies.
    pub fn text_between(&self, a: TextPoint, b: TextPoint) -> String {
        let (s, e) = if a <= b { (a, b) } else { (b, a) };
        let total = self.total_lines() as i64;
        let (first, last) = (s.line.max(0), e.line.min(total - 1));
        if total == 0 || first > last {
            return String::new();
        }
        let mut out = String::new();
        for i in first..=last {
            let cells = self.line(i as usize);
            if cells.is_empty() {
                if i < last {
                    out.push('\n')
                }
                continue;
            }
            let end = cells.len() as i64 - 1;
            let from = if i == s.line { s.col.clamp(0, end) } else { 0 };
            let to = if i == e.line { e.col.clamp(0, end) } else { end };
            let mut piece: String = if from <= to { cells[from as usize..=to as usize].iter().map(|c| c.ch).collect() } else { String::new() };
            let wraps = cells[end as usize].wraps_to_next && to == end;
            if !wraps {
                piece.truncate(piece.trim_end_matches(' ').len())
            }
            out += &piece;
            if i < last && !wraps {
                out.push('\n')
            }
        }
        out
    }

    /// The word around `p`, or the one character there if it is in none:
    /// what a double-click selects.
    pub fn word_range(&self, p: TextPoint) -> (TextPoint, TextPoint) {
        if p.line < 0 || p.line >= self.total_lines() as i64 {
            return (p, p);
        }
        let cells = self.line(p.line as usize);
        if p.col < 0 || p.col >= cells.len() as i64 || !in_word(cells[p.col as usize].ch) {
            return (p, p);
        }
        let (mut a, mut b) = (p.col as usize, p.col as usize);
        while a > 0 && in_word(cells[a - 1].ch) {
            a -= 1
        }
        while b + 1 < cells.len() && in_word(cells[b + 1].ch) {
            b += 1
        }
        (TextPoint::new(p.line, a as i64), TextPoint::new(p.line, b as i64))
    }

    /// The whole line at `p`: what a triple-click selects.
    pub fn line_range(&self, p: TextPoint) -> (TextPoint, TextPoint) {
        let n = if p.line >= 0 && p.line < self.total_lines() as i64 { self.line(p.line as usize).len() } else { self.cols() };
        (TextPoint::new(p.line, 0), TextPoint::new(p.line, (n as i64 - 1).max(0)))
    }

    /// Forget the history (Clear Scrollback, ⌘K). The screen stays.
    pub fn clear_scrollback(&mut self) {
        self.feed(b"\x1b[3J")
    }
}

/// What a paste sends: newlines become carriage returns (the Return key's
/// byte). When the program asked for bracketed paste (`CSI ?2004h`), it is
/// wrapped in `CSI 200~` … `CSI 201~`, and an end marker *inside* the text
/// is removed, or pasted text could end the bracket and run commands.
pub fn paste_bytes(text: &str, bracketed: bool) -> Vec<u8> {
    let t = text.as_bytes();
    let mut out = Vec::with_capacity(t.len());
    let mut i = 0;
    while i < t.len() {
        if t[i] == b'\r' && t.get(i + 1) == Some(&b'\n') {
            out.push(b'\r');
            i += 2;
            continue;
        }
        out.push(if t[i] == b'\n' { b'\r' } else { t[i] });
        i += 1
    }
    if !bracketed {
        return out;
    }
    const END: &[u8] = b"\x1b[201~";
    let mut clean = Vec::with_capacity(out.len() + 12);
    clean.extend_from_slice(b"\x1b[200~");
    let mut i = 0;
    while i < out.len() {
        if out[i..].starts_with(END) {
            i += END.len();
            continue;
        }
        clean.push(out[i]);
        i += 1
    }
    clean.extend_from_slice(END);
    clean
}
