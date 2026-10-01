// Processes tests (PHASE15 P15.7): the table from two samples, pure; and one
// look at the real system, which must contain this very test process.

import XCTest
@testable import Vents
#if canImport(Glibc)
import Glibc
#endif

final class ProcessesTests: XCTestCase {
    private func p(_ pid: Int32, _ name: String, uid: UInt32 = 1000, cpu: UInt64, started: Int64 = 100,
                   rss: UInt64 = 0, threads: Int32 = 1) -> Processes.Info {
        Processes.Info(pid: pid, uid: uid, threads: threads, residentBytes: rss, cpuMicroseconds: cpu,
                       started: started, name: name)
    }

    /// %CPU is CPU time over wall time between samples; a pid reused in between
    /// (a new start time) is a new process at 0, not an old one at 1,000%.
    func testCPUIsMeasuredBetweenSamplesOfTheSameProcess() {
        let before = Processes.Sample(processes: [p(10, "busy", cpu: 1_000_000), p(11, "idle", cpu: 50_000),
                                                  p(12, "old", cpu: 5_000_000, started: 100)], at: 10_000_000)
        let now = Processes.Sample(processes: [p(10, "busy", cpu: 1_500_000), p(11, "idle", cpu: 50_000),
                                               p(12, "new", cpu: 20_000_000, started: 900), p(13, "born", cpu: 7)],
                                   at: 11_000_000)
        let t = ProcessTable(now: now, before: before)
        let cpu = Dictionary(uniqueKeysWithValues: t.rows.map { ($0.info.pid, $0.cpuPercent) })
        XCTAssertEqual(cpu[10]!, 50, accuracy: 0.001, "0.5 s of CPU in 1 s")
        XCTAssertEqual(cpu[11], 0)
        XCTAssertEqual(cpu[12], 0, "pid 12 was reused: a different process")
        XCTAssertEqual(cpu[13], 0, "a process with nothing to measure against")
        XCTAssertTrue(ProcessTable(now: now, before: nil).rows.allSatisfy { $0.cpuPercent == 0 })
    }

    func testSortingAndFiltering() {
        let s = Processes.Sample(processes: [p(3, "beta", uid: 0, cpu: 0, rss: 30), p(1, "Alpha", cpu: 0, rss: 10),
                                             p(2, "gamma", cpu: 0, rss: 30, threads: 4)], at: 0)
        let t = ProcessTable(now: s, before: nil)
        XCTAssertEqual(t.view(filter: .all, sortBy: .name, ascending: true).map(\.info.pid), [1, 3, 2],
                       "names sort without regard to case")
        XCTAssertEqual(t.view(filter: .all, sortBy: .memory, ascending: false).map(\.info.pid), [2, 3, 1],
                       "ties broken by pid, so the order holds still between refreshes")
        XCTAssertEqual(t.view(filter: .mine(1000), sortBy: .pid, ascending: true).map(\.info.pid), [1, 2])
        XCTAssertEqual(t.view(filter: .all, sortBy: .threads, ascending: false).first?.info.pid, 2)
    }

    func testMemoryAndPercentAreWrittenAsActivityMonitorWritesThem() {
        XCTAssertEqual(ProcessTable.formatBytes(512 * 1024), "512 KB")
        XCTAssertEqual(ProcessTable.formatBytes(12 * 1024 * 1024 + 512 * 1024), "12.5 MB")
        XCTAssertEqual(ProcessTable.formatBytes(1_288_490_189), "1.20 GB")
        XCTAssertEqual(ProcessTable.formatPercent(3.14159), "3.1")
    }

    /// The real thing: this process is in the sample, as itself.
    func testTheSampleContainsThisProcess() throws {
        let s = try XCTUnwrap(Processes.sample())
        let me = try XCTUnwrap(s.processes.first { $0.pid == getpid() })
        XCTAssertEqual(me.uid, UInt32(getuid()))
        XCTAssertGreaterThan(me.residentBytes, 0)
        XCTAssertGreaterThan(me.started, 1_600_000_000, "a start time since the epoch")
        XCTAssertFalse(me.system)
        XCTAssertGreaterThan(s.memoryTotal, 0)
        XCTAssertGreaterThan(s.processes.count, 5)
    }
}
