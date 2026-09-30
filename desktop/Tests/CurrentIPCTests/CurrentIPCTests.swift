// CurrentIPC tests — the codec, the framing, and the thing the control plane
// exists for: handing a real file descriptor to another process.
//
// Everything here is portable POSIX, so the same tests run on Linux and FreeBSD
// (PHASE3.md §6.3 — this is why P3.5 wasn't blocked on the toolchain).

import XCTest
@testable import CurrentIPC

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

final class CurrentIPCTests: XCTestCase {

    // MARK: - The message and its wire format

    func testPackUnpackRoundTripsTypedFields() throws {
        var m = Msg()
        m.set("method", "Volume.Set")
        m.set("percent", UInt64(80))
        m.set("mute", false)
        m.set("blob", bytes: [1, 2, 3, 0, 255])

        let back = try Msg.unpack(m.pack())
        XCTAssertEqual(back.string("method"), "Volume.Set")
        XCTAssertEqual(back.uint64("percent"), 80)
        XCTAssertEqual(back.bool("mute"), false)
        XCTAssertEqual(back.bytes("blob"), [1, 2, 3, 0, 255])
    }

    func testMissingAndMistypedFieldsAreNil() {
        var m = Msg()
        m.set("n", UInt64(5))
        XCTAssertNil(m.uint64("nope"))
        XCTAssertNil(m.string("n"))          // present, wrong type
        XCTAssertTrue(m.has("n"))
        XCTAssertFalse(m.has("nope"))
    }

    func testPackingIsDeterministicAndSetReplacesInPlace() {
        var a = Msg()
        a.set("one", "1"); a.set("two", UInt64(2))
        var b = Msg()
        b.set("one", "1"); b.set("two", UInt64(2))
        XCTAssertEqual(a.pack(), b.pack(), "same fields in the same order must pack identically")

        // Replacing a value keeps the field's position, so the bytes stay stable.
        var c = Msg()
        c.set("one", "x"); c.set("two", UInt64(2)); c.set("one", "1")
        XCTAssertEqual(c.pack(), a.pack())
        XCTAssertEqual(c.fields.count, 2)
    }

    func testUnicodeAndEmptyValuesSurvive() throws {
        var m = Msg()
        m.set("emoji", "Aqua 💧 10.2")
        m.set("empty", "")
        m.set("nobytes", bytes: [])
        m.set("big", UInt64.max)
        let back = try Msg.unpack(m.pack())
        XCTAssertEqual(back.string("emoji"), "Aqua 💧 10.2")
        XCTAssertEqual(back.string("empty"), "")
        XCTAssertEqual(back.bytes("nobytes"), [])
        XCTAssertEqual(back.uint64("big"), UInt64.max)
    }

    // A hostile or buggy peer must get an error, never a crash or a hang. The
    // reader is bounds-checked on every read for exactly this.
    func testMalformedFramesAreRejectedNotCrashed() {
        XCTAssertThrowsError(try Msg.unpack([]))                       // empty
        XCTAssertThrowsError(try Msg.unpack(Array("NOPE".utf8) + [1]))  // bad magic
        XCTAssertThrowsError(try Msg.unpack(Array("ABYM".utf8) + [99])) // bad version

        var m = Msg()
        m.set("s", "hello")
        let good = m.pack()
        for cut in 1..<good.count {
            // Every truncation must throw rather than read off the end.
            XCTAssertThrowsError(try Msg.unpack(Array(good[0..<cut])),
                                 "truncation at \(cut) should be rejected")
        }

        // A length that claims more string than the buffer holds.
        var lying = Array("ABYM".utf8) + [1, 0, 1]        // version 1, 1 field
        lying += [0, 1, UInt8(ascii: "s")]                 // name "s"
        lying += [1, 0xff, 0xff, 0xff, 0xff]               // .string, length 4G
        XCTAssertThrowsError(try Msg.unpack(lying))
    }

    func testAnFDFieldWithNoDescriptorIsMalformed() {
        var m = Msg()
        m.set("buffer", fd: 1)
        // Packed with an index, but unpacked with no descriptors supplied.
        XCTAssertThrowsError(try Msg.unpack(m.pack(), fds: [])) { error in
            guard case CurrentError.malformed = error else {
                return XCTFail("expected .malformed, got \(error)")
            }
        }
    }

    // MARK: - Descriptor passing (the point of the whole component)

    /// A pair of connected sockets, the cheapest honest test of SCM_RIGHTS:
    /// the descriptor that comes out the far end is a *different* number
    /// pointing at the same open file.
    func testSCMRightsCarriesARealDescriptor() throws {
        var sv: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, sockStreamForTests, 0, &sv), 0)
        defer { close(sv[0]); close(sv[1]) }

        let (fd, contents) = try makeTempFileWithContents("aqua-fd-pass")
        defer { close(fd) }

        var out = Msg()
        out.set("method", "Buffer.Hand")
        out.set("buffer", fd: fd)
        out.set("bytes", UInt64(contents.count))
        try Current.send(out, on: sv[0])

        var got = try Current.receive(on: sv[1])
        XCTAssertEqual(got.string("method"), "Buffer.Hand")
        guard let received = got.takeFD("buffer") else {
            return XCTFail("no descriptor arrived")
        }
        defer { close(received) }
        XCTAssertNotEqual(received, fd, "a passed fd arrives as a new descriptor number")

        // The real proof: read the sender's file through the receiver's fd.
        XCTAssertEqual(try readWholeFile(received), contents)
        // takeFD removed the field, so nothing is left to leak.
        XCTAssertNil(got.fd("buffer"))
    }

    func testSeveralDescriptorsKeepTheirFieldsStraight() throws {
        var sv: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, sockStreamForTests, 0, &sv), 0)
        defer { close(sv[0]); close(sv[1]) }

        let (fdA, textA) = try makeTempFileWithContents("aqua-fd-a")
        let (fdB, textB) = try makeTempFileWithContents("aqua-fd-b")
        defer { close(fdA); close(fdB) }

        var out = Msg()
        out.set("first", fd: fdA)
        out.set("label", "between")     // a non-fd field in the middle
        out.set("second", fd: fdB)
        try Current.send(out, on: sv[0])

        var got = try Current.receive(on: sv[1])
        XCTAssertEqual(got.string("label"), "between")
        guard let a = got.takeFD("first"), let b = got.takeFD("second") else {
            return XCTFail("expected two descriptors")
        }
        defer { close(a); close(b) }
        // Indices must map back to the right *fields*, not just arrive.
        XCTAssertEqual(try readWholeFile(a), textA)
        XCTAssertEqual(try readWholeFile(b), textB)
    }

    func testCloseFDsDropsWhatTheHandlerDidntWant() throws {
        var sv: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, sockStreamForTests, 0, &sv), 0)
        defer { close(sv[0]); close(sv[1]) }

        let (fd, _) = try makeTempFileWithContents("aqua-fd-drop")
        defer { close(fd) }
        var out = Msg()
        out.set("buffer", fd: fd)
        try Current.send(out, on: sv[0])

        var got = try Current.receive(on: sv[1])
        let received = got.fd("buffer")
        XCTAssertNotNil(received)
        got.closeFDs()
        XCTAssertNil(got.fd("buffer"), "closeFDs removes the fields too")
        // The descriptor really is closed: fcntl on it now fails.
        XCTAssertEqual(fcntl(received!, F_GETFD), -1)
    }

    /// Writing to a peer that has gone away must be an *error*, never a signal.
    ///
    /// Without MSG_NOSIGNAL this raises SIGPIPE and the process dies silently
    /// with status 141 — which is exactly how `abyssctl quit` failed about one
    /// run in three on FreeBSD, looking for all the world like a supervisor
    /// that ignored the request (HANDOFF §2.33). If this test ever hangs or
    /// crashes the whole suite rather than failing, that protection is gone.
    func testWritingToAClosedPeerErrorsRatherThanKillingUs() throws {
        var sv: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, sockStreamForTests, 0, &sv), 0)
        defer { close(sv[0]) }
        close(sv[1])                        // the peer hangs up

        var m = Msg()
        m.set("method", "into-the-void")
        // A payload big enough that the write can't just vanish into a buffer.
        m.set("filler", bytes: [UInt8](repeating: 0x7f, count: 64 * 1024))
        XCTAssertThrowsError(try Current.send(m, on: sv[0])) { error in
            switch error {
            case CurrentError.closed, CurrentError.system:
                break                       // either is a fine way to say "gone"
            default:
                XCTFail("expected a closed/system error, got \(error)")
            }
        }
    }

    // MARK: - A real service on a real socket

    func testServerAndClientOverARealSocket() throws {
        let dir = try scratchRuntimeDir()
        defer { unsetenv("ABYSS_RUNTIME_DIR"); _ = rmdirTree(dir) }

        let server = try Current.Server(service: "volume")
        XCTAssertTrue(server.path.hasSuffix("/volume.sock"))

        // No thread: connect first and the connection waits in the listen
        // backlog, so client and service take turns in one thread. That is also
        // how a shell component will host a service — fold `server.fd` into the
        // run loop (Display.addFileDescriptor) and accept when it fires.
        let client = try Current.connect("volume")
        defer { close(client) }

        var req = Msg()
        req.set("method", "Volume.Set")
        req.set("percent", UInt64(41))
        try Current.send(req, on: client)

        XCTAssertTrue(try server.serveOne { request in
            var reply = Msg()
            reply.set("ok", true)
            reply.set("echo", request.string("method") ?? "")
            reply.set("percent", (request.uint64("percent") ?? 0) + 1)
            return reply
        })

        let reply = try Current.receive(on: client)
        XCTAssertEqual(reply.bool("ok"), true)
        XCTAssertEqual(reply.string("echo"), "Volume.Set")
        XCTAssertEqual(reply.uint64("percent"), 42)
    }

    /// A service must survive rubbish: a client that connects, sends nonsense
    /// and hangs up costs that connection and nothing more.
    func testAGarbageRequestDoesNotKillTheService() throws {
        let dir = try scratchRuntimeDir()
        defer { unsetenv("ABYSS_RUNTIME_DIR"); _ = rmdirTree(dir) }
        let server = try Current.Server(service: "anchor")

        let bad = try Current.connect("anchor")
        let junk: [UInt8] = [0, 0, 0, 5, 0x6e, 0x6f, 0x70, 0x65, 0x21]  // len 5, "nope!"
        _ = junk.withUnsafeBufferPointer { write(bad, $0.baseAddress, junk.count) }
        close(bad)
        var handled = false
        XCTAssertFalse(try server.serveOne { _ in handled = true; return Msg() },
                       "a malformed request is dropped, not handled")
        XCTAssertFalse(handled)

        // ... and the next well-formed client is served normally.
        let good = try Current.connect("anchor")
        defer { close(good) }
        var req = Msg(); req.set("method", "status")
        try Current.send(req, on: good)
        XCTAssertTrue(try server.serveOne { request in
            var r = Msg(); r.set("echo", request.string("method") ?? ""); return r
        })
        XCTAssertEqual(try Current.receive(on: good).string("echo"), "status")
    }

    /// A connection accepted from a **non-blocking listener** must itself be
    /// blocking.
    ///
    /// The BSDs propagate O_NONBLOCK from the listener to the accepted socket;
    /// Linux does not. A service that polls its listener (which every service
    /// hosted inside an event loop does) therefore gets non-blocking
    /// connections on FreeBSD only — and then `recvmsg` returns EAGAIN whenever
    /// the request hasn't landed yet, and the service drops a good client. That
    /// failed roughly half of all `abyssctl quit` calls, and passed every time
    /// on Linux (HANDOFF §2.33).
    func testAcceptedConnectionsAreBlockingEvenFromANonBlockingListener() throws {
        let dir = try scratchRuntimeDir()
        defer { unsetenv("ABYSS_RUNTIME_DIR"); _ = rmdirTree(dir) }

        let server = try Current.Server(service: "anchor")
        try server.setNonBlocking(true)
        let client = try Current.connect("anchor")
        defer { close(client) }

        let accepted = try server.accept()
        defer { close(accepted) }
        let flags = fcntl(accepted, F_GETFL, 0)
        XCTAssertGreaterThanOrEqual(flags, 0)
        XCTAssertEqual(flags & O_NONBLOCK, 0,
                       "an accepted connection must be blocking, whatever the listener is")
    }

    func testBindReplacesAStaleSocketAndUnlinksOnClose() throws {
        let dir = try scratchRuntimeDir()
        defer { unsetenv("ABYSS_RUNTIME_DIR"); _ = rmdirTree(dir) }

        let path = try Current.socketPath("anchor")
        do {
            let first = try Current.Server(service: "anchor")
            XCTAssertEqual(access(first.path, F_OK), 0)
            first.shutdownAndUnlink()
            XCTAssertEqual(access(path, F_OK), -1, "the socket is removed on shutdown")
        }
        // A crash leaves the socket file behind; binding again must not fail
        // with EADDRINUSE — the supervisor restarting is the normal case.
        let stale = open(path, O_CREAT | O_WRONLY, 0o600)
        XCTAssertGreaterThanOrEqual(stale, 0)
        close(stale)
        let second = try Current.Server(service: "anchor")
        XCTAssertEqual(access(second.path, F_OK), 0)
        second.shutdownAndUnlink()
    }

    func testConnectingToAMissingServiceFails() throws {
        let dir = try scratchRuntimeDir()
        defer { unsetenv("ABYSS_RUNTIME_DIR"); _ = rmdirTree(dir) }
        XCTAssertThrowsError(try Current.connect("nobody-home")) { error in
            guard case CurrentError.system = error else {
                return XCTFail("expected .system, got \(error)")
            }
        }
    }

    func testRuntimeDirPrecedenceAndPermissions() throws {
        let dir = try scratchRuntimeDir()
        defer { unsetenv("ABYSS_RUNTIME_DIR"); _ = rmdirTree(dir) }
        // ABYSS_RUNTIME_DIR wins outright.
        XCTAssertEqual(try Current.runtimeDir(), dir)
        var st = stat()
        XCTAssertEqual(stat(dir, &st), 0)
        XCTAssertEqual(st.st_mode & 0o777, 0o700, "the runtime dir must be private")

        // Falling back to XDG_RUNTIME_DIR appends /abyss, as the sibling does,
        // so one session's sockets share a namespace.
        unsetenv("ABYSS_RUNTIME_DIR")
        setenv("XDG_RUNTIME_DIR", dir, 1)
        XCTAssertEqual(try Current.runtimeDir(), dir + "/abyss")
        _ = rmdirTree(dir + "/abyss")
        unsetenv("XDG_RUNTIME_DIR")
    }

    func testAFrameOverTheSizeCapIsRefused() throws {
        var m = Msg()
        m.set("blob", bytes: [UInt8](repeating: 0xAB, count: Msg.maxFrame))
        var sv: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, sockStreamForTests, 0, &sv), 0)
        defer { close(sv[0]); close(sv[1]) }
        XCTAssertThrowsError(try Current.send(m, on: sv[0])) { error in
            guard case CurrentError.tooLarge = error else {
                return XCTFail("expected .tooLarge, got \(error)")
            }
        }
    }

    // MARK: - Helpers

    /// Point the runtime dir at a fresh scratch directory, so a test never binds
    /// a socket in the developer's real session.
    private func scratchRuntimeDir() throws -> String {
        var template = Array("\(tmpDir())/abyss-ipc-XXXXXX".utf8CString)
        guard let dir = template.withUnsafeMutableBufferPointer({
            mkdtemp($0.baseAddress!).map { String(cString: $0) }
        }) else {
            throw CurrentError.system(errno, "mkdtemp")
        }
        setenv("ABYSS_RUNTIME_DIR", dir, 1)
        return dir
    }

    private func tmpDir() -> String {
        if let t = getenv("TMPDIR"), t.pointee != 0 {
            var s = String(cString: t)
            while s.count > 1 && s.hasSuffix("/") { s.removeLast() }
            return s
        }
        return "/tmp"
    }

    private func makeTempFileWithContents(_ tag: String) throws -> (Int32, [UInt8]) {
        var template = Array("\(tmpDir())/\(tag)-XXXXXX".utf8CString)
        let (fd, path): (Int32, String) = try template.withUnsafeMutableBufferPointer {
            let f = mkstemp($0.baseAddress!)
            guard f >= 0 else { throw CurrentError.system(errno, "mkstemp") }
            return (f, String(cString: $0.baseAddress!))
        }
        // Unlink now: the descriptor keeps the file alive, which is exactly how a
        // handed-over shm buffer behaves.
        unlink(path)
        let contents = Array("contents of \(tag) — \(getpid())".utf8)
        _ = contents.withUnsafeBufferPointer { write(fd, $0.baseAddress, contents.count) }
        XCTAssertEqual(lseek(fd, 0, SEEK_SET), 0)
        return (fd, contents)
    }

    private func readWholeFile(_ fd: Int32) throws -> [UInt8] {
        XCTAssertEqual(lseek(fd, 0, SEEK_SET), 0)
        var out: [UInt8] = []
        var buf = [UInt8](repeating: 0, count: 512)
        while true {
            let n = buf.withUnsafeMutableBufferPointer { read(fd, $0.baseAddress, 512) }
            if n <= 0 { break }
            out += buf[0..<n]
        }
        return out
    }

    private func rmdirTree(_ path: String) -> Bool {
        // The scratch dirs hold at most a socket or two; no recursion needed.
        if let d = opendir(path) {
            while let e = readdir(d) {
                let name = withUnsafeBytes(of: e.pointee.d_name) { raw -> String in
                    String(cString: raw.baseAddress!.assumingMemoryBound(to: CChar.self))
                }
                if name == "." || name == ".." { continue }
                unlink(path + "/" + name)
            }
            closedir(d)
        }
        return rmdir(path) == 0
    }
}

// SOCK_STREAM imports as a different type per platform (see Current.swift).
#if canImport(Glibc) && os(Linux)
private let sockStreamForTests = Int32(SOCK_STREAM.rawValue)
#else
private let sockStreamForTests = Int32(SOCK_STREAM)
#endif
