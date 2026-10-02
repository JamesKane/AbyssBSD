// Our protocols' versions, both ends (HANDOFF §2.117).
//
// The compositor offers what its XML says; a client binds at most what
// `Display.ourVersions` says it handles. Bump one without the other and the
// new events never come, and nothing says so: it happened in P13.4 and again
// in P18.13b. This holds the client's cap to the XML.

import XCTest
import Surface
#if canImport(Glibc)
import Glibc
#endif

final class ProtocolVersionTests: XCTestCase {
    func testTheClientBindsEveryVersionTheXMLDefines() throws {
        let root = String(#filePath).split(separator: "/").dropLast(3).joined(separator: "/")
        var found: [String: UInt32] = [:]
        for file in ["abyss-menu-v1.xml", "abyss-window-v1.xml"] {
            guard let f = fopen("/" + root + "/protocols/" + file, "r") else { return XCTFail("cannot read \(file)") }
            var buf = [CChar](repeating: 0, count: 4096)
            while fgets(&buf, Int32(buf.count), f) != nil {
                let line = String(cString: buf)
                guard let n = line.range(of: "<interface name=\""), let v = line.range(of: "version=\"") else { continue }
                let name = line[n.upperBound...].prefix { $0 != "\"" }
                let version = line[v.upperBound...].prefix { $0 != "\"" }
                found[String(name)] = UInt32(version)
            }
            fclose(f)
        }
        XCTAssertFalse(found.isEmpty)
        for (name, cap) in Display.ourVersions {
            XCTAssertEqual(cap, found[name], "\(name): the client binds v\(cap); the XML defines v\(found[name].map(String.init) ?? "?")")
        }
    }
}
