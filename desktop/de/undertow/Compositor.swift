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
import AquaDraw

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

    /// **Minimized windows are not on screen and not under the pointer.** The
    /// flag lives here rather than in a list because everything that asks "what
    /// is showing" — the scene, the hit-test, the frame callbacks — asks through
    /// `mappedToplevels`, and one flag keeps them from disagreeing. The one
    /// exception is on purpose: a minimized window still gets a frame callback
    /// once a second (`sendFrameDone`, U.2), because withholding it hangs a
    /// client that waits for one.
    public internal(set) var minimized = false
    /// The island it is on (PHASE13 P13.1), of the display it lives on
    /// (`islandDisplay`, settled when it maps and when a drag ends). Hidden
    /// unless that display is showing that island — `mappedToplevels`.
    public internal(set) var island = 1
    public internal(set) var islandDisplay = ""
    /// What we last told the client about xdg-shell's `suspended`.
    var suspendedSaid = false
    /// When this window, minimized, last got a frame callback — the hidden
    /// clock's last tick (U.2), in monotonic nanoseconds.
    var hiddenFrameAt: UInt64 = 0
    public internal(set) var maximized = false
    /// Whether the compositor draws this window's frame (P9.6). Set when a
    /// client asks through `xdg-decoration` — our own Aqua windows never ask,
    /// because they draw their own chrome and always have.
    public internal(set) var decorated = false
    /// A decoration request waiting for this window's initial commit — see
    /// `Decorations.take`, and the assertion it exists to avoid.
    var decoration: UnsafeMutablePointer<wlr_xdg_toplevel_decoration_v1>?
    /// Where the window was before it was maximized or snapped, so unmaximizing
    /// puts it back rather than leaving it wherever the compositor decided.
    var restoreBox: Rect?

    /// This window's entry in `wlr-foreign-toplevel-management` — how the Dock
    /// learns that an application is running, and how a click on a tile reaches
    /// back to raise or un-minimize it. Created when the window maps, because a
    /// window nobody can see yet is not something to list.
    var foreign: UnsafeMutablePointer<wlr_foreign_toplevel_handle_v1>?
    private var foreignListeners: [UnsafeMutablePointer<tw_listener>?] = []

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
            t.compositor.settleIsland(t, fresh: true)
            t.publish()
        }, me))
        listeners.append(tw_listen(&surface.pointee.events.unmap, { ctx, _ in
            guard let ctx else { return }
            let t = Unmanaged<Toplevel>.fromOpaque(ctx).takeUnretainedValue()
            t.mapped = false
            t.withdraw()
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
                // What this compositor will do if asked — and not the window
                // menu, which it does not draw. Here and not at creation:
                // scheduling a configure before the first commit is an
                // assertion inside wlroots (P9.6).
                _ = wlr_xdg_toplevel_set_wm_capabilities(t.xdgToplevel,
                        UInt32(WLR_XDG_TOPLEVEL_WM_CAPABILITIES_MAXIMIZE.rawValue
                               | WLR_XDG_TOPLEVEL_WM_CAPABILITIES_FULLSCREEN.rawValue
                               | WLR_XDG_TOPLEVEL_WM_CAPABILITIES_MINIMIZE.rawValue))
                // ...and the decoration mode, which could not be answered
                // before this commit (P9.6).
                t.compositor.decorations?.answer(t)
                // The most room a window can have (T.3): the usable area of the
                // main display. A client choosing its own size keeps within it
                // — on a small display, a window that fits.
                let u = t.compositor.usableArea
                _ = wlr_xdg_toplevel_set_bounds(t.xdgToplevel, u.width, u.height)
                // And what the window asked for before this commit, which its
                // request handlers could not answer then (PHASE15 §4.2).
                let asked = t.xdgToplevel.pointee.requested
                if asked.fullscreen { t.compositor.setFullscreen(t, true) }
                else if asked.maximized { t.compositor.setMaximized(t, true) }
            }
            // **A window nobody can see drew anyway** (T.3): counted, so a test
            // can hold a client to xdg-shell's `suspended`.
            if t.minimized || !t.compositor.isOnActiveIsland(t),
               t.surface.pointee.current.committed & UInt32(WLR_SURFACE_STATE_BUFFER.rawValue) != 0 {
                t.compositor.hiddenCommits += 1
            }
            // A resize in progress: the client just told us the size it managed,
            // which is the only moment the anchored edge can be put back exactly
            // where it was (P9.4).
            t.compositor.resizeCommitted(t)
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
        // The rest of what a window may ask about itself (P9.4). Every one of
        // these was published and unanswered: the client sent the request, the
        // compositor had no listener, and nothing happened — which is why no
        // Aqua window could be resized, zoomed or minimized until now.
        listeners.append(tw_listen(&toplevel.pointee.events.request_resize, { ctx, data in
            guard let ctx, let data else { return }
            let t = Unmanaged<Toplevel>.fromOpaque(ctx).takeUnretainedValue()
            let ev = data.assumingMemoryBound(to: wlr_xdg_toplevel_resize_event.self)
            t.compositor.beginResize(t, edges: ev.pointee.edges)
        }, me))
        listeners.append(tw_listen(&toplevel.pointee.events.request_maximize, { ctx, _ in
            guard let ctx else { return }
            let t = Unmanaged<Toplevel>.fromOpaque(ctx).takeUnretainedValue()
            // **The client's own pending state is the request.** There is no
            // "unmaximize" event; both requests arrive here and the answer is in
            // `requested.maximized`. Answering with a configure is mandatory
            // even when we refuse, or the client waits for ever.
            // **Not before the first commit** (as P9.6's decorations): a
            // configure scheduled then is an assertion inside wlroots, and the
            // initial commit answers what was requested (below).
            guard t.xdgToplevel.pointee.base.pointee.initialized else { return }
            t.compositor.setMaximized(t, t.xdgToplevel.pointee.requested.maximized)
        }, me))
        listeners.append(tw_listen(&toplevel.pointee.events.request_minimize, { ctx, _ in
            guard let ctx else { return }
            let t = Unmanaged<Toplevel>.fromOpaque(ctx).takeUnretainedValue()
            guard t.xdgToplevel.pointee.base.pointee.initialized else { return }
            t.compositor.setMinimized(t, t.xdgToplevel.pointee.requested.minimized)
        }, me))
        listeners.append(tw_listen(&toplevel.pointee.events.request_fullscreen, { ctx, _ in
            guard let ctx else { return }
            let t = Unmanaged<Toplevel>.fromOpaque(ctx).takeUnretainedValue()
            // Firefox's `--kiosk` asks for fullscreen before its first commit,
            // and this took undertow down (PHASE15 §4.2).
            guard t.xdgToplevel.pointee.base.pointee.initialized else { return }
            t.compositor.setFullscreen(t, t.xdgToplevel.pointee.requested.fullscreen)
        }, me))
        // A window that renames itself must rename its Dock tile too.
        listeners.append(tw_listen(&toplevel.pointee.events.set_title, { ctx, _ in
            guard let ctx else { return }
            Unmanaged<Toplevel>.fromOpaque(ctx).takeUnretainedValue().describe()
        }, me))
        listeners.append(tw_listen(&toplevel.pointee.events.set_app_id, { ctx, _ in
            guard let ctx else { return }
            let t = Unmanaged<Toplevel>.fromOpaque(ctx).takeUnretainedValue()
            t.describe()
            // The bar names the frontmost application by it (P10.3).
            if t.compositor.seat?.focused === t { t.compositor.menus?.focusChanged() }
        }, me))
    }

    /// Free the listeners before the object they point at goes away. §2.2/§2.35,
    /// for the third time in this project — it is always this.
    func teardown() {
        withdraw()
        for l in listeners { tw_listener_free(l) }
        listeners.removeAll()
    }

    // MARK: - foreign-toplevel: how the Dock sees this window

    /// Announce this window to the shell, and listen for what the shell asks.
    ///
    /// **The manager global was created and no handle was ever made**, so under
    /// our own compositor the Dock showed no running applications, its tiles had
    /// no dots, and clicking one could not raise anything. Every test that
    /// proved otherwise ran on sway. The same shape as §2.56, found in the same
    /// pass and for the same reason: minimize needs somewhere to go, and the
    /// somewhere is a tile that has to exist.
    func publish() {
        guard foreign == nil, let manager = compositor.foreignManager else { return }
        guard let handle = wlr_foreign_toplevel_handle_v1_create(manager) else { return }
        foreign = handle
        describe()
        let me = Unmanaged.passUnretained(self).toOpaque()
        foreignListeners.append(tw_listen(&handle.pointee.events.request_activate,
                                          { ctx, _ in
            guard let ctx else { return }
            let t = Unmanaged<Toplevel>.fromOpaque(ctx).takeUnretainedValue()
            // A click on a Dock tile. Its island first, then un-minimize:
            // raising a window that is not on screen is a click that appears
            // to do nothing (PHASE13 §6.3: a window is never lost).
            t.compositor.bringToFront(t)
        }, me))
        foreignListeners.append(tw_listen(&handle.pointee.events.request_close, { ctx, _ in
            guard let ctx else { return }
            let t = Unmanaged<Toplevel>.fromOpaque(ctx).takeUnretainedValue()
            wlr_xdg_toplevel_send_close(t.xdgToplevel)
        }, me))
        foreignListeners.append(tw_listen(&handle.pointee.events.request_minimize,
                                          { ctx, data in
            guard let ctx, let data else { return }
            let t = Unmanaged<Toplevel>.fromOpaque(ctx).takeUnretainedValue()
            let ev = data.assumingMemoryBound(
                to: wlr_foreign_toplevel_handle_v1_minimized_event.self)
            t.compositor.setMinimized(t, ev.pointee.minimized)
        }, me))
        foreignListeners.append(tw_listen(&handle.pointee.events.request_maximize,
                                          { ctx, data in
            guard let ctx, let data else { return }
            let t = Unmanaged<Toplevel>.fromOpaque(ctx).takeUnretainedValue()
            let ev = data.assumingMemoryBound(
                to: wlr_foreign_toplevel_handle_v1_maximized_event.self)
            t.compositor.setMaximized(t, ev.pointee.maximized)
        }, me))
    }

    /// Keep the tile's label honest.
    func describe() {
        guard let handle = foreign else { return }
        wlr_foreign_toplevel_handle_v1_set_title(handle, title ?? "")
        wlr_foreign_toplevel_handle_v1_set_app_id(handle, appID ?? "")
    }

    /// Tell the shell what this window now is.
    func republish() {
        guard let handle = foreign else { return }
        wlr_foreign_toplevel_handle_v1_set_minimized(handle, minimized)
        wlr_foreign_toplevel_handle_v1_set_maximized(handle, maximized)
    }

    func setForeignActivated(_ on: Bool) {
        guard let handle = foreign else { return }
        wlr_foreign_toplevel_handle_v1_set_activated(handle, on)
    }

    /// The window is gone: take the tile with it, listeners first (§2.2).
    func withdraw() {
        for l in foreignListeners { tw_listener_free(l) }
        foreignListeners.removeAll()
        if let handle = foreign { wlr_foreign_toplevel_handle_v1_destroy(handle) }
        foreign = nil
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
    private var newPopupListener: UnsafeMutablePointer<tw_listener>?
    /// Every popup any client has made, in creation order (P10.4).
    public internal(set) var popups: [PopupSurface] = []
    /// How many popups have ever mapped — the witness a test asserts on, since
    /// a popup that opened and closed leaves no other trace.
    public internal(set) var popupsMapped = 0
    private var restoreTimer: OpaquePointer?
    private var activationListener: UnsafeMutablePointer<tw_listener>?
    fileprivate var foreignManager: UnsafeMutablePointer<wlr_foreign_toplevel_manager_v1>?
    /// Shell surfaces (wallpaper, menu bar, Dock, toasts), in creation order.
    public private(set) var layers: [LayerSurface] = []
    /// The area a toplevel may use on each display — the display minus every
    /// exclusive zone on it. A layer surface never appears in a window tree, so
    /// these rectangles are the only observable proof that the menu bar
    /// reserved its strip (§2.26).
    public private(set) var usable: [String: Rect] = [:]
    /// The main display's usable area — where new windows open, and what a
    /// desktop of one output has always reported.
    public var usableArea: Rect {
        guard let m = layout.main else { return Rect(x: 0, y: 0, width: 0, height: 0) }
        return usable[m.name] ?? m.rect
    }
    /// The usable area of the display a point is on (or the nearest one).
    public func usableArea(at x: Double, _ y: Double) -> Rect {
        let (cx, cy) = layout.clamp(x, y)
        guard let d = layout.display(at: cx, cy) else { return usableArea }
        return usable[d.name] ?? d.rect
    }
    /// How many surfaces clients have created since start-up.
    public private(set) var surfacesCreated = 0
    /// Every live toplevel, in creation order. Small by construction; a desktop
    /// has tens of windows, not thousands.
    public private(set) var toplevels: [Toplevel] = []
    /// The `WAYLAND_DISPLAY` value a client should connect to.
    public private(set) var socketName: String = ""

    /// Where every output sits (P14.7a). The first is the main display.
    public private(set) var layout: DisplayLayout
    /// wlroots' own copy of the same arrangement, which `xdg-output` reports to
    /// clients (and, in P14.7b, output management reads).
    public private(set) var outputLayout: UnsafeMutablePointer<wlr_output_layout>?
    /// wlr-output-management-v1 (P14.7b): how the Displays pane, wlr-randr and
    /// kanshi rearrange the outputs.
    public private(set) var outputManagement: OutputManagement?
    private var cascade: Int32 = 0
    /// Remembered window positions, persisted through PoolConfig.
    public let places: WindowPlaces
    /// The renderer the frame textures are uploaded to (P9.6). The session owns
    /// it; the scene needs it at latch time, and reaching through `session`
    /// there would put a `let` from another file on the frame path.
    var rendererForFrames: UnsafeMutablePointer<wlr_renderer>? { session.renderer }
    /// Server-side decorations: the manager, and the frame textures (P9.6).
    public private(set) var decorations: Decorations?
    /// Where this compositor's configuration lives (nil = the user's own).
    /// The keybind table is read from here, and re-read when it changes.
    public private(set) var configDir: String?
    /// The window being dragged, and the pointer offset within it.
    public private(set) var moving: Toplevel?
    /// Islands (PHASE13 P13.1): the count and names, and what each display is
    /// showing, by display name. See Islands.swift.
    public internal(set) var islands: IslandsConfig
    var activeIslands: [String: Int] = [:]
    /// Switches asked for and not yet latched, by display (C6).
    var islandInputs: [String: UInt64] = [:]
    public internal(set) var islandSwitches = 0
    private var moveDX: Double = 0
    private var moveDY: Double = 0
    /// The window being resized, which edges are being dragged, and the box it
    /// started from. The *anchored* edges are what this remembers: a resize from
    /// the left moves the left edge and must leave the right one exactly where
    /// it was, and doing that from the live size drifts by a pixel a frame.
    public private(set) var resizing: Toplevel?
    private var resizeEdges: UInt32 = 0
    private var resizeStartX: Double = 0
    private var resizeStartY: Double = 0
    private var resizeStartBox = Rect(x: 0, y: 0, width: 0, height: 0)
    private var resizeAnchorRight: Int32 = 0
    private var resizeAnchorBottom: Int32 = 0
    /// How many times each of these has happened — the positive controls, for
    /// the same reason `selectionsAccepted` and `dragsStarted` are (§2.37).
    public private(set) var resizesStarted = 0
    public private(set) var maximizeCount = 0
    public private(set) var minimizeCount = 0
    public private(set) var snapCount = 0
    /// Set when a window is restored to a remembered position rather than
    /// cascaded — the observable difference a test can assert on.
    public private(set) var restoredCount = 0
    /// Every window that ever mapped, by place key, in the order they appeared.
    ///
    /// `mappedToplevels` is who is on screen *now*, which at the end of a run is
    /// only whoever outlived the test. A client that opened, did its work and
    /// quit — the ordinary shape of an application asking for a file — leaves no
    /// trace in it, so a test asserting that this compositor composited that
    /// client has nothing to assert on. This is that trace.
    public private(set) var everMapped: [String] = []

    /// - Parameter socketName: the `WAYLAND_DISPLAY` to bind, or nil to take the
    ///   first free `wayland-N`.
    ///
    ///   A session that *names* its display can put that name in its children's
    ///   environment before the compositor exists, which is what lets one
    ///   command bring up a whole desktop rather than two — the same argument
    ///   `anchor` makes for naming its own bus socket (PHASE8 P8.4). Asking for
    ///   a name that is taken is an error rather than a silent fallback to
    ///   another one: the fallback would hand every component a display nothing
    ///   is listening on.
    /// Whose menus are whose (PHASE10.md P10.3).
    public private(set) var menus: Menus?
    /// The config directory, watched for a person changing the theme (P14.2).
    private var appearanceWatch: ThemeLoader.Watch?
    private var appearanceSource: OpaquePointer?
    /// How many times the theme has been changed under us, for the harness.
    public private(set) var themeReloads = 0

    /// Follow the theme a person chooses while the desktop runs.
    ///
    /// The watch's descriptor joins **this compositor's own wayland event
    /// loop** — the one place undertow already waits — rather than a thread or
    /// a poll per frame. When the appearance changes the theme is loaded again,
    /// and nothing else has to happen here: every frame texture is keyed on
    /// `Theme.generation`, so the next frame redraws each window's frame in
    /// the new theme and a frame from the old one can never be reused.
    public func watchAppearance() {
        guard appearanceWatch == nil, let w = ThemeLoader.Watch(configDir: configDir) else { return }
        appearanceWatch = w
        let loop = wl_display_get_event_loop(session.display)
        appearanceSource = wl_event_loop_add_fd(loop, w.fileDescriptor, UInt32(WL_EVENT_READABLE),
                                                { _, _, data in
            guard let data else { return 0 }
            let c = Unmanaged<Compositor>.fromOpaque(data).takeUnretainedValue()
            guard let outcome = c.appearanceWatch?.check() else { return 0 }
            c.themeReloads += 1
            Compositor.log("theme changed (#\(c.themeReloads))")
            ThemeLoader.announce(outcome)
            return 0
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    /// Whether `linux-dmabuf` is on offer — whether a GPU client can present.
    public private(set) var dmabufOffered = false
    /// Buffers committed by minimised windows — drawing for nobody (T.3).
    public internal(set) var hiddenCommits = 0
    /// linux-drm-syncobj (U.3b), where the renderer and backend can keep it.
    public private(set) var explicitSync: ExplicitSync?
    /// ext-session-lock-v1 (PHASE16 P16.2): while locked, nothing of the
    /// desktop is drawn or reachable.
    public private(set) var sessionLock: SessionLock?
    /// Whether the session is locked — held or abandoned.
    public var isLocked: Bool { sessionLock?.locked == true }

    static func log(_ s: String) {
        let line = "undertow: \(s)\n"
        line.withCString { _ = write(2, $0, strlen($0)) }
    }

    /// The socket privileged clients connect to, if one was asked for.
    public private(set) var privilegedSocketName: String?

    public init(session: WlrootsSession, layout: DisplayLayout,
                configDir: String? = nil, socketName: String? = nil,
                privilegedSocket: String? = nil) throws {
        self.places = WindowPlaces(configDir: configDir)
        self.islands = IslandsConfig.load(configDir: configDir)
        self.configDir = configDir
        self.session = session
        self.layout = layout
        // Until a layer surface reserves anything, each whole display is usable.
        for d in layout.displays { usable[d.name] = d.rect }
        // The same arrangement, told to wlroots, and through it to clients.
        outputLayout = wlr_output_layout_create(session.display)
        if let ol = outputLayout {
            for d in layout.displays {
                guard let o = session.output(named: d.name) else { continue }
                _ = wlr_output_layout_add(ol, o, d.x, d.y)
            }
            _ = wlr_xdg_output_manager_v1_create(session.display, ol)
        }

        // wl_compositor at version 6, plus the pieces a real client expects to
        // find. `wlr_compositor_create` with a renderer is what makes wlroots
        // turn client buffers into textures for us on commit.
        guard let comp = wlr_compositor_create(session.display, 6, session.renderer)
        else { throw BackendError.noGlobals("wl_compositor") }
        _ = wlr_subcompositor_create(session.display)
        _ = wlr_data_device_manager_create(session.display)
        // **viewporter and fractional-scale (U.8).** wlroots does the protocol
        // and applies a viewport's destination to the surface's size; the
        // source crop is the scene's to draw (SurfaceScene.addLeaf). A client
        // told its display's fractional scale renders at it and says, through
        // a viewport, how big that is in the layout: sharp at 1.5x, where one
        // guessing 2x and scaled down is soft, and one guessing 1x is blurred.
        _ = wlr_viewporter_create(session.display)
        _ = wlr_fractional_scale_manager_v1_create(session.display, 1)
        // **wl_shm, without which no client can attach a buffer.**
        // `wlr_compositor_create` does not create it, and its absence looks like
        // "the compositor is not a compositor": our own `Display.init` requires
        // compositor + shm + xdg_wm_base and refuses the connection outright, so
        // the client's error is "cannot connect", pointing nowhere near the
        // missing global. Every shm client — which is every client we have —
        // needs this line.
        _ = wlr_shm_create_with_renderer(session.display, 1, session.renderer)

        // **linux-dmabuf, without which a GPU client does not survive** (U.3).
        // Mesa's EGL and Vulkan WSI on Wayland hand the compositor dma-bufs:
        // with only wl_shm on offer, vkcube on RADV segfaulted and es2gears
        // fell back to drawing in software (measured, on the dev box's AMD
        // iGPU — the RX 6750 XT's driver family). The global is made from the renderer, which
        // is what it can import; pixman — every headless run, the build VM —
        // imports none, so there it is not offered and shm clients are all
        // there is, as before. Explicit sync (linux-drm-syncobj, U.3b) is
        // offered after it, where the renderer and backend take timelines.
        // **presentation-time** (U.4): when a client's frame actually reached
        // the display, per surface, from the output's present event. Without
        // it every toolkit estimates (F-101: mpv, Chromium, GTK, Zed and LÖVE
        // each build an estimator) — while undertow already holds the answer
        // for its own frame contract. wlroots sends the feedback; the scene
        // says which surfaces each frame contained (`markPresented`).
        guard wlr_presentation_create(session.display, session.backend, 1) != nil else {
            throw BackendError.noGlobals("wp_presentation")
        }

        if let _ = wlr_linux_dmabuf_v1_create_with_renderer(session.display, 5, session.renderer) {
            dmabufOffered = true
            Compositor.log("linux-dmabuf offered — GPU clients can hand us their buffers")
        } else {
            Compositor.log("linux-dmabuf not offered — this renderer imports no dma-bufs "
                           + "(pixman?); GPU clients will fail, shm clients are unaffected")
        }
        sessionLock = SessionLock(compositor: self)
        explicitSync = ExplicitSync(display: session.display, compositor: comp,
                                    renderer: session.renderer, backend: session.backend)

        // **v6, for `suspended`** (U.2): a minimized window is told it cannot
        // be seen, so a client that listens can stop drawing, while its frame
        // clock keeps ticking slowly for one that does not. v5 brings
        // `wm_capabilities`, which is answered per window below — never left
        // to wlroots' default, which claims all four, including a window menu
        // undertow does not draw: a GTK window would ask for it on a
        // right-click and nothing would appear (found by removing the call).
        // v4's `configure_bounds` is only sent if asked for, and we do not.
        // Our own toolkit binds v2 and hears none of it.
        guard let shell = wlr_xdg_shell_create(session.display, 6) else {
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
        // Menus (P10.4): see Popups.swift for why this had never existed.
        newPopupListener = tw_listen(&shell.pointee.events.new_popup, { ctx, data in
            guard let ctx, let data else { return }
            let c = Unmanaged<Compositor>.fromOpaque(ctx).takeUnretainedValue()
            let p = data.assumingMemoryBound(to: wlr_xdg_popup.self)
            c.popups.append(PopupSurface(p, compositor: c))
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
            // A layer surface may name no output; it is ours to choose, and the
            // choice is the main display — where a Mac keeps its menu bar and
            // Dock. A wallpaper that wants every display asks for each.
            if l.pointee.output == nil {
                l.pointee.output = c.layout.main.flatMap { c.session.output(named: $0.name) }
                    ?? c.session.outputs.first
            }
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

        // Who draws the frames (P9.6). Always us — see `Decorations`.
        decorations = Decorations(compositor: self, session: session)
        outputManagement = OutputManagement(compositor: self)

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

        // Menus (P10.3): the manager for everyone, the bar's global only for
        // clients that came in through the privileged socket (PHASE10 §6.1).
        guard let m = Menus(compositor: self, display: session.display) else {
            throw BackendError.noGlobals("abyss_menu_manager_v1")
        }
        menus = m
        if let name = privilegedSocket {
            // Named like WAYLAND_DISPLAY and in the same directory, so a client
            // reaches it with nothing but `WAYLAND_DISPLAY=<name>`.
            guard let dir = getenv("XDG_RUNTIME_DIR").map({ String(cString: $0) }),
                  !dir.isEmpty else { throw BackendError.noSocket }
            try m.addPrivilegedSocket(name.hasPrefix("/") ? name : dir + "/" + name)
            privilegedSocketName = name
            // **The session lock is the privileged socket's** (PHASE16
            // P16.2c). Offered to every client, any application in the session
            // could wait for the lock screen to crash, take the abandoned lock
            // over, and unlock it. With a privileged socket, only what anchor
            // starts there — the lock screen — can lock or take a lock over.
            // Without one (a bare undertow, the protocol's own tests) it is
            // everyone's, as on any compositor.
            if let lock = sessionLock { m.restrictToPrivileged(lock.global) }
            // A session with a bar can show GTK's menus in it, so GTK may stop
            // drawing its own (PHASE10 §6.5). Without one it keeps them.
            m.advertiseGlobalMenusToGTK(true)
        }

        if let wanted = socketName {
            guard wanted.withCString({ wl_display_add_socket(session.display, $0) }) == 0 else {
                throw BackendError.socketTaken(wanted)
            }
            self.socketName = wanted
        } else {
            guard let socket = wl_display_add_socket_auto(session.display) else {
                throw BackendError.noSocket
            }
            self.socketName = String(cString: socket)
        }
    }

    deinit {
        tw_listener_free(newSurfaceListener)
        tw_listener_free(newToplevelListener)
        tw_listener_free(newLayerListener)
        tw_listener_free(newPopupListener)
        tw_listener_free(activationListener)
        for p in popups { p.teardown() }
        if let t = restoreTimer { wl_event_source_remove(t) }
        for t in toplevels { t.teardown() }
        for l in layers { l.teardown() }
        // Here, while `session` — and so the wl_display the menu globals live
        // on — is certainly still alive. Left to `Menus.deinit` it would run
        // whenever Swift released the property, which is not specified.
        menus?.teardown()
    }

    // MARK: - Layer shell

    internal func forgetLayer(_ l: LayerSurface) {
        if seat?.keyboardLayer === l { seat?.restoreKeyboard() }
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
        // Each display arranges its own surfaces, against its own rectangle in
        // the layout: the menu bar's strip comes off the main display only.
        for d in layout.displays {
            let full = d.rect
            var area = full
            for l in layers.sorted(by: { $0.layer < $1.layer }) where l.outputName == d.name {
                let (rect, remaining) = LayerArrange.place(l.request, in: area, output: full)
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
                if l.mapped { area = remaining }
            }
            usable[d.name] = area
        }
        // A surface on an output that is not in the layout (it went away) is
        // still owed a configure; it gets the main display's box, and reserves
        // nothing.
        for l in layers where layout.named(l.outputName) == nil {
            if let m = layout.main { l.configure(LayerArrange.place(l.request, in: m.rect, output: m.rect).rect) }
        }
    }

    /// Layer surfaces whose output went away, with the name they were on, so
    /// they go back to it when it returns (P16: a VT switched away and back).
    private var orphanedLayers: [(layer: LayerSurface, name: String)] = []

    /// An output is being destroyed (inside wlroots' destroy signal). wlroots
    /// takes it out of the output layout and destroys lock surfaces on it
    /// itself; **a layer surface it leaves pointing at it**, so the menu bar,
    /// the Dock and the desktop picture are parked — no output — until it is
    /// back. Their clients never hear of it: the display was not unplugged
    /// from the desktop's point of view, the VT was only switched.
    public func outputLost(_ o: UnsafeMutablePointer<wlr_output>) {
        let name = String(cString: o.pointee.name)
        var parked = 0
        for l in layers where l.handle.pointee.output == o {
            orphanedLayers.append((l, name))
            l.handle.pointee.output = nil
            parked += 1
        }
        Compositor.log("output \(name) gone — \(parked) layer surface(s) wait for it")
    }

    /// An output of a name we had is back: where the layout has it, with the
    /// layer surfaces that were on it.
    public func outputReturned(_ o: UnsafeMutablePointer<wlr_output>) {
        let name = String(cString: o.pointee.name)
        if let ol = outputLayout, let d = layout.named(name) { _ = wlr_output_layout_add(ol, o, d.x, d.y) }
        var back = 0
        for e in orphanedLayers where e.name == name && layers.contains(where: { $0 === e.layer }) {
            e.layer.handle.pointee.output = o
            back += 1
        }
        orphanedLayers.removeAll { e in e.name == name || !layers.contains { $0 === e.layer } }
        arrangeLayers()
        outputManagement?.publish()
        Compositor.log("output \(name) back — \(back) layer surface(s) on it again")
    }

    /// A new arrangement of the displays (P14.7b): positions, sizes, scales.
    ///
    /// wlroots' layout follows (xdg-output tells clients); layers are arranged
    /// again on each display; a window left on **no** display — its display
    /// moved away from under it — is brought to the main one, since a window
    /// nobody can see or reach is lost; and the pointer is kept on a display.
    public func applyLayout(_ new: DisplayLayout) {
        layout = new
        if let ol = outputLayout {
            for d in new.displays {
                if let o = session.output(named: d.name) { _ = wlr_output_layout_add(ol, o, d.x, d.y) }
            }
        }
        for d in new.displays where usable[d.name] == nil { usable[d.name] = d.rect }
        arrangeLayers()
        let area = usableArea
        for t in toplevels where t.mapped {
            let r = Rect(x: t.x, y: t.y, width: t.width, height: t.height)
            let onSome = new.displays.contains { d in
                min(r.x + r.width, d.x + d.width) > max(r.x, d.x) && min(r.y + r.height, d.y + d.height) > max(r.y, d.y)
            }
            guard !onSome else { continue }
            t.x = area.x + max(0, (area.width - t.width) / 2)
            t.y = area.y + max(0, (area.height - t.height) / 2)
            Compositor.log("window \(t.placeKey ?? "?") was on no display; brought to the main one")
            // On the main display now, so on the island it is showing.
            settleIsland(t)
        }
        seat?.keepCursorOnDisplays()
    }

    /// Layer surfaces with something to show, in paint order (bottom to top).
    public var mappedLayers: [LayerSurface] {
        layers.filter { $0.mapped && wlr_surface_has_buffer($0.surface) }
              .sorted { $0.layer < $1.layer }
    }

    /// A window became decorated: make room for the frame.
    ///
    /// The client asked for its size and got it; the *frame* is extra, and it
    /// has to come out of the compositor's placement rather than the client's
    /// idea of how big it is. Moving the surface down and right by the frame's
    /// own metrics is the whole adjustment.
    func reframe(_ t: Toplevel) {
        let inset = FrameMetrics.surface(forFrameAt: t.x, t.y)
        t.x = inset.x
        t.y = inset.y
    }

    /// Where a newly mapped window goes.
    ///
    /// Centred, then cascaded — the Mac's own rule, and a decision only a
    /// compositor can make. A Wayland client cannot position itself, which is
    /// why the spatial Finder's remembered positions have waited for this phase
    /// (HANDOFF §2.22); P6.7 is where that debt is paid.
    fileprivate func place(_ t: Toplevel) {
        everMapped.append(t.placeKey ?? "?")
        // **A window that appears takes the keyboard.**
        //
        // Focus was only ever given on click (`Seat.button`), which is right for
        // *changing* focus and wrong for the first window: until somebody
        // clicked, every application was deaf. On the live medium that is an
        // installer you cannot type into until you have clicked it, and no test
        // had caught it because the harness drives a pointer before a keyboard
        // in every mode that uses both.
        //
        // Found by trying to send a Finder a ⌘C (P9.2), which is the first thing
        // in this project's history to want the keyboard without wanting the
        // mouse first.
        seat?.focus(t)
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
        // A decorated window is centred by its *frame*: the surface sits a
        // title bar lower, and clamping to the usable area's top would otherwise
        // put the title bar under the menu bar on the very first window.
        if t.decorated {
            let inset = FrameMetrics.surface(forFrameAt: t.x, t.y)
            t.x = inset.x
            t.y = max(inset.y, area.y + Int32(FrameMetrics.titleHeight))
        }
    }

    /// Persist a window's position under its key.
    func rememberPlace(of t: Toplevel) {
        guard let key = t.placeKey else { return }
        places.remember(WindowPlace(x: t.x, y: t.y), forKey: key)
    }

    // MARK: - Interactive move

    func beginMove(_ t: Toplevel) {
        guard let seat else { return }
        moving = t
        moveDX = seat.cursorX - Double(t.x)
        moveDY = seat.cursorY - Double(t.y)
        raise(t)
    }

    /// Follow the pointer. Called from the seat on every motion.
    func updateMove(cursorX: Double, cursorY: Double) {
        guard let t = moving else { return }
        // Clamp so a window can never be dragged entirely off the desktop and
        // become unreachable — a compositor's job, and one a client could not do
        // for itself even if it wanted to. Across the whole layout, so a window
        // can be dragged to another display; and never above the usable top of
        // the display the pointer is on, so a title bar cannot hide under that
        // display's menu bar.
        let b = layout.bounds
        let maxX = Double(b.x + b.width - 1), maxY = Double(b.y + b.height - 1)
        t.x = Int32(min(max(cursorX - moveDX, Double(b.x + 1 - t.width)), maxX))
        t.y = Int32(min(max(cursorY - moveDY, Double(usableArea(at: cursorX, cursorY).y)), maxY))
    }

    /// End the drag: snap if it ended on an edge, then remember where it landed.
    func endMove() {
        guard let t = moving else { return }
        moving = nil
        // **Snap on release, not during the drag.** A window that resizes while
        // you are still moving it fights the pointer, and the person cannot see
        // the zone they are about to commit to until they stop moving anyway.
        if let seat,
           let zone = WindowSnap.zone(cursorX: Int32(seat.cursorX),
                                      cursorY: Int32(seat.cursorY),
                                      area: usableArea(at: seat.cursorX, seat.cursorY)) {
            // Where it was before the snap, so unmaximizing gives it back.
            if t.restoreBox == nil {
                t.restoreBox = Rect(x: t.x, y: t.y, width: t.width, height: t.height)
            }
            let box = WindowSnap.rect(for: zone, in: usableArea(at: seat.cursorX, seat.cursorY))
            t.x = box.x
            t.y = box.y
            _ = wlr_xdg_toplevel_set_size(t.xdgToplevel, Int32(max(0, box.width)),
                                          Int32(max(0, box.height)))
            if zone == .maximize { setMaximized(t, true) }
            snapCount += 1
        }
        rememberPlace(of: t)
        // Dropped on another display: it joins the island that display shows.
        settleIsland(t)
    }

    // MARK: - Interactive resize

    /// Begin a resize the client asked for, from `edges`.
    func beginResize(_ t: Toplevel, edges: UInt32) {
        guard let seat else { return }
        resizing = t
        resizeEdges = edges
        resizeStartX = seat.cursorX
        resizeStartY = seat.cursorY
        resizeStartBox = Rect(x: t.x, y: t.y, width: t.width, height: t.height)
        resizeAnchorRight = t.x + t.width
        resizeAnchorBottom = t.y + t.height
        resizesStarted += 1
        raise(t)
    }

    /// Follow the pointer. Called from the seat on every motion.
    ///
    /// The compositor decides the *size*; the client decides whether it can
    /// honour it, and answers with a commit at whatever size it managed. So the
    /// position of a left- or top-dragged window is fixed up when that commit
    /// arrives (`resizeCommitted`) rather than here, or the anchored edge walks.
    func updateResize(cursorX: Double, cursorY: Double) {
        guard let t = resizing else { return }
        let dx = Int32(cursorX - resizeStartX), dy = Int32(cursorY - resizeStartY)
        var w = resizeStartBox.width, h = resizeStartBox.height
        if resizeEdges & UInt32(WLR_EDGE_LEFT.rawValue) != 0 { w -= dx }
        if resizeEdges & UInt32(WLR_EDGE_RIGHT.rawValue) != 0 { w += dx }
        if resizeEdges & UInt32(WLR_EDGE_TOP.rawValue) != 0 { h -= dy }
        if resizeEdges & UInt32(WLR_EDGE_BOTTOM.rawValue) != 0 { h += dy }
        // A window smaller than its own title bar cannot be dragged back, so the
        // floor is the compositor's business rather than the toolkit's.
        w = max(w, Compositor.minimumWindowWidth)
        h = max(h, Compositor.minimumWindowHeight)
        _ = wlr_xdg_toplevel_set_size(t.xdgToplevel, w, h)
        if resizeEdges & UInt32(WLR_EDGE_TOP.rawValue) == 0 { t.y = resizeStartBox.y }
        if resizeEdges & UInt32(WLR_EDGE_LEFT.rawValue) == 0 { t.x = resizeStartBox.x }
    }

    /// The client committed a new size during a resize: keep the anchored edges
    /// where they were. Called from the surface commit listener.
    func resizeCommitted(_ t: Toplevel) {
        guard resizing === t else { return }
        if resizeEdges & UInt32(WLR_EDGE_LEFT.rawValue) != 0 {
            t.x = resizeAnchorRight - t.width
        }
        if resizeEdges & UInt32(WLR_EDGE_TOP.rawValue) != 0 {
            t.y = resizeAnchorBottom - t.height
        }
    }

    func endResize() {
        guard let t = resizing else { return }
        resizing = nil
        resizeEdges = 0
        rememberPlace(of: t)
    }

    // MARK: - What a keybind can ask for (P9.5)

    /// Raise and focus the next window in the stack, wrapping.
    ///
    /// **Cmd-Tab, and the whole of it for now.** The switcher *interface* — the
    /// island with the icons — is Phase 13's; the binding and the raise are this
    /// pass's, and they are what Phase 13 is blocked on.
    func cycleWindow(forward: Bool) {
        // **Every island's windows** (PHASE13 §6.3): choosing one that is
        // elsewhere goes there, as the Dock does. Bottom-to-top; the last is
        // on top, and focusing raises, so the focused window is the last.
        let windows = toplevels.filter { $0.mapped && !$0.minimized && wlr_surface_has_buffer($0.surface) }
        guard windows.count > 1 else {
            if let only = windows.first { bringToFront(only) }
            return
        }
        // Forward means "the one under the top", which is what Cmd-Tab does on a
        // Mac: it goes to the window you were in before this one.
        let next = forward ? windows[windows.count - 2] : windows[0]
        bringToFront(next)
    }

    /// Ask the focused window to close. The client decides what that means — a
    /// document with unsaved changes is entitled to put up a sheet — which is
    /// why this sends `close` rather than destroying anything.
    func closeFocusedWindow() {
        guard let t = seat?.focused else { return }
        wlr_xdg_toplevel_send_close(t.xdgToplevel)
    }

    /// Cmd-Q: every window of the focused application, not just this one.
    ///
    /// That difference is the whole reason both bindings exist, and a compositor
    /// that treated them the same would be quietly wrong in the direction people
    /// notice — closing one window of five and calling it quitting.
    func quitFocusedApplication() {
        guard let t = seat?.focused, let app = t.appID, !app.isEmpty else {
            closeFocusedWindow()
            return
        }
        for w in toplevels where w.appID == app {
            wlr_xdg_toplevel_send_close(w.xdgToplevel)
        }
    }

    /// Force Quit (P10.8): kill every process with a toplevel of `appID`.
    ///
    /// Only the compositor can do this — it alone knows which client, and so
    /// which pid, is behind a window — and only the menu bar can ask, on the
    /// privileged socket. SIGKILL, because a *force* quit is for an application
    /// that has stopped answering; a polite one is Cmd-Q. Never ourselves.
    @discardableResult
    func forceQuit(appID: String) -> [Int32] {
        var pids: Set<Int32> = []
        for t in toplevels where t.appID == appID {
            let pid = Int32(tw_client_pid_of(t.xdgToplevel.pointee.resource))
            if pid > 0, pid != getpid() { pids.insert(pid) }
        }
        for pid in pids.sorted() { kill(pid, SIGKILL) }
        Menus.log("force quit \(appID): " + (pids.isEmpty ? "no such application"
                                              : "killed \(pids.sorted().map(String.init).joined(separator: " "))"))
        return pids.sorted()
    }

    public static let minimumWindowWidth: Int32 = 120
    public static let minimumWindowHeight: Int32 = 40

    // MARK: - Maximize, minimize, fullscreen

    /// Zoom to the **usable area**, not the output.
    ///
    /// The menu bar's exclusive zone has been computed since P6.4 and until now
    /// nothing consumed it. A window maximized to the output would slide under
    /// the menu bar, which is the visible symptom of a zone that was arithmetic
    /// and nothing else.
    func setMaximized(_ t: Toplevel, _ on: Bool) {
        if on {
            if t.restoreBox == nil {
                t.restoreBox = Rect(x: t.x, y: t.y, width: t.width, height: t.height)
            }
            // **A decorated window's frame has to fit too.** Maximizing the
            // surface to the usable area would put the title bar we drew above
            // it off the top of the screen — a window you cannot move, close or
            // un-zoom, because every control is off-screen.
            // The usable area of the display the window is on.
            let d = layout.display(for: Rect(x: t.x, y: t.y, width: t.width, height: t.height))
            var box = d.flatMap { usable[$0.name] } ?? usableArea
            if t.decorated {
                let inset = FrameMetrics.surface(forFrameAt: box.x, box.y)
                box = Rect(x: inset.x, y: inset.y,
                           width: box.width - 2 * Int32(FrameMetrics.border),
                           height: box.height - Int32(FrameMetrics.titleHeight)
                                              - Int32(FrameMetrics.border))
            }
            t.x = box.x
            t.y = box.y
            _ = wlr_xdg_toplevel_set_size(t.xdgToplevel, Int32(max(0, box.width)),
                                          Int32(max(0, box.height)))
            maximizeCount += 1
        } else if let box = t.restoreBox {
            t.x = box.x
            t.y = box.y
            _ = wlr_xdg_toplevel_set_size(t.xdgToplevel, Int32(max(0, box.width)),
                                          Int32(max(0, box.height)))
            t.restoreBox = nil
        }
        t.maximized = on
        // **The configure is not optional.** A client that asked and was never
        // answered waits for ever — including when the answer is no.
        _ = wlr_xdg_toplevel_set_maximized(t.xdgToplevel, on)
        t.republish()
    }

    /// Minimize to the Dock tile. No animation — the genie is Phase 13's, and it
    /// wants the same scaled `dst_box` and alpha that Ebb wants.
    func setMinimized(_ t: Toplevel, _ on: Bool) {
        guard t.minimized != on else { return }
        t.minimized = on
        // Say so (xdg-shell v6). A client that listens stops drawing; one
        // that does not still has the slow clock `sendFrameDone` keeps.
        refreshSuspended(t)
        if on {
            minimizeCount += 1
            // A minimized window must not keep the keyboard: the person just
            // put it away, and a deaf desktop is what happens if it does.
            if seat?.focused === t { seat?.focusTopmost() }
        } else {
            raise(t)
            seat?.focus(t)
        }
        t.republish()
    }

    func setFullscreen(_ t: Toplevel, _ on: Bool) {
        if on {
            if t.restoreBox == nil {
                t.restoreBox = Rect(x: t.x, y: t.y, width: t.width, height: t.height)
            }
            // The whole display the window is on — not the layout.
            let d = layout.display(for: Rect(x: t.x, y: t.y, width: t.width, height: t.height))
                ?? DisplayBox(name: "", x: 0, y: 0, width: 0, height: 0)
            t.x = d.x
            t.y = d.y
            _ = wlr_xdg_toplevel_set_size(t.xdgToplevel, d.width, d.height)
        } else if let box = t.restoreBox {
            t.x = box.x
            t.y = box.y
            _ = wlr_xdg_toplevel_set_size(t.xdgToplevel, Int32(max(0, box.width)),
                                          Int32(max(0, box.height)))
            t.restoreBox = nil
        }
        _ = wlr_xdg_toplevel_set_fullscreen(t.xdgToplevel, on)
    }

    /// The seat, once one exists — set by `Seat.init`.
    weak var seat: Seat?
    /// Display sleep, its inhibitors and idle-notify (U.9). Made by the run
    /// loop, which owns the outputs it switches.
    public var displaySleep: DisplaySleep?
    private var asleepFrameAt: UInt64 = 0
    /// When the windows behind the lock last had a frame (P16.2).
    private var lockedFrameAt: UInt64 = 0

    func forgetPopup(_ p: PopupSurface) {
        p.teardown()
        popups.removeAll { $0 === p }
        // The last menu closed: the keys go back to the window you were in —
        // **after a moment, not now.** Walking the bar with ←/→ closes one
        // menu and opens the next, and the bar may flush between the two; so
        // "no popups" is briefly true, and restoring then takes the keyboard
        // from the bar mid-walk. An idle callback was tried first and lost that
        // race (the destroy and the create arrived in separate dispatches).
        // 100 ms is long enough for a client to open its next menu and short
        // enough that nobody types into the gap after an Escape.
        if popups.isEmpty {
            let loop = wl_display_get_event_loop(session.display)
            if restoreTimer == nil {
                restoreTimer = wl_event_loop_add_timer(loop, { data in
                    guard let data else { return 0 }
                    let c = Unmanaged<Compositor>.fromOpaque(data).takeUnretainedValue()
                    if c.popups.isEmpty { c.seat?.restoreKeyboard() }
                    return 0
                }, Unmanaged.passUnretained(self).toOpaque())
            }
            _ = wl_event_source_timer_update(restoreTimer, 100)
        }
    }

    fileprivate func forget(_ t: Toplevel) {
        decorations?.forget(t)
        t.teardown()
        toplevels.removeAll { $0 === t }
        // **Closing the focused window used to leave focus on nothing** — the
        // same deaf desktop P9.4 fixed for minimize, by the other door: `focused`
        // is weak, so it went quietly nil and no window was told it was now
        // active. Found in P10.3, because the menu bar is the first thing that
        // has to be told who is frontmost after a close.
        if seat?.focused === t { seat?.focusTopmost() }
        menus?.focusChanged()
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

    /// Send a window to the back of the stack — the depth gadget (P11.6), the
    /// one window operation Phase 11 adds. The keyboard goes with the front:
    /// a window put behind the others is not the one you are typing into.
    public private(set) var lowerCount = 0
    public func lower(_ t: Toplevel) {
        guard let i = toplevels.firstIndex(where: { $0 === t }) else { return }
        lowerCount += 1
        if i != 0 {
            toplevels.remove(at: i)
            toplevels.insert(t, at: 0)
        }
        if seat?.focused === t { seat?.focusTopmost() }
    }

    /// Windows that currently have something to show, bottom to top.
    public var mappedToplevels: [Toplevel] {
        // On an island its display is not showing: not shown (PHASE13 P13.1).
        toplevels.filter { $0.mapped && !$0.minimized && isOnActiveIsland($0)
                           && wlr_surface_has_buffer($0.surface) }
    }

    /// The topmost window at (x, y), and its box as drawn — the frame undertow
    /// draws around a decorated window included (P15.6: Grab's Window mode
    /// takes the whole window, title bar and all, as Jaguar's did).
    public func windowBox(at x: Double, _ y: Double)
        -> (toplevel: Toplevel, x: Int32, y: Int32, width: Int32, height: Int32)? {
        for t in mappedToplevels.reversed() {
            let box = t.decorated
                ? FrameMetrics.frame(forSurfaceAt: t.x, t.y, width: t.width, height: t.height)
                : (x: t.x, y: t.y, w: t.width, h: t.height)
            if x >= Double(box.x), y >= Double(box.y), x < Double(box.x + box.w), y < Double(box.y + box.h) {
                return (t, box.x, box.y, box.w, box.h)
            }
        }
        return nil
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
        let nowNs = UInt64(now.tv_sec) &* 1_000_000_000 &+ UInt64(now.tv_nsec)
        // **Displays asleep (U.9): everyone gets the slow clock.** Nothing is
        // shown, so nothing needs the display's rate — but a FIFO client
        // blocked on its callback must still be let go now and then (U.2).
        if displaySleep?.asleep == true {
            guard nowNs &- asleepFrameAt >= Compositor.hiddenFramePeriodNs else { return }
            asleepFrameAt = nowNs
            for t in toplevels where t.mapped { Compositor.frameDone(tree: t.surface, &now) }
            for l in mappedLayers { Compositor.frameDone(tree: l.surface, &now) }
            for p in mappedPopups { Compositor.frameDone(tree: p.surface, &now) }
            for s in sessionLock?.surfaces ?? [] { Compositor.frameDone(tree: s.surface, &now) }
            return
        }
        // **Locked (PHASE16 P16.2): the lock screen gets the display's rate,
        // and everything behind it the slow clock** — nothing of it is shown,
        // so nothing of it should draw at full rate, but a FIFO client must
        // still be let go now and then (U.2). Without this the lock surfaces
        // had no clock at all: a lock screen drew its first frame and never
        // another, so typing and the shake were invisible (found in P16.2b —
        // P16.2a's test client drew one frame and never asked for a second).
        if let lock = sessionLock, lock.locked {
            for s in lock.surfaces { Compositor.frameDone(tree: s.surface, &now) }
            guard nowNs &- lockedFrameAt >= Compositor.hiddenFramePeriodNs else { return }
            lockedFrameAt = nowNs
            for t in toplevels where t.mapped { Compositor.frameDone(tree: t.surface, &now) }
            for l in mappedLayers { Compositor.frameDone(tree: l.surface, &now) }
            for p in mappedPopups { Compositor.frameDone(tree: p.surface, &now) }
            return
        }
        for t in mappedToplevels { Compositor.frameDone(tree: t.surface, &now) }
        // **A window nobody can see keeps a clock, a slow one** (U.2). It used
        // to get none: `mappedToplevels` leaves minimized windows out, so their
        // frame callbacks were withheld — and a client presenting in FIFO mode
        // (Mesa's default: SDL, Blender, zed) blocks inside its swap until the
        // callback comes, which was never. Once a second is enough to keep it
        // alive and cheap enough to cost nothing (API-STUDY §1.4, F-102/F-209).
        // **And so does one on an island nobody is looking at** (PHASE13 P13.1):
        // the same case, the same clock.
        for t in toplevels where t.mapped && (t.minimized || !isOnActiveIsland(t))
                                 && wlr_surface_has_buffer(t.surface) {
            guard nowNs &- t.hiddenFrameAt >= Compositor.hiddenFramePeriodNs else { continue }
            t.hiddenFrameAt = nowNs
            Compositor.frameDone(tree: t.surface, &now)
        }
        for l in mappedLayers { Compositor.frameDone(tree: l.surface, &now) }
        // Or a menu draws once and never shows its hover.
        for p in mappedPopups { Compositor.frameDone(tree: p.surface, &now) }
    }

    /// How often a window nobody can see is told to draw: once a second.
    static let hiddenFramePeriodNs: UInt64 = 1_000_000_000

    /// Frame-done to a surface **and every subsurface under it**.
    ///
    /// A subsurface has its own frame callbacks, and a desynchronised one
    /// commits on its own clock: one that asks and is never answered draws once
    /// and then waits for ever, exactly as a whole window did before this
    /// function existed. The time travels as the iterator's data pointer, so
    /// no closure is allocated per frame.
    static func frameDone(tree root: UnsafeMutablePointer<wlr_surface>,
                          _ now: UnsafeMutablePointer<timespec>) {
        wlr_surface_for_each_surface(root, { surface, _, _, data in
            guard let surface, let data else { return }
            wlr_surface_send_frame_done(surface, data.assumingMemoryBound(to: timespec.self))
        }, UnsafeMutableRawPointer(now))
    }

    /// Close out a frame: release clients to draw the next one, then push the
    /// queued protocol events down their sockets.
    ///
    /// One call rather than two so a caller cannot do half of it — a frame-done
    /// that is never flushed leaves the client waiting exactly as if it had
    /// never been sent, which is a hang with no fingerprints.
    public func endFrame() {
        // A frame was drawn under a new lock: now its client may be told.
        sessionLock?.frameDrawn()
        sendFrameDone()
        wl_display_flush_clients(session.display)
    }
}
