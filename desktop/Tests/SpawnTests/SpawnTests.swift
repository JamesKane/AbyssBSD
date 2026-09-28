// Spawn tests — a detached program really runs, in its own session, and
// leaves nothing behind to reap (BACKLOG S.2).
//
// What these cannot show is the point of the change: that the child allocates
// nothing between `fork` and `execve`. A deadlock from a lock held across the
// fork is a race, not a result — the argument for the code is in its header,
// and the review is the test.

import XCTest
@testable import Spawn

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

final class SpawnTests: XCTestCase {

    private var dir = ""

    override func setUp() {
        var template = Array("/tmp/abyss-spawn-XXXXXX".utf8CString)
        dir = template.withUnsafeMutableBufferPointer { String(cString: mkdtemp($0.baseAddress!)) }
    }

    override func tearDown() {
        for f in ["out", "notexec"] { unlink(dir + "/" + f) }
        rmdir(dir + "/adir")
        rmdir(dir)
    }

    private func read(_ path: String, within seconds: Double) -> String? {
        let deadline = Double(time(nil)) + seconds
        while Double(time(nil)) <= deadline {
            if let f = fopen(path, "r") {
                var buf = [CChar](repeating: 0, count: 256)
                let got = fgets(&buf, 256, f) != nil
                fclose(f)
                if got {
                    let s = String(cString: buf).trimmingCharacters(in: .newlines)
                    if !s.isEmpty { return s }
                }
            }
            usleep(20_000)
        }
        return nil
    }

    // MARK: - Resolving, in the parent

    func testABareNameIsFoundOnThePath() {
        XCTAssertEqual(Spawn.resolveExecutable("sh", path: "/nonexistent:/bin"), "/bin/sh")
        XCTAssertEqual(Spawn.resolveExecutable("sh", path: "/bin/"), "/bin/sh", "a trailing slash")
    }

    func testAPathIsTakenAsGivenOrRefused() {
        XCTAssertEqual(Spawn.resolveExecutable("/bin/sh"), "/bin/sh")
        XCTAssertNil(Spawn.resolveExecutable("/bin/no-such-program-here"))
        XCTAssertNil(Spawn.resolveExecutable(""))
        XCTAssertNil(Spawn.resolveExecutable("sh", path: "/nonexistent"))
    }

    func testOnlyAnExecutableRegularFileCounts() {
        let plain = dir + "/notexec"
        let f = fopen(plain, "w")!; fputs("#!/bin/sh\n", f); fclose(f)
        chmod(plain, 0o644)
        XCTAssertNil(Spawn.resolveExecutable(plain), "not executable")
        mkdir(dir + "/adir", 0o755)
        XCTAssertNil(Spawn.resolveExecutable(dir + "/adir"), "a directory is executable, and not a program")
    }

    // MARK: - Running, detached

    /// It runs; it is a session leader of its own (`setsid`), not in ours;
    /// and nothing is left for us to reap — the middle child was waited for,
    /// and the grandchild belongs to init.
    func testADetachedProgramRunsInItsOwnSessionAndLeavesNothingToReap() {
        let out = dir + "/out"
        // $$ is the shell's pid; `ps -o sid=` its session. Both base tools on
        // FreeBSD and Linux alike.
        XCTAssertTrue(Spawn.detached(["sh", "-c", "echo $$ $(ps -o sid= -p $$) > '\(out)'"]))
        guard let line = read(out, within: 5) else { return XCTFail("the program never ran") }
        let fields = line.split(separator: " ").compactMap { Int32($0) }
        XCTAssertEqual(fields.count, 2, "unexpected output: \(line)")
        guard fields.count == 2 else { return }
        XCTAssertEqual(fields[0], fields[1], "not a session leader: setsid did not happen")
        XCTAssertNotEqual(fields[1], getsid(0), "it is still in our session")

        var status: Int32 = 0
        errno = 0
        XCTAssertEqual(waitpid(-1, &status, WNOHANG), -1, "a child was left for us to reap")
        XCTAssertEqual(errno, ECHILD)
    }

    func testAProgramThatCannotBeFoundIsNotForked() {
        XCTAssertFalse(Spawn.detached(["no-such-program-anywhere-\(getpid())"]))
        XCTAssertFalse(Spawn.detached([]))
        var status: Int32 = 0
        errno = 0
        XCTAssertEqual(waitpid(-1, &status, WNOHANG), -1)
        XCTAssertEqual(errno, ECHILD, "a fork happened for a command that was never going to run")
    }
}
