// LoginWindow — the Aqua login window (PHASE16 P16.5a).
//
// What a machine shows when nobody is logged in: Jaguar's list of the people
// who can log in, each with their picture; choose one and type their password.
// A refusal shakes the panel, as the lock screen's does (the same `LockModel`);
// too many and the field closes with a countdown. Sleep, Restart and Shut Down
// sit along the bottom, as on the Mac's login window, and go straight to the
// root daemon, which lets the login window's own account ask for them.
//
// It runs as `_loginwindow`, in a session of its own (P16.5b), and asks the
// root daemon `login` — the one question only that account may ask: is this
// *that account's* password? On a yes the daemon ends this session and starts
// theirs; this window only says "Logging in…".

import Surface
import Login
import CCairo
import PoolConfig
import CWayland

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Where everything is on a display of this size: pure, so paint, hit and
/// the test's log agree.
public struct LoginWindowLayout: Equatable, Sendable {
    public static let rowHeight = 56.0, visibleRows = 5
    public var panel = Rect(0, 0, 0, 0)
    public var rows: [Rect] = []
    public var field = Rect(0, 0, 0, 0)
    public var back = Rect(0, 0, 0, 0), logIn = Rect(0, 0, 0, 0)
    public var sleep = Rect(0, 0, 0, 0), restart = Rect(0, 0, 0, 0), shutDown = Rect(0, 0, 0, 0)

    public init(w: Double, h: Double, accounts: Int) {
        panel = Rect(((w - 420) / 2).rounded(), ((h - 400) / 2).rounded(), 420, 400)
        let listTop = panel.y + 70
        for i in 0..<min(accounts, LoginWindowLayout.visibleRows) {
            rows.append(Rect(panel.x + 30, listTop + Double(i) * LoginWindowLayout.rowHeight, panel.w - 60,
                             LoginWindowLayout.rowHeight - 4))
        }
        field = Rect(panel.x + 70, panel.y + 220, panel.w - 140, 24)
        back = Rect(panel.x + 70, panel.y + 268, 120, 22)
        logIn = Rect(panel.x + panel.w - 70 - 120, panel.y + 268, 120, 22)
        let by = panel.y + panel.h - 40
        sleep = Rect(panel.x + 30, by, 100, 22)
        restart = Rect(panel.x + 160, by, 100, 22)
        shutDown = Rect(panel.x + 290, by, 100, 22)
    }
}

public final class LoginWindow: LayerSurfaceDelegate {
    private let display: Display
    private var layer: LayerSurface?
    public private(set) var accounts: [LoginAccount]
    /// The account whose password is being asked; nil shows the list.
    public private(set) var chosen: LoginAccount?
    private var highlighted = 0
    private var model = LockModel()
    private var pointerX = 0.0, pointerY = 0.0
    private var asking: Int32 = -1
    private var timer: Int32 = -1
    private let socket: String
    private let style: DesktopStyle
    private var loggedLayout = ""

    static func log(_ s: String) {
        let line = "LoginWindow: " + s + "\n"
        line.withCString { _ = write(2, $0, strlen($0)) }
    }

    public init?(display: Display, accounts: [LoginAccount] = LoginAccounts.system()) {
        self.display = display
        self.accounts = accounts
        socket = LoginClient.socket
        style = DesktopStyle.from((try? Pool.load("desktop")) ?? Config())
        guard let ls = LayerSurface(display: display, layer: .top, namespace: "abyss-loginwindow",
                                    width: 0, height: 0, anchor: .all, exclusiveZone: -1,
                                    keyboard: .exclusive, delegate: self) else { return nil }
        layer = ls
        LoginWindow.log("up: " + (accounts.isEmpty ? "no accounts" : accounts.map(\.name).joined(separator: " ")))
    }

    // MARK: Drawing

    public func render(_ buffer: PixelBuffer) {
        Text.renderScale = buffer.scale
        let w = Double(buffer.width / buffer.scale), h = Double(buffer.height / buffer.scale)
        let cs = cairo_image_surface_create_for_data(buffer.data.assumingMemoryBound(to: UInt8.self),
                                                     CAIRO_FORMAT_ARGB32, buffer.width, buffer.height, buffer.stride)
        guard let cr = cairo_create(cs) else { cairo_surface_destroy(cs); return }
        cairo_scale(cr, Double(buffer.scale), Double(buffer.scale))
        paintDesktop(cr, w: w, h: h, style: style)
        var l = LoginWindowLayout(w: w, h: h, accounts: accounts.count)
        let dx = model.shakeOffset(now: LockScreen.now()).rounded()
        paint(cr, &l, dx: dx)
        cairo_surface_flush(cs); cairo_destroy(cr); cairo_surface_destroy(cs)
        logLayout(l)
        if model.shakeStart != nil { layer?.setNeedsDisplay() }
    }

    private func logLayout(_ l: LoginWindowLayout) {
        func c(_ r: Rect) -> String { "\(Int(r.x + r.w / 2)),\(Int(r.y + r.h / 2))" }
        var line = "layout"
        for (a, r) in zip(accounts, l.rows) { line += " \(a.name)=\(c(r))" }
        line += " field=\(c(l.field)) back=\(c(l.back)) login=\(c(l.logIn))"
        line += " sleep=\(c(l.sleep)) restart=\(c(l.restart)) shutdown=\(c(l.shutDown))"
        guard line != loggedLayout else { return }
        loggedLayout = line
        LoginWindow.log(line)
    }

    private func paint(_ cr: OpaquePointer, _ l: inout LoginWindowLayout, dx: Double) {
        var p = l.panel
        p.x += dx
        Draw.roundedRect(cr, p, radius: 10)
        Draw.setColor(cr, Color(0.93, 0.93, 0.93, 0.97))
        cairo_fill_preserve(cr)
        Draw.setColor(cr, Color(0, 0, 0, 0.35)); cairo_set_line_width(cr, 1); cairo_stroke(cr)
        cairo_save(cr); Draw.roundedRect(cr, p, radius: 10); cairo_clip(cr)
        Draw.pinstripe(cr, p, Color(1, 1, 1, 0.5)); cairo_restore(cr)
        Draw.text(cr, "AbyssBSD", centerX: p.x + p.w / 2, centerY: p.y + 34, color: Color(0.1, 0.1, 0.1),
                  size: 20, style: .bold)

        if let who = chosen {
            Draw.icon("icon.myAccount", cr, Rect(p.x + p.w / 2 - 40, p.y + 70, 80, 80))
            Draw.text(cr, who.fullName, centerX: p.x + p.w / 2, centerY: p.y + 175, color: Color(0, 0, 0),
                      size: 15, style: .bold)
            var f = l.field; f.x += dx
            let open = model.phase == .typing
            Draw.textField(cr, f, text: model.bullets, caret: open, placeholder: open ? "Password" : "")
            let note: String
            switch model.phase {
            case .asking: note = "Checking…"
            case .unlocked: note = "Logging in…"
            default: note = model.status
            }
            if !note.isEmpty {
                let red = note.hasPrefix("The password") || note.hasPrefix("Too many")
                Draw.text(cr, note, centerX: p.x + p.w / 2, centerY: p.y + 256,
                          color: red ? Color(0.65, 0.05, 0.05) : Color(0.25, 0.25, 0.25), size: 11)
            }
            var b = l.back; b.x += dx; var g = l.logIn; g.x += dx
            Draw.gelButton(cr, b, label: "Back", blue: false, pressed: false)
            Draw.gelButton(cr, g, label: "Log In", blue: true, pressed: false)
        } else if accounts.isEmpty {
            Draw.text(cr, "There is nobody to log in as.", centerX: p.x + p.w / 2, centerY: p.y + 160,
                      color: Color(0.25, 0.25, 0.25), size: 13)
        } else {
            for (i, (a, r0)) in zip(accounts, l.rows).enumerated() {
                var r = r0; r.x += dx
                if i == highlighted {
                    Draw.roundedRect(cr, r, radius: 6)
                    Draw.setColor(cr, Color(0.22, 0.46, 0.84, 0.9)); cairo_fill(cr)
                }
                Draw.icon("icon.myAccount", cr, Rect(r.x + 8, r.y + 4, r.h - 8, r.h - 8))
                Draw.textLeft(cr, a.fullName, x: r.x + r.h + 12, baselineY: r.y + r.h / 2 + 5,
                              color: i == highlighted ? Color(1, 1, 1) : Color(0, 0, 0), size: 14, style: .bold)
            }
        }
        for (r0, label) in [(l.sleep, "Sleep"), (l.restart, "Restart"), (l.shutDown, "Shut Down")] {
            var r = r0; r.x += dx
            Draw.gelButton(cr, r, label: label, blue: false, pressed: false)
        }
    }

    // MARK: Input

    public func pointerMoved(x: Double, y: Double) { pointerX = x; pointerY = y }

    public func pointerButton(_ button: UInt32, pressed: Bool) {
        guard pressed, let size = layer?.size else { return }
        let l = LoginWindowLayout(w: Double(size.width), h: Double(size.height), accounts: accounts.count)
        if l.sleep.contains(pointerX, pointerY) { power(.sleep); return }
        if l.restart.contains(pointerX, pointerY) { power(.restart); return }
        if l.shutDown.contains(pointerX, pointerY) { power(.shutDown); return }
        if chosen != nil {
            if l.back.contains(pointerX, pointerY) { backToList() }
            else if l.logIn.contains(pointerX, pointerY) { ask() }
            return
        }
        for (i, r) in l.rows.enumerated() where r.contains(pointerX, pointerY) {
            highlighted = i
            choose(accounts[i])
            return
        }
    }

    public func keyEvent(_ e: KeyEvent) {
        guard e.pressed else { return }
        if chosen == nil {
            switch e.keysym {
            case KeySym.down: highlighted = min(highlighted + 1, max(0, accounts.count - 1))
            case KeySym.up: highlighted = max(highlighted - 1, 0)
            case KeySym.enter, 0xff8d:
                if accounts.indices.contains(highlighted) { choose(accounts[highlighted]) }
            default: break
            }
            layer?.setNeedsDisplay()
            return
        }
        if e.keysym == KeySym.escape, model.typed.isEmpty, model.phase == .typing { backToList(); return }
        if model.key(e) { ask() }
        layer?.setNeedsDisplay()
    }

    private func choose(_ a: LoginAccount) {
        chosen = a
        model = LockModel()
        LoginWindow.log("chose \(a.name)")
        layer?.setNeedsDisplay()
    }

    private func backToList() {
        guard asking < 0 else { return }
        chosen = nil
        model = LockModel()
        LoginWindow.log("back to the list")
        layer?.setNeedsDisplay()
    }

    // MARK: Asking

    private func ask() {
        guard asking < 0, let who = chosen, model.phase == .typing else { return }
        var password = model.takeForAsking()
        defer { Login.wipe(&password) }
        LoginWindow.log("asking for \(who.name)")
        do {
            let s = try LoginClient.login(user: who.name, password: password, socket: socket)
            asking = s
            display.addFileDescriptor(s) { [weak self] in self?.answered() }
        } catch {
            LoginWindow.log("could not ask: \(error)")
            model.answer(nil, error: "The login service is not running.", now: LockScreen.now())
        }
        layer?.setNeedsDisplay()
    }

    private func answered() {
        let s = asking
        display.removeFileDescriptor(s)
        asking = -1
        defer { close(s) }
        var why: String?
        let verdict: Verdict?
        do { verdict = try LoginClient.finish(on: s) } catch { verdict = nil; why = "\(error)" }
        model.answer(verdict, error: why.map { "Your password cannot be checked: \($0)" }, now: LockScreen.now())
        switch verdict {
        case .accepted?: LoginWindow.log("accepted \(chosen?.name ?? "?") — logging in")
        case .refused?: LoginWindow.log("refused — shake")
        case .wait(let ms)?: LoginWindow.log("wait \(ms) ms — the field is closed"); startTimer()
        case .unavailable(let w)?: LoginWindow.log("unavailable: \(w)")
        case nil: LoginWindow.log("no answer: \(why ?? "")")
        }
        layer?.setNeedsDisplay()
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
            LoginWindow.log("the wait is over — the field is open")
            display.removeFileDescriptor(timer); close(timer); timer = -1
        }
        layer?.setNeedsDisplay()
    }

    private func power(_ a: PowerAction) {
        do {
            let r = try PowerClient.request(a, socket: socket)
            LoginWindow.log("\(a.rawValue) → " + (r.bool("ok") == true ? "ok" : "refused: \(r.string("error") ?? "?")"))
        } catch {
            LoginWindow.log("\(a.rawValue) → nobody to ask: \(error)")
        }
    }
}
