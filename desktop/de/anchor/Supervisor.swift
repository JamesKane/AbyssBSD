// Anchor — the session supervisor: start the compositor and the shell, keep
// them alive, and tear the whole thing down together.
//
// A Swift rewrite of the sibling's `anchor` (read as the spec, never linked),
// replacing `abyss/session.sh` — whose restart accounting and teardown ordering
// are the behaviour to match (HANDOFF §2.26). No systemd, no D-Bus, no polling
// of pids: every child is a **pollable descriptor** (pdfork on FreeBSD, pidfd on
// Linux — `de/cproc`), so supervision is one poll() loop that also holds the
// control socket and the signal pipe.

import CProc
import CurrentIPC
import Spawn

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

public final class Supervisor {
    /// A component plus its live state.
    private final class Running {
        let spec: ComponentSpec
        var child = ap_child(fd: -1, pid: -1)
        var startedAt: Double = 0
        var failures = 0
        var restarts = 0
        init(_ spec: ComponentSpec) { self.spec = spec }
        var isUp: Bool { child.fd >= 0 }
    }

    private let policy: RestartPolicy
    /// How long a component waits for something it `requires`. Long enough for a
    /// cold `dbus-daemon` on the FreeBSD guest, short enough that a session that
    /// is never going to compose says so rather than hanging for ever.
    private let dependencyTimeout: Double = 10
    private let components: [Running]
    private let compositor: ComponentSpec?
    private var compositorChild = ap_child(fd: -1, pid: -1)
    private var control: Current.Server?
    private var signalFD: Int32 = -1
    private var stopping = false
    private var exitCode: Int32 = 0
    /// Log lines also go here so tests can assert on decisions without scraping
    /// stderr.
    public private(set) var journal: [String] = []

    public init(compositor: ComponentSpec?,
                components: [ComponentSpec],
                policy: RestartPolicy = RestartPolicy()) {
        self.compositor = compositor
        self.components = components.map(Running.init)
        self.policy = policy
    }

    // MARK: - Logging

    private func log(_ msg: String) {
        journal.append(msg)
        let line = "anchor: \(msg)\n"
        let b = Array(line.utf8)
        _ = b.withUnsafeBufferPointer { write(2, $0.baseAddress, b.count) }
    }

    // MARK: - Spawning

    /// Start one child. argv/envp are built here, in the parent, because after
    /// the fork the child may only make async-signal-safe calls.
    @discardableResult
    private func spawn(_ spec: ComponentSpec, stdoutTo: Int32 = -1) throws -> ap_child {
        guard let path = spec.argv.first else {
            throw CurrentError.malformed("component '\(spec.name)' has no command")
        }
        guard path.hasPrefix("/") else {
            throw CurrentError.malformed("component '\(spec.name)' needs an absolute path, got '\(path)'")
        }
        let env = environmentBlock(base: currentEnvironment(), overrides: spec.env)
        var child = ap_child(fd: -1, pid: -1)
        let rc = Spawn.withCStrings(spec.argv) { argv in
            Spawn.withCStrings(env) { envp in
                ap_child_spawn(argv, envp, stdoutTo, &child)
            }
        }
        guard rc == 0 else {
            throw CurrentError.system(errno, "spawn \(spec.name) (\(path))")
        }
        return child
    }

    private func start(_ r: Running) throws {
        for socket in r.spec.requires {
            guard waitForSocket(socket, seconds: dependencyTimeout) else {
                throw CurrentError.malformed(
                    "\(r.spec.name) needs \(socket), which never accepted a connection")
            }
        }
        r.child = try spawn(r.spec)
        r.startedAt = monotonicSeconds()
    }

    /// Wait until `path` accepts a connection, or give up.
    ///
    /// **Connecting is the readiness test.** The socket file appearing is not:
    /// `bind(2)` creates it and `listen(2)` is a separate call, so a client that
    /// raced into that gap gets ECONNREFUSED and a supervisor that watched for
    /// the file would have declared the dependency met. Nor is a `sleep` — that
    /// is the same race with better manners, and this project has paid for one
    /// of those already (HANDOFF §2.26).
    ///
    /// The connection is dropped immediately. It reaches no protocol, which is
    /// the point: this asks whether something is listening, and nothing else.
    private func waitForSocket(_ path: String, seconds: Double) -> Bool {
        let deadline = monotonicSeconds() + seconds
        var announced = false
        while true {
            if connectsNow(path) { return true }
            if monotonicSeconds() >= deadline { return false }
            if !announced {
                log("waiting for \(path)")
                announced = true
            }
            usleep(25_000)
        }
    }

    private func connectsNow(_ path: String) -> Bool {
        var addr = sockaddr_un()
        addr.sun_family = sunFamilyUnix
        let bytes = Array(path.utf8)
        // sun_path is 108 bytes and a truncated path connects to the wrong
        // thing, or to nothing, without saying so (HANDOFF §2.32).
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard bytes.count < capacity else { return false }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in bytes.enumerated() { raw[i] = b }
        }
        let fd = socket(AF_UNIX, sockStreamType, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
            }
        }
        return ok
    }

    // MARK: - Running the session

    /// Bring the session up and supervise it. Returns the process exit code.
    public func run() -> Int32 {
        do {
            try bringUp()
        } catch {
            log("failed to start the session: \(error)")
            teardown()
            return 1
        }
        loop()
        teardown()
        return exitCode
    }

    private func bringUp() throws {
        // A supervisor must not die because something stopped reading its log
        // (a `| head`, a detached terminal) or because a component closed a
        // socket mid-write. Ignore SIGPIPE and deal with EPIPE where it happens.
        signal(SIGPIPE, SIG_IGN)
        if let comp = compositor {
            compositorChild = try spawn(comp)
            log("compositor up (\(comp.argv.first ?? "?"))")
        }
        for r in components {
            try start(r)
            log("\(r.spec.name) up")
        }
        // Best effort: a session without a control socket still runs, it just
        // can't be driven from outside.
        do {
            let server = try Current.Server(service: "anchor")
            try server.setNonBlocking(true)
            control = server
            log("control service on \(server.path) — abyssctl status|quit")
        } catch {
            log("no control service (\(error)) — the session runs without it")
        }
        var sigs: [Int32] = [SIGTERM, SIGINT]
        signalFD = sigs.withUnsafeMutableBufferPointer {
            ap_signal_pipe($0.baseAddress, Int32($0.count))
        }
        if signalFD < 0 { log("warning: no signal pipe — Ctrl-C won't tear down cleanly") }
        log("session is live (\(components.count) component(s))")
    }

    /// The event loop: children, the control socket and signals all arrive as
    /// readable descriptors, so there is exactly one place that waits.
    private func loop() {
        let exitEvents = Int16(ap_child_exit_events() | POLLERR | POLLHUP | POLLIN)
        while !stopping {
            var fds: [pollfd] = []
            var owners: [Int] = []          // parallel: index into `components`, or -1/-2/-3
            if compositorChild.fd >= 0 {
                fds.append(pollfd(fd: compositorChild.fd, events: exitEvents, revents: 0))
                owners.append(-1)
            }
            for (i, r) in components.enumerated() where r.isUp {
                fds.append(pollfd(fd: r.child.fd, events: exitEvents, revents: 0))
                owners.append(i)
            }
            if let c = control {
                fds.append(pollfd(fd: c.fd, events: Int16(POLLIN), revents: 0))
                owners.append(-2)
            }
            if signalFD >= 0 {
                fds.append(pollfd(fd: signalFD, events: Int16(POLLIN), revents: 0))
                owners.append(-3)
            }
            guard !fds.isEmpty else {
                log("nothing left to supervise")
                return
            }

            let n = fds.withUnsafeMutableBufferPointer { poll($0.baseAddress, nfds_t($0.count), -1) }
            if n < 0 {
                if errno == EINTR { continue }
                log("poll failed: \(String(cString: strerror(errno)))")
                return
            }
            for (i, p) in fds.enumerated() where p.revents != 0 {
                switch owners[i] {
                case -1: compositorExited(); if stopping { return }
                case -2: handleControl(); if stopping { return }
                case -3: handleSignal(); if stopping { return }
                default: componentExited(components[owners[i]]); if stopping { return }
                }
            }
        }
    }

    private func compositorExited() {
        _ = ap_child_reap(&compositorChild, nil)
        // The compositor *is* the session: when it goes, everything goes. This
        // is why the shell components don't get restarted here.
        log("compositor exited — ending the session")
        stopping = true
    }

    private func componentExited(_ r: Running) {
        let ran = monotonicSeconds() - r.startedAt
        _ = ap_child_reap(&r.child, nil)
        switch policy.decide(ranFor: ran, previousFailures: r.failures) {
        case .giveUp(let n):
            log("\(r.spec.name) failed \(n) times in a row — giving up, tearing down")
            exitCode = 1
            stopping = true
        case .restart(let n):
            r.failures = n
            r.restarts += 1
            // No String(format:) — this module is Foundation-free like the rest
            // of de/, so round to one decimal by hand.
            let secs = (ran * 10).rounded() / 10
            log("\(r.spec.name) exited after \(secs)s — restarting "
                + "(\(n)/\(policy.maxConsecutiveFailures))")
            do {
                try start(r)
            } catch {
                log("could not restart \(r.spec.name): \(error) — tearing down")
                exitCode = 1
                stopping = true
            }
        }
    }

    private func handleSignal() {
        var b: UInt8 = 0
        let n = read(signalFD, &b, 1)
        guard n == 1 else { return }
        log("signal \(b) received — tearing down the session")
        stopping = true
    }

    /// One request on the control service. The listener is non-blocking and
    /// poll said it was readable, so `accept` returns at once.
    private func handleControl() {
        guard let server = control else { return }
        _ = try? server.serveOne { request in
            var reply = Msg()
            switch request.string("method") ?? "" {
            case "status":
                reply.set("ok", true)
                reply.set("running", true)
                reply.set("components", UInt64(components.count))
                // "name=up(restarts)" per component — enough to see a flapping
                // one without reading the log.
                let detail = components.map {
                    "\($0.spec.name)=\($0.isUp ? "up" : "down")(\($0.restarts))"
                }.joined(separator: ",")
                reply.set("detail", detail)
                // Read from the environment rather than remembered from the
                // plan, because the question a caller is really asking is "what
                // bus will a child of this session see?" — and the environment
                // is the only thing that answers that. A session started without
                // a bus of its own truthfully reports the one it inherited.
                if let bus = getenv("DBUS_SESSION_BUS_ADDRESS"), bus.pointee != 0 {
                    reply.set("bus", String(cString: bus))
                }
            case "quit", "shutdown":
                reply.set("ok", true)
                stopping = true
            default:
                reply.set("ok", false)
                reply.set("error", "unknown method")
            }
            return reply
        }
        if stopping { log("shutdown requested over the control plane") }
    }

    // MARK: - Teardown

    /// SIGTERM everything at once, give the session one shared beat to exit,
    /// then reap. Order matters: the components go before the compositor, so
    /// they aren't killed by their display vanishing and logged as crashes.
    private func teardown() {
        stopping = true
        var anyLive = false
        for r in components where r.isUp {
            _ = ap_child_signal(&r.child, SIGTERM)
            anyLive = true
        }
        if compositorChild.fd >= 0 {
            _ = ap_child_signal(&compositorChild, SIGTERM)
            anyLive = true
        }
        if anyLive {
            usleep(200_000)     // one shared grace period, as the sibling does
        }
        for r in components where r.isUp { _ = ap_child_reap(&r.child, nil) }
        if compositorChild.fd >= 0 { _ = ap_child_reap(&compositorChild, nil) }
        control?.shutdownAndUnlink()
        control = nil
        log("session down")
    }
}

// SOCK_STREAM and sun_family arrive with different Swift types per platform —
// `__socket_type` on Linux, a plain Int32 on the BSDs. `CurrentIPC` normalises
// the same two constants for the same reason; they are `private` there, and a
// supervisor importing an IPC module's internals to open one probe socket would
// be the worse trade.
#if canImport(Glibc) && os(Linux)
private let sockStreamType = Int32(SOCK_STREAM.rawValue)
#else
private let sockStreamType = Int32(SOCK_STREAM)
#endif
private let sunFamilyUnix = sa_family_t(AF_UNIX)

