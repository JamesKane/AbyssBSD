// Terminal tests — the VT parser and the screen model, with no pty and no
// display (PHASE15 P15.4a). Each feeds bytes a real program sends and asserts
// on what the screen then holds.

import XCTest
@testable import Terminal

final class TerminalTests: XCTestCase {
    private func screen(_ rows: Int = 5, _ cols: Int = 10, _ s: String) -> Screen {
        var sc = Screen(rows: rows, cols: cols)
        sc.feed(s)
        return sc
    }

    // MARK: The parser

    func testTheParserSplitsTextControlsAndSequences() {
        var p = VTParser(), got: [VTAction] = []
        p.feed(Array("a\r\u{1B}[?1049h\u{1B}[1;31m\u{1B}7\u{1B}]0;hi\u{07}é".utf8)) { got.append($0) }
        XCTAssertEqual(got, [.print("a"), .execute(0x0D),
                             .csi(params: [1049], intermediates: [], private: 0x3F, final: 0x68),
                             .csi(params: [1, 31], intermediates: [], private: nil, final: 0x6D),
                             .esc(intermediates: [], final: 0x37),
                             .osc("0;hi"), .print("é")])
    }

    /// A sequence split across reads — the ordinary case on a pty — parses the
    /// same as one that arrives whole.
    func testASequenceSplitAcrossReadsIsTheSameSequence() {
        var whole = VTParser(), split = VTParser(), a: [VTAction] = [], b: [VTAction] = []
        let bytes = Array("x\u{1B}[12;34Hé\u{1B}]2;t\u{1B}\\".utf8)
        whole.feed(bytes) { a.append($0) }
        for byte in bytes { split.step(byte) { b.append($0) } }
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.last, .osc("2;t"), "ST (ESC \\) ends an OSC as BEL does")
    }

    /// A control byte inside a broken UTF-8 rune: U+FFFD for the rune, and the
    /// control still acts — a stray byte never swallows an ESC.
    func testBrokenUTF8BecomesReplacementAndControlsStillAct() {
        var sc = Screen(rows: 2, cols: 10)
        sc.feed([0x61, 0xC3, 0x1B, 0x5B, 0x32, 0x43, 0x62] as [UInt8])  // a, half of é, ESC [ 2 C, b
        XCTAssertEqual(sc.text(row: 0), "a\u{FFFD}  b")
    }

    // MARK: Text and wrapping

    func testPrintingWrapsOnlyWhenTheNextCharacterArrives() {
        var sc = screen(3, 5, "abcde")
        XCTAssertEqual(sc.cursorRow, 0, "the last column sets a pending wrap, not a new line")
        XCTAssertEqual(sc.cursorCol, 4)
        sc.feed("f")
        XCTAssertEqual(sc.lines, ["abcde", "f", ""])
        let noWrap = screen(2, 5, "\u{1B}[?7labcdefg")
        XCTAssertEqual(noWrap.lines, ["abcdg", ""], "autowrap off: the last column is overwritten")
    }

    func testControlsMoveTheCursorAsATerminalDoes() {
        let sc = screen(3, 20, "ab\u{08}X\tY\r\nZ")
        XCTAssertEqual(sc.lines, ["aX      Y", "Z", ""])
    }

    func testTheScreenScrollsIntoScrollbackAtTheBottom() {
        let sc = screen(3, 10, "1\r\n2\r\n3\r\n4\r\n5")
        XCTAssertEqual(sc.lines, ["3", "4", "5"])
        XCTAssertEqual(sc.scrollback.count, 2)
        XCTAssertEqual(String(String.UnicodeScalarView(sc.scrollback[0].map(\.scalar))).trimmingCharacters(in: .whitespaces), "1")
    }

    // MARK: Cursor, erase, edit

    func testCursorAddressingAndErasing() {
        var sc = screen(4, 10, "xxxxxxxxxx\r\nyyyyyyyyyy\r\nzzzzzzzzzz")
        sc.feed("\u{1B}[2;4H\u{1B}[K")
        XCTAssertEqual(sc.lines[1], "yyy")
        sc.feed("\u{1B}[1;3H\u{1B}[1K")
        XCTAssertEqual(sc.lines[0], "   xxxxxxx")
        sc.feed("\u{1B}[3;5H\u{1B}[J")
        XCTAssertEqual(sc.lines, ["   xxxxxxx", "yyy", "zzzz", ""])
        sc.feed("\u{1B}[H\u{1B}[2J")
        XCTAssertEqual(sc.lines, ["", "", "", ""])
        XCTAssertEqual(sc.cursorRow, 0)
    }

    func testInsertAndDeleteCharactersAndLines() {
        var sc = screen(4, 8, "abcdef\r\nline2\r\nline3\r\nline4")
        sc.feed("\u{1B}[1;3H\u{1B}[2@")
        XCTAssertEqual(sc.lines[0], "ab  cdef")
        sc.feed("\u{1B}[3P")
        XCTAssertEqual(sc.lines[0], "abdef")
        sc.feed("\u{1B}[2;1H\u{1B}[L")
        XCTAssertEqual(sc.lines, ["abdef", "", "line2", "line3"])
        sc.feed("\u{1B}[M\u{1B}[M")
        XCTAssertEqual(sc.lines, ["abdef", "line3", "", ""])
        XCTAssertTrue(sc.scrollback.isEmpty, "deleting lines is not history")
        sc.feed("\u{1B}[1;2H\u{1B}[2X")
        XCTAssertEqual(sc.lines[0], "a  ef")
    }

    /// `rep` (terminfo, ncurses 6): CSI b repeats the last character — how a
    /// modern ncurses draws a rule.
    func testRepeatPrintsTheLastCharacterAgain() {
        XCTAssertEqual(screen(1, 10, "-\u{1B}[5b").lines, ["------"])
    }

    // MARK: Scroll regions, as vi and less use them

    func testAScrollRegionScrollsOnlyItsLines() {
        var sc = screen(5, 10, "top\r\na\r\nb\r\nc\r\nstatus")
        sc.feed("\u{1B}[2;4r")                                          // lines 2–4
        XCTAssertEqual(sc.cursorRow, 0, "setting a region homes the cursor")
        sc.feed("\u{1B}[4;1H\nnew")
        XCTAssertEqual(sc.lines, ["top", "b", "c", "new", "status"])
        XCTAssertTrue(sc.scrollback.isEmpty, "a region's lines are not history")
        sc.feed("\u{1B}[2;1H\u{1B}M")                                   // RI at the region's top
        XCTAssertEqual(sc.lines, ["top", "", "b", "c", "status"])
    }

    // MARK: The alternate screen

    func testTheAlternateScreenIsLeftAsItWasFound() {
        var sc = screen(3, 10, "$ vi\r\n")
        sc.feed("\u{1B}[?1049h\u{1B}[22;0;0t\u{1B}[H\u{1B}[2Jfile text\u{1B}[3;1H~")
        XCTAssertTrue(sc.usingAlternate)
        XCTAssertEqual(sc.lines, ["file text", "", "~"])
        sc.feed("\u{1B}[?1049l\u{1B}[23;0;0t")
        XCTAssertFalse(sc.usingAlternate)
        XCTAssertEqual(sc.lines, ["$ vi", "", ""])
        XCTAssertEqual(sc.cursorRow, 1, "and the cursor where it was")
    }

    // MARK: Attributes

    func testSGRSetsThePenAndErasingUsesItsBackground() {
        var sc = screen(2, 10, "\u{1B}[1;4;31;42mA\u{1B}[0mB\u{1B}[38;5;200;48;2;1;2;3mC\u{1B}[m")
        let a = sc.cell(0, 0).attrs
        XCTAssertTrue(a.bold && a.underline)
        XCTAssertEqual(a.fg, .indexed(1)); XCTAssertEqual(a.bg, .indexed(2))
        XCTAssertEqual(sc.cell(0, 1).attrs, CellAttributes(), "SGR 0 resets everything")
        XCTAssertEqual(sc.cell(0, 2).attrs.fg, .indexed(200))
        XCTAssertEqual(sc.cell(0, 2).attrs.bg, .rgb(1, 2, 3))
        sc.feed("\u{1B}[44m\u{1B}[2;1H\u{1B}[K")
        XCTAssertEqual(sc.cell(1, 5).attrs.bg, .indexed(4), "bce: erase takes the pen's background")
        XCTAssertFalse(sc.cell(1, 5).attrs.bold)
    }

    func testLineDrawingCharactersFromTheDECSet() {
        XCTAssertEqual(screen(1, 10, "\u{1B}(0lqqk\u{1B}(Bx").lines, ["┌──┐x"])
    }

    // MARK: Talking back

    func testTheTerminalAnswersWhereItsCursorIsAndWhatItIs() {
        var sc = screen(5, 10, "\u{1B}[3;7H\u{1B}[6n\u{1B}[c")
        XCTAssertEqual(String(decoding: sc.responses, as: UTF8.self), "\u{1B}[3;7R\u{1B}[?1;2c")
        sc.responses = []
        sc.feed("\u{1B}[>c")
        XCTAssertEqual(String(decoding: sc.responses, as: UTF8.self), "\u{1B}[>0;95;0c")
    }

    func testModesAndTheTitle() {
        var sc = screen(2, 10, "\u{1B}[?1h\u{1B}=\u{1B}[?25l\u{1B}[?2004h\u{1B}]2;vi file\u{07}")
        XCTAssertTrue(sc.applicationCursorKeys && sc.applicationKeypad && sc.bracketedPaste)
        XCTAssertFalse(sc.cursorVisible)
        XCTAssertEqual(sc.title, "vi file")
        sc.feed("\u{1B}[!p")                                             // DECSTR: FreeBSD termcap's `is`
        XCTAssertFalse(sc.applicationCursorKeys)
        XCTAssertTrue(sc.cursorVisible)
    }

    // MARK: Size

    func testResizingKeepsTheCursorsLineInView() {
        var sc = screen(4, 10, "1\r\n2\r\n3\r\n4")
        sc.resize(rows: 2, cols: 5)
        XCTAssertEqual(sc.lines, ["3", "4"])
        XCTAssertEqual(sc.cursorRow, 1)
        XCTAssertEqual(sc.scrollback.count, 2, "what no longer fits above the cursor is history")
        sc.resize(rows: 3, cols: 12)
        XCTAssertEqual(sc.lines, ["3", "4", ""])
        XCTAssertEqual(sc.cols, 12)
    }
}
