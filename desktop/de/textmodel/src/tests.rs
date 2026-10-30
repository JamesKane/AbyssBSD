//! TextModelTests.swift, ported: editing, motion, undo, find and wrapping,
//! with no display.

use super::*;

fn p(l: usize, c: usize) -> TextPosition {
    TextPosition::new(l, c)
}

fn r(a: TextPosition, b: TextPosition) -> TextRange {
    TextRange::new(a, b)
}

fn caret(m: &mut TextModel, at: TextPosition) {
    m.set_caret(at, false, false);
}

#[test]
fn insert_and_delete_across_lines() {
    let mut m = TextModel::new("hello\nworld");
    assert_eq!(m.line_count(), 2);
    caret(&mut m, p(0, 5));
    m.insert(" there\nbig", EditKind::Typing);
    assert_eq!(m.text(), "hello there\nbig\nworld");
    assert_eq!(m.caret(), p(1, 3));
    m.select(r(p(0, 5), p(2, 0)));
    m.delete_backward(false);
    assert_eq!(m.text(), "helloworld");
    caret(&mut m, p(0, 5));
    m.insert("\n", EditKind::Typing);
    m.delete_forward(false);
    assert_eq!(m.text(), "hello\norld");
    caret(&mut m, p(1, 0));
    m.delete_backward(false);
    assert_eq!(m.text(), "helloorld", "backspace at a line's start joins it to the one above");
}

#[test]
fn line_endings_are_all_lines() {
    assert_eq!(TextModel::new("a\r\nb\rc\nd").line_count(), 4);
    assert_eq!(TextModel::new("é\u{301}x").lines()[0].len(), 2, "a combining mark is part of its cluster");
    let flags = TextModel::new("🇫🇷🇩🇪👩‍👧");
    assert_eq!(flags.lines()[0].clusters().collect::<Vec<_>>(), ["🇫🇷", "🇩🇪", "👩‍👧"]);
}

/// An accent typed after its letter is its own column until the text is
/// read again, as in Swift: so Undo takes back exactly what was typed.
#[test]
fn an_edit_joins_clusters_and_undo_stays_exact() {
    let mut m = TextModel::new("e");
    caret(&mut m, p(0, 1));
    m.insert("\u{301}", EditKind::Typing);
    assert_eq!(m.lines()[0].len(), 2);
    assert_eq!(m.caret(), p(0, 2));
    m.undo();
    assert_eq!(m.text(), "e");
    assert_eq!(TextModel::new(&m.text()).lines()[0].len(), 1);
}

#[test]
fn word_and_line_motion() {
    let mut m = TextModel::new("one two, three\nfour");
    caret(&mut m, p(0, 0));
    for (want, why) in [(p(0, 3), ""), (p(0, 7), "over the space, to the end of 'two'"), (p(0, 14), ""), (p(1, 4), "from a line's end, to the end of the next word")] {
        m.move_caret(Motion::WordRight, false);
        assert_eq!(m.caret(), want, "{why}");
    }
    m.move_caret(Motion::WordLeft, false);
    assert_eq!(m.caret(), p(1, 0));
    m.move_caret(Motion::WordLeft, false);
    assert_eq!(m.caret(), p(0, 9), "back across the line break to the start of 'three'");
    m.move_caret(Motion::LineStart, true);
    assert_eq!(m.selected_text(), "one two, ");
    m.move_caret(Motion::Right, false);
    assert_eq!(m.caret(), p(0, 9), "Right with a selection collapses to its end");
    assert_eq!(m.word_range(p(0, 5)), r(p(0, 4), p(0, 7)));
    assert_eq!(m.line_range(p(0, 2)), r(p(0, 0), p(1, 0)));
    assert_eq!(m.line_range(p(1, 2)), r(p(1, 0), p(1, 4)));
}

/// Typing a word is one Undo; a click ends the run; Redo puts it back; and
/// the document knows when it is back to what was saved.
#[test]
fn undo_takes_back_typing_as_one_and_knows_the_saved_text() {
    let mut m = TextModel::new("abc");
    m.mark_saved();
    assert!(!m.is_dirty());
    caret(&mut m, p(0, 3));
    for c in [" ", "d", "e", "f"] {
        m.insert(c, EditKind::Typing);
    }
    assert_eq!(m.undo_name().as_deref(), Some("Typing"));
    assert!(m.is_dirty());
    caret(&mut m, p(0, 0));
    m.insert("X", EditKind::Typing);
    m.undo();
    assert_eq!(m.text(), "abc def", "the second run undone on its own");
    m.undo();
    assert_eq!(m.text(), "abc", "the first run, all four characters, as one");
    assert_eq!(m.caret(), p(0, 3));
    assert!(!m.is_dirty(), "back to what was saved");
    m.redo();
    assert_eq!(m.text(), "abc def");
    assert!(m.is_dirty());
    m.delete_backward(false);
    m.delete_backward(false);
    assert_eq!(m.undo_name().as_deref(), Some("Delete"));
    m.undo();
    assert_eq!(m.text(), "abc def", "two backspaces, one undo");
    m.select(r(p(0, 0), p(0, 3)));
    m.insert("ABC", EditKind::Paste);
    assert_eq!(m.undo_name().as_deref(), Some("Paste"));
    m.undo();
    assert_eq!(m.text(), "abc def");
    assert_eq!(m.selection(), r(p(0, 0), p(0, 3)), "and the selection that was pasted over");
}

#[test]
fn an_edit_after_undoing_past_the_save_is_dirty_for_good() {
    let mut m = TextModel::new("a");
    caret(&mut m, p(0, 1));
    m.insert("b", EditKind::Typing);
    m.mark_saved();
    m.undo();
    assert!(m.is_dirty());
    caret(&mut m, p(0, 0));
    m.insert("z", EditKind::Other("Change".into()));
    assert!(m.is_dirty());
    m.undo();
    assert!(m.is_dirty(), "the saved text ('ab') is no longer reachable");
}

#[test]
fn find_goes_round_and_ignores_case() {
    let mut m = TextModel::new("Cat hat\ncat");
    caret(&mut m, p(0, 0));
    let a = m.find("cat", false, true);
    assert_eq!(a, Some(r(p(0, 0), p(0, 3))), "from the caret, case ignored");
    m.select(a.unwrap());
    let b = m.find("cat", false, true);
    assert_eq!(b, Some(r(p(1, 0), p(1, 3))), "then the next one after the selection");
    m.select(b.unwrap());
    assert_eq!(m.find("cat", false, true), Some(r(p(0, 0), p(0, 3))), "and round the end");
    assert_eq!(m.find("cat", false, false), Some(r(p(1, 0), p(1, 3))), "matching case, round to the only one");
    assert_eq!(m.find("hat", true, true), Some(r(p(0, 4), p(0, 7))));
    assert_eq!(m.find("dog", false, true), None);
    assert_eq!(m.find("t\nc", false, true), Some(r(p(0, 6), p(1, 1))), "across a line break");
}

/// Backward from the end of the text, the only match is still found: Swift
/// starts past the last place a match can begin and spends its tries
/// getting back, so with the caret at the end it finds nothing.
#[test]
fn find_backward_from_the_end_finds_the_last_match() {
    let mut m = TextModel::new("ab");
    let end = m.end();
    caret(&mut m, end);
    assert_eq!(m.find("ab", true, true), Some(r(p(0, 0), p(0, 2))));
    let mut m = TextModel::new("xx ab");
    let end = m.end();
    caret(&mut m, end);
    assert_eq!(m.find("ab", true, true), Some(r(p(0, 3), p(0, 5))));
}

// MARK: layout

fn one(_: &str) -> f64 {
    1.0
}

#[test]
fn lines_wrap_after_the_last_space_that_fits() {
    let m = TextModel::new("the quick brown fox\n\nabcdefghij");
    let l = TextLayout::new(m.lines(), 10.0, one);
    let row = |line, start, end| VisualRow { line, start, end };
    assert_eq!(l.rows, [row(0, 0, 10), row(0, 10, 19), row(1, 0, 0), row(2, 0, 10)]);
    let w = TextModel::new("abcdefghijklm");
    assert_eq!(TextLayout::new(w.lines(), 5.0, one).rows.iter().map(|r| r.end).collect::<Vec<_>>(), [5, 10, 13], "a word longer than the row breaks inside it");
}

#[test]
fn positions_rows_and_x_map_both_ways() {
    let m = TextModel::new("the quick brown fox");
    let l = TextLayout::new(m.lines(), 10.0, one);
    assert_eq!(l.row_of(p(0, 10)), 1, "a caret at the wrap starts the next row");
    assert_eq!(l.row_of(p(0, 19)), 1, "the end of the line ends its last row");
    assert_eq!(l.x_of(p(0, 13)), 3.0);
    assert_eq!(l.position(1, 2.4), p(0, 12));
    assert_eq!(l.position(0, 99.0), p(0, 9), "past the end of a wrapped row: its end, not the next row's start");
    assert_eq!(l.position(1, 99.0), p(0, 19));
    assert_eq!(l.vertical(p(0, 3), 1, 3.0), Some(p(0, 13)));
    assert_eq!(l.vertical(p(0, 3), -1, 3.0), None);
}

#[test]
fn a_cluster_is_one_column_wide_to_the_layout() {
    let m = TextModel::new("e\u{301}e\u{301} 👩‍👧");
    let l = TextLayout::new(m.lines(), 100.0, one);
    assert_eq!(l.x_of(p(0, 4)), 4.0);
    assert_eq!(l.position(0, 3.6), p(0, 4));
}
