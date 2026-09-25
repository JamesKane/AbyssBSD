import XCTest
import CCairo
import Dispatch
@testable import AquaDraw

/// PHASE11 P11.4: every Jaguar draw list is byte-identical to the Swift recipe
/// it replaced — in every state, at integer and fractional origins, at odd
/// sizes, at 1× and 2×. The golden gate sees the states the scenes happen to
/// show; this sees all of them.
final class DrawParityTests: XCTestCase {
    private var lists: DrawListFile!

    override func setUpWithError() throws {
        let here = String(#filePath[..<#filePath.lastIndex(of: "/")!])
        let text = try XCTUnwrap(ThemeLoader.readFile(here + "/../../themes/aqua/draw/aqua.dl"))
        lists = try DrawListFile(parsing: text).merging(DrawListFile(parsing:
            try XCTUnwrap(ThemeLoader.readFile(here + "/../../themes/aqua/draw/chrome.dl"))))
    }
    override func tearDown() { Text.renderScale = 1 }

    /// Paint `a` and `b` into fresh 2×-capable surfaces and compare every byte.
    private func same(_ what: String, w: Int32 = 200, h: Int32 = 80,
                      _ a: (OpaquePointer) -> Void, _ b: (OpaquePointer) -> Void,
                      file: StaticString = #filePath, line: UInt = #line) {
        for scale in [1, 2] {
            Text.renderScale = Int32(scale)
            func paint(_ f: (OpaquePointer) -> Void) -> [UInt8] {
                let s = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, w * Int32(scale), h * Int32(scale))!
                let cr = cairo_create(s)!
                cairo_scale(cr, Double(scale), Double(scale))
                // A background with some colour in it, so a stray alpha-0 op or
                // a missing composite shows rather than hiding on transparent.
                cairo_set_source_rgb(cr, 0.93, 0.91, 0.87); cairo_paint(cr)
                // The caller's context carries state a recipe may inherit.
                cairo_set_line_width(cr, 1)
                f(cr)
                cairo_surface_flush(s)
                let n = Int(cairo_image_surface_get_stride(s)) * Int(h) * scale
                let out = Array(UnsafeBufferPointer(start: cairo_image_surface_get_data(s)!, count: n))
                cairo_destroy(cr); cairo_surface_destroy(s)
                return out
            }
            let pa = paint(a), pb = paint(b)
            let differ = zip(pa, pb).filter { $0 != $1 }.count
            XCTAssertEqual(differ, 0, "\(what) at \(scale)×: \(differ) bytes differ", file: file, line: line)
        }
    }

    private func run(_ name: String, _ cr: OpaquePointer, _ r: Rect, _ st: DrawState = [],
                     label: String = "", placeholder: String = "",
                     p: [String: Double] = [:], c: [String: Color] = [:]) {
        guard let l = lists[name] else { return XCTFail("no list \(name)") }
        DrawListRunner.run(l, cr, DrawContext(rect: r, state: st, label: label, placeholder: placeholder,
                                              parameters: p, colors: c))
    }

    /// Integer, half and awkward origins; ordinary and odd sizes.
    private let rects = [Rect(10, 10, 90, 22), Rect(10.5, 7.5, 71, 21), Rect(13.25, 9.75, 120.5, 19.5),
                         Rect(4, 30, 17, 17)]

    func testButtons() {
        for r in rects {
            for pressed in [false, true] {
                for blue in [false, true] {
                    same("gelButton \(r) blue=\(blue) pressed=\(pressed)",
                         { JaguarRef.gelButton($0, r, label: "Save", blue: blue, pressed: pressed) },
                         { self.run(blue ? "button.default" : "button", $0, r, pressed ? .pressed : [], label: "Save") })
                }
            }
        }
    }

    func testFocusRingAndPill() {
        for r in rects {
            for radius in [3.0, r.h / 2] {
                same("focusRing \(r) \(radius)", { JaguarRef.focusRing($0, r, radius: radius) },
                     { self.run("focusring", $0, r, p: ["radius": radius]) })
            }
            same("pill \(r)", { JaguarRef.pill($0, r) }, { self.run("gadget.pill", $0, r) })
        }
    }

    func testPinstripe() {
        for r in rects + [Rect(0, 0, 200, 80)] {
            same("pinstripe \(r)", { JaguarRef.pinstripe($0, r, Theme.titleBarPinstripe) },
                 { self.run("pinstripe", $0, r, c: ["color": Theme.titleBarPinstripe]) })
        }
    }

    func testTrafficLights() {
        for (cx, cy, rad) in [(20.0, 11.0, 6.5), (40.5, 20.5, 7.0), (61.25, 30.75, 5.5)] {
            for (name, base) in [("close", Theme.close), ("minimize", Theme.minimize), ("zoom", Theme.zoom)] {
                for active in [true, false] {
                    same("trafficLight \(name) \(cx),\(cy) r\(rad) active=\(active)",
                         { JaguarRef.trafficLight($0, cx: cx, cy: cy, radius: rad, base: base, active: active) },
                         { self.run("gadget." + name, $0, Rect(cx - rad, cy - rad, rad * 2, rad * 2),
                                    active ? .active : [], p: ["r": rad]) })
                }
            }
        }
    }

    func testTextField() {
        for r in [Rect(10, 10, 160, 22), Rect(10.5, 20.5, 121, 21)] {
            for (text, ph) in [("hello", ""), ("", "Search"), ("", ""), ("a much longer string than fits here", "")] {
                for caret in [false, true] {
                    same("textField \(r) '\(text)' ph='\(ph)' caret=\(caret)",
                         { JaguarRef.textField($0, r, text: text, caret: caret, placeholder: ph) },
                         { self.run("textfield", $0, r, caret ? .focused : [], label: text, placeholder: ph) })
                }
            }
        }
    }

    func testCheckboxAndRadio() {
        for r in [Rect(10, 10, 14, 14), Rect(30.5, 10.5, 15, 15), Rect(50.25, 30.75, 13, 13)] {
            for on in [false, true] {
                same("checkbox \(r) \(on)", { JaguarRef.checkbox($0, r, checked: on) },
                     { self.run("checkbox", $0, r, on ? .selected : []) })
                let rad = r.w / 2, cx = r.x + rad, cy = r.y + rad
                same("radio \(r) \(on)", { JaguarRef.radioButton($0, cx: cx, cy: cy, radius: rad, selected: on) },
                     { self.run("radio", $0, Rect(cx - rad, cy - rad, rad * 2, rad * 2), on ? .selected : [], p: ["r": rad]) })
            }
        }
    }

    func testSlider() {
        for r in [Rect(10, 10, 160, 22), Rect(10.5, 30.5, 121, 21)] {
            for v in [0, 0.25, 0.5, 1, -1, 2] {
                let clamped = max(0, min(1, v)), tr = Draw.sliderThumbRadius
                same("slider \(r) \(v)", { JaguarRef.slider($0, r, value: v) },
                     { self.run("slider", $0, r, p: ["thumb": tr + clamped * (r.w - 2 * tr)]) })
            }
        }
    }

    func testPopUp() {
        for r in rects {
            same("popUpButton \(r)", { JaguarRef.popUpButton($0, r, label: "Kind") },
                 { self.run("popup", $0, r, label: "Kind") })
        }
    }

    func testProgress() {
        for r in [Rect(10, 10, 160, 14), Rect(10.5, 30.5, 121, 13)] {
            for v in [0, 0.001, 0.3, 1, 1.5] {
                let c = max(0, min(1, v))
                same("progressBar \(r) \(v)", { JaguarRef.progressBar($0, r, value: v) },
                     { self.run("progress", $0, r, p: ["fill": c > 0 ? max(r.h, c * r.w) : 0]) })
            }
        }
    }

    func testScrollParts() {
        for (r, vertical) in [(Rect(180, 5, 15, 70), true), (Rect(5, 60, 170, 15), false),
                              (Rect(180.5, 5.5, 15, 14), true), (Rect(20.25, 40.75, 30, 15), false)] {
            same("scrollTrack \(r)", { JaguarRef.scrollTrack($0, r, vertical: vertical) },
                 { self.run("scrolltrack", $0, r) })
            same("scrollThumb \(r)", { JaguarRef.scrollThumb($0, r, vertical: vertical) },
                 { self.run("scrollthumb", $0, r) })
        }
        for r in [Rect(10, 10, 15, 15), Rect(30.5, 10.5, 15, 13), Rect(60, 20, 13, 17)] {
            for (dir, name) in [(Arrow.up, "up"), (.down, "down"), (.left, "left"), (.right, "right")] {
                for enabled in [true, false] {
                    same("scrollArrow \(r) \(name) \(enabled)", { JaguarRef.scrollArrow($0, r, dir, enabled: enabled) },
                         { self.run("scrollarrow." + name, $0, r, enabled ? [] : .disabled) })
                }
            }
        }
    }

    func testSegmented() {
        for r in [Rect(10, 10, 180, 22), Rect(10.5, 40.5, 151, 21)] {
            for labels in [["One", "Two", "Three"], ["Icons", "List"], ["A"]] {
                for sel in [-1, 0, labels.count - 1] {
                    same("segmented \(r) \(labels) \(sel)",
                         { JaguarRef.segmentedControl($0, r, labels: labels, selected: sel) },
                         { cr in
                            let segs = Draw.segmentRects(r, count: labels.count)
                            let segW = r.w / Double(labels.count)
                            func seg(_ name: String, _ i: Int, _ st: DrawState = []) {
                                self.run(name, cr, r, st, label: labels[i], p: ["x": Double(i) * segW, "w": segs[i].w])
                            }
                            for i in segs.indices { seg("segmented.segment", i, i == sel ? .selected : []) }
                            self.run("segmented.gloss", cr, r)
                            for i in segs.indices.dropFirst() { seg("segmented.divider", i) }
                            self.run("segmented.frame", cr, r)
                            for i in segs.indices { seg("segmented.label", i, i == sel ? .selected : []) }
                         })
                }
            }
        }
    }

    func testTabsAndGroupBox() {
        for r in [Rect(10, 10, 180, 60), Rect(10.5, 10.5, 151, 51)] {
            same("tabPane \(r)", { JaguarRef.tabPane($0, r) }, { self.run("tabpane", $0, r) })
            same("groupBox \(r)", { JaguarRef.groupBox($0, r, title: "Network") },
                 { self.run("groupbox", $0, r, label: "Network") })
        }
        for r in [Rect(10, 10, 80, 22), Rect(20.5, 30.5, 71, 21)] {
            for sel in [false, true] {
                same("tab \(r) \(sel)", { JaguarRef.tab($0, r, label: "General", selected: sel) },
                     { self.run("tab", $0, r, sel ? .selected : [], label: "General") })
            }
        }
    }

    /// The bench (P11.4): a list against the Swift it replaced, per widget. It
    /// prints; the bound only catches an interpreter gone badly wrong (the
    /// release numbers are in PHASE11.md).
    func testAListCostsAboutWhatTheSwiftDid() {
        let s = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, 300, 100)!, cr = cairo_create(s)!
        defer { cairo_destroy(cr); cairo_surface_destroy(s) }
        func time(_ f: () -> Void) -> Double {
            for _ in 0..<20 { f() }
            let t0 = DispatchTime.now().uptimeNanoseconds
            for _ in 0..<500 { f() }
            return Double(DispatchTime.now().uptimeNanoseconds - t0) / 500_000
        }
        let r = Rect(10, 10, 90, 22), seg = Rect(10, 10, 180, 22)
        let cases: [(String, () -> Void, () -> Void)] = [
            ("button", { Draw.gelButton(cr, r, label: "Save", blue: true, pressed: false) },
                       { JaguarRef.gelButton(cr, r, label: "Save", blue: true, pressed: false) }),
            ("traffic", { Draw.paint("gadget.close", cr, Rect(13.5, 4.5, 13, 13), .active, parameters: ["r": 6.5]) },
                        { JaguarRef.trafficLight(cr, cx: 20, cy: 11, radius: 6.5, base: Theme.close, active: true) }),
            ("segmented", { Draw.segmentedControl(cr, seg, labels: ["One", "Two", "Three"], selected: 1) },
                          { JaguarRef.segmentedControl(cr, seg, labels: ["One", "Two", "Three"], selected: 1) }),
        ]
        for (n, list, swift) in cases {
            let a = time(list), b = time(swift)
            print(String(format: "parity bench: %@ list %.1f µs, swift %.1f µs", n, a, b))
            XCTAssertLessThan(a, b * 4 + 20, n)
        }
    }
}
