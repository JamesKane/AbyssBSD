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

    // MARK: - The default session (P8.4)

    /// Build the session a real `anchor` would, on a machine we are not on.
    private func plan(dbusDaemon: String? = "/usr/bin/dbus-daemon",
                      compositorSocket: String? = nil,
                      mode: SessionMode = .desktop,
                      without: Set<String> = []) -> SessionPlan {
        defaultSession(shellBinary: "/opt/abyss/AquaDemo",
                       serviceDirectory: "/opt/abyss",
                       dbusDaemon: dbusDaemon,
                       runtimeDir: "/run/abyss",
                       display: "abyss-0",
                       compositorSocket: compositorSocket,
                       mode: mode,
                       without: without)
    }

    // MARK: - The live medium's session (PHASE5 P5.5)

    func testAnInstallerSessionRunsTheInstallerAndNotAShell() {
        // The medium runs the same compositor, toolkit and supervisor as the
        // installed desktop — one application instead of a shell. If `anchor`
        // can boot the installer, the installer is running on the real desktop
        // rather than on a special one built to demonstrate it.
        let p = plan(mode: .installer)
        let names = p.components.map(\.name)
        XCTAssertEqual(names.filter { $0 == "desktop" || $0 == "installer" },
                       ["desktop", "installer"])
        XCTAssertFalse(names.contains("dock"), "nothing to launch on an installer medium")
        XCTAssertFalse(names.contains("menubar"), "nothing to quit to on an installer medium")
    }

    func testTheInstallerComponentAsksForTheInstallerScene() {
        let p = plan(mode: .installer)
        let installer = p.components.first { $0.name == "installer" }
        XCTAssertEqual(installer?.env["AQUA_SCENE"], "installer")
        // ...and it is the same binary the desktop runs, not a second one.
        XCTAssertEqual(installer?.argv, ["/opt/abyss/AquaDemo"])
    }

    func testAnInstallerSessionStillWaitsForTheCompositor() {
        // The dependency gate is not a desktop nicety: an installer spawned
        // before there is a display spends its restart budget and the medium
        // boots to nothing.
        let p = plan(compositorSocket: "/run/abyss/wayland-1", mode: .installer)
        for c in p.components where c.name == "installer" || c.name == "desktop" {
            XCTAssertEqual(c.requires, ["/run/abyss/wayland-1"], c.name)
        }
    }

    /// The menu bar, and only the menu bar, goes to the compositor's
    /// privileged socket (PHASE10 P10.4) — and waits for it as the shell waits
    /// for the ordinary one, or a slow compositor start would spend its
    /// restart budget.
    func testOnlyTheMenuBarIsPointedAtThePrivilegedSocket() {
        let p = defaultSession(shellBinary: "/opt/abyss/AquaDemo", serviceDirectory: "/opt/abyss",
                               dbusDaemon: nil, runtimeDir: "/run/abyss", display: "abyss-0",
                               compositorSocket: "/run/x/abyss-0",
                               menubarDisplay: "abyss-0-bar", menubarSocket: "/run/x/abyss-0-bar")
        for c in p.components {
            if c.name == "menubar" {
                XCTAssertEqual(c.env["WAYLAND_DISPLAY"], "abyss-0-bar")
                XCTAssertEqual(c.env["ABYSS_APP_WAYLAND_DISPLAY"], "abyss-0",
                               "what the bar launches goes on the ordinary display (P10.8)")
                XCTAssertEqual(c.requires, ["/run/x/abyss-0", "/run/x/abyss-0-bar"])
            } else if c.env["WAYLAND_DISPLAY"] != nil {
                XCTAssertEqual(c.env["WAYLAND_DISPLAY"], "abyss-0",
                               "\(c.name) must not be handed the privileged socket")
            }
        }
        // Without one, the bar is an ordinary client, as before.
        let q = plan()
        XCTAssertEqual(q.components.first { $0.name == "menubar" }?.env["WAYLAND_DISPLAY"], "abyss-0")
    }

    /// The lock screen (PHASE16 P16.2c) is part of a desktop session's plan
    /// but not one of its components — started when asked, not at bring-up —
    /// and it goes on the privileged socket, the only one offered the lock.
    func testTheLockScreenIsPlannedOnThePrivilegedDisplayAndNotStarted() {
        let p = defaultSession(shellBinary: "/opt/abyss/AquaDemo", serviceDirectory: "/opt/abyss",
                               dbusDaemon: nil, runtimeDir: "/run/abyss", display: "abyss-0",
                               menubarDisplay: "abyss-0-bar")
        let lock = p.lockScreen
        XCTAssertEqual(lock?.argv, ["/opt/abyss/AquaDemo"])
        XCTAssertEqual(lock?.env["AQUA_SCENE"], "lock")
        XCTAssertEqual(lock?.env["WAYLAND_DISPLAY"], "abyss-0-bar")
        XCTAssertFalse(p.components.contains { $0.name == "lock" }, "not started with the session")
        // No privileged socket: the ordinary one, which then offers the lock.
        XCTAssertEqual(plan().lockScreen?.env["WAYLAND_DISPLAY"], "abyss-0")
        // The installer has nothing to lock, and `--without lock` means none.
        XCTAssertNil(plan(mode: .installer).lockScreen)
        XCTAssertNil(plan(without: ["lock"]).lockScreen)
    }

    /// The idle policy (PHASE16 P16.3) is a desktop session's, on the
    /// ordinary display, waiting for the compositor like the shell; the
    /// installer has none.
    func testTheIdlePolicyIsADesktopComponent() {
        let p = plan(compositorSocket: "/run/x/abyss-0")
        let idle = p.components.first { $0.name == "idle" }
        XCTAssertEqual(idle?.argv, ["/opt/abyss/abyss-idle"])
        XCTAssertEqual(idle?.env["WAYLAND_DISPLAY"], "abyss-0")
        XCTAssertEqual(idle?.requires, ["/run/x/abyss-0"])
        XCTAssertFalse(plan(mode: .installer).components.contains { $0.name == "idle" })
        XCTAssertFalse(plan(without: ["idle"]).components.contains { $0.name == "idle" })
    }

    /// The login window's session (PHASE16 P16.5b): the window, and nothing
    /// that serves a person who has not logged in yet.
    func testTheGreeterSessionIsTheLoginWindowAlone() {
        let p = plan(mode: .greeter)
        XCTAssertEqual(p.components.map(\.name), ["loginwindow"])
        XCTAssertEqual(p.components.first?.env["AQUA_SCENE"], "loginwindow")
        XCTAssertNil(p.lockScreen, "nothing to lock")
        XCTAssertNil(p.busAddress)
    }

    /// The Setup Assistant (PHASE16 P16.7): planned once, at a first login,
    /// in a desktop session only — and not a component, so never restarted.
    func testTheSetupAssistantIsPlannedOnlyUntilItIsDone() {
        func p(done: Bool, mode: SessionMode = .desktop, without: Set<String> = []) -> SessionPlan {
            defaultSession(shellBinary: "/opt/abyss/AquaDemo", serviceDirectory: "/opt/abyss", dbusDaemon: nil,
                           runtimeDir: "/run/abyss", display: "abyss-0", mode: mode, firstRunDone: done, without: without)
        }
        XCTAssertEqual(p(done: false).firstRun?.env["AQUA_SCENE"], "setupassistant")
        XCTAssertFalse(p(done: false).components.contains { $0.name == "setup" }, "not a component")
        XCTAssertNil(p(done: true).firstRun)
        XCTAssertNil(p(done: false, mode: .greeter).firstRun, "the login window sets nothing up")
        XCTAssertNil(p(done: false, mode: .installer).firstRun)
        XCTAssertNil(p(done: false, without: ["setup"]).firstRun)
    }

    func testTheDesktopSessionIsUnchangedByTheNewMode() {
        // The default is still what it was: a regression here is a desktop that
        // boots without its Dock.
        let names = plan().components.map(\.name)
        XCTAssertEqual(names.suffix(3), ["desktop", "menubar", "dock"])
    }

    /// **The bus is first, and the order is the pass.**
    ///
    /// Not alphabetical, not "services then apps": the bus has to exist before
    /// the shell does, because the shell is what launches applications and a GTK
    /// app double-clicked in the Finder inherits its bus from the Dock. Start it
    /// afterwards and every app launched from the desktop is on no bus at all.
    func testTheSessionStartsInTheOrderItsDependenciesRequire() {
        XCTAssertEqual(plan().components.map(\.name),
                       ["bus", "portal", "bridge", "menus", "idle", "desktop", "menubar", "dock"])
    }

    /// The GTK menu bridge is `abyss-dbus --menus`, on the session's bus, and
    /// waits for it — and there is none without a bus to bridge (P10.6).
    func testTheMenuBridgeIsItsOwnProcessOnTheBus() {
        let p = plan()
        let m = p.components.first { $0.name == "menus" }
        XCTAssertEqual(m?.argv, ["/opt/abyss/abyss-dbus", "--menus"])
        XCTAssertEqual(m?.requires, ["/run/abyss/bus"])
        XCTAssertEqual(m?.env["DBUS_SESSION_BUS_ADDRESS"], p.busAddress)
        XCTAssertNil(plan(dbusDaemon: nil).components.first { $0.name == "menus" })
    }

    /// The bridge names both things it cannot work without, as socket paths —
    /// the only fact about a dependency that can actually be checked.
    func testTheBridgeWaitsForTheBusAndForThePortal() {
        let bridge = plan().components.first { $0.name == "bridge" }
        XCTAssertEqual(bridge?.requires, ["/run/abyss/bus", "/run/abyss/portal.sock"])
        XCTAssertEqual(bridge?.env["DBUS_SESSION_BUS_ADDRESS"], "unix:path=/run/abyss/bus")
    }

    /// The address is ours, and it is inside the session's own runtime directory
    /// beside `anchor.sock` and `portal.sock`.
    ///
    /// The alternative — let `dbus-daemon` choose and read what it printed — is
    /// what every example does, and it gives an address that *changes when the
    /// daemon restarts*, stranding the variable in every child that already has
    /// it. Pinning is what makes the bus restartable at all.
    func testTheSessionNamesItsOwnBusRatherThanAskingWhatItChose() {
        let p = plan()
        XCTAssertEqual(p.busAddress, "unix:path=/run/abyss/bus")
        XCTAssertEqual(p.busAddress, sessionBusAddress(runtimeDir: "/run/abyss"))
        let bus = p.components.first { $0.name == "bus" }
        XCTAssertEqual(bus?.argv.first, "/usr/bin/dbus-daemon")
        XCTAssertTrue(bus?.argv.contains("--address=unix:path=/run/abyss/bus") == true)
        // A supervisor's child must be the process it supervises: let it
        // daemonise and the pollable descriptor belongs to a parent that has
        // already exited, so the session restarts the bus for ever.
        XCTAssertTrue(bus?.argv.contains("--nofork") == true)
        XCTAssertTrue(bus?.argv.contains("--session") == true)
    }

    /// What applications inherit (P15.3): the bus, and — only while the bridge
    /// answers the portal — `GTK_USE_PORTAL=1`, so GTK and Firefox ask for the
    /// Finder. Without a bridge, asking would get no answer, and GTK's own
    /// dialog is better than none.
    func testApplicationsAreToldToUseThePortalOnlyWhenItIsThere() {
        XCTAssertEqual(plan().applicationEnvironment,
                       ["DBUS_SESSION_BUS_ADDRESS": "unix:path=/run/abyss/bus", "GTK_USE_PORTAL": "1"])
        XCTAssertEqual(plan(dbusDaemon: nil).applicationEnvironment, [:])
    }

    func testAConfigFileReplacesTheSystemSessionConfig() {
        let p = defaultSession(shellBinary: "/opt/abyss/AquaDemo",
                               serviceDirectory: "/opt/abyss",
                               dbusDaemon: "/usr/bin/dbus-daemon",
                               dbusConfig: "/tmp/quiet.conf",
                               runtimeDir: "/run/abyss",
                               display: nil)
        let bus = p.components.first { $0.name == "bus" }
        XCTAssertTrue(bus?.argv.contains("--config-file=/tmp/quiet.conf") == true)
        XCTAssertFalse(bus?.argv.contains("--session") == true)
    }

    /// A box with no `dbus-daemon` still gets a desktop — our own apps never
    /// needed a bus — but it must **say so**. A desktop that quietly has no file
    /// chooser for foreign apps is the exact failure this phase exists to fix,
    /// and a silent omission is indistinguishable from a working one until
    /// somebody tries to open a file from GIMP.
    func testWithNoDbusDaemonTheSessionStillBootsAndSaysWhatIsMissing() {
        let p = plan(dbusDaemon: nil)
        XCTAssertEqual(p.components.map(\.name), ["portal", "idle", "desktop", "menubar", "dock"])
        XCTAssertNil(p.busAddress)
        XCTAssertEqual(p.notes.count, 1)
        XCTAssertTrue(p.notes[0].contains("dbus-daemon"), p.notes[0])
    }

    /// Dropping the bus drops the bridge with it, because a bridge with no bus
    /// has nothing to own a name on — and that, too, is said out loud rather
    /// than being a component that silently vanished from the list.
    func testDroppingTheBusDropsTheBridgeAndExplainsItself() {
        let p = plan(without: ["bus"])
        XCTAssertEqual(p.components.map(\.name), ["portal", "idle", "desktop", "menubar", "dock"])
        XCTAssertEqual(p.notes.count, 1)
        XCTAssertTrue(p.notes[0].contains("bridge"), p.notes[0])
    }

    /// Dropping the portal leaves the bridge with only the bus to wait for. It
    /// is still started: a foreign app then gets an error instead of a picker,
    /// which is a worse desktop but a truthful one.
    func testDroppingThePortalLeavesTheBridgeWaitingOnlyForTheBus() {
        let bridge = plan(without: ["portal"]).components.first { $0.name == "bridge" }
        XCTAssertEqual(bridge?.requires, ["/run/abyss/bus"])
    }

    /// The shell waits for the compositor instead of racing it.
    ///
    /// Without this the three components are spawned the instant the compositor
    /// is, fail to connect to a socket that does not exist yet, and spend their
    /// restart budget on it — so a slow compositor start tears the session down
    /// as if the shell were broken.
    func testTheShellWaitsForTheCompositorSocketWhenItsPathIsKnown() {
        let p = plan(compositorSocket: "/run/user/1000/abyss-0")
        for name in ["desktop", "menubar", "dock"] {
            XCTAssertEqual(p.components.first { $0.name == name }?.requires,
                           ["/run/user/1000/abyss-0"], name)
        }
        // Services do not wait for it: the portal only needs a display when it
        // launches the picker, which is minutes later or never.
        XCTAssertEqual(p.components.first { $0.name == "portal" }?.requires, [])
        // And with no knowable path there is no gate rather than a guess.
        XCTAssertEqual(plan().components.first { $0.name == "dock" }?.requires, [])
    }

    func testEveryComponentIsToldWhereTheSessionLives() {
        for c in plan(compositorSocket: "/run/user/1000/abyss-0").components {
            XCTAssertEqual(c.env["ABYSS_RUNTIME_DIR"], "/run/abyss", c.name)
            XCTAssertEqual(c.env["WAYLAND_DISPLAY"], "abyss-0", c.name)
        }
    }

    func testTheShellComponentsCarryTheirScene() {
        let p = plan()
        XCTAssertEqual(p.components.first { $0.name == "desktop" }?.env["AQUA_SCENE"], "wallpaper")
        XCTAssertEqual(p.components.first { $0.name == "menubar" }?.env["AQUA_SCENE"], "menubar")
        XCTAssertEqual(p.components.first { $0.name == "dock" }?.env["AQUA_SCENE"], "dock")
        XCTAssertEqual(p.components.first { $0.name == "dock" }?.argv, ["/opt/abyss/AquaDemo"])
    }

    /// Our own services are found beside the binary rather than on `$PATH`, so a
    /// build tree and an installed tree both work with no configuration — and
    /// nobody's stray `abyss-portal` earlier in `$PATH` gets supervised instead.
    func testOurOwnServicesAreFoundBesideTheBinary() {
        let p = plan()
        XCTAssertEqual(p.components.first { $0.name == "portal" }?.argv, ["/opt/abyss/abyss-portal"])
        XCTAssertEqual(p.components.first { $0.name == "bridge" }?.argv, ["/opt/abyss/abyss-dbus"])
    }

    func testTheBusAddressCanBeTurnedBackIntoASocketPath() {
        XCTAssertEqual(unixSocketPath(ofBusAddress: "unix:path=/run/abyss/bus"), "/run/abyss/bus")
        // dbus-daemon prints the address with its guid appended; the path stops
        // at the comma.
        XCTAssertEqual(unixSocketPath(ofBusAddress: "unix:path=/run/abyss/bus,guid=abc"),
                       "/run/abyss/bus")
        // An abstract socket has no filesystem path, and pretending otherwise
        // would have a caller wait for a file that will never appear.
        XCTAssertNil(unixSocketPath(ofBusAddress: "unix:abstract=/tmp/dbus-x"))
        XCTAssertNil(unixSocketPath(ofBusAddress: "tcp:host=localhost,port=1234"))
    }
}


/// BACKLOG U.7b: the session names our XCursor theme, and a person's own
/// choice stands.
final class CursorEnvironmentTests: XCTestCase {
    func testTheSessionNamesAbyssAndPutsItsDirectoryFirst() {
        let e = cursorEnvironment(runtimeDir: "/run/s", environment: ["HOME": "/home/p"])
        XCTAssertEqual(e["XCURSOR_THEME"], "Abyss")
        XCTAssertEqual(e["XCURSOR_SIZE"], "24")
        XCTAssertEqual(e["XCURSOR_PATH"], "/run/s/icons:/home/p/.local/share/icons:/home/p/.icons:"
                       + "/usr/local/share/icons:/usr/share/icons:/usr/share/pixmaps")
    }

    func testAPersonsOwnThemeAndSizeAreKeptAndTheirPathExtended() {
        let e = cursorEnvironment(runtimeDir: "/run/s", environment: [
            "XCURSOR_THEME": "Adwaita", "XCURSOR_SIZE": "48", "XCURSOR_PATH": "/opt/icons"])
        XCTAssertNil(e["XCURSOR_THEME"], "theirs stands")
        XCTAssertNil(e["XCURSOR_SIZE"], "theirs stands")
        XCTAssertEqual(e["XCURSOR_PATH"], "/run/s/icons:/opt/icons")
    }

    func testAnEmptyVariableIsNotAChoice() {
        let e = cursorEnvironment(runtimeDir: "/r", environment: ["XCURSOR_THEME": "", "XCURSOR_PATH": ""])
        XCTAssertEqual(e["XCURSOR_THEME"], "Abyss")
        XCTAssertEqual(e["XCURSOR_PATH"], "/r/icons:/usr/local/share/icons:/usr/share/icons:/usr/share/pixmaps")
    }
}
