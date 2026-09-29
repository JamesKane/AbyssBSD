// DisplaySleep — the displays sleep when nobody is using them, unless
// something on screen asks them not to (BACKLOG U.9).
//
// The Energy Saver pane (P14.8) has always written `display_sleep_minutes`
// to energy.ini; nothing acted on it. The compositor is the one process that
// sees every input and owns every output, so it is the one that sleeps the
// displays: after that many minutes without input, every output is turned off
// (on metal that is the CRTC; the monitor goes to standby), and the first key
// or motion turns them back on. While they are off, clients get the slow 1 Hz
// clock a minimised window gets (U.2), not the display's rate.
//
// **idle-inhibit-v1** is how a video player or a presentation says "not
// now": while a surface that holds an inhibitor is visible — mapped, not
// minimised — the clock does not run. When the last one goes, it starts
// again from then, not from the last input.
//
// **ext-idle-notify-v1** carries the same activity and the same inhibition
// to clients that want to know about idleness — Phase 16's session, which
// sleeps the *computer*, will be one — so there is one idea of "idle" on the
// desktop, not two.

import CWlroots
import PoolConfig

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// When the displays sleep: pure, so it is tested without a clock.
public struct IdleClock: Equatable, Sendable {
    /// Inactivity before sleep, in ns; 0 is never.
    public var timeoutNs: UInt64
    public private(set) var lastActivityNs: UInt64
    public private(set) var asleep = false

    public enum Change: Equatable, Sendable { case sleep, wake }

    public init(timeoutNs: UInt64, now: UInt64) {
        self.timeoutNs = timeoutNs
        lastActivityNs = now
    }

    /// A person did something. Wakes the displays if they were asleep.
    public mutating func activity(at now: UInt64) -> Change? {
        lastActivityNs = now
        guard asleep else { return nil }
        asleep = false
        return .wake
    }

    /// Time passed. While inhibited the clock is held at `now`, so it runs
    /// its full length once the inhibitor goes.
    public mutating func tick(at now: UInt64, inhibited: Bool) -> Change? {
        if inhibited { lastActivityNs = max(lastActivityNs, now); return nil }
        guard !asleep, timeoutNs > 0, now &- lastActivityNs >= timeoutNs else { return nil }
        asleep = true
        return .sleep
    }

    /// The timeout a person asked for: energy.ini's minutes, unless a
    /// run of undertow was given seconds (`--display-sleep`, for tests).
    public static func timeoutNs(prefs: EnergyPrefs, overrideSeconds: Double?) -> UInt64 {
        if let s = overrideSeconds { return s > 0 ? UInt64(s * 1_000_000_000) : 0 }
        return UInt64(max(prefs.displaySleepMinutes, 0)) * 60 * 1_000_000_000
    }
}

final class InhibitorEntry {
    let surface: UnsafeMutablePointer<wlr_surface>
    var listener: UnsafeMutablePointer<tw_listener>?
    weak var owner: DisplaySleep?
    init(_ s: UnsafeMutablePointer<wlr_surface>) { surface = s }
    deinit { tw_listener_free(listener) }
}

public final class DisplaySleep {
    private unowned let compositor: Compositor
    private let notifier: UnsafeMutablePointer<wlr_idle_notifier_v1>?
    private var inhibitors: [InhibitorEntry] = []
    private var listeners: [UnsafeMutablePointer<tw_listener>?] = []
    public private(set) var clock: IdleClock
    private let overrideSeconds: Double?
    private var prefsCheckedAt: UInt64 = 0
    private var inhibitedNow = false

    /// Called with true when the displays should go off, false when on.
    public var onChange: ((Bool) -> Void)?
    /// For the log a test reads.
    public private(set) var sleeps = 0, wakes = 0

    public var asleep: Bool { clock.asleep }
    public var inhibited: Bool { inhibitedNow }

    public init(compositor: Compositor, overrideSeconds: Double?) {
        self.compositor = compositor
        self.overrideSeconds = overrideSeconds
        let now = Mono.now()
        clock = IdleClock(timeoutNs: IdleClock.timeoutNs(prefs: EnergyPrefs.load(configDir: compositor.configDir),
                                                         overrideSeconds: overrideSeconds), now: now)
        prefsCheckedAt = now
        notifier = wlr_idle_notifier_v1_create(compositor.session.display)
        guard let im = wlr_idle_inhibit_v1_create(compositor.session.display) else { return }
        let me = Unmanaged.passUnretained(self).toOpaque()
        listeners.append(tw_listen(&im.pointee.events.new_inhibitor, { ctx, data in
            guard let ctx, let data else { return }
            Unmanaged<DisplaySleep>.fromOpaque(ctx).takeUnretainedValue()
                .newInhibitor(data.assumingMemoryBound(to: wlr_idle_inhibitor_v1.self))
        }, me))
    }

    deinit { for l in listeners { tw_listener_free(l) } }

    private func newInhibitor(_ i: UnsafeMutablePointer<wlr_idle_inhibitor_v1>) {
        guard let s = i.pointee.surface else { return }
        let e = InhibitorEntry(s)
        e.owner = self
        // The entry is its own context: a C callback carries one pointer, and
        // the handler must know which inhibitor went.
        e.listener = tw_listen(&i.pointee.events.destroy, { ctx, _ in
            guard let ctx else { return }
            let entry = Unmanaged<InhibitorEntry>.fromOpaque(ctx).takeUnretainedValue()
            // Dropping the entry frees its listener, off the signal during the
            // emit (§2.82: wlroots asserts nothing is left on it).
            entry.owner?.inhibitors.removeAll { $0 === entry }
        }, Unmanaged.passUnretained(e).toOpaque())
        inhibitors.append(e)
    }

    /// A key, a motion, a button, a wheel.
    func activity() {
        if let n = notifier, let s = compositor.seat?.wlrSeat { wlr_idle_notifier_v1_notify_activity(n, s) }
        if clock.activity(at: Mono.now()) == .wake {
            wakes += 1
            onChange?(false)
        }
    }

    /// Once per loop iteration: is anything on screen holding the displays
    /// awake, has the timeout changed, and is it time to sleep.
    public func tick() {
        let now = Mono.now()
        if overrideSeconds == nil, now &- prefsCheckedAt >= 1_000_000_000 {
            prefsCheckedAt = now
            clock.timeoutNs = IdleClock.timeoutNs(prefs: EnergyPrefs.load(configDir: compositor.configDir),
                                                  overrideSeconds: nil)
        }
        let inhibited = inhibitors.contains { visible($0.surface) }
        if inhibited != inhibitedNow {
            inhibitedNow = inhibited
            if let n = notifier { wlr_idle_notifier_v1_set_inhibited(n, inhibited) }
        }
        if clock.tick(at: now, inhibited: inhibited) == .sleep {
            sleeps += 1
            onChange?(true)
        }
    }

    /// An inhibitor counts while its surface can be seen: part of a mapped,
    /// unminimised window, or of a mapped layer surface.
    private func visible(_ s: UnsafeMutablePointer<wlr_surface>) -> Bool {
        let root = wlr_surface_get_root_surface(s)
        if compositor.toplevels.contains(where: { $0.mapped && !$0.minimized && $0.surface == root }) { return true }
        return compositor.mappedLayers.contains { $0.surface == root }
    }
}
