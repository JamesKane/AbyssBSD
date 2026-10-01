// Undertow — wlr-layer-shell, server side (PHASE6.md P6.6).
//
// The protocol the whole Aqua shell is built on: the wallpaper is a BACKGROUND
// surface, the menu bar a TOP strip with an exclusive zone, the Dock a BOTTOM
// shelf, and a notification toast an OVERLAY. Phase 2 wrote all four as clients
// against sway; this is the other end of that conversation.
//
// **`arrange()` is the whole pass.** A layer surface does not choose where it
// goes — it states anchors, a desired size, margins and an exclusive zone, and
// the compositor decides. Getting that arithmetic right is what makes the menu
// bar reserve 22px that the desktop then does not paint under, which is the
// property `live-session.sh` has asserted since Phase 2 (HANDOFF §2.26: a layer
// surface never appears in a window tree, so the *usable area* is the only
// observable proof it worked).

import CWlroots

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// The anchor bits, spelled out. Same values as the protocol; named here so the
/// arithmetic below reads as geometry rather than as bit twiddling.
public struct LayerAnchor: OptionSet, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public static let top = LayerAnchor(rawValue: 1)
    public static let bottom = LayerAnchor(rawValue: 2)
    public static let left = LayerAnchor(rawValue: 4)
    public static let right = LayerAnchor(rawValue: 8)
    /// Anchored to both edges of an axis means "span it".
    public var spansHorizontally: Bool { contains(.left) && contains(.right) }
    public var spansVertically: Bool { contains(.top) && contains(.bottom) }
}

/// A rectangle, in output coordinates.
public struct Rect: Equatable, Sendable {
    public var x, y, width, height: Int32
    public init(x: Int32, y: Int32, width: Int32, height: Int32) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
}

/// What a layer surface asks for. Pulled out of the protocol state so the
/// placement rule can be tested without a compositor or a client — the same
/// argument as `PointerRouting` (P6.4) and §2.9's one-pure-function discipline.
public struct LayerRequest: Equatable, Sendable {
    public var anchor: LayerAnchor
    public var desiredWidth: Int32
    public var desiredHeight: Int32
    public var marginTop: Int32 = 0
    public var marginRight: Int32 = 0
    public var marginBottom: Int32 = 0
    public var marginLeft: Int32 = 0
    /// Space to reserve for this surface along its anchored edge. `-1` means
    /// "ignore everyone else's reservations and take the whole output" — which
    /// is exactly what the desktop asks for, so the wallpaper paints under the
    /// menu bar rather than starting below it (HANDOFF §2.26).
    public var exclusiveZone: Int32 = 0

    public init(anchor: LayerAnchor, desiredWidth: Int32, desiredHeight: Int32) {
        self.anchor = anchor
        self.desiredWidth = desiredWidth
        self.desiredHeight = desiredHeight
    }
}

/// The placement rule, as a pure function.
public enum LayerArrange {
    /// Where a surface goes, and what the usable area becomes afterwards.
    ///
    /// Returns the surface's rect plus the remaining usable area — so callers
    /// fold over their surfaces and end up with the workspace rectangle a
    /// toplevel should be given. That fold order matters: a surface with an
    /// exclusive zone shrinks the area for everyone arranged *after* it, which
    /// is why the menu bar (arranged first) reserves space and the Dock
    /// (arranged later, zone 0) simply overlaps.
    public static func place(_ req: LayerRequest, in usable: Rect, output: Rect)
        -> (rect: Rect, usable: Rect) {
        // A zone of -1 means "I ignore reservations": lay out against the whole
        // output, and change nothing for anyone else.
        let box = req.exclusiveZone < 0 ? output : usable

        var w = Int32(req.desiredWidth)
        var h = Int32(req.desiredHeight)
        // Zero means "you choose", which for an anchored-both-sides axis means
        // span it, and otherwise means the whole box.
        if w == 0 { w = box.width - req.marginLeft - req.marginRight }
        if h == 0 { h = box.height - req.marginTop - req.marginBottom }
        if req.anchor.spansHorizontally { w = box.width - req.marginLeft - req.marginRight }
        if req.anchor.spansVertically { h = box.height - req.marginTop - req.marginBottom }
        w = max(w, 0); h = max(h, 0)

        // Horizontal placement.
        var x: Int32
        if req.anchor.contains(.left) && !req.anchor.contains(.right) {
            x = box.x + req.marginLeft
        } else if req.anchor.contains(.right) && !req.anchor.contains(.left) {
            x = box.x + box.width - w - req.marginRight
        } else {
            x = box.x + (box.width - w) / 2      // centred, spanning or neither
        }
        // Vertical placement.
        var y: Int32
        if req.anchor.contains(.top) && !req.anchor.contains(.bottom) {
            y = box.y + req.marginTop
        } else if req.anchor.contains(.bottom) && !req.anchor.contains(.top) {
            y = box.y + box.height - h - req.marginBottom
        } else {
            y = box.y + (box.height - h) / 2
        }

        let rect = Rect(x: x, y: y, width: w, height: h)
        guard req.exclusiveZone > 0 else { return (rect, usable) }

        // Reserve along the one edge this surface is anchored to. A surface
        // anchored to opposite edges reserves nothing — there is no unambiguous
        // side to take it from.
        var left = usable
        let zone = req.exclusiveZone
        if req.anchor.contains(.top) && !req.anchor.contains(.bottom) {
            let take = min(zone + req.marginTop, left.height)
            left.y += take; left.height -= take
        } else if req.anchor.contains(.bottom) && !req.anchor.contains(.top) {
            left.height -= min(zone + req.marginBottom, left.height)
        } else if req.anchor.contains(.left) && !req.anchor.contains(.right) {
            let take = min(zone + req.marginLeft, left.width)
            left.x += take; left.width -= take
        } else if req.anchor.contains(.right) && !req.anchor.contains(.left) {
            left.width -= min(zone + req.marginRight, left.width)
        }
        left.width = max(left.width, 0)
        left.height = max(left.height, 0)
        return (rect, left)
    }
}

/// One layer-shell surface (wallpaper, menu bar, Dock, toast).
public final class LayerSurface {
    let handle: UnsafeMutablePointer<wlr_layer_surface_v1>
    public let surface: UnsafeMutablePointer<wlr_surface>
    public private(set) var mapped = false
    public private(set) var rect = Rect(x: 0, y: 0, width: 0, height: 0)
    public var namespace: String {
        handle.pointee.namespace.map { String(cString: $0) } ?? ""
    }
    /// 0 background, 1 bottom, 2 top, 3 overlay — the paint order.
    public var layer: UInt32 { handle.pointee.current.layer.rawValue }
    /// Whether a click should hand this surface the keyboard: `on_demand`
    /// (the menu bar) or `exclusive` (P10.4 — undertow ignored both).
    public var takesKeyboardOnClick: Bool {
        handle.pointee.current.keyboard_interactive
            != ZWLR_LAYER_SURFACE_V1_KEYBOARD_INTERACTIVITY_NONE
    }

    /// `exclusive` on the top or overlay layer: the protocol's "this surface
    /// receives all keyboard input" — a lock screen, Grab's overlay (P15.6).
    /// Given the keyboard as it maps, with no click; undertow did neither
    /// until now.
    public var wantsExclusiveKeyboard: Bool {
        handle.pointee.current.keyboard_interactive == ZWLR_LAYER_SURFACE_V1_KEYBOARD_INTERACTIVITY_EXCLUSIVE
            && layer >= 2
    }

    private func claimKeyboardIfExclusive() {
        guard mapped, wantsExclusiveKeyboard, let seat = compositor.seat, seat.keyboardLayer !== self else { return }
        seat.giveKeyboard(to: self)
    }

    private func releaseKeyboard() {
        if let seat = compositor.seat, seat.keyboardLayer === self { seat.restoreKeyboard() }
    }

    private unowned let compositor: Compositor
    private var listeners: [UnsafeMutablePointer<tw_listener>?] = []

    init(_ handle: UnsafeMutablePointer<wlr_layer_surface_v1>, compositor: Compositor) {
        self.handle = handle
        self.surface = handle.pointee.surface
        self.compositor = compositor

        let me = Unmanaged.passUnretained(self).toOpaque()
        listeners.append(tw_listen(&surface.pointee.events.map, { ctx, _ in
            guard let ctx else { return }
            let l = Unmanaged<LayerSurface>.fromOpaque(ctx).takeUnretainedValue()
            l.mapped = true
            l.compositor.arrangeLayers()
            l.claimKeyboardIfExclusive()
        }, me))
        listeners.append(tw_listen(&surface.pointee.events.unmap, { ctx, _ in
            guard let ctx else { return }
            let l = Unmanaged<LayerSurface>.fromOpaque(ctx).takeUnretainedValue()
            l.mapped = false
            l.compositor.arrangeLayers()
            l.releaseKeyboard()
        }, me))
        listeners.append(tw_listen(&surface.pointee.events.commit, { ctx, _ in
            guard let ctx else { return }
            let l = Unmanaged<LayerSurface>.fromOpaque(ctx).takeUnretainedValue()
            // Same rule as xdg-shell: the client's first commit must be answered
            // with a configure before it may attach anything. It also re-arranges
            // on any commit, because a client may change its anchors or its
            // exclusive zone at any time — the menu bar does exactly that when a
            // menu opens.
            l.compositor.arrangeLayers()
            l.claimKeyboardIfExclusive()               // asked for after mapping
            _ = l.handle.pointee.initial_commit
        }, me))
        listeners.append(tw_listen(&handle.pointee.events.destroy, { ctx, _ in
            guard let ctx else { return }
            let l = Unmanaged<LayerSurface>.fromOpaque(ctx).takeUnretainedValue()
            l.mapped = false
            l.releaseKeyboard()
            l.compositor.forgetLayer(l)
        }, me))
    }

    func teardown() {
        for l in listeners { tw_listener_free(l) }
        listeners.removeAll()
    }
    deinit { teardown() }

    /// What this surface is asking for, read out of the protocol state.
    var request: LayerRequest {
        let s = handle.pointee.current
        var r = LayerRequest(anchor: LayerAnchor(rawValue: s.anchor),
                             desiredWidth: Int32(s.desired_width),
                             desiredHeight: Int32(s.desired_height))
        r.marginTop = s.margin.top
        r.marginRight = s.margin.right
        r.marginBottom = s.margin.bottom
        r.marginLeft = s.margin.left
        r.exclusiveZone = s.exclusive_zone
        return r
    }

    /// Tell the client the size we decided on.
    func configure(_ rect: Rect) {
        self.rect = rect
        _ = wlr_layer_surface_v1_configure(handle, UInt32(max(rect.width, 0)),
                                           UInt32(max(rect.height, 0)))
    }

    public var width: Int32 { surface.pointee.current.width }
    public var height: Int32 { surface.pointee.current.height }
    /// The output it is on, by name ("" before one is assigned).
    public var outputName: String { handle.pointee.output.map { String(cString: $0.pointee.name) } ?? "" }
}
