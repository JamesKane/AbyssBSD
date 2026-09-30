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

    // MARK: - Screenshot (P7.5)

    /// `file.open` at least takes a directory hint. A screenshot request takes
    /// **nothing** — so nothing an app sends alongside it can survive parsing.
    /// The same unrepresentability argument as the file chooser, one step
    /// further: there is no field at all, so there is nothing to sanitise.
    func testAScreenshotRequestCarriesNothingAnAppSent() {
        var msg = Msg()
        msg.set("method", "screenshot")
        // Every plausible way to say "capture *that* instead".
        msg.set("output", "HEADLESS-2")
        msg.set("path", "/etc/master.passwd")
        msg.set("dir", "/home/build")
        msg.set("window", UInt64(42))
        XCTAssertEqual(PortalRequest(msg), .screenshot)
    }

    /// The reply is a capability and nothing else. A `path` here would hand back
    /// the very name the request was not allowed to contain — and the file it
    /// came from is unlinked before the descriptor is sent, so any path would be
    /// a lie as well as a leak.
    func testTheScreenshotReplyNamesNoPath() {
        let reply = portalScreenshotReply(.captured(width: 520, height: 400))
        XCTAssertEqual(reply.bool("ok"), true)
        XCTAssertEqual(reply.uint64("width"), 520)
        XCTAssertEqual(reply.uint64("height"), 400)
        XCTAssertEqual(reply.string("mode"), "r")
        XCTAssertNil(reply.string("path"))
    }

    /// Exit status and file state, read together, exactly as the picker's are
    /// (PHASE7.md §6.2).
    func testAGrabThatWroteNoImageIsNotACapture() {
        let png = PNGSize(width: 8, height: 8)
        XCTAssertEqual(GrabOutcome.from(status: 0, signalled: false, image: png),
                       .captured(width: 8, height: 8))
        // Exit 0 with nothing readable is a broken helper, never a capture —
        // otherwise the portal hands over a descriptor to it knows not what.
        if case .failed = GrabOutcome.from(status: 0, signalled: false, image: nil) {} else {
            XCTFail("exit 0 with no PNG must not read as a capture")
        }
        // A helper that produced an image but failed is still a failure: the
        // status is the authority on whether the capture completed.
        if case .failed = GrabOutcome.from(status: 1, signalled: false, image: png) {} else {
            XCTFail("a non-zero exit must not read as a capture")
        }
        if case .failed = GrabOutcome.from(status: 11, signalled: true, image: png) {} else {
            XCTFail("a killed helper must not read as a capture")
        }
    }

    /// The portal confirms the bytes are an image before handing them over. It
    /// decodes nothing — but "a capability to what?" has to have an answer.
    func testPNGHeaderReadsSizeAndRejectsEverythingElse() {
        var png = PNGHeader.signature
        png += [0, 0, 0, 13] + Array("IHDR".utf8)
        png += [0, 0, 0x02, 0x08]           // width  520
        png += [0, 0, 0x01, 0x90]           // height 400
        XCTAssertEqual(PNGHeader.size(of: png), PNGSize(width: 520, height: 400))

        // Truncated: a helper killed mid-write leaves exactly this.
        XCTAssertNil(PNGHeader.size(of: Array(png[0..<20])))
        // Right length, wrong file — a JPEG, or anything else that isn't ours.
        var notPNG = [UInt8](repeating: 0xAB, count: 24)
        notPNG[0] = 0xFF; notPNG[1] = 0xD8
        XCTAssertNil(PNGHeader.size(of: notPNG))
        // The signature alone is not enough; the IHDR has to be there too.
        var noIHDR = png
        noIHDR[12] = 0x49; noIHDR[13] = 0x45; noIHDR[14] = 0x4E; noIHDR[15] = 0x44
        XCTAssertNil(PNGHeader.size(of: noIHDR))
        // A zero dimension is not an image.
        var zero = png
        zero[16] = 0; zero[17] = 0; zero[18] = 0; zero[19] = 0
        XCTAssertNil(PNGHeader.size(of: zero))
        XCTAssertNil(PNGHeader.size(of: []))
    }

    /// A capture helper that cannot run is a clean refusal, and — the part worth
    /// pinning — **no descriptor comes back with it**. A failed capability
    /// request must hand over nothing at all.
    func testAGrabberThatCannotRunYieldsNoDescriptor() {
        let dir = "/tmp/abyss-portal-rt3.\(getpid())"
        _ = mkdir(dir, 0o700)
        setenv("ABYSS_RUNTIME_DIR", dir, 1)
        defer { unsetenv("ABYSS_RUNTIME_DIR"); _ = rmdir(dir) }

        let service = PortalService(pickerBinary: "/nonexistent/picker",
                                    grabberBinary: "/nonexistent/grabber")
        let (reply, fd) = service.handle(.screenshot)
        XCTAssertEqual(reply.bool("ok"), false)
        XCTAssertNotNil(reply.string("error"))
        XCTAssertNil(fd, "a failed capture must not hand back a descriptor")
    }

    /// `/usr/bin/true` exits 0 and writes no image: the "broken helper" shape,
    /// through the real fork/exec path. It must not become a capability.
    func testAGrabberThatWritesNoImageYieldsNoDescriptor() {
        let dir = "/tmp/abyss-portal-rt4.\(getpid())"
        _ = mkdir(dir, 0o700)
        setenv("ABYSS_RUNTIME_DIR", dir, 1)
        defer { unsetenv("ABYSS_RUNTIME_DIR"); _ = rmdir(dir) }

        let truePath = access("/usr/bin/true", X_OK) == 0 ? "/usr/bin/true" : "/bin/true"
        let service = PortalService(pickerBinary: truePath, grabberBinary: truePath)
        let (reply, fd) = service.handle(.screenshot)
        XCTAssertEqual(reply.bool("ok"), false)
        XCTAssertNil(fd)
        // And it left nothing behind in the runtime dir for anyone to find.
        XCTAssertEqual(access(dir + "/shot.\(getpid()).png", F_OK), -1)
    }
}
