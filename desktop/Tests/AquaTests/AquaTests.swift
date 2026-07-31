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

    // MARK: Phase 2.5 — Dock magnification

    func testDockMagnifyAtRest() {
        // No pointer → every tile is base size, evenly spaced, centred.
        let n = 6, S = 48.0, G = DockMetrics.gap
        let f = dockMagnify(count: n, baseSize: S, gap: G, centerX: 400,
                            pointerX: nil, maxScale: DockMetrics.maxScale, range: 118)
        XCTAssertEqual(f.count, n)
        for t in f {
            XCTAssertEqual(t.size, S, accuracy: 0.001)
            XCTAssertEqual(t.scale, 1, accuracy: 0.001)
        }
        // Symmetric about the centre; adjacent gaps equal S+G.
        XCTAssertEqual((f.first!.centerX + f.last!.centerX) / 2, 400, accuracy: 0.01)
        XCTAssertEqual(f[1].centerX - f[0].centerX, S + G, accuracy: 0.01)
    }

    func testDockMagnifyPeaksUnderPointer() {
        let n = 7, S = 48.0, G = DockMetrics.gap, M = 1.9, R = 118.0
        let center = 400.0
        // Base centre of tile 2, to place the pointer exactly on it.
        let baseW = Double(n) * S + Double(n - 1) * G
        let baseLeft = center - baseW / 2
        let target = 2
        let px = baseLeft + Double(target) * (S + G) + S / 2

        let f = dockMagnify(count: n, baseSize: S, gap: G, centerX: center,
                            pointerX: px, maxScale: M, range: R)
        // The pointed-at tile is the largest and near full magnification.
        let maxIdx = f.indices.max(by: { f[$0].size < f[$1].size })!
        XCTAssertEqual(maxIdx, target)
        XCTAssertEqual(f[target].scale, M, accuracy: 0.05)
        // Every tile is between 1x and Mx, and magnification decreases with
        // distance from the pointed tile on each side.
        for t in f {
            XCTAssertGreaterThanOrEqual(t.scale, 1 - 1e-9)
            XCTAssertLessThanOrEqual(t.scale, M + 1e-9)
        }
        XCTAssertGreaterThan(f[target].size, f[target - 1].size)
        XCTAssertGreaterThan(f[target].size, f[target + 1].size)
        XCTAssertGreaterThan(f[target - 1].size, f[0].size)
        // Tiles never overlap: each centre is past the previous one's right edge.
        for i in 1..<f.count {
            XCTAssertGreaterThanOrEqual(f[i].centerX - f[i].size / 2,
                                        f[i - 1].centerX + f[i - 1].size / 2 - 0.01)
        }
    }

    func testDockSurfaceHeightFitsMagnifiedTile() {
        // The surface must be tall enough for a fully magnified tile.
        let h = DockMetrics.surfaceHeight(tileSize: 48)
        XCTAssertGreaterThan(h, 48 * DockMetrics.maxScale)
    }

    // MARK: Finder — listing model

    func testFinderSortIsCaseInsensitiveAndInterleaved() {
        // The Mac Finder sorts one alphabetical run: folders do NOT float to the
        // top (that's the GNOME-2 behaviour the Rust sibling had).
        let sorted = finderSort([
            FinderEntry(name: "zebra.txt", kind: .document),
            FinderEntry(name: "Apps", kind: .folder),
            FinderEntry(name: "banana.txt", kind: .document),
            FinderEntry(name: "Cats", kind: .folder),
        ])
        XCTAssertEqual(sorted.map(\.name), ["Apps", "banana.txt", "Cats", "zebra.txt"])
    }

    func testFinderKindDetectsAppBundle() {
        XCTAssertEqual(finderKind(name: "TextEdit.app", isDirectory: true), .application)
        XCTAssertEqual(finderKind(name: "Documents", isDirectory: true), .folder)
        XCTAssertEqual(finderKind(name: "notes.txt", isDirectory: false), .document)
        // A *file* called foo.app is still a document, not a bundle.
        XCTAssertEqual(finderKind(name: "foo.app", isDirectory: false), .document)
    }

    func testFinderPathHelpers() {
        XCTAssertEqual(finderJoin("/home/abyss", "Docs"), "/home/abyss/Docs")
        XCTAssertEqual(finderJoin("/", "usr"), "/usr")
        XCTAssertEqual(finderParent("/home/abyss/Docs"), "/home/abyss")
        XCTAssertEqual(finderParent("/home"), "/")
        XCTAssertNil(finderParent("/"))
        XCTAssertEqual(finderDisplayName("/home/abyss/Docs"), "Docs")
        XCTAssertEqual(finderDisplayName("/home/abyss/"), "abyss")  // trailing slash
        XCTAssertEqual(finderDisplayName("/"), "Computer")
    }

    func testFinderFormatBytesAndStatusText() {
        XCTAssertEqual(finderFormatBytes(0), "0 bytes")
        XCTAssertEqual(finderFormatBytes(1), "1 byte")
        XCTAssertEqual(finderFormatBytes(4_812), "4.8 KB")
        XCTAssertEqual(finderFormatBytes(61_440), "61.4 KB")
        XCTAssertEqual(finderFormatBytes(39_600_000_000), "39.6 GB")
        XCTAssertEqual(finderStatusText(count: 1, freeBytes: 0), "1 item")
        XCTAssertEqual(finderStatusText(count: 12, freeBytes: 39_600_000_000),
                       "12 items, 39.6 GB available")
    }

    func testFinderTypeSelectWrapsAndIsCaseInsensitive() {
        let e = finderSampleEntries()   // Applications … TextEdit.app
        let first = finderTypeSelect(e, prefix: "m", after: nil)
        XCTAssertEqual(e[first!].name, "Movies")
        // The next "m" advances to Music, then wraps back to Movies.
        let second = finderTypeSelect(e, prefix: "M", after: first)
        XCTAssertEqual(e[second!].name, "Music")
        let third = finderTypeSelect(e, prefix: "m", after: second)
        XCTAssertEqual(e[third!].name, "Movies")
        XCTAssertNil(finderTypeSelect(e, prefix: "q", after: nil))
    }

    // MARK: Finder — geometry (the same pure functions paint and hit-test use)

    func testFinderLayoutSplitsTheWindow() {
        let L = finderLayout(w: 520, h: 400)
        // Toolbar sits under the title bar; the status bar is the last strip.
        XCTAssertEqual(L.toolbar.y, Theme.titleBarHeight, accuracy: 0.001)
        XCTAssertEqual(L.status.y + L.status.h, 400, accuracy: 0.001)
        // The content well stops short of the scrollbar and never overlaps the
        // status bar.
        XCTAssertEqual(L.content.w, 520 - FinderMetrics.scrollbarWidth, accuracy: 0.001)
        XCTAssertLessThanOrEqual(L.content.y + L.content.h, L.status.y + 0.001)
        // Both scroll arrows are paired at the bottom (the Jaguar default).
        XCTAssertGreaterThan(L.upArrow.y, L.track.y + L.track.h - 0.001)
        XCTAssertEqual(L.downArrow.y, L.upArrow.y + L.upArrow.h, accuracy: 0.001)
    }

    func testFinderLayoutWithoutToolbarIsSpatial() {
        // Hiding the toolbar (the title bar's pill) is what makes the Finder
        // spatial in 10.2: the item well then starts right under the title bar,
        // and its extra height goes to the content.
        let browser = finderLayout(w: 520, h: 400)
        let spatial = finderLayout(w: 520, h: 400, toolbarVisible: false)
        XCTAssertEqual(spatial.toolbar.h, 0, accuracy: 0.001)
        XCTAssertEqual(spatial.content.y, Theme.titleBarHeight, accuracy: 0.001)
        XCTAssertEqual(spatial.content.h - browser.content.h,
                       FinderMetrics.toolbarHeight, accuracy: 0.001)
        // The status bar and scrollbar are unaffected.
        XCTAssertEqual(spatial.status, browser.status)
        XCTAssertEqual(spatial.track.x, browser.track.x, accuracy: 0.001)
    }

    func testFinderIconGridHitTestRoundTrips() {
        let L = finderLayout(w: 520, h: 400)
        let vp = finderItemViewport(L, view: .icon)
        let count = 12
        let cols = finderColumns(viewportW: vp.w)
        XCTAssertGreaterThan(cols, 1)
        // Every item's own cell centre hit-tests back to that item.
        for i in 0..<count {
            let r = finderItemRect(i, view: .icon, viewport: vp, scroll: 0)
            let hit = finderIndex(atX: r.x + r.w / 2, y: r.y + r.h / 2, count: count,
                                  view: .icon, viewport: vp, scroll: 0)
            XCTAssertEqual(hit, i)
        }
        // Empty space past the last item hits nothing.
        let past = finderItemRect(count, view: .icon, viewport: vp, scroll: 0)
        XCTAssertNil(finderIndex(atX: past.x + 4, y: past.y + 4, count: count,
                                 view: .icon, viewport: vp, scroll: 0))
    }

    func testFinderListHitTestFollowsScroll() {
        let L = finderLayout(w: 520, h: 400)
        let vp = finderItemViewport(L, view: .list)
        // The list view's rows start below the column header.
        XCTAssertEqual(vp.y, L.content.y + finderListHeaderHeight, accuracy: 0.001)
        let count = 60
        let scroll = 5 * FinderMetrics.rowHeight
        // Scrolled by five rows, the top row is item 5.
        XCTAssertEqual(finderIndex(atX: vp.x + 10, y: vp.y + 1, count: count,
                                   view: .list, viewport: vp, scroll: scroll), 5)
    }

    func testFinderScrollToShowRevealsOffscreenItems() {
        let L = finderLayout(w: 520, h: 400)
        let vp = finderItemViewport(L, view: .icon)
        let count = 60
        let maxS = finderMaxScroll(count: count, view: .icon, viewport: vp)
        XCTAssertGreaterThan(maxS, 0)

        // Scrolling to the last item pins the bottom and shows it in full.
        let s = finderScrollToShow(count - 1, scroll: 0, count: count,
                                   view: .icon, viewport: vp)
        XCTAssertEqual(s, maxS, accuracy: 0.001)
        let last = finderItemRect(count - 1, view: .icon, viewport: vp, scroll: s)
        XCTAssertLessThanOrEqual(last.y + last.h, vp.y + vp.h + 0.001)
        // Coming back to item 0 scrolls to the top.
        XCTAssertEqual(finderScrollToShow(0, scroll: s, count: count,
                                          view: .icon, viewport: vp), 0, accuracy: 0.001)
        // An already-visible item doesn't move the view.
        XCTAssertEqual(finderScrollToShow(1, scroll: 0, count: count,
                                          view: .icon, viewport: vp), 0, accuracy: 0.001)
    }

    func testFinderArrowMotionStepsRowsAndClamps() {
        let L = finderLayout(w: 520, h: 400)
        let vp = finderItemViewport(L, view: .icon)
        let cols = finderColumns(viewportW: vp.w)
        let count = 12
        // No selection yet: any arrow starts at the first item.
        XCTAssertEqual(finderMove(from: nil, dx: 1, dy: 0, count: count,
                                  view: .icon, viewport: vp), 0)
        // Down moves a whole row in icon view, one item in list view.
        XCTAssertEqual(finderMove(from: 0, dx: 0, dy: 1, count: count,
                                  view: .icon, viewport: vp), cols)
        XCTAssertEqual(finderMove(from: 0, dx: 0, dy: 1, count: count,
                                  view: .list, viewport: vp), 1)
        // Motion clamps at both ends rather than wrapping.
        XCTAssertEqual(finderMove(from: 0, dx: -1, dy: 0, count: count,
                                  view: .icon, viewport: vp), 0)
        XCTAssertEqual(finderMove(from: count - 1, dx: 0, dy: 1, count: count,
                                  view: .icon, viewport: vp), count - 1)
    }

    // MARK: The Finder as a portal's picker (P7.1)

    /// A private directory for a test that touches the filesystem.
    private func makeScratchDir(_ tag: String) -> String {
        var template = Array((NSTemporaryDirectoryPath() + "/abyss-\(tag).XXXXXX").utf8CString)
        guard let dir = template.withUnsafeMutableBufferPointer({
            mkdtemp($0.baseAddress!).map { String(cString: $0) }
        }) else {
            XCTFail("mkdtemp failed")
            return NSTemporaryDirectoryPath()
        }
        return dir
    }

    func testPickerModeChoosesAFileInsteadOfLaunchingIt() {
        let doc = FinderEntry(name: "Read Me.txt", kind: .document, size: 10)
        let folder = FinderEntry(name: "Reports", kind: .folder, size: 0)
        let app = FinderEntry(name: "Marker.app", kind: .application, size: 0)

        // Normally a file is launched...
        XCTAssertEqual(finderActivation(entry: doc, in: "/home/x", picking: false),
                       .launch("/home/x/Read Me.txt"))
        // ...but a file dialog must never run what you click: in picker mode the
        // same double-click is the *answer*, not an exec.
        XCTAssertEqual(finderActivation(entry: doc, in: "/home/x", picking: true),
                       .choose("/home/x/Read Me.txt"))
        // An app bundle is a file like any other to a picker — choosing it must
        // not launch it either, which is the case most likely to go wrong.
        XCTAssertEqual(finderActivation(entry: app, in: "/home/x", picking: true),
                       .choose("/home/x/Marker.app"))
        // Folders still navigate in both modes; you have to be able to browse.
        XCTAssertEqual(finderActivation(entry: folder, in: "/home/x", picking: true),
                       .navigate("/home/x/Reports"))
        XCTAssertEqual(finderActivation(entry: folder, in: "/home/x", picking: false),
                       .navigate("/home/x/Reports"))
    }

    func testPickerResultRoundTripsThroughTheResultFile() {
        let dir = makeScratchDir("picker")
        defer { _ = finderRemovePath(dir) }
        let result = dir + "/result"

        // What the picker writes, the portal reads back.
        let fd = open(result, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        XCTAssertGreaterThanOrEqual(fd, 0)
        let line = Array("/home/x/Read Me.txt\n".utf8)
        _ = line.withUnsafeBufferPointer { write(fd, $0.baseAddress, line.count) }
        close(fd)
        XCTAssertEqual(FinderPicker.readResult(result), "/home/x/Read Me.txt")
    }

    func testACancelledPickIsNotMistakenForAChoice() {
        let dir = makeScratchDir("picker-cancel")
        defer { _ = finderRemovePath(dir) }

        // A cancel leaves no file at all...
        XCTAssertNil(FinderPicker.readResult(dir + "/never-written"))
        // ...and an empty file (a picker that died mid-write) is not a path.
        let empty = dir + "/empty"
        close(open(empty, O_WRONLY | O_CREAT | O_TRUNC, 0o600))
        XCTAssertNil(FinderPicker.readResult(empty))
    }

    func testAResultMustBeAnAbsolutePath() {
        let dir = makeScratchDir("picker-relative")
        defer { _ = finderRemovePath(dir) }
        let result = dir + "/result"
        // The portal *opens* whatever comes back, so a relative path would
        // resolve against the portal's working directory rather than the user's
        // choice — refuse it rather than open the wrong file.
        let fd = open(result, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        let line = Array("Read Me.txt\n".utf8)
        _ = line.withUnsafeBufferPointer { write(fd, $0.baseAddress, line.count) }
        close(fd)
        XCTAssertNil(FinderPicker.readResult(result))
    }

    func testPickerModeIsOffUnlessTheEnvironmentSaysOtherwise() {
        unsetenv("ABYSS_FINDER_PICK")
        XCTAssertFalse(FinderPicker.isPicking)
        XCTAssertNil(FinderPicker.resultPath())
        setenv("ABYSS_FINDER_PICK", "/tmp/abyss-pick-result", 1)
        defer { unsetenv("ABYSS_FINDER_PICK") }
        XCTAssertTrue(FinderPicker.isPicking)
        XCTAssertEqual(FinderPicker.resultPath(), "/tmp/abyss-pick-result")
        // An empty value means "not picking" rather than "pick into ''".
        setenv("ABYSS_FINDER_PICK", "", 1)
        XCTAssertFalse(FinderPicker.isPicking)
    }

    // MARK: Menu-bar status items

    func testStatusItemsAreOmittedWhenTheMachineCantFeedThem() {
        // The rule the whole feature rests on: no mixer means no speaker, not a
        // speaker showing 0%. A VM (and the Linux dev box) has neither device.
        let empty = MenuBarStatus()
        XCTAssertTrue(empty.isEmpty)
        let rects = menuBarStatusLayout(status: empty, h: 22, rightEdge: 800)
        XCTAssertNil(rects.volume)
        XCTAssertNil(rects.battery)
    }

    func testStatusItemsLayOutRightToLeftAndDontOverlap() {
        let both = MenuBarStatus(volume: 60, batteryPercent: 84)
        let r = menuBarStatusLayout(status: both, h: 22, rightEdge: 800)
        let volume = try! XCTUnwrap(r.volume)
        let battery = try! XCTUnwrap(r.battery)
        // Battery sits nearest the clock, volume to its left — Jaguar's order.
        XCTAssertLessThan(volume.x, battery.x)
        XCTAssertLessThanOrEqual(volume.x + volume.w, battery.x)
        // Everything stays left of the clock's edge.
        XCTAssertLessThanOrEqual(battery.x + battery.w, 800)
        XCTAssertEqual(volume.h, 22)
    }

    func testASingleItemStillHugsTheClock() {
        // With only one item present the other's slot must not be reserved —
        // otherwise the bar shows a gap where a hidden item would have been.
        let onlyVolume = menuBarStatusLayout(status: MenuBarStatus(volume: 30),
                                             h: 22, rightEdge: 800)
        let onlyBattery = menuBarStatusLayout(status: MenuBarStatus(batteryPercent: 10),
                                              h: 22, rightEdge: 800)
        XCTAssertNil(onlyVolume.battery)
        XCTAssertNil(onlyBattery.volume)
        let v = try! XCTUnwrap(onlyVolume.volume)
        let b = try! XCTUnwrap(onlyBattery.battery)
        XCTAssertEqual(v.x + v.w, 800 - MenuBarStatusMetrics.clockGap)
        XCTAssertEqual(b.x + b.w, 800 - MenuBarStatusMetrics.clockGap)
    }

    func testTheMenuBarLayoutReservesSpaceForStatusItems() {
        // Paint and hit-test share one layout (§2.9), so the bar's own layout
        // must carry the item rects rather than computing them separately.
        let surface = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, 800, 22)
        defer { cairo_surface_destroy(surface) }
        guard let cr = cairo_create(surface) else { return XCTFail("no cairo context") }
        defer { cairo_destroy(cr) }
        let menus = MenuBar.defaultMenus(appName: "Finder")
        let withStatus = menuBarLayout(cr, w: 800, h: 22, menus: menus,
                                       clock: "Mon 9:41 AM", showClock: true,
                                       status: MenuBarStatus(volume: 60, batteryPercent: 84))
        XCTAssertNotNil(withStatus.volumeRect)
        XCTAssertNotNil(withStatus.batteryRect)
        // They sit left of the clock, never over it.
        XCTAssertLessThanOrEqual(withStatus.batteryRect!.x + withStatus.batteryRect!.w,
                                 withStatus.clockRect.x)
        let without = menuBarLayout(cr, w: 800, h: 22, menus: menus,
                                    clock: "Mon 9:41 AM", showClock: true)
        XCTAssertNil(without.volumeRect)
        XCTAssertNil(without.batteryRect)
        // The clock doesn't move when items appear: they take space to its left.
        XCTAssertEqual(withStatus.clockRect.x, without.clockRect.x)
    }

    // MARK: Launching

    func testLauncherResolvesExecutables() {
        // A bare name is searched along the given PATH…
        XCTAssertEqual(Launcher.resolveExecutable("sh", path: "/nonexistent:/bin"),
                       "/bin/sh")
        XCTAssertNil(Launcher.resolveExecutable("sh", path: "/nonexistent"))
        // …a path with a slash is used as-is, but only if it's executable.
        XCTAssertEqual(Launcher.resolveExecutable("/bin/sh"), "/bin/sh")
        XCTAssertNil(Launcher.resolveExecutable("/etc/hostname"))   // not executable
        XCTAssertNil(Launcher.resolveExecutable(""))
    }

    func testLauncherFindsItsOwnExecutable() {
        // The mechanism is per-OS and lives in CPlatform (/proc/self/exe on
        // Linux, the KERN_PROC_PATHNAME sysctl on FreeBSD, which mounts no
        // procfs by default). Whatever the path, it must be absolute and point
        // at something we could actually exec — that is what the Dock relies on
        // when it launches another copy of the shell.
        guard let me = Launcher.selfExecutable() else {
            return XCTFail("selfExecutable() returned nil")
        }
        XCTAssertTrue(me.hasPrefix("/"), "not absolute: \(me)")
        XCTAssertEqual(access(me, X_OK), 0, "not executable: \(me)")

        // $ABYSS_APP_BINARY overrides — but only when it names something
        // executable, so a stale value can't break launching.
        setenv("ABYSS_APP_BINARY", "/bin/sh", 1)
        XCTAssertEqual(Launcher.selfExecutable(), "/bin/sh")
        setenv("ABYSS_APP_BINARY", "/nonexistent/binary", 1)
        XCTAssertEqual(Launcher.selfExecutable(), me)
        unsetenv("ABYSS_APP_BINARY")
    }

    func testLauncherSplitsCommandLines() {
        XCTAssertEqual(Launcher.splitCommand("xdg-open"), ["xdg-open"])
        XCTAssertEqual(Launcher.splitCommand("  open   -a  Preview "),
                       ["open", "-a", "Preview"])
        XCTAssertEqual(Launcher.splitCommand(""), [])
    }

    func testLauncherFindsABundleExecutable() {
        let base = NSTemporaryDirectoryPath()
        var template = Array((base + "/bundle.XXXXXX").utf8CString)
        guard let root = template.withUnsafeMutableBufferPointer({ buf -> String? in
            mkdtemp(buf.baseAddress!).map { String(cString: $0) }
        }) else { return XCTFail("mkdtemp failed") }
        defer { removeTree(root) }

        // Foo.app/Contents/MacOS/Foo — the Mac convention.
        let app = finderJoin(root, "Foo.app")
        XCTAssertTrue(finderCreateDirectory(app))
        XCTAssertTrue(finderCreateDirectory(finderJoin(app, "Contents")))
        XCTAssertTrue(finderCreateDirectory(finderJoin(app, "Contents/MacOS")))
        let exe = finderJoin(app, "Contents/MacOS/Foo")
        let fd = exe.withCString { open($0, O_CREAT | O_WRONLY, 0o755) }
        XCTAssertGreaterThanOrEqual(fd, 0)
        close(fd)

        XCTAssertEqual(Launcher.bundleExecutable(app), exe)
        XCTAssertTrue(Launcher.isExecutableFile(exe))
        // A bundle with nothing runnable in it resolves to nil rather than
        // launching something arbitrary.
        let empty = finderJoin(root, "Bare.app")
        XCTAssertTrue(finderCreateDirectory(empty))
        XCTAssertNil(Launcher.bundleExecutable(empty))
    }

    func testLauncherRunsADetachedProcess() {
        let base = NSTemporaryDirectoryPath()
        var template = Array((base + "/launch.XXXXXX").utf8CString)
        guard let root = template.withUnsafeMutableBufferPointer({ buf -> String? in
            mkdtemp(buf.baseAddress!).map { String(cString: $0) }
        }) else { return XCTFail("mkdtemp failed") }
        defer { removeTree(root) }

        // A script that records the environment it was launched with, so we can
        // prove both the exec and the extra environment took effect.
        let marker = finderJoin(root, "ran.txt")
        let script = finderJoin(root, "run.sh")
        let body = "#!/bin/sh\nprintf '%s' \"$ABYSS_TEST_TAG\" > \(marker)\n"
        let fd = script.withCString { open($0, O_CREAT | O_WRONLY | O_TRUNC, 0o755) }
        XCTAssertGreaterThanOrEqual(fd, 0)
        _ = Array(body.utf8).withUnsafeBytes { Glibc.write(fd, $0.baseAddress, $0.count) }
        close(fd)

        XCTAssertTrue(Launcher.launchDetached([script],
                                              extraEnv: ["ABYSS_TEST_TAG": "hello"]))
        // The child is detached, so poll briefly for its side effect.
        var contents = ""
        for _ in 0..<50 {
            if finderExists(marker) {
                let f = marker.withCString { open($0, O_RDONLY) }
                if f >= 0 {
                    var buf = [UInt8](repeating: 0, count: 64)
                    let n = buf.withUnsafeMutableBytes { Glibc.read(f, $0.baseAddress, $0.count) }
                    close(f)
                    if n > 0 { contents = String(decoding: buf[0..<n], as: UTF8.self) }
                }
                if !contents.isEmpty { break }
            }
            usleep(20_000)
        }
        XCTAssertEqual(contents, "hello", "the detached child ran with our environment")
        // Nothing to reap: the grandchild belongs to init, so no zombie is left.
        XCTAssertEqual(waitpid(-1, nil, WNOHANG), -1)

        XCTAssertFalse(Launcher.launchDetached(["definitely-not-a-real-command-xyz"]))
    }

    // MARK: Desktop icons

    func testDesktopIconsStackFromTheTopRight() {
        let bounds = Rect(0, DesktopMetrics.topInset, 800, 600 - DesktopMetrics.topInset)
        let rows = desktopRows(bounds: bounds)
        XCTAssertGreaterThan(rows, 1)

        // The first icon hugs the top-right corner (where the Mac puts the disk).
        let first = desktopIconRect(0, bounds: bounds)
        XCTAssertEqual(first.x + first.w, bounds.x + bounds.w - DesktopMetrics.margin,
                       accuracy: 0.001)
        XCTAssertEqual(first.y, bounds.y + DesktopMetrics.margin, accuracy: 0.001)

        // The second is directly below it — the column fills downward…
        let second = desktopIconRect(1, bounds: bounds)
        XCTAssertEqual(second.x, first.x, accuracy: 0.001)
        XCTAssertEqual(second.y, first.y + DesktopMetrics.cellH, accuracy: 0.001)

        // …and once the column is full, the next one starts to its LEFT.
        let wrapped = desktopIconRect(rows, bounds: bounds)
        XCTAssertEqual(wrapped.x, first.x - DesktopMetrics.cellW, accuracy: 0.001)
        XCTAssertEqual(wrapped.y, first.y, accuracy: 0.001)
        // Every icon stays inside the desktop.
        for i in 0..<(rows * 2) {
            let r = desktopIconRect(i, bounds: bounds)
            XCTAssertGreaterThanOrEqual(r.x, bounds.x)
            XCTAssertLessThanOrEqual(r.y + r.h, bounds.y + bounds.h)
        }
    }

    func testDesktopIconHitTestRoundTrips() {
        let bounds = Rect(0, DesktopMetrics.topInset, 800, 600 - DesktopMetrics.topInset)
        let count = 5
        for i in 0..<count {
            let icon = desktopIconBox(desktopIconRect(i, bounds: bounds))
            let hit = desktopIndex(atX: icon.x + icon.w / 2, y: icon.y + icon.h / 2,
                                   count: count, bounds: bounds)
            XCTAssertEqual(hit, i)
        }
        // Bare desktop (well left of the icon column) hits nothing.
        XCTAssertNil(desktopIndex(atX: 100, y: 300, count: count, bounds: bounds))
        XCTAssertNil(desktopIndex(atX: 400, y: 500, count: count, bounds: bounds))
    }

    func testDesktopEntriesLeadWithTheVolume() {
        let base = NSTemporaryDirectoryPath()
        var template = Array((base + "/desktop.XXXXXX").utf8CString)
        guard let dir = template.withUnsafeMutableBufferPointer({ buf -> String? in
            mkdtemp(buf.baseAddress!).map { String(cString: $0) }
        }) else { return XCTFail("mkdtemp failed") }
        defer { removeTree(dir) }

        XCTAssertTrue(finderCreateDirectory(finderJoin(dir, "Projects")))
        let fd = finderJoin(dir, "notes.txt").withCString {
            open($0, O_CREAT | O_WRONLY, 0o644)
        }
        close(fd)

        let entries = desktopEntries(volumeName: "AbyssBSD HD", desktopFolder: dir)
        XCTAssertEqual(entries.first?.kind, .disk)
        XCTAssertEqual(entries.map(\.name), ["AbyssBSD HD", "notes.txt", "Projects"])
        // With no Desktop folder there's still a volume to show.
        XCTAssertEqual(desktopEntries(volumeName: "AbyssBSD HD",
                                      desktopFolder: nil).count, 1)
    }

    // MARK: Finder — file-operation naming rules (pure)

    func testFinderSplitExtension() {
        XCTAssertEqual(finderSplitExtension("Read Me.txt").base, "Read Me")
        XCTAssertEqual(finderSplitExtension("Read Me.txt").ext, ".txt")
        XCTAssertEqual(finderSplitExtension("Documents").ext, "")
        // A leading dot is part of the name, not an extension; so is a trailing one.
        XCTAssertEqual(finderSplitExtension(".hidden").base, ".hidden")
        XCTAssertEqual(finderSplitExtension(".hidden").ext, "")
        XCTAssertEqual(finderSplitExtension("weird.").ext, "")
        XCTAssertEqual(finderSplitExtension("a.tar.gz").ext, ".gz")
    }

    func testFinderNewFolderNameSequence() {
        var taken: Set<String> = []
        func exists(_ n: String) -> Bool { taken.contains(n) }
        XCTAssertEqual(finderNewFolderName(exists: exists), "untitled folder")
        taken.insert("untitled folder")
        XCTAssertEqual(finderNewFolderName(exists: exists), "untitled folder 2")
        taken.insert("untitled folder 2")
        XCTAssertEqual(finderNewFolderName(exists: exists), "untitled folder 3")
    }

    func testFinderCopyNameKeepsTheExtension() {
        var taken: Set<String> = ["Read Me.txt", "Documents"]
        func exists(_ n: String) -> Bool { taken.contains(n) }
        // " copy" goes before the extension, as on Mac.
        XCTAssertEqual(finderCopyName("Read Me.txt", exists: exists), "Read Me copy.txt")
        taken.insert("Read Me copy.txt")
        XCTAssertEqual(finderCopyName("Read Me.txt", exists: exists), "Read Me copy 2.txt")
        XCTAssertEqual(finderCopyName("Documents", exists: exists), "Documents copy")
    }

    func testFinderPasteNameOnlyRenamesOnCollision() {
        let taken: Set<String> = ["Read Me.txt"]
        func exists(_ n: String) -> Bool { taken.contains(n) }
        // Pasting into another folder keeps the name…
        XCTAssertEqual(finderPasteName("notes.txt", exists: exists), "notes.txt")
        // …but pasting where it already lives makes a copy.
        XCTAssertEqual(finderPasteName("Read Me.txt", exists: exists), "Read Me copy.txt")
    }

    func testFinderNameValidation() {
        XCTAssertTrue(finderIsValidName("Reports"))
        XCTAssertTrue(finderIsValidName(".hidden"))
        XCTAssertFalse(finderIsValidName(""))
        XCTAssertFalse(finderIsValidName("."))
        XCTAssertFalse(finderIsValidName(".."))
        XCTAssertFalse(finderIsValidName("a/b"))       // would escape the folder
        XCTAssertFalse(finderIsValidName(String(repeating: "x", count: 256)))
    }

    // MARK: Finder — file operations on a real directory

    func testFinderFileOperations() {
        let base = NSTemporaryDirectoryPath()
        var template = Array((base + "/finderops.XXXXXX").utf8CString)
        guard let root = template.withUnsafeMutableBufferPointer({ buf -> String? in
            mkdtemp(buf.baseAddress!).map { String(cString: $0) }
        }) else { return XCTFail("mkdtemp failed") }

        // ~/.Trash must land inside the temp tree, not the real home.
        let savedHome = getenv("HOME").map { String(cString: $0) }
        setenv("HOME", root, 1)
        defer {
            if let savedHome { setenv("HOME", savedHome, 1) } else { unsetenv("HOME") }
            removeTree(root)
        }

        let dir = finderJoin(root, "work")
        XCTAssertTrue(finderCreateDirectory(dir))

        func write(_ path: String, _ text: String) {
            let fd = path.withCString { open($0, O_CREAT | O_WRONLY | O_TRUNC, 0o644) }
            XCTAssertGreaterThanOrEqual(fd, 0)
            _ = Array(text.utf8).withUnsafeBytes { Glibc.write(fd, $0.baseAddress, $0.count) }
            close(fd)
        }
        func read(_ path: String) -> String {
            let fd = path.withCString { open($0, O_RDONLY) }
            guard fd >= 0 else { return "" }
            defer { close(fd) }
            var buf = [UInt8](repeating: 0, count: 256)
            let n = buf.withUnsafeMutableBytes { Glibc.read(fd, $0.baseAddress, $0.count) }
            return n > 0 ? String(decoding: buf[0..<n], as: UTF8.self) : ""
        }

        // New folder + rename.
        let folder = finderJoin(dir, "untitled folder")
        XCTAssertTrue(finderCreateDirectory(folder))
        XCTAssertTrue(finderRenameEntry(from: folder, to: finderJoin(dir, "Reports")))
        XCTAssertFalse(finderExists(folder))
        XCTAssertTrue(finderIsDirectory(finderJoin(dir, "Reports")))

        // Copy a file (contents and all).
        write(finderJoin(dir, "Read Me.txt"), "hello abyss")
        XCTAssertTrue(finderCopyFile(from: finderJoin(dir, "Read Me.txt"),
                                     to: finderJoin(dir, "Read Me copy.txt")))
        XCTAssertEqual(read(finderJoin(dir, "Read Me copy.txt")), "hello abyss")

        // Copy a directory tree: the nested file comes along, dot-files included.
        write(finderJoin(dir, "Reports/q1.txt"), "quarter one")
        write(finderJoin(dir, "Reports/.notes"), "private")
        XCTAssertTrue(finderCreateDirectory(finderJoin(dir, "Reports/sub")))
        write(finderJoin(dir, "Reports/sub/deep.txt"), "deep")
        XCTAssertTrue(finderCopyPath(from: finderJoin(dir, "Reports"),
                                     to: finderJoin(dir, "Reports copy")))
        XCTAssertEqual(read(finderJoin(dir, "Reports copy/q1.txt")), "quarter one")
        XCTAssertEqual(read(finderJoin(dir, "Reports copy/sub/deep.txt")), "deep")
        XCTAssertEqual(read(finderJoin(dir, "Reports copy/.notes")), "private")
        // The original is untouched by the copy.
        XCTAssertEqual(read(finderJoin(dir, "Reports/q1.txt")), "quarter one")

        // Delete = move to Trash, never an unlink.
        let victim = finderJoin(dir, "Read Me copy.txt")
        let trashed = finderMoveToTrash(victim)
        XCTAssertNotNil(trashed)
        XCTAssertFalse(finderExists(victim))
        XCTAssertEqual(read(trashed ?? ""), "hello abyss")
        XCTAssertTrue((trashed ?? "").hasPrefix(finderJoin(root, ".Trash")))

        // A second item of the same name in the Trash gets uniqued, not clobbered.
        write(finderJoin(dir, "Read Me copy.txt"), "second one")
        let trashedAgain = finderMoveToTrash(finderJoin(dir, "Read Me copy.txt"))
        XCTAssertNotNil(trashedAgain)
        XCTAssertNotEqual(trashedAgain, trashed)
        XCTAssertEqual(read(trashed ?? ""), "hello abyss")      // still there
        XCTAssertEqual(read(trashedAgain ?? ""), "second one")
    }

    // MARK: Application bundles — an app's own icon

    func testAppBundleIconLookupAndDecode() {
        let base = NSTemporaryDirectoryPath()
        var template = Array((base + "/appicon.XXXXXX").utf8CString)
        guard let root = template.withUnsafeMutableBufferPointer({ buf -> String? in
            mkdtemp(buf.baseAddress!).map { String(cString: $0) }
        }) else { return XCTFail("mkdtemp failed") }
        defer { finderRemovePath(root) }

        let bundle = finderJoin(root, "Marker.app")
        let resources = finderJoin(bundle, "Contents/Resources")
        XCTAssertTrue(finderCreateDirectory(bundle))
        XCTAssertTrue(finderCreateDirectory(finderJoin(bundle, "Contents")))
        XCTAssertTrue(finderCreateDirectory(resources))

        // A bundle with no artwork has no icon — the procedural glyph stands in.
        XCTAssertNil(AppIcon.iconFile(inBundle: bundle))

        // Write a real 8x8 red PNG with cairo (no fixture files in the repo).
        func writePNG(_ path: String, side: Int32, r: Double, g: Double, b: Double) {
            let s = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, side, side)
            let cr = cairo_create(s)
            cairo_set_source_rgba(cr, r, g, b, 1)
            cairo_paint(cr)
            cairo_destroy(cr)
            path.withCString { _ = cairo_surface_write_to_png(s, $0) }
            cairo_surface_destroy(s)
        }
        writePNG(finderJoin(resources, "zebra.png"), side: 8, r: 0, g: 0, b: 1)
        // Any PNG will do when nothing matches the naming convention...
        XCTAssertEqual(AppIcon.iconFile(inBundle: bundle), finderJoin(resources, "zebra.png"))
        // ...but a file named after the bundle wins.
        writePNG(finderJoin(resources, "Marker.png"), side: 16, r: 1, g: 0, b: 0)
        XCTAssertEqual(AppIcon.iconFile(inBundle: bundle), finderJoin(resources, "Marker.png"))

        // It decodes, and drawing it paints the icon's pixels (red) into a rect.
        let target = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, 32, 32)
        guard let cr = cairo_create(target) else { return XCTFail("no cairo context") }
        XCTAssertTrue(AppIcon.draw(cr, path: finderJoin(resources, "Marker.png"),
                                   Rect(0, 0, 32, 32)))
        cairo_surface_flush(target)
        let px = cairo_image_surface_get_data(target)!
        let stride = Int(cairo_image_surface_get_stride(target))
        // ARGB32 is premultiplied BGRA in memory on little-endian.
        let mid = 16 * stride + 16 * 4
        XCTAssertEqual(px[mid + 2], 255)   // red
        XCTAssertEqual(px[mid + 1], 0)     // green
        XCTAssertEqual(px[mid + 0], 0)     // blue
        cairo_destroy(cr)
        cairo_surface_destroy(target)

        // A listing marks the bundle with its icon; a plain folder gets none.
        XCTAssertTrue(finderCreateDirectory(finderJoin(root, "Documents")))
        let listed = readDirectory(root)
        let app = listed.first { $0.name == "Marker.app" }
        XCTAssertEqual(app?.kind, .application)
        XCTAssertEqual(app?.iconPath, finderJoin(resources, "Marker.png"))
        XCTAssertNil(listed.first { $0.name == "Documents" }?.iconPath)
    }

    func testICNSEmbeddedPNGExtraction() {
        let base = NSTemporaryDirectoryPath()
        var template = Array((base + "/icns.XXXXXX").utf8CString)
        guard let root = template.withUnsafeMutableBufferPointer({ buf -> String? in
            mkdtemp(buf.baseAddress!).map { String(cString: $0) }
        }) else { return XCTFail("mkdtemp failed") }
        defer { finderRemovePath(root) }

        // Two PNGs of different sizes, wrapped as .icns variants: the extractor
        // must pick the biggest one (that's the sharpest icon in the container).
        func pngBytes(side: Int32) -> [UInt8] {
            let path = finderJoin(root, "tmp\(side).png")
            let s = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, side, side)
            let cr = cairo_create(s)
            cairo_set_source_rgba(cr, 0, 1, 0, 1); cairo_paint(cr)
            cairo_destroy(cr)
            path.withCString { _ = cairo_surface_write_to_png(s, $0) }
            cairo_surface_destroy(s)
            let fd = path.withCString { open($0, O_RDONLY) }
            defer { close(fd); path.withCString { _ = unlink($0) } }
            var out = [UInt8](), buf = [UInt8](repeating: 0, count: 4096)
            while true {
                let n = buf.withUnsafeMutableBytes { Glibc.read(fd, $0.baseAddress, $0.count) }
                if n <= 0 { break }
                out.append(contentsOf: buf[0..<n])
            }
            return out
        }
        let small = pngBytes(side: 8), large = pngBytes(side: 64)
        XCTAssertGreaterThan(large.count, small.count)

        func chunk(_ type: String, _ payload: [UInt8]) -> [UInt8] {
            let len = payload.count + 8
            return Array(type.utf8) + [UInt8(len >> 24 & 0xff), UInt8(len >> 16 & 0xff),
                                       UInt8(len >> 8 & 0xff), UInt8(len & 0xff)] + payload
        }
        let body = chunk("ic07", small) + chunk("ic09", large)
        let file = Array("icns".utf8)
            + [UInt8((body.count + 8) >> 24 & 0xff), UInt8((body.count + 8) >> 16 & 0xff),
               UInt8((body.count + 8) >> 8 & 0xff), UInt8((body.count + 8) & 0xff)]
            + body
        let icns = finderJoin(root, "Marker.icns")
        let fd = icns.withCString { open($0, O_CREAT | O_WRONLY | O_TRUNC, 0o644) }
        XCTAssertGreaterThanOrEqual(fd, 0)
        _ = file.withUnsafeBytes { Glibc.write(fd, $0.baseAddress, $0.count) }
        close(fd)

        XCTAssertEqual(AppIcon.largestEmbeddedPNG(inICNS: icns), large)
        // And the whole path decodes: the 64px variant comes back as a surface.
        let surface = AppIcon.surface(icns)
        XCTAssertNotNil(surface)
        XCTAssertEqual(cairo_image_surface_get_width(surface!), 64)

        // A file that isn't an ICNS (or holds no PNG variant) is nil, not a crash.
        let notICNS = finderJoin(root, "bogus.icns")
        let fd2 = notICNS.withCString { open($0, O_CREAT | O_WRONLY | O_TRUNC, 0o644) }
        _ = Array("not an icon at all".utf8).withUnsafeBytes {
            Glibc.write(fd2, $0.baseAddress, $0.count)
        }
        close(fd2)
        XCTAssertNil(AppIcon.largestEmbeddedPNG(inICNS: notICNS))
        XCTAssertNil(AppIcon.surface(notICNS))
    }

    // MARK: The Dock — emptying the Trash (the one path that really unlinks)

    func testEmptyTrashRemovesEverythingPermanently() {
        let base = NSTemporaryDirectoryPath()
        var template = Array((base + "/emptytrash.XXXXXX").utf8CString)
        guard let root = template.withUnsafeMutableBufferPointer({ buf -> String? in
            mkdtemp(buf.baseAddress!).map { String(cString: $0) }
        }) else { return XCTFail("mkdtemp failed") }

        // Own $HOME, or this test empties the developer's real Trash.
        let savedHome = getenv("HOME").map { String(cString: $0) }
        setenv("HOME", root, 1)
        defer {
            if let savedHome { setenv("HOME", savedHome, 1) } else { unsetenv("HOME") }
            finderRemovePath(root)
        }

        func write(_ path: String, _ text: String) {
            let fd = path.withCString { open($0, O_CREAT | O_WRONLY | O_TRUNC, 0o644) }
            XCTAssertGreaterThanOrEqual(fd, 0)
            _ = Array(text.utf8).withUnsafeBytes { Glibc.write(fd, $0.baseAddress, $0.count) }
            close(fd)
        }

        // Looking at the Trash must not create it, and an absent Trash reads as
        // empty rather than as an error.
        XCTAssertEqual(finderTrashPath(), finderJoin(root, ".Trash"))
        XCTAssertFalse(finderExists(finderJoin(root, ".Trash")))
        XCTAssertTrue(finderTrashContents().isEmpty)
        XCTAssertEqual(finderEmptyTrash().removed, 0)
        XCTAssertFalse(finderExists(finderJoin(root, ".Trash")))

        // Throw away a file and a whole folder (with a dot-file inside, which an
        // empty must take with it).
        let work = finderJoin(root, "work")
        XCTAssertTrue(finderCreateDirectory(work))
        write(finderJoin(work, "Read Me.txt"), "hello")
        XCTAssertTrue(finderCreateDirectory(finderJoin(work, "Reports")))
        write(finderJoin(work, "Reports/q1.txt"), "quarter one")
        write(finderJoin(work, "Reports/.notes"), "private")
        XCTAssertNotNil(finderMoveToTrash(finderJoin(work, "Read Me.txt")))
        XCTAssertNotNil(finderMoveToTrash(finderJoin(work, "Reports")))
        XCTAssertEqual(finderTrashContents().count, 2)

        // Emptying reports what went, and leaves the Trash itself in place (as
        // on Mac — the folder stays, its contents don't).
        let result = finderEmptyTrash()
        XCTAssertEqual(result.removed, 2)
        XCTAssertEqual(result.failed, 0)
        XCTAssertTrue(finderTrashContents().isEmpty)
        XCTAssertTrue(finderIsDirectory(finderJoin(root, ".Trash")))
        XCTAssertFalse(finderExists(finderJoin(root, ".Trash/Read Me.txt")))
        XCTAssertFalse(finderExists(finderJoin(root, ".Trash/Reports/q1.txt")))
        // Nothing outside the Trash was touched.
        XCTAssertTrue(finderIsDirectory(work))
    }

    func testRemovePathDeletesTreesAndReportsFailure() {
        let base = NSTemporaryDirectoryPath()
        var template = Array((base + "/removepath.XXXXXX").utf8CString)
        guard let root = template.withUnsafeMutableBufferPointer({ buf -> String? in
            mkdtemp(buf.baseAddress!).map { String(cString: $0) }
        }) else { return XCTFail("mkdtemp failed") }
        defer { finderRemovePath(root) }

        let tree = finderJoin(root, "a")
        XCTAssertTrue(finderCreateDirectory(tree))
        XCTAssertTrue(finderCreateDirectory(finderJoin(tree, "b")))
        let leaf = finderJoin(tree, "b/c.txt")
        let fd = leaf.withCString { open($0, O_CREAT | O_WRONLY, 0o644) }
        XCTAssertGreaterThanOrEqual(fd, 0); close(fd)

        XCTAssertTrue(finderRemovePath(tree))
        XCTAssertFalse(finderExists(tree))
        // Removing something that isn't there fails rather than pretending.
        XCTAssertFalse(finderRemovePath(finderJoin(root, "gone")))
    }

    // MARK: Finder — the real filesystem

    func testReadDirectorySortsAndHidesDotfiles() {
        let base = NSTemporaryDirectoryPath()
        var template = Array((base + "/finder.XXXXXX").utf8CString)
        guard let dir = template.withUnsafeMutableBufferPointer({ buf -> String? in
            mkdtemp(buf.baseAddress!).map { String(cString: $0) }
        }) else { return XCTFail("mkdtemp failed") }
        defer {
            for n in ["beta.txt", ".hidden", "TextEdit.app", "Alpha"] {
                let p = finderJoin(dir, n)
                p.withCString { _ = unlink($0) == 0 || rmdir($0) == 0 }
            }
            dir.withCString { _ = rmdir($0) }
        }

        func write(_ name: String, bytes: Int) {
            let fd = finderJoin(dir, name).withCString { open($0, O_CREAT | O_WRONLY, 0o644) }
            XCTAssertGreaterThanOrEqual(fd, 0)
            let data = [UInt8](repeating: 0x41, count: bytes)
            _ = data.withUnsafeBytes { Glibc.write(fd, $0.baseAddress, bytes) }
            close(fd)
        }
        func makeDir(_ name: String) {
            finderJoin(dir, name).withCString { _ = mkdir($0, 0o755) }
        }
        write("beta.txt", bytes: 1_500)
        write(".hidden", bytes: 3)
        makeDir("Alpha")
        makeDir("TextEdit.app")

        let entries = readDirectory(dir)
        // Alphabetical, case-insensitive, folders interleaved; dot-file hidden.
        XCTAssertEqual(entries.map(\.name), ["Alpha", "beta.txt", "TextEdit.app"])
        XCTAssertEqual(entries[0].kind, .folder)
        XCTAssertEqual(entries[1].kind, .document)
        XCTAssertEqual(entries[1].size, 1_500)
        XCTAssertEqual(entries[2].kind, .application)
        // ... and shown when asked for.
        XCTAssertEqual(readDirectory(dir, showHidden: true).count, 4)
        // An unreadable path lists as empty rather than failing.
        XCTAssertTrue(readDirectory(finderJoin(dir, "nope")).isEmpty)
        // Free space on a real volume is non-zero.
        XCTAssertGreaterThan(finderFreeSpace(dir), 0)
    }
}

/// Delete a directory tree — test cleanup. It's `finderRemovePath` (the Trash's
/// own eraser); the Finder still never unlinks what a *user* deletes, it moves
/// it to the Trash.
private func removeTree(_ path: String) {
    finderRemovePath(path)
}

// A temp dir without importing Foundation (which the toolkit avoids).
private func NSTemporaryDirectoryPath() -> String {
    getenv("TMPDIR").map { String(cString: $0) } ?? "/tmp"
}
