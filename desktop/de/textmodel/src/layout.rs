//! The text's lines wrapped to a width (TextLayout.swift, PHASE15 P15.5).
//!
//! A text view shows *visual* rows: a long line wraps after the last space
//! that fits or, for a word longer than the row, inside it. Up and Down move
//! between rows, a click lands in one, the caret is drawn at an x in one, so
//! the mapping between a position and (row, x) lives here, with the one
//! thing only the view knows (how wide a cluster is) passed in.

use crate::model::{Line, TextPosition};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct VisualRow {
    pub line: usize,
    /// Columns [start, end) of `line`.
    pub start: usize,
    pub end: usize,
}

pub struct TextLayout<'a, F: Fn(&str) -> f64> {
    pub width: f64,
    pub rows: Vec<VisualRow>,
    lines: &'a [Line],
    advance: F,
}

impl<'a, F: Fn(&str) -> f64> TextLayout<'a, F> {
    pub fn new(lines: &'a [Line], width: f64, advance: F) -> TextLayout<'a, F> {
        let width = width.max(1.0);
        let rows = lines.iter().enumerate().flat_map(|(i, l)| wrap(l, i, width, &advance)).collect();
        TextLayout { width, rows, lines, advance }
    }

    /// The row the caret at `p` is drawn in. A position exactly at a wrap is
    /// the start of the next row; the end of a line is the end of its last.
    pub fn row_of(&self, p: TextPosition) -> usize {
        let mut found = 0;
        for (i, r) in self.rows.iter().enumerate() {
            if r.line > p.line {
                break;
            }
            if r.line == p.line && r.start <= p.column {
                found = i;
            }
        }
        found
    }

    /// The x of `p` within its row.
    pub fn x_of(&self, p: TextPosition) -> f64 {
        let r = self.rows[self.row_of(p)];
        let line = &self.lines[r.line];
        (r.start..p.column.min(r.end)).map(|c| (self.advance)(line.cluster(c))).sum()
    }

    /// The position nearest `x` in `row`: where a click or Up/Down lands. On
    /// a row a line wraps out of, never its very end (that is the next
    /// row's start): the last boundary before it.
    pub fn position(&self, row: isize, x: f64) -> TextPosition {
        let r = self.rows[row.clamp(0, self.rows.len() as isize - 1) as usize];
        let line = &self.lines[r.line];
        let wraps = r.end < line.len();
        let limit = if wraps && r.end > r.start { r.end - 1 } else { r.end };
        let mut acc = 0.0;
        for c in r.start..limit {
            let w = (self.advance)(line.cluster(c));
            if x < acc + w / 2.0 {
                return TextPosition::new(r.line, c);
            }
            acc += w;
        }
        TextPosition::new(r.line, limit)
    }

    /// Up (-1) or Down (+1) from `p`, keeping `goal_x`; None at the top or
    /// bottom.
    pub fn vertical(&self, p: TextPosition, delta: isize, goal_x: f64) -> Option<TextPosition> {
        let target = self.row_of(p) as isize + delta;
        (0..self.rows.len() as isize).contains(&target).then(|| self.position(target, goal_x))
    }
}

fn wrap(line: &Line, index: usize, width: f64, advance: &impl Fn(&str) -> f64) -> Vec<VisualRow> {
    if line.is_empty() {
        return vec![VisualRow { line: index, start: 0, end: 0 }];
    }
    let mut out = vec![];
    let (mut start, mut x, mut last_break, mut i) = (0, 0.0, None::<usize>, 0);
    while i < line.len() {
        let w = advance(line.cluster(i));
        if x + w > width && i > start {
            // After the last space on this row, if there is one; otherwise
            // inside the word.
            let cut = last_break.filter(|&b| b > start).unwrap_or(i);
            out.push(VisualRow { line: index, start, end: cut });
            (start, x, last_break, i) = (cut, 0.0, None, cut);
            continue;
        }
        x += w;
        if matches!(line.cluster(i), " " | "\t") {
            last_break = Some(i + 1);
        }
        i += 1;
    }
    out.push(VisualRow { line: index, start, end: line.len() });
    out
}
