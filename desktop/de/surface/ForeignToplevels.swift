// Surface.ForeignToplevels — tracks the compositor's open toplevels via
// wlr-foreign-toplevel-management, so the shell (the Dock, a taskbar) can show
// running apps and activate one. The compositor advertises a handle per
// toplevel with title/app_id/state; we mirror those and notify a delegate on
// each atomic `done`.
//
// The manager global is captured by Display (name+version) but bound HERE, so
// the manager listener is attached in the same step — otherwise the `toplevel`
// events the compositor sends for already-open windows would hit a NULL listener
// and abort (the §2.3 trap). Bound at v3, so every handle event slot
// (title/app_id/output_enter/output_leave/state/done/closed/parent) needs a
// handler.

import CWayland

/// A tracked toplevel window (reference type so the delegate can hold it).
public final class ToplevelInfo {
    public let handle: OpaquePointer
    public internal(set) var appID = ""
    public internal(set) var title = ""
    public internal(set) var activated = false
    init(handle: OpaquePointer) { self.handle = handle }
}

public protocol ForeignToplevelsDelegate: AnyObject {
    /// The set of open toplevels changed (added / removed / retitled / state).
    func toplevelsChanged(_ toplevels: [ToplevelInfo])
}

public final class ForeignToplevels {
    private let display: Display
    private let manager: OpaquePointer
    public weak var delegate: ForeignToplevelsDelegate?

    // Insertion-ordered list of live toplevels.
    private var toplevels: [ToplevelInfo] = []

    /// Bind the foreign-toplevel manager and start listening. Returns nil if the
    /// compositor doesn't offer it.
    public init?(display: Display, delegate: ForeignToplevelsDelegate? = nil) {
        guard let (name, version) = display.foreignToplevelManager,
              let mgr = wlBind(display.registry, name, zwlr_foreign_toplevel_manager_v1_iface, version)
        else { return nil }
        self.display = display
        self.manager = mgr
        self.delegate = delegate

        let me = Unmanaged.passUnretained(self).toOpaque()
        var ml = zwlr_foreign_toplevel_manager_v1_listener()
        ml.toplevel = { data, _, handle in
            guard let data, let handle else { return }
            let ft = Unmanaged<ForeignToplevels>.fromOpaque(data).takeUnretainedValue()
            ft.addToplevel(handle)
        }
        ml.finished = { _, _ in }
        display.addListener(to: mgr, listener: ml, data: me)
    }

    /// Currently-open toplevels (snapshot).
    public var current: [ToplevelInfo] { toplevels }

    /// Activate the first toplevel with `appID` (raise/focus it).
    @discardableResult
    public func activate(appID: String) -> Bool {
        guard let seat = display.seat,
              let info = toplevels.first(where: { $0.appID == appID }) else { return false }
        zwlr_foreign_toplevel_handle_v1_activate(info.handle, seat)
        return true
    }

    /// Ask every window of `appID` to close — Quit from a Dock tile (P10.8).
    /// A polite request each application may refuse; Force Quit is the
    /// compositor's, not this. Returns how many windows were asked.
    @discardableResult
    public func close(appID: String) -> Int {
        let mine = toplevels.filter { $0.appID == appID }
        for info in mine { zwlr_foreign_toplevel_handle_v1_close(info.handle) }
        display.flush()
        return mine.count
    }

    /// Activate a specific tracked toplevel.
    public func activate(_ info: ToplevelInfo) {
        guard let seat = display.seat else { return }
        zwlr_foreign_toplevel_handle_v1_activate(info.handle, seat)
    }

    // MARK: handle bookkeeping

    private func addToplevel(_ handle: OpaquePointer) {
        let info = ToplevelInfo(handle: handle)
        toplevels.append(info)

        let me = Unmanaged.passUnretained(self).toOpaque()
        var hl = zwlr_foreign_toplevel_handle_v1_listener()
        hl.title = { data, h, title in
            guard let data, let h, let title else { return }
            let ft = Unmanaged<ForeignToplevels>.fromOpaque(data).takeUnretainedValue()
            ft.find(h)?.title = String(cString: title)
        }
        hl.app_id = { data, h, appID in
            guard let data, let h, let appID else { return }
            let ft = Unmanaged<ForeignToplevels>.fromOpaque(data).takeUnretainedValue()
            ft.find(h)?.appID = String(cString: appID)
        }
        hl.output_enter = { _, _, _ in }
        hl.output_leave = { _, _, _ in }
        hl.state = { data, h, array in
            guard let data, let h, let array else { return }
            let ft = Unmanaged<ForeignToplevels>.fromOpaque(data).takeUnretainedValue()
            ft.updateState(h, array: array)
        }
        hl.done = { data, _ in
            guard let data else { return }
            let ft = Unmanaged<ForeignToplevels>.fromOpaque(data).takeUnretainedValue()
            ft.notify()
        }
        hl.closed = { data, h in
            guard let data, let h else { return }
            let ft = Unmanaged<ForeignToplevels>.fromOpaque(data).takeUnretainedValue()
            ft.removeToplevel(h)
        }
        hl.parent = { _, _, _ in }
        display.addListener(to: handle, listener: hl, data: me)
    }

    private func find(_ handle: OpaquePointer) -> ToplevelInfo? {
        toplevels.first { $0.handle == handle }
    }

    private func updateState(_ handle: OpaquePointer,
                             array: UnsafeMutablePointer<wl_array>) {
        guard let info = find(handle) else { return }
        // wl_array of uint32 state enums; ACTIVATED == 2.
        let count = array.pointee.size / MemoryLayout<UInt32>.size
        var activated = false
        if let base = array.pointee.data?.assumingMemoryBound(to: UInt32.self) {
            for i in 0..<count where base[i] == 2 { activated = true }
        }
        info.activated = activated
    }

    private func removeToplevel(_ handle: OpaquePointer) {
        guard let i = toplevels.firstIndex(where: { $0.handle == handle }) else { return }
        toplevels.remove(at: i)
        zwlr_foreign_toplevel_handle_v1_destroy(handle)
        notify()
    }

    private func notify() { delegate?.toplevelsChanged(toplevels) }
}
