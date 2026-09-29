// Which outputs a surface is on — wl_surface.enter and leave (BACKLOG U.10).

import CWlroots

// MARK: - Which outputs a surface is on (U.10)

extension Compositor {
    /// Tell every visible surface which outputs it is on: `wl_surface.enter`
    /// and `leave`, which undertow never sent (HANDOFF §2.71). A client learns
    /// its scale from the outputs it has entered, so until this, a window on
    /// a scale-2 display could not know it. Both wlroots calls are no-ops when
    /// nothing changed, so this runs every loop iteration — off the present
    /// path — and sends only changes. A surface's rectangle decides: its
    /// subsurfaces are told what their root is.
    public func updateSurfaceOutputs() {
        var outs: [(rect: Rect, output: UnsafeMutablePointer<wlr_output>, scale: Double)] = []
        for d in layout.displays { if let o = session.output(named: d.name) { outs.append((d.rect, o, d.scale)) } }
        guard !outs.isEmpty else { return }
        func tell(_ root: UnsafeMutablePointer<wlr_surface>, _ r: Rect?) {
            // The scale a surface should draw at (U.8): the largest of the
            // displays it is on — too sharp on the smaller is right; too soft
            // on the larger is what the person sees. On none (minimised), the
            // last it was told stands.
            var best = 0.0
            for (d, o, scale) in outs {
                let on = r.map { r in
                    min(r.x + r.width, d.x + d.width) > max(r.x, d.x) && min(r.y + r.height, d.y + d.height) > max(r.y, d.y)
                } ?? false
                if on { best = max(best, scale) }
                let job = SurfaceOutputJob(output: o, enter: on)
                wlr_surface_for_each_surface(root, { s, _, _, data in
                    guard let s, let data else { return }
                    let j = Unmanaged<SurfaceOutputJob>.fromOpaque(data).takeUnretainedValue()
                    if j.enter { wlr_surface_send_enter(s, j.output) } else { wlr_surface_send_leave(s, j.output) }
                }, Unmanaged.passUnretained(job).toOpaque())
            }
            guard best > 0 else { return }
            // Both ways a client can hear it: fractional-scale-v1's preferred
            // scale, and wl_surface v6's integer preferred_buffer_scale (for
            // the toolkits that know only that). wlroots sends each only when
            // it changes.
            let job = SurfaceScaleJob(best)
            wlr_surface_for_each_surface(root, { s, _, _, data in
                guard let s, let data else { return }
                let j = Unmanaged<SurfaceScaleJob>.fromOpaque(data).takeUnretainedValue()
                wlr_fractional_scale_v1_notify_scale(s, j.scale)
                wlr_surface_set_preferred_buffer_scale(s, Int32(j.scale.rounded(.up)))
            }, Unmanaged.passUnretained(job).toOpaque())
        }
        for t in toplevels where t.mapped {
            // Minimised: on no output — it is not shown anywhere.
            tell(t.surface, t.minimized ? nil : Rect(x: t.x, y: t.y, width: t.width, height: t.height))
        }
        for l in mappedLayers { tell(l.surface, l.rect) }
        for p in mappedPopups {
            guard let o = p.origin else { continue }
            tell(p.surface, Rect(x: o.x, y: o.y, width: p.width, height: p.height))
        }
        for p in seat?.textInput?.mappedPopups ?? [] {
            tell(p.surface, Rect(x: p.x, y: p.y, width: p.surface.pointee.current.width,
                                 height: p.surface.pointee.current.height))
        }
    }
}

private final class SurfaceOutputJob {
    let output: UnsafeMutablePointer<wlr_output>
    let enter: Bool
    init(output: UnsafeMutablePointer<wlr_output>, enter: Bool) { self.output = output; self.enter = enter }
}

private final class SurfaceScaleJob {
    let scale: Double
    init(_ scale: Double) { self.scale = scale }
}
