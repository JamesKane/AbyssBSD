// Disk Utility — disks, ZFS datasets and their snapshots (PHASE15 P15.8).
//
// The disks the installer already knows how to describe (`DiskInventory`,
// probed without privilege), the machine's ZFS datasets, and each dataset's
// snapshots — read here, in the person's own process. Every change is a typed
// plan for the settings helper (`VolumePlan`): take a snapshot, roll back to
// the latest one (asked first: changes since are lost), mount and unmount. The
// helper checks the thing still exists and refuses what would destroy more than
// asked — a rollback past later snapshots, the system's own mounts.
//
// What a test reads (ABYSS_DISKUTILITY_DUMP=1): the sidebar's and the snapshot
// list's rows and where they are drawn, the buttons, and what the helper said.

import Surface
import CCairo
import AquaDraw
import MenuModel
import MenuWire
import CurrentIPC
import Install
import InstallRun
import Volumes
import Settings
import SettingsWire

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

public enum DiskUtilityVerb {
    public static let about = "app.about", quit = "app.quit", close = "window.close", minimize = "window.minimize"
    public static let snapshot = "volume.snapshot", rollback = "volume.rollback", mount = "volume.mount", refresh = "view.refresh"
}

public func diskUtilityMenuBar() -> MenuBarModel {
    func c(_ verb: String, _ title: String, _ key: KeyEquivalent? = nil, _ summary: String) -> MenuItem {
        .command(Command(verb, title, key: key, summary: summary))
    }
    return MenuBarModel(appName: "Disk Utility", menus: [
        Menu("Disk Utility", [
            c(DiskUtilityVerb.about, "About Disk Utility", nil, "Show Disk Utility's version."),
            .separator,
            c(DiskUtilityVerb.quit, "Quit Disk Utility", .cmd("q"), "Close Disk Utility."),
        ]),
        Menu("File", [c(DiskUtilityVerb.close, "Close", .cmd("w"), "Close the window.")]),
        Menu("Volume", [
            c(DiskUtilityVerb.mount, "Mount or Unmount", .cmd("e"), "Mount or unmount the selected dataset."),
            c(DiskUtilityVerb.snapshot, "Take Snapshot", .cmd("t"), "Snapshot the selected dataset now."),
            c(DiskUtilityVerb.rollback, "Roll Back…", nil, "Return the dataset to its latest snapshot."),
            .separator,
            c(DiskUtilityVerb.refresh, "Refresh", .cmd("r"), "Read the disks and pools again."),
        ]),
        Menu("Window", [c(DiskUtilityVerb.minimize, "Minimize", .cmd("m"), "Put the window in the Dock.")]),
    ])
}

/// What the sidebar lists: disks, then datasets.
public enum VolumeItem: Equatable, Sendable {
    case disk(Disk)
    case dataset(ZFSDataset)
    var key: String {
        switch self { case .disk(let d): return "disk:" + d.name; case .dataset(let d): return "ds:" + d.name }
    }
}

public struct DiskUtilityView: Sendable {
    public var disks: [Disk] = []
    public var disksUnavailable: String?
    public var volumes = Volumes.State()
    public var selected: String?            // VolumeItem.key
    public var selectedSnapshot: String?
    public var status = ""
    /// Dates in UTC rather than local time: the golden scene's, so a picture
    /// does not depend on the machine's time zone.
    public var utcDates = false
    public init() {}

    public var items: [VolumeItem] { disks.map { .disk($0) } + volumes.datasets.map { .dataset($0) } }
    public var selectedItem: VolumeItem? { items.first { $0.key == selected } }
    public var selectedDataset: ZFSDataset? { if case .dataset(let d)? = selectedItem { return d } else { return nil } }
}

public struct DiskUtilityLayout: Equatable, Sendable {
    public let sidebar: Rect, pane: Rect, rowHeight: Double
    public let mount: Rect, snapshot: Rect, rollback: Rect, snapshots: Rect, footer: Rect
    public init(w: Double, h: Double) {
        let top = Theme.titleBarHeight
        footer = Rect(0, h - 26 - windowResizeBand, w, 26)
        sidebar = Rect(0, top, 220, footer.y - top)
        pane = Rect(221, top, w - 221, footer.y - top)
        rowHeight = 20
        mount = Rect(pane.x + 16, top + 128, 110, 26)
        snapshot = Rect(pane.x + 136, top + 128, 130, 26)
        rollback = Rect(pane.x + 276, top + 128, 110, 26)
        snapshots = Rect(pane.x + 16, top + 186, pane.w - 32, max(0, footer.y - top - 196))
    }
}

func diskUtilityDate(_ t: Int64, utc: Bool = false) -> String {
    var tt = time_t(t), tm = tm()
    if utc { gmtime_r(&tt, &tm) } else { localtime_r(&tt, &tm) }
    func two(_ v: Int32) -> String { v < 10 ? "0\(v)" : "\(v)" }
    return "\(tm.tm_year + 1900)-\(two(tm.tm_mon + 1))-\(two(tm.tm_mday)) \(two(tm.tm_hour)):\(two(tm.tm_min))"
}

public func paintDiskUtility(_ cr: OpaquePointer, w: Double, h: Double, view: DiskUtilityView) -> DiskUtilityLayout {
    paintWindowChrome(cr, w: w, h: h, title: "Disk Utility")
    let l = DiskUtilityLayout(w: w, h: h)
    Draw.setColor(cr, Color(hex: 0xE8EDF3)); cairo_rectangle(cr, l.sidebar.x, l.sidebar.y, l.sidebar.w, l.sidebar.h); cairo_fill(cr)
    Draw.setColor(cr, Theme.contentBackground); cairo_rectangle(cr, l.pane.x, l.pane.y, l.pane.w, l.pane.h); cairo_fill(cr)
    // The sidebar.
    var y = l.sidebar.y + 8
    func heading(_ s: String) {
        Draw.textLeft(cr, s, x: 10, baselineY: y + 13, color: Theme.bodyText.with(a: 0.6), size: 10, style: .bold)
        y += 18
    }
    func row(_ item: VolumeItem, _ text: String, indent: Double) {
        if view.selected == item.key {
            Draw.setColor(cr, Color(hex: 0x3875D7)); cairo_rectangle(cr, 0, y, l.sidebar.w, l.rowHeight); cairo_fill(cr)
        }
        Draw.textLeft(cr, text, x: 12 + indent, baselineY: y + 14,
                      color: view.selected == item.key ? Color(1, 1, 1) : Theme.bodyText, size: 11)
        y += l.rowHeight
    }
    heading("DISKS")
    if let why = view.disksUnavailable {
        Draw.textLeft(cr, why, x: 12, baselineY: y + 14, color: Theme.bodyText.with(a: 0.6), size: 10); y += l.rowHeight
    }
    for d in view.disks { row(.disk(d), "\(d.name)  \(ProcessTableBytes(d.bytes))", indent: 0) }
    y += 6
    heading("ZFS")
    if let why = view.volumes.unavailable {
        Draw.textLeft(cr, why, x: 12, baselineY: y + 14, color: Theme.bodyText.with(a: 0.6), size: 10); y += l.rowHeight
    }
    for d in view.volumes.datasets { row(.dataset(d), d.depth == 0 ? d.name : d.leaf, indent: Double(d.depth) * 12) }

    // The pane.
    let px = l.pane.x + 16
    func line(_ k: String, _ v: String, _ yy: Double) {
        Draw.textLeft(cr, k, x: px, baselineY: yy, color: Theme.bodyText.with(a: 0.7), size: 11)
        Draw.textLeft(cr, v, x: px + 110, baselineY: yy, color: Theme.bodyText, size: 11)
    }
    let top = Theme.titleBarHeight
    switch view.selectedItem {
    case .disk(let d)?:
        Draw.textLeft(cr, d.name, x: px, baselineY: top + 30, color: Theme.bodyText, size: 15, style: .bold)
        line("Size:", ProcessTableBytes(d.bytes), top + 56)
        line("Description:", d.description.isEmpty ? "—" : d.description, top + 74)
        line("Partitions:", d.partitionKinds.isEmpty ? "none" : d.partitionKinds.joined(separator: ", "), top + 92)
        line("Mounted at:", d.mountedAt.isEmpty ? "nothing" : d.mountedAt.joined(separator: ", "), top + 110)
        if d.holdsRunningRoot { line("", "This disk holds the running system.", top + 128) }
    case .dataset(let d)?:
        Draw.textLeft(cr, d.name, x: px, baselineY: top + 30, color: Theme.bodyText, size: 15, style: .bold)
        line("Mountpoint:", d.mountpoint, top + 56)
        line("Used:", ProcessTableBytes(d.used), top + 74)
        line("Available:", ProcessTableBytes(d.available), top + 92)
        line("Mounted:", d.mounted ? "yes" : "no", top + 110)
        Draw.gelButton(cr, l.mount, label: d.mounted ? "Unmount" : "Mount", blue: false, pressed: false)
        Draw.gelButton(cr, l.snapshot, label: "Take Snapshot", blue: false, pressed: false)
        Draw.gelButton(cr, l.rollback, label: "Roll Back…", blue: false, pressed: false)
        Draw.textLeft(cr, "Snapshots", x: px, baselineY: top + 178, color: Theme.bodyText, size: 11, style: .bold)
        Draw.setColor(cr, Color(1, 1, 1)); cairo_rectangle(cr, l.snapshots.x, l.snapshots.y, l.snapshots.w, l.snapshots.h); cairo_fill(cr)
        let snaps = view.volumes.snapshots(of: d.name)
        if snaps.isEmpty {
            Draw.textLeft(cr, "No snapshots yet.", x: l.snapshots.x + 8, baselineY: l.snapshots.y + 15,
                          color: Theme.bodyText.with(a: 0.6), size: 11)
        }
        for (i, s) in snaps.reversed().enumerated() where Double(i + 1) * l.rowHeight <= l.snapshots.h {
            let ry = l.snapshots.y + Double(i) * l.rowHeight
            let sel = view.selectedSnapshot == s.name
            if sel { Draw.setColor(cr, Color(hex: 0x3875D7)); cairo_rectangle(cr, l.snapshots.x, ry, l.snapshots.w, l.rowHeight); cairo_fill(cr) }
            let fg = sel ? Color(1, 1, 1) : Theme.bodyText
            Draw.textLeft(cr, s.short, x: l.snapshots.x + 8, baselineY: ry + 14, color: fg, size: 11)
            Draw.textLeft(cr, diskUtilityDate(s.created, utc: view.utcDates), x: l.snapshots.x + l.snapshots.w - 210, baselineY: ry + 14, color: fg, size: 11)
            Draw.textLeft(cr, ProcessTableBytes(s.used), x: l.snapshots.x + l.snapshots.w - 70, baselineY: ry + 14, color: fg, size: 11)
        }
    case nil:
        Draw.textLeft(cr, "Choose a disk or a dataset.", x: px, baselineY: top + 30, color: Theme.bodyText.with(a: 0.6), size: 12)
    }
    Draw.setColor(cr, Color(hex: 0xE4E4E4)); cairo_rectangle(cr, l.footer.x, l.footer.y, l.footer.w, l.footer.h); cairo_fill(cr)
    Draw.textLeft(cr, view.status, x: 12, baselineY: l.footer.y + 17, color: Theme.bodyText, size: 11)
    return l
}

/// Activity Monitor's way of writing a size, without depending on Vents here.
func ProcessTableBytes(_ b: UInt64) -> String {
    let k = 1024.0, v = Double(b)
    func r(_ x: Double, _ places: Double) -> String {
        let t = (x * places).rounded() / places
        return places == 10 ? String(format1: t) : String(format2: t)
    }
    if v >= k * k * k * k { return r(v / (k * k * k * k), 100) + " TB" }
    if v >= k * k * k { return r(v / (k * k * k), 100) + " GB" }
    if v >= k * k { return r(v / (k * k), 10) + " MB" }
    return "\(Int((v / k).rounded())) KB"
}

extension String {
    init(format1 v: Double) { let t = Int((v * 10).rounded()); self = "\(t / 10).\(abs(t % 10))" }
    init(format2 v: Double) { let t = Int((v * 100).rounded()); let f = abs(t % 100); self = "\(t / 100).\(f < 10 ? "0" : "")\(f)" }
}

// MARK: - The application

public final class DiskUtilityApp: WindowDelegate, MenuProvider {
    private let display: Display
    private var window: Window?
    private var view = DiskUtilityView()
    private var menuService: MenuService?
    private var pointerX = 0.0, pointerY = 0.0
    private var askingRollback: String?
    private let dump = getenv("ABYSS_DISKUTILITY_DUMP") != nil
    private var lastDump = ""
    public var onQuit: () -> Void = { exit(0) }

    public static let menuBar = diskUtilityMenuBar()

    public init?(display: Display) {
        self.display = display
        let scale: Int32, auto: Bool
        if let s = getenv("AQUA_SCALE"), let v = Int32(String(cString: s)), v > 0 { (scale, auto) = (v, false) }
        else { (scale, auto) = (1, true) }
        guard let win = Window(display: display, title: "Disk Utility", appID: "org.abyssbsd.diskutility",
                               width: 700, height: 480, scale: scale, autoScale: auto, delegate: self) else { return nil }
        window = win
        display.window = win
        let name = MenuWire.serviceName(app: "DiskUtility", pid: getpid())
        if let service = try? MenuService(name: name, provider: self) {
            display.addFileDescriptor(service.fd) { [weak service] in service?.serviceReadable() }
            menuService = service
            _ = win.publishMenus(at: name)
        }
        refresh()
    }

    static func log(_ s: String) { ("Disk Utility: " + s + "\n").withCString { _ = write(2, $0, strlen($0)) } }

    private func refresh() {
        do { view.disks = try probeMachine().disks; view.disksUnavailable = nil }
        catch { view.disks = []; view.disksUnavailable = "\(error)".contains("notSupported") ? "disks are FreeBSD's to list" : "\(error)" }
        view.volumes = Volumes.read()
        if let s = view.selectedSnapshot, !view.volumes.snapshots.contains(where: { $0.name == s }) { view.selectedSnapshot = nil }
        if dump {
            Self.log(view.volumes.unavailable.map { "volumes: unavailable: \($0)" }
                     ?? "volumes: \(view.volumes.datasets.count) datasets, \(view.volumes.snapshots.count) snapshots")
        }
        window?.setNeedsDisplay()
    }

    // MARK: changes, through the helper

    private func send(_ action: VolumeAction, _ what: String) {
        var request = Msg(); request.set("method", "apply")
        SettingsWire.encode(.volume(VolumePlan(action)), into: &request)
        guard let sock = SettingsClient.begin(request) else {
            view.status = "The settings helper is not running, so nothing can be changed."
            Self.log("\(what): no settings helper"); window?.setNeedsDisplay(); return
        }
        view.status = "\(what)…"
        Self.log("\(what): asked the helper")
        display.addFileDescriptor(sock) { [weak self] in
            guard let self else { return }
            guard let e = SettingsClient.next(on: sock) else {
                self.display.removeFileDescriptor(sock); close(sock); return
            }
            if case .finished(let ok, let err) = e {
                Self.log("\(what): \(ok ? "done" : "refused: \(err)")")
                self.view.status = ok ? "\(what): done." : "\(what): \(err)"
                self.display.removeFileDescriptor(sock); close(sock)
                self.refresh()
            }
        }
        window?.setNeedsDisplay()
    }

    private func latestSnapshot(_ d: ZFSDataset) -> ZFSSnapshot? { view.volumes.snapshots(of: d.name).last }

    private func perform(_ verb: String) -> CommandResult {
        switch verb {
        case DiskUtilityVerb.quit, DiskUtilityVerb.close: onQuit(); return .ok("")
        case DiskUtilityVerb.minimize: _ = window?.minimize(); return .ok("")
        case DiskUtilityVerb.refresh: refresh(); return .ok("")
        case DiskUtilityVerb.snapshot:
            guard let d = view.selectedDataset else { return .refused("no dataset is selected") }
            var t = time(nil), tm = tm()
            localtime_r(&t, &tm)
            let name = Volumes.snapshotName(year: Int(tm.tm_year) + 1900, month: Int(tm.tm_mon) + 1, day: Int(tm.tm_mday),
                                            hour: Int(tm.tm_hour), minute: Int(tm.tm_min), second: Int(tm.tm_sec))
            send(.snapshot(dataset: d.name, name: name), "snapshot \(d.name)@\(name)")
            return .ok("")
        case DiskUtilityVerb.mount:
            guard let d = view.selectedDataset else { return .refused("no dataset is selected") }
            send(d.mounted ? .unmountDataset(d.name) : .mountDataset(d.name), "\(d.mounted ? "unmount" : "mount") \(d.name)")
            return .ok("")
        case DiskUtilityVerb.rollback:
            guard let d = view.selectedDataset, let latest = latestSnapshot(d) else { return .refused("there is no snapshot to roll back to") }
            if let s = view.selectedSnapshot, s != latest.name {
                return .refused("only the latest snapshot (\(latest.short)) can be rolled back to; the ones after it would be destroyed")
            }
            askingRollback = latest.name
            Self.log("asked to roll back to \(latest.name)")
            window?.setNeedsDisplay()
            return .ok("")
        default: return .refused("Disk Utility has no verb \(verb)")
        }
    }

    // MARK: WindowDelegate

    public func render(_ buffer: PixelBuffer) {
        Text.renderScale = buffer.scale
        let w = Double(buffer.width / buffer.scale), h = Double(buffer.height / buffer.scale)
        let cs = cairo_image_surface_create_for_data(buffer.data.assumingMemoryBound(to: UInt8.self),
                                                     CAIRO_FORMAT_ARGB32, buffer.width, buffer.height, buffer.stride)
        guard let cr = cairo_create(cs) else { cairo_surface_destroy(cs); return }
        cairo_scale(cr, Double(buffer.scale), Double(buffer.scale))
        cairo_save(cr); cairo_set_operator(cr, CAIRO_OPERATOR_CLEAR); cairo_paint(cr); cairo_restore(cr)
        cairo_set_operator(cr, CAIRO_OPERATOR_OVER)
        let l = paintDiskUtility(cr, w: w, h: h, view: view)
        var sheet: RollbackSheetLayout?
        if let s = askingRollback { sheet = paintRollbackSheet(cr, w: w, snapshot: s) }
        cairo_surface_flush(cs); cairo_destroy(cr); cairo_surface_destroy(cs)
        if dump { dumpLayout(l, w: w, sheet: sheet) }
    }

    private func sidebarRows(_ l: DiskUtilityLayout) -> [(item: VolumeItem, y: Double)] {
        var y = l.sidebar.y + 8 + 18
        var out: [(VolumeItem, Double)] = []
        if view.disksUnavailable != nil { y += l.rowHeight }
        for d in view.disks { out.append((.disk(d), y)); y += l.rowHeight }
        y += 6 + 18
        if view.volumes.unavailable != nil { y += l.rowHeight }
        for d in view.volumes.datasets { out.append((.dataset(d), y)); y += l.rowHeight }
        return out
    }

    private func dumpLayout(_ l: DiskUtilityLayout, w: Double, sheet: RollbackSheetLayout?) {
        func c(_ r: Rect) -> String { "\(Int(r.x + r.w / 2)),\(Int(r.y + r.h / 2))" }
        var line = "buttons mount=\(c(l.mount)) snapshot=\(c(l.snapshot)) rollback=\(c(l.rollback)); sidebar"
        for (item, y) in sidebarRows(l) {
            if case .dataset(let d) = item { line += " \(d.name)@\(Int(y + l.rowHeight / 2))" }
        }
        if let d = view.selectedDataset {
            line += "; snapshots of \(d.name):"
            for (i, s) in view.volumes.snapshots(of: d.name).reversed().enumerated() {
                line += " \(s.short)@\(Int(l.snapshots.y + Double(i) * l.rowHeight + l.rowHeight / 2))"
            }
        }
        if let s = sheet { line += "; sheet rollback=\(c(s.rollback)) cancel=\(c(s.cancel))" }
        guard line != lastDump else { return }
        lastDump = line
        Self.log(line)
    }

    public func pointerMoved(x: Double, y: Double) { pointerX = x; pointerY = y }

    public func pointerButton(_ button: UInt32, pressed: Bool) {
        guard pressed, let w = window else { return }
        let W = Double(w.size.width), H = Double(w.size.height)
        switch windowChromeHit(x: pointerX, y: pointerY, w: W, h: H) {
        case .close: onQuit(); return
        case .minimize: _ = w.minimize(); return
        case .zoom: w.setMaximized(!w.isMaximized); return
        case .depth: _ = w.lower(); return
        case .title: w.beginMove(); return
        case .resize(let e): w.beginResize(e); return
        case .pill, .content: break
        }
        guard button == 0x110 else { return }
        if let s = askingRollback {
            let sl = RollbackSheetLayout(w: W)
            if sl.rollback.contains(pointerX, pointerY) {
                askingRollback = nil
                send(.rollback(snapshot: s), "roll back to \(s)")
            } else if sl.cancel.contains(pointerX, pointerY) {
                askingRollback = nil; Self.log("rollback cancelled")
            }
            window?.setNeedsDisplay()
            return
        }
        let l = DiskUtilityLayout(w: W, h: H)
        if l.sidebar.contains(pointerX, pointerY) {
            if let hit = sidebarRows(l).first(where: { pointerY >= $0.y && pointerY < $0.y + l.rowHeight }) {
                view.selected = hit.item.key; view.selectedSnapshot = nil
                if case .dataset(let d) = hit.item { Self.log("selected \(d.name)") }
                window?.setNeedsDisplay()
            }
            return
        }
        if let d = view.selectedDataset {
            if l.mount.contains(pointerX, pointerY) { report(perform(DiskUtilityVerb.mount)); return }
            if l.snapshot.contains(pointerX, pointerY) { report(perform(DiskUtilityVerb.snapshot)); return }
            if l.rollback.contains(pointerX, pointerY) { report(perform(DiskUtilityVerb.rollback)); return }
            if l.snapshots.contains(pointerX, pointerY) {
                let i = Int((pointerY - l.snapshots.y) / l.rowHeight)
                let snaps = Array(view.volumes.snapshots(of: d.name).reversed())
                if i < snaps.count { view.selectedSnapshot = snaps[i].name; window?.setNeedsDisplay() }
            }
        }
    }

    private func report(_ r: CommandResult) {
        if case .refused(let why) = r { view.status = why; Self.log("refused: \(why)"); window?.setNeedsDisplay() }
    }

    public func keyEvent(_ event: KeyEvent) {
        guard event.pressed else { return }
        if let s = askingRollback {
            if event.keysym == KeySym.enter { askingRollback = nil; send(.rollback(snapshot: s), "roll back to \(s)") }
            else if event.keysym == KeySym.escape { askingRollback = nil; Self.log("rollback cancelled") }
            window?.setNeedsDisplay()
            return
        }
        if event.modifiers.contains(.command), let press = keyEquivalent(event), let verb = Self.menuBar.verb(for: press) {
            report(perform(verb))
        }
    }

    public func windowShouldClose(_ window: Window) { onQuit() }

    // MARK: MenuProvider

    public var menuModel: MenuBarModel { Self.menuBar }

    public func menuValidate(_ command: Command) -> Enablement {
        switch command.verb {
        case DiskUtilityVerb.about: return .disabled("Disk Utility has no About box yet")
        case DiskUtilityVerb.snapshot, DiskUtilityVerb.mount:
            return view.selectedDataset == nil ? .disabled("no dataset is selected") : .enabled
        case DiskUtilityVerb.rollback:
            guard let d = view.selectedDataset else { return .disabled("no dataset is selected") }
            return latestSnapshot(d) == nil ? .disabled("it has no snapshots") : .enabled
        default: return .enabled
        }
    }

    public func menuPerform(_ command: Command, arguments: [String: String]) -> CommandResult {
        if case .disabled(let why) = menuValidate(command) { return .refused(why) }
        return perform(command.verb)
    }
}

/// "Roll back to …?" — the changes since the snapshot are lost.
public struct RollbackSheetLayout: Equatable, Sendable {
    public let panel: Rect, rollback: Rect, cancel: Rect
    public init(w: Double) {
        let pw = min(460, w - 40), ph = 116.0
        panel = Rect((w - pw) / 2, Theme.titleBarHeight, pw, ph)
        rollback = Rect(panel.x + pw - 112, panel.y + ph - 40, 98, 26)
        cancel = Rect(rollback.x - 92, panel.y + ph - 40, 82, 26)
    }
}

func paintRollbackSheet(_ cr: OpaquePointer, w: Double, snapshot: String) -> RollbackSheetLayout {
    let l = RollbackSheetLayout(w: w)
    Draw.setColor(cr, Color(0, 0, 0, 0.18)); cairo_rectangle(cr, l.panel.x + 2, l.panel.y, l.panel.w, l.panel.h + 3); cairo_fill(cr)
    Draw.setColor(cr, Color(hex: 0xECECEC)); cairo_rectangle(cr, l.panel.x, l.panel.y, l.panel.w, l.panel.h); cairo_fill(cr)
    Draw.textLeft(cr, "Roll back to \(snapshot)?", x: l.panel.x + 18, baselineY: l.panel.y + 30,
                  color: Theme.bodyText, size: Theme.fontSize, style: .bold)
    Draw.textLeft(cr, "Everything changed in it since the snapshot will be lost.",
                  x: l.panel.x + 18, baselineY: l.panel.y + 50, color: Theme.bodyText, size: Theme.fontSize - 1)
    Draw.gelButton(cr, l.cancel, label: "Cancel", blue: false, pressed: false)
    Draw.gelButton(cr, l.rollback, label: "Roll Back", blue: true, pressed: false)
    return l
}
