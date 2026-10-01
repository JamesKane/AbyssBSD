// TextModel tests — editing, motion, undo, find and wrapping, with no display
// (PHASE15 P15.5).

import XCTest
@testable import TextModel

final class TextModelTests: XCTestCase {
    private func p(_ l: Int, _ c: Int) -> TextPosition { TextPosition(line: l, column: c) }

    func testInsertAndDeleteAcrossLines() {
        var m = TextModel("hello\nworld")
        XCTAssertEqual(m.lineCount, 2)
        m.setCaret(p(0, 5))
        m.insert(" there\nbig")
        XCTAssertEqual(m.text, "hello there\nbig\nworld")
        XCTAssertEqual(m.caret, p(1, 3))
        m.select(TextRange(p(0, 5), p(2, 0)))
        m.deleteBackward()
        XCTAssertEqual(m.text, "helloworld")
        m.setCaret(p(0, 5)); m.insert("\n")
        m.deleteForward()
        XCTAssertEqual(m.text, "hello\norld")
        m.setCaret(p(1, 0)); m.deleteBackward()
        XCTAssertEqual(m.text, "helloorld", "backspace at a line's start joins it to the one above")
    }

    func testLineEndingsAreAllLines() {
        XCTAssertEqual(TextModel("a\r\nb\rc\nd").lineCount, 4)
        XCTAssertEqual(TextModel("é\u{301}x").lines[0].count, 2, "a combining mark is part of its Character")
    }

    func testWordAndLineMotion() {
        var m = TextModel("one two, three\nfour")
        m.setCaret(p(0, 0))
        m.move(.wordRight); XCTAssertEqual(m.caret, p(0, 3))
        m.move(.wordRight); XCTAssertEqual(m.caret, p(0, 7), "over the space, to the end of 'two'")
        m.move(.wordRight); XCTAssertEqual(m.caret, p(0, 14))
        m.move(.wordRight); XCTAssertEqual(m.caret, p(1, 4), "from a line's end, to the end of the next word (a Mac's Option-Right)")
        m.move(.wordLeft); XCTAssertEqual(m.caret, p(1, 0))
        m.move(.wordLeft); XCTAssertEqual(m.caret, p(0, 9), "back across the line break to the start of 'three'")
        m.move(.lineStart, extend: true)
        XCTAssertEqual(m.selectedText, "one two, ")
        m.move(.right)
        XCTAssertEqual(m.caret, p(0, 9), "Right with a selection collapses to its end")
        XCTAssertEqual(m.wordRange(at: p(0, 5)), TextRange(p(0, 4), p(0, 7)))
    }

    /// Typing a word is one Undo; a click ends the run; Redo puts it back; and
    /// the document knows when it is back to what was saved.
    func testUndoTakesBackTypingAsOneAndKnowsTheSavedText() {
        var m = TextModel("abc")
        m.markSaved()
        XCTAssertFalse(m.isDirty)
        m.setCaret(p(0, 3))
        for c in " def" { m.insert(String(c)) }
        XCTAssertEqual(m.undoName, "Typing")
        XCTAssertTrue(m.isDirty)
        m.setCaret(p(0, 0))
        m.insert("X")
        m.undo()
        XCTAssertEqual(m.text, "abc def", "the second run undone on its own")
        m.undo()
        XCTAssertEqual(m.text, "abc", "the first run, all four characters, as one")
        XCTAssertEqual(m.caret, p(0, 3))
        XCTAssertFalse(m.isDirty, "back to what was saved")
        m.redo()
        XCTAssertEqual(m.text, "abc def")
        XCTAssertTrue(m.isDirty)
        m.deleteBackward(); m.deleteBackward()
        XCTAssertEqual(m.undoName, "Delete")
        m.undo()
        XCTAssertEqual(m.text, "abc def", "two backspaces, one undo")
        m.select(TextRange(p(0, 0), p(0, 3)))
        m.insert("ABC", kind: .paste)
        XCTAssertEqual(m.undoName, "Paste")
        m.undo()
        XCTAssertEqual(m.text, "abc def")
        XCTAssertEqual(m.selection, TextRange(p(0, 0), p(0, 3)), "and the selection that was pasted over")
    }

    func testAnEditAfterUndoingPastTheSaveIsDirtyForGood() {
        var m = TextModel("a")
        m.setCaret(p(0, 1)); m.insert("b")
        m.markSaved()
        m.undo()
        XCTAssertTrue(m.isDirty)
        m.setCaret(p(0, 0)); m.insert("z", kind: .other("Change"))
        XCTAssertTrue(m.isDirty)
        m.undo()
        XCTAssertTrue(m.isDirty, "the saved text ('ab') is no longer reachable")
    }

    func testFindGoesRoundAndIgnoresCase() {
        var m = TextModel("Cat hat\ncat")
        m.setCaret(p(0, 0))
        let a = m.find("cat")
        XCTAssertEqual(a, TextRange(p(0, 0), p(0, 3)), "from the caret, case ignored")
        m.select(a!)
        let b = m.find("cat")
        XCTAssertEqual(b, TextRange(p(1, 0), p(1, 3)), "then the next one after the selection")
        m.select(b!)
        XCTAssertEqual(m.find("cat"), TextRange(p(0, 0), p(0, 3)), "and round the end")
        XCTAssertEqual(m.find("cat", ignoringCase: false), TextRange(p(1, 0), p(1, 3)),
                       "matching case, 'Cat' is not 'cat': round to the only one")
        XCTAssertEqual(m.find("hat", backward: true), TextRange(p(0, 4), p(0, 7)))
        XCTAssertNil(m.find("dog"))
    }

    // MARK: Layout

    private func layout(_ s: String, width: Double) -> (TextModel, TextLayout) {
        let m = TextModel(s)
        return (m, TextLayout(m.lines, width: width, advance: { _ in 1 }))
    }

    func testLinesWrapAfterTheLastSpaceThatFits() {
        let (_, l) = layout("the quick brown fox\n\nabcdefghij", width: 10)
        XCTAssertEqual(l.rows, [VisualRow(line: 0, start: 0, end: 10),     // "the quick "
                                VisualRow(line: 0, start: 10, end: 19),    // "brown fox"
                                VisualRow(line: 1, start: 0, end: 0),      // the empty line
                                VisualRow(line: 2, start: 0, end: 10)])
        let (_, w) = layout("abcdefghijklm", width: 5)
        XCTAssertEqual(w.rows.map(\.end), [5, 10, 13], "a word longer than the row breaks inside it")
    }

    func testPositionsRowsAndXMapBothWays() {
        let (_, l) = layout("the quick brown fox", width: 10)
        XCTAssertEqual(l.row(of: p(0, 10)), 1, "a caret at the wrap starts the next row")
        XCTAssertEqual(l.row(of: p(0, 19)), 1, "the end of the line ends its last row")
        XCTAssertEqual(l.x(of: p(0, 13)), 3)
        XCTAssertEqual(l.position(row: 1, x: 2.4), p(0, 12))
        XCTAssertEqual(l.position(row: 0, x: 99), p(0, 9), "past the end of a wrapped row: its end, not the next row's start")
        XCTAssertEqual(l.position(row: 1, x: 99), p(0, 19))
        XCTAssertEqual(l.vertical(from: p(0, 3), by: 1, goalX: 3), p(0, 13))
        XCTAssertNil(l.vertical(from: p(0, 3), by: -1, goalX: 3))
    }
}
