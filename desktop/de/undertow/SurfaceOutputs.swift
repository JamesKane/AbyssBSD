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
        var outs: [(rect: Rect, output: UnsafeMutablePointer<wlr_output>)] = []
        for d in layout.displays { if let o = session.output(named: d.name) { outs.append((d.rect, o)) } }
        guard !outs.isEmpty else { return }
        func tell(_ root: UnsafeMutablePointer<wlr_surface>, _ r: Rect?) {
            for (d, o) in outs {
                let on = r.map { r in
                    min(r.x + r.width, d.x + d.width) > max(r.x, d.x) && min(r.y + r.height, d.y + d.height) > max(r.y, d.y)
                } ?? false
                let job = SurfaceOutputJob(output: o, enter: on)
                wlr_surface_for_each_surface(root, { s, _, _, data in
                    guard let s, let data else { return }
                    let j = Unmanaged<SurfaceOutputJob>.fromOpaque(data).takeUnretainedValue()
                    if j.enter { wlr_surface_send_enter(s, j.output) } else { wlr_surface_send_leave(s, j.output) }
                }, Unmanaged.passUnretained(job).toOpaque())
            }
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
    }
}

private final class SurfaceOutputJob {
    let output: UnsafeMutablePointer<wlr_output>
    let enter: Bool
    init(output: UnsafeMutablePointer<wlr_output>, enter: Bool) { self.output = output; self.enter = enter }
}
