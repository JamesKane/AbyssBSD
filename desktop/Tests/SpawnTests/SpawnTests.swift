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

    func testTheEnvironmentReachesADetachedProgram() {
        let out = dir + "/out"
        XCTAssertTrue(Spawn.detached(["sh", "-c", "echo \"$ABYSS_SPAWN_T\" > '\(out)'"],
                                     environment: ["ABYSS_SPAWN_T": "given"]))
        XCTAssertEqual(read(out, within: 5), "given")
    }

    func testAProgramThatCannotBeFoundIsNotForked() {
        XCTAssertFalse(Spawn.detached(["no-such-program-anywhere-\(getpid())"]))
        XCTAssertFalse(Spawn.detached([]))
        var status: Int32 = 0
        errno = 0
        XCTAssertEqual(waitpid(-1, &status, WNOHANG), -1)
        XCTAssertEqual(errno, ECHILD, "a fork happened for a command that was never going to run")
    }

    // MARK: - Running, for the output (S.3)

    func testStdoutAndStderrAreKeptApartAndTheExitCodeIsReported() {
        let r = Spawn.run(["sh", "-c", "echo out; echo err >&2; exit 3"])
        XCTAssertEqual(r.stdoutText, "out\n")
        XCTAssertEqual(r.stderrText, "err\n", "stderr must never be parsed as data — so it is kept apart")
        XCTAssertEqual(r.exitCode, 3)
        XCTAssertEqual(r.code, 3)
        XCTAssertFalse(r.succeeded)
        XCTAssertNil(r.failure)
    }

    func testMergedOutputKeepsItsOrder() {
        let r = Spawn.run(["sh", "-c", "echo a; echo b >&2; echo c"], stderr: .merge)
        XCTAssertEqual(r.stdoutText, "a\nb\nc\n")
        XCTAssertTrue(r.stderr.isEmpty)
    }

    /// Without input a child reads /dev/null: `cat` must finish, not wait on
    /// whatever the caller's stdin is.
    func testWithoutInputStdinIsDevNull() {
        let r = Spawn.run(["cat"])
        XCTAssertTrue(r.succeeded)
        XCTAssertTrue(r.stdout.isEmpty)
    }

    /// **More than a pipe holds, both ways at once.** Writing all the input
    /// and then reading the output deadlocks here: cat blocks writing to a full
    /// stdout while we block writing to its full stdin. One poll loop does not.
    func testInputAndOutputLargerThanAPipeDoNotDeadlock() {
        let input = (0..<(1 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 7) }
        let r = Spawn.run(["cat"], input: input, limit: 2 << 20)
        XCTAssertTrue(r.succeeded)
        XCTAssertEqual(r.stdout.count, input.count)
        XCTAssertEqual(r.stdout, input)
    }

    /// **The fathom bug.** A child that fills stderr before writing stdout,
    /// read by a caller that drains stdout first, waits for ever on both sides.
    func testAFullStderrBeforeStdoutDoesNotDeadlock() {
        let r = Spawn.run(["sh", "-c", "head -c 1048576 /dev/zero >&2; echo done"],
                          limit: 2 << 20)
        XCTAssertTrue(r.succeeded)
        XCTAssertEqual(r.stderr.count, 1 << 20)
        XCTAssertEqual(r.stdoutText, "done\n")
    }

    /// **The installer's bug.** Past the limit the rest is read and dropped,
    /// so the program runs to its real end — not killed by SIGPIPE and
    /// reported as failing.
    func testPastTheLimitTheRestIsDrainedAndTheProgramFinishes() {
        // `head` itself, not under `sh -c`: a shell that carries on after its
        // child dies of SIGPIPE exits 0 and hides exactly what this is for —
        // the first version of this test did, and passed with the bug put back.
        let r = Spawn.run(["head", "-c", "3000000", "/dev/zero"], limit: 1000)
        XCTAssertEqual(r.stdout.count, 1000)
        XCTAssertEqual(r.exitCode, 0, "the program did not finish normally (signal \(r.signal ?? 0))")
    }

    /// A child that exits without reading its input: our write gets EPIPE,
    /// and the SIGPIPE it raises must not kill us. If it did, this test
    /// process would die here rather than fail.
    func testAChildThatIgnoresItsInputCannotKillTheCaller() {
        let r = Spawn.run(["true"], input: [UInt8](repeating: 65, count: 4 << 20))
        XCTAssertEqual(r.exitCode, 0)
    }

    func testASignalledProgramIsReportedAsSignalled() {
        let r = Spawn.run(["sh", "-c", "kill -TERM $$"])
        XCTAssertNil(r.exitCode)
        XCTAssertEqual(r.signal, SIGTERM)
        XCTAssertEqual(r.code, 128 + SIGTERM)
    }

    func testAProgramThatIsNotFoundSaysSo() {
        let r = Spawn.run(["no-such-program-anywhere-\(getpid())"])
        XCTAssertNil(r.rawStatus)
        XCTAssertEqual(r.code, 127, "the shell's number for not found")
        XCTAssertTrue(r.failure?.hasSuffix(": not found") ?? false, r.failure ?? "no failure")
        var status: Int32 = 0
        errno = 0
        XCTAssertEqual(waitpid(-1, &status, WNOHANG), -1)
        XCTAssertEqual(errno, ECHILD, "a process was started for a command that does not exist")
    }

    func testTheEnvironmentIsAddedToOursNotInsteadOfIt() {
        let r = Spawn.run(["sh", "-c", "echo \"$ABYSS_SPAWN_T:${PATH:+path}\""],
                          environment: ["ABYSS_SPAWN_T": "given"])
        XCTAssertEqual(r.stdoutText, "given:path\n")
    }
}
