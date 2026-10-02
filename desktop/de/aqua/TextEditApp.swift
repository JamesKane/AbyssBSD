// TextEdit — plain text, opened and saved (PHASE15 P15.5).
//
// A document per window: a `TextView` (the toolkit's multi-line text) under
// Aqua chrome, the file it came from, and a find bar. Files come and go
// through the portal (P7) — Open… and Save As… ask `portal` for a descriptor,
// so a sandboxed TextEdit is possible later — or by path, when the Finder or a
// command line names one. The portal's answer arrives on its socket in the run
// loop, so the window keeps drawing while the person chooses in the Finder.
//
// **Bytes are kept.** A file that is not UTF-8 is refused rather than opened,
// because saving the replacement characters back would destroy it; a save is
// a temporary file and a rename, so a crash mid-write leaves the old file whole.
//
// What a test reads (ABYSS_TEXTEDIT_DUMP=1): where the text and its cells are,
// what was opened, saved and found.

import Surface
import CCairo
import AquaDraw
import MenuModel
import MenuWire
import CurrentIPC
import CWayland
import TextModel

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

// MARK: - The vocabulary

public enum TextEditVerb {
    public static let about = "app.about", quit = "app.quit"
    public static let new = "file.new", open = "file.open", close = "file.close"
    public static let save = "file.save", saveAs = "file.save-as"
    public static let undo = "edit.undo", redo = "edit.redo"
    public static let cut = "edit.cut", copy = "edit.copy", paste = "edit.paste", selectAll = "edit.select-all"
    public static let find = "edit.find", findNext = "edit.find-next", findPrevious = "edit.find-previous"
    public static let minimize = "window.minimize"
}

public func textEditMenuBar() -> MenuBarModel {
    // Save and Save As… write the person's file: an agent's first in a
    // session asks the person first (PHASE18 P18.11, requester 1).
    let writing: Set<String> = [TextEditVerb.save, TextEditVerb.saveAs]
    func c(_ verb: String, _ title: String, _ key: KeyEquivalent? = nil, _ summary: String) -> MenuItem {
        .command(Command(verb, title, key: key, summary: summary, writes: writing.contains(verb)))
    }
    return MenuBarModel(appName: "TextEdit", menus: [
        Menu("TextEdit", [
            c(TextEditVerb.about, "About TextEdit", nil, "Show TextEdit's version."),
            .separator,
            c(TextEditVerb.quit, "Quit TextEdit", .cmd("q"), "Close every document and quit."),
        ]),
        Menu("File", [
            c(TextEditVerb.new, "New", .cmd("n"), "Open an empty document."),
            c(TextEditVerb.open, "Open…", .cmd("o"), "Choose a text file in the Finder."),
            .separator,
            c(TextEditVerb.close, "Close", .cmd("w"), "Close this document."),
            c(TextEditVerb.save, "Save", .cmd("s"), "Save this document."),
            c(TextEditVerb.saveAs, "Save As…", .cmd("s", .shift), "Save this document under another name."),
        ]),
        Menu("Edit", [
            c(TextEditVerb.undo, "Undo", .cmd("z"), "Take back the last change."),
            c(TextEditVerb.redo, "Redo", .cmd("z", .shift), "Put back what was undone."),
            .separator,
            c(TextEditVerb.cut, "Cut", .cmd("x"), "Remove the selection to the clipboard."),
            c(TextEditVerb.copy, "Copy", .cmd("c"), "Copy the selection."),
            c(TextEditVerb.paste, "Paste", .cmd("v"), "Put the clipboard's text in."),
            c(TextEditVerb.selectAll, "Select All", .cmd("a"), "Select the whole document."),
            .separator,
            c(TextEditVerb.find, "Find…", .cmd("f"), "Find text in the document."),
            c(TextEditVerb.findNext, "Find Next", .cmd("g"), "Find the next occurrence."),
            c(TextEditVerb.findPrevious, "Find Previous", .cmd("g", .shift), "Find the one before."),
        ]),
        Menu("Window", [
            c(TextEditVerb.minimize, "Minimize", .cmd("m"), "Put the window in the Dock."),
        ]),
    ])
}

// MARK: - Files

public enum TextFile {
    /// The text in `bytes`, or why it cannot be edited as plain text.
    public static func decode(_ bytes: [UInt8]) -> (text: String?, why: String?) {
        let s = String(decoding: bytes, as: UTF8.self)
        guard Array(s.utf8) == bytes else { return (nil, "it is not UTF-8 text, and saving it would change it") }
        guard !bytes.contains(0) else { return (nil, "it holds NUL bytes — it is not a text file") }
        return (s, nil)
    }

    public static func read(fd: Int32) -> [UInt8] {
        var out: [UInt8] = [], buf = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = buf.withUnsafeMutableBytes { Glibc.read(fd, $0.baseAddress, $0.count) }
            if n > 0 { out.append(contentsOf: buf[0..<n]); continue }
            if n < 0 && errno == EINTR { continue }
            return out
        }
    }

    static func writeAll(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
        var off = 0
        while off < bytes.count {
            let n = bytes[off...].withUnsafeBytes { Glibc.write(fd, $0.baseAddress, $0.count) }
            if n > 0 { off += n; continue }
            if n < 0 && errno == EINTR { continue }
            return false
        }
        return true
    }

    /// Save over `path` through a temporary file beside it and a rename, keeping
    /// the file's mode: a crash mid-write leaves the old file, never half a new one.
    public static func save(_ bytes: [UInt8], to path: String) -> String? {
        let dir = path.split(separator: "/", omittingEmptySubsequences: false).dropLast().joined(separator: "/")
        let name = String(path.split(separator: "/").last ?? "")
        var template = Array(((dir.isEmpty ? "." : dir) + "/." + name + ".XXXXXX").utf8CString)
        let fd = template.withUnsafeMutableBufferPointer { mkstemp($0.baseAddress!) }
        guard fd >= 0 else { return "cannot write in \(dir): \(String(cString: strerror(errno)))" }
        let tmp = template.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        var st = stat()
        let mode: mode_t = stat(path, &st) == 0 ? st.st_mode & 0o7777 : 0o644
        guard writeAll(fd, bytes), fchmod(fd, mode) == 0, fsync(fd) == 0 else {
            close(fd); unlink(tmp); return "could not write \(path): \(String(cString: strerror(errno)))"
        }
        close(fd)
        guard rename(tmp, path) == 0 else { unlink(tmp); return "could not replace \(path): \(String(cString: strerror(errno)))" }
        return nil
    }

    /// Write through a descriptor the portal opened for us (Save As).
    public static func save(_ bytes: [UInt8], fd: Int32) -> String? {
        defer { close(fd) }
        guard writeAll(fd, bytes), ftruncate(fd, off_t(bytes.count)) == 0, fsync(fd) == 0 else {
            return "could not write: \(String(cString: strerror(errno)))"
        }
        return nil
    }
}

/// One question to the portal, answered in the run loop.
final class PortalQuestion {
    static func ask(_ msg: Msg, display: Display, _ done: @escaping (Msg?) -> Void) {
        let service = getenv("ABYSS_PORTAL_SERVICE").map { String(cString: $0) } ?? "portal"
        guard let sock = try? Current.connect(service) else { done(nil); return }
        guard (try? Current.send(msg, on: sock)) != nil else { close(sock); done(nil); return }
        display.addFileDescriptor(sock) {
            display.removeFileDescriptor(sock)
            let reply = try? Current.receive(on: sock)
            close(sock)
            done(reply)
        }
    }
}

// MARK: - Painting

public enum TextEditStyle {
    public static let findBarHeight = 30.0
}

/// The text view's place in a window, under the title bar and the find bar.
public func textEditTextRect(w: Double, h: Double, findBar: Bool) -> Rect {
    let top = Theme.titleBarHeight + (findBar ? TextEditStyle.findBarHeight : 0)
    return Rect(0, top, w, max(0, h - top - windowResizeBand))
}

public func paintTextEdit(_ cr: OpaquePointer, w: Double, h: Double, title: String, view: TextView,
                          findBar: String?, findFocused: Bool, caretOn: Bool) {
    paintWindowChrome(cr, w: w, h: h, title: title)
    if let find = findBar {
        let bar = Rect(0, Theme.titleBarHeight, w, TextEditStyle.findBarHeight)
        Draw.setColor(cr, Color(hex: 0xE8E8E8)); cairo_rectangle(cr, bar.x, bar.y, bar.w, bar.h); cairo_fill(cr)
        Draw.textLeft(cr, "Find:", x: 10, baselineY: bar.y + 19, color: Theme.bodyText, size: Theme.fontSize)
        Draw.textField(cr, Rect(48, bar.y + 4, min(260, w - 60), 22), text: find, caret: findFocused && caretOn)
    }
    view.frame = textEditTextRect(w: w, h: h, findBar: findBar != nil)
    view.caretOn = caretOn
    view.paint(cr, focused: !findFocused)
}

/// "Do you want to save changes?" — the sheet a document shows when it is
/// closed with edits (Jaguar's, from the title bar down): where it and its
/// three buttons are, one layout for paint and hit-test.
public struct SaveSheetLayout: Equatable, Sendable {
    public let panel: Rect, save: Rect, dontSave: Rect, cancel: Rect
    public init(w: Double) {
        let pw = min(420, w - 40), ph = 116.0
        panel = Rect((w - pw) / 2, Theme.titleBarHeight, pw, ph)
        let by = panel.y + ph - 40, bh = 26.0
        save = Rect(panel.x + pw - 96, by, 82, bh)
        cancel = Rect(save.x - 92, by, 82, bh)
        dontSave = Rect(panel.x + 16, by, 104, bh)
    }
}

func paintSaveSheet(_ cr: OpaquePointer, w: Double, name: String) -> SaveSheetLayout {
    let l = SaveSheetLayout(w: w)
    Draw.setColor(cr, Color(0, 0, 0, 0.18))
    cairo_rectangle(cr, l.panel.x + 2, l.panel.y, l.panel.w, l.panel.h + 3); cairo_fill(cr)
    Draw.setColor(cr, Color(hex: 0xECECEC))
    cairo_rectangle(cr, l.panel.x, l.panel.y, l.panel.w, l.panel.h); cairo_fill(cr)
    Draw.textLeft(cr, "Do you want to save changes to \"\(name)\" before closing?",
                  x: l.panel.x + 18, baselineY: l.panel.y + 30, color: Theme.bodyText, size: Theme.fontSize, style: .bold)
    Draw.textLeft(cr, "If you don't save, your changes will be lost.",
                  x: l.panel.x + 18, baselineY: l.panel.y + 50, color: Theme.bodyText, size: Theme.fontSize - 1)
    Draw.gelButton(cr, l.dontSave, label: "Don't Save", blue: false, pressed: false)
    Draw.gelButton(cr, l.cancel, label: "Cancel", blue: false, pressed: false)
    Draw.gelButton(cr, l.save, label: "Save", blue: true, pressed: false)
    return l
}

// MARK: - A document

final class TextEditDocument: WindowDelegate {
    private(set) var window: Window?
    private let display: Display
    private weak var app: TextEditApp?
    let view = TextView()
    private(set) var path: String?
    /// The find bar: its text when shown, and whether keys go to it.
    private(set) var findText: String?
    private var findFocused = false
    private(set) var lastFind = ""
    private var pointerX = 0.0, pointerY = 0.0, shiftHeld = false
    private var announced: (Int, Int) = (0, 0)
    private let dump = getenv("ABYSS_TEXTEDIT_DUMP") != nil
    private var shownTitle = ""
    /// The save sheet is up: the document was asked to close with edits.
    private(set) var asking = false
    private var sheetLogged = false
    /// Close once a save (perhaps through the portal) has gone through.
    var closeAfterSave = false

    init?(display: Display, app: TextEditApp, path: String?, text: String) {
        self.display = display; self.app = app; self.path = path
        let scale: Int32, auto: Bool
        if let s = getenv("AQUA_SCALE"), let v = Int32(String(cString: s)), v > 0 { (scale, auto) = (v, false) }
        else { (scale, auto) = (1, true) }
        guard let win = Window(display: display, title: "", appID: "org.abyssbsd.textedit",
                               width: 560, height: 440, scale: scale, autoScale: auto, delegate: self) else { return nil }
        window = win
        view.setText(text)
        view.onChange = { [weak self] changed in self?.changed(changed) }
        updateTitle()
    }

    var name: String { path.map { String($0.split(separator: "/").last ?? "") } ?? "Untitled" }

    func updateTitle() {
        let t = name + (view.model.isDirty ? " — Edited" : "")
        guard t != shownTitle else { return }
        shownTitle = t
        window?.setTitle(t)
    }

    private func changed(_ textChanged: Bool) {
        updateTitle()
        app?.menusMayHaveChanged()
        window?.setNeedsDisplay()
    }

    func load(path: String, text: String) {
        self.path = path
        view.setText(text)
        updateTitle()
    }

    func blink() {
        guard window?.isActivated ?? false else { return }
        view.caretOn.toggle()
        window?.setNeedsDisplay()
    }

    // MARK: saving

    var bytes: [UInt8] { Array(view.model.text.utf8) }

    /// Save to the file it came from; false when it has none (Save As then).
    func save() -> CommandResult {
        guard let p = path else { return .refused("it has no file yet — Save As") }
        if let why = TextFile.save(bytes, to: p) { TextEditApp.log("could not save \(p): \(why)"); return .refused(why) }
        view.edit { $0.markSaved() }
        updateTitle()
        TextEditApp.log("saved \(p) (\(bytes.count) bytes)")
        return .ok(p)
    }

    func savedThroughPortal(path p: String, fd: Int32) {
        if let why = TextFile.save(bytes, fd: fd) { TextEditApp.log("could not save \(p): \(why)"); return }
        path = p
        view.edit { $0.markSaved() }
        updateTitle()
        TextEditApp.log("saved \(p) (\(bytes.count) bytes)")
        if closeAfterSave { close() }
    }

    // MARK: find

    func showFind() {
        findText = findText ?? lastFind
        findFocused = true
        window?.setNeedsDisplay()
    }

    func find(backward: Bool) -> CommandResult {
        let needle = findText ?? lastFind
        guard !needle.isEmpty else { return .refused("nothing to find") }
        lastFind = needle
        guard let r = view.model.find(needle, backward: backward) else {
            TextEditApp.log("not found: \(needle)")
            return .refused("'\(needle)' is not in the document")
        }
        view.edit { $0.select(r) }
        TextEditApp.log("found \(r.start.line + 1):\(r.start.column + 1)-\(r.end.line + 1):\(r.end.column + 1)")
        return .ok("")
    }

    private func closeFind() {
        findText = nil; findFocused = false
        window?.setNeedsDisplay()
    }

    /// Closed with edits: ask first.
    func askToClose() {
        asking = true
        TextEditApp.log("asked to save changes to \(name)")
        window?.setNeedsDisplay()
    }

    enum Answer { case save, dontSave, cancel }

    func answer(_ a: Answer) {
        asking = false
        window?.setNeedsDisplay()
        switch a {
        case .cancel:
            TextEditApp.log("close cancelled")
            app?.closeCancelled()
        case .dontSave:
            TextEditApp.log("closed \(name) without saving")
            close()
        case .save:
            closeAfterSave = true
            if path != nil {
                if case .ok = save() { close() } else { closeAfterSave = false }
            } else {
                _ = app?.perform(TextEditVerb.saveAs, in: self)
            }
        }
    }

    func close() {
        window?.close()
        window = nil
        app?.documentClosed(self)
    }

    // MARK: WindowDelegate

    func render(_ buffer: PixelBuffer) {
        Text.renderScale = buffer.scale
        let w = Double(buffer.width / buffer.scale), h = Double(buffer.height / buffer.scale)
        let cs = cairo_image_surface_create_for_data(buffer.data.assumingMemoryBound(to: UInt8.self),
                                                     CAIRO_FORMAT_ARGB32, buffer.width, buffer.height, buffer.stride)
        guard let cr = cairo_create(cs) else { cairo_surface_destroy(cs); return }
        cairo_scale(cr, Double(buffer.scale), Double(buffer.scale))
        cairo_save(cr); cairo_set_operator(cr, CAIRO_OPERATOR_CLEAR); cairo_paint(cr); cairo_restore(cr)
        cairo_set_operator(cr, CAIRO_OPERATOR_OVER)
        paintTextEdit(cr, w: w, h: h, title: shownTitle, view: view, findBar: findText,
                      findFocused: findFocused, caretOn: view.caretOn)
        if asking {
            let l = paintSaveSheet(cr, w: w, name: name)
            if dump, !sheetLogged {
                sheetLogged = true
                func c(_ r: Rect) -> String { "\(Int(r.x + r.w / 2)),\(Int(r.y + r.h / 2))" }
                TextEditApp.log("sheet save=\(c(l.save)) dontsave=\(c(l.dontSave)) cancel=\(c(l.cancel))")
            }
        } else { sheetLogged = false }
        cairo_surface_flush(cs); cairo_destroy(cr); cairo_surface_destroy(cs)
        if dump, announced != (Int(w), Int(h)) {
            announced = (Int(w), Int(h))
            let r = view.frame, (cw, ch) = TextView.cell()
            let gadgets = windowChrome(w: w, h: h).gadgets.map {
                "\($0.gadget)=\(Int($0.rect.x + $0.rect.w / 2)),\(Int($0.rect.y + $0.rect.h / 2))"
            }
            TextEditApp.log("chrome \(Int(w))x\(Int(h)) " + gadgets.joined(separator: " ")
                            + " text=\(Int(r.x)),\(Int(r.y)),\(Int(r.w)),\(Int(r.h)) inset=\(Int(TextViewStyle.inset))"
                            + " cell=\(twoPlaces(cw))x\(twoPlaces(ch))")
        }
    }

    func pointerMoved(x: Double, y: Double) {
        pointerX = x; pointerY = y
        view.pointerMoved(x: x, y: y)
    }

    func pointerButton(_ button: UInt32, pressed: Bool) {
        guard let w = window else { return }
        if !pressed { view.pointerReleased(); return }
        let size = w.size
        switch windowChromeHit(x: pointerX, y: pointerY, w: Double(size.width), h: Double(size.height)) {
        case .close: _ = app?.perform(TextEditVerb.close, in: self); return
        case .minimize: _ = w.minimize(); return
        case .zoom: w.setMaximized(!w.isMaximized); return
        case .depth: _ = w.lower(); return
        case .title: w.beginMove(); return
        case .resize(let e): w.beginResize(e); return
        case .pill, .content: break
        }
        guard button == 0x110 else { return }
        if asking {
            let l = SaveSheetLayout(w: Double(size.width))
            if l.save.contains(pointerX, pointerY) { answer(.save) }
            else if l.dontSave.contains(pointerX, pointerY) { answer(.dontSave) }
            else if l.cancel.contains(pointerX, pointerY) { answer(.cancel) }
            return
        }
        if view.contains(pointerX, pointerY) {
            findFocused = false
            view.pointerPressed(x: pointerX, y: pointerY, shift: shiftHeld)
        } else if findText != nil, pointerY < Theme.titleBarHeight + TextEditStyle.findBarHeight {
            findFocused = true
            window?.setNeedsDisplay()
        }
    }

    func pointerAxis(_ axis: UInt32, value: Double) {
        guard axis == 0 else { return }
        view.scroll(by: value * 2)
        window?.setNeedsDisplay()
    }

    func keyEvent(_ event: KeyEvent) {
        shiftHeld = event.modifiers.contains(.shift)
        guard event.pressed else { return }
        if asking {
            // Return saves, Escape cancels, ⌘D is Don't Save — Jaguar's keys.
            if event.keysym == KeySym.enter { answer(.save) }
            else if event.keysym == KeySym.escape { answer(.cancel) }
            else if event.modifiers.contains(.command), event.keysym == 0x64 { answer(.dontSave) }
            return
        }
        if event.modifiers.contains(.command) {
            if let press = keyEquivalent(event), let verb = TextEditApp.menuBar.verb(for: press),
               case .refused(let why)? = app?.perform(verb, in: self) {
                TextEditApp.log("\(verb) refused: \(why)")
            } else if !(keyEquivalent(event).flatMap { TextEditApp.menuBar.verb(for: $0) } != nil) {
                view.key(event)                                  // Command-arrows
            }
            return
        }
        if findFocused, findText != nil {
            switch event.keysym {
            case KeySym.escape: closeFind()
            case KeySym.enter: _ = find(backward: event.modifiers.contains(.shift))
            case KeySym.backspace: if !(findText ?? "").isEmpty { findText?.removeLast() }
            default:
                if !event.text.isEmpty, event.text.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7F }) {
                    findText = (findText ?? "") + event.text
                }
            }
            window?.setNeedsDisplay()
            return
        }
        if event.keysym == KeySym.escape, findText != nil { closeFind(); return }
        view.key(event)
    }

    func windowShouldClose(_ window: Window) { _ = app?.perform(TextEditVerb.close, in: self) }
    func windowStateChanged(_ window: Window) { view.caretOn = true; window.setNeedsDisplay() }
}

// MARK: - The application

public final class TextEditApp: MenuProvider {
    private let display: Display
    private var documents: [TextEditDocument] = []
    private var menuService: MenuService?
    private var menuName = ""
    private var blinkTimer: Int32 = -1
    private var lastMenuState = ""
    public var onQuit: () -> Void = { exit(0) }

    public static let menuBar = textEditMenuBar()

    public init(display: Display) {
        self.display = display
        menuName = MenuWire.serviceName(app: "TextEdit", pid: getpid())
        if let service = try? MenuService(name: menuName, provider: self) {
            display.addFileDescriptor(service.fd) { [weak service] in service?.serviceReadable() }
            menuService = service
        }
        blinkTimer = aw_create_interval_timer(500)
        if blinkTimer >= 0 { display.addFileDescriptor(blinkTimer) { [weak self] in self?.tick() } }
    }

    static func log(_ s: String) { ("TextEdit: " + s + "\n").withCString { _ = write(2, $0, strlen($0)) } }

    /// A window for `path`, or an empty one. False if the file cannot be
    /// edited as text (and says why) or no window could be made.
    @discardableResult
    public func open(path: String?) -> Bool {
        var text = ""
        if let p = path {
            let fd = Glibc.open(p, O_RDONLY | O_CLOEXEC)
            if fd >= 0 {
                let bytes = TextFile.read(fd: fd); close(fd)
                let (t, why) = TextFile.decode(bytes)
                guard let t else { TextEditApp.log("cannot open \(p): \(why ?? "")"); return false }
                text = t
            } else if errno != ENOENT {
                TextEditApp.log("cannot open \(p): \(String(cString: strerror(errno)))"); return false
            }
            // A name that does not exist yet is a new document that will be saved there.
        }
        return addDocument(path: path, text: text)
    }

    @discardableResult
    private func addDocument(path: String?, text: String) -> Bool {
        guard let d = TextEditDocument(display: display, app: self, path: path, text: text) else { return false }
        documents.append(d)
        if let win = d.window {
            display.window = win
            if !menuName.isEmpty, win.publishMenus(at: menuName) { TextEditApp.log("menus on \(menuName)") }
        }
        TextEditApp.log("opened \(path ?? "a new document") (\(d.view.model.lineCount) lines)")
        return true
    }

    func documentClosed(_ d: TextEditDocument) {
        documents.removeAll { $0 === d }
        if documents.isEmpty { TextEditApp.log("the last document closed"); onQuit(); return }
        if let w = documents.last?.window { display.window = w }
        if quitting { continueQuit() }
    }

    /// Quit: close every document, asking about each one with edits in turn.
    private var quitting = false

    private func continueQuit() {
        guard quitting else { return }
        if documents.contains(where: { $0.asking }) { return }
        if let dirty = documents.first(where: { $0.view.model.isDirty }) { dirty.askToClose(); return }
        TextEditApp.log("quitting")
        onQuit()
    }

    /// A save sheet's Cancel stops a Quit too.
    func closeCancelled() { quitting = false }

    private func tick() {
        var n: UInt64 = 0
        _ = withUnsafeMutablePointer(to: &n) { read(blinkTimer, $0, MemoryLayout<UInt64>.size) }
        for d in documents { d.blink() }
    }

    /// Tell the bar only when what its Edit and File menus say has changed:
    /// not on every keystroke.
    func menusMayHaveChanged() {
        guard let d = front else { return }
        let m = d.view.model
        let state = "\(m.undoName ?? "")|\(m.redoName ?? "")|\(m.selection.isEmpty)|\(m.isDirty)"
        guard state != lastMenuState else { return }
        lastMenuState = state
        menuService?.changed()
    }

    private var front: TextEditDocument? { documents.first { $0.window?.isActivated ?? false } ?? documents.last }

    func perform(_ verb: String, in d: TextEditDocument?) -> CommandResult {
        let doc = d ?? front
        switch verb {
        case TextEditVerb.quit:
            quitting = true
            continueQuit()
            return .ok("")
        case TextEditVerb.new: return addDocument(path: nil, text: "") ? .ok("") : .refused("no window could be made")
        case TextEditVerb.open:
            var m = Msg(); m.set("method", "file.open")
            if let p = doc?.path { m.set("dir", String(p.split(separator: "/", omittingEmptySubsequences: false).dropLast().joined(separator: "/"))) }
            PortalQuestion.ask(m, display: display) { [weak self] reply in self?.opened(reply) }
            return .ok("asked the portal")
        case TextEditVerb.close:
            guard let doc else { return .refused("no document") }
            if doc.view.model.isDirty { if !doc.asking { doc.askToClose() }; return .ok("asked") }
            doc.close(); return .ok("")
        case TextEditVerb.save:
            guard let doc else { return .refused("no document") }
            if doc.path == nil { return perform(TextEditVerb.saveAs, in: doc) }
            return doc.save()
        case TextEditVerb.saveAs:
            guard let doc else { return .refused("no document") }
            var m = Msg(); m.set("method", "file.save"); m.set("name", doc.name == "Untitled" ? "Untitled.txt" : doc.name)
            PortalQuestion.ask(m, display: display) { [weak self, weak doc] reply in
                guard let doc else { return }
                self?.savedAs(reply, doc)
            }
            return .ok("asked the portal")
        case TextEditVerb.undo:
            guard let doc, doc.view.model.canUndo else { return .refused("nothing to undo") }
            let name = doc.view.model.undoName ?? ""
            doc.view.edit { $0.undo() }
            TextEditApp.log("undid \(name)")
            return .ok("")
        case TextEditVerb.redo:
            guard let doc, doc.view.model.canRedo else { return .refused("nothing to redo") }
            doc.view.edit { $0.redo() }
            return .ok("")
        case TextEditVerb.copy, TextEditVerb.cut:
            guard let doc, !doc.view.model.selection.isEmpty else { return .refused("nothing is selected") }
            let t = doc.view.model.selectedText
            guard display.clipboard?.writeText(t) == true else { return .refused("the clipboard would not take it") }
            lastCopied = t
            if verb == TextEditVerb.cut { doc.view.edit { $0.insert("", kind: .cut) } }
            return .ok("")
        case TextEditVerb.paste:
            guard let doc else { return .refused("no document") }
            let t = (display.clipboard?.ownsSelection ?? false) ? lastCopied : (display.clipboard?.readText() ?? lastCopied)
            guard let t, !t.isEmpty else { return .refused("the clipboard holds no text") }
            doc.view.edit { $0.insert(t, kind: .paste) }
            return .ok("")
        case TextEditVerb.selectAll:
            doc?.view.edit { $0.selectAll() }; return .ok("")
        case TextEditVerb.find:
            doc?.showFind(); return .ok("")
        case TextEditVerb.findNext, TextEditVerb.findPrevious:
            guard let doc else { return .refused("no document") }
            return doc.find(backward: verb == TextEditVerb.findPrevious)
        case TextEditVerb.minimize:
            _ = doc?.window?.minimize(); return .ok("")
        default: return .refused("TextEdit has no verb \(verb)")
        }
    }

    private var lastCopied: String?

    private func opened(_ reply: Msg?) {
        guard var reply, reply.bool("ok") == true, let fd = reply.takeFD("file") else {
            TextEditApp.log("open: \(reply?.string("error") ?? "the portal did not answer")")
            return
        }
        let bytes = TextFile.read(fd: fd); close(fd)
        let path = reply.string("path")
        let (t, why) = TextFile.decode(bytes)
        guard let t else { TextEditApp.log("cannot open \(path ?? "it"): \(why ?? "")"); return }
        // An empty, untouched Untitled window is reused, as TextEdit does.
        if let d = front, d.path == nil, !d.view.model.isDirty, d.view.model.text.isEmpty {
            d.load(path: path ?? "Untitled", text: t)
            TextEditApp.log("opened \(path ?? "a file") (\(d.view.model.lineCount) lines)")
        } else {
            addDocument(path: path, text: t)
        }
    }

    private func savedAs(_ reply: Msg?, _ doc: TextEditDocument) {
        guard var reply, reply.bool("ok") == true, let fd = reply.takeFD("file"), let path = reply.string("path") else {
            TextEditApp.log("save as: \(reply?.string("error") ?? "the portal did not answer")")
            return
        }
        doc.savedThroughPortal(path: path, fd: fd)
    }

    // MARK: MenuProvider

    /// The Edit menu says what Undo would take back ("Undo Typing").
    public var menuModel: MenuBarModel {
        guard let m = front?.view.model else { return TextEditApp.menuBar }
        return TextEditApp.menuBar.retitled([
            TextEditVerb.undo: m.undoName.map { "Undo \($0)" } ?? "Undo",
            TextEditVerb.redo: m.redoName.map { "Redo \($0)" } ?? "Redo",
        ])
    }

    public func menuValidate(_ command: Command) -> Enablement {
        let m = front?.view.model
        switch command.verb {
        case TextEditVerb.about: return .disabled("TextEdit has no About box yet")
        case TextEditVerb.quit, TextEditVerb.new, TextEditVerb.open: return .enabled
        case TextEditVerb.undo: return m?.canUndo == true ? .enabled : .disabled("nothing to undo")
        case TextEditVerb.redo: return m?.canRedo == true ? .enabled : .disabled("nothing to redo")
        case TextEditVerb.cut, TextEditVerb.copy:
            return m.map { !$0.selection.isEmpty } == true ? .enabled : .disabled("nothing is selected")
        case TextEditVerb.paste:
            let has = display.clipboard?.offers([ClipboardMIME.text]) == true || lastCopied != nil
            return has ? .enabled : .disabled("the clipboard holds no text")
        case TextEditVerb.findNext, TextEditVerb.findPrevious:
            return (front.map { !($0.findText ?? $0.lastFind).isEmpty } ?? false) ? .enabled : .disabled("nothing to find")
        default: return documents.isEmpty ? .disabled("no document") : .enabled
        }
    }

    public func menuPerform(_ command: Command, arguments: [String: String]) -> CommandResult {
        if case .disabled(let why) = menuValidate(command) { return .refused(why) }
        return perform(command.verb, in: front)
    }
}
