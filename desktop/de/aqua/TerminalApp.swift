// Terminal — a shell in a window (PHASE15 P15.4b).
//
// Each window is a `Pty` running the person's shell and a `Screen` that its
// output drives (P15.4a); this draws the screen in the theme's `mono` role,
// turns keys into bytes (`KeyEncoder`), blinks a caret, and gives the shell a
// new size when the window gets one. The window's own chrome is drawn here, as
// every Aqua application's is. When the shell exits, its window closes — Mac
// Terminal's "close if the shell exited cleanly", without the question.
//
// **What the tests read** (ABYSS_TERMINAL_DUMP=1): each row as it changes,
// `Terminal: row N |text|`, and the size the shell was given. The model is
// asserted on by `live-vt.sh` with no window; this is how the window's copy of
// it is.

import Surface
import CCairo
import AquaDraw
import MenuModel
import MenuWire
import CWayland
import Terminal
import Pty

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

// MARK: - The vocabulary

public enum TerminalVerb {
    public static let about = "app.about"
    public static let quit = "app.quit"
    public static let newWindow = "shell.new-window"
    public static let close = "window.close"
    public static let minimize = "window.minimize"
}

public func terminalMenuBar() -> MenuBarModel {
    func c(_ verb: String, _ title: String, _ key: KeyEquivalent? = nil, _ summary: String) -> MenuItem {
        .command(Command(verb, title, key: key, summary: summary))
    }
    return MenuBarModel(appName: "Terminal", menus: [
        Menu("Terminal", [
            c(TerminalVerb.about, "About Terminal", nil, "Show Terminal's version."),
            .separator,
            c(TerminalVerb.quit, "Quit Terminal", .cmd("q"), "Close every Terminal window."),
        ]),
        Menu("Shell", [
            c(TerminalVerb.newWindow, "New Window", .cmd("n"), "Open another window with a new shell."),
            .separator,
            c(TerminalVerb.close, "Close Window", .cmd("w"), "Close this window and its shell."),
        ]),
        Menu("Window", [
            c(TerminalVerb.minimize, "Minimize", .cmd("m"), "Put the window in the Dock."),
        ]),
    ])
}

// MARK: - Look

/// How big the grid's text is, and the colours a program's SGR means. The
/// default pen is Jaguar Terminal's: black on white.
public enum TerminalStyle {
    public static let fontSize = 12.0
    public static let padding = 4.0
    public static let foreground = Color(hex: 0x000000)
    public static let background = Color(hex: 0xFFFFFF)
    public static let caret = Color(hex: 0x3875D7)

    /// xterm's sixteen, then its 6×6×6 cube and 24 greys.
    public static func color(_ c: TermColor, default d: Color) -> Color {
        switch c {
        case .default: return d
        case .rgb(let r, let g, let b): return Color(Double(r) / 255, Double(g) / 255, Double(b) / 255)
        case .indexed(let i):
            let basic: [UInt32] = [0x000000, 0xCD0000, 0x00CD00, 0xCDCD00, 0x0000EE, 0xCD00CD, 0x00CDCD, 0xE5E5E5,
                                   0x7F7F7F, 0xFF0000, 0x00FF00, 0xFFFF00, 0x5C5CFF, 0xFF00FF, 0x00FFFF, 0xFFFFFF]
            if i < 16 { return Color(hex: basic[Int(i)]) }
            if i < 232 {
                let n = Int(i) - 16
                func level(_ v: Int) -> Double { v == 0 ? 0 : Double(55 + v * 40) / 255 }
                return Color(level(n / 36), level((n / 6) % 6), level(n % 6))
            }
            let g = Double(8 + (Int(i) - 232) * 10) / 255
            return Color(g, g, g)
        }
    }
}

/// One character cell's size in the `mono` role, in logical pixels.
public func terminalCellSize() -> (w: Double, h: Double) {
    guard Text.available else { return (7, 15) }
    let px = Text.px(TerminalStyle.fontSize)
    let scale = Double(Text.renderScale)
    let w = Text.width(Text.shape("M", px: px, style: .regular, role: .mono)) / scale
    let m = Text.metrics(px: px, role: .mono)
    return (max(1, w), max(1, ((m.ascent + m.descent) / scale).rounded(.up) + 1))
}

/// The grid's area inside a window of `w` × `h`: under the title bar, above
/// the resize band.
public func terminalGridRect(w: Double, h: Double) -> Rect {
    let top = Theme.titleBarHeight + TerminalStyle.padding
    let p = TerminalStyle.padding
    return Rect(p, top, max(0, w - 2 * p), max(0, h - top - max(p, windowResizeBand)))
}

/// Paint a screen: chrome, cells, caret. Pure but for cairo, so the golden
/// scene can draw one from a fed `Screen`.
public func paintTerminal(_ cr: OpaquePointer, w: Double, h: Double, title: String,
                          screen: Screen, caretOn: Bool, focused: Bool) {
    paintWindowChrome(cr, w: w, h: h, title: title)
    let grid = terminalGridRect(w: w, h: h)
    Draw.setColor(cr, TerminalStyle.background)
    cairo_rectangle(cr, 0, Theme.titleBarHeight, w, h - Theme.titleBarHeight)
    cairo_fill(cr)

    let (cw, ch) = terminalCellSize()
    let ascent: Double = {
        guard Text.available else { return 11 }
        return Text.metrics(px: Text.px(TerminalStyle.fontSize), role: .mono).ascent / Double(Text.renderScale)
    }()
    func colors(_ a: CellAttributes) -> (fg: Color, bg: Color) {
        var fg = TerminalStyle.color(a.fg, default: TerminalStyle.foreground)
        var bg = TerminalStyle.color(a.bg, default: TerminalStyle.background)
        if a.bold, case .indexed(let i) = a.fg, i < 8 { fg = TerminalStyle.color(.indexed(i + 8), default: fg) }
        if a.inverse { swap(&fg, &bg) }
        if a.dim { fg = fg.with(a: 0.6) }
        return (fg, bg)
    }
    let rows = min(screen.rows, Int(grid.h / ch)), cols = min(screen.cols, Int(grid.w / cw))
    for r in 0..<rows {
        let line = screen.grid[r]
        let y = grid.y + Double(r) * ch
        var c = 0
        while c < cols {
            // A run: the cells from here with the same attributes.
            let attrs = line[c].attrs
            var end = c + 1
            while end < cols && line[end].attrs == attrs { end += 1 }
            let (fg, bg) = colors(attrs)
            let x = grid.x + Double(c) * cw
            if bg != TerminalStyle.background {
                Draw.setColor(cr, bg)
                cairo_rectangle(cr, x, y, Double(end - c) * cw, ch)
                cairo_fill(cr)
            }
            if !attrs.invisible {
                // Cell by cell, so a glyph the font draws wider or narrower
                // than the cell never moves the rest of the line.
                let style: Text.Style = attrs.bold ? (attrs.italic ? .boldItalic : .bold) : (attrs.italic ? .italic : .regular)
                for i in c..<end where line[i].scalar != " " {
                    if drawBoxCharacter(cr, line[i].scalar, x: grid.x + Double(i) * cw, y: y,
                                        w: cw, h: ch, color: fg) { continue }
                    Draw.textLeft(cr, String(Character(line[i].scalar)), x: grid.x + Double(i) * cw,
                                  baselineY: y + ascent, color: fg, size: TerminalStyle.fontSize,
                                  style: style, role: .mono)
                }
                if attrs.underline || attrs.strike {
                    Draw.setColor(cr, fg)
                    cairo_set_line_width(cr, 1)
                    let ly = attrs.underline ? y + ascent + 1.5 : y + ch / 2
                    cairo_move_to(cr, x, ly); cairo_line_to(cr, x + Double(end - c) * cw, ly)
                    cairo_stroke(cr)
                }
            }
            c = end
        }
    }

    // The caret: a block when the window has focus and the blink is on, an
    // outline when it does not — where the next character goes.
    if screen.cursorVisible, screen.cursorRow < rows, screen.cursorCol < cols {
        let x = grid.x + Double(screen.cursorCol) * cw, y = grid.y + Double(screen.cursorRow) * ch
        if focused {
            if caretOn {
                Draw.setColor(cr, TerminalStyle.caret)
                cairo_rectangle(cr, x, y, cw, ch); cairo_fill(cr)
                let cell = screen.cell(screen.cursorRow, screen.cursorCol)
                if cell.scalar != " " {
                    Draw.textLeft(cr, String(Character(cell.scalar)), x: x, baselineY: y + ascent,
                                  color: TerminalStyle.background, size: TerminalStyle.fontSize, role: .mono)
                }
            }
        } else {
            Draw.setColor(cr, TerminalStyle.caret)
            cairo_set_line_width(cr, 1)
            cairo_rectangle(cr, x + 0.5, y + 0.5, cw - 1, ch - 1); cairo_stroke(cr)
        }
    }
}

/// The light box-drawing characters, drawn edge to edge rather than from the
/// font — a glyph is shorter than a cell, and a box of them has gaps between
/// its rows (xterm draws these itself for the same reason). Each is which of
/// its four arms it has: up, down, left, right.
private let boxArms: [Unicode.Scalar: (Bool, Bool, Bool, Bool)] = [
    "─": (false, false, true, true), "│": (true, true, false, false),
    "┌": (false, true, false, true), "┐": (false, true, true, false),
    "└": (true, false, false, true), "┘": (true, false, true, false),
    "├": (true, true, false, true), "┤": (true, true, true, false),
    "┬": (false, true, true, true), "┴": (true, false, true, true),
    "┼": (true, true, true, true),
]

private func drawBoxCharacter(_ cr: OpaquePointer, _ s: Unicode.Scalar, x: Double, y: Double,
                              w: Double, h: Double, color: Color) -> Bool {
    guard let (up, down, left, right) = boxArms[s] else { return false }
    // The centre on a pixel boundary plus half, so a 1-px line is crisp.
    let cx = (x + w / 2).rounded(.down) + 0.5, cy = (y + h / 2).rounded(.down) + 0.5
    Draw.setColor(cr, color)
    cairo_set_line_width(cr, 1)
    cairo_set_line_cap(cr, CAIRO_LINE_CAP_SQUARE)
    if up { cairo_move_to(cr, cx, y); cairo_line_to(cr, cx, cy) }
    if down { cairo_move_to(cr, cx, cy); cairo_line_to(cr, cx, y + h) }
    if left { cairo_move_to(cr, x, cy); cairo_line_to(cr, cx, cy) }
    if right { cairo_move_to(cr, cx, cy); cairo_line_to(cr, x + w, cy) }
    cairo_stroke(cr)
    return true
}

// MARK: - A window

final class TerminalWindow: WindowDelegate {
    private(set) var window: Window?
    private let display: Display
    private weak var app: TerminalApp?
    let pty: Pty
    private(set) var screen: Screen
    private var caretOn = true
    private var pointerX = 0.0, pointerY = 0.0
    private let program: String
    private var dumped: [String] = []
    private let dump = getenv("ABYSS_TERMINAL_DUMP") != nil
    private var currentTitle = ""
    /// The window size last said (`size`, and `chrome` with ABYSS_TERMINAL_DUMP).
    private var announced: (Int, Int) = (0, 0)

    init?(display: Display, app: TerminalApp, command: [String]) {
        self.display = display
        self.app = app
        let rows = 24, cols = 80
        let home = getenv("HOME").map { String(cString: $0) }
        guard let p = Pty(command, rows: rows, cols: cols, environment: ["TERM_PROGRAM": "AbyssBSD Terminal"],
                          directory: home) else { return nil }
        pty = p
        screen = Screen(rows: rows, cols: cols)
        program = String(command[0].split(separator: "/").last ?? Substring(command[0]))
        let (cw, ch) = terminalCellSize()
        let bottom = max(TerminalStyle.padding, windowResizeBand)
        let width = Int32((Double(cols) * cw + 2 * TerminalStyle.padding).rounded(.up))
        let height = Int32((Theme.titleBarHeight + TerminalStyle.padding + Double(rows) * ch + bottom).rounded(.up))
        let scale: Int32, auto: Bool
        if let s = getenv("AQUA_SCALE"), let v = Int32(String(cString: s)), v > 0 { (scale, auto) = (v, false) }
        else { (scale, auto) = (1, true) }
        guard let win = Window(display: display, title: "", appID: "org.abyssbsd.terminal",
                               width: width, height: height, scale: scale, autoScale: auto, delegate: self) else {
            return nil
        }
        window = win
        updateTitle()
        display.addFileDescriptor(pty.fd) { [weak self] in self?.ptyReadable() }
        TerminalApp.log("window: \(command.joined(separator: " ")) (pid \(pty.pid)) \(cols)x\(rows), "
                        + "cell \(twoPlaces(cw))x\(twoPlaces(ch))")
    }

    private func updateTitle() {
        let t = "\(screen.title.isEmpty ? program : screen.title) — \(screen.cols)×\(screen.rows)"
        guard t != currentTitle else { return }
        currentTitle = t
        window?.setTitle(t)
    }

    // MARK: the shell

    private func ptyReadable() {
        guard let bytes = pty.read() else { shellExited(); return }
        guard !bytes.isEmpty else { return }
        screen.feed(bytes)
        if !screen.responses.isEmpty { pty.write(screen.responses); screen.responses = [] }
        caretOn = true
        updateTitle()
        if dump { dumpRows() }
        window?.setNeedsDisplay()
    }

    private func shellExited() {
        display.removeFileDescriptor(pty.fd)
        let status = pty.reap()
        TerminalApp.log("the shell exited" + (status.map { " (status \($0))" } ?? ""))
        close()
    }

    func close() {
        display.removeFileDescriptor(pty.fd)
        window?.close()
        window = nil
        app?.windowClosed(self)
    }

    private func dumpRows() {
        let now = screen.lines
        for (i, line) in now.enumerated() where i >= dumped.count || dumped[i] != line {
            TerminalApp.log("row \(i + 1) |\(line)|")
        }
        dumped = now
    }

    func blink() {
        guard screen.cursorVisible, window?.isActivated ?? false else { return }
        caretOn.toggle()
        window?.setNeedsDisplay()
    }

    // MARK: WindowDelegate

    func render(_ buffer: PixelBuffer) {
        Text.renderScale = buffer.scale
        let w = Double(buffer.width / buffer.scale), h = Double(buffer.height / buffer.scale)
        // The window's size is the shell's: rows and columns that fit.
        let (cw, ch) = terminalCellSize()
        let g = terminalGridRect(w: w, h: h)
        let cols = max(2, Int(g.w / cw)), rows = max(1, Int(g.h / ch))
        if rows != screen.rows || cols != screen.cols {
            screen.resize(rows: rows, cols: cols)
            pty.resize(rows: rows, cols: cols)
            updateTitle()
            if dump { dumpRows() }
        }
        if announced != (Int(w), Int(h)) {
            announced = (Int(w), Int(h))
            TerminalApp.log("size \(cols)x\(rows)")
            if dump {
                // Where the frame's buttons were drawn, for a test to press
                // rather than coordinates copied into a script (§2.46).
                let gadgets = windowChrome(w: w, h: h).gadgets.map {
                    "\($0.gadget)=\(Int($0.rect.x + $0.rect.w / 2)),\(Int($0.rect.y + $0.rect.h / 2))"
                }
                TerminalApp.log("chrome \(Int(w))x\(Int(h)) " + gadgets.joined(separator: " ")
                                + " grid=\(twoPlaces(g.x)),\(twoPlaces(g.y)) cell=\(twoPlaces(cw))x\(twoPlaces(ch))")
            }
        }
        let cs = cairo_image_surface_create_for_data(buffer.data.assumingMemoryBound(to: UInt8.self),
                                                     CAIRO_FORMAT_ARGB32, buffer.width, buffer.height, buffer.stride)
        guard let cr = cairo_create(cs) else { cairo_surface_destroy(cs); return }
        cairo_scale(cr, Double(buffer.scale), Double(buffer.scale))
        cairo_save(cr); cairo_set_operator(cr, CAIRO_OPERATOR_CLEAR); cairo_paint(cr); cairo_restore(cr)
        cairo_set_operator(cr, CAIRO_OPERATOR_OVER)
        paintTerminal(cr, w: w, h: h, title: currentTitle, screen: screen,
                      caretOn: caretOn, focused: window?.isActivated ?? true)
        cairo_surface_flush(cs); cairo_destroy(cr); cairo_surface_destroy(cs)
    }

    func pointerMoved(x: Double, y: Double) { pointerX = x; pointerY = y }

    func pointerButton(_ button: UInt32, pressed: Bool) {
        guard pressed, let w = window else { return }
        let size = w.size
        switch windowChromeHit(x: pointerX, y: pointerY, w: Double(size.width), h: Double(size.height)) {
        case .close: close()
        case .minimize: _ = w.minimize()
        case .zoom: w.setMaximized(!w.isMaximized)
        case .depth: _ = w.lower()
        case .title: w.beginMove()
        case .resize(let e): w.beginResize(e)
        case .pill, .content: break
        }
    }

    func keyEvent(_ event: KeyEvent) {
        guard event.pressed else { return }
        if event.modifiers.contains(.command) {
            if let press = keyEquivalent(event), let verb = TerminalApp.menuBar.verb(for: press) {
                _ = app?.perform(verb, in: self)
            }
            return
        }
        var mods: KeyEncoder.Modifiers = []
        if event.modifiers.contains(.shift) { mods.insert(.shift) }
        if event.modifiers.contains(.alt) { mods.insert(.option) }
        if event.modifiers.contains(.control) { mods.insert(.control) }
        let bytes = KeyEncoder.encode(keysym: event.keysym, text: event.text, mods: mods,
                                      appCursor: screen.applicationCursorKeys)
        if dump {
            TerminalApp.log("key 0x\(String(event.keysym, radix: 16)) text=\(Array(event.text.utf8)) "
                            + "mods=\(event.modifiers.rawValue) -> \(bytes)")
        }
        guard !bytes.isEmpty else { return }
        pty.write(bytes)
        caretOn = true
        window?.setNeedsDisplay()
    }

    func windowShouldClose(_ window: Window) { close() }
    func windowStateChanged(_ window: Window) { caretOn = true; window.setNeedsDisplay() }
}

// MARK: - The application

public final class TerminalApp: MenuProvider {
    private let display: Display
    private var windows: [TerminalWindow] = []
    private var menuService: MenuService?
    private var menuName = ""
    private var blinkTimer: Int32 = -1
    private let command: [String]
    public var onQuit: () -> Void = { exit(0) }

    public static let menuBar = terminalMenuBar()

    /// The person's shell (`$SHELL`, else /bin/sh), or `command` when given —
    /// a bundle whose program needs a terminal (`Terminal=true`) runs in one.
    public init(display: Display, command: [String]? = nil) {
        self.display = display
        let shell = getenv("SHELL").map { String(cString: $0) }.flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/sh"
        self.command = command.flatMap { $0.isEmpty ? nil : $0 } ?? [shell]
        menuName = MenuWire.serviceName(app: "Terminal", pid: getpid())
        if let service = try? MenuService(name: menuName, provider: self) {
            display.addFileDescriptor(service.fd) { [weak service] in service?.serviceReadable() }
            menuService = service
        }
        blinkTimer = aw_create_interval_timer(500)
        if blinkTimer >= 0 {
            display.addFileDescriptor(blinkTimer) { [weak self] in self?.tick() }
        }
    }

    static func log(_ s: String) {
        ("Terminal: " + s + "\n").withCString { _ = write(2, $0, strlen($0)) }
    }

    /// Open a window with a new shell; false if neither could be started.
    @discardableResult
    public func openWindow() -> Bool {
        guard let w = TerminalWindow(display: display, app: self, command: command) else {
            TerminalApp.log("could not start \(command.joined(separator: " ")) on a new terminal")
            return false
        }
        windows.append(w)
        if let win = w.window {
            display.window = win
            if !menuName.isEmpty, win.publishMenus(at: menuName) { TerminalApp.log("menus on \(menuName)") }
        }
        return true
    }

    func windowClosed(_ w: TerminalWindow) {
        windows.removeAll { $0 === w }
        if windows.isEmpty { TerminalApp.log("the last window closed"); onQuit() }
        else if let last = windows.last?.window { display.window = last }
    }

    private func tick() {
        var n: UInt64 = 0
        _ = withUnsafeMutablePointer(to: &n) { read(blinkTimer, $0, MemoryLayout<UInt64>.size) }
        for w in windows { w.blink() }
    }

    func perform(_ verb: String, in w: TerminalWindow?) -> CommandResult {
        switch verb {
        case TerminalVerb.quit: onQuit(); return .ok("")
        case TerminalVerb.newWindow: return openWindow() ? .ok("") : .refused("no new shell could be started")
        case TerminalVerb.close:
            guard let w = w ?? windows.last else { return .refused("no window") }
            w.close(); return .ok("")
        case TerminalVerb.minimize:
            guard let win = (w ?? windows.last)?.window else { return .refused("no window") }
            _ = win.minimize(); return .ok("")
        default: return .refused("Terminal has no verb \(verb)")
        }
    }

    // MARK: MenuProvider

    public var menuModel: MenuBarModel { TerminalApp.menuBar }

    public func menuValidate(_ command: Command) -> Enablement {
        switch command.verb {
        case TerminalVerb.about: return .disabled("Terminal has no About box yet")
        case TerminalVerb.quit, TerminalVerb.newWindow: return .enabled
        case TerminalVerb.close, TerminalVerb.minimize: return windows.isEmpty ? .disabled("no window") : .enabled
        default: return .disabled("Terminal has no verb \(command.verb)")
        }
    }

    public func menuPerform(_ command: Command, arguments: [String: String]) -> CommandResult {
        if case .disabled(let why) = menuValidate(command) { return .refused(why) }
        let front = windows.first { $0.window?.isActivated ?? false }
        return perform(command.verb, in: front)
    }
}
