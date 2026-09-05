// Fathom tests — and the order of them is the point.
//
// **For every probe, the ABSENT case is written first.** A probe suite proves
// nothing by reporting "ok" on a machine that has the hardware; what it has to
// be shown to do is say *no*, and say it about a machine that really is missing
// the thing. The build VM supplies six such cases for free — no `/dev/dri`, an
// empty `net.wlan.devices`, an unknown battery oid, a `/dev/sndstat` that says
// so in a sentence — and every fixture below is **captured from it**, never
// invented (PHASE12 §4.1, HANDOFF §2.37).
//
// The third answer gets the same treatment: `unknown` is not `absent`, and the
// tests that pin that distinction are the ones protecting a report from
// rounding "could not tell" up to "fine".

import XCTest
@testable import Fathom

final class FathomTests: XCTestCase {

    // MARK: - Fixtures, captured from the FreeBSD build VM

    /// `cat /dev/sndstat` on a machine with no sound card. **Prose, not a
    /// missing file** — which is what makes the absent case exercise the parser.
    static let sndstatNone = """
    No devices installed.
    No devices installed from userspace.
    """

    /// `kldstat` in the build VM: a kernel, zfs, and nothing graphical.
    static let kldstatNoGraphics = """
    Id Refs Address                Size Name
     1   25 0xffffffff80200000  1f4dcd8 kernel
     2    1 0xffffffff8214e000   620f30 zfs.ko
     3    1 0xffffffff83018000     4250 ichsmb.ko
     4    1 0xffffffff8301d000     2178 smbus.ko
     5    1 0xffffffff83200000   340438 vmm.ko
     6    1 0xffffffff83020000     21dc nmdm.ko
    """

    /// The same with the drm stack bound, as the metal machine reports it.
    static let kldstatWithAmdgpu = kldstatNoGraphics + """

     7    1 0xffffffff83400000   b2f000 amdgpu.ko
     8    3 0xffffffff83100000    5a000 drm.ko
    """

    // MARK: - Absent: the answers the build VM gives, and the reason for the suite

    func testNoGPUIsAbsentAndSaysWhy() {
        let r = probeGPU(driEntries: [])
        XCTAssertEqual(r.status, .absent)
        XCTAssertTrue(r.detail.contains("card"), r.detail)
    }

    func testARenderNodeAloneIsNotADisplay() {
        // The distinction the first metal boot turned on: both nodes present and
        // still no picture (PHASE4 §5.3). A render node is not a display, and a
        // probe that counted it as one would have reported that machine fine.
        let r = probeGPU(driEntries: ["renderD128"])
        XCTAssertEqual(r.status, .absent)
        XCTAssertTrue(r.detail.contains("not a display"), r.detail)
    }

    func testNoWifiIsAbsentFromAnEmptyStringNotAMissingSysctl() {
        // `net.wlan.devices` exists and is empty on a machine with no wireless,
        // so this is a value the parser must read rather than a lookup that fails.
        let r = probeWifi(wlanDevices: "")
        XCTAssertEqual(r.status, .absent)
        XCTAssertEqual(probeWifi(wlanDevices: "   ").status, .absent)
    }

    func testNoAudioIsAbsentAndTheSentenceIsParsed() {
        let r = probeAudio(sndstat: Self.sndstatNone)
        XCTAssertEqual(r.status, .absent, r.detail)
    }

    func testNoGraphicsModulesIsAbsent() {
        let r = probeModules(kldstat: Self.kldstatNoGraphics)
        XCTAssertEqual(r.status, .absent, r.detail)
    }

    func testNoBatteryIsAbsentNotUnknown() {
        // A desktop has no battery. That is an answer about the machine, not a
        // failure to ask, and conflating them would make every desktop look
        // broken.
        let r = probeBattery(life: nil, present: false)
        XCTAssertEqual(r.status, .absent)
        XCTAssertTrue(r.detail.contains("mains"), r.detail)
    }

    func testOnlyLoopbackIsAbsent() {
        XCTAssertEqual(probeNetwork(interfaceList: "lo0").status, .absent)
    }

    // MARK: - Unknown is not absent, which is the whole of §6.1

    func testEveryProbeSeparatesCouldNotAskFromIsNotThere() {
        // Same probes, nothing to read. Each must say `unknown` — a suite that
        // reported `absent` here would tell a person their hardware is missing
        // when in fact the probe never ran.
        XCTAssertEqual(probeGPU(driEntries: nil).status, .unknown)
        XCTAssertEqual(probeWifi(wlanDevices: nil).status, .unknown)
        XCTAssertEqual(probeAudio(sndstat: nil).status, .unknown)
        XCTAssertEqual(probeModules(kldstat: nil).status, .unknown)
        XCTAssertEqual(probeNetwork(interfaceList: nil).status, .unknown)
        XCTAssertEqual(probeBootMethod(nil).status, .unknown)
        XCTAssertEqual(probeMachine(maker: nil, product: nil).status, .unknown)
        XCTAssertEqual(probeCPU(model: nil, cores: nil).status, .unknown)
        XCTAssertEqual(probeMemory(physBytes: nil).status, .unknown)
    }

    func testABatteryThatWillNotAnswerIsUnknownNotEmpty() {
        // Present but unreadable is the case that must not round to "0%".
        XCTAssertEqual(probeBattery(life: nil, present: true).status, .unknown)
        XCTAssertEqual(probeBattery(life: 250, present: true).status, .unknown)
    }

    func testHalfAnIdentityIsNotAnIdentity() {
        // `Apple Inc.` with no model does not identify a machine, and reporting
        // the half we have as though it were the answer is how a conditional
        // built on it goes wrong.
        XCTAssertEqual(probeMachine(maker: "Apple Inc.", product: "").status, .unknown)
        XCTAssertEqual(probeMachine(maker: "", product: "MacPro6,1").status, .unknown)
    }

    // MARK: - Present: the positive control

    func testTheProbesCanAlsoSayYes() {
        // Without this every test above would pass against a suite that answers
        // `absent` to everything (§2.37).
        XCTAssertEqual(probeGPU(driEntries: ["card0", "renderD128"]).status, .present)
        XCTAssertEqual(probeWifi(wlanDevices: "wlan0").status, .present)
        XCTAssertEqual(probeNetwork(interfaceList: "igc0 lo0").status, .present)
        XCTAssertEqual(probeModules(kldstat: Self.kldstatWithAmdgpu).status, .present)
        XCTAssertEqual(probeBattery(life: 87, present: true).status, .present)
    }

    func testTheGPUReportNamesTheCard() {
        let r = probeGPU(driEntries: ["card0", "renderD128"])
        XCTAssertTrue(r.detail.contains("card0"), r.detail)
        XCTAssertTrue(r.detail.contains("renderD128"), r.detail)
    }

    func testAudioNamesTheDevicesItFound() {
        let stat = """
        Installed devices:
        pcm0: <Realtek ALC1220 (Rear Analog)> (play/rec) default
        pcm1: <Realtek ALC1220 (Front Analog)> (play/rec)
        """
        let r = probeAudio(sndstat: stat)
        XCTAssertEqual(r.status, .present)
        XCTAssertEqual(r.detail, "pcm0, pcm1")
    }

    func testBothBootMethodsAreAnAnswerAndNeitherIsAFailure() {
        // The harness exercises both: the build VM boots BIOS, and the nested
        // bhyve run in live-medium.sh boots UEFI. A legacy boot is a machine
        // that started the other way, not a machine that is broken.
        XCTAssertEqual(probeBootMethod("UEFI").status, .present)
        XCTAssertEqual(probeBootMethod("BIOS").status, .present)
        XCTAssertTrue(probeBootMethod("BIOS").detail.contains("legacy"))
        XCTAssertEqual(probeBootMethod("something else").status, .unknown)
    }

    func testCPUAndMemoryRenderForAPerson() {
        let cpu = probeCPU(model: "AMD Ryzen 7 9700X 8-Core Processor   ", cores: 8)
        XCTAssertEqual(cpu.detail, "AMD Ryzen 7 9700X 8-Core Processor (8 cores)")
        XCTAssertEqual(probeMemory(physBytes: 17_135_251_456).detail, "15.9 GiB")
    }

    // MARK: - The tunable that has been unconditional

    func testOnlyAMacProAsksForPCIeHotplugToBeDisabled() {
        // `hw.pci.enable_pcie_hp="0"` is written to every machine we install
        // because nothing could ask what machine it was on (PHASE4 §5.2). This
        // is the rule that ends that, and it is pure so it can be tested without
        // the machine — which matters, because we no longer bring up on one.
        XCTAssertTrue(needsPCIeHotplugDisabled(maker: "Apple Inc.", product: "MacPro6,1"))
        XCTAssertTrue(needsPCIeHotplugDisabled(maker: "Apple Inc.", product: "MacPro5,1"))
    }

    func testEveryOtherMachineIsLeftAlone() {
        // The negative control, and the reason the rule exists: the retarget
        // machine and the build VM must not inherit somebody else's workaround.
        XCTAssertFalse(needsPCIeHotplugDisabled(maker: "Micro-Star International Co., Ltd.",
                                                product: "MS-7D25"))
        XCTAssertFalse(needsPCIeHotplugDisabled(maker: "QEMU",
                                                product: "Standard PC (Q35 + ICH9, 2009)"))
        XCTAssertFalse(needsPCIeHotplugDisabled(maker: nil, product: nil))
        // An Apple that is not a Mac Pro does not need it either.
        XCTAssertFalse(needsPCIeHotplugDisabled(maker: "Apple Inc.", product: "MacBookPro11,3"))
    }

    func testTheMakerAndTheModelBothHaveToMatch() {
        // **This test exists because breaking the rule did not fail the suite.**
        // Deleting the maker check left every assertion above green, since no
        // fixture paired a non-Apple maker with a Mac-shaped product — so the
        // conjunction was untested and the check was half decoration.
        //
        // The case is not hypothetical: a VM's smbios strings are settable, and
        // people do set them to Apple's models. Somebody else's PCIe workaround
        // should not follow a spoofed model string onto a machine that has ICH9
        // bridges and no fault to work around.
        XCTAssertFalse(needsPCIeHotplugDisabled(maker: "QEMU", product: "MacPro6,1"))
        XCTAssertFalse(needsPCIeHotplugDisabled(maker: nil, product: "MacPro6,1"))
    }
}
