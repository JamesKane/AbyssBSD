// Portal tests — the request rules and the outcome rules.
//
// The security-relevant part of this component is *what it refuses*, so that is
// what most of these test.

import XCTest
@testable import Portal
import CurrentIPC

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

final class PortalTests: XCTestCase {

    // MARK: - The confused-deputy rule

    /// The invariant the whole design rests on: **a request cannot name the file
    /// that gets opened**. An app supplies a suggested *directory*; the portal
    /// opens what the user picked. If this ever becomes expressible, the portal
    /// has turned into a privileged `open(2)` for anyone who can reach its
    /// socket.
    func testARequestCannotNameTheFileToOpen() {
        var msg = Msg()
        msg.set("method", "file.open")
        // An app trying every plausible way to say "just open this".
        msg.set("path", "/etc/master.passwd")
        msg.set("file", "/etc/master.passwd")
        msg.set("dir", "/home/build")

        let request = PortalRequest(msg)
        guard case .openFile(let startDir) = request else {
            return XCTFail("expected .openFile, got \(request)")
        }
        // Only the directory hint survives parsing; there is nowhere for the
        // path to go — the type has no field for it.
        XCTAssertEqual(startDir, "/home/build")
    }

    func testASuggestedDirectoryMustBeAbsolute() {
        // A relative hint would resolve against the *portal's* working
        // directory, which is not somewhere an app should get to point the
        // picker by accident.
        for bad in ["relative/path", "..", "../../etc", ""] {
            var msg = Msg()
            msg.set("method", "file.open")
            msg.set("dir", bad)
            XCTAssertEqual(PortalRequest(msg), .openFile(startDir: nil),
                           "'\(bad)' should not survive as a start directory")
        }
        var good = Msg()
        good.set("method", "file.open")
        good.set("dir", "/home/build/Documents")
        XCTAssertEqual(PortalRequest(good), .openFile(startDir: "/home/build/Documents"))
    }

    func testASuggestedNameMustBeASinglePathComponent() {
        // "Save as" is a *name*, not a path. An app proposing
        // ../../.ssh/authorized_keys is proposing a location.
        for bad in ["../../.ssh/authorized_keys", "a/b", "..", ".", ""] {
            var msg = Msg()
            msg.set("method", "file.save")
            msg.set("name", bad)
            XCTAssertEqual(PortalRequest(msg), .saveFile(startDir: nil, suggestedName: nil),
                           "'\(bad)' should not survive as a suggested name")
        }
        var good = Msg()
        good.set("method", "file.save")
        good.set("name", "Untitled.txt")
        XCTAssertEqual(PortalRequest(good), .saveFile(startDir: nil, suggestedName: "Untitled.txt"))
    }

    func testUnknownMethodsArePreservedForTheReply() {
        var msg = Msg()
        msg.set("method", "file.delete")     // not a thing, and never will be
        XCTAssertEqual(PortalRequest(msg), .unknown("file.delete"))
        XCTAssertEqual(PortalRequest(Msg()), .unknown(""))
    }

    // MARK: - notify

    func testNotifyNeedsASummary() {
        var empty = Msg()
        empty.set("method", "notify")
        // A blank panel is not a notification; refuse it at the parse.
        XCTAssertEqual(PortalRequest(empty), .unknown("notify (no summary)"))

        var full = Msg()
        full.set("method", "notify")
        full.set("summary", "Build finished")
        full.set("body", "all tests green")
        full.set("timeout", UInt64(8))
        XCTAssertEqual(PortalRequest(full),
                       .notify(summary: "Build finished", body: "all tests green", timeout: 8))

        var minimal = Msg()
        minimal.set("method", "notify")
        minimal.set("summary", "Done")
        XCTAssertEqual(PortalRequest(minimal),
                       .notify(summary: "Done", body: nil, timeout: nil))
    }

    // MARK: - Reading the picker's answer

    /// Exit status and result file are read *together*, because either alone is
    /// ambiguous (PHASE7.md §6.2).
    func testChoiceCancelAndCrashAreDistinguishable() {
        XCTAssertEqual(PickerOutcome.from(status: 0, signalled: false, result: "/home/x/a.txt"),
                       .chose("/home/x/a.txt"))
        XCTAssertEqual(PickerOutcome.from(status: 1, signalled: false, result: nil),
                       .cancelled)
        // A crash is not a cancel.
        if case .failed = PickerOutcome.from(status: 11, signalled: true, result: nil) {} else {
            XCTFail("a signalled picker must be .failed, not .cancelled")
        }
        if case .failed = PickerOutcome.from(status: 127, signalled: false, result: nil) {} else {
            XCTFail("exec failure must be .failed")
        }
    }

    func testExitZeroWithNoResultIsAFailureNotAChoice() {
        // A picker that exits 0 without writing is broken. Reporting that as a
        // choice would mean the portal opening... nothing, or worse, whatever a
        // stale result file held.
        if case .failed = PickerOutcome.from(status: 0, signalled: false, result: nil) {} else {
            XCTFail("exit 0 with no result must be .failed")
        }
    }

    // MARK: - Replies

    func testReplyShapes() {
        let ok = portalReply(.chose("/home/x/a.txt"), mode: .read)
        XCTAssertEqual(ok.bool("ok"), true)
        XCTAssertEqual(ok.string("path"), "/home/x/a.txt")
        XCTAssertEqual(ok.string("mode"), "r")

        let write = portalReply(.chose("/home/x/a.txt"), mode: .write)
        XCTAssertEqual(write.string("mode"), "w")

        let cancelled = portalReply(.cancelled, mode: .read)
        XCTAssertEqual(cancelled.bool("ok"), false)
        XCTAssertEqual(cancelled.string("error"), "cancelled")
        // A cancelled reply must carry no path: there is nothing to open.
        XCTAssertNil(cancelled.string("path"))

        let failed = portalReply(.failed("the picker exited 3"), mode: .read)
        XCTAssertEqual(failed.bool("ok"), false)
        XCTAssertEqual(failed.string("error"), "the picker exited 3")
    }

    // MARK: - The result file, read the portal's way

    func testTheResultReaderRefusesAnythingButAnAbsolutePath() {
        var template = Array("/tmp/abyss-portal-test.XXXXXX".utf8CString)
        guard let dir = template.withUnsafeMutableBufferPointer({
            mkdtemp($0.baseAddress!).map { String(cString: $0) }
        }) else { return XCTFail("mkdtemp failed") }
        defer { _ = rmdir(dir) }

        func write(_ contents: String, to name: String) -> String {
            let path = dir + "/" + name
            let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
            let b = Array(contents.utf8)
            _ = b.withUnsafeBufferPointer { Glibc.write(fd, $0.baseAddress, b.count) }
            close(fd)
            return path
        }

        XCTAssertEqual(FinderPickerResult.read(write("/home/x/a.txt\n", to: "good")),
                       "/home/x/a.txt")
        XCTAssertNil(FinderPickerResult.read(write("relative.txt\n", to: "relative")))
        XCTAssertNil(FinderPickerResult.read(write("", to: "empty")))
        XCTAssertNil(FinderPickerResult.read(dir + "/absent"))
        for name in ["good", "relative", "empty"] { unlink(dir + "/" + name) }
    }

    func testThePickerBinaryCanBeOverridden() {
        let service = PortalService(pickerBinary: "/usr/bin/true")
        XCTAssertEqual(service.pickerBinary, "/usr/bin/true")
        setenv("ABYSS_PICKER", "/usr/bin/false", 1)
        defer { unsetenv("ABYSS_PICKER") }
        XCTAssertEqual(PortalService().pickerBinary, "/usr/bin/false")
    }

    /// A picker that cannot run must produce a clean refusal, not a hang or a
    /// bogus success.
    func testAPickerThatCannotRunIsReportedAsFailed() {
        let dir = "/tmp/abyss-portal-rt.\(getpid())"
        _ = mkdir(dir, 0o700)
        setenv("ABYSS_RUNTIME_DIR", dir, 1)
        defer { unsetenv("ABYSS_RUNTIME_DIR"); _ = rmdir(dir) }

        let service = PortalService(pickerBinary: "/nonexistent/picker")
        let outcome = service.runPicker(startDir: nil, suggestedName: nil)
        if case .failed = outcome {} else {
            XCTFail("a missing picker must be .failed, got \(outcome)")
        }
    }

    /// `/usr/bin/true` exits 0 and writes nothing — the "broken picker" shape,
    /// end to end through the real fork/exec path.
    func testAPickerThatWritesNothingIsNotAChoice() {
        let dir = "/tmp/abyss-portal-rt2.\(getpid())"
        _ = mkdir(dir, 0o700)
        setenv("ABYSS_RUNTIME_DIR", dir, 1)
        defer { unsetenv("ABYSS_RUNTIME_DIR"); _ = rmdir(dir) }

        let truePath = access("/usr/bin/true", X_OK) == 0 ? "/usr/bin/true" : "/bin/true"
        let service = PortalService(pickerBinary: truePath)
        if case .failed = service.runPicker(startDir: nil, suggestedName: nil) {} else {
            XCTFail("a picker that writes nothing must not read as a choice")
        }
    }
}
