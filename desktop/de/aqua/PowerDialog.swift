// PowerDialog — "Are you sure…?" (PHASE16 P16.4b).
//
// Jaguar asks before it restarts or shuts down, and its power key asks what
// you meant. One small window, three questions:
//
//   - System > Restart…    "Are you sure you want to restart the computer now?"
//                          Cancel · **Restart**
//   - System > Shut Down…  "Are you sure you want to shut down the computer now?"
//                          Cancel · **Shut Down**
//   - the power key        "Are you sure you want to shut down your computer now?"
//                          Restart · Sleep          Cancel · **Shut Down**
//
// The bold one is the default (Return); Escape is Cancel. The choice goes to
// the root daemon (`PowerClient`), which decides who may: a refusal is shown in
// the dialog, in the daemon's words, with an OK — never a silent nothing.

import Surface
import Login
import CCairo

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

public enum PowerAsk: String, Sendable {
    case restart, shutDown = "shut-down", powerKey = "power-key"

    public var question: String {
        switch self {
        case .restart: return "Are you sure you want to restart the computer now?"
        case .shutDown: return "Are you sure you want to shut down the computer now?"
        case .powerKey: return "Are you sure you want to shut down your computer now?"
        }
    }

    /// The buttons, left to right; the last is the default.
    public var choices: [PowerChoice] {
        switch self {
        case .restart: return [.cancel, .restart]
        case .shutDown: return [.cancel, .shutDown]
        case .powerKey: return [.restart, .sleep, .cancel, .shutDown]
        }
    }
}

public enum PowerChoice: String, Sendable {
    case restart = "Restart", sleep = "Sleep", cancel = "Cancel", shutDown = "Shut Down", ok = "OK"

    public var action: PowerAction? {
        switch self {
        case .restart: return .restart
        case .sleep: return .sleep
        case .shutDown: return .shutDown
        case .cancel, .ok: return nil
        }
    }
}

/// Where everything is: pure, so paint, hit and the test's log agree.
public struct PowerDialogLayout: Equatable, Sendable {
    public var icon = Rect(0, 0, 0, 0)
    public var buttons: [(PowerChoice, Rect)] = []
    public var textX = 0.0

    public static func == (a: PowerDialogLayout, b: PowerDialogLayout) -> Bool {
        a.icon == b.icon && a.textX == b.textX && a.buttons.map { $0.0 } == b.buttons.map { $0.0 }
            && a.buttons.map { $0.1 } == b.buttons.map { $0.1 }
    }

    public init(choices: [PowerChoice], w: Double, h: Double) {
        let top = Theme.titleBarHeight
        icon = Rect(20, top + 16, 64, 64)
        textX = 100
        let bw = 92.0, bh = 22.0, gap = 12.0, y = h - bh - 18
        // Jaguar's arrangement: the choices that are not "stop" on the left,
        // Cancel and the default on the right.
        let right = choices.filter { $0 == .cancel || $0 == choices.last || $0 == .ok }
        let left = choices.filter { !right.contains($0) }
        var x = w - 20 - Double(right.count) * bw - Double(max(0, right.count - 1)) * gap
        for c in right { buttons.append((c, Rect(x, y, bw, bh))); x += bw + gap }
        x = 20                     // the left pair from the window's edge, under the icon
        for c in left { buttons.append((c, Rect(x, y, bw, bh))); x += bw + gap }
    }

    public func hit(_ x: Double, _ y: Double) -> PowerChoice? {
        buttons.first { $0.1.contains(x, y) }?.0
    }
}

public final class PowerDialog: WindowDelegate {
    private(set) var window: Window?
    public let ask: PowerAsk
    private var choices: [PowerChoice]
    private var message: String
    private var refusal: String?
    private var pointerX = 0.0, pointerY = 0.0
    private var logged = false
    public var onDone: () -> Void = { exit(0) }
    private let socket: String

    static func log(_ s: String) {
        let line = "PowerDialog: " + s + "\n"
        line.withCString { _ = write(2, $0, strlen($0)) }
    }

    public init?(display: Display, ask: PowerAsk) {
        self.ask = ask
        choices = ask.choices
        message = ask.question
        socket = LoginClient.socket
        let scale: Int32, auto: Bool
        if let s = getenv("AQUA_SCALE"), let v = Int32(String(cString: s)), v > 0 { (scale, auto) = (v, false) }
        else { (scale, auto) = (1, true) }
        guard let win = Window(display: display, title: "", appID: "org.abyssbsd.power",
                               width: 460, height: 150, scale: scale, autoScale: auto, delegate: self) else { return nil }
        window = win
        PowerDialog.log("up (\(ask.rawValue))")
    }

    var defaultChoice: PowerChoice? { choices.last }

    public func render(_ buffer: PixelBuffer) {
        Text.renderScale = buffer.scale
        let w = Double(buffer.width / buffer.scale), h = Double(buffer.height / buffer.scale)
        let cs = cairo_image_surface_create_for_data(buffer.data.assumingMemoryBound(to: UInt8.self),
                                                     CAIRO_FORMAT_ARGB32, buffer.width, buffer.height, buffer.stride)
        guard let cr = cairo_create(cs) else { cairo_surface_destroy(cs); return }
        cairo_scale(cr, Double(buffer.scale), Double(buffer.scale))
        cairo_save(cr); cairo_set_operator(cr, CAIRO_OPERATOR_CLEAR); cairo_paint(cr); cairo_restore(cr)
        cairo_set_operator(cr, CAIRO_OPERATOR_OVER)
        let l = paintPowerDialog(cr, w: w, h: h, message: message, refusal: refusal, choices: choices)
        cairo_surface_flush(cs); cairo_destroy(cr); cairo_surface_destroy(cs)
        if !logged {
            logged = true
            let at = l.buttons.map { "\(String($0.0.rawValue.map { $0 == " " ? "_" : $0 }))=\(Int($0.1.x + $0.1.w / 2)),\(Int($0.1.y + $0.1.h / 2))" }
            PowerDialog.log("buttons " + at.joined(separator: " "))
        }
    }

    public func pointerMoved(x: Double, y: Double) { pointerX = x; pointerY = y }
    public func pointerAxis(_ axis: UInt32, value: Double) {}

    public func pointerButton(_ button: UInt32, pressed: Bool) {
        guard pressed, let w = window else { return }
        let size = w.size
        switch windowChromeHit(x: pointerX, y: pointerY, w: Double(size.width), h: Double(size.height)) {
        case .close: choose(.cancel); return
        case .title: w.beginMove(); return
        default: break
        }
        let l = PowerDialogLayout(choices: choices, w: Double(size.width), h: Double(size.height))
        if let c = l.hit(pointerX, pointerY) { choose(c) }
    }

    public func keyEvent(_ e: KeyEvent) {
        guard e.pressed else { return }
        if e.keysym == KeySym.enter || e.keysym == 0xff8d, let d = defaultChoice { choose(d) }
        else if e.keysym == KeySym.escape { choose(refusal == nil ? .cancel : .ok) }
    }

    public func windowShouldClose(_ window: Window) { choose(.cancel) }

    private func choose(_ c: PowerChoice) {
        guard let action = c.action else {
            PowerDialog.log("chose \(c.rawValue)")
            finish(); return
        }
        do {
            let r = try PowerClient.request(action, socket: socket)
            if r.bool("ok") == true {
                PowerDialog.log("chose \(c.rawValue) → ok")
                finish(); return
            }
            refuse(c, r.string("error") ?? "the computer said no")
        } catch {
            refuse(c, "nobody to ask: \(error)")
        }
    }

    private func refuse(_ c: PowerChoice, _ why: String) {
        PowerDialog.log("chose \(c.rawValue) → refused: \(why)")
        refusal = why
        choices = [.ok]
        logged = false
        window?.setNeedsDisplay()
    }

    private func finish() {
        window?.close()
        window = nil
        onDone()
    }
}

@discardableResult
public func paintPowerDialog(_ cr: OpaquePointer, w: Double, h: Double, message: String, refusal: String?,
                             choices: [PowerChoice]) -> PowerDialogLayout {
    paintWindowChrome(cr, w: w, h: h, title: "")
    Draw.setColor(cr, Theme.contentBackground)
    cairo_rectangle(cr, 0, Theme.titleBarHeight, w, h - Theme.titleBarHeight); cairo_fill(cr)
    let l = PowerDialogLayout(choices: choices, w: w, h: h)
    Draw.icon("icon.displays", cr, l.icon)
    // The question in bold, wrapped to the room beside the icon, as Jaguar's
    // alerts set it; a refusal under it in the daemon's words.
    var y = Theme.titleBarHeight + 30
    for line in wrapWords(cr, message, width: w - l.textX - 20, size: 13, style: .bold) {
        Draw.textLeft(cr, line, x: l.textX, baselineY: y, color: Theme.bodyText, size: 13, style: .bold)
        y += 18
    }
    if let r = refusal {
        for line in wrapWords(cr, r, width: w - l.textX - 20, size: 11) {
            Draw.textLeft(cr, line, x: l.textX, baselineY: y + 4, color: Color(0.65, 0.05, 0.05), size: 11)
            y += 15
        }
    }
    for (c, r) in l.buttons {
        Draw.gelButton(cr, r, label: c.rawValue, blue: c == choices.last, pressed: false)
    }
    return l
}

/// Break `text` into lines no wider than `width` at `size`, between words.
func wrapWords(_ cr: OpaquePointer, _ text: String, width: Double, size: Double,
               style: Text.Style = .regular) -> [String] {
    var lines: [String] = [], line = ""
    for word in text.split(separator: " ") {
        let next = line.isEmpty ? String(word) : line + " " + word
        if !line.isEmpty, Draw.textWidth(cr, next, size: size, style: style) > width { lines.append(line); line = String(word) }
        else { line = next }
    }
    if !line.isEmpty { lines.append(line) }
    return lines
}
