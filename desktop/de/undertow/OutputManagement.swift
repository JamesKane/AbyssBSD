// OutputManagement — wlr-output-management-v1, server side (PHASE14 P14.7b).
//
// The protocol the Displays pane speaks, and so do `wlr-randr` and `kanshi`: a
// client reads every output's modes, position and scale, and asks for a new
// arrangement to be *tested* or *applied*. The compositor answers succeeded or
// failed, and afterwards tells every client what is now true.
//
// **Whole or not at all.** A configuration is checked (`DisplaysConfig.problems`
// — no overlaps, a sane scale, nothing turned off), then every output's new
// state is test-committed, and only when all of them pass is anything
// committed. What was applied is written to displays.ini, which undertow applies
// at start: the file is always what is on screen, whoever changed it.

import CWlroots

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

public final class OutputManagement {
    private let manager: UnsafeMutablePointer<wlr_output_manager_v1>
    private unowned let compositor: Compositor
    private var listeners: [UnsafeMutablePointer<tw_listener>?] = []
    /// After a configuration is applied, with the new layout: the run loop
    /// re-aims each output's scene and, for a new refresh rate, its metronome.
    public var onApplied: (DisplayLayout) -> Void = { _ in }
    public private(set) var appliedCount = 0
    public private(set) var refusedCount = 0

    init?(compositor: Compositor) {
        guard let m = wlr_output_manager_v1_create(compositor.session.display) else { return nil }
        manager = m
        self.compositor = compositor
        let me = Unmanaged.passUnretained(self).toOpaque()
        listeners.append(tw_listen(&m.pointee.events.apply, { ctx, data in
            guard let ctx, let data else { return }
            Unmanaged<OutputManagement>.fromOpaque(ctx).takeUnretainedValue()
                .handle(data.assumingMemoryBound(to: wlr_output_configuration_v1.self), apply: true)
        }, me))
        listeners.append(tw_listen(&m.pointee.events.test, { ctx, data in
            guard let ctx, let data else { return }
            Unmanaged<OutputManagement>.fromOpaque(ctx).takeUnretainedValue()
                .handle(data.assumingMemoryBound(to: wlr_output_configuration_v1.self), apply: false)
        }, me))
        publish()
    }

    deinit { for l in listeners { tw_listener_free(l) } }

    /// Tell every client what is true now. wlroots fills each head from its
    /// output; the position and scale are ours.
    public func publish() {
        guard let config = wlr_output_configuration_v1_create() else { return }
        for d in compositor.layout.displays {
            guard let o = compositor.session.output(named: d.name),
                  let head = wlr_output_configuration_head_v1_create(config, o) else { continue }
            head.pointee.state.x = d.x
            head.pointee.state.y = d.y
            head.pointee.state.scale = Float(d.scale)
        }
        wlr_output_manager_v1_set_configuration(manager, config)   // takes ownership
    }

    /// What a head asks for, as a setting.
    private static func setting(_ h: UnsafeMutablePointer<wlr_output_configuration_head_v1>) -> DisplaySetting? {
        let st = h.pointee.state
        guard let o = st.output else { return nil }
        var w = st.custom_mode.width, ht = st.custom_mode.height, r = st.custom_mode.refresh
        if let m = st.mode { w = m.pointee.width; ht = m.pointee.height; r = m.pointee.refresh }
        return DisplaySetting(name: String(cString: o.pointee.name), enabled: st.enabled,
                              modeWidth: w, modeHeight: ht, refreshMilliHz: r,
                              x: st.x, y: st.y, scale: Double(st.scale))
    }

    private func handle(_ config: UnsafeMutablePointer<wlr_output_configuration_v1>, apply: Bool) {
        defer { wlr_output_configuration_v1_destroy(config) }
        let verb = apply ? "apply" : "test"
        func refuse(_ why: String) {
            refusedCount += 1
            Compositor.log("output-config \(verb) refused: \(why)")
            wlr_output_configuration_v1_send_failed(config)
        }

        var heads = [UnsafeMutablePointer<wlr_output_configuration_head_v1>?](repeating: nil, count: 32)
        let n = heads.withUnsafeMutableBufferPointer { tw_output_config_heads(config, $0.baseAddress, 32) }
        let asked = heads.prefix(min(n, 32)).compactMap { $0 }
        let settings = asked.compactMap(OutputManagement.setting)
        var problems = DisplaysConfig.problems(settings)
        // A display the configuration leaves out is one it turns off.
        for d in compositor.layout.displays where !settings.contains(where: { $0.name == d.name }) {
            problems.append("\(d.name) is not in the configuration (turning a display off is not supported yet)")
        }
        if !problems.isEmpty { return refuse(problems.joined(separator: "; ")) }

        // Every output's new state must pass a test commit before any is made.
        for h in asked {
            guard let o = h.pointee.state.output else { continue }
            var os = wlr_output_state()
            wlr_output_state_init(&os)
            wlr_output_head_v1_state_apply(&h.pointee.state, &os)
            let ok = wlr_output_test_state(o, &os)
            wlr_output_state_finish(&os)
            if !ok { return refuse("\(String(cString: o.pointee.name)) refused that mode or scale") }
        }
        guard apply else {
            Compositor.log("output-config test ok: " + settings.map(DisplaysConfig.format).joined(separator: "; "))
            wlr_output_configuration_v1_send_succeeded(config)
            return
        }

        for h in asked {
            guard let o = h.pointee.state.output else { continue }
            var os = wlr_output_state()
            wlr_output_state_init(&os)
            wlr_output_head_v1_state_apply(&h.pointee.state, &os)
            let ok = wlr_output_commit_state(o, &os)
            wlr_output_state_finish(&os)
            // Tested a moment ago; a failure now is the backend's, and the
            // outputs already committed stay as they are — said, not hidden.
            if !ok { return refuse("\(String(cString: o.pointee.name)) failed to commit after its test passed") }
        }
        // The layout, in the order it had: the main display stays the main one.
        let order = compositor.layout.displays.map(\.name)
        let boxes = order.compactMap { name in settings.first { $0.name == name }?.box }
        compositor.applyLayout(DisplayLayout(boxes))
        do { try DisplaysFile.store(settings, configDir: compositor.configDir) } catch {
            Compositor.log("output-config: applied, but displays.ini could not be written: \(error)")
        }
        appliedCount += 1
        Compositor.log("output-config applied: \(compositor.layout.summary)")
        onApplied(compositor.layout)
        wlr_output_configuration_v1_send_succeeded(config)
        publish()
    }

    /// Put a saved setting on an output before the run starts (displays.ini).
    /// A headless or nested output takes any mode; a real one is asked for a
    /// custom mode, which DRM turns into a CVT timing — a named mode from the
    /// output's own list is P14.7c's, when the pane offers them.
    public static func commit(_ s: DisplaySetting, to output: UnsafeMutablePointer<wlr_output>) -> Bool {
        var os = wlr_output_state()
        wlr_output_state_init(&os)
        defer { wlr_output_state_finish(&os) }
        wlr_output_state_set_enabled(&os, true)
        if s.modeWidth != output.pointee.width || s.modeHeight != output.pointee.height
            || (s.refreshMilliHz != 0 && s.refreshMilliHz != output.pointee.refresh) {
            wlr_output_state_set_custom_mode(&os, s.modeWidth, s.modeHeight, s.refreshMilliHz)
        }
        wlr_output_state_set_scale(&os, Float(s.scale))
        return wlr_output_commit_state(output, &os)
    }
}
