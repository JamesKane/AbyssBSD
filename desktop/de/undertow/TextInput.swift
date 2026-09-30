// TextInput — text-input-v3 and input-method-v2: the relay (BACKLOG U.5).
//
// Two protocols, and the compositor between them. An application's text field
// speaks **text-input-v3**: it says where its cursor is, what text surrounds
// it, what kind of field it is, and receives composed text. An input method —
// fcitx5, ibus, the keyboard of a language with more characters than keys —
// speaks **input-method-v2**: it is told a field is active, and answers with
// preedit (what is being composed, shown in place, underlined), commits
// (the finished text) and deletions. Neither talks to the other; the
// compositor relays, which is why without this there is no input method on the
// desktop at all, and so no CJK.
//
// The rules, as sway keeps them:
//   - a text input is entered (told it may be used) when its surface gets
//     keyboard focus, and left when it loses it — the seat's focus_change is
//     the one place that sees every way focus moves;
//   - the enabled text input on the focused surface is the ACTIVE one: its
//     state goes to the input method (activate / surrounding / content type /
//     done), and the method's commits come back to it;
//   - an input method may GRAB the keyboard: then keys go to it rather than
//     to the application — except keys from its own virtual keyboard, which is
//     how it types what it has composed and would otherwise loop;
//   - its candidate popup goes below the text cursor.
//
// Nothing here logs text: what an input method commits can be a password.

import CWlroots

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// One text input, and the context its listeners are called with. wlroots
/// 0.20 emits a text input's `enable`, `commit`, `disable` and `destroy` with
/// **NULL data** (0.19 passed the text input), so a handler cannot learn from
/// the signal which text input it is about — the entry has to say.
final class TextInputEntry {
    let ti: UnsafeMutablePointer<wlr_text_input_v3>
    unowned let relay: TextInputRelay
    var listeners: [UnsafeMutablePointer<tw_listener>?] = []
    init(_ ti: UnsafeMutablePointer<wlr_text_input_v3>, relay: TextInputRelay) {
        self.ti = ti
        self.relay = relay
    }
    deinit { for l in listeners { tw_listener_free(l) } }
    static func of(_ ctx: UnsafeMutableRawPointer) -> TextInputEntry {
        Unmanaged<TextInputEntry>.fromOpaque(ctx).takeUnretainedValue()
    }
}

/// The same for a candidate popup, whose `destroy` also arrives with NULL data.
final class InputPopupEntry {
    let popup: UnsafeMutablePointer<wlr_input_popup_surface_v2>
    unowned let relay: TextInputRelay
    var listener: UnsafeMutablePointer<tw_listener>?
    init(_ p: UnsafeMutablePointer<wlr_input_popup_surface_v2>, relay: TextInputRelay) {
        popup = p
        self.relay = relay
    }
    deinit { tw_listener_free(listener) }
}

public final class TextInputRelay {
    private unowned let compositor: Compositor
    private let seat: UnsafeMutablePointer<wlr_seat>
    private var textInputs: [TextInputEntry] = []
    private var inputMethod: UnsafeMutablePointer<wlr_input_method_v2>?
    private var imListeners: [UnsafeMutablePointer<tw_listener>?] = []
    private var grab: UnsafeMutablePointer<wlr_input_method_keyboard_grab_v2>?
    private var grabListener: UnsafeMutablePointer<tw_listener>?
    private var popups: [InputPopupEntry] = []
    private var listeners: [UnsafeMutablePointer<tw_listener>?] = []

    /// For the log a test reads: counts, never text.
    public private(set) var enters = 0, activations = 0, commitsRelayed = 0, keysGrabbed = 0

    init?(compositor: Compositor, seat: UnsafeMutablePointer<wlr_seat>) {
        guard let tim = wlr_text_input_manager_v3_create(compositor.session.display),
              let imm = wlr_input_method_manager_v2_create(compositor.session.display) else { return nil }
        self.compositor = compositor
        self.seat = seat
        let me = Unmanaged.passUnretained(self).toOpaque()
        listeners.append(tw_listen(&tim.pointee.events.new_text_input, { ctx, data in
            guard let ctx, let data else { return }
            Unmanaged<TextInputRelay>.fromOpaque(ctx).takeUnretainedValue()
                .newTextInput(data.assumingMemoryBound(to: wlr_text_input_v3.self))
        }, me))
        listeners.append(tw_listen(&imm.pointee.events.new_input_method, { ctx, data in
            guard let ctx, let data else { return }
            Unmanaged<TextInputRelay>.fromOpaque(ctx).takeUnretainedValue()
                .newInputMethod(data.assumingMemoryBound(to: wlr_input_method_v2.self))
        }, me))
        listeners.append(tw_listen(&seat.pointee.keyboard_state.events.focus_change, { ctx, data in
            guard let ctx, let data else { return }
            let e = data.assumingMemoryBound(to: wlr_seat_keyboard_focus_change_event.self)
            Unmanaged<TextInputRelay>.fromOpaque(ctx).takeUnretainedValue().focusChanged(to: e.pointee.new_surface)
        }, me))
    }

    deinit {
        for l in listeners + imListeners { tw_listener_free(l) }
        tw_listener_free(grabListener)
    }

    // MARK: text inputs

    private func client(_ s: UnsafeMutablePointer<wlr_surface>?) -> OpaquePointer? {
        guard let r = s?.pointee.resource else { return nil }
        return wl_resource_get_client(r)
    }

    private func newTextInput(_ ti: UnsafeMutablePointer<wlr_text_input_v3>) {
        let e = TextInputEntry(ti, relay: self)
        // A C callback cannot capture, and the signal no longer says which
        // text input it is about (0.20), so each listener's context is its
        // entry. The relay's array keeps the entry alive until `destroy`.
        let ctx = Unmanaged.passUnretained(e).toOpaque()
        e.listeners.append(tw_listen(&ti.pointee.events.enable, { ctx, _ in
            guard let ctx else { return }
            let e = TextInputEntry.of(ctx)
            e.relay.enabled(e.ti)
        }, ctx))
        e.listeners.append(tw_listen(&ti.pointee.events.commit, { ctx, _ in
            guard let ctx else { return }
            let e = TextInputEntry.of(ctx)
            e.relay.committed(e.ti)
        }, ctx))
        e.listeners.append(tw_listen(&ti.pointee.events.disable, { ctx, _ in
            guard let ctx else { return }
            let e = TextInputEntry.of(ctx)
            e.relay.disabled(e.ti)
        }, ctx))
        e.listeners.append(tw_listen(&ti.pointee.events.destroy, { ctx, _ in
            guard let ctx else { return }
            // `e` holds the entry until this returns; dropping it from the
            // array takes its listeners off their signals (§2.82).
            let e = TextInputEntry.of(ctx)
            let r = e.relay
            if r.active == e.ti { r.deactivate() }
            r.textInputs.removeAll { $0 === e }
        }, ctx))
        textInputs.append(e)
        // Its client may already have the keyboard.
        if let f = seat.pointee.keyboard_state.focused_surface, client(f) == wl_resource_get_client(ti.pointee.resource) {
            wlr_text_input_v3_send_enter(ti, f)
            enters += 1
        }
    }

    private func focusChanged(to surface: UnsafeMutablePointer<wlr_surface>?) {
        if active != nil { deactivate() }
        let c = client(surface)
        for e in textInputs {
            if e.ti.pointee.focused_surface != nil, e.ti.pointee.focused_surface != surface {
                wlr_text_input_v3_send_leave(e.ti)
            }
            if let surface, let c, wl_resource_get_client(e.ti.pointee.resource) == c,
               e.ti.pointee.focused_surface != surface {
                wlr_text_input_v3_send_enter(e.ti, surface)
                enters += 1
                Compositor.log("text-input: entered on focus")
            }
        }
    }

    /// The enabled text input on the focused surface.
    private var active: UnsafeMutablePointer<wlr_text_input_v3>?

    private func sendState(_ ti: UnsafeMutablePointer<wlr_text_input_v3>) {
        guard let im = inputMethod else { return }
        let st = ti.pointee.current
        if ti.pointee.active_features & UInt32(WLR_TEXT_INPUT_V3_FEATURE_SURROUNDING_TEXT.rawValue) != 0 {
            if let t = st.surrounding.text {
                wlr_input_method_v2_send_surrounding_text(im, t, st.surrounding.cursor, st.surrounding.anchor)
            } else {
                wlr_input_method_v2_send_surrounding_text(im, "", st.surrounding.cursor, st.surrounding.anchor)
            }
        }
        wlr_input_method_v2_send_text_change_cause(im, st.text_change_cause)
        if ti.pointee.active_features & UInt32(WLR_TEXT_INPUT_V3_FEATURE_CONTENT_TYPE.rawValue) != 0 {
            wlr_input_method_v2_send_content_type(im, st.content_type.hint, st.content_type.purpose)
        }
        wlr_input_method_v2_send_done(im)
        placePopups()
    }

    private func enabled(_ ti: UnsafeMutablePointer<wlr_text_input_v3>) {
        guard ti.pointee.focused_surface != nil else { return }
        active = ti
        Compositor.log("text-input: enabled" + (inputMethod == nil ? " (no input method)" : ""))
        guard let im = inputMethod else { return }
        wlr_input_method_v2_send_activate(im)
        activations += 1
        sendState(ti)
    }

    private func committed(_ ti: UnsafeMutablePointer<wlr_text_input_v3>) {
        guard ti == active, ti.pointee.current_enabled else { return }
        sendState(ti)
    }

    private func disabled(_ ti: UnsafeMutablePointer<wlr_text_input_v3>) {
        if ti == active { deactivate() }
    }

    private func deactivate() {
        active = nil
        Compositor.log("text-input: deactivated")
        guard let im = inputMethod else { return }
        wlr_input_method_v2_send_deactivate(im)
        wlr_input_method_v2_send_done(im)
    }

    // MARK: the input method

    private func newInputMethod(_ im: UnsafeMutablePointer<wlr_input_method_v2>) {
        // One per seat: a second is told it is unavailable, as the protocol says.
        guard inputMethod == nil else { wlr_input_method_v2_send_unavailable(im); return }
        inputMethod = im
        Compositor.log("input-method: bound")
        let me = Unmanaged.passUnretained(self).toOpaque()
        imListeners.append(tw_listen(&im.pointee.events.commit, { ctx, _ in
            guard let ctx else { return }
            Unmanaged<TextInputRelay>.fromOpaque(ctx).takeUnretainedValue().methodCommitted()
        }, me))
        imListeners.append(tw_listen(&im.pointee.events.grab_keyboard, { ctx, data in
            guard let ctx, let data else { return }
            Unmanaged<TextInputRelay>.fromOpaque(ctx).takeUnretainedValue()
                .grabbed(data.assumingMemoryBound(to: wlr_input_method_keyboard_grab_v2.self))
        }, me))
        imListeners.append(tw_listen(&im.pointee.events.new_popup_surface, { ctx, data in
            guard let ctx, let data else { return }
            Unmanaged<TextInputRelay>.fromOpaque(ctx).takeUnretainedValue()
                .newPopup(data.assumingMemoryBound(to: wlr_input_popup_surface_v2.self))
        }, me))
        imListeners.append(tw_listen(&im.pointee.events.destroy, { ctx, _ in
            guard let ctx else { return }
            let r = Unmanaged<TextInputRelay>.fromOpaque(ctx).takeUnretainedValue()
            for l in r.imListeners { tw_listener_free(l) }
            r.imListeners = []
            r.inputMethod = nil
            r.grab = nil
            tw_listener_free(r.grabListener); r.grabListener = nil
            r.popups = []
            // The application's composing is over: whatever preedit it showed
            // is withdrawn.
            if let ti = r.active {
                wlr_text_input_v3_send_preedit_string(ti, nil, 0, 0)
                wlr_text_input_v3_send_done(ti)
            }
            Compositor.log("input-method: gone")
        }, me))
        // A field already active gets the method at once.
        if let ti = active { wlr_input_method_v2_send_activate(im); activations += 1; sendState(ti) }
    }

    private func methodCommitted() {
        guard let im = inputMethod, let ti = active else { return }
        let st = im.pointee.current
        if let text = st.preedit.text {
            wlr_text_input_v3_send_preedit_string(ti, text, st.preedit.cursor_begin, st.preedit.cursor_end)
        } else {
            wlr_text_input_v3_send_preedit_string(ti, nil, 0, 0)
        }
        if let text = st.commit_text { wlr_text_input_v3_send_commit_string(ti, text) }
        if st.delete.before_length > 0 || st.delete.after_length > 0 {
            wlr_text_input_v3_send_delete_surrounding_text(ti, st.delete.before_length, st.delete.after_length)
        }
        wlr_text_input_v3_send_done(ti)
        commitsRelayed += 1
        Compositor.log("input-method: commit relayed (preedit \(st.preedit.text.map { strlen($0) } ?? 0) bytes,"
                       + " commit \(st.commit_text.map { strlen($0) } ?? 0) bytes)")
    }

    private func grabbed(_ g: UnsafeMutablePointer<wlr_input_method_keyboard_grab_v2>) {
        grab = g
        if let kbd = wlr_seat_get_keyboard(seat) { wlr_input_method_keyboard_grab_v2_set_keyboard(g, kbd) }
        let me = Unmanaged.passUnretained(self).toOpaque()
        grabListener = tw_listen(&g.pointee.events.destroy, { ctx, _ in
            guard let ctx else { return }
            let r = Unmanaged<TextInputRelay>.fromOpaque(ctx).takeUnretainedValue()
            r.grab = nil
            // **Off the signal before wlroots finishes destroying it**: 0.19
            // asserts every destroy listener is gone (an abort on the grab's
            // release, found by live-ime.sh). Removal during the emit is safe.
            tw_listener_free(r.grabListener); r.grabListener = nil
            // Keys the method had while it held the grab: the app's state is
            // re-sent, so modifiers held across the release are not stuck.
            if let kbd = wlr_seat_get_keyboard(r.seat) { wlr_seat_keyboard_notify_modifiers(r.seat, &kbd.pointee.modifiers) }
            Compositor.log("input-method: keyboard released")
        }, me)
        Compositor.log("input-method: keyboard grabbed")
    }

    /// Whether a key from `keyboard` goes to the input method's grab instead of
    /// the application. Never its own virtual keyboard's: that is the method
    /// typing, and would come straight back to it.
    func routeKey(_ e: UnsafeMutablePointer<wlr_keyboard_key_event>, keyboard: UnsafeMutablePointer<wlr_keyboard>) -> Bool {
        guard let g = grab, let im = inputMethod, !fromMethod(keyboard, im) else { return false }
        wlr_input_method_keyboard_grab_v2_set_keyboard(g, keyboard)
        wlr_input_method_keyboard_grab_v2_send_key(g, e.pointee.time_msec, e.pointee.keycode, UInt32(e.pointee.state.rawValue))
        keysGrabbed += 1
        return true
    }

    func routeModifiers(_ keyboard: UnsafeMutablePointer<wlr_keyboard>) -> Bool {
        guard let g = grab, let im = inputMethod, !fromMethod(keyboard, im) else { return false }
        wlr_input_method_keyboard_grab_v2_set_keyboard(g, keyboard)
        wlr_input_method_keyboard_grab_v2_send_modifiers(g, &keyboard.pointee.modifiers)
        return true
    }

    private func fromMethod(_ keyboard: UnsafeMutablePointer<wlr_keyboard>,
                            _ im: UnsafeMutablePointer<wlr_input_method_v2>) -> Bool {
        guard let vk = wlr_input_device_get_virtual_keyboard(&keyboard.pointee.base),
              let r = vk.pointee.resource, let imr = im.pointee.resource else { return false }
        return wl_resource_get_client(r) == wl_resource_get_client(imr)
    }

    // MARK: the candidate popup

    private func newPopup(_ p: UnsafeMutablePointer<wlr_input_popup_surface_v2>) {
        let e = InputPopupEntry(p, relay: self)
        e.listener = tw_listen(&p.pointee.events.destroy, { ctx, _ in
            guard let ctx else { return }
            let e = Unmanaged<InputPopupEntry>.fromOpaque(ctx).takeUnretainedValue()
            e.relay.popups.removeAll { $0 === e }
        }, Unmanaged.passUnretained(e).toOpaque())
        popups.append(e)
        placePopups()
    }

    /// Where the focused field is on the desktop: its surface's origin plus
    /// the cursor rectangle it reported.
    private func cursorRect() -> Rect? {
        guard let ti = active, let s = ti.pointee.focused_surface else { return nil }
        var origin: (Int32, Int32)?
        if let t = compositor.toplevels.first(where: { $0.surface == s }) { origin = (t.x, t.y) }
        else if let l = compositor.layers.first(where: { $0.surface == s }) { origin = (l.rect.x, l.rect.y) }
        guard let o = origin else { return nil }
        let c = ti.pointee.current.cursor_rectangle
        return Rect(x: o.0 + c.x, y: o.1 + c.y, width: max(1, c.width), height: max(1, c.height))
    }

    private func placePopups() {
        guard let ti = active else { return }
        let c = ti.pointee.current.cursor_rectangle
        for e in popups {
            var box = c
            wlr_input_popup_surface_v2_send_text_input_rectangle(e.popup, &box)
        }
    }

    /// The candidate popups with something to show, and where: just below the
    /// text cursor, in layout coordinates.
    var mappedPopups: [(surface: UnsafeMutablePointer<wlr_surface>, x: Int32, y: Int32)] {
        guard let r = cursorRect() else { return [] }
        return popups.compactMap { e in
            guard let s = e.popup.pointee.surface, wlr_surface_has_buffer(s) else { return nil }
            return (s, r.x, r.y + r.height)
        }
    }
}
