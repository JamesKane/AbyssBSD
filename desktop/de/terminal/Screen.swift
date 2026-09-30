// Screen — what a terminal shows, and what a program's output does to it
// (PHASE15 P15.4a).
//
// The model `VTParser`'s actions drive: a grid of cells, a cursor and its pen,
// a scroll region, the modes a program sets, and the alternate screen that
// full-screen programs (`vi`, `less`, `top`) draw on and leave. Pure — no pty,
// no display — so that "vi draws correctly" is an assertion on `lines`.
//
// **The subset is xterm's, as `TERM=xterm` uses it** (PHASE15 §6.4), read off
// its terminfo entry rather than guessed: `smcup` is `CSI ?1049h CSI 22;0;0t`,
// `rep` is `CSI Ps b`, `csr` sets a scroll region, `sgr0` is `ESC ( B CSI m`,
// colours are SGR 30–37/40–47 plus 256 and direct colour for programs that
// assume them. Erase uses the pen's background (terminfo's `bce`). Not here:
// double-width characters (every scalar is one column), combining marks, mouse
// reporting, double-height lines, and 132-column mode — each ignored, not
// mis-drawn.

public enum TermColor: Equatable, Hashable, Sendable {
    case `default`
    case indexed(UInt8)                 // 0–15 the palette, 16–255 xterm's cube and greys
    case rgb(UInt8, UInt8, UInt8)
}

public struct CellAttributes: Equatable, Hashable, Sendable {
    public var fg: TermColor = .default
    public var bg: TermColor = .default
    public var bold = false, dim = false, italic = false, underline = false
    public var blink = false, inverse = false, invisible = false, strike = false
    public init() {}
}

public struct Cell: Equatable, Sendable {
    public var scalar: Unicode.Scalar
    public var attrs: CellAttributes
    public init(_ scalar: Unicode.Scalar = " ", _ attrs: CellAttributes = CellAttributes()) {
        self.scalar = scalar; self.attrs = attrs
    }
}

public struct Screen: Sendable {
    public private(set) var rows: Int
    public private(set) var cols: Int
    public private(set) var cursorRow = 0
    public private(set) var cursorCol = 0
    /// The pen: what the next character is drawn with.
    public private(set) var pen = CellAttributes()

    // Modes a program sets.
    public private(set) var autowrap = true
    public private(set) var originMode = false
    public private(set) var insertMode = false
    public private(set) var cursorVisible = true
    /// DECCKM: arrow keys send `ESC O A`, not `ESC [ A` — `vi` and `less` ask.
    public private(set) var applicationCursorKeys = false
    public private(set) var applicationKeypad = false
    public private(set) var bracketedPaste = false
    public private(set) var usingAlternate = false

    public private(set) var scrollTop = 0
    public private(set) var scrollBottom: Int
    public private(set) var title = ""
    public private(set) var bells = 0

    /// Lines scrolled off the top of the main screen, oldest first — P15.4c's
    /// scrollback. Never the alternate screen's: `vi` scrolling is not history.
    public private(set) var scrollback: [[Cell]] = []
    public var scrollbackLimit = 10_000

    /// What the terminal must say back to the program — the replies to `CSI 6n`
    /// (where is the cursor?) and `CSI c` (what are you?). The owner writes them
    /// to the pty and clears this.
    public var responses: [UInt8] = []

    private var main: [[Cell]]
    private var alternate: [[Cell]]
    /// Set by printing in the last column: the *next* character wraps. xterm's
    /// rule, and the difference between a status line that fits and one that
    /// scrolls the screen.
    private var pendingWrap = false
    private var tabStops: Set<Int> = []
    private var saved = Saved()
    private var savedAlternate = Saved()
    /// G0 and G1: DEC special graphics (line drawing) or ASCII; SO selects G1.
    private var g0Graphics = false, g1Graphics = false, shifted = false
    private var lastPrinted: Unicode.Scalar = " "
    private var parser = VTParser()

    struct Saved: Sendable {
        var row = 0, col = 0
        var pen = CellAttributes()
        var originMode = false, autowrap = true
        var g0Graphics = false, g1Graphics = false, shifted = false
    }

    public init(rows: Int, cols: Int) {
        self.rows = max(1, rows); self.cols = max(1, cols)
        scrollBottom = self.rows - 1
        main = Screen.blank(self.rows, self.cols)
        alternate = Screen.blank(self.rows, self.cols)
        resetTabs()
    }

    // MARK: - Reading it

    public var grid: [[Cell]] { usingAlternate ? alternate : main }

    /// Row `r` as text, trailing spaces trimmed.
    public func text(row r: Int) -> String {
        var s = String(String.UnicodeScalarView(grid[r].map(\.scalar)))
        while s.last == " " { s.removeLast() }
        return s
    }

    public var lines: [String] { (0..<rows).map { text(row: $0) } }

    public func cell(_ r: Int, _ c: Int) -> Cell { grid[r][c] }

    // MARK: - Feeding it

    public mutating func feed<S: Sequence>(_ bytes: S) where S.Element == UInt8 {
        var p = parser
        var actions: [VTAction] = []
        p.feed(bytes) { actions.append($0) }
        parser = p
        for a in actions { apply(a) }
    }

    public mutating func feed(_ s: String) { feed(Array(s.utf8)) }

    public mutating func apply(_ action: VTAction) {
        switch action {
        case .print(let s): put(s)
        case .execute(let b): execute(b)
        case .csi(let params, let inter, let priv, let final): csi(params, inter, priv, final)
        case .esc(let inter, let final): esc(inter, final)
        case .osc(let s): osc(s)
        }
    }

    // MARK: - Size

    /// A new size, as the window gives it. Lines that no longer fit above the
    /// cursor go to scrollback (main screen), so the cursor's line stays in view.
    public mutating func resize(rows newRows: Int, cols newCols: Int) {
        let nr = max(1, newRows), nc = max(1, newCols)
        guard nr != rows || nc != cols else { return }
        func fit(_ g: [[Cell]], keepHistory: Bool, cursor: inout Int) -> [[Cell]] {
            var g = g.map { line -> [Cell] in
                line.count >= nc ? Array(line.prefix(nc)) : line + Array(repeating: Cell(), count: nc - line.count)
            }
            if g.count > nr {
                let excess = min(g.count - nr, max(0, cursor - (nr - 1)))
                if excess > 0 {
                    if keepHistory { pushScrollback(g.prefix(excess)) }
                    g.removeFirst(excess)
                    cursor -= excess
                }
                if g.count > nr { g.removeLast(g.count - nr) }
            }
            while g.count < nr { g.append(Array(repeating: Cell(), count: nc)) }
            return g
        }
        var mainCursor = usingAlternate ? saved.row : cursorRow
        var altCursor = usingAlternate ? cursorRow : 0
        main = fit(main, keepHistory: true, cursor: &mainCursor)
        alternate = fit(alternate, keepHistory: false, cursor: &altCursor)
        rows = nr; cols = nc
        if usingAlternate { cursorRow = altCursor; saved.row = min(mainCursor, nr - 1) } else { cursorRow = mainCursor }
        cursorRow = min(max(0, cursorRow), nr - 1)
        cursorCol = min(cursorCol, nc - 1)
        scrollTop = 0; scrollBottom = nr - 1
        pendingWrap = false
        resetTabs()
    }

    // MARK: - Characters

    private mutating func put(_ scalar: Unicode.Scalar) {
        var s = scalar
        if (shifted ? g1Graphics : g0Graphics), let g = Screen.decGraphics[s] { s = g }
        if pendingWrap && autowrap {
            cursorCol = 0
            lineFeed()
        }
        pendingWrap = false
        if insertMode {
            let blank = Cell(" ", pen), c = cursorCol
            modifyCurrentLine { line in
                line.insert(blank, at: c)
                line.removeLast()
            }
        }
        setCell(cursorRow, cursorCol, Cell(s, pen))
        lastPrinted = s
        if cursorCol == cols - 1 { pendingWrap = autowrap } else { cursorCol += 1 }
    }

    private mutating func execute(_ b: UInt8) {
        switch b {
        case 0x07: bells += 1
        case 0x08: if cursorCol > 0 { cursorCol -= 1 }; pendingWrap = false
        case 0x09: tab(1)
        case 0x0A, 0x0B, 0x0C: lineFeed()
        case 0x0D: cursorCol = 0; pendingWrap = false
        case 0x0E: shifted = true
        case 0x0F: shifted = false
        default: break
        }
    }

    private mutating func lineFeed() {
        pendingWrap = false
        if cursorRow == scrollBottom { scrollUp(1) }
        else if cursorRow < rows - 1 { cursorRow += 1 }
    }

    private mutating func reverseIndex() {
        pendingWrap = false
        if cursorRow == scrollTop { scrollDown(1) }
        else if cursorRow > 0 { cursorRow -= 1 }
    }

    private mutating func tab(_ n: Int) {
        pendingWrap = false
        for _ in 0..<max(1, n) {
            var c = cursorCol + 1
            while c < cols - 1 && !tabStops.contains(c) { c += 1 }
            cursorCol = min(c, cols - 1)
        }
    }

    private mutating func backTab(_ n: Int) {
        pendingWrap = false
        for _ in 0..<max(1, n) {
            var c = cursorCol - 1
            while c > 0 && !tabStops.contains(c) { c -= 1 }
            cursorCol = max(0, c)
        }
    }

    // MARK: - Scrolling

    /// Scroll the region up: its top line leaves (into scrollback, if the
    /// region is the whole main screen), a blank one enters at the bottom.
    /// `history: false` for DL, which deletes lines rather than scrolling them away.
    private mutating func scrollUp(_ n: Int, history: Bool = true) {
        let n = min(max(1, n), scrollBottom - scrollTop + 1)
        let blank = blankLine(), top = scrollTop, bottom = scrollBottom
        var gone: [[Cell]] = []
        modifyGrid { g in
            gone = Array(g[top..<(top + n)])
            g.removeSubrange(top..<(top + n))
            g.insert(contentsOf: Array(repeating: blank, count: n), at: bottom - n + 1)
        }
        if history && !usingAlternate && top == 0 && bottom == rows - 1 {
            pushScrollback(gone[...])
        }
    }

    private mutating func scrollDown(_ n: Int) {
        let n = min(max(1, n), scrollBottom - scrollTop + 1)
        let blank = blankLine(), top = scrollTop, bottom = scrollBottom
        modifyGrid { g in
            g.removeSubrange((bottom - n + 1)...bottom)
            g.insert(contentsOf: Array(repeating: blank, count: n), at: top)
        }
    }

    private mutating func pushScrollback(_ lines: ArraySlice<[Cell]>) {
        scrollback.append(contentsOf: lines)
        if scrollback.count > scrollbackLimit { scrollback.removeFirst(scrollback.count - scrollbackLimit) }
    }

    // MARK: - ESC

    private mutating func esc(_ inter: [UInt8], _ final: UInt8) {
        switch (inter.first, final) {
        case (nil, 0x37): saveCursor()                               // 7
        case (nil, 0x38): restoreCursor()                            // 8
        case (nil, 0x44): lineFeed()                                 // D  IND
        case (nil, 0x45): cursorCol = 0; lineFeed()                  // E  NEL
        case (nil, 0x4D): reverseIndex()                             // M  RI
        case (nil, 0x48): tabStops.insert(cursorCol)                 // H  HTS
        case (nil, 0x63): self = Screen(rows: rows, cols: cols)      // c  RIS
        case (nil, 0x3D): applicationKeypad = true                   // =
        case (nil, 0x3E): applicationKeypad = false                  // >
        case (0x28?, let f): g0Graphics = (f == 0x30)                // ( 0 / ( B
        case (0x29?, let f): g1Graphics = (f == 0x30)                // ) 0 / ) B
        case (0x23?, 0x38):                                          // # 8  DECALN (vttest's screen of E)
            main = Array(repeating: Array(repeating: Cell("E"), count: cols), count: rows)
            if usingAlternate { alternate = main }
            cursorRow = 0; cursorCol = 0
        default: break
        }
    }

    private mutating func saveCursor() {
        let s = Saved(row: cursorRow, col: cursorCol, pen: pen, originMode: originMode, autowrap: autowrap,
                      g0Graphics: g0Graphics, g1Graphics: g1Graphics, shifted: shifted)
        if usingAlternate { savedAlternate = s } else { saved = s }
    }

    private mutating func restoreCursor() {
        let s = usingAlternate ? savedAlternate : saved
        cursorRow = min(s.row, rows - 1); cursorCol = min(s.col, cols - 1)
        pen = s.pen; originMode = s.originMode; autowrap = s.autowrap
        g0Graphics = s.g0Graphics; g1Graphics = s.g1Graphics; shifted = s.shifted
        pendingWrap = false
    }

    // MARK: - OSC

    private mutating func osc(_ s: String) {
        guard let semi = s.firstIndex(of: ";") else { return }
        switch s[..<semi] {
        case "0", "2": title = String(s[s.index(after: semi)...])
        default: break
        }
    }

    // MARK: - CSI

    private mutating func csi(_ p: [Int], _ inter: [UInt8], _ priv: UInt8?, _ final: UInt8) {
        /// Parameter `i`, where 0 and absent both mean `def` — the ANSI rule.
        func arg(_ i: Int, _ def: Int = 1) -> Int { i < p.count && p[i] != 0 ? p[i] : def }
        if priv == 0x3F {                                            // ?
            switch final {
            case 0x68: for m in p { setPrivateMode(m, true) }        // h
            case 0x6C: for m in p { setPrivateMode(m, false) }       // l
            default: break
            }
            return
        }
        if priv == 0x3E {                                            // >
            if final == 0x63 { reply("\u{1B}[>0;95;0c") }            // secondary DA: an xterm
            return
        }
        if priv == nil, inter == [0x21], final == 0x70 { softReset(); return }   // ! p  DECSTR (termcap's `is`)
        guard priv == nil, inter.isEmpty else { return }             // DECSCUSR (" q") and the rest: ignored
        switch final {
        case 0x40: insertCells(arg(0))                               // @  ICH
        case 0x41: moveUp(arg(0))                                    // A  CUU
        case 0x42, 0x65: moveDown(arg(0))                            // B CUD, e VPR
        case 0x43, 0x61: moveTo(cursorRow, cursorCol + arg(0))       // C CUF, a HPR
        case 0x44: moveTo(cursorRow, cursorCol - arg(0))             // D  CUB
        case 0x45: moveDown(arg(0)); cursorCol = 0                   // E  CNL
        case 0x46: moveUp(arg(0)); cursorCol = 0                     // F  CPL
        case 0x47, 0x60: moveTo(cursorRow, arg(0) - 1)               // G CHA, ` HPA
        case 0x48, 0x66: cursorPosition(arg(0), arg(1))              // H CUP, f HVP
        case 0x49: tab(arg(0))                                       // I  CHT
        case 0x4A: eraseDisplay(arg(0, 0))                           // J  ED
        case 0x4B: eraseLine(arg(0, 0))                              // K  EL
        case 0x4C: insertLines(arg(0))                               // L  IL
        case 0x4D: deleteLines(arg(0))                               // M  DL
        case 0x50: deleteCells(arg(0))                               // P  DCH
        case 0x53: scrollUp(arg(0))                                  // S  SU
        case 0x54: scrollDown(arg(0))                                // T  SD
        case 0x58: eraseCells(arg(0))                                // X  ECH
        case 0x5A: backTab(arg(0))                                   // Z  CBT
        case 0x62: for _ in 0..<min(arg(0), rows * cols) { put(lastPrinted) }  // b  REP
        case 0x63: if arg(0, 0) == 0 { reply("\u{1B}[?1;2c") }      // c  DA: a VT100 with AVO
        case 0x64: cursorPosition(arg(0), cursorCol + 1, absoluteRow: true)    // d  VPA
        case 0x67:                                                   // g  TBC
            switch arg(0, 0) { case 0: tabStops.remove(cursorCol); case 3: tabStops.removeAll(); default: break }
        case 0x68: if p.contains(4) { insertMode = true }            // h  SM (IRM)
        case 0x6C: if p.contains(4) { insertMode = false }           // l  RM
        case 0x6D: sgr(p)                                            // m  SGR
        case 0x6E:                                                   // n  DSR
            switch arg(0, 0) {
            case 5: reply("\u{1B}[0n")
            case 6:
                let r = originMode ? cursorRow - scrollTop : cursorRow
                reply("\u{1B}[\(r + 1);\(cursorCol + 1)R")
            default: break
            }
        case 0x72:                                                   // r  DECSTBM
            let top = arg(0) - 1, bottom = arg(1, rows) - 1
            if top < bottom && bottom < rows {
                scrollTop = top; scrollBottom = bottom
                cursorPosition(1, 1)
            }
        case 0x73: saveCursor()                                      // s  SCOSC
        case 0x75: restoreCursor()                                   // u  SCORC
        default: break                                               // t (window ops) and the rest
        }
    }

    /// DECSTR: modes and pen to their defaults, the text left alone.
    private mutating func softReset() {
        pen = CellAttributes()
        insertMode = false; originMode = false; autowrap = true; cursorVisible = true
        applicationCursorKeys = false; applicationKeypad = false
        scrollTop = 0; scrollBottom = rows - 1
        g0Graphics = false; g1Graphics = false; shifted = false
        saved = Saved(); savedAlternate = Saved()
        pendingWrap = false
    }

    private mutating func setPrivateMode(_ m: Int, _ on: Bool) {
        switch m {
        case 1: applicationCursorKeys = on
        case 6: originMode = on; cursorPosition(1, 1)
        case 7: autowrap = on; if !on { pendingWrap = false }
        case 25: cursorVisible = on
        case 47, 1047:
            if on != usingAlternate {
                if on { alternate = Screen.blank(rows, cols) }
                usingAlternate = on
            }
        case 1048: if on { saveCursor() } else { restoreCursor() }
        case 1049:
            // Save the cursor on the main screen, switch, clear — and back.
            if on && !usingAlternate {
                saveCursor()
                usingAlternate = true
                alternate = Screen.blank(rows, cols)
                savedAlternate = saved
            } else if !on && usingAlternate {
                usingAlternate = false
                restoreCursor()
            }
        case 2004: bracketedPaste = on
        default: break                                               // 3, 5, 12, mouse modes: ignored
        }
    }

    private mutating func reply(_ s: String) { responses.append(contentsOf: Array(s.utf8)) }

    // MARK: - Cursor movement

    private mutating func moveTo(_ r: Int, _ c: Int) {
        cursorRow = min(max(0, r), rows - 1)
        cursorCol = min(max(0, c), cols - 1)
        pendingWrap = false
    }

    /// CUU and CUD stop at the scroll region's edge when they start inside it.
    private mutating func moveUp(_ n: Int) {
        let limit = cursorRow >= scrollTop ? scrollTop : 0
        moveTo(max(limit, cursorRow - n), cursorCol)
    }

    private mutating func moveDown(_ n: Int) {
        let limit = cursorRow <= scrollBottom ? scrollBottom : rows - 1
        moveTo(min(limit, cursorRow + n), cursorCol)
    }

    /// CUP, 1-based; relative to the scroll region in origin mode.
    private mutating func cursorPosition(_ row: Int, _ col: Int, absoluteRow: Bool = false) {
        if originMode && !absoluteRow {
            moveTo(min(scrollTop + row - 1, scrollBottom), col - 1)
        } else {
            moveTo(row - 1, col - 1)
        }
    }

    // MARK: - Erasing and editing

    private func blankLine() -> [Cell] { Array(repeating: blankCell(), count: cols) }
    /// Erased cells take the pen's background, nothing else (terminfo `bce`).
    private func blankCell() -> Cell { var a = CellAttributes(); a.bg = pen.bg; return Cell(" ", a) }

    private mutating func eraseDisplay(_ mode: Int) {
        pendingWrap = false
        let blank = blankCell()
        switch mode {
        case 0:
            eraseLine(0)
            for r in (cursorRow + 1)..<max(cursorRow + 1, rows) { setLine(r, Array(repeating: blank, count: cols)) }
        case 1:
            eraseLine(1)
            for r in 0..<cursorRow { setLine(r, Array(repeating: blank, count: cols)) }
        case 2:
            for r in 0..<rows { setLine(r, Array(repeating: blank, count: cols)) }
        case 3:
            scrollback.removeAll()
        default: break
        }
    }

    private mutating func eraseLine(_ mode: Int) {
        pendingWrap = false
        let blank = blankCell(), c = cursorCol
        modifyCurrentLine { line in
            switch mode {
            case 0: for i in c..<line.count { line[i] = blank }
            case 1: for i in 0...c { line[i] = blank }
            case 2: for i in 0..<line.count { line[i] = blank }
            default: break
            }
        }
    }

    private mutating func eraseCells(_ n: Int) {
        pendingWrap = false
        let blank = blankCell(), c = cursorCol, end = min(cols, cursorCol + n)
        modifyCurrentLine { line in for i in c..<end { line[i] = blank } }
    }

    private mutating func insertCells(_ n: Int) {
        pendingWrap = false
        let blank = blankCell(), c = cursorCol, n = min(n, cols - cursorCol)
        modifyCurrentLine { line in
            line.insert(contentsOf: Array(repeating: blank, count: n), at: c)
            line.removeLast(n)
        }
    }

    private mutating func deleteCells(_ n: Int) {
        pendingWrap = false
        let blank = blankCell(), c = cursorCol, n = min(n, cols - cursorCol)
        modifyCurrentLine { line in
            line.removeSubrange(c..<(c + n))
            line.append(contentsOf: Array(repeating: blank, count: n))
        }
    }

    /// IL and DL work from the cursor's line to the region's bottom, and only
    /// inside the region.
    private mutating func insertLines(_ n: Int) {
        guard cursorRow >= scrollTop && cursorRow <= scrollBottom else { return }
        let top = scrollTop
        scrollTop = cursorRow
        scrollDown(n)
        scrollTop = top
        cursorCol = 0
    }

    private mutating func deleteLines(_ n: Int) {
        guard cursorRow >= scrollTop && cursorRow <= scrollBottom else { return }
        let top = scrollTop
        scrollTop = cursorRow
        scrollUp(n, history: false)
        scrollTop = top
        cursorCol = 0
    }

    // MARK: - SGR

    private mutating func sgr(_ p: [Int]) {
        let p = p.isEmpty ? [0] : p
        var i = 0
        while i < p.count {
            let v = p[i]
            switch v {
            case 0: pen = CellAttributes()
            case 1: pen.bold = true
            case 2: pen.dim = true
            case 3: pen.italic = true
            case 4: pen.underline = true
            case 5, 6: pen.blink = true
            case 7: pen.inverse = true
            case 8: pen.invisible = true
            case 9: pen.strike = true
            case 21, 22: pen.bold = false; pen.dim = false
            case 23: pen.italic = false
            case 24: pen.underline = false
            case 25: pen.blink = false
            case 27: pen.inverse = false
            case 28: pen.invisible = false
            case 29: pen.strike = false
            case 30...37: pen.fg = .indexed(UInt8(v - 30))
            case 39: pen.fg = .default
            case 40...47: pen.bg = .indexed(UInt8(v - 40))
            case 49: pen.bg = .default
            case 90...97: pen.fg = .indexed(UInt8(v - 90 + 8))
            case 100...107: pen.bg = .indexed(UInt8(v - 100 + 8))
            case 38, 48:
                // 38;5;n and 38;2;r;g;b (and the same after 48).
                var color: TermColor? = nil
                if i + 2 < p.count, p[i + 1] == 5 {
                    color = .indexed(UInt8(clamping: p[i + 2])); i += 2
                } else if i + 4 < p.count, p[i + 1] == 2 {
                    color = .rgb(UInt8(clamping: p[i + 2]), UInt8(clamping: p[i + 3]), UInt8(clamping: p[i + 4])); i += 4
                } else {
                    i = p.count                                      // malformed: the rest is not trustworthy
                }
                if let color { if v == 38 { pen.fg = color } else { pen.bg = color } }
            default: break
            }
            i += 1
        }
    }

    // MARK: - Storage

    private static func blank(_ r: Int, _ c: Int) -> [[Cell]] {
        Array(repeating: Array(repeating: Cell(), count: c), count: r)
    }

    private mutating func resetTabs() {
        tabStops = Set(stride(from: 8, to: cols, by: 8))
    }

    private mutating func modifyGrid(_ f: (inout [[Cell]]) -> Void) {
        if usingAlternate { f(&alternate) } else { f(&main) }
    }

    private mutating func modifyCurrentLine(_ f: (inout [Cell]) -> Void) {
        let r = cursorRow
        modifyGrid { g in f(&g[r]) }
    }

    private mutating func setCell(_ r: Int, _ c: Int, _ cell: Cell) {
        modifyGrid { g in g[r][c] = cell }
    }

    private mutating func setLine(_ r: Int, _ line: [Cell]) {
        modifyGrid { g in g[r] = line }
    }

    /// DEC special graphics: what `ESC ( 0` makes of `a`–`~` — the line-drawing
    /// set `mc`, `tmux` and ncurses' ACS use.
    static let decGraphics: [Unicode.Scalar: Unicode.Scalar] = [
        "`": "◆", "a": "▒", "b": "␉", "c": "␌", "d": "␍", "e": "␊", "f": "°", "g": "±",
        "h": "␤", "i": "␋", "j": "┘", "k": "┐", "l": "┌", "m": "└", "n": "┼", "o": "⎺",
        "p": "⎻", "q": "─", "r": "⎼", "s": "⎽", "t": "├", "u": "┤", "v": "┴", "w": "┬",
        "x": "│", "y": "≤", "z": "≥", "{": "π", "|": "≠", "}": "£", "~": "·",
    ]
}
