import XCTest
import CProc
import CurrentIPC
@testable import Login

/// PHASE16 P16.1: the authenticator's decisions — who is asking, how fast they
/// may ask again, and that a password is never written down. No root, no PAM,
/// no socket: the checker and the account table are handed in.
final class LoginTests: XCTestCase {
    let s: UInt64 = 1_000_000_000

    /// An authenticator whose accounts are a table and whose PAM is a compare.
    private func auth(_ calls: UnsafeMutablePointer<Int>? = nil) -> Authenticator {
        Authenticator(userName: { [1001: "alice", 1002: "bob"][$0] },
                      check: { user, pw in
                          calls?.pointee += 1
                          let right = ["alice": "correct-horse", "bob": "battery-staple"][user]
                          return String(decoding: pw, as: UTF8.self) == right ? .yes : .no("Authentication error")
                      })
    }
    private func ask(_ a: inout Authenticator, uid: UInt32?, _ pw: String, at t: UInt64) -> (Verdict?, String) {
        let r = a.handle(uid: uid, request: LoginWire.request(password: Array(pw.utf8)), now: t)
        return (LoginWire.decode(r.reply), r.log)
    }

    func testTheCallersOwnPasswordIsAcceptedAndAnotherAccountsIsNot() {
        var a = auth()
        XCTAssertEqual(ask(&a, uid: 1001, "correct-horse", at: 0).0, .accepted)
        XCTAssertEqual(ask(&a, uid: 1001, "battery-staple", at: 0).0, .refused,
                       "bob's password says nothing about alice: the uid decides whose is checked")
        XCTAssertEqual(ask(&a, uid: 1002, "battery-staple", at: 0).0, .accepted)
    }

    func testACallerTheKernelWouldNotNameIsRefusedOutright() {
        var a = auth()
        let r = a.handle(uid: nil, request: LoginWire.request(password: Array("correct-horse".utf8)), now: 0)
        XCTAssertEqual(r.reply.bool("ok"), false)
        XCTAssertNil(LoginWire.decode(r.reply))
    }

    func testTwoTyposAreFreeThenEachFailureDoublesTheWait() {
        var l = Limiter()
        l.failed(1, now: 0); XCTAssertEqual(l.wait(for: 1, now: 0), 0)
        l.failed(1, now: 0); XCTAssertEqual(l.wait(for: 1, now: 0), 0)
        l.failed(1, now: 0); XCTAssertEqual(l.wait(for: 1, now: 0), 2 * s)
        l.failed(1, now: 10 * s); XCTAssertEqual(l.wait(for: 1, now: 10 * s), 4 * s)
        for _ in 0..<30 { l.failed(1, now: 0) }
        XCTAssertEqual(l.wait(for: 1, now: 0), Limiter.capNs, "five minutes at most")
        XCTAssertEqual(l.wait(for: 2, now: 0), 0, "another uid is not held up")
        l.succeeded(1)
        XCTAssertEqual(l.wait(for: 1, now: 0), 0)
        XCTAssertEqual(l.failures(of: 1), 0)
    }

    func testWhileWaitingNotEvenTheRightPasswordIsCheckedAndPAMIsNotAsked() {
        var calls = 0
        var a = auth(&calls)
        for _ in 0..<3 { _ = ask(&a, uid: 1001, "wrong", at: 0) }
        XCTAssertEqual(calls, 3)
        let (v, log) = ask(&a, uid: 1001, "correct-horse", at: 1 * s)
        guard case .wait(let ms)? = v else { return XCTFail("expected a wait, got \(String(describing: v))") }
        XCTAssertEqual(ms, 1000)
        XCTAssertEqual(calls, 3, "a caller made to wait must not get a free guess")
        XCTAssertTrue(log.contains("too soon"))
        XCTAssertEqual(ask(&a, uid: 1001, "correct-horse", at: 2 * s).0, .accepted, "the wait over, the right one works")
    }

    func testThePasswordIsNeverInTheLog() {
        var a = auth()
        for pw in ["correct-horse", "hunter2-wrong", "battery-staple"] {
            let (_, log) = ask(&a, uid: 1001, pw, at: 0)
            XCTAssertFalse(log.contains(pw), "logged: \(log)")
        }
    }

    func testAnAccountThatDoesNotExistIsRefusedAndAnUnknownMethodIsAnError() {
        var a = auth()
        XCTAssertEqual(ask(&a, uid: 4242, "anything", at: 0).0, .refused)
        var m = Msg(); m.set("method", "become-root")
        XCTAssertEqual(a.handle(uid: 1001, request: m, now: 0).reply.bool("ok"), false)
    }

    func testTheVerdictsSurviveTheWire() {
        for v: Verdict in [.accepted, .refused, .wait(1500), .unavailable("no PAM")] {
            XCTAssertEqual(LoginWire.decode(LoginWire.reply(v)), v)
        }
    }

    // MARK: Power (P16.4a)

    func testAnyoneMaySleepTheMachineAndOnlyAdministratorsRestartIt() {
        XCTAssertTrue(PowerPolicy.may(.sleep, uid: 1001, groups: []), "sleep is anyone's, as on the Mac")
        XCTAssertFalse(PowerPolicy.may(.restart, uid: 1001, groups: ["audio"]))
        XCTAssertFalse(PowerPolicy.may(.shutDown, uid: 1001, groups: ["video", "audio"]))
        XCTAssertTrue(PowerPolicy.may(.restart, uid: 1001, groups: ["wheel"]))
        XCTAssertTrue(PowerPolicy.may(.shutDown, uid: 1001, groups: ["operator"]), "shutdown(8)'s own group")
        XCTAssertTrue(PowerPolicy.may(.shutDown, uid: 0, groups: []))
    }

    func testEachActionRunsItsCommand() {
        var c = PowerCommands()
        XCTAssertEqual(PowerPolicy.argv(.sleep, commands: c), ["/usr/sbin/acpiconf", "-s", "3"])
        XCTAssertEqual(PowerPolicy.argv(.restart, commands: c), ["/sbin/shutdown", "-r", "now"])
        XCTAssertEqual(PowerPolicy.argv(.shutDown, commands: c), ["/sbin/shutdown", "-p", "now"])
        c.acpiconf = "/tmp/stand-in"
        XCTAssertEqual(PowerPolicy.argv(.sleep, commands: c).first, "/tmp/stand-in")
    }

    func testTheMachinesButtonsAreRootsAlone() {
        for a in [PowerAction.lid, .sleepKey, .powerKey] {
            XCTAssertTrue(PowerPolicy.may(a, uid: 0, groups: []))
            XCTAssertFalse(PowerPolicy.may(a, uid: 1001, groups: ["wheel", "operator"]),
                           "an administrator is not the hardware: \(a)")
        }
        XCTAssertEqual(PowerPolicy.argv(.lid, commands: PowerCommands()), ["/usr/sbin/acpiconf", "-s", "3"])
        XCTAssertEqual(PowerPolicy.argv(.powerKey, commands: PowerCommands()), ["/sbin/shutdown", "-p", "now"],
                       "the power key with nobody to ask: what the kernel would have done")
    }

    // MARK: The login window (P16.5a)

    private func loginRequest(_ user: String, _ pw: String) -> Msg {
        var m = LoginWire.request(password: Array(pw.utf8)); m.set("method", "login"); m.set("user", user); return m
    }
    private func windowAuth() -> Authenticator {
        Authenticator(userName: { _ in nil }, check: { user, pw in
            (user == "ada" && pw == Array("lovelace".utf8)) || (user == "bob" && pw == Array("b".utf8)) ? .yes : .no("wrong")
        })
    }
    private let uids: (String) -> UInt32? = { ["ada": 1001, "bob": 1002][$0] }

    func testOnlyTheLoginWindowMayAskAboutAnotherAccount() {
        var a = windowAuth()
        let r = a.handleLogin(callerIsGreeter: false, request: loginRequest("ada", "lovelace"), now: 0, uidOf: uids)
        XCTAssertEqual(r.reply.bool("ok"), false)
        XCTAssertNil(r.user)
        let g = a.handleLogin(callerIsGreeter: true, request: loginRequest("ada", "lovelace"), now: 0, uidOf: uids)
        XCTAssertEqual(LoginWire.decode(g.reply), .accepted)
        XCTAssertEqual(g.user, "ada", "the service starts ada's session")
    }

    func testTheWaitIsPerAccountAskedAboutAndUnknownNamesCostTheSame() {
        var a = windowAuth()
        for k in 0..<3 { _ = a.handleLogin(callerIsGreeter: true, request: loginRequest("ada", "x\(k)"), now: 0, uidOf: uids) }
        let held = a.handleLogin(callerIsGreeter: true, request: loginRequest("ada", "lovelace"), now: 1, uidOf: uids)
        guard case .wait? = LoginWire.decode(held.reply) else { return XCTFail("ada should wait: \(held.log)") }
        let other = a.handleLogin(callerIsGreeter: true, request: loginRequest("bob", "b"), now: 1, uidOf: uids)
        XCTAssertEqual(LoginWire.decode(other.reply), .accepted, "bob is not held up by guesses at ada")
        let ghost = a.handleLogin(callerIsGreeter: true, request: loginRequest("nobodyhere", "x"), now: 1, uidOf: uids)
        XCTAssertEqual(LoginWire.decode(ghost.reply), .refused, "no such account looks like a wrong password")
        for _ in 0..<2 { _ = a.handleLogin(callerIsGreeter: true, request: loginRequest("nobodyhere", "x"), now: 1, uidOf: uids) }
        guard case .wait? = LoginWire.decode(a.handleLogin(callerIsGreeter: true, request: loginRequest("nobodyhere", "x"),
                                                           now: 2, uidOf: uids).reply) else {
            return XCTFail("guessing at a name that is not an account must cost a wait too")
        }
        XCTAssertFalse(held.log.contains("lovelace"))
    }

    func testTheWindowOffersPeopleNotTheSystemsAccounts() {
        let all: [(name: String, uid: UInt32, gecos: String, shell: String)] = [
            ("root", 0, "Charlie &", "/bin/sh"), ("_loginwindow", 1100, "", "/usr/sbin/nologin"),
            ("nobody", 65534, "Unprivileged user", "/usr/sbin/nologin"), ("daemon", 1, "", "/usr/sbin/nologin"),
            ("zed", 1003, "Zed Shaw,,,", "/bin/sh"), ("ada", 1001, "Ada Lovelace", "/bin/csh"),
            ("svc", 1004, "A service", "/usr/sbin/nologin"), ("bob", 1002, "", "/bin/sh"),
        ]
        XCTAssertEqual(LoginAccounts.offered(all).map(\.name), ["ada", "bob", "zed"])
        XCTAssertEqual(LoginAccounts.offered(all).first?.fullName, "Ada Lovelace")
        XCTAssertEqual(LoginAccounts.offered(all)[1].fullName, "bob", "no full name: the account name")
    }

    func testTheLoginWindowMayRestartAndShutDown() {
        XCTAssertTrue(PowerPolicy.may(.restart, uid: 1100, groups: [], greeterUID: 1100))
        XCTAssertTrue(PowerPolicy.may(.shutDown, uid: 1100, groups: [], greeterUID: 1100))
        XCTAssertFalse(PowerPolicy.may(.restart, uid: 1101, groups: [], greeterUID: 1100))
        XCTAssertFalse(PowerPolicy.may(.powerKey, uid: 1100, groups: [], greeterUID: 1100), "not the hardware")
    }

    // MARK: Sessions (P16.5b)

    /// Only root may start a process as someone else; anyone else, only as
    /// themselves — which is how a test runs the whole login flow unprivileged.
    func testOnlyRootSpawnsAsAnotherAccount() throws {
        try XCTSkipIf(geteuid() == 0, "as root, every account is ours to spawn as")
        var c = ap_child(fd: -1, pid: -1)
        let argv: [UnsafePointer<CChar>?] = [UnsafePointer(strdup("/bin/sh")), UnsafePointer(strdup("-c")),
                                            UnsafePointer(strdup("exit 0")), nil]
        let envp: [UnsafePointer<CChar>?] = [nil]
        errno = 0
        XCTAssertEqual(ap_child_spawn_as("root", argv, envp, -1, &c), -1)
        XCTAssertEqual(errno, EPERM, "another account: refused before any fork")
        XCTAssertEqual(ap_child_spawn_as("nosuchaccount\(getpid())", argv, envp, -1, &c), -1)
        XCTAssertEqual(errno, ENOENT)
        guard let me = getpwuid(geteuid()).map({ String(cString: $0.pointee.pw_name) }) else { return XCTFail("who am I") }
        XCTAssertEqual(ap_child_spawn_as(me, argv, envp, -1, &c), 0, "as oneself: allowed, nothing changed")
        var p = pollfd(fd: c.fd, events: Int16(ap_child_exit_events() | POLLHUP | POLLIN), revents: 0)
        XCTAssertEqual(poll(&p, 1, 5000), 1)
        _ = ap_child_reap(&c, nil)
        // **Reaped means reaped**: on FreeBSD, closing the process descriptor
        // alone left a zombie (HANDOFF §2.108).
        XCTAssertEqual(waitpid(-1, nil, WNOHANG), -1, "a reaped child is not left as a zombie")
    }

    /// One VT each (P16.6b): the greeter's is fixed; people get the lowest
    /// free from 10, keep theirs, and give it back when they log out.
    func testEachSessionHasItsOwnVT() {
        var p = VTPlan()
        XCTAssertEqual(VTPlan.greeter, 9, "ttyv8: what /etc/ttys leaves for a display manager")
        XCTAssertEqual(p.vt(for: "ada"), 10)
        XCTAssertEqual(p.vt(for: "bob"), 11)
        XCTAssertEqual(p.vt(for: "ada"), 10, "ada keeps hers")
        p.release("ada")
        XCTAssertEqual(p.vt(for: "cy"), 10, "the lowest free")
        for n in ["d", "e", "f", "g", "h"] { _ = p.vt(for: n) }
        XCTAssertNil(p.vt(for: "z"), "every VT taken: none, not a shared one")
    }
}
