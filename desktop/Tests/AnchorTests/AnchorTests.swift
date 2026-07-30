// Anchor tests — the supervisor's *decisions*, which are the part that can be
// wrong quietly. Spawning and tearing down real processes is proved live by
// abyss/tests/live-anchor.sh.

import XCTest
@testable import Anchor

final class AnchorTests: XCTestCase {

    // MARK: - Restart policy

    func testAFlappingComponentIsEventuallyAbandoned() {
        let p = RestartPolicy(maxConsecutiveFailures: 3, healthyRunSeconds: 5)
        // Five failures in a row, each one immediate: restart, restart, restart,
        // then give up — a component that dies instantly forever is a broken
        // build, and respawning it just fills the log.
        XCTAssertEqual(p.decide(ranFor: 0.1, previousFailures: 0), .restart(consecutiveFailures: 1))
        XCTAssertEqual(p.decide(ranFor: 0.1, previousFailures: 1), .restart(consecutiveFailures: 2))
        XCTAssertEqual(p.decide(ranFor: 0.1, previousFailures: 2), .restart(consecutiveFailures: 3))
        XCTAssertEqual(p.decide(ranFor: 0.1, previousFailures: 3), .giveUp(consecutiveFailures: 4))
    }

    func testAHealthyRunClearsTheStreak() {
        let p = RestartPolicy(maxConsecutiveFailures: 3, healthyRunSeconds: 5)
        // Four failures deep, but this run lasted: the count restarts at 1, so a
        // component that worked for an hour gets its full budget again rather
        // than inheriting failures from earlier in the session.
        XCTAssertEqual(p.decide(ranFor: 60, previousFailures: 3), .restart(consecutiveFailures: 1))
        // Exactly at the threshold counts as healthy.
        XCTAssertEqual(p.decide(ranFor: 5, previousFailures: 3), .restart(consecutiveFailures: 1))
        // Just under does not.
        XCTAssertEqual(p.decide(ranFor: 4.999, previousFailures: 3), .giveUp(consecutiveFailures: 4))
    }

    func testZeroRestartsMeansOneStrike() {
        let p = RestartPolicy(maxConsecutiveFailures: 0, healthyRunSeconds: 5)
        XCTAssertEqual(p.decide(ranFor: 0.1, previousFailures: 0), .giveUp(consecutiveFailures: 1))
        // Even a long healthy run gives up, because the streak still starts at 1.
        XCTAssertEqual(p.decide(ranFor: 3600, previousFailures: 0), .giveUp(consecutiveFailures: 1))
    }

    /// The policy matches `abyss/session.sh`, the thing it replaces: a run of
    /// >= 5s resets `fails`, then the failure is counted, and more than
    /// `max_restarts` in a row is fatal.
    func testDefaultsMatchTheShellSupervisorItReplaces() {
        let p = RestartPolicy()
        XCTAssertEqual(p.maxConsecutiveFailures, 5)
        XCTAssertEqual(p.healthyRunSeconds, 5)
        XCTAssertEqual(p.decide(ranFor: 0, previousFailures: 4), .restart(consecutiveFailures: 5))
        XCTAssertEqual(p.decide(ranFor: 0, previousFailures: 5), .giveUp(consecutiveFailures: 6))
    }

    // MARK: - Building a child's environment

    func testOverridesLayerOverTheInheritedEnvironment() {
        let base = ["PATH": "/bin", "HOME": "/home/build", "AQUA_SCENE": "old"]
        let block = environmentBlock(base: base,
                                     overrides: ["AQUA_SCENE": "dock", "WAYLAND_DISPLAY": "wayland-1"])
        // Sorted, so a child's environment is reproducible run to run.
        XCTAssertEqual(block, ["AQUA_SCENE=dock", "HOME=/home/build",
                               "PATH=/bin", "WAYLAND_DISPLAY=wayland-1"])
    }

    func testAnEmptyOverrideStillReplaces() {
        let block = environmentBlock(base: ["A": "1"], overrides: ["A": ""])
        XCTAssertEqual(block, ["A="])
    }

    func testTheProcessEnvironmentIsReadable() {
        setenv("ABYSS_TEST_MARKER", "present", 1)
        defer { unsetenv("ABYSS_TEST_MARKER") }
        XCTAssertEqual(currentEnvironment()["ABYSS_TEST_MARKER"], "present")
        // Real environments always have a PATH; this catches a parser that
        // silently produces nothing.
        XCTAssertNotNil(currentEnvironment()["PATH"])
    }

    // MARK: - Command splitting

    func testCommandSplittingIsWhitespaceOnly() {
        XCTAssertEqual(splitCommand("/usr/local/bin/sway"), ["/usr/local/bin/sway"])
        XCTAssertEqual(splitCommand("  /bin/sleep   300 "), ["/bin/sleep", "300"])
        XCTAssertEqual(splitCommand(""), [])
        // Deliberately not a shell: quotes are not honoured, they are just
        // characters. A component whose argument contains a space needs the
        // argv form instead of pretending this parses.
        XCTAssertEqual(splitCommand("/bin/echo \"a b\""), ["/bin/echo", "\"a", "b\""])
    }

    // MARK: - Component specs

    func testASpecCarriesItsEnvironment() {
        let spec = ComponentSpec(name: "dock", argv: ["/x/AquaDemo"], env: ["AQUA_SCENE": "dock"])
        XCTAssertEqual(spec.name, "dock")
        XCTAssertEqual(spec.argv, ["/x/AquaDemo"])
        XCTAssertEqual(spec.env["AQUA_SCENE"], "dock")
    }

    func testMonotonicClockMovesForward() {
        let a = monotonicSeconds()
        usleep(20_000)
        let b = monotonicSeconds()
        XCTAssertGreaterThan(b, a)
        XCTAssertLessThan(b - a, 5, "20ms should not read as seconds")
    }
}
