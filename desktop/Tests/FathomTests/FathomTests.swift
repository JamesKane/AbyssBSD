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

    // MARK: - The report

    func testTheSummaryNamesUnknownsInsteadOfLettingThemBlendIn() {
        // An incomplete report that looks complete is the failure this whole
        // status exists to prevent, so the count is called out in words rather
        // than left to be inferred from a column.
        let r = FathomReport([
            ProbeResult("GPU", .present, "card0"),
            ProbeResult("Wi-Fi", .absent, "none"),
            ProbeResult("Audio", .unknown, "could not read /dev/sndstat"),
        ])
        let text = renderText(r)
        XCTAssertTrue(text.contains("COULD NOT BE ASKED"), text)
        XCTAssertTrue(text.contains("1 present, 1 absent, 1 COULD NOT BE ASKED"), text)
    }

    func testACompleteReportDoesNotMentionUnknownsAtAll() {
        // The build VM's own shape: plenty absent, nothing unasked. Saying
        // "0 could not be asked" would train a reader to skip the line that
        // matters when it is not zero.
        let r = FathomReport([
            ProbeResult("GPU", .absent, "none"),
            ProbeResult("Network", .present, "igc0"),
        ])
        XCTAssertTrue(r.isComplete)
        XCTAssertFalse(renderText(r).contains("COULD NOT"), renderText(r))
    }

    func testAbsentAndUnknownDoNotLookAlike() {
        // Two characters apart in the output and a world apart in meaning.
        XCTAssertNotEqual(mark(.absent), mark(.unknown))
        XCTAssertNotEqual(mark(.present), mark(.absent))
        // ...and all the same width, so a column of them reads as a shape.
        XCTAssertEqual(Set(ProbeStatus.allCases.map { mark($0).count }).count, 1)
    }

    func testCompletenessIsNotSuitability() {
        // **A report can be complete and describe a machine that cannot show a
        // desktop.** Blurring the two is how a probe suite starts telling people
        // their hardware is fine (§6.4).
        let noGPU = FathomReport([
            ProbeResult("GPU", .absent, "no /dev/dri/card*"),
            ProbeResult("Network", .present, "igc0"),
        ])
        XCTAssertTrue(noGPU.isComplete, "nothing went unasked —")
        XCTAssertEqual(noGPU.counts.absent, 1, "— and the machine still has no GPU")
    }

    func testTheTextRenderingStaysPlainEnoughForABrokenMachine() {
        // The machine that most needs this report is the one that cannot draw
        // one, so: ASCII only, and no line longer than 80 columns for the
        // fixtures we control.
        let text = renderText(FathomReport([
            ProbeResult("GPU", .present, "card0 (+ renderD128)"),
            ProbeResult("Power", .unknown, "no way to ask this platform about power"),
        ]))
        for scalar in text.unicodeScalars where scalar != "\n" {
            XCTAssertTrue(scalar.isASCII, "non-ASCII \(scalar) would not render on a console")
        }
        for line in text.split(separator: "\n") {
            XCTAssertLessThanOrEqual(line.count, 80, "\(line)")
        }
    }

    func testAProbeDetailWrittenCarelesslyDegradesRatherThanCorrupts() {
        // The renderer enforces ASCII instead of trusting whoever writes the
        // next probe. This project's prose is full of em dashes and curly
        // quotes, and the first version of this file put four of them into
        // strings a console has to print.
        let r = FathomReport([ProbeResult("GPU", .absent, "no card \u{2014} \u{201C}none\u{201D}\u{2026}")])
        let text = renderText(r)
        XCTAssertTrue(text.contains("no card - \"none\"..."), text)
        for scalar in text.unicodeScalars where scalar != "\n" {
            XCTAssertTrue(scalar.isASCII, "\(scalar) survived the fold")
        }
    }

    func testDisksAreReportedAsHardwareAndNotAsSomewhereToInstall() {
        // The privacy line drawn on the way in (§6.2): a model and a size say
        // whether a desktop can run here; a pool name and a mount point say
        // whose machine it is, and this report gets e-mailed to strangers.
        let r = probeDisks([DiskFact(name: "nvd0", bytes: 1_000_204_886_016,
                                     model: "Samsung SSD 980")])
        XCTAssertEqual(r.status, .present)
        XCTAssertTrue(r.detail.contains("nvd0"), r.detail)
        XCTAssertTrue(r.detail.contains("Samsung SSD 980"), r.detail)
        XCTAssertEqual(probeDisks([]).status, .absent)
    }

    func testNoWayToAskAboutPowerIsNotTheSameAsNoBattery() {
        // Found by running the CLI on Linux, where every sysctl answers nil: the
        // report said "no battery — mains only" about a machine it had not
        // looked at. A platform that cannot be asked is `unknown`.
        XCTAssertEqual(probeBattery(life: nil, present: false, canAsk: false).status, .unknown)
        XCTAssertEqual(probeBattery(life: nil, present: false, canAsk: true).status, .absent)
    }

    // MARK: - The measurement

    /// `undertow run --backend auto --frames 300` on the RX 6750 XT, captured
    /// off the screen on 2026-09-05 — the first frame numbers this project has
    /// ever taken from real hardware.
    static let metalRun = """
    WAYLAND_DISPLAY=wayland-0
    usable=0,0,2560x1440
    surfaces-created=0
    layers=0 of 0
    wake-late-p99-us=715
    composite-p99-us=9
    margin-us=8000
    missed=45 of 300
    period-us=16666
    vblank-source=hardware
    backend=drm
    verdict ok
    """

    func testTheFrameContractIsReadOffUndertowsOwnOutput() {
        let r = probeFrameContract(runOutput: Self.metalRun)
        XCTAssertEqual(r.status, .present)
        XCTAssertTrue(r.detail.contains("45 of 300"), r.detail)
        XCTAssertTrue(r.detail.contains("150 per mille"), r.detail)
        XCTAssertTrue(r.detail.contains("composite p99 9us"), r.detail)
    }

    func testOnlyDRMWithAHardwareClockCountsAsAMeasurement() {
        // §2.48 has three cases, not two, and the third is the trap: a **nested**
        // compositor presents when its host does and passes real timestamps
        // through, so `vblank-source=hardware` is true there and the numbers mean
        // nothing. Found by running `fathom --measure` on the dev box, where
        // `--backend auto` gives a nested window and the first version of this
        // probe cheerfully labelled it "[hardware clock]".
        func detail(_ backend: String, _ clock: String) -> String {
            probeFrameContract(runOutput: "missed=45 of 300\nbackend=\(backend)\nvblank-source=\(clock)").detail
        }
        XCTAssertTrue(detail("drm", "hardware").contains("hardware clock, DRM"))
        XCTAssertTrue(detail("nested-wayland", "hardware").contains("NOT APPLICABLE"))
        XCTAssertTrue(detail("nested-x11", "hardware").contains("NOT APPLICABLE"))
        XCTAssertTrue(detail("headless", "nominal").contains("HEADLESS"))
        // DRM without a hardware clock is a real and different case again.
        XCTAssertTrue(detail("drm", "nominal").contains("provisional"))
    }

    func testAnUnstatedClockIsNotSilentlyAssumedToBeHardware() {
        // Output from a build that predates the label. Saying nothing would let
        // it read as a hardware measurement, which is the failure this guards.
        let old = "missed=0 of 300\ncomposite-p99-us=9"
        XCTAssertTrue(probeFrameContract(runOutput: old).detail.contains("unstated"))
        // A hardware clock with no backend named is still not a DRM result.
        let half = "missed=0 of 300\nvblank-source=hardware"
        XCTAssertTrue(probeFrameContract(runOutput: half).detail.contains("backend unstated"))
    }

    func testNoFramesIsAnAnswerAboutTheMachineNotAFailureToAsk() {
        // And it stops every rate below being a division by zero dressed up as
        // a result.
        let none = "missed=0 of 0\nvblank-source=hardware"
        XCTAssertEqual(probeFrameContract(runOutput: none).status, .absent)
    }

    func testTheProbeReportsNumbersAndRefusesAVerdict() {
        // §6.4: a pass/fail here would be calibrated on whatever machine was
        // convenient, and the first one is a 20-thread 5 GHz desktop. A terrible
        // result and a perfect one differ in their numbers and not in their
        // status — the reader draws the conclusion.
        let bad = "missed=299 of 300\nvblank-source=hardware"
        let good = "missed=0 of 300\nvblank-source=hardware"
        XCTAssertEqual(probeFrameContract(runOutput: bad).status,
                       probeFrameContract(runOutput: good).status)
        for word in ["ok", "fail", "pass", "good", "bad", "verdict"] {
            XCTAssertFalse(probeFrameContract(runOutput: bad).detail.lowercased().contains(word),
                           "the probe rendered a verdict: \(probeFrameContract(runOutput: bad).detail)")
        }
    }

    func testUnreadableOutputIsUnknown() {
        XCTAssertEqual(probeFrameContract(runOutput: nil).status, .unknown)
        XCTAssertEqual(probeFrameContract(runOutput: "").status, .unknown)
        XCTAssertEqual(probeFrameContract(runOutput: "nothing useful here").status, .unknown)
        XCTAssertEqual(probeFrameContract(runOutput: "missed=lots of frames").status, .unknown)
    }

    func testAMissedFrameReportSaysWhichTermAteIt() {
        // "58 of 300 missed while compositing in 12us" is a true sentence that
        // sends somebody back to the machine. The margin is four measured terms;
        // the largest is the answer.
        let out = """
        missed=58 of 300
        composite-p99-us=12
        period-us=16680
        margin-wake-us=300
        margin-cost-us=12
        margin-commit-us=7000
        margin-safety-us=400
        margin-pinned=yes
        backend=drm
        vblank-source=hardware
        """
        let d = probeFrameContract(runOutput: out).detail
        XCTAssertTrue(d.contains("display commit"), d)
        XCTAssertTrue(d.contains("PINNED"), d)
    }

    func testAPerfectRunSaysNothingAboutMargins() {
        // The diagnosis is for a machine with a problem. A clean result should
        // read as a clean result, not as a wall of terms nobody needs.
        let out = "missed=0 of 300\nmargin-commit-us=7000\nmargin-pinned=yes\nbackend=drm\nvblank-source=hardware"
        let d = probeFrameContract(runOutput: out).detail
        XCTAssertFalse(d.contains("dominated"), d)
        XCTAssertFalse(d.contains("PINNED"), d)
    }

    func testAPinnedMarginIsDistinguishedFromAMerelyLargeOne() {
        // A number at its ceiling and a number that happens to be big look
        // identical without the flag — and they are the difference between
        // "slow" and "the control loop has given up".
        let base = "missed=10 of 300\nmargin-commit-us=7000\nbackend=drm\nvblank-source=hardware"
        XCTAssertFalse(probeFrameContract(runOutput: base + "\nmargin-pinned=no").detail.contains("PINNED"))
        XCTAssertTrue(probeFrameContract(runOutput: base + "\nmargin-pinned=yes").detail.contains("PINNED"))
    }

    // MARK: - Getting the report off the machine

    func testTheFilenameIdentifiesTheMachineAndNotThePerson() {
        // §6.2 applies to the filename too — it is as public as the contents,
        // and it ends up on a stick that gets handed around.
        XCTAssertEqual(reportFilename(maker: "Apple Inc.", product: "MacPro6,1"),
                       "fathom-apple-inc-macpro6-1.txt")
        XCTAssertEqual(reportFilename(maker: "Micro-Star International Co., Ltd.",
                                      product: "MS-7D25"),
                       "fathom-micro-star-international-co-ltd-ms-7d25.txt")
    }

    func testTwoMachinesOnOneStickGetTwoFiles() {
        // The case the matrix is for. The same machine twice overwrites, which
        // is the case a person is for.
        let a = reportFilename(maker: "Apple Inc.", product: "MacPro6,1")
        let b = reportFilename(maker: "Apple Inc.", product: "MacBookPro11,3")
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(a, reportFilename(maker: "Apple Inc.", product: "MacPro6,1"))
    }

    func testTheFilenameIsSafeOnAFilesystemWeDoNotControl() {
        // It is written to FAT and read on whatever the person owns. Lowercase
        // ASCII, digits and hyphens; nothing that needs quoting or a codepage.
        for (mk, pr) in [("Wéird Ünïcode", "Ma/chine\\Name"),
                         ("   ", "  "),
                         ("A", String(repeating: "x", count: 200))] {
            let f = reportFilename(maker: mk, product: pr)
            XCTAssertTrue(f.hasPrefix("fathom-"), f)
            XCTAssertTrue(f.hasSuffix(".txt"), f)
            XCTAssertLessThanOrEqual(f.count, 64, f)
            for ch in f.dropLast(4).dropFirst(7) {
                XCTAssertTrue(ch.isASCII && (ch.isLowercase || ch.isNumber || ch == "-"),
                              "\(ch) in \(f)")
            }
        }
    }

    func testAMachineThatWillNotSayWhatItIsStillGetsAFile() {
        // A report from an unidentified machine is still a data point, and
        // refusing to name the file would lose it.
        XCTAssertEqual(reportFilename(maker: nil, product: nil), "fathom-unknown.txt")
        XCTAssertEqual(reportFilename(maker: "", product: ""), "fathom-unknown.txt")
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

    /// arm64 has no `machdep.bootmethod`, and boots only through UEFI: its
    /// absence there is the answer, not an unknown — on x86 it stays unknown.
    func testArm64BootsThroughUEFIWithoutTheX86Sysctl() {
        XCTAssertEqual(probeBootMethod(nil, arch: "aarch64").status, .present)
        XCTAssertTrue(probeBootMethod(nil, arch: "aarch64").detail.hasPrefix("UEFI"))
        XCTAssertEqual(probeBootMethod(nil, arch: "amd64").status, .unknown)
        XCTAssertEqual(probeBootMethod("BIOS", arch: "amd64").detail, "BIOS (legacy)")
    }

    /// The Q8B's Adreno is the msm driver's, and is named as such.
    func testTheAdrenosDriverIsAGraphicsModule() {
        let k = """
        Id Refs Address                Size Name
         1   80 0xffff000000000000  2b4e9a8 kernel
         7    1 0xffff0000ab000000   400000 msm.ko
         8    2 0xffff0000ac000000   100000 drm.ko
        """
        XCTAssertEqual(probeModules(kldstat: k).detail, "drm, msm loaded")
    }

    /// No `net.wlan.devices` and no `wlan` module: nothing wireless, which is
    /// "absent" (the Q8B); with `wlan` loaded and still no sysctl, unknown.
    func testNoWlanModuleMeansNoWireless() {
        XCTAssertEqual(probeWifi(wlanDevices: nil, wlanLoaded: false).status, .absent)
        XCTAssertEqual(probeWifi(wlanDevices: nil, wlanLoaded: true).status, .unknown)
        XCTAssertEqual(probeWifi(wlanDevices: nil).status, .unknown, "not asked: unknown, as before")
        XCTAssertEqual(probeWifi(wlanDevices: "iwm0", wlanLoaded: true).status, .present)
    }
}
