// TextModel — multi-line text being edited (PHASE15 P15.5).
//
// The toolkit's text view is built on this, and every editor after TextEdit
// uses the view, so this is the part that has to be right: what an edit does,
// where the caret goes, what Undo puts back, what Find finds. Pure — no
// display, no font — so every one of those is a unit test. The view supplies
// what only it knows (how wide a line is, for wrapping and for up/down) through
// `TextLayout`.
//
// The text is lines of Characters (grapheme clusters): a caret never lands
// inside an "é" written as e + combining accent, and a line is what a person
// would call one. A position is (line, column-in-Characters).

public struct TextPosition: Comparable, Hashable, Sendable {
    public var line: Int
    public var column: Int
    public init(line: Int, column: Int) { self.line = line; self.column = column }
    public static let start = TextPosition(line: 0, column: 0)
    public static func < (a: TextPosition, b: TextPosition) -> Bool {
        a.line != b.line ? a.line < b.line : a.column < b.column
    }
}

public struct TextRange: Equatable, Hashable, Sendable {
    public var start: TextPosition
    public var end: TextPosition
    public init(_ a: TextPosition, _ b: TextPosition) { start = min(a, b); end = max(a, b) }
    public var isEmpty: Bool { start == end }
}

/// One change, as Undo needs it: what was there, what is there now.
public struct TextEdit: Equatable, Sendable {
    /// Where the change happened, in the text as it was before.
    public var at: TextPosition
    public var removed: String
    public var inserted: String
    public var selectionBefore: TextRange
    public var selectionAfter: TextRange
    public var kind: Kind
    public enum Kind: Equatable, Sendable { case typing, deleting, paste, cut, other(String) }
}

public struct TextModel: Sendable {
    public private(set) var lines: [[Character]] = [[]]
    /// Where a selection was started, and the caret: equal when nothing is selected.
    public private(set) var anchor = TextPosition.start
    public private(set) var caret = TextPosition.start
    /// Up and down keep the column a person was in, across shorter lines.
    public var goalX: Double?
    public private(set) var history = UndoHistory()
    /// Edited since it was last opened or saved.
    public var isDirty: Bool { history.dirty }

    public init(_ text: String = "") {
        lines = TextModel.split(text)
    }

    // MARK: - Reading

    public var text: String { lines.map { String($0) }.joined(separator: "\n") }
    public var selection: TextRange { TextRange(anchor, caret) }
    public var selectedText: String { text(in: selection) }
    public var lineCount: Int { lines.count }

    public func text(in r: TextRange) -> String {
        let s = clamp(r.start), e = clamp(r.end)
        if s.line == e.line { return String(lines[s.line][s.column..<e.column]) }
        var out = String(lines[s.line][s.column...])
        for l in (s.line + 1)..<e.line { out += "\n" + String(lines[l]) }
        out += "\n" + String(lines[e.line][..<e.column])
        return out
    }

    public func clamp(_ p: TextPosition) -> TextPosition {
        let l = min(max(0, p.line), lines.count - 1)
        return TextPosition(line: l, column: min(max(0, p.column), lines[l].count))
    }

    public var end: TextPosition { TextPosition(line: lines.count - 1, column: lines[lines.count - 1].count) }

    // MARK: - Selecting

    /// Put the caret at `p`; with `extend`, keep the anchor (Shift).
    public mutating func setCaret(_ p: TextPosition, extend: Bool = false, keepGoal: Bool = false) {
        caret = clamp(p)
        if !extend { anchor = caret }
        if !keepGoal { goalX = nil }
        history.breakTyping()
    }

    public mutating func select(_ r: TextRange) {
        anchor = clamp(r.start); caret = clamp(r.end); goalX = nil
        history.breakTyping()
    }

    public mutating func selectAll() { select(TextRange(.start, end)) }

    // MARK: - Motion

    public enum Motion: Sendable { case left, right, wordLeft, wordRight, lineStart, lineEnd, documentStart, documentEnd }

    /// Move the caret. Without `extend`, a selection collapses to the side
    /// moved toward (left or right), as a Mac text field does.
    public mutating func move(_ m: Motion, extend: Bool = false) {
        if !extend, !selection.isEmpty, m == .left || m == .right {
            setCaret(m == .left ? selection.start : selection.end)
            return
        }
        setCaret(target(of: m, from: caret), extend: extend)
    }

    public func target(of m: Motion, from p: TextPosition) -> TextPosition {
        switch m {
        case .left:
            if p.column > 0 { return TextPosition(line: p.line, column: p.column - 1) }
            return p.line > 0 ? TextPosition(line: p.line - 1, column: lines[p.line - 1].count) : p
        case .right:
            if p.column < lines[p.line].count { return TextPosition(line: p.line, column: p.column + 1) }
            return p.line < lines.count - 1 ? TextPosition(line: p.line + 1, column: 0) : p
        case .wordLeft:
            var q = p
            // Back over spaces and punctuation, then over the word.
            while true {
                let prev = target(of: .left, from: q)
                if prev == q { return q }
                if prev.line != q.line { if q.column == 0 && q != p { return q }; q = prev; continue }
                if TextModel.isWord(lines[prev.line][prev.column]) { break }
                q = prev
            }
            while q.column > 0 && TextModel.isWord(lines[q.line][q.column - 1]) { q.column -= 1 }
            return q
        case .wordRight:
            var q = p
            while true {
                if q.column >= lines[q.line].count {
                    if q.line == lines.count - 1 { return q }
                    if q != p { return q }
                    q = TextPosition(line: q.line + 1, column: 0); continue
                }
                if TextModel.isWord(lines[q.line][q.column]) { break }
                q.column += 1
            }
            while q.column < lines[q.line].count && TextModel.isWord(lines[q.line][q.column]) { q.column += 1 }
            return q
        case .lineStart: return TextPosition(line: p.line, column: 0)
        case .lineEnd: return TextPosition(line: p.line, column: lines[p.line].count)
        case .documentStart: return .start
        case .documentEnd: return end
        }
    }

    static func isWord(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" || c == "'" }

    /// The word around `p`: what a double-click selects.
    public func wordRange(at p: TextPosition) -> TextRange {
        let p = clamp(p), line = lines[p.line]
        guard !line.isEmpty else { return TextRange(p, p) }
        var c = min(p.column, line.count - 1)
        if !TextModel.isWord(line[c]), c > 0, TextModel.isWord(line[c - 1]) { c -= 1 }
        guard TextModel.isWord(line[c]) else {
            return TextRange(TextPosition(line: p.line, column: c), TextPosition(line: p.line, column: c + 1))
        }
        var a = c, b = c
        while a > 0 && TextModel.isWord(line[a - 1]) { a -= 1 }
        while b < line.count && TextModel.isWord(line[b]) { b += 1 }
        return TextRange(TextPosition(line: p.line, column: a), TextPosition(line: p.line, column: b))
    }

    public func lineRange(at p: TextPosition) -> TextRange {
        let l = clamp(p).line
        let e = l < lines.count - 1 ? TextPosition(line: l + 1, column: 0) : TextPosition(line: l, column: lines[l].count)
        return TextRange(TextPosition(line: l, column: 0), e)
    }

    // MARK: - Editing

    /// Type or paste `s` over the selection.
    public mutating func insert(_ s: String, kind: TextEdit.Kind = .typing) {
        replace(selection, with: s, kind: kind)
    }

    /// Backspace: the selection, or the Character before the caret (with
    /// `word`, the word before it — Option-Delete).
    public mutating func deleteBackward(word: Bool = false) {
        if !selection.isEmpty { replace(selection, with: "", kind: .deleting); return }
        let from = target(of: word ? .wordLeft : .left, from: caret)
        guard from != caret else { return }
        replace(TextRange(from, caret), with: "", kind: .deleting)
    }

    /// Forward delete (fn-Delete).
    public mutating func deleteForward(word: Bool = false) {
        if !selection.isEmpty { replace(selection, with: "", kind: .deleting); return }
        let to = target(of: word ? .wordRight : .right, from: caret)
        guard to != caret else { return }
        replace(TextRange(caret, to), with: "", kind: .deleting)
    }

    /// The one primitive every edit goes through: so Undo is exact by
    /// construction.
    public mutating func replace(_ r: TextRange, with s: String, kind: TextEdit.Kind = .other("Change")) {
        let r = TextRange(clamp(r.start), clamp(r.end))
        let before = selection
        let removed = text(in: r)
        let endPos = splice(r, s)
        caret = endPos; anchor = endPos; goalX = nil
        history.record(TextEdit(at: r.start, removed: removed, inserted: s,
                                selectionBefore: before, selectionAfter: TextRange(endPos, endPos), kind: kind))
    }

    /// Put `s` in place of `r` and return where it ends. No history.
    @discardableResult
    private mutating func splice(_ r: TextRange, _ s: String) -> TextPosition {
        let head = lines[r.start.line][..<r.start.column]
        let tail = lines[r.end.line][r.end.column...]
        var pieces = TextModel.split(s)
        let lastCount = pieces[pieces.count - 1].count
        pieces[0] = Array(head) + pieces[0]
        pieces[pieces.count - 1] += Array(tail)
        lines.replaceSubrange(r.start.line...r.end.line, with: pieces)
        let endLine = r.start.line + pieces.count - 1
        let endCol = pieces.count == 1 ? head.count + lastCount : lastCount
        return TextPosition(line: endLine, column: endCol)
    }

    /// Lines of `s`: "\n", "\r\n" and a lone "\r" all end one.
    static func split(_ s: String) -> [[Character]] {
        var out: [[Character]] = [[]]
        for c in s {
            if c == "\n" || c == "\r\n" || c == "\r" { out.append([]) } else { out[out.count - 1].append(c) }
        }
        return out
    }

    // MARK: - Undo

    public var canUndo: Bool { history.canUndo }
    public var canRedo: Bool { history.canRedo }
    /// "Typing", "Paste", … — the Edit menu says "Undo Typing".
    public var undoName: String? { history.undoName }
    public var redoName: String? { history.redoName }

    public mutating func undo() {
        guard let group = history.popUndo() else { return }
        for e in group.reversed() {
            let insertedEnd = TextModel.endOf(e.inserted, from: e.at)
            splice(TextRange(e.at, insertedEnd), e.removed)
        }
        if let first = group.first { anchor = clamp(first.selectionBefore.start); caret = clamp(first.selectionBefore.end) }
        goalX = nil
    }

    public mutating func redo() {
        guard let group = history.popRedo() else { return }
        for e in group {
            let removedEnd = TextModel.endOf(e.removed, from: e.at)
            splice(TextRange(e.at, removedEnd), e.inserted)
        }
        if let last = group.last { anchor = clamp(last.selectionAfter.start); caret = clamp(last.selectionAfter.end) }
        goalX = nil
    }

    /// Where `s` ends if it starts at `p`.
    static func endOf(_ s: String, from p: TextPosition) -> TextPosition {
        let pieces = split(s)
        return pieces.count == 1 ? TextPosition(line: p.line, column: p.column + pieces[0].count)
                                 : TextPosition(line: p.line + pieces.count - 1, column: pieces[pieces.count - 1].count)
    }

    /// The text is what is on disk now (opened, or just saved).
    public mutating func markSaved() { history.markSaved() }

    // MARK: - Find

    /// The next place `needle` occurs after the selection (before it, with
    /// `backward`), going round the end; nil if it is nowhere.
    public func find(_ needle: String, backward: Bool = false, ignoringCase: Bool = true) -> TextRange? {
        guard !needle.isEmpty else { return nil }
        let hay = Array(text), want = Array(needle)
        func fold(_ c: Character) -> Character { ignoringCase ? Character(c.lowercased()) : c }
        let h = ignoringCase ? hay.map(fold) : hay, w = ignoringCase ? want.map(fold) : want
        guard w.count <= h.count else { return nil }
        func matches(_ i: Int) -> Bool { i >= 0 && i + w.count <= h.count && Array(h[i..<(i + w.count)]) == w }
        let selStart = offset(of: selection.start), selEnd = offset(of: selection.end)
        let n = h.count - w.count
        if backward {
            var i = selStart - 1
            for _ in 0...n { if i < 0 { i = n }; if matches(i) { return range(i, w.count) }; i -= 1 }
        } else {
            var i = selEnd
            for _ in 0...n { if i > n { i = 0 }; if matches(i) { return range(i, w.count) }; i += 1 }
        }
        return nil
    }

    /// A position as a Character offset into `text`, newlines counted.
    public func offset(of p: TextPosition) -> Int {
        let p = clamp(p)
        var n = 0
        for l in 0..<p.line { n += lines[l].count + 1 }
        return n + p.column
    }

    public func position(ofOffset o: Int) -> TextPosition {
        var o = max(0, o)
        for (i, l) in lines.enumerated() {
            if o <= l.count { return TextPosition(line: i, column: o) }
            o -= l.count + 1
        }
        return end
    }

    private func range(_ offset: Int, _ count: Int) -> TextRange {
        TextRange(position(ofOffset: offset), position(ofOffset: offset + count))
    }
}

/// What Undo can put back, and what Redo can put back again. Typing that runs
/// on — one Character after another, with nothing between — is one entry
/// ("Undo Typing" takes back the word, not the letter), as is a run of
/// Backspaces; any other edit, a click, or a caret move closes the run.
public struct UndoHistory: Sendable {
    private var done: [[TextEdit]] = []
    private var undone: [[TextEdit]] = []
    private var typingOpen = false
    /// How many entries back the saved text is; nil when it can no longer be
    /// reached (an edit after an undo past it).
    private var savedAt: Int? = 0
    public let limit: Int

    public init(limit: Int = 200) { self.limit = limit }

    public var canUndo: Bool { !done.isEmpty }
    public var canRedo: Bool { !undone.isEmpty }
    public var dirty: Bool { savedAt != done.count }
    public var undoName: String? { done.last.map(UndoHistory.name) }
    public var redoName: String? { undone.last.map(UndoHistory.name) }

    static func name(_ g: [TextEdit]) -> String {
        switch g.first?.kind {
        case .typing?: return "Typing"
        case .deleting?: return "Delete"
        case .paste?: return "Paste"
        case .cut?: return "Cut"
        case .other(let s)?: return s
        case nil: return ""
        }
    }

    mutating func record(_ e: TextEdit) {
        // An edit after undoing past the saved text: that text can no longer
        // be reached by Undo or Redo, so the document is dirty until saved.
        if let s = savedAt, s > done.count { savedAt = nil }
        undone.removeAll()
        let runs = (e.kind == .typing || e.kind == .deleting)
        // A run continues only while typing is open — a save, a click or a
        // caret move closes it — so a group never straddles the saved text.
        if runs, typingOpen, let last = done.last?.last, last.kind == e.kind, contiguous(last, e) {
            done[done.count - 1].append(e)
        } else {
            done.append([e])
            if done.count > limit {
                let drop = done.count - limit
                done.removeFirst(drop)
                savedAt = savedAt.flatMap { $0 - drop >= 0 ? $0 - drop : nil }
            }
        }
        typingOpen = runs
    }

    /// Typing continues where it left off; deleting continues where the last
    /// deletion left the caret.
    private func contiguous(_ a: TextEdit, _ b: TextEdit) -> Bool {
        if a.kind == .typing { return b.at == TextModel.endOf(a.inserted, from: a.at) && b.removed.isEmpty && a.removed.isEmpty }
        return b.selectionBefore == a.selectionAfter
    }

    mutating func breakTyping() { typingOpen = false }

    mutating func popUndo() -> [TextEdit]? {
        guard let g = done.popLast() else { return nil }
        undone.append(g); typingOpen = false
        return g
    }

    mutating func popRedo() -> [TextEdit]? {
        guard let g = undone.popLast() else { return nil }
        done.append(g); typingOpen = false
        return g
    }

    mutating func markSaved() { savedAt = done.count; typingOpen = false }
}
