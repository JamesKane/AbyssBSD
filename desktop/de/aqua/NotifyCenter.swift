// NotifyCenter — the shell component that shows toasts (PHASE7.md P7.4).
//
// It hosts a `notify` service on the control plane and draws whatever arrives on
// a layer-shell **OVERLAY** surface at the top right.
//
// Two properties it must have, both easy to get wrong:
//
//   - **It never takes focus.** `keyboard_interactivity: none`, so a toast
//     appearing while you type cannot swallow your keystrokes.
//   - **It covers only itself.** An OVERLAY surface takes pointer input
//     wherever it extends, so the surface is sized to the stack and destroyed
//     when the last toast expires — a full-screen invisible surface would eat
//     every click meant for the desktop.
//
// The trust boundary is the same one the file chooser draws: a jailed app never
// holds this service's socket. It asks the *portal*, which relays here.

import CCairo
import CWayland
import CurrentIPC
import PoolConfig
import Surface

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

public final class NotifyCenter: LayerSurfaceDelegate {
    private let display: Display
    private var layer: LayerSurface?
    private var toasts: [Toast] = []
    private var rects: [Rect] = []
    private var nextID: UInt64 = 1
    private var server: Current.Server?
    private var timerFd: Int32 = -1
    private let defaultTimeout: Double

    /// Cap what one app can put on screen. Notifications are a shared resource;
    /// an app that posts fifty of them must not own the display.
    public static let maxVisible = 5

    public init(display: Display, defaultTimeout: Double = 5) {
        self.display = display
        self.defaultTimeout = defaultTimeout
    }

    static func log(_ msg: String) {
        let line = "Notify: \(msg)\n"
        line.withCString { _ = write(2, $0, strlen($0)) }
    }

    /// Bind the service and fold its listener into the run loop — no thread,
    /// no second loop (HANDOFF §2.18).
    @discardableResult
    public func start(service: String = "notify") -> Bool {
        do {
            let s = try Current.Server(service: service)
            try s.setNonBlocking(true)
            display.addFileDescriptor(s.fd) { [weak self] in self?.acceptOne() }
            server = s
            NotifyCenter.log("serving \(s.path)")
        } catch {
            NotifyCenter.log("no notify service (\(error))")
            return false
        }
        // One timer drives expiry; toasts vanish on their own.
        let fd = aw_create_interval_timer(500)
        if fd >= 0 {
            timerFd = fd
            display.addFileDescriptor(fd) { [weak self] in self?.tick() }
        }
        return true
    }

    private func acceptOne() {
        guard let server else { return }
        _ = try? server.serveOne { [weak self] request in
            var reply = Msg()
            guard let self else { reply.set("ok", false); return reply }
            switch request.string("method") ?? "notify" {
            case "notify":
                let summary = request.string("summary") ?? ""
                guard !summary.isEmpty else {
                    reply.set("ok", false)
                    reply.set("error", "notify needs a summary")
                    return reply
                }
                let timeout = Double(request.uint64("timeout") ?? 0)
                let id = self.post(summary: summary, body: request.string("body"),
                                   timeout: timeout > 0 ? timeout : self.defaultTimeout)
                reply.set("ok", true)
                reply.set("id", id)
            case "dismiss":
                if let id = request.uint64("id") { self.dismiss(id) }
                reply.set("ok", true)
            default:
                reply.set("ok", false)
                reply.set("error", "unknown method")
            }
            return reply
        }
    }

    /// Show a notification. Returns its id.
    @discardableResult
    public func post(summary: String, body: String?, timeout: Double) -> UInt64 {
        let id = nextID
        nextID += 1
        toasts.append(Toast(id: id, summary: summary, body: body,
                            expiresAt: monotonicNow() + timeout))
        // Oldest first out when the screen is full.
        if toasts.count > NotifyCenter.maxVisible {
            toasts.removeFirst(toasts.count - NotifyCenter.maxVisible)
        }
        NotifyCenter.log("posted #\(id): \(summary)")
        rebuild()
        return id
    }

    public func dismiss(_ id: UInt64) {
        toasts.removeAll { $0.id == id }
        NotifyCenter.log("dismissed #\(id)")
        rebuild()
    }

    private func tick() {
        var buf = UInt64(0)
        _ = withUnsafeMutableBytes(of: &buf) {
            read(timerFd, $0.baseAddress, MemoryLayout<UInt64>.size)
        }
        let before = toasts.count
        toasts = liveToasts(toasts, now: monotonicNow())
        if toasts.count != before { rebuild() }
    }

    /// Create, resize or destroy the surface to match what's on screen.
    private func rebuild() {
        guard !toasts.isEmpty else {
            // Nothing to show: drop the surface entirely rather than leave an
            // invisible one swallowing clicks. Explicit close() first — the
            // Wayland objects must be destroyed before the Swift object goes,
            // or libwayland keeps delivering events into freed memory (§2.2).
            if let l = layer {
                l.close()
                layer = nil
                NotifyCenter.log("surface released (no toasts)")
            }
            return
        }
        let heights = measure()
        let l = toastLayout(heights: heights)
        rects = l.rects
        // Recreated rather than resized when the stack changes: layer surfaces
        // negotiate their size through configure/ack, and toasts change rarely
        // enough (seconds apart) that rebuilding is simpler than a resize path
        // nothing else needs. The old one is closed explicitly first, for the
        // same reason as above — replacing the reference alone is not teardown.
        layer?.close()
        layer = LayerSurface(display: display, layer: .overlay,
                             namespace: "abyss.notify",
                             width: Int32(l.width), height: Int32(l.height),
                             anchor: [.top, .right], exclusiveZone: 0,
                             keyboard: .none,
                             margin: (Int32(ToastMetrics.topInset),
                                      Int32(ToastMetrics.rightInset), 0, 0),
                             delegate: self)
        layer?.setNeedsDisplay()
    }

    /// Wrapped body lines need a cairo context for text measurement; use a
    /// scratch surface rather than the live buffer, which may not exist yet.
    private func measure() -> [Double] {
        let scratch = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, 1, 1)
        defer { cairo_surface_destroy(scratch) }
        guard let cr = cairo_create(scratch) else {
            return toasts.map { _ in toastHeight(bodyLines: 0) }
        }
        defer { cairo_destroy(cr) }
        return toasts.map { t in
            let lines = t.body.map {
                toastWrap(cr, $0, width: ToastMetrics.width - ToastMetrics.padX * 2 - 20,
                          size: ToastMetrics.bodySize, maxLines: ToastMetrics.maxBodyLines)
            } ?? []
            return toastHeight(bodyLines: lines.count)
        }
    }

    // MARK: LayerSurfaceDelegate

    public func render(_ buffer: PixelBuffer) {
        Text.renderScale = buffer.scale
        let cs = cairo_image_surface_create_for_data(
            buffer.data, CAIRO_FORMAT_ARGB32,
            buffer.width, buffer.height, buffer.stride)
        guard let cr = cairo_create(cs) else { cairo_surface_destroy(cs); return }
        cairo_scale(cr, Double(buffer.scale), Double(buffer.scale))
        // Fully transparent background: only the panels are visible.
        cairo_set_operator(cr, CAIRO_OPERATOR_SOURCE)
        cairo_set_source_rgba(cr, 0, 0, 0, 0)
        cairo_paint(cr)
        cairo_set_operator(cr, CAIRO_OPERATOR_OVER)

        let heights = measure()
        let l = toastLayout(heights: heights)
        rects = l.rects
        for (i, t) in toasts.enumerated() where i < rects.count {
            let lines = t.body.map {
                toastWrap(cr, $0, width: ToastMetrics.width - ToastMetrics.padX * 2 - 20,
                          size: ToastMetrics.bodySize, maxLines: ToastMetrics.maxBodyLines)
            } ?? []
            paintToast(cr, rects[i], toast: t, bodyLines: lines)
        }
        cairo_surface_flush(cs)
        cairo_destroy(cr)
        cairo_surface_destroy(cs)
    }

    public func pointerButton(_ button: UInt32, pressed: Bool, x: Double, y: Double) {
        guard pressed, let i = toastIndex(at: y, rects: rects), i < toasts.count else { return }
        dismiss(toasts[i].id)      // click to dismiss
    }
}

/// Monotonic seconds — a toast must not outlive its timeout because the wall
/// clock moved.
func monotonicNow() -> Double {
    var ts = timespec()
    clock_gettime(CLOCK_MONOTONIC, &ts)
    return Double(ts.tv_sec) + Double(ts.tv_nsec) / 1_000_000_000
}
