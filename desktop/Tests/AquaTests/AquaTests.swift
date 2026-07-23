import XCTest
import CCairo
import Surface
import PoolConfig
@testable import Aqua

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

final class AquaTests: XCTestCase {
    func testColorHex() {
        let c = Color(hex: 0xFF8040)
        XCTAssertEqual(c.r, 1.0, accuracy: 0.001)
        XCTAssertEqual(c.g, 128.0 / 255.0, accuracy: 0.001)
        XCTAssertEqual(c.b, 64.0 / 255.0, accuracy: 0.001)
        XCTAssertEqual(c.a, 1.0, accuracy: 0.001)
    }

    func testColorWithAlpha() {
        let c = Color(hex: 0x000000).with(a: 0.5)
        XCTAssertEqual(c.a, 0.5, accuracy: 0.001)
    }

    func testRectContains() {
        let r = Rect(10, 10, 100, 50)
        XCTAssertTrue(r.contains(20, 20))
        XCTAssertTrue(r.contains(10, 10))     // edge inclusive
        XCTAssertTrue(r.contains(110, 60))    // far edge inclusive
        XCTAssertFalse(r.contains(5, 5))
        XCTAssertFalse(r.contains(200, 200))
    }

    // Text shaping is only meaningful when a real font is loaded. On a box with
    // no font these assertions are skipped (the toolkit uses toy-text there).
    func testShapeEmptyIsEmpty() {
        XCTAssertTrue(Text.shape("", px: 13).isEmpty)
    }

    func testShapeProducesGlyphs() throws {
        try XCTSkipUnless(Text.available, "no font on this host")
        let g = Text.shape("Displays", px: 13)
        XCTAssertEqual(g.count, 8, "one glyph per Latin letter")
        XCTAssertTrue(g.allSatisfy { $0.face == 0 }, "Latin covered by the primary face")
        XCTAssertTrue(g.allSatisfy { $0.x_advance > 0 }, "every glyph advances the pen")
        // A glyph INDEX, not the codepoint 'D' (0x44).
        XCTAssertNotEqual(g.first?.index, UInt(UInt8(ascii: "D")))
    }

    func testWidgetsLayoutIsSaneAndInBounds() {
        let w = 460.0, h = 360.0
        let L = widgetsLayout(w: w, h: h)

        XCTAssertEqual(L.checks.count, widgetCheckLabels.count)
        XCTAssertEqual(L.checkBoxes.count, widgetCheckLabels.count)
        XCTAssertEqual(L.radios.count, widgetRadioLabels.count)
        XCTAssertEqual(L.radioCenters.count, widgetRadioLabels.count)

        // Every interactive rect stays inside the window.
        func inBounds(_ r: Rect) -> Bool {
            r.x >= 0 && r.y >= 0 && r.x + r.w <= w && r.y + r.h <= h
        }
        for r in L.checks + L.checkBoxes + L.radios {
            XCTAssertTrue(inBounds(r))
        }
        for r in [L.sliderTrack, L.progress, L.popup, L.okButton, L.cancelButton] {
            XCTAssertTrue(inBounds(r))
            XCTAssertGreaterThan(r.w, 0)
        }

        // Checkbox boxes are the standard 14px squares, stacked top to bottom.
        for b in L.checkBoxes {
            XCTAssertEqual(b.w, 14, accuracy: 0.01)
            XCTAssertEqual(b.h, 14, accuracy: 0.01)
        }
        XCTAssertLessThan(L.checkBoxes[0].y, L.checkBoxes[1].y)
        XCTAssertLessThan(L.checkBoxes[1].y, L.checkBoxes[2].y)

        // Cancel sits to the left of OK, both pinned to the bottom band.
        XCTAssertLessThan(L.cancelButton.x + L.cancelButton.w, L.okButton.x + L.okButton.w)
        XCTAssertEqual(L.cancelButton.y, L.okButton.y, accuracy: 0.01)
        XCTAssertGreaterThan(L.okButton.y, h / 2)
    }

    func testWidgetFocusOrderCoversEveryControl() {
        let order = widgetFocusOrder
        // One stop per checkbox, then radio, slider, popup, cancel, ok.
        XCTAssertEqual(order.count, widgetCheckLabels.count + 5)
        for i in 0..<widgetCheckLabels.count {
            XCTAssertEqual(order[i], .check(i))
        }
        XCTAssertEqual(Array(order.suffix(5)),
                       [.radio, .slider, .popup, .cancel, .ok])
        // The default button is last so a fresh scene rings OK, and Tab from it
        // wraps forward to the first checkbox.
        XCTAssertEqual(order.last, .ok)
        XCTAssertEqual(order.first, .check(0))
    }

    func testBoldStyleShapesAndIsWider() throws {
        try XCTSkipUnless(Text.available, "no font on this host")
        let s = "Delete this item?"
        let reg = Text.shape(s, px: 15, style: .regular)
        let bold = Text.shape(s, px: 15, style: .bold)
        XCTAssertEqual(reg.count, bold.count, "same glyph count across weights")
        // When a real bold face is present, the run is wider than regular; if the
        // host lacks one, bold falls back to regular (equal), so don't fail there.
        if Text.styleAvailable(.bold) {
            XCTAssertGreaterThan(Text.width(bold), Text.width(reg),
                                 "bold is wider than regular")
        }
        // Shaping is deterministic (and cached): same input, same run.
        let again = Text.shape(s, px: 15, style: .bold)
        XCTAssertEqual(again.count, bold.count)
        XCTAssertEqual(Text.width(again), Text.width(bold), accuracy: 0.001)
    }

    func testWidthScalesAndMetricsPositive() throws {
        try XCTSkipUnless(Text.available, "no font on this host")
        let narrow = Text.width(Text.shape("ii", px: 13))
        let wide = Text.width(Text.shape("WW", px: 13))
        XCTAssertGreaterThan(wide, narrow, "W is wider than i")
        let m = Text.metrics(px: 13)
        XCTAssertGreaterThan(m.ascent, 0)
        XCTAssertGreaterThan(m.descent, 0)
    }

    func testSegmentRectsAndTabsLayout() {
        // segmentRects: equal widths, adjacent, covering the whole rect.
        let r = Rect(10, 20, 240, 22)
        let segs = Draw.segmentRects(r, count: 3)
        XCTAssertEqual(segs.count, 3)
        XCTAssertEqual(segs[0].x, r.x, accuracy: 0.01)
        XCTAssertEqual(segs[2].x + segs[2].w, r.x + r.w, accuracy: 0.01)
        for i in 1..<segs.count {
            XCTAssertEqual(segs[i].x, segs[i - 1].x + segs[i - 1].w, accuracy: 0.01)
            XCTAssertEqual(segs[i].w, segs[0].w, accuracy: 0.01)
        }
        XCTAssertEqual(Draw.segmentRects(r, count: 0).count, 0)

        // Scene layout: segments + pane stay in bounds.
        let w = 480.0, h = 380.0
        let L = tabsLayout(w: w, h: h)
        XCTAssertEqual(L.segments.count, tabsSegmentLabels.count)
        func inBounds(_ x: Rect) -> Bool {
            x.x >= 0 && x.y >= 0 && x.x + x.w <= w && x.y + x.h <= h
        }
        XCTAssertTrue(inBounds(L.pane))
        XCTAssertGreaterThan(L.pane.h, 0)
        for s in L.segments { XCTAssertTrue(inBounds(s)) }
    }

    func testSheetLayoutInBounds() {
        let w = 440.0, h = 320.0
        let (panel, cancel, ok) = sheetLayout(w: w, h: h)
        // The panel hangs from the title bar, centred, within the window.
        XCTAssertEqual(panel.y, Theme.titleBarHeight, accuracy: 0.01)
        XCTAssertEqual(panel.x + panel.w / 2, w / 2, accuracy: 0.5)
        XCTAssertLessThanOrEqual(panel.x + panel.w, w)
        // Buttons sit inside the panel, Cancel left of Delete.
        for b in [cancel, ok] {
            XCTAssertGreaterThanOrEqual(b.x, panel.x)
            XCTAssertLessThanOrEqual(b.x + b.w, panel.x + panel.w)
            XCTAssertLessThanOrEqual(b.y + b.h, panel.y + panel.h)
        }
        XCTAssertLessThan(cancel.x + cancel.w, ok.x + ok.w)
        // The base button clears the fully-extended panel.
        let base = sheetBaseButton(w: w, h: h)
        XCTAssertGreaterThan(base.y, panel.y + panel.h - 20)
    }

    func testScrollLayoutAndThumb() {
        let w = 360.0, h = 420.0
        let L = scrollLayout(w: w, h: h)
        let vp = L.list.h

        // The content overflows, so there's a real thumb with travel.
        XCTAssertGreaterThan(scrollMaxOffset(viewportH: vp), 0)
        // Paired arrows sit at the bottom, up above down, both in the bar.
        XCTAssertLessThan(L.upArrow.y, L.downArrow.y)
        XCTAssertEqual(L.upArrow.x, L.track.x, accuracy: 0.01)
        XCTAssertLessThanOrEqual(L.downArrow.y + L.downArrow.h, h)

        let maxOff = scrollMaxOffset(viewportH: vp)
        guard let top = scrollThumbRect(track: L.track, offset: 0, viewportH: vp),
              let bot = scrollThumbRect(track: L.track, offset: maxOff, viewportH: vp)
        else { return XCTFail("expected a thumb when content overflows") }

        // Thumb stays within the track and travels top→bottom with the offset.
        XCTAssertGreaterThanOrEqual(top.y, L.track.y - 0.01)
        XCTAssertLessThan(top.y, bot.y)
        XCTAssertLessThanOrEqual(bot.y + bot.h, L.track.y + L.track.h + 0.01)
        XCTAssertEqual(top.h, bot.h, accuracy: 0.01, "thumb length is offset-independent")

        // A viewport taller than the content yields no thumb.
        XCTAssertNil(scrollThumbRect(track: L.track,
                                     offset: 0, viewportH: scrollContentHeight() + 10))
    }

    // MARK: Phase 2 — layer shell / wallpaper

    func testLayerAnchorAndLayerValues() {
        // Anchor bits match the protocol (top=1, bottom=2, left=4, right=8),
        // and `.all` is their union — the wallpaper anchors to every edge.
        XCTAssertEqual(LayerSurface.Anchor.top.rawValue, 1)
        XCTAssertEqual(LayerSurface.Anchor.bottom.rawValue, 2)
        XCTAssertEqual(LayerSurface.Anchor.left.rawValue, 4)
        XCTAssertEqual(LayerSurface.Anchor.right.rawValue, 8)
        XCTAssertEqual(LayerSurface.Anchor.all.rawValue, 15)
        XCTAssertTrue(LayerSurface.Anchor.all.contains(.top))
        XCTAssertTrue(LayerSurface.Anchor.all.contains(.right))
        // Layers are bottom-to-top, matching zwlr_layer_shell_v1_layer.
        XCTAssertEqual(LayerSurface.Layer.background.rawValue, 0)
        XCTAssertEqual(LayerSurface.Layer.overlay.rawValue, 3)
    }

    func testWallpaperPaintsOpaqueBlue() {
        // The pure painter should fill the whole surface — no transparent gaps,
        // and the Jaguar-blue reads as blue-dominant.
        let w: Int32 = 64, h: Int32 = 48
        guard let cs = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, w, h),
              let cr = cairo_create(cs) else { return XCTFail("no cairo surface") }
        defer { cairo_destroy(cr); cairo_surface_destroy(cs) }
        paintWallpaper(cr, w: Double(w), h: Double(h))
        cairo_surface_flush(cs)
        guard let data = cairo_image_surface_get_data(cs) else {
            return XCTFail("no pixel data")
        }
        let stride = Int(cairo_image_surface_get_stride(cs))
        func pixel(_ x: Int, _ y: Int) -> (b: UInt8, g: UInt8, r: UInt8, a: UInt8) {
            let p = data + y * stride + x * 4      // ARGB32 LE: B,G,R,A
            return (p[0], p[1], p[2], p[3])
        }
        for (x, y) in [(0, 0), (Int(w) - 1, 0), (Int(w) / 2, Int(h) / 2),
                       (0, Int(h) - 1), (Int(w) - 1, Int(h) - 1)] {
            let px = pixel(x, y)
            XCTAssertEqual(px.a, 255, "wallpaper must be fully opaque at (\(x),\(y))")
            XCTAssertGreaterThan(px.b, px.r, "blue should dominate red")
        }
        // Bottom is the deep ocean stop, so it's darker than the lighter top.
        XCTAssertLessThan(pixel(Int(w) / 2, Int(h) - 1).b, pixel(Int(w) / 2, 0).b)
    }

    // MARK: Phase 2.2 — desktop config

    func testColorCssHex() {
        // #rrggbb (opaque) and #aarrggbb (alpha first, sibling format).
        let rgb = Color(cssHex: "#20304a")
        XCTAssertEqual(rgb?.r ?? -1, 0x20 / 255.0, accuracy: 0.001)
        XCTAssertEqual(rgb?.g ?? -1, 0x30 / 255.0, accuracy: 0.001)
        XCTAssertEqual(rgb?.b ?? -1, 0x4a / 255.0, accuracy: 0.001)
        XCTAssertEqual(rgb?.a ?? -1, 1.0, accuracy: 0.001)

        let argb = Color(cssHex: "#80ff0000")   // half-alpha red
        XCTAssertEqual(argb?.a ?? -1, 0x80 / 255.0, accuracy: 0.001)
        XCTAssertEqual(argb?.r ?? -1, 1.0, accuracy: 0.001)
        XCTAssertEqual(argb?.g ?? -1, 0.0, accuracy: 0.001)

        XCTAssertEqual(Color(cssHex: "112233"), Color(cssHex: "#112233"))  // # optional
        XCTAssertNil(Color(cssHex: "#xyz"))
        XCTAssertNil(Color(cssHex: "#12345"))   // wrong length
    }

    func testDesktopStylePrecedence() {
        // image > gradient > flat > default.
        var c = Config()
        XCTAssertEqual(DesktopStyle.from(c).fill, .defaultAqua)

        c.set("desktop", "bg", "#ff112233")
        XCTAssertEqual(DesktopStyle.from(c).kind, "flat")

        c.set("desktop", "grad_top", "#ff000000")
        c.set("desktop", "grad_bot", "#ffffffff")
        XCTAssertEqual(DesktopStyle.from(c).kind, "gradient")

        c.set("desktop", "image", "/tmp/wall.png")
        XCTAssertEqual(DesktopStyle.from(c).fill, .image("/tmp/wall.png"))

        // A malformed colour is ignored (falls through), never a crash.
        var bad = Config(); bad.set("desktop", "bg", "not-a-color")
        XCTAssertEqual(DesktopStyle.from(bad).fill, .defaultAqua)
    }

    func testPaintDesktopFlatAndGradient() {
        func sample(_ style: DesktopStyle, _ x: Int, _ y: Int)
            -> (b: UInt8, g: UInt8, r: UInt8, a: UInt8) {
            let w: Int32 = 32, h: Int32 = 32
            let cs = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, w, h)!
            let cr = cairo_create(cs)!
            defer { cairo_destroy(cr); cairo_surface_destroy(cs) }
            paintDesktop(cr, w: Double(w), h: Double(h), style: style)
            cairo_surface_flush(cs)
            let d = cairo_image_surface_get_data(cs)!
            let stride = Int(cairo_image_surface_get_stride(cs))
            let p = d + y * stride + x * 4
            return (p[0], p[1], p[2], p[3])
        }
        // Flat red fills every pixel red.
        let flat = sample(DesktopStyle(fill: .flat(Color(1, 0, 0))), 16, 16)
        XCTAssertEqual(flat.r, 255); XCTAssertEqual(flat.g, 0); XCTAssertEqual(flat.b, 0)
        // Vertical black→white gradient: darker at top than bottom.
        let g = DesktopStyle(fill: .gradient(top: Color(0, 0, 0), bottom: Color(1, 1, 1)))
        XCTAssertLessThan(sample(g, 16, 1).r, sample(g, 16, 30).r)
    }

    func testPaintDesktopImageAndFallback() {
        // Write a solid-green 4×4 PNG, then paint it as the desktop image.
        let dir = NSTemporaryDirectoryPath()
        let path = dir + "/aqua-wall-test.png"
        let img = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, 4, 4)!
        let icr = cairo_create(img)!
        cairo_set_source_rgba(icr, 0, 1, 0, 1); cairo_paint(icr)
        cairo_surface_flush(img)
        _ = path.withCString { cairo_surface_write_to_png(img, $0) }
        cairo_destroy(icr); cairo_surface_destroy(img)

        let cs = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, 16, 16)!
        let cr = cairo_create(cs)!
        defer { cairo_destroy(cr); cairo_surface_destroy(cs) }
        paintDesktop(cr, w: 16, h: 16, style: DesktopStyle(fill: .image(path)))
        cairo_surface_flush(cs)
        let d = cairo_image_surface_get_data(cs)!
        let stride = Int(cairo_image_surface_get_stride(cs))
        let center = d + 8 * stride + 8 * 4   // ARGB32 LE: B,G,R,A
        XCTAssertEqual(center[1], 255, "green channel")
        XCTAssertEqual(center[2], 0, "red channel")

        // A missing image falls back to the Aqua default (blue-dominant), no crash.
        let cs2 = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, 16, 16)!
        let cr2 = cairo_create(cs2)!
        defer { cairo_destroy(cr2); cairo_surface_destroy(cs2) }
        paintDesktop(cr2, w: 16, h: 16, style: DesktopStyle(fill: .image("/no/such.png")))
        cairo_surface_flush(cs2)
        let d2 = cairo_image_surface_get_data(cs2)!
        let c2 = d2 + 8 * Int(cairo_image_surface_get_stride(cs2)) + 8 * 4
        XCTAssertGreaterThan(c2[0], c2[2], "fallback is blue-dominant")
        unlink(path)
    }

    // MARK: Phase 2.4 — menu bar

    func testFormatMenuClock() {
        XCTAssertEqual(formatMenuClock(hour24: 9, minute: 41, wday: 1), "Mon 9:41 AM")
        XCTAssertEqual(formatMenuClock(hour24: 0, minute: 5, wday: 0), "Sun 12:05 AM")
        XCTAssertEqual(formatMenuClock(hour24: 12, minute: 0, wday: 6), "Sat 12:00 PM")
        XCTAssertEqual(formatMenuClock(hour24: 23, minute: 59, wday: 3), "Wed 11:59 PM")
    }

    func testMenuBarDefaultMenus() {
        let menus = MenuBar.defaultMenus(appName: "Finder")
        XCTAssertTrue(menus[0].isSystem, "the system (drop) menu is first")
        XCTAssertTrue(menus[1].bold, "the application menu is bold")
        XCTAssertEqual(menus[1].title, "Finder")
        XCTAssertEqual(menus.map(\.title), ["", "Finder", "File", "Edit", "View",
                                            "Go", "Window", "Help"])
        for m in menus { XCTAssertFalse(m.items.isEmpty) }   // every title opens something
    }

    func testMenuBarLayoutOrderAndClock() {
        let cs = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, 800, 22)!
        let cr = cairo_create(cs)!
        defer { cairo_destroy(cr); cairo_surface_destroy(cs) }
        let menus = MenuBar.defaultMenus(appName: "Finder")
        let L = menuBarLayout(cr, w: 800, h: 22, menus: menus, clock: "Mon 9:41 AM",
                              showClock: true)

        XCTAssertEqual(L.titleRects.count, menus.count)
        // Titles march left-to-right without gaps or overlaps, all in the bar.
        var x = MenuBarMetrics.leftMargin
        for r in L.titleRects {
            XCTAssertEqual(r.x, x, accuracy: 0.01)
            XCTAssertGreaterThan(r.w, 0)
            XCTAssertEqual(r.h, 22, accuracy: 0.01)
            x += r.w
        }
        // The clock sits at the right, clear of the last title.
        XCTAssertGreaterThan(L.clockRect.x, L.titleRects.last!.x + L.titleRects.last!.w)
        XCTAssertLessThanOrEqual(L.clockRect.x + L.clockRect.w, 800)

        // show_clock off → no clock rect.
        let noClock = menuBarLayout(cr, w: 800, h: 22, menus: menus,
                                    clock: "Mon 9:41 AM", showClock: false)
        XCTAssertEqual(noClock.clockRect.w, 0)
    }
}

// A temp dir without importing Foundation (which the toolkit avoids).
private func NSTemporaryDirectoryPath() -> String {
    getenv("TMPDIR").map { String(cString: $0) } ?? "/tmp"
}
