// Vents tests — the parsing and encoding, which are pure and run anywhere, plus
// the sysctl bridge where the platform actually has one.
//
// The devd fixtures are **real lines captured from the build VM** (triggered
// with `mdconfig -a -t malloc`), not invented ones — including the CAM error
// with quoted, space-bearing values that a naive whitespace split would mangle.

import XCTest
@testable import Vents

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

final class VentsTests: XCTestCase {

    // MARK: - devd event parsing

    func testAttachAndDetachCarryTheDeviceName() {
        let attach = Vents.Event("+ugen0.2 at port=2 ... on uhub0")
        XCTAssertEqual(attach.kind, .attach)
        XCTAssertEqual(attach.device, "ugen0.2")
        XCTAssertEqual(attach.summary, "attach ugen0.2")

        let detach = Vents.Event("-ugen0.2 at port=2 on uhub0")
        XCTAssertEqual(detach.kind, .detach)
        XCTAssertEqual(detach.device, "ugen0.2")
    }

    func testNotifyFieldsFromRealDevfsEvents() {
        // Captured from the VM when a malloc-backed md(4) disk was created.
        let e = Vents.Event("!system=DEVFS subsystem=CDEV type=CREATE cdev=md0")
        XCTAssertEqual(e.kind, .notify)
        XCTAssertEqual(e.value("system"), "DEVFS")
        XCTAssertEqual(e.value("subsystem"), "CDEV")
        XCTAssertEqual(e.value("type"), "CREATE")
        XCTAssertEqual(e.value("cdev"), "md0")
        XCTAssertNil(e.value("nope"))
        // An attach/detach question asked of a notify gets an honest nil.
        XCTAssertNil(e.device)
    }

    func testQuotedValuesWithSpacesSurvive() {
        // Also real: a CAM error, whose CDB value contains spaces inside quotes.
        // Splitting on whitespace alone chops this into nonsense and loses the
        // field entirely.
        let line = #"!system=CAM subsystem=periph type=error device=cd0 serial="QM00005" cam_status="0x4cc" scsi_status=2 scsi_sense="70 02 3a 00" CDB="00 00 00 00 00 00 ""#
        let e = Vents.Event(line)
        XCTAssertEqual(e.kind, .notify)
        XCTAssertEqual(e.value("device"), "cd0")
        XCTAssertEqual(e.value("serial"), "QM00005")
        XCTAssertEqual(e.value("scsi_sense"), "70 02 3a 00")
        XCTAssertEqual(e.value("CDB"), "00 00 00 00 00 00 ")
        XCTAssertEqual(e.value("scsi_status"), "2")
    }

    func testNomatchAndUnknownLines() {
        let nomatch = Vents.Event("? at bus=0 on pci0")
        XCTAssertEqual(nomatch.kind, .nomatch)
        let odd = Vents.Event("something devd never sends")
        XCTAssertEqual(odd.kind, .unknown)
        // An unknown line keeps its first character — it wasn't a type byte.
        XCTAssertEqual(odd.raw, "something devd never sends")
    }

    func testLineEndingsAndEmptyInput() {
        XCTAssertEqual(Vents.Event("+md0 at\r\n").device, "md0")
        XCTAssertEqual(Vents.Event("").kind, .unknown)
        XCTAssertEqual(Vents.Event("").raw, "")
        // A notify with no fields is fine, not a crash.
        XCTAssertEqual(Vents.Event("!").fields.count, 0)
    }

    // MARK: - Volume encoding (OSS packs stereo into one int)

    func testVolumeEncodingRoundTripsAndClamps() {
        let v = Vents.VolumeLevel(left: 42, right: 73)
        XCTAssertEqual(Vents.VolumeLevel(encoded: v.encoded), v)
        XCTAssertEqual(Vents.VolumeLevel(left: 10, right: 20).encoded, 10 | (20 << 8))
        // Out-of-range levels clamp rather than wrapping into the other channel,
        // which is what makes the byte packing dangerous.
        let loud = Vents.VolumeLevel(left: 200, right: 150)
        XCTAssertEqual(loud, Vents.VolumeLevel(left: 100, right: 100))
        XCTAssertEqual(Vents.VolumeLevel(66).mono, 66)
    }

    func testVolumeDecodeIgnoresHigherBits() {
        // The kernel may return more than the two channel bytes; only the low
        // two are the master level.
        let decoded = Vents.VolumeLevel(encoded: 0x00FF_3264)
        XCTAssertEqual(decoded.left, 100)     // 0x64 = 100
        XCTAssertEqual(decoded.right, 50)     // 0x32 = 50
    }

    // MARK: - Battery

    func testBatteryLabelIsHonestAboutNotKnowing() {
        XCTAssertEqual(Vents.Battery(percent: 84, minutesRemaining: 120,
                                     isCharging: false).label, "84%")
        // The kernel reports -1 while it doesn't yet know; we show a dash rather
        // than a confident 0%.
        XCTAssertEqual(Vents.Battery(percent: nil, minutesRemaining: nil,
                                     isCharging: true).label, "—")
    }

    // MARK: - sysctl (real, where the platform has it)

    func testSysctlReadsRealKernelValues() throws {
        guard Vents.Sysctl.isSupported else {
            // On Linux the bridge is a stub, and must say so rather than
            // pretending — that is what keeps the status items honest.
            XCTAssertNil(Vents.Sysctl.string("kern.ostype"))
            XCTAssertNil(Vents.Sysctl.int("hw.ncpu"))
            return
        }
        XCTAssertEqual(Vents.Sysctl.string("kern.ostype"), "FreeBSD")
        let ncpu = try XCTUnwrap(Vents.Sysctl.int("hw.ncpu"))
        XCTAssertGreaterThan(ncpu, 0)
        XCTAssertGreaterThan(try XCTUnwrap(Vents.Sysctl.int("hw.physmem")), 0)
        // A name that doesn't exist is nil, not a crash or a zero.
        XCTAssertNil(Vents.Sysctl.string("abyss.no.such.sysctl"))
    }

    /// A string sysctl must not be printed as an integer.
    ///
    /// `kern.ostype` is "FreeBSD\0" — *exactly eight bytes* — so a display path
    /// that checks "is it a number?" first renders it as 19231843050418758.
    /// That is precisely what the live test caught on the first run.
    func testDisplayPrefersTextOverAPlausibleInteger() throws {
        guard Vents.Sysctl.isSupported else {
            XCTAssertNil(Vents.Sysctl.display("kern.ostype"))
            return
        }
        XCTAssertEqual(Vents.Sysctl.display("kern.ostype"), "FreeBSD")
        // A genuine integer still displays as one.
        let ncpu = try XCTUnwrap(Vents.Sysctl.display("hw.ncpu"))
        XCTAssertNotNil(Int(ncpu))
        XCTAssertNil(Vents.Sysctl.display("abyss.no.such.sysctl"))
    }

    func testAbsentFacilitiesReturnNilRatherThanFakeReadings() {
        // Neither the dev box nor the build VM has a mixer; a machine that does
        // will simply exercise the other branch. Either way the contract is the
        // same: nil means "no such thing", never a made-up level.
        if let mixer = Vents.Mixer(path: "/nonexistent/mixer") {
            XCTFail("opened a mixer that doesn't exist: \(mixer)")
        }
        XCTAssertNil(Vents.Devd(path: "/nonexistent/devd.pipe"))
    }
}
