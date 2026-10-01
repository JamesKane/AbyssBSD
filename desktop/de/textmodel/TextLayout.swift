// TextLayout — the text's lines wrapped to a width (PHASE15 P15.5).
//
// A text view shows *visual* rows: a long line wraps, after the last space
// that fits or, for a word longer than the row, inside it. Up and Down move
// between rows, a click lands in one, and the caret is drawn at an x in one —
// so the mapping between a `TextPosition` and (row, x) lives here, pure, with
// the one thing only the view knows — how wide a Character is — passed in.

public struct VisualRow: Equatable, Sendable {
    public let line: Int
    /// Columns [start, end) of `line`.
    public let start: Int
    public let end: Int
}

public struct TextLayout {
    public let width: Double
    public private(set) var rows: [VisualRow] = []
    private let lines: [[Character]]
    private let advance: (Character) -> Double

    public init(_ lines: [[Character]], width: Double, advance: @escaping (Character) -> Double) {
        self.lines = lines
        self.width = max(1, width)
        self.advance = advance
        for (l, line) in lines.enumerated() { rows += TextLayout.wrap(line, index: l, width: self.width, advance: advance) }
    }

    static func wrap(_ line: [Character], index: Int, width: Double,
                     advance: (Character) -> Double) -> [VisualRow] {
        guard !line.isEmpty else { return [VisualRow(line: index, start: 0, end: 0)] }
        var out: [VisualRow] = []
        var start = 0, x = 0.0, lastBreak: Int? = nil, i = 0
        while i < line.count {
            let w = advance(line[i])
            if x + w > width && i > start {
                // Break after the last space on this row, if there is one;
                // otherwise inside the word.
                let cut = (lastBreak.map { $0 > start ? $0 : nil } ?? nil) ?? i
                out.append(VisualRow(line: index, start: start, end: cut))
                start = cut; x = 0; lastBreak = nil; i = cut
                continue
            }
            x += w
            if line[i] == " " || line[i] == "\t" { lastBreak = i + 1 }
            i += 1
        }
        out.append(VisualRow(line: index, start: start, end: line.count))
        return out
    }

    /// The row the caret at `p` is drawn in. A position exactly at a wrap is
    /// the start of the next row; the end of a line is the end of its last.
    public func row(of p: TextPosition) -> Int {
        var found = 0
        for (i, r) in rows.enumerated() {
            if r.line > p.line { break }
            if r.line == p.line && r.start <= p.column { found = i }
        }
        return found
    }

    /// The x of `p` within its row.
    public func x(of p: TextPosition) -> Double {
        let r = rows[row(of: p)]
        let line = lines[r.line]
        var x = 0.0
        for c in r.start..<min(p.column, r.end) { x += advance(line[c]) }
        return x
    }

    /// The position nearest `x` in row `row` — where a click or Up/Down lands.
    /// On a row a line wraps out of, never its very end (that is the next
    /// row's start): the last Character boundary before it.
    public func position(row: Int, x: Double) -> TextPosition {
        let row = min(max(0, row), rows.count - 1)
        let r = rows[row], line = lines[r.line]
        let wraps = r.end < line.count
        let limit = wraps && r.end > r.start ? r.end - 1 : r.end
        var acc = 0.0
        for c in r.start..<limit {
            let w = advance(line[c])
            if x < acc + w / 2 { return TextPosition(line: r.line, column: c) }
            acc += w
        }
        return TextPosition(line: r.line, column: limit)
    }

    /// Up (-1) or Down (+1) from `p`, keeping `goalX`; nil at the top or bottom.
    public func vertical(from p: TextPosition, by delta: Int, goalX: Double) -> TextPosition? {
        let target = row(of: p) + delta
        guard target >= 0 && target < rows.count else { return nil }
        return position(row: target, x: goalX)
    }
}
