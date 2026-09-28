// The settings plan on the wire (PHASE14 P14.3).
//
// Its own target for the installer's reason (InstallWire): System Preferences
// must be able to speak the protocol **without linking the code that runs
// `sysrc` as root**. `Msg` has scalars and no arrays, so a plan is a few named
// fields and a step list is indexed ones — verbose, and trivially readable in a
// log, which is where a root helper's messages end up being read.

import CurrentIPC
import Settings

/// What an apply reports as it happens — the vocabulary both ends share.
public enum SettingsEvent: Equatable, Sendable {
    case starting(index: Int, total: Int, what: String)
    case ok(index: Int)
    case failed(index: Int, what: String, why: String, ignored: Bool)
    case finished(ok: Bool, error: String)
}

public enum SettingsWire {

    // MARK: - The plan

    public static func encode(_ p: SettingsPlan, into m: inout Msg) {
        m.set("kind", p.kind)
        switch p {
        case .energy(let e):
            m.set("energy.powerd", e.powerd)
            m.set("energy.ac", e.onAC.rawValue)
            m.set("energy.battery", e.onBattery.rawValue)
        }
    }

    /// The plan a message describes, or why it describes none. An unknown kind
    /// or an unknown mode is refused rather than defaulted: a helper that
    /// guessed what a caller meant is a helper that does something nobody asked.
    public static func decodePlan(_ m: Msg) -> Result<SettingsPlan, SettingsRefusal> {
        switch m.string("kind") ?? "" {
        case "energy":
            guard let on = m.bool("energy.powerd") else {
                return .failure(SettingsRefusal("an energy plan must say whether powerd runs"))
            }
            let ac = m.string("energy.ac") ?? PowerdMode.hiadaptive.rawValue
            let bat = m.string("energy.battery") ?? PowerdMode.adaptive.rawValue
            guard let a = PowerdMode(rawValue: ac), let b = PowerdMode(rawValue: bat) else {
                return .failure(SettingsRefusal("powerd has no mode \(PowerdMode(rawValue: ac) == nil ? ac : bat)"
                    + " (it has: \(PowerdMode.allCases.map(\.rawValue).joined(separator: ", ")))"))
            }
            return .success(.energy(EnergyPlan(powerd: on, onAC: a, onBattery: b)))
        case "":
            return .failure(SettingsRefusal("the request names no kind of plan"))
        case let other:
            return .failure(SettingsRefusal("there is no \(other) plan (there is: energy)"))
        }
    }

    // MARK: - Events

    public static func encode(_ e: SettingsEvent) -> Msg {
        var m = Msg()
        switch e {
        case .starting(let i, let n, let what):
            m.set("event", "starting"); m.set("index", UInt64(i)); m.set("total", UInt64(n)); m.set("what", what)
        case .ok(let i):
            m.set("event", "ok"); m.set("index", UInt64(i))
        case .failed(let i, let what, let why, let ignored):
            m.set("event", "failed"); m.set("index", UInt64(i)); m.set("what", what)
            m.set("why", why); m.set("ignored", ignored)
        case .finished(let ok, let error):
            m.set("event", "finished"); m.set("ok", ok); m.set("error", error)
        }
        return m
    }

    public static func decodeEvent(_ m: Msg) -> SettingsEvent? {
        let i = Int(m.uint64("index") ?? 0)
        switch m.string("event") ?? "" {
        case "starting": return .starting(index: i, total: Int(m.uint64("total") ?? 0), what: m.string("what") ?? "")
        case "ok": return .ok(index: i)
        case "failed": return .failed(index: i, what: m.string("what") ?? "", why: m.string("why") ?? "",
                                      ignored: m.bool("ignored") ?? false)
        case "finished": return .finished(ok: m.bool("ok") ?? false, error: m.string("error") ?? "")
        default: return nil
        }
    }
}
