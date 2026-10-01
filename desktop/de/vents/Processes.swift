// Processes — what is running, for Activity Monitor (PHASE15 P15.7).
//
// One `sample()` reads every process (FreeBSD's `kern.proc.proc`, no kvm;
// Linux's /proc) and the machine's memory; `ProcessTable`, pure, turns two
// samples into rows — %CPU is CPU time used between them over the time between
// them — and sorts and filters them. A process is the same process across two
// samples only if its pid **and** its start time agree: a pid reused in between
// is a new process, not an old one that suddenly used a lot of CPU.

import CVents

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

public enum Processes {
    public struct Info: Equatable, Hashable, Sendable {
        public let pid: Int32
        public let ppid: Int32
        public let uid: UInt32
        public let threads: Int32
        public let residentBytes: UInt64
        public let virtualBytes: UInt64
        public let cpuMicroseconds: UInt64
        public let started: Int64
        public let state: Character
        /// A kernel process or thread: shown, never signalled.
        public let system: Bool
        public let name: String

        public init(pid: Int32, ppid: Int32 = 0, uid: UInt32, threads: Int32 = 1, residentBytes: UInt64 = 0,
                    virtualBytes: UInt64 = 0, cpuMicroseconds: UInt64 = 0, started: Int64 = 0,
                    state: Character = "S", system: Bool = false, name: String) {
            self.pid = pid; self.ppid = ppid; self.uid = uid; self.threads = threads
            self.residentBytes = residentBytes; self.virtualBytes = virtualBytes
            self.cpuMicroseconds = cpuMicroseconds; self.started = started
            self.state = state; self.system = system; self.name = name
        }

        /// Who this process is across samples: its pid at its start.
        public var identity: Identity { Identity(pid: pid, started: started) }
    }

    public struct Identity: Hashable, Sendable {
        public let pid: Int32
        public let started: Int64
    }

    public struct Sample: Sendable {
        public let processes: [Info]
        /// Monotonic microseconds when it was taken.
        public let at: UInt64
        public let memoryTotal: UInt64
        public let memoryAvailable: UInt64
        public init(processes: [Info], at: UInt64, memoryTotal: UInt64 = 0, memoryAvailable: UInt64 = 0) {
            self.processes = processes; self.at = at
            self.memoryTotal = memoryTotal; self.memoryAvailable = memoryAvailable
        }
    }

    /// Every process now, or nil if the system would not say.
    public static func sample() -> Sample? {
        var cap = 1024
        while true {
            var buf = [av_proc](repeating: av_proc(), count: cap)
            let n = buf.withUnsafeMutableBufferPointer { av_proc_list($0.baseAddress, Int32(cap)) }
            if n < 0 { return nil }
            if Int(n) == cap, cap < 1 << 20 { cap *= 4; continue }     // more than fitted: again, bigger
            var ts = timespec(); clock_gettime(CLOCK_MONOTONIC, &ts)
            var total: UInt64 = 0, avail: UInt64 = 0
            _ = av_memory(&total, &avail)
            let list = buf.prefix(Int(n)).map { p -> Info in
                let name = withUnsafeBytes(of: p.name) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
                return Info(pid: p.pid, ppid: p.ppid, uid: p.uid, threads: p.threads,
                            residentBytes: p.rss_bytes, virtualBytes: p.vsize_bytes,
                            cpuMicroseconds: p.cpu_usec, started: p.start_sec,
                            state: Character(Unicode.Scalar(UInt8(bitPattern: p.state))),
                            system: p.system != 0, name: name)
            }
            return Sample(processes: list, at: UInt64(ts.tv_sec) * 1_000_000 + UInt64(ts.tv_nsec) / 1000,
                          memoryTotal: total, memoryAvailable: avail)
        }
    }

    /// The name an account goes by, for the User column.
    public static func userName(_ uid: UInt32) -> String {
        guard let pw = getpwuid(uid_t(uid)), let n = pw.pointee.pw_name else { return String(uid) }
        return String(cString: n)
    }
}

/// The rows Activity Monitor shows, from two samples.
public struct ProcessTable: Sendable {
    public struct Row: Equatable, Sendable {
        public let info: Processes.Info
        /// Percent of one CPU, as `top` shows it (a busy two-thread process can pass 100).
        public let cpuPercent: Double
    }

    public enum Column: String, Sendable, CaseIterable {
        case pid, name, user, cpu, threads, memory
    }

    public enum Filter: Sendable { case all, mine(UInt32) }

    public private(set) var rows: [Row] = []

    public init() {}

    /// The rows for `now`, %CPU measured against `before` (nil: zero, there
    /// being nothing yet to measure against).
    public init(now: Processes.Sample, before: Processes.Sample?) {
        var previous: [Processes.Identity: UInt64] = [:]
        for p in before?.processes ?? [] { previous[p.identity] = p.cpuMicroseconds }
        let elapsed = before.map { now.at > $0.at ? Double(now.at - $0.at) : 0 } ?? 0
        rows = now.processes.map { p in
            var cpu = 0.0
            if elapsed > 0, let was = previous[p.identity], p.cpuMicroseconds >= was {
                cpu = Double(p.cpuMicroseconds - was) / elapsed * 100
            }
            return Row(info: p, cpuPercent: cpu)
        }
    }

    /// Filtered, then sorted by `column`; ties broken by pid, so the order
    /// does not shuffle between refreshes.
    public func view(filter: Filter, sortBy column: Column, ascending: Bool,
                     userName: (UInt32) -> String = Processes.userName) -> [Row] {
        var r = rows
        if case .mine(let uid) = filter { r = r.filter { $0.info.uid == uid } }
        func less(_ a: Row, _ b: Row) -> Bool {
            switch column {
            case .pid: return a.info.pid < b.info.pid
            case .name: return a.info.name.lowercased() < b.info.name.lowercased()
            case .user: return userName(a.info.uid) < userName(b.info.uid)
            case .cpu: return a.cpuPercent < b.cpuPercent
            case .threads: return a.info.threads < b.info.threads
            case .memory: return a.info.residentBytes < b.info.residentBytes
            }
        }
        return r.sorted { a, b in
            if less(a, b) != less(b, a) { return ascending ? less(a, b) : less(b, a) }
            return a.info.pid < b.info.pid
        }
    }

    /// "12.5 MB", "1.20 GB", "512 KB" — as Activity Monitor writes memory.
    public static func formatBytes(_ b: UInt64) -> String {
        let k = 1024.0, v = Double(b)
        if v >= k * k * k { return twoDigits(v / (k * k * k)) + " GB" }
        if v >= k * k { return oneDigit(v / (k * k)) + " MB" }
        return String(Int((v / k).rounded())) + " KB"
    }

    public static func formatPercent(_ p: Double) -> String { oneDigit(p) }

    static func oneDigit(_ v: Double) -> String {
        let t = Int((v * 10).rounded())
        return "\(t / 10).\(abs(t % 10))"
    }

    static func twoDigits(_ v: Double) -> String {
        let t = Int((v * 100).rounded())
        let f = abs(t % 100)
        return "\(t / 100).\(f < 10 ? "0" : "")\(f)"
    }
}
