// SystemProfilerApp — what this computer is (Jaguar's Apple System Profiler,
// fastfetch's report).
//
// One window: the machine's name and who is using it, then two boxes of
// `Label  value` rows — Software (OS, kernel, uptime, packages, shell,
// desktop, window manager, theme, terminal, locale) and Hardware (host, CPU,
// GPU, memory, swap, disk, displays, address, battery). Copy (⌘C) puts the
// fastfetch-shaped text on the clipboard; Refresh (⌘R) reads it all again.
//
// The reading is here, the parsing in `SystemFacts` (pure, tested). Every
// reading has a fallback for a machine unlike a PC — the device tree's model
// where there is no SMBIOS, the bound DRM driver where the GPU is no PCI
// device — and a reading that fails stays **unknown**, shown as such.

import Surface
import SystemFacts
import Vents
import Spawn
import CCairo

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

// MARK: - Gathering

public enum FactGatherer {
    static func run(_ argv: [String]) -> String? {
        let r = Spawn.run(argv, stderr: .capture, limit: 1 << 20)
        return r.succeeded ? r.stdoutText : nil
    }

    static func readFile(_ path: String) -> String? {
        guard let f = fopen(path, "r") else { return nil }
        defer { fclose(f) }
        var out = [UInt8](), buf = [UInt8](repeating: 0, count: 4096)
        while true { let n = fread(&buf, 1, buf.count, f); if n <= 0 { break }; out += buf[0..<n] }
        return String(decoding: out, as: UTF8.self)
    }

    static func env(_ k: String) -> String? { getenv(k).map { String(cString: $0) }.flatMap { $0.isEmpty ? nil : $0 } }

    static func uname() -> (sysname: String, release: String, machine: String) {
        var u = utsname()
        _ = Glibc.uname(&u)
        func field<T>(_ t: T) -> String { withUnsafeBytes(of: t) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) } }
        return (field(u.sysname), field(u.release), field(u.machine))
    }

    /// Everything, read now. `displays` comes from the compositor, which the
    /// caller has asked (wlr-output-management), or nil.
    public static func gather(displays: [DisplayConfigurator.Head]? = nil) -> SystemFacts {
        let me = getpwuid(getuid()).flatMap { $0.pointee.pw_name.map { String(cString: $0) } } ?? "user"
        var host = [CChar](repeating: 0, count: 256)
        gethostname(&host, host.count)
        let hostname = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        let u = uname()
        let arch = Vents.Sysctl.string("hw.machine_arch") ?? u.machine
        let release = Vents.Sysctl.string("kern.osrelease") ?? u.release
        var f: [Fact] = []

        // ---- software
        f.append(Fact(.software, "OS", "AbyssBSD on \(u.sysname) \(release) \(arch)"))
        f.append(Fact(.software, "Kernel", "\(u.sysname) \(release)"))
        var uptime: Int64?
        if let raw = Vents.Sysctl.raw("kern.boottime"), let boot = FactParse.bootSeconds(timeval: raw) {
            uptime = Int64(time(nil)) - boot
        } else if let t = readFile("/proc/uptime"), let s = Double(t.split(separator: " ").first ?? "") {
            uptime = Int64(s)
        }
        f.append(Fact(.software, "Uptime", uptime.map { FactFormat.uptime(seconds: $0) }))
        let pkgs = run(["pkg", "info", "-q"]).map { $0.split(separator: "\n").count }
        f.append(Fact(.software, "Packages", pkgs.map { "\($0) (pkg)" }))
        f.append(Fact(.software, "Shell", env("SHELL").map { String($0.split(separator: "/").last ?? "") }))
        f.append(Fact(.software, "Desktop", "AbyssBSD Aqua"))
        f.append(Fact(.software, "Window Manager", env("WAYLAND_DISPLAY") != nil ? "undertow" : nil))
        f.append(Fact(.software, "Theme", AppearanceChoice.current().theme))
        f.append(Fact(.software, "Terminal", "Terminal"))
        f.append(Fact(.software, "Locale", env("LC_ALL") ?? env("LANG") ?? "C"))

        // ---- hardware
        var machine: String?
        if let m = Vents.Kenv.machine() { machine = "\(m.maker) \(m.product)" }
        else if let t = run(["ofwdump", "-P", "model", "-R", "/"]) { machine = FactParse.ofwModel(t) }
        f.append(Fact(.hardware, "Host", machine))
        var cpu: String?
        if let model = Vents.Sysctl.string("hw.model")?.trimmed, !model.isEmpty {
            var s = model
            if let n = Vents.Sysctl.int("hw.ncpu") { s += " (\(n))" }
            if let mhz = Vents.Sysctl.int("dev.cpu.0.freq"), mhz > 0 { s += " @ " + FactFormat.frequency(mhz: mhz) }
            cpu = s
        }
        f.append(Fact(.hardware, "CPU", cpu))
        var gpus = run(["pciconf", "-lv"]).map(FactParse.pciDisplays) ?? []
        if gpus.isEmpty, let k = run(["kldstat"]), let d = FactParse.drmDriver(kldstat: k) { gpus = [d] }
        f.append(Fact(.hardware, "GPU", gpus.isEmpty ? nil : gpus.joined(separator: ", ")))
        var mem: String?
        if let ps = Vents.Sysctl.int("hw.pagesize"), let pages = Vents.Sysctl.int("vm.stats.vm.v_page_count"),
           let free = Vents.Sysctl.int("vm.stats.vm.v_free_count"),
           let inactive = Vents.Sysctl.int("vm.stats.vm.v_inactive_count") {
            let laundry = Vents.Sysctl.int("vm.stats.vm.v_laundry_count") ?? 0
            let used = FactParse.memoryUsed(pageSize: UInt64(ps), pages: UInt64(pages), free: UInt64(free),
                                            inactive: UInt64(inactive), laundry: UInt64(laundry))
            mem = FactFormat.usage(used: used, total: UInt64(ps) * UInt64(pages))
        }
        f.append(Fact(.hardware, "Memory", mem))
        let swap = run(["swapinfo", "-k"]).flatMap(FactParse.swap)
        f.append(Fact(.hardware, "Swap", swap.map { FactFormat.usage(used: $0.used, total: $0.total) }
                                         ?? (run(["swapinfo", "-k"]) != nil ? "none" : nil)))
        var disk: String?
        var st = statvfs()
        if statvfs("/", &st) == 0 {
            let total = UInt64(st.f_blocks) * UInt64(st.f_frsize)
            let used = (UInt64(st.f_blocks) - UInt64(st.f_bfree)) * UInt64(st.f_frsize)
            disk = FactFormat.usage(used: used, total: total) + fsType("/").map { " - " + $0 }.orEmpty
        }
        f.append(Fact(.hardware, "Disk (/)", disk))
        if let ds = displays, !ds.isEmpty {
            let shown = ds.filter(\.enabled).compactMap { h -> String? in
                guard let m = h.current else { return nil }
                let hz = Int((Double(m.refreshMilliHz) / 1000).rounded())
                return "\(h.name) \(m.width)×\(m.height) @ \(hz) Hz" + (h.scale != 1 ? " (×\(h.scale))" : "")
            }
            f.append(Fact(.hardware, "Display", shown.isEmpty ? nil : shown.joined(separator: ", ")))
        } else {
            f.append(Fact(.hardware, "Display", nil))
        }
        let ifs = Vents.Network.interfaces().filter { !$0.loopback && !$0.ipv4.isEmpty }
        f.append(Fact(.hardware, "Local IP", ifs.first.map { "\($0.ipv4[0].address)/\($0.ipv4[0].prefix) (\($0.name))" }))
        let battery: String?
        if let b = Vents.Battery.read() {
            battery = (b.percent.map { "\($0)%" } ?? "unknown charge") + (b.isCharging ? " (charging)" : "")
        } else {
            battery = Vents.Sysctl.isSupported ? "none" : nil
        }
        f.append(Fact(.hardware, "Battery", battery))
        return SystemFacts(title: "\(me)@\(hostname)", facts: f)
    }

    static func fsType(_ path: String) -> String? {
        #if os(FreeBSD)
        var s = statfs()
        guard statfs(path, &s) == 0 else { return nil }
        return withUnsafeBytes(of: s.f_fstypename) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        #else
        return nil
        #endif
    }
}

extension Optional where Wrapped == String {
    var orEmpty: String { self ?? "" }
}

// MARK: - Layout and paint (pure: paint, hit and the test's log agree)

public struct ProfilerLayout: Equatable, Sendable {
    public var icon = Rect(0, 0, 0, 0)
    public var boxes: [(Fact.Section, Rect)] = []
    public var rows: [Rect] = []
    public var copy = Rect(0, 0, 0, 0), refresh = Rect(0, 0, 0, 0)
    public static func == (a: ProfilerLayout, b: ProfilerLayout) -> Bool {
        a.icon == b.icon && a.rows == b.rows && a.copy == b.copy && a.refresh == b.refresh
            && a.boxes.map(\.1) == b.boxes.map(\.1)
    }

    public static let rowHeight = 19.0
    public static func height(for facts: SystemFacts) -> Double {
        Theme.titleBarHeight + 104 + Double(facts.facts.count) * rowHeight + 2 * 44 + 56
    }

    public init(w: Double, facts: SystemFacts) {
        let top = Theme.titleBarHeight
        icon = Rect(24, top + 18, 64, 64)
        var y = top + 104
        for section in Fact.Section.allCases {
            let n = facts.facts.filter { $0.section == section }.count
            let box = Rect(20, y, w - 40, Double(n) * ProfilerLayout.rowHeight + 32)
            boxes.append((section, box))
            var ry = box.y + 22
            for _ in 0..<n { rows.append(Rect(box.x + 12, ry, box.w - 24, ProfilerLayout.rowHeight)); ry += ProfilerLayout.rowHeight }
            y = box.y + box.h + 12
        }
        copy = Rect(w - 20 - 100 - 12 - 100, y + 6, 100, 22)
        refresh = Rect(w - 20 - 100, y + 6, 100, 22)
    }
}

@discardableResult
public func paintSystemProfiler(_ cr: OpaquePointer, w: Double, h: Double, facts: SystemFacts) -> ProfilerLayout {
    paintWindowChrome(cr, w: w, h: h, title: "System Profiler")
    Draw.setColor(cr, Theme.contentBackground)
    cairo_rectangle(cr, 0, Theme.titleBarHeight, w, h - Theme.titleBarHeight); cairo_fill(cr)
    let l = ProfilerLayout(w: w, facts: facts)
    Draw.icon("icon.displays", cr, l.icon)
    Draw.textLeft(cr, facts.value("Host") ?? "This Computer", x: l.icon.x + l.icon.w + 18,
                  baselineY: l.icon.y + 26, color: Theme.bodyText, size: 20, style: .bold)
    Draw.textLeft(cr, facts.title + " — " + (facts.value("OS") ?? "AbyssBSD"), x: l.icon.x + l.icon.w + 18,
                  baselineY: l.icon.y + 50, color: Theme.secondaryText, size: 12)
    var i = 0
    for (section, box) in l.boxes {
        Draw.groupBox(cr, box, title: section.rawValue)
        for fact in facts.facts where fact.section == section {
            let r = l.rows[i]; i += 1
            let lw = Draw.textWidth(cr, fact.label, size: 12, style: .bold)
            Draw.textLeft(cr, fact.label, x: r.x + 120 - lw, baselineY: r.y + 14, color: Theme.bodyText, size: 12, style: .bold)
            Draw.textLeft(cr, fact.value ?? "unknown", x: r.x + 132, baselineY: r.y + 14,
                          color: fact.value == nil ? Theme.secondaryText : Theme.bodyText, size: 12)
        }
    }
    Draw.gelButton(cr, l.copy, label: "Copy", blue: false, pressed: false)
    Draw.gelButton(cr, l.refresh, label: "Refresh", blue: true, pressed: false)
    return l
}

// MARK: - The application

public final class SystemProfilerApp: WindowDelegate {
    private let display: Display
    private var window: Window?
    private var facts: SystemFacts
    private var configurator: DisplayConfigurator?
    private var pointerX = 0.0, pointerY = 0.0
    private var logged = false
    public var onQuit: () -> Void = { exit(0) }

    static func log(_ s: String) {
        let line = "System Profiler: " + s + "\n"
        line.withCString { _ = write(2, $0, strlen($0)) }
    }

    public init?(display: Display) {
        self.display = display
        // The displays, from the compositor; its own connection, as the
        // Displays pane does, so its requests pump their own loop.
        configurator = DisplayConfigurator()
        facts = FactGatherer.gather(displays: configurator?.displays)
        let width: Int32 = 620
        let height = Int32(ProfilerLayout.height(for: facts))
        guard let win = Window(display: display, title: "System Profiler", appID: "org.abyssbsd.systemprofiler",
                               width: width, height: height, delegate: self) else { return nil }
        window = win
        logFacts()
    }

    private func logFacts() {
        SystemProfilerApp.log("facts \(facts.facts.count): " + facts.facts.map { "\($0.label)=\($0.value ?? "unknown")" }
            .joined(separator: " | "))
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
        let l = paintSystemProfiler(cr, w: w, h: h, facts: facts)
        cairo_surface_flush(cs); cairo_destroy(cr); cairo_surface_destroy(cs)
        if !logged {
            logged = true
            func c(_ r: Rect) -> String { "\(Int(r.x + r.w / 2)),\(Int(r.y + r.h / 2))" }
            SystemProfilerApp.log("buttons copy=\(c(l.copy)) refresh=\(c(l.refresh))")
        }
    }

    public func pointerMoved(x: Double, y: Double) { pointerX = x; pointerY = y }
    public func pointerAxis(_ axis: UInt32, value: Double) {}

    public func pointerButton(_ button: UInt32, pressed: Bool) {
        guard pressed, let w = window else { return }
        let size = w.size
        switch windowChromeHit(x: pointerX, y: pointerY, w: Double(size.width), h: Double(size.height)) {
        case .close: onQuit(); return
        case .minimize: _ = w.minimize(); return
        case .title: w.beginMove(); return
        default: break
        }
        let l = ProfilerLayout(w: Double(size.width), facts: facts)
        if l.copy.contains(pointerX, pointerY) { copy() }
        else if l.refresh.contains(pointerX, pointerY) { refresh() }
    }

    public func keyEvent(_ e: KeyEvent) {
        guard e.pressed, e.modifiers.contains(.command) else { return }
        switch e.text.lowercased() {
        case "c": copy()
        case "r": refresh()
        case "q", "w": onQuit()
        default: break
        }
    }

    public func windowShouldClose(_ window: Window) { onQuit() }

    private func copy() {
        let ok = display.clipboard?.writeText(facts.text) == true
        SystemProfilerApp.log(ok ? "copied \(facts.text.utf8.count) bytes" : "the clipboard would not take it")
    }

    private func refresh() {
        facts = FactGatherer.gather(displays: configurator?.displays)
        logFacts()
        window?.setNeedsDisplay()
    }
}

/// The window as the golden gate pictures it: a fixed machine (`.sample`),
/// so the picture is the same on every computer that draws it.
public func renderSystemProfilerPNG(path: String, scale: Int32 = 1) -> Bool {
    let facts = SystemFacts.sample
    let width: Int32 = 620, height = Int32(ProfilerLayout.height(for: facts))
    guard let cs = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, width * scale, height * scale),
          let cr = cairo_create(cs) else { return false }
    defer { cairo_destroy(cr); cairo_surface_destroy(cs) }
    cairo_scale(cr, Double(scale), Double(scale))
    Text.renderScale = scale
    defer { Text.renderScale = 1 }
    paintSystemProfiler(cr, w: Double(width), h: Double(height), facts: facts)
    cairo_surface_flush(cs)
    return cairo_surface_write_to_png(cs, path) == CAIRO_STATUS_SUCCESS
}
