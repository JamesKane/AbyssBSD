//! Multi-line text being edited (TextModel.swift, PHASE15 P15.5).
//!
//! The toolkit's text view is built on this, and every editor after
//! TextEdit uses the view, so this is the part that has to be right: what an
//! edit does, where the caret goes, what Undo puts back, what Find finds.
//! Pure, so every one of those is a unit test; the view supplies what only
//! it knows (how wide a cluster is) through `TextLayout`.
//!
//! The text is lines of grapheme clusters, Swift's Characters: a caret never
//! lands inside an "é" written as e + combining accent. A position is (line,
//! column in clusters). **An edit joins clusters, it does not re-segment**:
//! an accent typed after an "e" is its own column until the text is read
//! again, as in Swift, which is what keeps Undo exact.

use crate::grapheme::clusters;

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Default)]
pub struct TextPosition {
    pub line: usize,
    pub column: usize,
}

impl TextPosition {
    pub const START: TextPosition = TextPosition { line: 0, column: 0 };

    pub fn new(line: usize, column: usize) -> TextPosition {
        TextPosition { line, column }
    }
}

/// A range, start before end whichever way it was given.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Default)]
pub struct TextRange {
    pub start: TextPosition,
    pub end: TextPosition,
}

impl TextRange {
    pub fn new(a: TextPosition, b: TextPosition) -> TextRange {
        TextRange { start: a.min(b), end: a.max(b) }
    }

    pub fn is_empty(&self) -> bool {
        self.start == self.end
    }
}

/// One line: its text, and where each of its clusters ends.
#[derive(Clone, Debug, PartialEq, Eq, Default)]
pub struct Line {
    text: String,
    ends: Vec<usize>,
}

impl Line {
    fn from_clusters<'a>(cs: impl IntoIterator<Item = &'a str>) -> Line {
        let mut l = Line::default();
        for c in cs {
            l.push(c);
        }
        l
    }

    fn push(&mut self, cluster: &str) {
        self.text.push_str(cluster);
        self.ends.push(self.text.len());
    }

    fn byte(&self, column: usize) -> usize {
        if column == 0 { 0 } else { self.ends[column - 1] }
    }

    /// Columns [a, b), as clusters.
    fn slice(&self, a: usize, b: usize) -> Line {
        Line::from_clusters((a..b).map(|i| self.cluster(i)))
    }

    fn append(&mut self, other: &Line) {
        for c in other.clusters() {
            self.push(c);
        }
    }

    /// How many clusters.
    pub fn len(&self) -> usize {
        self.ends.len()
    }

    pub fn is_empty(&self) -> bool {
        self.ends.is_empty()
    }

    pub fn as_str(&self) -> &str {
        &self.text
    }

    pub fn cluster(&self, i: usize) -> &str {
        &self.text[self.byte(i)..self.ends[i]]
    }

    pub fn clusters(&self) -> impl Iterator<Item = &str> {
        (0..self.len()).map(|i| self.cluster(i))
    }

    /// The text of columns [a, b).
    pub fn text(&self, a: usize, b: usize) -> &str {
        &self.text[self.byte(a)..self.byte(b)]
    }
}

/// What an edit was, for the Edit menu's "Undo Typing".
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum EditKind {
    Typing,
    Deleting,
    Paste,
    Cut,
    Other(String),
}

/// One change, as Undo needs it: what was there, what is there now.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TextEdit {
    /// Where it happened, in the text as it was before.
    pub at: TextPosition,
    pub removed: String,
    pub inserted: String,
    pub selection_before: TextRange,
    pub selection_after: TextRange,
    pub kind: EditKind,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Motion {
    Left,
    Right,
    WordLeft,
    WordRight,
    LineStart,
    LineEnd,
    DocumentStart,
    DocumentEnd,
}

#[derive(Clone, Debug)]
pub struct TextModel {
    lines: Vec<Line>,
    /// Where a selection was started, and the caret: equal when nothing is
    /// selected.
    anchor: TextPosition,
    caret: TextPosition,
    /// Up and Down keep the column a person was in, across shorter lines.
    pub goal_x: Option<f64>,
    history: UndoHistory,
}

impl Default for TextModel {
    fn default() -> TextModel {
        TextModel::new("")
    }
}

impl TextModel {
    pub fn new(text: &str) -> TextModel {
        TextModel { lines: split(text), anchor: TextPosition::START, caret: TextPosition::START, goal_x: None, history: UndoHistory::new(200) }
    }

    // MARK: reading

    pub fn lines(&self) -> &[Line] {
        &self.lines
    }

    pub fn line_count(&self) -> usize {
        self.lines.len()
    }

    pub fn text(&self) -> String {
        self.lines.iter().map(Line::as_str).collect::<Vec<_>>().join("\n")
    }

    pub fn anchor(&self) -> TextPosition {
        self.anchor
    }

    pub fn caret(&self) -> TextPosition {
        self.caret
    }

    pub fn selection(&self) -> TextRange {
        TextRange::new(self.anchor, self.caret)
    }

    pub fn selected_text(&self) -> String {
        self.text_in(self.selection())
    }

    /// Edited since it was last opened or saved.
    pub fn is_dirty(&self) -> bool {
        self.history.dirty()
    }

    pub fn history(&self) -> &UndoHistory {
        &self.history
    }

    pub fn text_in(&self, r: TextRange) -> String {
        let (s, e) = (self.clamp(r.start), self.clamp(r.end));
        if s.line == e.line {
            return self.lines[s.line].text(s.column, e.column).to_owned();
        }
        let first = &self.lines[s.line];
        let mut out = first.text(s.column, first.len()).to_owned();
        for l in &self.lines[s.line + 1..e.line] {
            out += "\n";
            out += l.as_str();
        }
        out + "\n" + self.lines[e.line].text(0, e.column)
    }

    pub fn clamp(&self, p: TextPosition) -> TextPosition {
        let line = p.line.min(self.lines.len() - 1);
        TextPosition::new(line, p.column.min(self.lines[line].len()))
    }

    pub fn end(&self) -> TextPosition {
        let last = self.lines.len() - 1;
        TextPosition::new(last, self.lines[last].len())
    }

    // MARK: selecting

    /// Put the caret at `p`; with `extend`, keep the anchor (Shift).
    pub fn set_caret(&mut self, p: TextPosition, extend: bool, keep_goal: bool) {
        self.caret = self.clamp(p);
        if !extend {
            self.anchor = self.caret;
        }
        if !keep_goal {
            self.goal_x = None;
        }
        self.history.break_typing();
    }

    pub fn select(&mut self, r: TextRange) {
        self.anchor = self.clamp(r.start);
        self.caret = self.clamp(r.end);
        self.goal_x = None;
        self.history.break_typing();
    }

    pub fn select_all(&mut self) {
        self.select(TextRange::new(TextPosition::START, self.end()));
    }

    // MARK: motion

    /// Move the caret. Without `extend`, a selection collapses to the side
    /// moved toward, as a Mac text field does.
    pub fn move_caret(&mut self, m: Motion, extend: bool) {
        let sel = self.selection();
        if !extend && !sel.is_empty() && matches!(m, Motion::Left | Motion::Right) {
            self.set_caret(if m == Motion::Left { sel.start } else { sel.end }, false, false);
            return;
        }
        self.set_caret(self.target(m, self.caret), extend, false);
    }

    fn is_word_at(&self, p: TextPosition) -> bool {
        is_word(self.lines[p.line].cluster(p.column))
    }

    pub fn target(&self, m: Motion, p: TextPosition) -> TextPosition {
        let len = |l: usize| self.lines[l].len();
        match m {
            Motion::Left => {
                if p.column > 0 {
                    TextPosition::new(p.line, p.column - 1)
                } else if p.line > 0 {
                    TextPosition::new(p.line - 1, len(p.line - 1))
                } else {
                    p
                }
            }
            Motion::Right => {
                if p.column < len(p.line) {
                    TextPosition::new(p.line, p.column + 1)
                } else if p.line < self.lines.len() - 1 {
                    TextPosition::new(p.line + 1, 0)
                } else {
                    p
                }
            }
            Motion::WordLeft => {
                // Back over spaces and punctuation, then over the word.
                let mut q = p;
                loop {
                    let prev = self.target(Motion::Left, q);
                    if prev == q {
                        return q;
                    }
                    if prev.line != q.line {
                        if q.column == 0 && q != p {
                            return q;
                        }
                        q = prev;
                        continue;
                    }
                    if self.is_word_at(prev) {
                        break;
                    }
                    q = prev;
                }
                while q.column > 0 && self.is_word_at(TextPosition::new(q.line, q.column - 1)) {
                    q.column -= 1;
                }
                q
            }
            Motion::WordRight => {
                let mut q = p;
                loop {
                    if q.column >= len(q.line) {
                        if q.line == self.lines.len() - 1 || q != p {
                            return q;
                        }
                        q = TextPosition::new(q.line + 1, 0);
                        continue;
                    }
                    if self.is_word_at(q) {
                        break;
                    }
                    q.column += 1;
                }
                while q.column < len(q.line) && self.is_word_at(q) {
                    q.column += 1;
                }
                q
            }
            Motion::LineStart => TextPosition::new(p.line, 0),
            Motion::LineEnd => TextPosition::new(p.line, len(p.line)),
            Motion::DocumentStart => TextPosition::START,
            Motion::DocumentEnd => self.end(),
        }
    }

    /// The word around `p`: what a double-click selects.
    pub fn word_range(&self, p: TextPosition) -> TextRange {
        let p = self.clamp(p);
        let line = &self.lines[p.line];
        if line.is_empty() {
            return TextRange::new(p, p);
        }
        let at = |c: usize| TextPosition::new(p.line, c);
        let word = |c: usize| is_word(line.cluster(c));
        let mut c = p.column.min(line.len() - 1);
        if !word(c) && c > 0 && word(c - 1) {
            c -= 1;
        }
        if !word(c) {
            return TextRange::new(at(c), at(c + 1));
        }
        let (mut a, mut b) = (c, c);
        while a > 0 && word(a - 1) {
            a -= 1;
        }
        while b < line.len() && word(b) {
            b += 1;
        }
        TextRange::new(at(a), at(b))
    }

    /// The line around `p`, and its line break: what a triple-click selects.
    pub fn line_range(&self, p: TextPosition) -> TextRange {
        let l = self.clamp(p).line;
        let e = if l < self.lines.len() - 1 { TextPosition::new(l + 1, 0) } else { TextPosition::new(l, self.lines[l].len()) };
        TextRange::new(TextPosition::new(l, 0), e)
    }

    // MARK: editing

    /// Type or paste `s` over the selection.
    pub fn insert(&mut self, s: &str, kind: EditKind) {
        self.replace(self.selection(), s, kind);
    }

    /// Backspace: the selection, or the cluster before the caret (with
    /// `word`, the word before it: Option-Delete).
    pub fn delete_backward(&mut self, word: bool) {
        if !self.selection().is_empty() {
            return self.replace(self.selection(), "", EditKind::Deleting);
        }
        let from = self.target(if word { Motion::WordLeft } else { Motion::Left }, self.caret);
        if from != self.caret {
            self.replace(TextRange::new(from, self.caret), "", EditKind::Deleting);
        }
    }

    /// Forward delete (fn-Delete).
    pub fn delete_forward(&mut self, word: bool) {
        if !self.selection().is_empty() {
            return self.replace(self.selection(), "", EditKind::Deleting);
        }
        let to = self.target(if word { Motion::WordRight } else { Motion::Right }, self.caret);
        if to != self.caret {
            self.replace(TextRange::new(self.caret, to), "", EditKind::Deleting);
        }
    }

    /// The one primitive every edit goes through, so Undo is exact by
    /// construction.
    pub fn replace(&mut self, r: TextRange, s: &str, kind: EditKind) {
        let r = TextRange::new(self.clamp(r.start), self.clamp(r.end));
        let before = self.selection();
        let removed = self.text_in(r);
        let end = self.splice(r, s);
        (self.caret, self.anchor, self.goal_x) = (end, end, None);
        self.history.record(TextEdit {
            at: r.start,
            removed,
            inserted: s.to_owned(),
            selection_before: before,
            selection_after: TextRange::new(end, end),
            kind,
        });
    }

    /// Put `s` in place of `r` and return where it ends. No history.
    fn splice(&mut self, r: TextRange, s: &str) -> TextPosition {
        let first = &self.lines[r.start.line];
        let head = first.slice(0, r.start.column);
        let last = &self.lines[r.end.line];
        let tail = last.slice(r.end.column, last.len());
        let mut pieces = split(s);
        let n = pieces.len();
        let last_count = pieces[n - 1].len();
        let mut joined = head.clone();
        joined.append(&pieces[0]);
        pieces[0] = joined;
        pieces[n - 1].append(&tail);
        self.lines.splice(r.start.line..=r.end.line, pieces);
        let column = if n == 1 { head.len() + last_count } else { last_count };
        TextPosition::new(r.start.line + n - 1, column)
    }

    // MARK: undo

    pub fn can_undo(&self) -> bool {
        self.history.can_undo()
    }

    pub fn can_redo(&self) -> bool {
        self.history.can_redo()
    }

    /// "Typing", "Paste", …: the Edit menu says "Undo Typing".
    pub fn undo_name(&self) -> Option<String> {
        self.history.undo_name()
    }

    pub fn redo_name(&self) -> Option<String> {
        self.history.redo_name()
    }

    pub fn undo(&mut self) {
        let Some(group) = self.history.pop_undo() else { return };
        for e in group.iter().rev() {
            self.splice(TextRange::new(e.at, end_of(&e.inserted, e.at)), &e.removed);
        }
        if let Some(first) = group.first() {
            self.anchor = self.clamp(first.selection_before.start);
            self.caret = self.clamp(first.selection_before.end);
        }
        self.goal_x = None;
    }

    pub fn redo(&mut self) {
        let Some(group) = self.history.pop_redo() else { return };
        for e in &group {
            self.splice(TextRange::new(e.at, end_of(&e.removed, e.at)), &e.inserted);
        }
        if let Some(last) = group.last() {
            self.anchor = self.clamp(last.selection_after.start);
            self.caret = self.clamp(last.selection_after.end);
        }
        self.goal_x = None;
    }

    /// The text is what is on disk now (opened, or just saved).
    pub fn mark_saved(&mut self) {
        self.history.mark_saved();
    }

    // MARK: find

    /// The next place `needle` occurs after the selection (before it, with
    /// `backward`), going round the end; None if it is nowhere. Clusters
    /// match when their text does (Swift's match when canonically
    /// equivalent, so a composed é finds a decomposed one).
    pub fn find(&self, needle: &str, backward: bool, ignoring_case: bool) -> Option<TextRange> {
        if needle.is_empty() {
            return None;
        }
        let fold = |c: &str| if ignoring_case { c.to_lowercase() } else { c.to_owned() };
        let mut hay: Vec<String> = vec![];
        for (i, l) in self.lines.iter().enumerate() {
            if i > 0 {
                hay.push("\n".into());
            }
            hay.extend(l.clusters().map(fold));
        }
        let want: Vec<String> = split(needle).iter().enumerate().flat_map(|(i, l)| (i > 0).then(|| "\n".to_owned()).into_iter().chain(l.clusters().map(fold))).collect();
        if want.len() > hay.len() {
            return None;
        }
        let n = hay.len() - want.len();
        let matches = |i: usize| hay[i..i + want.len()] == want[..];
        let range = |i: usize| TextRange::new(self.position_of_offset(i), self.position_of_offset(i + want.len()));
        let sel = self.selection();
        if backward {
            let mut i = self.offset_of(sel.start) as isize - 1;
            for _ in 0..=n {
                if i < 0 || i as usize > n {
                    i = n as isize;
                }
                if matches(i as usize) {
                    return Some(range(i as usize));
                }
                i -= 1;
            }
        } else {
            let mut i = self.offset_of(sel.end);
            for _ in 0..=n {
                if i > n {
                    i = 0;
                }
                if matches(i) {
                    return Some(range(i));
                }
                i += 1;
            }
        }
        None
    }

    /// A position as a cluster offset into `text`, line breaks counted.
    pub fn offset_of(&self, p: TextPosition) -> usize {
        let p = self.clamp(p);
        self.lines[..p.line].iter().map(|l| l.len() + 1).sum::<usize>() + p.column
    }

    pub fn position_of_offset(&self, mut o: usize) -> TextPosition {
        for (i, l) in self.lines.iter().enumerate() {
            if o <= l.len() {
                return TextPosition::new(i, o);
            }
            o -= l.len() + 1;
        }
        self.end()
    }
}

/// A word's cluster: a letter, a digit, `_` or `'`, by its first scalar.
pub(crate) fn is_word(c: &str) -> bool {
    c == "_" || c == "'" || c.chars().next().is_some_and(|f| f.is_alphabetic() || f.is_numeric())
}

/// Lines of `s`: "\n", "\r\n" and a lone "\r" each end one.
fn split(s: &str) -> Vec<Line> {
    let mut out = vec![Line::default()];
    for c in clusters(s) {
        if matches!(c, "\n" | "\r\n" | "\r") {
            out.push(Line::default());
        } else {
            out.last_mut().unwrap().push(c);
        }
    }
    out
}

/// Where `s` ends if it starts at `p`.
pub(crate) fn end_of(s: &str, p: TextPosition) -> TextPosition {
    let pieces = split(s);
    let last = pieces[pieces.len() - 1].len();
    if pieces.len() == 1 { TextPosition::new(p.line, p.column + last) } else { TextPosition::new(p.line + pieces.len() - 1, last) }
}

/// What Undo can put back, and what Redo can put back again. Typing that
/// runs on is one entry ("Undo Typing" takes back the word, not the
/// letter), as is a run of Backspaces; any other edit, a click, or a caret
/// move closes the run.
#[derive(Clone, Debug)]
pub struct UndoHistory {
    done: Vec<Vec<TextEdit>>,
    undone: Vec<Vec<TextEdit>>,
    typing_open: bool,
    /// How many entries back the saved text is; None once it cannot be
    /// reached (an edit after an undo past it).
    saved_at: Option<usize>,
    pub limit: usize,
}

impl UndoHistory {
    pub fn new(limit: usize) -> UndoHistory {
        UndoHistory { done: vec![], undone: vec![], typing_open: false, saved_at: Some(0), limit }
    }

    pub fn can_undo(&self) -> bool {
        !self.done.is_empty()
    }

    pub fn can_redo(&self) -> bool {
        !self.undone.is_empty()
    }

    pub fn dirty(&self) -> bool {
        self.saved_at != Some(self.done.len())
    }

    pub fn undo_name(&self) -> Option<String> {
        self.done.last().map(|g| name(g))
    }

    pub fn redo_name(&self) -> Option<String> {
        self.undone.last().map(|g| name(g))
    }

    fn record(&mut self, e: TextEdit) {
        // An edit after undoing past the saved text: it cannot be reached
        // again, so the document is dirty until saved.
        if self.saved_at.is_some_and(|s| s > self.done.len()) {
            self.saved_at = None;
        }
        self.undone.clear();
        let runs = matches!(e.kind, EditKind::Typing | EditKind::Deleting);
        // A run continues only while typing is open, so a group never
        // straddles the saved text.
        let continues = runs && self.typing_open && self.done.last().and_then(|g| g.last()).is_some_and(|last| last.kind == e.kind && contiguous(last, &e));
        if continues {
            self.done.last_mut().unwrap().push(e);
        } else {
            self.done.push(vec![e]);
            if self.done.len() > self.limit {
                let drop = self.done.len() - self.limit;
                self.done.drain(..drop);
                self.saved_at = self.saved_at.and_then(|s| s.checked_sub(drop));
            }
        }
        self.typing_open = runs;
    }

    fn break_typing(&mut self) {
        self.typing_open = false;
    }

    fn pop_undo(&mut self) -> Option<Vec<TextEdit>> {
        let g = self.done.pop()?;
        self.undone.push(g.clone());
        self.typing_open = false;
        Some(g)
    }

    fn pop_redo(&mut self) -> Option<Vec<TextEdit>> {
        let g = self.undone.pop()?;
        self.done.push(g.clone());
        self.typing_open = false;
        Some(g)
    }

    fn mark_saved(&mut self) {
        self.saved_at = Some(self.done.len());
        self.typing_open = false;
    }
}

fn name(g: &[TextEdit]) -> String {
    match g.first().map(|e| &e.kind) {
        Some(EditKind::Typing) => "Typing".into(),
        Some(EditKind::Deleting) => "Delete".into(),
        Some(EditKind::Paste) => "Paste".into(),
        Some(EditKind::Cut) => "Cut".into(),
        Some(EditKind::Other(s)) => s.clone(),
        None => String::new(),
    }
}

/// Typing continues where it left off; deleting continues where the last
/// deletion left the caret.
fn contiguous(a: &TextEdit, b: &TextEdit) -> bool {
    if a.kind == EditKind::Typing {
        return b.at == end_of(&a.inserted, a.at) && b.removed.is_empty() && a.removed.is_empty();
    }
    b.selection_before == a.selection_after
}
