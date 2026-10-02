// The fetch bridge (PHASE18 P18.12b): a host the person allowed, never this
// computer's own, redirects asked about too, and pages as text.

import XCTest
@testable import Fetch
@testable import Model

final class FetchTests: XCTestCase {
    func page(_ status: Int, _ body: String, type: String = "text/html", location: String? = nil) -> HTTPResponse {
        var h: [(String, String)] = [("Content-Type", type)]
        if let location { h.append(("Location", location)) }
        return HTTPResponse(status: status, reason: "", headers: h, body: Array(body.utf8))
    }
    let publicDNS: (String) -> [String] = { h in h == "home.lan" ? ["192.168.1.5"] : ["93.184.215.14"] }

    func testANewHostIsAskedAboutFirst() {
        var got: [String] = [], logged: [String] = []
        let b = FetchBridge(resolve: publicDNS, get: { u in got.append(u.text); return self.page(200, "<p>hello</p>") },
                            log: { k, _ in logged.append(k) })
        XCTAssertEqual(b.fetch("https://example.org/a"), .ask(host: "example.org", url: "https://example.org/a"))
        XCTAssertTrue(got.isEmpty, "nothing is fetched before the person answers")
        b.permit("example.org", allow: false)
        XCTAssertEqual(b.fetch("https://example.org/a"), .ask(host: "example.org", url: "https://example.org/a"),
                       "Don't Allow is not remembered: asked again")
        b.permit("Example.ORG", allow: true)
        XCTAssertEqual(b.fetch("https://example.org/a"), .page(url: "https://example.org/a", status: 200, text: "hello"))
        XCTAssertEqual(logged, ["asked", "denied", "asked", "permitted", "fetched"])
    }

    func testThisComputersOwnAddressesAreRefused() {
        let b = FetchBridge(resolve: { h in h == "localhost" ? ["127.0.0.1"] : self.publicDNS(h) }, get: { _ in XCTFail("fetched"); return self.page(200, "") })
        b.permit("localhost", allow: true); b.permit("home.lan", allow: true)
        guard case .refused(let why) = b.fetch("http://localhost:631/") else { return XCTFail("loopback reached") }
        XCTAssertTrue(why.contains("this computer's or a private network's (127.0.0.1)"))
        guard case .refused = b.fetch("http://home.lan/") else { return XCTFail("a private network reached") }
        XCTAssertEqual(FetchBridge(allowLocal: true, resolve: { _ in ["127.0.0.1"] }, get: { _ in self.page(200, "ok", type: "text/plain") })
            .fetchAllowed("http://127.0.0.1:9/"), .page(url: "http://127.0.0.1:9/", status: 200, text: "ok"), "a test may")
    }

    func testARedirectToANewHostIsAskedAboutToo() {
        let b = FetchBridge(resolve: publicDNS, get: { u in
            u.host == "a.org" ? self.page(301, "", location: "https://b.org/x") : self.page(200, "B", type: "text/plain")
        })
        b.permit("a.org", allow: true)
        XCTAssertEqual(b.fetch("https://a.org/"), .ask(host: "b.org", url: "https://b.org/x"))
        b.permit("b.org", allow: true)
        XCTAssertEqual(b.fetch("https://a.org/"), .page(url: "https://b.org/x", status: 200, text: "B"))
    }

    func testRedirectsEnd() {
        let b = FetchBridge(resolve: publicDNS, get: { _ in self.page(302, "", location: "/again") })
        b.permit("a.org", allow: true)
        XCTAssertEqual(b.fetch("https://a.org/"), .refused("too many redirects"))
        XCTAssertEqual(b.fetch("ftp://a.org/"), .refused("not an http or https URL: ftp://a.org/"))
    }

    func testAPageIsItsWords() {
        let html = "<html><head><title>T</title><style>p{}</style><script>alert(1)</script></head>"
            + "<body><h1>Head</h1><p>One &amp; two</p><p>  three\n   four </p></body></html>"
        XCTAssertEqual(PageText.from(html, contentType: "text/html; charset=utf-8"), "T\nHead\nOne & two\nthree\nfour")
        XCTAssertEqual(PageText.from("<b>raw</b>", contentType: "text/plain"), "<b>raw</b>")
        XCTAssertTrue(PageText.from(String(repeating: "x", count: 20000), contentType: "text/plain").hasSuffix("(cut at 16 KB)"))
    }

    func testWhatIsLocal() {
        for ip in ["127.0.0.1", "10.1.2.3", "172.16.0.1", "172.31.255.255", "192.168.0.2", "169.254.1.1", "0.0.0.0",
                   "100.64.0.1", "::1", "fe80::1", "fd00::1", "::ffff:127.0.0.1"] {
            XCTAssertTrue(Addresses.isLocal(ip), ip)
        }
        for ip in ["93.184.215.14", "172.32.0.1", "8.8.8.8", "2606:2800:220:1::1"] { XCTAssertFalse(Addresses.isLocal(ip), ip) }
    }

    func testTheDigestSaysFetches() {
        let lines = Transcript.lines("""
        {"t":1,"kind":"fetch","event":"asked","host":"example.org","url":"https://example.org/"}
        {"t":2,"kind":"fetch","event":"permitted","host":"example.org"}
        {"t":3,"kind":"fetch","event":"fetched","url":"https://example.org/","status":200,"bytes":513}
        """)
        XCTAssertEqual(Transcript.digest(lines).map { String($0.dropFirst(10)) }, [
            "The agent asked to reach example.org (https://example.org/)",
            "You allowed the agent to reach example.org",
            "  Fetched https://example.org/ (200, 513 bytes)",
        ])
    }
}

extension FetchBridge {
    /// For the allow-local check: everything allowed, as a test's bridge is.
    func fetchAllowed(_ url: String) -> FetchAnswer {
        if let u = WebURL(url) { permit(u.host, allow: true) }
        return fetch(url)
    }
}
