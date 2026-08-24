// Talking to `abyss-install` from the GUI.
//
// The installer app links `InstallWire` and **not** `InstallRun`: it speaks the
// protocol, it does not carry the code that forks `gpart`. That is what makes
// "the GUI does not touch the disk" (PHASE5 §1) a fact about the binary rather
// than an intention in a comment — there is no path from a click in this
// process to a partition table, because the instructions do not exist here.

import CurrentIPC
import Install
import InstallWire
import CPlatform

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

public enum InstallerClient {
    /// The service name, so a test can point the GUI at its own installer.
    public static var service: String {
        getenv("ABYSS_INSTALL_SERVICE").map { String(cString: $0) } ?? "install"
    }

    /// Ask the machine what disks it has. Returns the inventory, or the reason
    /// there isn't one — which the hub shows on the disk spoke verbatim, rather
    /// than turning into "no disks found". The difference between "this machine
    /// has none" and "I could not look" matters to whoever has to fix it.
    public static func disks() -> (DiskInventory, String) {
        var request = Msg()
        request.set("method", "disks")
        guard let reply = try? Current.call(service, request) else {
            return (DiskInventory(disks: []),
                    "The installer service is not running on this machine")
        }
        guard reply.bool("ok") == true else {
            return (DiskInventory(disks: []), reply.string("error") ?? "unknown error")
        }
        return (Wire.decodeInventory(reply), "")
    }

    /// Ask whether a plan would be accepted, without anything being written.
    /// The hub has already decided the plan is complete; this is the *other*
    /// side's opinion, and the two must agree.
    public static func check(_ plan: InstallPlan) -> [String] {
        var request = Msg()
        request.set("method", "check")
        Wire.encode(plan, into: &request)
        guard let reply = try? Current.call(service, request) else {
            return ["The installer service is not running on this machine"]
        }
        if reply.bool("ok") == true { return [] }
        let n = Int(reply.uint64("problems.count") ?? 0)
        return (0..<n).compactMap { reply.string("problem.\($0)") }
    }

    /// Start an install. Returns the connected socket, which the caller folds
    /// into its run loop and reads events from — a GUI that blocks on this stops
    /// painting, and the one thing a progress screen must do is keep moving.
    public static func begin(_ plan: InstallPlan) -> Int32? {
        var request = Msg()
        request.set("method", "install")
        Wire.encode(plan, into: &request)
        guard let sock = try? Current.connect(service) else { return nil }
        guard (try? Current.send(request, on: sock)) != nil else { close(sock); return nil }
        return sock
    }

    /// Read one event from a socket `begin` returned, or nil when it is done.
    public static func next(on sock: Int32) -> RunEvent? {
        guard let m = try? Current.receive(on: sock) else { return nil }
        if let e = Wire.event(from: m) { return e }
        // A refusal arrives as an ordinary reply rather than an event.
        if m.bool("ok") == false {
            return .finished(ok: false, error: m.string("error") ?? "refused")
        }
        return nil
    }

    /// Hash a password the way the installed system will check it.
    ///
    /// Here, in the unprivileged half, so that **no plaintext ever crosses the
    /// control plane** and none reaches an `InstallPlan` — which is a value that
    /// gets logged, rendered into a golden test, and passed between processes.
    public static func hash(_ password: String) -> String {
        var buf = [CChar](repeating: 0, count: 256)
        let ok = password.withCString { p in
            buf.withUnsafeMutableBufferPointer { b in
                ap_crypt_sha512(p, b.baseAddress, 256) == 0
            }
        }
        // A failure here must not become an account with no password: `*` is
        // what `pw` writes for "nothing will ever match", and the plan's own
        // `noAdministrator` refusal then stops the install.
        return ok ? String(cString: buf) : "*"
    }
}
