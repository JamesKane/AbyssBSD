// Undertow — the compositor proper: real clients, a real scene (PHASE6.md P6.3).
//
// This is where `undertow` stops being a frame scheduler with a test pattern and
// becomes something an application can connect to. Three things arrive together
// because none of them is useful alone:
//
//   1. the `wl_compositor` and `xdg_shell` globals, and a socket to reach them;
//   2. a **scene** — our own structure-of-arrays, not `wlr_scene`;
//   3. a render step that textures each mapped surface into the frame.
//
// **We do not use `wlr_scene`,** and that is the deliberate line DESKTOP.md §2
// draws: wlroots owns the plumbing, we own the scene, the scheduler and the
// present path. `wlr_scene` is a perfectly good retained scene graph, and taking
// it would hand away exactly the part the performance contract is about.

import CWlroots

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// One mapped toplevel window.
///
/// A class because wlroots listeners need a stable context pointer, and because
/// its lifetime is the surface's, not the frame's.
public final class Toplevel {
    let xdgToplevel: UnsafeMutablePointer<wlr_xdg_toplevel>
    public let surface: UnsafeMutablePointer<wlr_surface>
    /// Position in output coordinates, chosen by us — a client cannot place its
    /// own window, which is precisely the power a compositor has and a Wayland
    /// client does not (HANDOFF §2.22).
    public var x: Int32 = 0
    public var y: Int32 = 0
    public private(set) var mapped = false
    /// What the client calls itself, and what it calls this window. Together
    /// they are the key a remembered position is stored under.
    public var appID: String? { xdgToplevel.pointee.app_id.map { String(cString: $0) } }
    public var title: String? { xdgToplevel.pointee.title.map { String(cString: $0) } }
    public var placeKey: String? { WindowPlaces.key(appID: appID, title: title) }

    private unowned let compositor: Compositor
    private var listeners: [UnsafeMutablePointer<tw_listener>?] = []

    init(_ toplevel: UnsafeMutablePointer<wlr_xdg_toplevel>, compositor: Compositor) {
        self.xdgToplevel = toplevel
        self.surface = toplevel.pointee.base.pointee.surface
        self.compositor = compositor

        let me = Unmanaged.passUnretained(self).toOpaque()
        listeners.append(tw_listen(&surface.pointee.events.map, { ctx, _ in
            guard let ctx else { return }
            let t = Unmanaged<Toplevel>.fromOpaque(ctx).takeUnretainedValue()
            t.mapped = true
            t.compositor.place(t)
        }, me))
        listeners.append(tw_listen(&surface.pointee.events.unmap, { ctx, _ in
            guard let ctx else { return }
            Unmanaged<Toplevel>.fromOpaque(ctx).takeUnretainedValue().mapped = false
        }, me))
        listeners.append(tw_listen(&surface.pointee.events.commit, { ctx, _ in
            guard let ctx else { return }
            let t = Unmanaged<Toplevel>.fromOpaque(ctx).takeUnretainedValue()
            // xdg-shell requires the compositor to answer a client's first
            // commit with a configure before the client may attach a buffer.
            // Miss this and the client waits for ever having done nothing
            // wrong — a hang with no error anywhere.
            if t.xdgToplevel.pointee.base.pointee.initial_commit {
                _ = wlr_xdg_toplevel_set_size(t.xdgToplevel, 0, 0)  // 0,0: you choose
            }
        }, me))
        listeners.append(tw_listen(&toplevel.pointee.events.destroy, { ctx, _ in
            guard let ctx else { return }
            let t = Unmanaged<Toplevel>.fromOpaque(ctx).takeUnretainedValue()
            // Remember where it was BEFORE letting go of it: after `forget` the
            // title and app_id are gone and there is no key left to store under.
            t.compositor.rememberPlace(of: t)
            t.mapped = false
            t.compositor.forget(t)
        }, me))
        // Interactive move — the client asks, the compositor does. `xdg_toplevel`
        // has no set-position for a reason: only the compositor may place a
        // window, which is why remembering a position had to wait for this phase
        // (HANDOFF §2.22).
        listeners.append(tw_listen(&toplevel.pointee.events.request_move, { ctx, _ in
            guard let ctx else { return }
            let t = Unmanaged<Toplevel>.fromOpaque(ctx).takeUnretainedValue()
            t.compositor.beginMove(t)
        }, me))
    }

    /// Free the listeners before the object they point at goes away. §2.2/§2.35,
    /// for the third time in this project — it is always this.
    func teardown() {
        for l in listeners { tw_listener_free(l) }
        listeners.removeAll()
    }

    deinit { teardown() }

    /// The surface's current buffer size, in surface-local pixels.
    public var width: Int32 { surface.pointee.current.width }
    public var height: Int32 { surface.pointee.current.height }
}

/// The compositor: globals, a socket, and the list of windows.
public final class Compositor {
    public let session: WlrootsSession
    private var xdgShell: UnsafeMutablePointer<wlr_xdg_shell>?
    private var newToplevelListener: UnsafeMutablePointer<tw_listener>?
    private var newSurfaceListener: UnsafeMutablePointer<tw_listener>?
    private var newLayerListener: UnsafeMutablePointer<tw_listener>?
    private var activationListener: UnsafeMutablePointer<tw_listener>?
    private var foreignManager: UnsafeMutablePointer<wlr_foreign_toplevel_manager_v1>?
    /// Shell surfaces (wallpaper, menu bar, Dock, toasts), in creation order.
    public private(set) var layers: [LayerSurface] = []
    /// The area a toplevel may use — the output minus every exclusive zone.
    /// A layer surface never appears in a window tree, so this rectangle is the
    /// only observable proof that the menu bar reserved its strip (§2.26).
    public private(set) var usableArea = Rect(x: 0, y: 0, width: 0, height: 0)
    /// How many surfaces clients have created since start-up.
    public private(set) var surfacesCreated = 0
    /// Every live toplevel, in creation order. Small by construction; a desktop
    /// has tens of windows, not thousands.
    public private(set) var toplevels: [Toplevel] = []
    /// The `WAYLAND_DISPLAY` value a client should connect to.
    public private(set) var socketName: String = ""

    private let outputWidth: Int32
    private let outputHeight: Int32
    private var cascade: Int32 = 0
    /// Remembered window positions, persisted through PoolConfig.
    public let places: WindowPlaces
    /// The window being dragged, and the pointer offset within it.
    public private(set) var moving: Toplevel?
    private var moveDX: Double = 0
    private var moveDY: Double = 0
    /// Set when a window is restored to a remembered position rather than
    /// cascaded — the observable difference a test can assert on.
    public private(set) var restoredCount = 0

    public init(session: WlrootsSession, outputWidth: Int32, outputHeight: Int32,
                configDir: String? = nil) throws {
        self.places = WindowPlaces(configDir: configDir)
        self.session = session
        self.outputWidth = outputWidth
        self.outputHeight = outputHeight
        // Until a layer surface reserves anything, the whole output is usable.
        self.usableArea = Rect(x: 0, y: 0, width: outputWidth, height: outputHeight)

        // wl_compositor at version 6, plus the pieces a real client expects to
        // find. `wlr_compositor_create` with a renderer is what makes wlroots
        // turn client buffers into textures for us on commit.
        guard let comp = wlr_compositor_create(session.display, 6, session.renderer)
        else { throw BackendError.noGlobals("wl_compositor") }
        _ = wlr_subcompositor_create(session.display)
        _ = wlr_data_device_manager_create(session.display)
        // **wl_shm, without which no client can attach a buffer.**
        // `wlr_compositor_create` does not create it, and its absence looks like
        // "the compositor is not a compositor": our own `Display.init` requires
        // compositor + shm + xdg_wm_base and refuses the connection outright, so
        // the client's error is "cannot connect", pointing nowhere near the
        // missing global. Every shm client — which is every client we have —
        // needs this line.
        _ = wlr_shm_create_with_renderer(session.display, 1, session.renderer)

        guard let shell = wlr_xdg_shell_create(session.display, 3) else {
            throw BackendError.noGlobals("xdg_wm_base")
        }
        xdgShell = shell

        let me = Unmanaged.passUnretained(self).toOpaque()
        // Every surface any client ever creates. Not used for rendering — it is
        // the POSITIVE CONTROL for adversarial load (PHASE6.md P6.5): a C2 bench
        // that only asserts "no frames were missed" passes just as happily when
        // the adversaries failed to connect at all.
        newSurfaceListener = tw_listen(&comp.pointee.events.new_surface, { ctx, _ in
            guard let ctx else { return }
            Unmanaged<Compositor>.fromOpaque(ctx).takeUnretainedValue().surfacesCreated += 1
        }, me)
        newToplevelListener = tw_listen(&shell.pointee.events.new_toplevel, { ctx, data in
            guard let ctx, let data else { return }
            let c = Unmanaged<Compositor>.fromOpaque(ctx).takeUnretainedValue()
            let t = data.assumingMemoryBound(to: wlr_xdg_toplevel.self)
            c.toplevels.append(Toplevel(t, compositor: c))
        }, me)

        // The three protocols the Aqua shell speaks that an ordinary app does
        // not: layer-shell for the wallpaper/menu bar/Dock/toasts,
        // foreign-toplevel so the Dock can see running apps, and xdg-activation
        // so the spatial Finder can raise a window it already has open.
        guard let layerShell = wlr_layer_shell_v1_create(session.display, 4) else {
            throw BackendError.noGlobals("zwlr_layer_shell_v1")
        }
        newLayerListener = tw_listen(&layerShell.pointee.events.new_surface, { ctx, data in
            guard let ctx, let data else { return }
            let c = Unmanaged<Compositor>.fromOpaque(ctx).takeUnretainedValue()
            let l = data.assumingMemoryBound(to: wlr_layer_surface_v1.self)
            // A layer surface may name no output; it is ours to choose, and we
            // have exactly one.
            if l.pointee.output == nil { l.pointee.output = c.session.outputs.first }
            c.layers.append(LayerSurface(l, compositor: c))
        }, me)

        foreignManager = wlr_foreign_toplevel_manager_v1_create(session.display)

        // wlr-screencopy, server side — PHASE7 §6.6's debt, handed to this phase
        // when P7.5 bound the *client* half. Our `abyssgrab` and therefore the
        // whole screenshot portal work against undertow with no change at all.
        // (Upstream deprecates this protocol in favour of
        // ext-image-copy-capture-v1; moving both halves together is a later
        // decision, and the portal never sees either one.)
        _ = wlr_screencopy_manager_v1_create(session.display)

        if let activation = wlr_xdg_activation_v1_create(session.display) {
            activationListener = tw_listen(&activation.pointee.events.request_activate,
                                           { ctx, data in
                guard let ctx, let data else { return }
                let c = Unmanaged<Compositor>.fromOpaque(ctx).takeUnretainedValue()
                let ev = data.assumingMemoryBound(to: wlr_xdg_activation_v1_request_activate_event.self)
                // The sanctioned "raise my own window" path — the spatial
                // Finder uses it so re-opening an open folder brings its window
                // forward instead of making a second one (HANDOFF §2.22).
                guard let surface = ev.pointee.surface else { return }
                for t in c.toplevels where t.surface == surface { c.raise(t) }
            }, me)
        }

        guard let socket = wl_display_add_socket_auto(session.display) else {
            throw BackendError.noSocket
        }
        socketName = String(cString: socket)
    }

    deinit {
        tw_listener_free(newSurfaceListener)
        tw_listener_free(newToplevelListener)
        tw_listener_free(newLayerListener)
        tw_listener_free(activationListener)
        for t in toplevels { t.teardown() }
        for l in layers { l.teardown() }
    }

    // MARK: - Layer shell

    internal func forgetLayer(_ l: LayerSurface) {
        l.teardown()
        layers.removeAll { $0 === l }
        arrangeLayers()
    }

    /// Place every layer surface and recompute the usable area.
    ///
    /// Order matters and is the protocol's, not ours: surfaces are arranged
    /// **by layer, bottom to top**, and each exclusive zone shrinks the area for
    /// everyone arranged after it. That is why the menu bar (TOP, zone 22)
    /// reserves its strip while the Dock (also TOP, zone 0) simply overlaps —
    /// and why the desktop (BACKGROUND, zone -1) paints the whole output
    /// underneath regardless.
    public func arrangeLayers() {
        let full = Rect(x: 0, y: 0, width: outputWidth, height: outputHeight)
        var usable = full
        for l in layers.sorted(by: { $0.layer < $1.layer }) {
            let (rect, remaining) = LayerArrange.place(l.request, in: usable, output: full)
            // **Configure EVERY surface, reserve for MAPPED ones only.**
            //
            // An unmapped surface still needs its configure — that is how it
            // learns the size to draw at, and it cannot map until it has one.
            // The first version arranged only surfaces that were already mapped
            // or not yet initialized, which deadlocked precisely in between: a
            // surface that had been initialized but had not yet mapped was
            // skipped, never configured, and so could never map. The menu bar
            // came up and simply never appeared.
            l.configure(rect)
            if l.mapped { usable = remaining }
        }
        usableArea = usable
    }

    /// Layer surfaces with something to show, in paint order (bottom to top).
    public var mappedLayers: [LayerSurface] {
        layers.filter { $0.mapped && wlr_surface_has_buffer($0.surface) }
              .sorted { $0.layer < $1.layer }
    }

    /// Where a newly mapped window goes.
    ///
    /// Centred, then cascaded — the Mac's own rule, and a decision only a
    /// compositor can make. A Wayland client cannot position itself, which is
    /// why the spatial Finder's remembered positions have waited for this phase
    /// (HANDOFF §2.22); P6.7 is where that debt is paid.
    fileprivate func place(_ t: Toplevel) {
        // A remembered position wins. This is the spatial Finder's whole
        // behaviour — a folder's window reopens where you left it — and it is
        // the thing HANDOFF §2.22 recorded as waiting for a compositor of our
        // own, because xdg-shell gives a client no way to ask.
        if let key = t.placeKey, let remembered = places.place(forKey: key) {
            t.x = remembered.x
            t.y = remembered.y
            restoredCount += 1
            return
        }
        let w = t.width, h = t.height
        let offset = cascade * 24
        cascade = (cascade + 1) % 8
        // Centred in the USABLE area, not the output: a window that opened
        // under the menu bar would be the visible symptom of an exclusive zone
        // that was computed but never honoured.
        let area = usableArea
        t.x = max(area.x, area.x + (area.width - w) / 2 + offset)
        t.y = max(area.y, area.y + (area.height - h) / 2 + offset)
    }

    /// Persist a window's position under its key.
    func rememberPlace(of t: Toplevel) {
        guard let key = t.placeKey else { return }
        places.remember(WindowPlace(x: t.x, y: t.y), forKey: key)
    }

    // MARK: - Interactive move

    fileprivate func beginMove(_ t: Toplevel) {
        guard let seat else { return }
        moving = t
        moveDX = seat.cursorX - Double(t.x)
        moveDY = seat.cursorY - Double(t.y)
        raise(t)
    }

    /// Follow the pointer. Called from the seat on every motion.
    func updateMove(cursorX: Double, cursorY: Double) {
        guard let t = moving else { return }
        // Clamp so a window can never be dragged entirely off the output and
        // become unreachable — a compositor's job, and one a client could not do
        // for itself even if it wanted to.
        let maxX = Double(outputWidth - 1), maxY = Double(outputHeight - 1)
        t.x = Int32(min(max(cursorX - moveDX, Double(1 - t.width)), maxX))
        t.y = Int32(min(max(cursorY - moveDY, Double(usableArea.y)), maxY))
    }

    /// End the drag and remember where it landed.
    func endMove() {
        guard let t = moving else { return }
        moving = nil
        rememberPlace(of: t)
    }

    /// The seat, once one exists — set by `Seat.init`.
    weak var seat: Seat?

    fileprivate func forget(_ t: Toplevel) {
        t.teardown()
        toplevels.removeAll { $0 === t }
    }

    /// Move a window to the top of the stack.
    ///
    /// `toplevels` is in bottom-to-top order and the scene walks it forwards, so
    /// raising is simply moving to the end — the stacking order and the paint
    /// order are the same list, which is the cheapest way to keep them from
    /// disagreeing.
    public func raise(_ t: Toplevel) {
        guard let i = toplevels.firstIndex(where: { $0 === t }), i != toplevels.count - 1
        else { return }
        toplevels.remove(at: i)
        toplevels.append(t)
    }

    /// Windows that currently have something to show, bottom to top.
    public var mappedToplevels: [Toplevel] {
        toplevels.filter { $0.mapped && wlr_surface_has_buffer($0.surface) }
    }

    /// Tell every mapped client the frame is done, so it draws the next one.
    ///
    /// Without this a client renders exactly one frame and then waits for ever
    /// for a callback that never comes. The symptom is a compositor that looks
    /// like it works — the first frame is correct — and a client that appears
    /// to have hung.
    public func sendFrameDone() {
        var now = timespec()
        clock_gettime(CLOCK_MONOTONIC, &now)
        for t in mappedToplevels {
            wlr_surface_send_frame_done(t.surface, &now)
        }
        for l in mappedLayers {
            wlr_surface_send_frame_done(l.surface, &now)
        }
    }

    /// Close out a frame: release clients to draw the next one, then push the
    /// queued protocol events down their sockets.
    ///
    /// One call rather than two so a caller cannot do half of it — a frame-done
    /// that is never flushed leaves the client waiting exactly as if it had
    /// never been sent, which is a hang with no fingerprints.
    public func endFrame() {
        sendFrameDone()
        wl_display_flush_clients(session.display)
    }
}
