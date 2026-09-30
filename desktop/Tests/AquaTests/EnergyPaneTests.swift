// Energy Saver tests (PHASE14 P14.8): the sleep delays' rule and file, the
// sliders' stops, the page in words, one layout for paint and hit.

import XCTest
@testable import Aqua
@testable import AquaDraw
import PoolConfig
import Settings
import Vents

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

final class EnergyPaneTests: XCTestCase {

    func testTheDisplayNeverSleepsLaterThanTheComputer() {
        // The display slider pushed past the computer's: the computer follows.
        XCTAssertEqual(EnergyPrefs(displaySleepMinutes: 60, systemSleepMinutes: 30).consistent(changedDisplay: true),
                       EnergyPrefs(displaySleepMinutes: 60, systemSleepMinutes: 60))
        // The computer's slider pulled under the display's: the display follows.
        XCTAssertEqual(EnergyPrefs(displaySleepMinutes: 60, systemSleepMinutes: 30).consistent(changedDisplay: false),
                       EnergyPrefs(displaySleepMinutes: 30, systemSleepMinutes: 30))
        // A display that never sleeps means a computer that never does either.
        XCTAssertEqual(EnergyPrefs(displaySleepMinutes: 0, systemSleepMinutes: 30).consistent(changedDisplay: true),
                       EnergyPrefs(displaySleepMinutes: 0, systemSleepMinutes: 0))
        // A computer that never sleeps constrains nothing.
        XCTAssertEqual(EnergyPrefs(displaySleepMinutes: 180, systemSleepMinutes: 0).consistent(changedDisplay: true),
                       EnergyPrefs(displaySleepMinutes: 180, systemSleepMinutes: 0))
    }

    func testDelaysInWordsAndOnTheSlider() {
        XCTAssertEqual(EnergyPrefs.words(10), "10 min")
        XCTAssertEqual(EnergyPrefs.words(90), "1 hr 30 min")
        XCTAssertEqual(EnergyPrefs.words(120), "2 hr")
        XCTAssertEqual(EnergyPrefs.words(0), "Never")
        XCTAssertEqual(EnergySlider.minutes(at: 0), 1)
        XCTAssertEqual(EnergySlider.minutes(at: 1), 0, "the far end is Never")
        for m in EnergyPrefs.stops + [0] {
            XCTAssertEqual(EnergySlider.minutes(at: EnergySlider.position(m)), m, "a stop round-trips: \(m)")
        }
    }

    func testEnergyIniIsStoredAndLoaded() throws {
        var t = Array("/tmp/abyss-energy-XXXXXX".utf8CString)
        let dir = t.withUnsafeMutableBufferPointer { String(cString: mkdtemp($0.baseAddress!)) }
        XCTAssertEqual(EnergyPrefs.load(configDir: dir), EnergyPrefs(), "nothing written: the defaults")
        try EnergyPrefs(displaySleepMinutes: 5, systemSleepMinutes: 0).store(configDir: dir)
        XCTAssertEqual(EnergyPrefs.load(configDir: dir), EnergyPrefs(displaySleepMinutes: 5, systemSleepMinutes: 0))
    }

    func testThePageInWords() {
        XCTAssertEqual(EnergyWords.statusLine(.sample), "computer 30 display 10 powerd on ac hiadaptive battery adaptive battery 83")
        XCTAssertEqual(EnergyWords.battery(nil), "No battery")
        XCTAssertEqual(EnergyWords.battery(Vents.Battery(percent: 50, minutesRemaining: nil, isCharging: true)), "50%, charging")
        XCTAssertEqual(EnergyWords.sleepStates("S3 S4 S5"), "This machine can sleep (S3), hibernate (S4), power off (S5).")
        XCTAssertEqual(EnergyWords.sleepStates(nil), "This machine reports no sleep states.")
    }

    func testOneLayoutForPaintAndHit() {
        let l = energyLayout(body: Rect(0, 80, 760, 540))
        XCTAssertEqual(energyHit(l, x: l.computer.x, y: l.computer.y + 10), .sleep(display: false, minutes: 1))
        XCTAssertEqual(energyHit(l, x: l.display.x + l.display.w, y: l.display.y + 10), .sleep(display: true, minutes: 0))
        XCTAssertEqual(energyHit(l, x: l.powerd.hit.x + 5, y: l.powerd.hit.y + 5), .powerd)
        XCTAssertEqual(energyHit(l, x: l.battery[2].hit.x + 5, y: l.battery[2].hit.y + 5), .battery(.minimum))
        XCTAssertEqual(energyHit(l, x: l.ac[3].hit.x + 5, y: l.ac[3].hit.y + 5), .ac(.maximum))
        XCTAssertLessThan(l.noteBaseline, 620)
        XCTAssertTrue(l.profile.isEmpty)
    }

    /// With power profiles (P14.8b) the power mode replaces powerd's per-source
    /// modes — one layout still, and nothing to hit where the old rows were.
    func testWithProfilesThePowerModeReplacesThePerSourceModes() {
        let l = energyLayout(body: Rect(0, 80, 760, 540), profiles: true)
        XCTAssertTrue(l.ac.isEmpty && l.battery.isEmpty)
        XCTAssertEqual(l.profile.map(\.value), ["power-saver", "balanced", "performance"])
        XCTAssertEqual(energyHit(l, x: l.profile[2].hit.x + 5, y: l.profile[2].hit.y + 5), .profile(.performance))
        XCTAssertEqual(energyHit(l, x: l.powerd.hit.x + 5, y: l.powerd.hit.y + 5), .powerd)
        XCTAssertEqual(EnergyWords.profile(.powerSaver), "Power Saver")
        var s = EnergyPaneState.sample
        s.profile = .balanced
        XCTAssertTrue(EnergyWords.statusLine(s).contains(" profile balanced battery "))
    }
}
