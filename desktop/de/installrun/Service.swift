// The installer's privileged half, as a service.
//
// Three methods, and the shape of them is the argument of PHASE5 §1: the caller
// describes what it wants, and this decides whether that may happen and then
// makes it happen. The GUI never names a command.
//
//   disks    {}          → the machine: every disk, what is mounted from it,
//                          which one holds the running root, which pools exist
//   check    {plan…}     → the refusals, and the step list a good plan compiles
//                          to — so a summary page can show both without
//                          anything being written
//   install  {plan…}     → the same compile, then run it, streaming one message
//                          per step and a final `finished`
//
// `check` is not a formality. It is the same `compile` that `install` calls, so
// a plan that passes here is a plan that will not be refused there — and one
// that fails here never becomes a step list at all.

import CurrentIPC
import Install

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

public final class InstallService {
    public let authority: Authority
    /// Run everything except the commands. The events are identical, so a caller
    /// can be developed — and a live test can check the *protocol* — without a
    /// disk in the room.
    public let dryRun: Bool
    /// Where the inventory comes from. A closure so a test can hand in a machine
    /// instead of asking the kernel about this one.
    public let machine: () throws -> DiskInventory

    public private(set) var installsRun = 0

    public init(authority: Authority, dryRun: Bool = false,
                machine: @escaping () throws -> DiskInventory = probeMachine) {
        self.authority = authority
        self.dryRun = dryRun
        self.machine = machine
    }

    /// Serve one connection to completion. Returns what to log about it.
    ///
    /// The caller owns the socket and closes it; this never does, because the
    /// last thing an install sends is the one message that says whether it
    /// worked, and closing under it would turn "failed" into "hung up".
    @discardableResult
    public func serve(_ client: Int32, log: (String) -> Void = { _ in }) -> String {
        // Before anything is read: is this caller allowed to speak at all?
        // Checked here rather than per-method, because there is no method on an
        // installer that an unauthorised caller should get to try.
        let verdict = authority.admits(client)
        guard verdict.ok else {
            var deny = Msg()
            deny.set("ok", false)
            deny.set("error", "refused: " + verdict.why)
            try? Current.send(deny, on: client)
            return "refused a caller: \(verdict.why)"
        }

        var request: Msg
        do { request = try Current.receive(on: client) } catch {
            return "a client connected and said nothing useful: \(error)"
        }
        request.closeFDs()      // no method here takes a descriptor

        switch request.string("method") ?? "" {
        case "disks":
            return handleDisks(client)
        case "check":
            return handleCheck(client, request)
        case "install":
            return handleInstall(client, request, log: log)
        case let other:
            var reply = Msg()
            reply.set("ok", false)
            reply.set("error", other.isEmpty
                      ? "no method named in the request"
                      : "no such method: \(other)")
            try? Current.send(reply, on: client)
            return "unknown method '\(other)'"
        }
    }

    private func handleDisks(_ client: Int32) -> String {
        var reply = Msg()
        do {
            let inv = try machine()
            reply.set("ok", true)
            Wire.encode(inv, into: &reply)
            try? Current.send(reply, on: client)
            return "disks: \(inv.disks.count) disk(s), pools \(inv.importedPools.joined(separator: ","))"
        } catch {
            reply.set("ok", false)
            reply.set("error", describe(error))
            try? Current.send(reply, on: client)
            return "disks: \(describe(error))"
        }
    }

    private func handleCheck(_ client: Int32, _ request: Msg) -> String {
        let plan = Wire.decodePlan(request)
        var reply = Msg()
        do {
            let inv = try machine()
            let refusals = problems(plan, on: inv)
            reply.set("ok", refusals.isEmpty)
            reply.set("problems.count", UInt64(refusals.count))
            for (i, r) in refusals.enumerated() { reply.set("problem.\(i)", r.message) }
            if refusals.isEmpty {
                let list = try compile(plan, on: inv)
                reply.set("steps.count", UInt64(list.count))
                reply.set("render", render(list))
            }
            try? Current.send(reply, on: client)
            return refusals.isEmpty
                ? "check: \(plan.disk) is installable"
                : "check: refused — \(refusals.map(\.message).joined(separator: "; "))"
        } catch {
            reply.set("ok", false)
            reply.set("problems.count", UInt64(1))
            reply.set("problem.0", describe(error))
            reply.set("error", describe(error))
            try? Current.send(reply, on: client)
            return "check: \(describe(error))"
        }
    }

    private func handleInstall(_ client: Int32, _ request: Msg,
                               log: (String) -> Void) -> String {
        let plan = Wire.decodePlan(request)
        let steps: [Step]
        do {
            steps = try compile(plan, on: try machine())
        } catch {
            // A refusal is not a failed install; it is an install that never
            // started, and the caller is told which.
            var reply = Msg()
            reply.set("event", "finished")
            reply.set("ok", false)
            reply.set("error", "refused: " + describe(error))
            try? Current.send(reply, on: client)
            return "install refused: \(describe(error))"
        }

        installsRun += 1
        var lastError = ""
        var sendFailed = false
        _ = execute(steps, dryRun: dryRun) { event in
            if case .finished(_, let error) = event { lastError = error }
            // A client that hangs up mid-install does not stop the install —
            // the disk is already half-rewritten, and abandoning it there is
            // strictly worse than finishing. We stop *talking*, not working.
            guard !sendFailed else { return }
            do { try Current.send(Wire.message(for: event), on: client) }
            catch { sendFailed = true; log("the client stopped listening; finishing anyway") }
        }
        if sendFailed { return "install ran to completion with nobody listening" }
        return lastError.isEmpty
            ? "install: \(steps.count) steps, ok\(dryRun ? " (dry run)" : "")"
            : "install: failed — \(lastError)"
    }
}

func describe(_ error: Error) -> String {
    if let r = error as? PlanRefusal { return r.message }
    if let p = error as? ProbeError {
        switch p {
        case .notSupported(let why): return why
        case .commandFailed(let cmd, let out):
            return "`\(cmd)` failed\(out.isEmpty ? "" : ": " + trimmed(out))"
        }
    }
    return "\(error)"
}
