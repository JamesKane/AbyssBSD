// Off is one file, absent (PHASE18 P18.13).

import XCTest
@testable import PoolConfig
#if canImport(Glibc)
import Glibc
#endif

final class AgentsOnOffTests: XCTestCase {
    func testOffIsTheFileAbsent() throws {
        var t = Array("/tmp/abyss-agents-XXXXXX".utf8CString)
        let dir = String(cString: mkdtemp(&t)!)
        defer { unlink(dir + "/agents.ini"); rmdir(dir) }
        XCTAssertFalse(Agents.on(configDir: dir), "a new account has no agents")
        XCTAssertNil(Agents.set(true, configDir: dir))
        XCTAssertTrue(Agents.on(configDir: dir))
        XCTAssertNil(Agents.set(true, configDir: dir), "on twice is on")
        var st = stat(); stat(dir + "/agents.ini", &st)
        XCTAssertEqual(st.st_mode & 0o777, 0o600)
        XCTAssertNil(Agents.set(false, configDir: dir))
        XCTAssertFalse(Agents.on(configDir: dir))
        XCTAssertNil(Agents.set(false, configDir: dir), "off twice is off")
    }

    func testTheChordIsADefault() {
        XCTAssertTrue(DesktopKeys.defaults.contains { $0 == ("Cmd+Alt+A", "agent") })
    }
}
