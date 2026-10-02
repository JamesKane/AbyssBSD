// URLs as the fetch bridge takes them (PHASE18 P18.12a).

import XCTest
@testable import Model

final class WebURLTests: XCTestCase {
    func testWhatAURLIs() {
        let u = WebURL("https://Example.org/docs/a?b=1#top")!
        XCTAssertTrue(u.https)
        XCTAssertEqual(u.host, "example.org", "a host compares without case")
        XCTAssertEqual(u.port, 443)
        XCTAssertEqual(u.path, "/docs/a?b=1", "the fragment is the reader's, not the server's")
        XCTAssertEqual(WebURL("http://h:8080")?.path, "/")
        XCTAssertEqual(WebURL("http://h:8080")?.port, 8080)
        XCTAssertEqual(WebURL("http://h?x=1")?.path, "/?x=1")
        XCTAssertEqual(WebURL("https://h:443/p")?.text, "https://h/p")
    }

    func testWhatItIsNot() {
        for bad in ["ftp://h/", "file:///etc/passwd", "https://", "https://user:pw@h/", "https://h:0/", "https://h:99999/",
                    "https://h_x/", "https://h x/", "example.org"] {
            XCTAssertNil(WebURL(bad), bad)
        }
        XCTAssertNil(WebURL("https://evil.com@good.com/"), "userinfo is refused: the host is not what it looks like")
    }

    func testARedirectResolvesAgainstItsPage() {
        let u = WebURL("https://a.org/x")!
        XCTAssertEqual(u.resolve("/y")?.text, "https://a.org/y")
        XCTAssertEqual(u.resolve("https://b.org/z")?.host, "b.org")
        XCTAssertNil(u.resolve("relative"), "only absolute paths and URLs")
    }
}
