// Surface.LayerSurface — a wlr-layer-shell surface: the shell's anchored,
// compositor-placed surface role (wallpaper, menu bar, Dock), as opposed to a
// floating xdg-shell toplevel (Window).
//
// The compositor owns placement: the client picks a layer (background/bottom/
// top/overlay), anchors to screen edges, and optionally reserves an exclusive
// zone (a menu bar reserving the top strip). The layer_surface object carries
// its own configure/ack — there is no xdg_surface in between — and the configure
// event delivers the size the compositor chose, which the client acks and paints
// into. Buffer pooling, frame-callback pacing, and per-output scale tracking are
// the same discipline as Window; this is the trimmed layer-shell variant.

import CWayland

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

public extension LayerSurface {
    /// Which layer the surface sits in (bottom-to-top paint order).
    enum Layer: UInt32 {
        case background = 0, bottom = 1, top = 2, overlay = 3
    }

    /// Screen edges to anchor to. Anchoring two opposite edges stretches the
    /// surface across that axis; anchoring all four fills the output.
    struct Anchor: OptionSet, Sendable {
        public let rawValue: UInt32
        public init(rawValue: UInt32) { self.rawValue = rawValue }
        public static let top    = Anchor(rawValue: 1)
        public static let bottom = Anchor(rawValue: 2)
        public static let left   = Anchor(rawValue: 4)
        public static let right  = Anchor(rawValue: 8)
        public static let all: Anchor = [.top, .bottom, .left, .right]
    }

    /// Keyboard focus policy (mirrors the protocol enum).
    enum KeyboardInteractivity: UInt32 {
        case none = 0, exclusive = 1, onDemand = 2
    }
}

/// A layer-shell client surface. Reuses WindowDelegate for rendering + input;
/// windowDidRenderFrame is delivered with a nil Window (layer surfaces have no
/// toplevel), so animating delegates should use layerSurfaceDidRenderFrame.
public protocol LayerSurfaceDelegate: AnyObject {
    func render(_ buffer: PixelBuffer)
    func pointerMoved(x: Double, y: Double)
    func pointerButton(_ button: UInt32, pressed: Bool)
    func pointerAxis(_ axis: UInt32, value: Double)
    func keyEvent(_ event: KeyEvent)
    /// Called after each committed frame is released (animation hook). Default no-op.
    func layerSurfaceDidRenderFrame(_ surface: LayerSurface)
}

public extension LayerSurfaceDelegate {
    func pointerMoved(x: Double, y: Double) {}
    func pointerButton(_ button: UInt32, pressed: Bool) {}
    func pointerAxis(_ axis: UInt32, value: Double) {}
    func keyEvent(_ event: KeyEvent) {}
    func layerSurfaceDidRenderFrame(_ surface: LayerSurface) {}
}

public final class LayerSurface {
    let display: Display
    let surface: OpaquePointer
    let layerSurface: OpaquePointer

    public weak var delegate: LayerSurfaceDelegate?

    public private(set) var scale: Int32
    private let autoScale: Bool
    private var enteredOutputs: [OpaquePointer] = []

    // Logical size. A configure may hand us a compositor-chosen size (e.g. the
    // full output width for an edge-anchored bar); 0 means "keep our request".
    private var logicalW: Int32
    private var logicalH: Int32
    private var configuredW: Int32 = 0
    private var configuredH: Int32 = 0

    private var buffers: [ShmBuffer] = []
    private var needsRedraw = true
    private var framePending = false
    private var didMap = false
    private let namespace: String

    /// Create and map a layer-shell surface. `width`/`height` are the requested
    /// logical size; pass 0 on an axis you anchor to both edges to let the
    /// compositor stretch it (e.g. width 0 + anchor left|right for a full bar).
    /// `exclusiveZone` reserves that many logical px for the surface (a menu bar
    /// passes its height; a wallpaper passes -1 to sit under exclusive zones).
    public init?(display: Display, layer: Layer, namespace: String,
                 width: Int32, height: Int32,
                 anchor: Anchor, exclusiveZone: Int32 = 0,
                 keyboard: KeyboardInteractivity = .none,
                 scale: Int32 = 1, autoScale: Bool = true,
                 delegate: LayerSurfaceDelegate) {
        guard let compositor = display.compositor, let shell = display.layerShell,
              let surf = opt(aw_compositor_create_surface(raw(compositor)))
        else { return nil }
        self.display = display
        self.surface = surf
        self.scale = max(1, scale)
        self.autoScale = autoScale
        self.logicalW = max(1, width)
        self.logicalH = max(1, height)
        self.namespace = namespace
        self.delegate = delegate

        guard let ls = namespace.withCString({ ns in
            opt(aw_layer_shell_get_layer_surface(
                raw(shell), raw(surf), nil, layer.rawValue, ns))
        }) else { return nil }
        layerSurface = ls

        aw_layer_surface_set_size(raw(ls), UInt32(max(0, width)), UInt32(max(0, height)))
        aw_layer_surface_set_anchor(raw(ls), anchor.rawValue)
        aw_layer_surface_set_exclusive_zone(raw(ls), exclusiveZone)
        aw_layer_surface_set_keyboard_interactivity(raw(ls), keyboard.rawValue)

        let me = Unmanaged.passUnretained(self).toOpaque()

        var lsl = zwlr_layer_surface_v1_listener()
        lsl.configure = { data, _, serial, w, h in
            guard let data else { return }
            let s = Unmanaged<LayerSurface>.fromOpaque(data).takeUnretainedValue()
            s.applyConfigure(serial: serial, w: Int32(bitPattern: w),
                             h: Int32(bitPattern: h))
        }
        lsl.closed = { data, _ in
            guard let data else { return }
            let s = Unmanaged<LayerSurface>.fromOpaque(data).takeUnretainedValue()
            s.display.stop()
        }
        display.addListener(to: ls, listener: lsl, data: me)

        // Track the outputs the surface is shown on, for the buffer scale.
        var sl = wl_surface_listener()
        sl.enter = { data, _, output in
            guard let data, let output else { return }
            let s = Unmanaged<LayerSurface>.fromOpaque(data).takeUnretainedValue()
            s.surfaceEntered(output)
        }
        sl.leave = { data, _, output in
            guard let data, let output else { return }
            let s = Unmanaged<LayerSurface>.fromOpaque(data).takeUnretainedValue()
            s.surfaceLeft(output)
        }
        display.addListener(to: surf, listener: sl, data: me)

        display.layerSurface = self
        aw_surface_commit(raw(surf))  // no buffer yet — triggers the first configure
        wl_display_flush(display.display)
    }

    public func setNeedsDisplay() {
        needsRedraw = true
        if !framePending { renderAndCommit() }
    }

    private func applyConfigure(serial: UInt32, w: Int32, h: Int32) {
        let newW = w > 0 ? w : logicalW
        let newH = h > 0 ? h : logicalH
        let sizeChanged = newW != configuredW || newH != configuredH
        if sizeChanged || buffers.isEmpty {
            logicalW = newW
            logicalH = newH
            configuredW = newW
            configuredH = newH
            allocateBuffers()
        }
        aw_layer_surface_ack_configure(raw(layerSurface), serial)
        if !didMap {
            didMap = true
            // First configure means the compositor accepted and placed us — the
            // live proof that the layer-shell handshake worked. Log to fd 2 (not
            // the stderr global; Swift 6 rejects it — see HANDOFF §2.4).
            let msg = "Surface.LayerSurface: mapped \(logicalW)x\(logicalH) " +
                      "[\(namespace)]\n"
            msg.withCString { _ = write(2, $0, strlen($0)) }
        }
        needsRedraw = true
        if !framePending { renderAndCommit() }
    }

    private func surfaceEntered(_ output: OpaquePointer) {
        if !enteredOutputs.contains(output) { enteredOutputs.append(output) }
        recomputeScale()
    }

    private func surfaceLeft(_ output: OpaquePointer) {
        enteredOutputs.removeAll { $0 == output }
        recomputeScale()
    }

    func recomputeScale() {
        guard autoScale else { return }
        var s: Int32 = 1
        for o in enteredOutputs { s = max(s, display.outputScale(o)) }
        updateScale(s)
    }

    private func updateScale(_ newScale: Int32) {
        let s = max(1, newScale)
        guard s != scale else { return }
        scale = s
        let msg = "Surface.LayerSurface: buffer scale -> \(s)x\n"
        msg.withCString { _ = write(2, $0, strlen($0)) }
        if !buffers.isEmpty {
            allocateBuffers()
            needsRedraw = true
            if !framePending { renderAndCommit() }
        }
    }

    private func allocateBuffers() {
        for b in buffers { b.destroy() }
        buffers.removeAll()
        let bw = logicalW * scale
        let bh = logicalH * scale
        for _ in 0..<2 {
            guard let b = ShmBuffer(display: display, width: bw, height: bh)
            else { continue }
            b.attachReleaseListener(display: display)
            buffers.append(b)
        }
    }

    private func renderAndCommit() {
        guard let buf = buffers.first(where: { !$0.busy }) else {
            needsRedraw = true
            return
        }
        delegate?.render(PixelBuffer(data: buf.data, width: buf.width,
                                     height: buf.height, stride: buf.stride,
                                     scale: scale))
        buf.busy = true
        aw_surface_attach(raw(surface), raw(buf.wlBuffer), 0, 0)
        aw_surface_set_buffer_scale(raw(surface), scale)
        aw_surface_damage_buffer(raw(surface), 0, 0, buf.width, buf.height)
        if let cb = opt(aw_surface_frame(raw(surface))) {
            var cl = wl_callback_listener()
            cl.done = { data, _, _ in
                guard let data else { return }
                let s = Unmanaged<LayerSurface>.fromOpaque(data).takeUnretainedValue()
                s.frameDone()
            }
            let me = Unmanaged.passUnretained(self).toOpaque()
            display.addListener(to: cb, listener: cl, data: me)
            framePending = true
        }
        needsRedraw = false
        aw_surface_commit(raw(surface))
        wl_display_flush(display.display)
    }

    private func frameDone() {
        framePending = false
        delegate?.layerSurfaceDidRenderFrame(self)
        if needsRedraw { renderAndCommit() }
    }

    func pointerMoved(fx: Int32, fy: Int32) {
        delegate?.pointerMoved(x: Double(fx) / 256.0, y: Double(fy) / 256.0)
    }

    func pointerButton(_ button: UInt32, pressed: Bool) {
        delegate?.pointerButton(button, pressed: pressed)
    }

    func pointerAxis(_ axis: UInt32, value: Double) {
        delegate?.pointerAxis(axis, value: value)
    }

    func keyEvent(_ event: KeyEvent) {
        delegate?.keyEvent(event)
    }

    /// Open a grabbing popup (a menu) anchored to a rect in this layer surface's
    /// logical coordinates — the menu bar's / Dock's dropdowns. The caller owns
    /// the returned Popup; dropping it (or a `popup_done`) tears it down.
    public func openPopup(anchorX: Int32, anchorY: Int32, anchorW: Int32,
                          anchorH: Int32, width: Int32, height: Int32,
                          delegate: PopupDelegate) -> Popup? {
        Popup(layerParent: self, anchorX: anchorX, anchorY: anchorY,
              anchorW: anchorW, anchorH: anchorH, width: width, height: height,
              delegate: delegate)
    }

    /// Logical (surface) size, for the toolkit's layout.
    public var size: (width: Int32, height: Int32) { (logicalW, logicalH) }
}
