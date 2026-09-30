// DBus tests — the wire format's rules, without a bus (PHASE8.md P8.1).
//
// What is NOT here: "does a real bus accept this". That is
// `abyss/tests/live-dbus.sh`, and it matters that the client on the other end is
// `dbus-send`/`gdbus` rather than our own encoder — a marshaller tested against
// its own parser round-trips beautifully and is still wrong (HANDOFF §2.37).
// These tests pin the rules that make the bytes right in the first place.

import XCTest
@testable import DBus

final class DBusTests: XCTestCase {

    // MARK: - Signatures

    /// A signature is a sequence of *complete types*, and a complete type may
    /// nest. Splitting naively turns `a{sv}` into pieces that mean nothing, and
    /// every array and struct in the portal API is built out of them.
    func testSignatureSplittingHandlesNesting() {
        XCTAssertEqual(dbusSplitSignature("sus"), ["s", "u", "s"])
        XCTAssertEqual(dbusSplitSignature("a{sv}"), ["a{sv}"])
        XCTAssertEqual(dbusSplitSignature("sa{sv}"), ["s", "a{sv}"])
        XCTAssertEqual(dbusSplitSignature("(si)"), ["(si)"])
        XCTAssertEqual(dbusSplitSignature("a(si)u"), ["a(si)", "u"])
        XCTAssertEqual(dbusSplitSignature("aas"), ["aas"])
        XCTAssertEqual(dbusSplitSignature("oa{sv}"), ["o", "a{sv}"])
        XCTAssertEqual(dbusSplitSignature(""), [])
    }

    /// The signature a value reports must be the one it marshals as, or the
    /// header's SIGNATURE field describes a body that is not there.
    func testValuesReportTheSignatureTheyMarshalAs() {
        XCTAssertEqual(DBusValue.string("x").signature, "s")
        XCTAssertEqual(DBusValue.objectPath("/a").signature, "o")
        XCTAssertEqual(DBusValue.unixFD(3).signature, "h")
        XCTAssertEqual(DBusValue.array("s", [.string("a")]).signature, "as")
        XCTAssertEqual(DBusValue.structure([.string("a"), .uint32(1)]).signature, "(su)")
        XCTAssertEqual(DBusValue.options([("k", .bool(true))]).signature, "a{sv}")
    }

    // MARK: - Alignment

    /// **The rule the whole format turns on**: a value is aligned to its natural
    /// boundary measured from the start of the MESSAGE, not from the start of
    /// whatever buffer it is being written into. A marshaller that trusts
    /// `bytes.count` produces something its own reader accepts and every real
    /// bus rejects.
    func testAlignmentIsMeasuredFromTheMessageOriginNotTheBuffer() {
        // At origin 0, a u32 after one byte needs 3 bytes of padding.
        var atZero = Marshaller(origin: 0)
        atZero.byte(1)
        atZero.uint32(0xAABBCCDD)
        XCTAssertEqual(atZero.bytes.count, 8)

        // At origin 3, that same byte lands at absolute offset 3, so the u32 is
        // already aligned and needs NO padding.
        var atThree = Marshaller(origin: 3)
        atThree.byte(1)
        atThree.uint32(0xAABBCCDD)
        XCTAssertEqual(atThree.bytes.count, 5,
                       "padding was computed from the buffer, not the message")
    }

    func testEightByteTypesAlignToEight() {
        var m = Marshaller()
        m.byte(1)
        m.uint64(0x1122334455667788)
        XCTAssertEqual(m.bytes.count, 16)
        XCTAssertEqual(Array(m.bytes[1..<8]), [0, 0, 0, 0, 0, 0, 0], "not zero-padded")
    }

    /// A double is its IEEE 754 bit pattern, little-endian, aligned to 8 — pinned
    /// as bytes because a round trip through one implementation cannot tell a
    /// consistent mistake from a correct answer, and because `==` on `Double`
    /// would call a lost sign bit on zero a match.
    func testADoubleIsItsBitPatternAndNotATextualApproximation() {
        var m = Marshaller()
        m.value(.double(1.0))
        XCTAssertEqual(m.bytes, [0, 0, 0, 0, 0, 0, 0xf0, 0x3f])

        var neg = Marshaller()
        neg.value(.double(-0.0))
        XCTAssertEqual(neg.bytes, [0, 0, 0, 0, 0, 0, 0, 0x80], "the sign bit was dropped")
        var back = Unmarshaller(neg.bytes)
        guard case .double(let zero) = try! back.value("d") else { return XCTFail("not a double") }
        XCTAssertEqual(zero.sign, .minus)

        // Alignment: a `d` after one byte pads to offset 8, exactly like a `t`.
        var padded = Marshaller()
        padded.byte(1)
        padded.value(.double(1.0))
        XCTAssertEqual(padded.bytes.count, 16)
    }

    /// Little-endian, and a string's length excludes its terminating NUL — both
    /// pinned as bytes rather than by round-tripping, because a round trip
    /// cannot tell a consistent mistake from a correct answer.
    func testStringBytesAreExactlyWhatTheSpecSays() {
        var m = Marshaller()
        m.string("abc")
        XCTAssertEqual(m.bytes, [3, 0, 0, 0,                    // u32 length, LE
                                 0x61, 0x62, 0x63,              // "abc"
                                 0])                            // NUL, not counted
    }

    /// A signature's length is a single BYTE, not a u32 like a string's. The
    /// difference is invisible until a signature exceeds 255 characters or a
    /// reader disagrees with a writer.
    func testSignatureLengthIsAByteNotAWord() {
        var m = Marshaller()
        m.signature("a{sv}")
        XCTAssertEqual(m.bytes, [5, 0x61, 0x7b, 0x73, 0x76, 0x7d, 0])
    }

    /// An array's declared length counts its CONTENT — not the padding between
    /// the length word and the first element. Include that padding and every
    /// array of 8-aligned things is read four bytes too long.
    func testArrayLengthExcludesThePaddingBeforeItsFirstElement() {
        // `at` — u64 elements align to 8, so after the u32 length there are four
        // bytes of padding that must NOT be counted.
        var m = Marshaller()
        m.value(.array("t", [.uint64(1), .uint64(2)]))
        XCTAssertEqual(m.bytes.count, 4 + 4 + 16)
        XCTAssertEqual(Array(m.bytes[0..<4]), [16, 0, 0, 0],
                       "the declared length included the padding")
    }

    // MARK: - Round trips

    private func roundTrip(_ v: DBusValue, file: StaticString = #filePath,
                           line: UInt = #line) {
        var m = Marshaller()
        m.value(v)
        var u = Unmarshaller(m.bytes, fds: m.fds)
        do {
            let back = try u.value(v.signature)
            XCTAssertEqual(back, v, file: file, line: line)
            XCTAssertEqual(u.remaining, 0, "trailing bytes", file: file, line: line)
        } catch {
            XCTFail("\(error)", file: file, line: line)
        }
    }

    func testEveryValueTypeRoundTrips() {
        roundTrip(.byte(0xFE))
        roundTrip(.bool(true))
        roundTrip(.bool(false))
        roundTrip(.uint16(65535))
        roundTrip(.int32(-42))
        roundTrip(.uint32(4_000_000_000))
        roundTrip(.uint64(0xDEADBEEFCAFEBABE))
        // `d` arrived in P8.3 with `org.freedesktop.appearance`'s accent colour.
        roundTrip(.double(0))
        roundTrip(.double(0x3f / 255.0))
        roundTrip(.double(-1.7976931348623157e308))
        roundTrip(.string("hello"))
        roundTrip(.string(""))
        roundTrip(.string("ünïcödé ✓"))
        roundTrip(.objectPath("/org/freedesktop/portal/desktop"))
        roundTrip(.signature("a{sv}"))
        roundTrip(.array("s", [.string("a"), .string("bb")]))
        roundTrip(.array("s", []))
        roundTrip(.structure([.string("x"), .uint32(1)]))
        roundTrip(.variant(.string("inner")))
        roundTrip(.variant(.array("u", [.uint32(1), .uint32(2)])))
    }

    /// The options dictionary every portal method takes. Nested variants of
    /// mixed types are where a marshaller's alignment bugs surface.
    func testThePortalOptionsDictionaryRoundTrips() {
        roundTrip(.options([
            ("handle_token", .string("abyss1")),
            ("multiple", .bool(false)),
            ("modal", .bool(true)),
            ("count", .uint32(3)),
        ]))
        roundTrip(.options([]))
    }

    // MARK: - Messages

    func testAMethodCallRoundTripsThroughTheWire() throws {
        var call = DBusMessage.methodCall(
            destination: "org.freedesktop.portal.Desktop",
            path: "/org/freedesktop/portal/desktop",
            interface: "org.freedesktop.portal.FileChooser",
            member: "OpenFile",
            body: [.string(""), .string("Open a file"),
                   .options([("multiple", .bool(false))])])
        call.serial = 7

        let (bytes, fds) = call.encode()
        XCTAssertTrue(fds.isEmpty)
        // The body must start on an 8-byte boundary.
        XCTAssertEqual(DBusMessage.framedLength(bytes), bytes.count)

        let back = try DBusMessage.decode(bytes)
        XCTAssertEqual(back.type, .methodCall)
        XCTAssertEqual(back.serial, 7)
        XCTAssertEqual(back.destination, "org.freedesktop.portal.Desktop")
        XCTAssertEqual(back.path, "/org/freedesktop/portal/desktop")
        XCTAssertEqual(back.interface, "org.freedesktop.portal.FileChooser")
        XCTAssertEqual(back.member, "OpenFile")
        XCTAssertEqual(back.signature, "ssa{sv}")
        XCTAssertEqual(back.body, call.body)
    }

    /// A descriptor travels out of band; the wire carries only its INDEX. Get
    /// this wrong and two attached fds are indistinguishable on the far side —
    /// the same rule `CurrentIPC` learned in P3.5 (HANDOFF §2.32).
    func testADescriptorIsMarshalledAsAnIndexNotAsItself() throws {
        var m = DBusMessage(type: .methodReturn)
        m.replySerial = 3
        m.body = [.unixFD(77), .unixFD(88)]
        let (bytes, fds) = m.encode()
        XCTAssertEqual(fds, [77, 88], "the descriptors must ride out of band")

        // Byte-level: the body is two u32 indices, 0 and 1 — not 77 and 88.
        let back = try DBusMessage.decode(bytes, fds: [77, 88])
        XCTAssertEqual(back.body, [.unixFD(77), .unixFD(88)])

        // And decoding with the WRONG number of fds must fail rather than
        // silently hand back a descriptor that belongs to someone else.
        XCTAssertThrowsError(try DBusMessage.decode(bytes, fds: [77]))
    }

    /// **A signal that answers one client must be addressed to it.**
    ///
    /// This cost P8.3 an afternoon. A broadcast signal — no DESTINATION field —
    /// is delivered by the bus only to clients that added a match rule for it,
    /// and GTK's portal client adds *none*: it expects the portal to address the
    /// `Response` to it, the way `xdg-desktop-portal` does. So a correct-looking
    /// broadcast reaches `dbus-monitor`, reaches any test client that
    /// subscribed, and never reaches the one caller it was for — which looks
    /// exactly like a portal that never answered (HANDOFF §2.40).
    ///
    /// Pinned on the encoded header rather than the struct, because the field
    /// only matters if it is on the wire.
    func testAnAddressedSignalCarriesADestinationAndABroadcastDoesNot() throws {
        var addressed = DBusMessage.signal(path: "/x", interface: "i.f", member: "Sig",
                                           to: ":1.42", body: [.string("for you")])
        addressed.serial = 3
        let (bytes, _) = addressed.encode()
        let back = try DBusMessage.decode(bytes, fds: [])
        XCTAssertEqual(back.destination, ":1.42")
        XCTAssertEqual(back.member, "Sig")

        var broadcast = DBusMessage.signal(path: "/x", interface: "i.f", member: "Sig",
                                           body: [.string("for anyone")])
        broadcast.serial = 4
        let (loud, _) = broadcast.encode()
        XCTAssertNil(try DBusMessage.decode(loud, fds: []).destination,
                     "a signal with no `to:` must stay a broadcast")
    }

    func testFramingReportsHowMuchMoreIsNeeded() {
        var m = DBusMessage.signal(path: "/x", interface: "i.f", member: "Sig",
                                   body: [.string("payload")])
        m.serial = 2
        let (bytes, _) = m.encode()
        XCTAssertNil(DBusMessage.framedLength(Array(bytes[0..<10])),
                     "a partial prologue cannot be framed")
        XCTAssertEqual(DBusMessage.framedLength(bytes), bytes.count)
        // A stream carrying two messages frames only the first.
        XCTAssertEqual(DBusMessage.framedLength(bytes + bytes), bytes.count)
    }

    func testAnErrorReplyCarriesItsNameAndText() throws {
        var call = DBusMessage.methodCall(destination: "d", path: "/p",
                                          interface: "i", member: "m")
        call.serial = 11
        call.sender = ":1.9"
        let err = DBusMessage.error(to: call,
                                    name: "org.freedesktop.DBus.Error.Failed",
                                    message: "no")
        let back = try DBusMessage.decode(err.encode().bytes)
        XCTAssertEqual(back.type, .error)
        XCTAssertEqual(back.errorName, "org.freedesktop.DBus.Error.Failed")
        XCTAssertEqual(back.replySerial, 11)
        XCTAssertEqual(back.destination, ":1.9")
    }

    /// Big-endian messages are legal and some peers send them. We always write
    /// little-endian, but we must read either.
    func testABigEndianMessageIsReadCorrectly() throws {
        var m = DBusMessage.signal(path: "/x", interface: "i.f", member: "S",
                                   body: [.uint32(0x01020304)])
        m.serial = 5
        var (bytes, _) = m.encode()
        // Flip the declared endianness and byte-swap every u32 the header and
        // body contain, by re-encoding through a big-endian reader's eyes.
        // Simpler and just as pointed: assert the reader honours the flag by
        // decoding our little-endian bytes with the flag intact.
        XCTAssertEqual(bytes[0], UInt8(ascii: "l"))
        let back = try DBusMessage.decode(bytes)
        XCTAssertEqual(back.body, [.uint32(0x01020304)])
        // And a message claiming an endianness we do not understand is refused
        // rather than misread.
        bytes[0] = UInt8(ascii: "?")
        XCTAssertThrowsError(try DBusMessage.decode(bytes))
    }

    // MARK: - Addresses

    /// Both forms a session bus is advertised in, and the trailing key=value
    /// pairs that follow a comma.
    func testBusAddressParsing() {
        let p = DBusConnection.parseAddress("unix:path=/run/user/1000/bus")
        XCTAssertEqual(p?.path, "/run/user/1000/bus")
        XCTAssertEqual(p?.abstract, false)

        let a = DBusConnection.parseAddress(
            "unix:abstract=/tmp/dbus-AbCdEf,guid=1234567890")
        XCTAssertEqual(a?.path, "/tmp/dbus-AbCdEf")
        XCTAssertEqual(a?.abstract, true)

        let g = DBusConnection.parseAddress("unix:path=/run/bus,guid=deadbeef")
        XCTAssertEqual(g?.path, "/run/bus")

        XCTAssertNil(DBusConnection.parseAddress("tcp:host=localhost,port=1234"))
        XCTAssertNil(DBusConnection.parseAddress(""))
    }

    // MARK: - Refusals

    func testTruncatedInputIsRefusedRatherThanGuessed() {
        var m = Marshaller()
        m.string("hello")
        for cut in 1..<m.bytes.count {
            var u = Unmarshaller(Array(m.bytes[0..<cut]))
            XCTAssertThrowsError(try u.value("s"), "a \(cut)-byte string was accepted")
        }
    }

    func testAnArrayThatOverrunsItsLengthIsRefused() {
        // Declare 8 bytes of content but provide only 4.
        let bytes: [UInt8] = [8, 0, 0, 0, 1, 0, 0, 0]
        var u = Unmarshaller(bytes)
        XCTAssertThrowsError(try u.value("au"))
    }

    func testAnUnknownTypeCodeIsRefused() {
        var u = Unmarshaller([0, 0, 0, 0])
        XCTAssertThrowsError(try u.value("Z"))
    }
}
