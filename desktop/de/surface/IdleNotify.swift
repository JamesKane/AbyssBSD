// Surface.IdleNotify — ext-idle-notify-v1, the client side (PHASE16 P16.3).
//
// "Tell me when nobody has touched this seat for N milliseconds, and when
// somebody does again." The compositor counts; an inhibitor (a video playing)
// holds the count, because this is v1's `get_idle_notification`, not v2's
// input-only kind — so the session's policy and the displays' sleep share one
// idea of idle (HANDOFF §2.86).

import CWayland

public final class IdleNotification {
    private let display: Display
    private var notification: OpaquePointer?
    private let onIdle: () -> Void
    private let onResume: () -> Void
    public let timeoutMs: UInt32

    public init?(display: Display, timeoutMs: UInt32,
                 onIdle: @escaping () -> Void, onResume: @escaping () -> Void = {}) {
        guard let n = display.idleNotifier, let seat = display.seat,
              let note = ext_idle_notifier_v1_get_idle_notification(n, timeoutMs, seat) else { return nil }
        self.display = display
        self.notification = note
        self.timeoutMs = timeoutMs
        self.onIdle = onIdle
        self.onResume = onResume
        var l = ext_idle_notification_v1_listener()
        l.idled = { data, _ in
            guard let data else { return }
            Unmanaged<IdleNotification>.fromOpaque(data).takeUnretainedValue().onIdle()
        }
        l.resumed = { data, _ in
            guard let data else { return }
            Unmanaged<IdleNotification>.fromOpaque(data).takeUnretainedValue().onResume()
        }
        display.addListener(to: note, listener: l, data: Unmanaged.passUnretained(self).toOpaque())
        display.flush()
    }

    deinit {
        if let n = notification { ext_idle_notification_v1_destroy(n) }
        display.flush()
    }
}
