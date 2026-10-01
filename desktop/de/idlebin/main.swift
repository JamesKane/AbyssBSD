// abyss-idle — the session's idle policy (PHASE16 P16.3).
//
// Turns idleness into what a person asked for in Energy Saver:
//
//   - when the display sleeps, **lock** — if "require a password to wake this
//     computer" is on (energy.ini `require_password`, on by default);
//   - after the computer's delay, lock (the same rule) and **ask the machine
//     to sleep**: a `power sleep` request to the root daemon, which acts on it
//     from P16.4 on — before then it says it cannot, and this says so too.
//
// Idleness is the compositor's, through ext-idle-notify v1, so a video that
// holds the displays awake holds this too: one idea of idle (HANDOFF §2.86).
// energy.ini is watched; a change re-arms both timers. anchor supervises this
// as the `idle` component.
//
// ABYSS_IDLE_MINUTE=SECONDS makes a minute that long — for a test, which
// cannot wait ten real minutes for a lock.

import Surface
import PoolConfig
import CurrentIPC
import Login

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

func say(_ s: String) {
    let b = Array(("abyss-idle: " + s + "\n").utf8)
    _ = b.withUnsafeBufferPointer { write(2, $0.baseAddress, b.count) }
}

let minuteMs: UInt64 = getenv("ABYSS_IDLE_MINUTE").flatMap { Double(String(cString: $0)) }
    .map { UInt64(max(0.05, $0) * 1000) } ?? 60_000

guard let display = Display() else { say("cannot connect to the compositor"); exit(1) }
guard display.hasIdleNotifier else {
    say("the compositor offers no ext-idle-notify — there is no idleness to act on"); exit(1)
}

final class Policy {
    let display: Display
    var prefs = EnergyPrefs.load()
    var lockNote: IdleNotification?
    var sleepNote: IdleNotification?

    init(display: Display) { self.display = display }

    func words(_ ms: UInt64?) -> String {
        guard let ms else { return "never" }
        return ms % 1000 == 0 ? "\(ms / 1000) s" : "\(Double(ms) / 1000) s"
    }

    func arm() {
        let t = prefs.idleTimeouts(minuteMs: minuteMs)
        lockNote = t.lock.flatMap { ms in
            IdleNotification(display: display, timeoutMs: UInt32(min(ms, UInt64(UInt32.max))),
                             onIdle: { [weak self] in self?.lock(because: "the display sleeps") })
        }
        sleepNote = t.sleep.flatMap { ms in
            IdleNotification(display: display, timeoutMs: UInt32(min(ms, UInt64(UInt32.max))),
                             onIdle: { [weak self] in self?.sleep() })
        }
        say("armed: lock after \(words(t.lock)), sleep after \(words(t.sleep))"
            + (prefs.requirePassword ? "" : " (no password required: no lock)"))
    }

    @discardableResult
    func lock(because why: String) -> Bool {
        var m = Msg(); m.set("method", "lock")
        guard let r = try? Current.call("anchor", m) else { say("idle (\(why)): anchor did not answer — not locked"); return false }
        guard r.bool("ok") == true else { say("idle (\(why)): anchor would not lock: \(r.string("error") ?? "?")"); return false }
        say("idle (\(why)): " + (r.bool("already") == true ? "already locked" : "locking"))
        return true
    }

    func sleep() {
        if prefs.requirePassword {
            guard lock(because: "the computer sleeps") else {
                say("idle (the computer sleeps): could not lock — not asking the machine to sleep")
                return
            }
            // **Not before the compositor has locked.** anchor's `locked` is
            // the lock screen's word that the compositor said so — a running
            // lock screen is not enough (the first version went on that, and
            // asked for sleep with the desktop still showing). Without that
            // word in five seconds, the machine is not asked to sleep at all:
            // a computer that wakes unlocked is worse than one that stays up.
            var waited = 0, locked = false
            while waited < 50 {
                var m = Msg(); m.set("method", "status")
                if (try? Current.call("anchor", m))?.bool("locked") == true { locked = true; break }
                usleep(100_000); waited += 1
            }
            guard locked else {
                say("idle (the computer sleeps): the session never locked — not asking the machine to sleep")
                return
            }
        }
        do {
            let r = try PowerClient.request(.sleep)
            if r.bool("ok") == true { say("idle (the computer sleeps): asked the machine to sleep — ok") }
            else { say("idle (the computer sleeps): the machine cannot sleep yet: \(r.string("error") ?? "?")") }
        } catch {
            say("idle (the computer sleeps): nobody to ask the machine to sleep: \(error)")
        }
    }

    func configChanged() {
        let p = EnergyPrefs.load()
        guard p != prefs else { return }
        prefs = p
        say("energy.ini changed")
        arm()
    }
}

let policy = Policy(display: display)
policy.arm()
let watcher = try? Pool.Watcher()
if let w = watcher {
    display.addFileDescriptor(w.fileDescriptor) { _ = w.drain(); policy.configChanged() }
}
withExtendedLifetime((policy, watcher)) { display.run() }
