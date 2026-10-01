// abyss-idle — the session's idle policy (PHASE16 P16.3).
//
// Turns idleness into what a person asked for in Energy Saver:
//
//   - when the display sleeps, **lock** — if "require a password to wake this
//     computer" is on (energy.ini `require_password`, on by default);
//   - after the computer's delay, **ask the machine to sleep**: a `power
//     sleep` request to the root daemon (P16.4a).
//
// It is also the session's **power agent**: it keeps a `watch` connection to
// the daemon, which tells it before the machine sleeps — whoever asked: the
// system menu, this, the lid — and does not sleep until it answers that the
// session is locked (or needs no lock: no password required). So the lock
// before sleep is here, once, for every way to sleep.
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
import CWayland

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
                             onIdle: { [weak self] in self?.lock(because: "idle (the display sleeps)") })
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
        guard let r = try? Current.call("anchor", m) else { say("\(why): anchor did not answer — not locked"); return false }
        guard r.bool("ok") == true else { say("\(why): anchor would not lock: \(r.string("error") ?? "?")"); return false }
        say("\(why): " + (r.bool("already") == true ? "already locked" : "locking"))
        return true
    }

    /// Lock, and wait for anchor to say the **compositor** has locked — a
    /// running lock screen is not enough (HANDOFF §2.104). Nil, or why not.
    func lockAndConfirm(because why: String) -> String? {
        guard lock(because: why) else { return "the session could not be locked" }
        for _ in 0..<50 {
            var m = Msg(); m.set("method", "status")
            if (try? Current.call("anchor", m))?.bool("locked") == true { return nil }
            usleep(100_000)
        }
        return "the session did not lock in 5 s"
    }

    /// The idle half: ask the machine to sleep. **Not a blocking call**: the
    /// daemon asks this very process, on its watch connection, to lock before
    /// it answers — waiting here would hold the answer up until it gave up.
    var asking: Int32 = -1
    func sleep() {
        guard asking < 0 else { return }
        do {
            var m = Msg(); m.set("method", "power"); m.set("action", PowerAction.sleep.rawValue)
            let s = try Current.connect(path: LoginClient.socket)
            try Current.send(m, on: s)
            asking = s
            say("idle (the computer sleeps): asking the machine to sleep")
            display.addFileDescriptor(s) { [weak self] in self?.sleepAnswered() }
        } catch {
            say("idle (the computer sleeps): nobody to ask the machine to sleep: \(error)")
        }
    }

    func sleepAnswered() {
        let s = asking
        display.removeFileDescriptor(s)
        asking = -1
        defer { close(s) }
        guard let r = try? Current.receive(on: s) else { say("idle (the computer sleeps): no answer"); return }
        if r.bool("ok") == true { say("idle (the computer sleeps): the machine is going to sleep") }
        else { say("idle (the computer sleeps): the machine did not sleep: \(r.string("error") ?? "?")") }
    }

    // MARK: The power agent

    var watch: Int32 = -1
    var retry: Int32 = -1

    func startWatching() {
        guard watch < 0 else { return }
        do {
            let s = try Current.connect(path: LoginClient.socket)
            var m = Msg(); m.set("method", "watch")
            try Current.send(m, on: s)
            guard (try Current.receive(on: s)).bool("ok") == true else { close(s); throw CurrentError.malformed("refused") }
            // No receive timeout from here on: events come when they come.
            var tv = timeval(); _ = setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            watch = s
            display.addFileDescriptor(s) { [weak self] in self?.event() }
            if retry >= 0 { display.removeFileDescriptor(retry); close(retry); retry = -1 }
            say("watching for the machine's sleep")
        } catch {
            if retry < 0 {
                say("cannot watch for the machine's sleep yet (\(error)) — retrying")
                retry = aw_create_interval_timer(2000)
                if retry >= 0 { display.addFileDescriptor(retry) { [weak self] in self?.retryTick() } }
            }
        }
    }

    func retryTick() {
        var n: UInt64 = 0
        _ = withUnsafeMutablePointer(to: &n) { read(retry, $0, MemoryLayout<UInt64>.size) }
        startWatching()
    }

    func event() {
        guard let m = try? Current.receive(on: watch) else {
            display.removeFileDescriptor(watch); close(watch); watch = -1
            say("the daemon went away — watching again when it is back")
            startWatching()
            return
        }
        switch m.string("event") {
        case "sleep":
            var answer = Msg()
            if prefs.requirePassword {
                if let why = lockAndConfirm(because: "the machine is about to sleep") {
                    answer.set("ready", false); answer.set("why", why)
                    say("the machine is about to sleep: NOT ready — \(why)")
                } else {
                    answer.set("ready", true); answer.set("why", "locked")
                    say("the machine is about to sleep: locked, ready")
                }
            } else {
                answer.set("ready", true); answer.set("why", "no password required")
                say("the machine is about to sleep: no password required, ready")
            }
            _ = try? Current.send(answer, on: watch)
        case "resumed":
            say("the machine is awake")
        default:
            break
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
policy.startWatching()
let watcher = try? Pool.Watcher()
if let w = watcher {
    display.addFileDescriptor(w.fileDescriptor) { _ = w.drain(); policy.configChanged() }
}
withExtendedLifetime((policy, watcher)) { display.run() }
