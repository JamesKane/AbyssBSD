// Surface.SessionLock — the client side of ext-session-lock-v1 (PHASE16
// P16.2b): what the lock screen is, to the compositor.
//
// A `SessionLockClient` asks to lock the session and gives every display a
// `LockSurface` — including one plugged in while locked, since the compositor
// shows a display with no lock surface as a plain colour and a lock screen
// should cover it properly. The compositor answers `locked` (after it has drawn
// a frame with nothing of the desktop in it) or `finished` (it refused — another
// lock client holds the lock — or ended this one). Unlocking is one request,
// `unlock_and_destroy`, sent only once the authenticator has said yes.
//
// **Dying is not unlocking.** If this process exits or crashes without that
// request, the compositor keeps the session locked (undertow's rule, P16.2a);
// nothing here needs to be careful about that — only about not asking for it
// too early.

import CWayland

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

public protocol SessionLockDelegate: AnyObject {
    /// Draw the lock screen for one display.
    func render(_ buffer: PixelBuffer, on surface: LockSurface)
    func pointerMoved(x: Double, y: Double, on surface: LockSurface)
    func pointerButton(_ button: UInt32, pressed: Bool, on surface: LockSurface)
    /// Keys, from whichever lock surface holds the keyboard.
    func keyEvent(_ event: KeyEvent)
    /// The compositor has hidden the desktop.
    func sessionLocked()
    /// The compositor refused the lock, or ended it.
    func sessionLockFinished()
}

public extension SessionLockDelegate {
    func pointerMoved(x: Double, y: Double, on surface: LockSurface) {}
    func pointerButton(_ button: UInt32, pressed: Bool, on surface: LockSurface) {}
}

public final class SessionLockClient {
    let display: Display
    private var lock: OpaquePointer?
    public weak var delegate: SessionLockDelegate?
    public private(set) var surfaces: [LockSurface] = []
    public private(set) var isLocked = false

    /// Ask to lock. Nil when the compositor offers no ext-session-lock — a
    /// lock screen that cannot lock must say so, not pretend.
    public init?(display: Display, delegate: SessionLockDelegate) {
        guard let manager = display.sessionLockManager,
              let l = ext_session_lock_manager_v1_lock(manager) else { return nil }
        self.display = display
        self.delegate = delegate
        lock = l
        let me = Unmanaged.passUnretained(self).toOpaque()
        var ll = ext_session_lock_v1_listener()
        ll.locked = { data, _ in
            guard let data else { return }
            let c = Unmanaged<SessionLockClient>.fromOpaque(data).takeUnretainedValue()
            c.isLocked = true
            c.delegate?.sessionLocked()
        }
        ll.finished = { data, _ in
            guard let data else { return }
            let c = Unmanaged<SessionLockClient>.fromOpaque(data).takeUnretainedValue()
            c.finished()
        }
        display.addListener(to: l, listener: ll, data: me)
        for i in 0..<display.outputCount { addSurface(output: i) }
        // A display that arrives while locked gets its own lock surface.
        display.outputAdded = { [weak self] i in self?.addSurface(output: i) }
        display.outputRemoved = { [weak self] proxy in
            guard let self else { return }
            for s in self.surfaces where s.output == proxy { s.close() }
            self.surfaces.removeAll { $0.output == proxy }
        }
        display.flush()
    }

    deinit { teardown() }

    private func addSurface(output index: Int) {
        guard let lock, let output = display.output(at: index),
              let s = LockSurface(client: self, lock: lock, output: output, index: index) else { return }
        surfaces.append(s)
    }

    /// The authenticator said yes: give the session back. Only then.
    public func unlock() {
        guard let l = lock else { return }
        for s in surfaces { s.close() }
        surfaces.removeAll()
        ext_session_lock_v1_unlock_and_destroy(l)
        lock = nil
        isLocked = false
        display.flush()
        display.roundtrip()
    }

    private func finished() {
        isLocked = false
        teardown()
        delegate?.sessionLockFinished()
    }

    private func teardown() {
        display.outputAdded = nil
        display.outputRemoved = nil
        for s in surfaces { s.close() }
        surfaces.removeAll()
        // `destroy` after `finished` is the protocol's way out; before it,
        // destroying a held lock is a protocol error, so it is only ever
        // reached here when the lock was refused or already given back.
        if let l = lock { ext_session_lock_v1_destroy(l); lock = nil }
        display.flush()
    }

    public func setNeedsDisplay() { for s in surfaces { s.setNeedsDisplay() } }
}

/// One display's lock surface: shm buffers, the configure handshake, frame
/// pacing — the trimmed shape of `LayerSurface`, with its size always the
/// display's (the compositor says so in the configure, and nothing else is
/// allowed).
public final class LockSurface {
    unowned let client: SessionLockClient
    public let surface: OpaquePointer
    private let lockSurface: OpaquePointer
    let output: OpaquePointer
    /// The display's place in the registry's order: 0 is the first.
    public let index: Int

    public private(set) var width: Int32 = 0
    public private(set) var height: Int32 = 0
    public private(set) var scale: Int32 = 1
    private var buffers: [ShmBuffer] = []
    private var needsRedraw = true
    private var framePending = false
    private var frameCallback: OpaquePointer?
    private var tornDown = false

    init?(client: SessionLockClient, lock: OpaquePointer, output: OpaquePointer, index: Int) {
        let display = client.display
        guard let compositor = display.compositor,
              let surf = wl_compositor_create_surface(compositor) else { return nil }
        guard let ls = ext_session_lock_v1_get_lock_surface(lock, surf, output) else {
            wl_surface_destroy(surf); return nil
        }
        self.client = client
        self.surface = surf
        self.lockSurface = ls
        self.output = output
        self.index = index
        self.scale = display.outputScale(output)
        let me = Unmanaged.passUnretained(self).toOpaque()
        var l = ext_session_lock_surface_v1_listener()
        l.configure = { data, _, serial, w, h in
            guard let data else { return }
            let s = Unmanaged<LockSurface>.fromOpaque(data).takeUnretainedValue()
            s.configure(serial: serial, w: Int32(bitPattern: w), h: Int32(bitPattern: h))
        }
        display.addListener(to: ls, listener: l, data: me)
        display.lockSurfaceAdded(self)
    }

    deinit { close() }

    func close() {
        guard !tornDown else { return }
        tornDown = true
        client.display.lockSurfaceRemoved(self)
        for b in buffers { b.destroy() }
        buffers.removeAll()
        if let c = frameCallback { wl_callback_destroy(c); frameCallback = nil }
        ext_session_lock_surface_v1_destroy(lockSurface)
        wl_surface_destroy(surface)
    }

    public func setNeedsDisplay() {
        guard !tornDown else { return }
        needsRedraw = true
        if !framePending, !buffers.isEmpty { renderAndCommit() }
    }

    private func configure(serial: UInt32, w: Int32, h: Int32) {
        ext_session_lock_surface_v1_ack_configure(lockSurface, serial)
        let s = client.display.outputScale(output)
        if w != width || h != height || s != scale || buffers.isEmpty {
            width = max(1, w); height = max(1, h); scale = s
            for b in buffers { b.destroy() }
            buffers.removeAll()
            for _ in 0..<2 {
                guard let b = ShmBuffer(display: client.display, width: width * scale, height: height * scale)
                else { continue }
                b.attachReleaseListener(display: client.display)
                buffers.append(b)
            }
        }
        needsRedraw = true
        if !framePending { renderAndCommit() }
    }

    private func renderAndCommit() {
        guard !tornDown, let buf = buffers.first(where: { !$0.busy }) else { needsRedraw = true; return }
        client.delegate?.render(PixelBuffer(data: buf.data, width: buf.width, height: buf.height,
                                            stride: buf.stride, scale: scale), on: self)
        buf.busy = true
        wl_surface_attach(surface, buf.wlBuffer, 0, 0)
        wl_surface_set_buffer_scale(surface, scale)
        wl_surface_damage_buffer(surface, 0, 0, buf.width, buf.height)
        if let cb = wl_surface_frame(surface) {
            frameCallback = cb
            var cl = wl_callback_listener()
            cl.done = { data, cb, _ in
                if let cb { wl_callback_destroy(cb) }
                guard let data else { return }
                let s = Unmanaged<LockSurface>.fromOpaque(data).takeUnretainedValue()
                s.frameCallback = nil
                s.framePending = false
                if s.needsRedraw { s.renderAndCommit() }
            }
            client.display.addListener(to: cb, listener: cl, data: Unmanaged.passUnretained(self).toOpaque())
            framePending = true
        }
        needsRedraw = false
        wl_surface_commit(surface)
        client.display.flush()
    }

    func pointerMoved(fx: Int32, fy: Int32) {
        client.delegate?.pointerMoved(x: Double(fx) / 256.0, y: Double(fy) / 256.0, on: self)
    }
    func pointerButton(_ button: UInt32, pressed: Bool) {
        client.delegate?.pointerButton(button, pressed: pressed, on: self)
    }
    func pointerLeft() {}
    func keyEvent(_ event: KeyEvent) { client.delegate?.keyEvent(event) }
}
