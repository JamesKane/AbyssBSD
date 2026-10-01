// SetupAssistant — an account's first login (PHASE16 P16.7, §6.5).
//
// The installer already asked for the keyboard, the time zone and the
// account; this is the rest, small, once, and skippable — on the installer's
// hub-and-spoke shape: the steps down the left, a page on the right.
//
//   Welcome     who this desktop thinks you are
//   Network     whether this computer is connected, and where to change it
//               (joining Wi-Fi is the Network pane's — an administrator's)
//   Appearance  the theme, chosen here and written where the General pane
//               reads it (appearance.ini) — the session redraws as you choose
//   All Set     and done
//
// Finishing or skipping writes `setup.ini` (`SetupState`), so the next login
// goes straight to the desktop. Closing the window without either does not:
// it asks again next time, since nothing was said either way.

import Surface
import PoolConfig
import Vents
import CCairo

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

public enum SetupPage: Int, CaseIterable, Sendable {
    case welcome, network, appearance, done
    public var title: String {
        switch self {
        case .welcome: return "Welcome"
        case .network: return "Network"
        case .appearance: return "Appearance"
        case .done: return "All Set"
        }
    }
}

/// The assistant's state, without a window: tested directly.
public struct SetupModel: Equatable, Sendable {
    public var page: SetupPage = .welcome
    public var themes: [InstalledTheme]
    public var theme: String
    public var fullName: String
    public var connection: String
    public init(themes: [InstalledTheme], theme: String, fullName: String, connection: String) {
        self.themes = themes; self.theme = theme; self.fullName = fullName; self.connection = connection
    }

    public mutating func forward() { page = SetupPage(rawValue: min(page.rawValue + 1, SetupPage.done.rawValue))! }
    public mutating func back() { page = SetupPage(rawValue: max(page.rawValue - 1, 0))! }
    public var continueLabel: String { page == .done ? "Start Using AbyssBSD" : "Continue" }
    public var canGoBack: Bool { page != .welcome }

    /// What the computer's connection is, in a sentence, from the kernel's
    /// interfaces: the first one up with an address.
    public static func connection(_ ifs: [Vents.Network.Interface]) -> String {
        if let i = ifs.first(where: { !$0.loopback && $0.up && !$0.ipv4.isEmpty }) {
            return "This computer is connected through \(i.name) (\(i.ipv4[0].address))."
        }
        return "This computer is not connected to a network."
    }
}

public struct SetupLayout: Equatable, Sendable {
    public var steps: [Rect] = []
    public var page = Rect(0, 0, 0, 0)
    public var themeRows: [Rect] = []
    public var skip = Rect(0, 0, 0, 0), back = Rect(0, 0, 0, 0), next = Rect(0, 0, 0, 0)
    public var openNetwork = Rect(0, 0, 0, 0)

    public init(w: Double, h: Double, themes: Int) {
        let top = Theme.titleBarHeight
        for i in 0..<SetupPage.allCases.count { steps.append(Rect(16, top + 24 + Double(i) * 32, 150, 26)) }
        page = Rect(190, top + 16, w - 210, h - top - 76)
        for i in 0..<themes { themeRows.append(Rect(page.x + 8, page.y + 100 + Double(i) * 30, page.w - 16, 26)) }
        openNetwork = Rect(page.x + 8, page.y + 120, 210, 22)
        let by = h - 44
        skip = Rect(16, by, 110, 22)
        next = Rect(w - 20 - 170, by, 170, 22)
        back = Rect(next.x - 12 - 100, by, 100, 22)
    }
}

@discardableResult
public func paintSetupAssistant(_ cr: OpaquePointer, w: Double, h: Double, _ m: SetupModel) -> SetupLayout {
    paintWindowChrome(cr, w: w, h: h, title: "Setup Assistant")
    Draw.setColor(cr, Theme.contentBackground)
    cairo_rectangle(cr, 0, Theme.titleBarHeight, w, h - Theme.titleBarHeight); cairo_fill(cr)
    let l = SetupLayout(w: w, h: h, themes: m.themes.count)
    for (i, p) in SetupPage.allCases.enumerated() {
        let r = l.steps[i]
        let here = p == m.page, past = p.rawValue < m.page.rawValue
        if here {
            Draw.roundedRect(cr, r, radius: 6)
            Draw.setColor(cr, Color(0.22, 0.46, 0.84)); cairo_fill(cr)
        }
        Draw.textLeft(cr, (past ? "✓ " : "  ") + p.title, x: r.x + 10, baselineY: r.y + 17,
                      color: here ? Color(1, 1, 1) : (past ? Theme.bodyText : Theme.secondaryText), size: 13,
                      style: here ? .bold : .regular)
    }
    Draw.setColor(cr, Color(0.7, 0.7, 0.7)); cairo_set_line_width(cr, 1)
    cairo_move_to(cr, 178.5, Theme.titleBarHeight + 16); cairo_line_to(cr, 178.5, h - 60); cairo_stroke(cr)

    let p = l.page
    func heading(_ s: String) { Draw.textLeft(cr, s, x: p.x + 8, baselineY: p.y + 30, color: Theme.bodyText, size: 20, style: .bold) }
    func body(_ s: String, _ line: Int) {
        Draw.textLeft(cr, s, x: p.x + 8, baselineY: p.y + 64 + Double(line) * 20, color: Theme.bodyText, size: 13)
    }
    switch m.page {
    case .welcome:
        heading("Welcome to AbyssBSD")
        body("Hello, \(m.fullName).", 0)
        body("A few things to set up, and each can be changed later", 2)
        body("in System Preferences.", 3)
    case .network:
        heading("Network")
        body(m.connection, 0)
        body("Wi-Fi networks and addresses are in the Network pane.", 1)
        Draw.gelButton(cr, l.openNetwork, label: "Open Network Preferences…", blue: false, pressed: false)
    case .appearance:
        heading("Appearance")
        body("Choose how windows, menus and controls look:", 0)
        for (t, r) in zip(m.themes, l.themeRows) {
            Draw.radioButton(cr, cx: r.x + 10, cy: r.y + 13, radius: 7, selected: t.id == m.theme)
            Draw.textLeft(cr, t.name, x: r.x + 26, baselineY: r.y + 17, color: Theme.bodyText, size: 13)
        }
    case .done:
        heading("You're All Set")
        body("Your desktop is ready.", 0)
        body("To change any of this later, open System Preferences.", 2)
    }
    Draw.gelButton(cr, l.skip, label: "Skip Setup", blue: false, pressed: false)
    if m.canGoBack { Draw.gelButton(cr, l.back, label: "Go Back", blue: false, pressed: false) }
    Draw.gelButton(cr, l.next, label: m.continueLabel, blue: true, pressed: false)
    return l
}

public final class SetupAssistantApp: WindowDelegate {
    private let display: Display
    private var window: Window?
    private var model: SetupModel
    private var pointerX = 0.0, pointerY = 0.0
    private var loggedPage: SetupPage?
    public var onQuit: () -> Void = { exit(0) }

    static func log(_ s: String) {
        let line = "Setup Assistant: " + s + "\n"
        line.withCString { _ = write(2, $0, strlen($0)) }
    }

    public init?(display: Display) {
        self.display = display
        let pw = getpwuid(getuid())
        let name = pw.flatMap { $0.pointee.pw_name.map { String(cString: $0) } } ?? "you"
        let gecos = pw.flatMap { $0.pointee.pw_gecos.map { String(cString: $0) } } ?? ""
        let full = gecos.split(separator: ",", omittingEmptySubsequences: false).first.map(String.init) ?? ""
        model = SetupModel(themes: AppearanceCatalogue.installed(), theme: AppearanceChoice.current().theme,
                           fullName: full.isEmpty ? name : full,
                           connection: SetupModel.connection(Vents.Network.interfaces()))
        guard let win = Window(display: display, title: "Setup Assistant", appID: "org.abyssbsd.setupassistant",
                               width: 640, height: 400, delegate: self) else { return nil }
        window = win
        SetupAssistantApp.log("up for \(name) — themes: " + model.themes.map(\.id).joined(separator: " "))
    }

    public func render(_ buffer: PixelBuffer) {
        Text.renderScale = buffer.scale
        let w = Double(buffer.width / buffer.scale), h = Double(buffer.height / buffer.scale)
        let cs = cairo_image_surface_create_for_data(buffer.data.assumingMemoryBound(to: UInt8.self),
                                                     CAIRO_FORMAT_ARGB32, buffer.width, buffer.height, buffer.stride)
        guard let cr = cairo_create(cs) else { cairo_surface_destroy(cs); return }
        cairo_scale(cr, Double(buffer.scale), Double(buffer.scale))
        cairo_save(cr); cairo_set_operator(cr, CAIRO_OPERATOR_CLEAR); cairo_paint(cr); cairo_restore(cr)
        cairo_set_operator(cr, CAIRO_OPERATOR_OVER)
        let l = paintSetupAssistant(cr, w: w, h: h, model)
        cairo_surface_flush(cs); cairo_destroy(cr); cairo_surface_destroy(cs)
        if loggedPage != model.page {
            loggedPage = model.page
            func c(_ r: Rect) -> String { "\(Int(r.x + r.w / 2)),\(Int(r.y + r.h / 2))" }
            var line = "page \(model.page.title) skip=\(c(l.skip)) back=\(c(l.back)) next=\(c(l.next))"
            if model.page == .appearance { for (t, r) in zip(model.themes, l.themeRows) { line += " theme.\(t.id)=\(c(r))" } }
            if model.page == .network { line += " open-network=\(c(l.openNetwork))" }
            SetupAssistantApp.log(line)
        }
    }

    public func pointerMoved(x: Double, y: Double) { pointerX = x; pointerY = y }
    public func pointerAxis(_ axis: UInt32, value: Double) {}

    public func pointerButton(_ button: UInt32, pressed: Bool) {
        guard pressed, let w = window else { return }
        let size = w.size
        switch windowChromeHit(x: pointerX, y: pointerY, w: Double(size.width), h: Double(size.height)) {
        case .close: SetupAssistantApp.log("closed — it asks again next time"); onQuit(); return
        case .title: w.beginMove(); return
        default: break
        }
        let l = SetupLayout(w: Double(size.width), h: Double(size.height), themes: model.themes.count)
        if l.skip.contains(pointerX, pointerY) { finish(skipped: true); return }
        if l.next.contains(pointerX, pointerY) { next(); return }
        if model.canGoBack, l.back.contains(pointerX, pointerY) { model.back(); w.setNeedsDisplay(); return }
        if model.page == .network, l.openNetwork.contains(pointerX, pointerY) { openNetwork(); return }
        if model.page == .appearance {
            for (t, r) in zip(model.themes, l.themeRows) where r.contains(pointerX, pointerY) { choose(t.id); return }
        }
    }

    public func keyEvent(_ e: KeyEvent) {
        guard e.pressed else { return }
        if e.keysym == KeySym.enter || e.keysym == 0xff8d { next() }
        else if e.keysym == KeySym.escape, model.canGoBack { model.back(); window?.setNeedsDisplay() }
    }

    public func windowShouldClose(_ window: Window) {
        SetupAssistantApp.log("closed — it asks again next time"); onQuit()
    }

    private func next() {
        if model.page == .done { finish(skipped: false); return }
        model.forward()
        window?.setNeedsDisplay()
    }

    private func choose(_ id: String) {
        guard id != model.theme else { return }
        do {
            try AppearanceWrite.store(AppearanceChoice(theme: id, scheme: nil, parameters: [:]))
            model.theme = id
            SetupAssistantApp.log("theme \(id) chosen")
        } catch {
            SetupAssistantApp.log("could not save the theme: \(error)")
        }
        window?.setNeedsDisplay()
    }

    private func openNetwork() {
        let exe = Launcher.selfExecutable() ?? "AquaDemo"
        let ok = Launcher.launchDetached([exe], extraEnv: ["AQUA_SCENE": "sysprefs", "ABYSS_PREFS_PANE": "network"])
        SetupAssistantApp.log("open Network Preferences — " + (ok ? "started" : "could not start"))
    }

    private func finish(skipped: Bool) {
        do {
            try SetupState.markDone(skipped: skipped)
            SetupAssistantApp.log("done (\(skipped ? "skipped" : "finished")) — not again at this account's logins")
        } catch {
            SetupAssistantApp.log("could not say it is done: \(error)")
        }
        onQuit()
    }
}
