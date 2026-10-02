// The desktop's own applications as bundles (P18.13 loose ends).

import XCTest
@testable import AppBundles

final class BuiltinAppTests: XCTestCase {
    func testJaguarsLayout() {
        let at = Dictionary(uniqueKeysWithValues: BuiltinApp.all.map { ($0.name, $0.folder) })
        XCTAssertEqual(at["Finder"], .some(nil), "the Finder lived in CoreServices: no bundle")
        for n in ["System Preferences", "TextEdit", "Agent"] { XCTAssertEqual(at[n], "", n) }
        for n in ["Terminal", "Grab", "Activity Monitor", "Disk Utility", "System Profiler"] { XCTAssertEqual(at[n], "Utilities", n) }
        XCTAssertEqual(Set(BuiltinApp.all.map(\.token)).count, BuiltinApp.all.count, "one token each")
    }

    func testALauncherRunsTheShellInItsScene() {
        let t = BuiltinApp.all.first { $0.token == "diskutility" }!
        XCTAssertEqual(t.launcher(binary: "/opt/ade bin/AquaDemo").split(separator: "\n").last,
                       "AQUA_SCENE=diskutility exec '/opt/ade bin/AquaDemo' \"$@\"", "the path quoted; the files handed on")
        XCTAssertEqual(t.themeIcon, "dock.icon.diskutility")
        XCTAssertEqual(t.marker, "builtin:diskutility")
    }
}
