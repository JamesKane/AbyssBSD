// LockScreen — the Aqua lock screen (PHASE16 P16.2b).
//
// An ext-session-lock client: it locks the session, covers every display, and
// on the first display shows who is logged in — the My Account picture, the
// full name — with a password field. Return asks the authenticator (P16.1);
// only its yes unlocks. A no clears the field and **shakes** the panel, as the
// Mac's login window does. Too many and the authenticator says wait: the
// field is closed and counts down, and nothing is asked until it is over.
//
// It fails closed. If the authenticator is not running, or PAM cannot be
// asked, the screen says so and stays locked: the way out of that is another
// console, not this window. If this process dies, the session stays locked
// too (undertow, P16.2a) — and a new lock screen can take over.
//
// The password is held as bytes, wiped when it is sent or cleared, and never
// logged; the log says what happened to an attempt, not what it was.

import Surface
import Login
import CCairo
import CWayland
import PoolConfig

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// What the lock screen shows and does, without a display: tested directly.
public struct LockModel {
    public enum Phase: Equatable { case typing, asking, waiting(UInt64), unlocked }
    public private(set) var phase: Phase = .typing
    /// The typed password, as bytes. Never logged, wiped on every clear.
    public private(set) var typed: [UInt8] = []
    public var status: String = ""
    /// When the shake began (monotonic ns), nil when still.
    public private(set) var shakeStart: UInt64?
    public static let shakeNs: UInt64 = 500_000_000

    public init() {}

    public var bullets: String { String(repeating: "•", count: typedCharacters) }
    private var typedCharacters: Int { String(decoding: typed, as: UTF8.self).count }

    /// A key: typing while the field is open, Backspace, Escape. Returns true
    /// for Return when there is something to ask.
    public mutating func key(_ e: KeyEvent) -> Bool {
        guard e.pressed, phase == .typing else { return false }
        switch e.keysym {
        case KeySym.enter, 0xff8d:          // Return, keypad Enter
            return true
        case KeySym.backspace:
            // A whole character, not a byte of one.
            var s = String(decoding: typed, as: UTF8.self)
            if !s.isEmpty { s.removeLast() }
            wipe(); typed = Array(s.utf8)
        case KeySym.escape:
            wipe()
        default:
            guard !e.text.isEmpty, !e.modifiers.contains(.control), !e.modifiers.contains(.command),
                  e.text.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7f }) else { return false }
            typed.append(contentsOf: Array(e.text.utf8))
            status = ""
        }
        return false
    }

    /// The password, handed over to be asked; the model's copy is wiped.
    public mutating func takeForAsking() -> [UInt8] {
        let p = typed
        wipe()
        phase = .asking
        status = ""
        return p
    }

    /// The authenticator's answer (or why there was none).
    public mutating func answer(_ v: Verdict?, error: String? = nil, now: UInt64) {
        switch v {
        case .accepted?:
            phase = .unlocked
        case .refused?:
            phase = .typing
            status = "The password is incorrect."
            shakeStart = now
        case .wait(let ms)?:
            phase = .waiting(now &+ ms &* 1_000_000)
            shakeStart = now
            status = LockModel.waitText(ms)
        case .unavailable(let why)?:
            phase = .typing
            status = "Your password cannot be checked: \(why)"
        case nil:
            phase = .typing
            status = error ?? "Your password cannot be checked."
        }
    }

    /// A second has passed: count down, and open the field when it is over.
    public mutating func tick(now: UInt64) {
        guard case .waiting(let until) = phase else { return }
        if now >= until { phase = .typing; status = "" }
        else { status = LockModel.waitText((until - now) / 1_000_000) }
    }

    static func waitText(_ ms: UInt64) -> String {
        let s = (ms + 999) / 1000
        return "Too many attempts. Try again in \(s) second\(s == 1 ? "" : "s")."
    }

    /// The panel's sideways offset at `now`: a decaying shake, then still.
    public mutating func shakeOffset(now: UInt64) -> Double {
        guard let start = shakeStart else { return 0 }
        let t = now &- start
        guard t < LockModel.shakeNs else { shakeStart = nil; return 0 }
        let f = Double(t) / Double(LockModel.shakeNs)
        return 14 * (1 - f) * sin(f * 6 * Double.pi)
    }

    private mutating func wipe() { Login.wipe(&typed) }
}

public final class LockScreen: SessionLockDelegate {
    private let display: Display
    private var lock: SessionLockClient?
    private var model = LockModel()
    private let user: String
    private let fullName: String
    private let socket: String
    private var asking: Int32 = -1
    private var timer: Int32 = -1
    private let style: DesktopStyle
    public var onDone: ((Bool) -> Void)?

    static func log(_ s: String) {
        let line = "LockScreen: " + s + "\n"
        line.withCString { _ = write(2, $0, strlen($0)) }
    }

    public init?(display: Display) {
        self.display = display
        let pw = getpwuid(getuid())
        user = pw.flatMap { $0.pointee.pw_name.map { String(cString: $0) } } ?? "user"
        // GECOS's first field is the full name; an empty one falls back to the
        // account name, as the Mac shows the short name when there is no other.
        let gecos = pw.flatMap { $0.pointee.pw_gecos.map { String(cString: $0) } } ?? ""
        let full = gecos.split(separator: ",", omittingEmptySubsequences: false).first.map(String.init) ?? ""
        fullName = full.isEmpty ? user : full
        socket = LoginClient.socket
        style = DesktopStyle.from((try? Pool.load("desktop")) ?? Config())
        guard display.hasSessionLock else {
            LockScreen.log("the compositor offers no session lock — cannot lock")
            return nil
        }
        guard let l = SessionLockClient(display: display, delegate: self) else { return nil }
        lock = l
        LockScreen.log("locking for \(user) (\(l.surfaces.count) display(s)); asking \(socket)")
    }

    // MARK: SessionLockDelegate

    public func sessionLocked() { LockScreen.log("locked") }

    public func sessionLockFinished() {
        LockScreen.log(model.phase == .unlocked ? "finished" : "the compositor refused the lock or ended it")
        onDone?(false)
    }

    public func keyEvent(_ event: KeyEvent) {
        if model.key(event) { ask() }
        lock?.setNeedsDisplay()
    }

    public func render(_ buffer: PixelBuffer, on surface: LockSurface) {
        Text.renderScale = buffer.scale
        let w = Double(buffer.width / buffer.scale), h = Double(buffer.height / buffer.scale)
        let cs = cairo_image_surface_create_for_data(buffer.data.assumingMemoryBound(to: UInt8.self),
                                                     CAIRO_FORMAT_ARGB32, buffer.width, buffer.height, buffer.stride)
        guard let cr = cairo_create(cs) else { cairo_surface_destroy(cs); return }
        cairo_scale(cr, Double(buffer.scale), Double(buffer.scale))
        paintDesktop(cr, w: w, h: h, style: style)
        // Dimmed: this is not the desktop, and must not look like it is waiting
        // for a click on it.
        cairo_set_source_rgba(cr, 0, 0, 0, 0.45)
        cairo_rectangle(cr, 0, 0, w, h)
        cairo_fill(cr)
        if surface.index == 0 { paintPanel(cr, w: w, h: h) }
        cairo_surface_flush(cs)
        cairo_destroy(cr)
        cairo_surface_destroy(cs)
        // Still shaking: draw again next frame.
        if model.shakeStart != nil { surface.setNeedsDisplay() }
    }

    /// The panel's rectangle on a display of this size, before any shake.
    public static func panelRect(w: Double, h: Double) -> Rect {
        Rect(((w - 320) / 2).rounded(), ((h - 250) / 2).rounded(), 320, 250)
    }

    private func paintPanel(_ cr: OpaquePointer, w: Double, h: Double) {
        var p = LockScreen.panelRect(w: w, h: h)
        p.x += model.shakeOffset(now: LockScreen.now()).rounded()
        // The login window's look: a pinstriped sheet with a soft edge.
        Draw.roundedRect(cr, p, radius: 10)
        Draw.setColor(cr, Color(0.93, 0.93, 0.93, 0.97))
        cairo_fill_preserve(cr)
        Draw.setColor(cr, Color(0, 0, 0, 0.35))
        cairo_set_line_width(cr, 1)
        cairo_stroke(cr)
        cairo_save(cr)
        Draw.roundedRect(cr, p, radius: 10)
        cairo_clip(cr)
        Draw.pinstripe(cr, p, Color(1, 1, 1, 0.5))
        cairo_restore(cr)
        Draw.icon("icon.myAccount", cr, Rect(p.x + 128, p.y + 22, 64, 64))
        Draw.text(cr, fullName, centerX: p.x + p.w / 2, centerY: p.y + 104,
                  color: Color(0, 0, 0), size: 15, style: .bold)
        let field = Rect(p.x + 40, p.y + 132, p.w - 80, 24)
        let open = model.phase == .typing
        Draw.textField(cr, field, text: model.bullets, caret: open,
                       placeholder: open ? "Password" : "")
        let note: String
        switch model.phase {
        case .asking: note = "Checking…"
        case .unlocked: note = ""
        default: note = model.status.isEmpty ? "Enter your password to unlock." : model.status
        }
        let red = model.status.hasPrefix("The password") || model.status.hasPrefix("Too many")
        Draw.text(cr, note, centerX: p.x + p.w / 2, centerY: p.y + 180,
                  color: red ? Color(0.65, 0.05, 0.05) : Color(0.25, 0.25, 0.25), size: 11)
        Draw.text(cr, "This computer is locked.", centerX: p.x + p.w / 2, centerY: p.y + 220,
                  color: Color(0.35, 0.35, 0.35), size: 10)
    }

    // MARK: Asking

    private func ask() {
        guard asking < 0 else { return }
        var password = model.takeForAsking()
        defer { Login.wipe(&password) }
        LockScreen.log("asking the authenticator")
        do {
            let s = try LoginClient.begin(password: password, socket: socket)
            asking = s
            display.addFileDescriptor(s) { [weak self] in self?.answered() }
        } catch {
            LockScreen.log("could not ask: \(error)")
            model.answer(nil, error: "The authenticator is not running, so your password cannot be checked.",
                         now: LockScreen.now())
        }
        lock?.setNeedsDisplay()
    }

    private func answered() {
        let s = asking
        display.removeFileDescriptor(s)
        asking = -1
        defer { close(s) }
        let verdict: Verdict?
        var why: String?
        do { verdict = try LoginClient.finish(on: s) } catch { verdict = nil; why = "\(error)" }
        model.answer(verdict, error: why.map { "Your password cannot be checked: \($0)" }, now: LockScreen.now())
        switch verdict {
        case .accepted?:
            LockScreen.log("accepted — unlocking")
            lock?.unlock()
            lock = nil
            onDone?(true)
            return
        case .refused?: LockScreen.log("refused — shake")
        case .wait(let ms)?: LockScreen.log("wait \(ms) ms — the field is closed"); startTimer()
        case .unavailable(let w)?: LockScreen.log("unavailable: \(w)")
        case nil: LockScreen.log("no answer: \(why ?? "")")
        }
        lock?.setNeedsDisplay()
    }

    private func startTimer() {
        guard timer < 0 else { return }
        timer = aw_create_interval_timer(250)
        guard timer >= 0 else { return }
        display.addFileDescriptor(timer) { [weak self] in self?.tick() }
    }

    private func tick() {
        var n: UInt64 = 0
        _ = withUnsafeMutablePointer(to: &n) { read(timer, $0, MemoryLayout<UInt64>.size) }
        model.tick(now: LockScreen.now())
        if model.phase == .typing {
            LockScreen.log("the wait is over — the field is open")
            display.removeFileDescriptor(timer); close(timer); timer = -1
        }
        lock?.setNeedsDisplay()
    }

    static func now() -> UInt64 {
        var ts = timespec()
        clock_gettime(CLOCK_MONOTONIC, &ts)
        return UInt64(ts.tv_sec) &* 1_000_000_000 &+ UInt64(ts.tv_nsec)
    }
}
