// ExplicitSync — linux-drm-syncobj-v1 (BACKLOG U.3b).
//
// A GPU client's buffer is not ready when it is committed; it is ready when
// the GPU says so. With implicit sync the kernel tracks that inside the
// dma-buf, and the renderer waits without being asked — which radeonsi and
// radv do, and NVIDIA's driver does not. Explicit sync says it out loud: each
// buffer comes with an ACQUIRE point on a DRM syncobj timeline (don't read it
// before this is signalled) and a RELEASE point (signal this when you are done
// with it, and not before — the client will draw into it again).
//
// Two halves, as `wlr_scene` has them:
//
//   - **acquire**: the scene hands each texture's acquire point to the
//     renderer as a wait (`wlr_render_texture_options.wait_timeline`), and the
//     GPU waits on it; nothing on the CPU blocks (SurfaceScene);
//   - **release**: when a commit brings a new buffer, its release point is
//     armed to be signalled when the buffer is released — when nothing, the
//     surface nor a frame in flight, holds it any longer (here).
//
// Offered only where both halves can be kept: the renderer must take waits
// and signals (`features.timeline`) and so must the backend's output commits.
// pixman does neither, so a software run offers none and says so — advertising
// it anyway would be §2.58 again, a global with nothing behind it, and a
// client that trusted it would wait for a release that never comes.

import CWlroots

final class SyncSurface {
    let surface: UnsafeMutablePointer<wlr_surface>
    var listeners: [UnsafeMutablePointer<tw_listener>?] = []
    weak var owner: ExplicitSync?
    init(_ s: UnsafeMutablePointer<wlr_surface>) { surface = s }
    deinit { for l in listeners { tw_listener_free(l) } }
}

public final class ExplicitSync {
    private var listener: UnsafeMutablePointer<tw_listener>?
    private var surfaces: [UnsafeMutableRawPointer: SyncSurface] = [:]
    /// Release points armed — one per new buffer from a client using it. The
    /// test's positive control: a client that never uses explicit sync leaves
    /// this at zero, and the test can tell.
    public private(set) var releasesArmed = 0

    /// Nil, with the reason logged, where it cannot be kept.
    init?(display: OpaquePointer, compositor comp: UnsafeMutablePointer<wlr_compositor>,
          renderer: UnsafeMutablePointer<wlr_renderer>, backend: UnsafeMutablePointer<wlr_backend>) {
        guard renderer.pointee.features.timeline else {
            Compositor.log("linux-drm-syncobj not offered — this renderer takes no timeline waits "
                           + "(pixman?); GPU clients use implicit sync")
            return nil
        }
        guard backend.pointee.features.timeline else {
            Compositor.log("linux-drm-syncobj not offered — this backend's output commits take no timelines")
            return nil
        }
        let fd = wlr_renderer_get_drm_fd(renderer)
        guard fd >= 0, wlr_linux_drm_syncobj_manager_v1_create(display, 1, fd) != nil else {
            Compositor.log("linux-drm-syncobj not offered — the render node refused a syncobj manager")
            return nil
        }
        Compositor.log("linux-drm-syncobj offered — the scene waits on acquire points and arms release points")
        let me = Unmanaged.passUnretained(self).toOpaque()
        listener = tw_listen(&comp.pointee.events.new_surface, { ctx, data in
            guard let ctx, let data else { return }
            Unmanaged<ExplicitSync>.fromOpaque(ctx).takeUnretainedValue()
                .track(data.assumingMemoryBound(to: wlr_surface.self))
        }, me)
    }

    deinit { tw_listener_free(listener) }

    private func track(_ s: UnsafeMutablePointer<wlr_surface>) {
        let e = SyncSurface(s)
        e.owner = self
        let ctx = Unmanaged.passUnretained(e).toOpaque()
        e.listeners.append(tw_listen(&s.pointee.events.commit, { ctx, _ in
            guard let ctx else { return }
            let e = Unmanaged<SyncSurface>.fromOpaque(ctx).takeUnretainedValue()
            e.owner?.committed(e.surface)
        }, ctx))
        e.listeners.append(tw_listen(&s.pointee.events.destroy, { ctx, _ in
            guard let ctx else { return }
            let e = Unmanaged<SyncSurface>.fromOpaque(ctx).takeUnretainedValue()
            // Off both signals during the emit (§2.82): dropping the entry
            // frees them.
            e.owner?.surfaces.removeValue(forKey: UnsafeMutableRawPointer(e.surface))
        }, ctx))
        surfaces[UnsafeMutableRawPointer(s)] = e
    }

    /// A new buffer with a release point: arm it. wlroots signals it when the
    /// buffer is released — the surface has moved on and no frame holds it.
    ///
    /// wlroots 0.20 made the release point private; the acquire point stands
    /// in for it, because the protocol requires the two together on any commit
    /// that attaches a buffer (`no_release_point`/`no_acquire_point` are
    /// errors). 0.20's helper would also accept a commit with neither and
    /// quietly arm nothing — the guard keeps `releasesArmed` a count of real
    /// releases, which is what live-syncobj.sh reads.
    private func committed(_ s: UnsafeMutablePointer<wlr_surface>) {
        guard s.pointee.current.committed & UInt32(WLR_SURFACE_STATE_BUFFER.rawValue) != 0,
              let buffer = s.pointee.buffer,
              let state = wlr_linux_drm_syncobj_v1_get_surface_state(s),
              state.pointee.acquire_timeline != nil else { return }
        if wlr_linux_drm_syncobj_v1_state_signal_release_with_buffer(state, &buffer.pointee.base) {
            releasesArmed += 1
        }
    }

    /// A surface's acquire point, for the scene's renderer to wait on.
    static func acquire(_ s: UnsafeMutablePointer<wlr_surface>)
        -> (timeline: UnsafeMutablePointer<wlr_drm_syncobj_timeline>?, point: UInt64) {
        guard let state = wlr_linux_drm_syncobj_v1_get_surface_state(s) else { return (nil, 0) }
        return (state.pointee.acquire_timeline, state.pointee.acquire_point)
    }
}
