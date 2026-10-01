// TextView — the toolkit's multi-line text (PHASE15 P15.5).
//
// A `TextModel` (P15.5's pure model) on screen: wrapped by `TextLayout` to the
// view's width, scrolled, drawn, and driven by keys and the pointer. A toolkit
// piece, not TextEdit's — any later editor holds one of these — so it knows
// nothing about files, menus or windows: an owner gives it a rect, forwards
// events, and is told when the text or the selection changed.
//
// **Fixed pitch, for now** (the theme's `mono` role): every Character is one
// cell wide and a tab four, so caret, click and selection positions are exact
// with no per-glyph measurement. Proportional text needs only a different
// `advance` for the layout and per-run drawing; nothing else here changes.

import AquaDraw
import CCairo
import Surface
import TextModel

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

public enum TextViewStyle {
    public static let fontSize = 12.0
    public static let tabCells = 4.0
    public static let inset = 6.0
    public static let background = Color(hex: 0xFFFFFF)
    public static let text = Color(hex: 0x000000)
    public static let selection = Color(hex: 0xB5D5FF)
    public static let caret = Color(hex: 0x000000)
}

public final class TextView {
    public private(set) var model: TextModel
    /// Where the view is in its owner, in the owner's coordinates.
    public var frame = Rect(0, 0, 0, 0) {
        didSet {
            guard frame.w != oldValue.w || frame.h != oldValue.h else { return }
            // A new size: new rows, and the caret kept in sight in them (an
            // edit made before the view had a size scrolled for a 1-px row).
            layout = nil
            if frame.w > 1 && frame.h > 1 { scrollToCaret() }
        }
    }
    /// How far down the text the view is scrolled, in points.
    public private(set) var scrollY = 0.0
    public var caretOn = true
    /// The text changed (`true`) or only the selection moved (`false`).
    public var onChange: (_ textChanged: Bool) -> Void = { _ in }

    private var layout: TextLayout?
    private var dragging = false
    private var lastPress: (at: UInt64, pos: TextPosition, count: Int)?

    public init(_ text: String = "") { model = TextModel(text) }

    // MARK: - Metrics

    /// One cell of the `mono` role at the view's size: its width, and a row's height.
    public static func cell() -> (w: Double, h: Double) {
        guard Text.available else { return (7, 15) }
        let px = Text.px(TextViewStyle.fontSize), scale = Double(Text.renderScale)
        let w = Text.width(Text.shape("M", px: px, style: .regular, role: .mono)) / scale
        let m = Text.metrics(px: px, role: .mono)
        return (max(1, w), max(1, ((m.ascent + m.descent) / scale).rounded(.up) + 2))
    }

    private var textRect: Rect {
        let i = TextViewStyle.inset
        return Rect(frame.x + i, frame.y + i / 2, max(1, frame.w - 2 * i), max(1, frame.h - i))
    }

    /// The wrapped rows, rebuilt when the text or the width changes.
    public func currentLayout() -> TextLayout {
        if let l = layout { return l }
        let cw = TextView.cell().w
        let l = TextLayout(model.lines, width: textRect.w, advance: { $0 == "\t" ? cw * TextViewStyle.tabCells : cw })
        layout = l
        return l
    }

    private var rowHeight: Double { TextView.cell().h }

    // MARK: - Changing it

    /// Replace the whole text (a document just opened); the history starts here.
    public func setText(_ s: String) {
        model = TextModel(s)
        model.markSaved()
        layout = nil; scrollY = 0
        onChange(true)
    }

    /// Do something to the model (an edit, a selection, Undo) and keep the
    /// view in step: the layout, the caret in sight, the owner told.
    public func edit(_ f: (inout TextModel) -> Void) {
        let before = model.text
        f(&model)
        let changed = model.text != before
        if changed { layout = nil }
        caretOn = true
        scrollToCaret()
        onChange(changed)
    }

    public func scrollToCaret() {
        let l = currentLayout()
        let y = Double(l.row(of: model.caret)) * rowHeight
        let h = textRect.h
        if y < scrollY { scrollY = y }
        else if y + rowHeight > scrollY + h { scrollY = y + rowHeight - h }
        clampScroll()
    }

    public func scroll(by dy: Double) {
        scrollY += dy
        clampScroll()
    }

    private func clampScroll() {
        let content = Double(currentLayout().rows.count) * rowHeight
        scrollY = min(max(0, scrollY), max(0, content - textRect.h))
    }

    // MARK: - Drawing

    public func paint(_ cr: OpaquePointer, focused: Bool) {
        Draw.setColor(cr, TextViewStyle.background)
        cairo_rectangle(cr, frame.x, frame.y, frame.w, frame.h)
        cairo_fill(cr)
        cairo_save(cr)
        cairo_rectangle(cr, frame.x, frame.y, frame.w, frame.h)
        cairo_clip(cr)
        let l = currentLayout(), r = textRect, rh = rowHeight
        let ascent = Text.available
            ? Text.metrics(px: Text.px(TextViewStyle.fontSize), role: .mono).ascent / Double(Text.renderScale) : 11
        let first = max(0, Int(scrollY / rh)), last = min(l.rows.count - 1, Int((scrollY + r.h) / rh) + 1)
        let sel = model.selection
        if first <= last {
            for i in first...last {
                let row = l.rows[i], line = model.lines[row.line]
                let y = r.y + Double(i) * rh - scrollY
                // The selection's part of this row (and, past its end, the
                // newline it includes, as a Mac draws it).
                if !sel.isEmpty {
                    let a = TextPosition(line: row.line, column: row.start), b = TextPosition(line: row.line, column: row.end)
                    let s = max(sel.start, a), e = min(sel.end, b)
                    let newline = sel.end > b && row.end == line.count
                    if s < e || (newline && sel.start <= b) {
                        // x within *this* row: a position at a wrap belongs to
                        // the next row in the layout, but ends this one here.
                        let x0 = xIn(row, line, s < e ? s.column : row.end)
                        let x1 = newline ? r.w : xIn(row, line, e.column)
                        Draw.setColor(cr, TextViewStyle.selection)
                        cairo_rectangle(cr, r.x + x0, y, max(0, x1 - x0), rh)
                        cairo_fill(cr)
                    }
                }
                guard row.end > row.start else { continue }
                var s = String(line[row.start..<row.end])
                if s.contains("\t") { s = s.replacingTabs(with: Int(TextViewStyle.tabCells)) }
                Draw.textLeft(cr, s, x: r.x, baselineY: y + ascent + 1, color: TextViewStyle.text,
                              size: TextViewStyle.fontSize, role: .mono)
            }
        }
        // The caret: a thin bar, where the next character goes.
        if focused && caretOn && sel.isEmpty {
            let i = l.row(of: model.caret)
            let x = (r.x + l.x(of: model.caret)).rounded(.down) + 0.5
            let y = r.y + Double(i) * rh - scrollY
            Draw.setColor(cr, TextViewStyle.caret)
            cairo_set_line_width(cr, 1)
            cairo_move_to(cr, x, y + 1); cairo_line_to(cr, x, y + rh - 1)
            cairo_stroke(cr)
        }
        cairo_restore(cr)
    }

    /// The x of column `col` measured from the start of `row`.
    private func xIn(_ row: VisualRow, _ line: [Character], _ col: Int) -> Double {
        let cw = TextView.cell().w
        var x = 0.0
        for c in row.start..<min(max(row.start, col), row.end) { x += line[c] == "\t" ? cw * TextViewStyle.tabCells : cw }
        return x
    }

    // MARK: - Keys

    /// Handle a key; false if it is not the view's (a Command chord the
    /// application's menus own).
    @discardableResult
    public func key(_ e: KeyEvent) -> Bool {
        guard e.pressed else { return false }
        let shift = e.modifiers.contains(.shift), cmd = e.modifiers.contains(.command)
        let opt = e.modifiers.contains(.alt)
        let l = currentLayout()
        func vertical(_ delta: Int) {
            edit { m in
                let goal = m.goalX ?? l.x(of: m.caret)
                if let p = l.vertical(from: m.caret, by: delta, goalX: goal) {
                    m.setCaret(p, extend: shift, keepGoal: true)
                } else {
                    m.setCaret(delta < 0 ? .start : m.end, extend: shift, keepGoal: true)
                }
                m.goalX = goal
            }
        }
        switch e.keysym {
        case KeySym.left, KeySym.right:
            let left = e.keysym == KeySym.left
            if cmd {
                // The visual row's ends, as a Mac's Command-arrow.
                let row = l.rows[l.row(of: model.caret)]
                let p = TextPosition(line: row.line, column: left ? row.start : (row.end < model.lines[row.line].count ? max(row.start, row.end - 1) : row.end))
                edit { $0.setCaret(p, extend: shift) }
            } else {
                edit { $0.move(opt ? (left ? .wordLeft : .wordRight) : (left ? .left : .right), extend: shift) }
            }
        case KeySym.up: cmd ? edit { $0.move(.documentStart, extend: shift) } : vertical(-1)
        case KeySym.down: cmd ? edit { $0.move(.documentEnd, extend: shift) } : vertical(1)
        case KeySym.home: edit { $0.move(.documentStart, extend: shift) }
        case KeySym.end: edit { $0.move(.documentEnd, extend: shift) }
        case KeySym.pageUp: vertical(-max(1, Int(textRect.h / rowHeight) - 1))
        case KeySym.pageDown: vertical(max(1, Int(textRect.h / rowHeight) - 1))
        case KeySym.backspace: edit { $0.deleteBackward(word: opt) }
        case KeySym.delete: edit { $0.deleteForward(word: opt) }
        case KeySym.enter: edit { $0.insert("\n") }
        case KeySym.tab: edit { $0.insert("\t") }
        default:
            guard !cmd, !e.modifiers.contains(.control), !e.text.isEmpty,
                  e.text.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7F }) else { return false }
            edit { $0.insert(e.text) }
        }
        return true
    }

    // MARK: - The pointer

    public func contains(_ x: Double, _ y: Double) -> Bool { frame.contains(x, y) }

    private func position(_ x: Double, _ y: Double) -> TextPosition {
        let r = textRect
        let row = Int((y - r.y + scrollY) / rowHeight)
        return currentLayout().position(row: row, x: x - r.x)
    }

    public func pointerPressed(x: Double, y: Double, shift: Bool) {
        let p = position(x, y)
        var ts = timespec(); clock_gettime(CLOCK_MONOTONIC, &ts)
        let now = UInt64(ts.tv_sec) &* 1000 &+ UInt64(ts.tv_nsec) / 1_000_000
        var count = 1
        if let last = lastPress, now &- last.at < 500, last.pos.line == p.line, abs(last.pos.column - p.column) <= 1 {
            count = last.count % 3 + 1
        }
        lastPress = (now, p, count)
        dragging = true
        edit { m in
            switch count {
            case 2: m.select(m.wordRange(at: p))
            case 3: m.select(m.lineRange(at: p))
            default: m.setCaret(p, extend: shift)
            }
        }
    }

    public func pointerMoved(x: Double, y: Double) {
        guard dragging else { return }
        let p = position(x, y)
        edit { $0.setCaret(p, extend: true) }
    }

    public func pointerReleased() { dragging = false }
}

extension String {
    /// Each tab as `n` spaces — what the fixed-pitch drawing shows for one.
    func replacingTabs(with n: Int) -> String {
        var out = ""
        for c in self { if c == "\t" { out += String(repeating: " ", count: n) } else { out.append(c) } }
        return out
    }
}
