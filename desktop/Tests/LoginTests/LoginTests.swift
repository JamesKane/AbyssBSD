import XCTest
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
}
