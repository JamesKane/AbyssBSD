// SessionLock — ext-session-lock-v1 (PHASE16 P16.2a).
//
// A lock client (the Aqua lock screen, P16.2b) asks to lock the session; from
// then until it unlocks, **nothing of the desktop is shown and nothing of the
// desktop is reachable**: every output draws the lock client's surface for it
// and nothing else, and the pointer and the keys go to those surfaces alone.
// This is the security boundary of the whole session (PHASE16 §6.6), so the
// rules are sway's and the protocol's, and each has a test:
//
//   - **One lock at a time.** A second client asking while a lock is held is
//     told `finished` — it cannot take over a lock somebody else holds.
//   - **A lock client that dies without unlocking leaves the session locked**
//     ("abandoned"). The outputs show the plain lock colour, input reaches
//     nothing, and a new lock client may then take over — which is how a
//     person gets back in after the lock screen crashed.
//   - **`locked` is said after a frame**, so the frame that hides everything
//     has been drawn before the client is told the session is locked.
//   - Windows that map while locked are not drawn, and are not focused.

import CWlroots

final class LockSurfaceEntry {
    let lockSurface: UnsafeMutablePointer<wlr_session_lock_surface_v1>
    var listeners: [UnsafeMutablePointer<tw_listener>?] = []
    weak var owner: SessionLock?
    init(_ s: UnsafeMutablePointer<wlr_session_lock_surface_v1>) { lockSurface = s }
    deinit { for l in listeners { tw_listener_free(l) } }

    var surface: UnsafeMutablePointer<wlr_surface> { lockSurface.pointee.surface }
    var outputName: String { lockSurface.pointee.output.map { String(cString: $0.pointee.name) } ?? "" }
}

public final class SessionLock {
    private unowned let compositor: Compositor
    private var managerListener: UnsafeMutablePointer<tw_listener>?
    /// The lock object currently held, nil when none is — unlocked, or abandoned.
    private var lock: UnsafeMutablePointer<wlr_session_lock_v1>?
    private var lockListeners: [UnsafeMutablePointer<tw_listener>?] = []
    private(set) var surfaces: [LockSurfaceEntry] = []
    /// `locked` is owed to the client, after the next frame.
    private var lockedOwed = false

    /// **The session is locked** — held, or abandoned by a client that died.
    public private(set) var locked = false
    /// Locked with nobody holding the lock: its client died without unlocking.
    public var abandoned: Bool { locked && lock == nil }
    /// For the log a test reads.
    public private(set) var locks = 0, unlocks = 0, refused = 0, abandonments = 0

    init?(compositor: Compositor) {
        guard let m = wlr_session_lock_manager_v1_create(compositor.session.display) else { return nil }
        self.compositor = compositor
        let me = Unmanaged.passUnretained(self).toOpaque()
        managerListener = tw_listen(&m.pointee.events.new_lock, { ctx, data in
            guard let ctx, let data else { return }
            Unmanaged<SessionLock>.fromOpaque(ctx).takeUnretainedValue()
                .newLock(data.assumingMemoryBound(to: wlr_session_lock_v1.self))
        }, me)
    }

    deinit {
        tw_listener_free(managerListener)
        for l in lockListeners { tw_listener_free(l) }
    }

    private func newLock(_ l: UnsafeMutablePointer<wlr_session_lock_v1>) {
        // Somebody already holds it: they keep it (`finished` to this one).
        guard lock == nil else {
            refused += 1
            Compositor.log("session lock refused: another client holds the lock")
            wlr_session_lock_v1_destroy(l)
            return
        }
        let wasAbandoned = abandoned
        lock = l
        locked = true
        locks += 1
        lockedOwed = true
        let me = Unmanaged.passUnretained(self).toOpaque()
        lockListeners.append(tw_listen(&l.pointee.events.new_surface, { ctx, data in
            guard let ctx, let data else { return }
            Unmanaged<SessionLock>.fromOpaque(ctx).takeUnretainedValue()
                .newSurface(data.assumingMemoryBound(to: wlr_session_lock_surface_v1.self))
        }, me))
        lockListeners.append(tw_listen(&l.pointee.events.unlock, { ctx, _ in
            guard let ctx else { return }
            Unmanaged<SessionLock>.fromOpaque(ctx).takeUnretainedValue().unlocked()
        }, me))
        lockListeners.append(tw_listen(&l.pointee.events.destroy, { ctx, _ in
            guard let ctx else { return }
            Unmanaged<SessionLock>.fromOpaque(ctx).takeUnretainedValue().lockGone()
        }, me))
        Compositor.log(wasAbandoned ? "session locked again, taking over an abandoned lock"
                                    : "session locked")
        // Nothing behind the lock keeps the pointer or the keys.
        compositor.seat?.sessionLocked()
    }

    private func newSurface(_ s: UnsafeMutablePointer<wlr_session_lock_surface_v1>) {
        let e = LockSurfaceEntry(s)
        e.owner = self
        let ctx = Unmanaged.passUnretained(e).toOpaque()
        e.listeners.append(tw_listen(&s.pointee.events.destroy, { ctx, _ in
            guard let ctx else { return }
            let e = Unmanaged<LockSurfaceEntry>.fromOpaque(ctx).takeUnretainedValue()
            // Off the signal during the emit (§2.82): dropping the entry frees it.
            e.owner?.surfaces.removeAll { $0 === e }
        }, ctx))
        // The first buffer: give it the keyboard if the lock has nobody's.
        e.listeners.append(tw_listen(&s.pointee.surface.pointee.events.commit, { ctx, _ in
            guard let ctx else { return }
            let e = Unmanaged<LockSurfaceEntry>.fromOpaque(ctx).takeUnretainedValue()
            e.owner?.compositor.seat?.lockSurfaceCommitted(e.surface)
        }, ctx))
        surfaces.append(e)
        // Its output's whole size, in the layout's points.
        let box = compositor.layout.displays.first { $0.name == e.outputName }
        _ = wlr_session_lock_surface_v1_configure(s, UInt32(box?.width ?? 0), UInt32(box?.height ?? 0))
    }

    private func unlocked() {
        locked = false
        unlocks += 1
        Compositor.log("session unlocked")
        lock = nil
        surfaces.removeAll()
        compositor.seat?.sessionUnlocked()
    }

    /// The lock object went. After `unlock` that is the end of it; without,
    /// the client died holding the lock, and the session stays locked.
    private func lockGone() {
        for l in lockListeners { tw_listener_free(l) }
        lockListeners = []
        guard lock != nil else { return }
        lock = nil
        lockedOwed = false
        abandonments += 1
        Compositor.log("the lock client went without unlocking: the session STAYS locked")
    }

    /// Once a frame has been drawn under the lock, say so to its client.
    func frameDrawn() {
        guard lockedOwed, let l = lock else { return }
        lockedOwed = false
        wlr_session_lock_v1_send_locked(l)
    }

    /// The lock surface for the display named `name`, mapped, if there is one.
    func surface(on name: String) -> UnsafeMutablePointer<wlr_surface>? {
        surfaces.first { $0.outputName == name && wlr_surface_has_buffer($0.surface) }?.surface
    }

    /// Every lock surface with a buffer, with the display it covers.
    var mapped: [(surface: UnsafeMutablePointer<wlr_surface>, display: DisplayBox)] {
        surfaces.compactMap { e in
            guard wlr_surface_has_buffer(e.surface),
                  let d = compositor.layout.displays.first(where: { $0.name == e.outputName }) else { return nil }
            return (e.surface, d)
        }
    }
}
