// Sound pane tests (PHASE14 P14.6c): the page in words, one layout for paint
// and hit, and the one change that goes through the helper.

import XCTest
@testable import Aqua
@testable import AquaDraw
import Settings
import SettingsWire
import Vents

final class SoundPaneTests: XCTestCase {

    func testThePageInOneLine() {
        XCTAssertEqual(SoundWords.statusLine(.sample),
                       "default pcm0; vol 60:60; pcm 75:75; rec 50:50 muted; playing 2211 firefox 100:100, 3104 mpv 45:45")
        XCTAssertEqual(SoundWords.statusLine(SoundPaneState()), "no devices")
        var quiet = SoundPaneState.sample
        quiet.devices = quiet.devices.map { .init(unit: $0.unit, name: $0.name, description: $0.description,
                                                  devnode: $0.devnode, playback: $0.playback, recording: $0.recording,
                                                  fromUser: $0.fromUser, channels: []) }
        XCTAssertTrue(SoundWords.statusLine(quiet).hasSuffix("; playing none"))
    }

    func testAPlayerAndAControlAreSaidAsAPersonReadsThem() {
        XCTAssertEqual(SoundWords.player(.init(name: "x", pid: 7, command: "mpv", left: 45, right: 45)), "mpv (pid 7) — 45%")
        XCTAssertEqual(SoundWords.player(.init(name: "x", pid: 7, command: "mpv", left: 80, right: 40)),
                       "mpv (pid 7) — 80% (80:40)", "an unbalanced level says both sides")
        XCTAssertEqual(SoundWords.label("vol"), "Output volume")
        XCTAssertEqual(SoundWords.label("ogain"), "ogain", "an unknown control keeps its name")
    }

    func testOneLayoutForPaintAndHit() {
        let body = Rect(0, 80, 760, 540)
        let l = soundLayout(body: body, .sample)
        XCTAssertEqual(l.outputs.map(\.value), ["0", "1"])
        XCTAssertEqual(l.levels.map(\.value), ["vol", "pcm", "rec"])
        func at(_ r: Rect) -> SoundHit? { soundHit(l, x: r.x + r.w / 2, y: r.y + r.h / 2) }
        XCTAssertEqual(at(l.outputs[1].hit), .output(1))
        XCTAssertEqual(at(l.mutes[2].hit), .mute("rec"))
        let track = l.levels[0].control
        XCTAssertEqual(soundHit(l, x: track.x, y: track.y + 5), .level("vol", 0))
        XCTAssertEqual(soundHit(l, x: track.x + track.w, y: track.y + 5), .level("vol", 100))
        XCTAssertEqual(soundHit(l, x: track.x + track.w / 4, y: track.y + 5), .level("vol", 25))
        XCTAssertEqual(soundLevel(track: track, x: track.x - 50), 0, "past the end is the end")
        XCTAssertLessThan(l.noteBaseline, body.y + body.h)
        let rects = l.outputs.map(\.hit) + l.levels.map(\.hit) + l.mutes.map(\.hit)
        for (i, a) in rects.enumerated() {
            for b in rects[(i + 1)...] {
                XCTAssertFalse(a.x < b.x + b.w && b.x < a.x + a.w && a.y < b.y + b.h && b.y < a.y + a.h, "\(a) overlaps \(b)")
            }
        }
        XCTAssertEqual(soundLayout(body: body, SoundPaneState()).outputs, [], "no devices, no controls")
    }

    func testChoosingAnOutputAsksTheHelperForExactlyThat() throws {
        let m = SettingsClient.soundRequest(defaultUnit: 1)
        XCTAssertEqual(m.string("method"), "apply")
        XCTAssertEqual(try SettingsWire.decodePlan(m).get(), .sound(SoundPlan(defaultUnit: 1)))
    }
}

/// The menu bar's volume item (P14.6d).
final class VolumeExtraTests: XCTestCase {
    func testTheSliderIsLoudAtTheTop() {
        let t = VolumeSliderMetrics.track
        XCTAssertEqual(VolumeSliderMetrics.level(y: t.y), 100)
        XCTAssertEqual(VolumeSliderMetrics.level(y: t.y + t.h), 0)
        XCTAssertEqual(VolumeSliderMetrics.level(y: t.y + t.h * 0.7), 30)
        XCTAssertEqual(VolumeSliderMetrics.level(y: -40), 100, "past the top is the top")
        XCTAssertLessThanOrEqual(t.y + t.h, VolumeSliderMetrics.height, "the track is inside the popup")
    }

    func testTheBarSaysMutedAndHidesWhatItCannotFeed() {
        var s = MenuBarStatus(volume: 40, batteryPercent: nil)
        XCTAssertEqual(MenuBar.describe(s), "volume 40%, no battery")
        s.muted = true
        XCTAssertEqual(MenuBar.describe(s), "volume 40% muted, no battery")
        XCTAssertEqual(MenuBar.describe(MenuBarStatus()), "no mixer, no battery")
        XCTAssertNil(menuBarStatusLayout(status: MenuBarStatus(), h: 22, rightEdge: 700).volume,
                     "no mixer, no speaker")
    }
}
