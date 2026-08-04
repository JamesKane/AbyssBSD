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
            t.mapped = false
            t.compositor.forget(t)
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

    public init(session: WlrootsSession, outputWidth: Int32, outputHeight: Int32) throws {
        self.session = session
        self.outputWidth = outputWidth
        self.outputHeight = outputHeight

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

        guard let socket = wl_display_add_socket_auto(session.display) else {
            throw BackendError.noSocket
        }
        socketName = String(cString: socket)
    }

    deinit {
        tw_listener_free(newSurfaceListener)
        tw_listener_free(newToplevelListener)
        for t in toplevels { t.teardown() }
    }

    /// Where a newly mapped window goes.
    ///
    /// Centred, then cascaded — the Mac's own rule, and a decision only a
    /// compositor can make. A Wayland client cannot position itself, which is
    /// why the spatial Finder's remembered positions have waited for this phase
    /// (HANDOFF §2.22); P6.7 is where that debt is paid.
    fileprivate func place(_ t: Toplevel) {
        let w = t.width, h = t.height
        let offset = cascade * 24
        cascade = (cascade + 1) % 8
        t.x = max(0, (outputWidth - w) / 2 + offset)
        t.y = max(0, (outputHeight - h) / 2 + offset)
    }

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
