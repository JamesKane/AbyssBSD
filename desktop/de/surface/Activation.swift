// Activation — xdg-activation-v1, the sanctioned way for a client to raise one
// of its own windows. (A Wayland client can't focus itself by fiat: it asks the
// compositor for a *token*, tied to a real input serial, and hands that token
// back with the surface to raise.)
//
// The Finder uses this in spatial mode: opening a folder that already has a
// window brings that window forward instead of making a second one.
//
// The token is a two-step handshake — get_activation_token → set_serial /
// set_surface / commit → the token object's `done` event carries the string —
// so the request outlives the call. `ActivationRequest` is passed to the
// listener as a *retained* Unmanaged reference and released in `done`; that is
// what keeps it alive across the round trip.

import CWayland

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

final class ActivationRequest {
    let display: Display
    let token: OpaquePointer
    let target: OpaquePointer      // the wl_surface to raise

    init(display: Display, token: OpaquePointer, target: OpaquePointer) {
        self.display = display
        self.token = token
        self.target = target
    }

    func finish(token string: UnsafePointer<CChar>?) {
        if let string, let activation = display.activation {
            xdg_activation_v1_activate(activation, string, target)
        }
        xdg_activation_token_v1_destroy(token)
        wl_display_flush(display.display)
    }
}

public extension Display {
    /// Whether the compositor offers xdg-activation.
    var canActivate: Bool { activation != nil }

    /// Ask the compositor to raise `surface` (one of ours). Returns false when
    /// the protocol isn't available, so the caller can fall back.
    @discardableResult
    func activate(surface: OpaquePointer) -> Bool {
        guard let activation,
              let token = xdg_activation_v1_get_activation_token(activation)
        else { return false }

        // Tie the request to the most recent input serial we saw: compositors
        // reject (or deprioritise) activation that isn't rooted in real input.
        if let seat { xdg_activation_token_v1_set_serial(token, lastPointerSerial, seat) }
        // The surface the request comes *from* — the compositor uses it to
        // decide whether the focus hand-off is legitimate.
        if let from = activationSourceSurface {
            xdg_activation_token_v1_set_surface(token, from)
        }

        let request = ActivationRequest(display: self, token: token, target: surface)
        var tl = xdg_activation_token_v1_listener()
        tl.done = { data, _, tokenString in
            guard let data else { return }
            // Retained at registration; this is the one and only `done`.
            let r = Unmanaged<ActivationRequest>.fromOpaque(data).takeRetainedValue()
            r.finish(token: tokenString)
        }
        addListener(to: token, listener: tl,
                    data: Unmanaged.passRetained(request).toOpaque())
        xdg_activation_token_v1_commit(token)
        wl_display_flush(display)
        return true
    }
}
