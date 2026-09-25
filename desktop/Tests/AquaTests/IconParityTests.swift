import XCTest
import CCairo
@testable import AquaDraw
@testable import Aqua

/// PHASE11 P11.8: every icon list is byte-identical to the Swift painter it
/// replaced (frozen in IconReference.swift) — at the sizes the desktop draws
/// them, at integer and fractional positions, at 1× and 2×.
final class IconParityTests: XCTestCase {
    private var lists: DrawListFile!

    override func setUpWithError() throws {
        let here = String(#filePath[..<#filePath.lastIndex(of: "/")!])
        var all = DrawListFile(lists: [:])
        for f in ["prefs", "finder", "dock"] {
            let text = try XCTUnwrap(ThemeLoader.readFile(here + "/../../themes/aqua/icons/\(f).dl"), f)
            all = all.merging(try DrawListFile(parsing: text))
        }
        lists = all
    }
    override func tearDown() { Text.renderScale = 1 }

    private func same(_ what: String, _ a: (OpaquePointer) -> Void, _ b: (OpaquePointer) -> Void,
                      file: StaticString = #filePath, line: UInt = #line) {
        for scale in [1, 2] {
            Text.renderScale = Int32(scale)
            func paint(_ f: (OpaquePointer) -> Void) -> [UInt8] {
                let s = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, 80 * Int32(scale), 80 * Int32(scale))!
                let cr = cairo_create(s)!
                cairo_scale(cr, Double(scale), Double(scale))
                cairo_set_source_rgb(cr, 0.93, 0.91, 0.87); cairo_paint(cr)
                cairo_set_line_width(cr, 1)
                f(cr)
                cairo_surface_flush(s)
                let n = Int(cairo_image_surface_get_stride(s)) * 80 * scale
                let out = Array(UnsafeBufferPointer(start: cairo_image_surface_get_data(s)!, count: n))
                cairo_destroy(cr); cairo_surface_destroy(s)
                return out
            }
            let pa = paint(a), pb = paint(b)
            let differ = zip(pa, pb).filter { $0 != $1 }.count
            XCTAssertEqual(differ, 0, "\(what) at \(scale)×: \(differ) bytes differ", file: file, line: line)
        }
    }

    private func run(_ name: String, _ cr: OpaquePointer, _ r: Rect) {
        guard let l = lists[name] else { return XCTFail("no list \(name)") }
        cairo_new_path(cr)
        DrawListRunner.run(l, cr, DrawContext(rect: r))
    }

    private let boxes = [Rect(10, 10, 48, 48), Rect(10.5, 20.5, 32, 32), Rect(3, 3, 16, 16),
                         Rect(20.25, 30.75, 14, 14), Rect(4, 40, 24, 24)]

    private let prefIcons: [(PrefIcon, String)] = [
        (.showAll, "showAll"), (.dock, "dock"), (.displays, "displays"), (.desktop, "desktop"),
        (.sound, "sound"), (.network, "network"), (.international, "international"),
        (.internetIcon, "internetIcon"), (.startupDisk, "startupDisk"), (.general, "general"),
        (.loginItems, "loginItems"), (.myAccount, "myAccount"), (.universalAccess, "universalAccess"),
        (.accounts, "accounts"), (.screenEffects, "screenEffects"), (.cdsDvds, "cdsDvds"),
        (.colorSync, "colorSync"), (.energySaver, "energySaver"), (.keyboard, "keyboard"),
        (.mouse, "mouse"), (.sharing, "sharing"), (.dateTime, "dateTime"),
        (.softwareUpdate, "softwareUpdate"), (.speech, "speech"), (.quicktime, "quicktime"),
        (.classic, "classic"),
    ]

    func testPreferenceIcons() {
        for (icon, name) in prefIcons {
            for b in boxes {
                same("icon.\(name) \(b)", { IconsRef.draw($0, icon, in: b) }, { self.run("icon." + name, $0, b) })
            }
        }
    }

    func testFinderIcons() {
        let kinds: [(String, (OpaquePointer, Rect) -> Void)] = [
            ("folder", refDrawFolderIcon), ("document", refDrawDocumentIcon),
            ("application", refDrawAppIcon), ("disk", refDrawDiskIcon),
        ]
        for (name, ref) in kinds {
            for b in boxes {
                let list = b.w < 24 && lists["icon.\(name).small"] != nil ? "icon.\(name).small" : "icon.\(name)"
                same("\(list) \(b)", { cr in cairo_new_path(cr); ref(cr, b) }, { self.run(list, $0, b) })
            }
        }
    }

    func testDockIcons() {
        let kinds: [(DockIcon, String)] = [(.finder, "finder"), (.browser, "browser"), (.mail, "mail"),
                                            (.music, "music"), (.prefs, "prefs"), (.genericApp, "genericApp"),
                                            (.trash, "trash"), (.trashFull, "trashFull")]
        for (kind, name) in kinds {
            for b in [Rect(10, 10, 48, 48), Rect(12.5, 8.25, 64, 64), Rect(3, 3, 32, 32)] {
                same("dock.icon.\(name) \(b)", { cr in cairo_new_path(cr); refDrawDockIcon(cr, kind, b) },
                     { self.run("dock.icon." + name, $0, b) })
            }
        }
    }
}
