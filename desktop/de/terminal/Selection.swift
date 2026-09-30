// Selection — the screen's text across its scrollback, for Copy (PHASE15
// P15.4c): every line addressed as one sequence, oldest scrollback first, so a
// selection can start in history and end on the screen.

/// A place in the text: `line` counts from the oldest line of scrollback
/// (0) through the screen's rows; `col` is a column in that line.
public struct TextPoint: Comparable, Hashable, Sendable {
    public var line: Int
    public var col: Int
    public init(line: Int, col: Int) { self.line = line; self.col = col }
    public static func < (a: TextPoint, b: TextPoint) -> Bool {
        a.line != b.line ? a.line < b.line : a.col < b.col
    }
}

extension Screen {
    /// Scrollback and screen, as one count.
    public var totalLines: Int { scrollback.count + rows }

    /// Line `i` of the whole: scrollback, then the screen's rows.
    public func line(_ i: Int) -> [Cell] {
        i < scrollback.count ? scrollback[i] : grid[i - scrollback.count]
    }

    /// The text from `a` to `b` inclusive, in whichever order they are given.
    /// A line that wrapped continues into the next with no newline (a long
    /// command copies as one line); any other line ends with one and loses
    /// its trailing spaces, as xterm copies.
    public func text(from a: TextPoint, to b: TextPoint) -> String {
        let (s, e) = a <= b ? (a, b) : (b, a)
        guard totalLines > 0 else { return "" }
        let first = max(0, s.line), last = min(totalLines - 1, e.line)
        guard first <= last else { return "" }
        var out = ""
        for i in first...last {
            let cells = line(i)
            guard !cells.isEmpty else { if i < last { out += "\n" }; continue }
            let from = i == s.line ? min(max(0, s.col), cells.count - 1) : 0
            let to = i == e.line ? min(max(0, e.col), cells.count - 1) : cells.count - 1
            var piece = from <= to ? String(String.UnicodeScalarView(cells[from...to].map(\.scalar))) : ""
            let wraps = cells.last?.wrapsToNext == true && to == cells.count - 1
            if !wraps { while piece.last == " " { piece.removeLast() } }
            out += piece
            if i < last && !wraps { out += "\n" }
        }
        return out
    }

    /// The word around `p` — letters, digits and the characters paths and
    /// URLs are made of — or the one character there if it is not in a word;
    /// what a double-click selects.
    public func wordRange(at p: TextPoint) -> (TextPoint, TextPoint) {
        guard p.line >= 0, p.line < totalLines else { return (p, p) }
        let cells = line(p.line)
        guard p.col >= 0, p.col < cells.count else { return (p, p) }
        func inWord(_ s: Unicode.Scalar) -> Bool {
            s.properties.isAlphabetic || ("0"..."9").contains(s) || "-_./~:@%+=?&#".unicodeScalars.contains(s)
        }
        guard inWord(cells[p.col].scalar) else { return (p, p) }
        var a = p.col, b = p.col
        while a > 0 && inWord(cells[a - 1].scalar) { a -= 1 }
        while b < cells.count - 1 && inWord(cells[b + 1].scalar) { b += 1 }
        return (TextPoint(line: p.line, col: a), TextPoint(line: p.line, col: b))
    }

    /// The whole line at `p`: what a triple-click selects.
    public func lineRange(at p: TextPoint) -> (TextPoint, TextPoint) {
        let n = p.line >= 0 && p.line < totalLines ? line(p.line).count : cols
        return (TextPoint(line: p.line, col: 0), TextPoint(line: p.line, col: max(0, n - 1)))
    }

    /// Forget the history (Clear Scrollback, ⌘K). The screen stays.
    public mutating func clearScrollback() { feed("\u{1B}[3J") }
}

/// What a paste sends the program (P15.4c).
public enum Paste {
    /// `text` as typed: newlines become carriage returns, which the tty turns
    /// back into newlines for a program reading lines — the Return key's byte.
    /// When the program asked for bracketed paste (`CSI ?2004h`: shells and
    /// editors, so a pasted command does not run line by line), it is wrapped
    /// in `CSI 200~` … `CSI 201~`, and an end marker *inside* the text is
    /// removed — otherwise pasted text could end the bracket and run commands.
    public static func bytes(_ text: String, bracketed: Bool) -> [UInt8] {
        // Bytes, not String: this target imports no Foundation.
        var out: [UInt8] = []
        let t = Array(text.utf8)
        var i = 0
        while i < t.count {
            if t[i] == 0x0D && i + 1 < t.count && t[i + 1] == 0x0A { out.append(0x0D); i += 2; continue }
            out.append(t[i] == 0x0A ? 0x0D : t[i]); i += 1
        }
        guard bracketed else { return out }
        let end: [UInt8] = Array("\u{1B}[201~".utf8)
        var clean: [UInt8] = []
        i = 0
        while i < out.count {
            if i + end.count <= out.count && Array(out[i..<(i + end.count)]) == end { i += end.count; continue }
            clean.append(out[i]); i += 1
        }
        return Array("\u{1B}[200~".utf8) + clean + end
    }
}
