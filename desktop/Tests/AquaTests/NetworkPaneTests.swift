// Network pane tests — a wired interface, by DHCP or by hand (PHASE14 P14.4c).
//
// The form sends what was typed, in the helper's vocabulary (the helper, not
// the pane, decides what is an address); the page says what the kernel has,
// in words; one layout serves paint and hit-test (§2.9).

import XCTest
@testable import Aqua
@testable import AquaDraw
import CurrentIPC
import Settings
import SettingsWire
import Vents

final class NetworkPaneTests: XCTestCase {

    func testAPlanFillsTheFormAndTheFormSendsItBack() {
        let plan = NetworkPlan(interface: "em0",
                               ipv4: .manual(address: IPv4("192.168.1.20")!, prefix: 24, router: IPv4("192.168.1.1")),
                               dns: [IPv4("9.9.9.9")!, IPv4("1.1.1.1")!])
        let f = NetworkForm.from(plan)
        XCTAssertFalse(f.dhcp)
        XCTAssertEqual(f[.netmask], "255.255.255.0", "a prefix is shown as the mask a person types")
        XCTAssertEqual(f[.dns], "9.9.9.9 1.1.1.1")
        // What the form sends decodes, through the helper's own decoder, to the plan it came from.
        guard case .success(.network(let back)) = SettingsWire.decodePlan(f.request("apply")) else {
            return XCTFail("the form's request does not decode")
        }
        XCTAssertEqual(back, plan)
        XCTAssertEqual(f.request("apply").string("method"), "apply")
        XCTAssertEqual(f.request("apply").string("interface"), "em0")
    }

    func testDHCPSendsNoAddressAndTheNameServersAsAList() {
        var f = NetworkForm(interface: "vtnet0")
        f.values = [.address: "10.0.0.5", .dns: " 9.9.9.9,1.1.1.1  "]
        let m = f.request("check")
        XCTAssertEqual(m.string("network.mode"), "dhcp")
        XCTAssertNil(m.string("network.address"), "with DHCP the lease says the address")
        XCTAssertEqual(m.string("network.dns"), "9.9.9.9 1.1.1.1", "commas and runs of spaces are a list")
        guard case .success(.network(let p)) = SettingsWire.decodePlan(m) else { return XCTFail("does not decode") }
        XCTAssertEqual(p.ipv4, .dhcp)
    }

    func testWhatWasTypedIsSentAsTypedForTheHelperToRefuse() {
        var f = NetworkForm(interface: "em0")
        f.setDHCP(false)
        f.focus = .address
        f.type("10.0.0.300")
        guard case .failure(let why) = SettingsWire.decodePlan(f.request("apply")) else {
            return XCTFail("an impossible address was accepted")
        }
        XCTAssertTrue(why.message.contains("10.0.0.300"), why.message)
    }

    func testTypingEditsTheFocusedFieldOnly() {
        var f = NetworkForm(interface: "em0")
        f.type("1")
        XCTAssertEqual(f.values, [:], "no field has focus")
        f.setDHCP(false)
        f.focus = .router
        f.type("10.0.0.1"); f.type("\u{8}"); f.type("\t")
        XCTAssertEqual(f[.router], "10.0.0.1", "control characters are not text")
        f.backspace()
        XCTAssertEqual(f[.router], "10.0.0.")
        f.setDHCP(true)
        XCTAssertNil(f.focus, "the router field is not editable with DHCP, and loses focus")
    }

    func testTabWalksTheEditableFieldsRoundAgain() {
        var f = NetworkForm(interface: "em0")
        f.moveFocus(1)
        XCTAssertEqual(f.focus, .dns, "with DHCP there is one field")
        f.moveFocus(1)
        XCTAssertEqual(f.focus, .dns)
        f.setDHCP(false)
        f.focus = nil
        var seen: [NetworkField] = []
        for _ in 0..<5 { f.moveFocus(1); seen.append(f.focus!) }
        XCTAssertEqual(seen, [.address, .netmask, .router, .dns, .address])
        f.moveFocus(-1)
        XCTAssertEqual(f.focus, .dns)
    }

    func testTheStatusIsSaidInWords() {
        let s = NetworkPaneState.sample.status
        XCTAssertEqual(NetworkWords.choosable(s.interfaces).map(\.name), ["em0", "igc0"], "no loopback")
        let wifi = Vents.Network.Interface(name: "wlan0", up: true, loopback: false, link: .up, ipv4: [],
                                           mac: "02:00:00:00:00:01")
        let pseudo = Vents.Network.Interface(name: "pflog0", up: true, loopback: false, link: .unknown, ipv4: [], mac: nil)
        XCTAssertEqual(NetworkWords.choosable([wifi, pseudo] + s.interfaces).map(\.name), ["em0", "igc0"],
                       "wireless is its own pane, and an interface with no hardware is nobody's")
        let em = Dictionary(uniqueKeysWithValues: NetworkWords.status(s, interface: "em0"))
        XCTAssertEqual(em["Status:"], "Connected")
        XCTAssertEqual(em["IPv4 Address:"], "192.168.1.20/24")
        XCTAssertEqual(em["Router:"], "192.168.1.1")
        let igc = Dictionary(uniqueKeysWithValues: NetworkWords.status(s, interface: "igc0"))
        XCTAssertEqual(igc["Status:"], "Cable unplugged")
        XCTAssertEqual(igc["Router:"], "none through igc0", "the default route is em0's, not this one's")
        XCTAssertEqual(NetworkWords.status(s, interface: "em9").first?.1, "em9 is not on this machine now")
        XCTAssertEqual(NetworkWords.statusLine(s, interface: "em0"),
                       "em0 up link up ipv4 192.168.1.20/24 router 192.168.1.1 via em0 dns 192.168.1.1")
    }

    func testAnOutcomeIsSaidAsWhatHappened() {
        XCTAssertEqual(NetworkWords.outcome(ok: true, error: "", skipped: []), "Applied.")
        XCTAssertEqual(NetworkWords.outcome(ok: true, error: "", skipped: ["write-only"]),
                       "Saved, and not put into effect (write-only).", "a skipped restart is not 'applied'")
        XCTAssertEqual(NetworkWords.outcome(ok: false, error: "em7 is not on this machine", skipped: []),
                       "Not applied: em7 is not on this machine")
    }

    func testOneLayoutForPaintAndHit() {
        let body = Rect(0, 80, 760, 540)
        let l = networkLayout(body: body, interfaces: ["em0", "igc0"])
        var f = NetworkForm(interface: "em0")
        func at(_ r: Rect) -> NetworkHit? { networkHit(l, form: f, x: r.x + r.w / 2, y: r.y + r.h / 2) }
        XCTAssertEqual(at(l.interfaces[1].hit), .interface("igc0"))
        XCTAssertEqual(at(l.manual.hit), .mode(dhcp: false))
        XCTAssertEqual(at(l.dhcp.hit), .mode(dhcp: true))
        XCTAssertNil(at(l.fields[.address]!), "with DHCP the address is not a field")
        XCTAssertEqual(at(l.fields[.dns]!), .field(.dns))
        f.setDHCP(false)
        XCTAssertEqual(at(l.fields[.address]!), .field(.address))
        XCTAssertEqual(at(l.apply), .apply)
        XCTAssertEqual(at(l.revert), .revert)
        XCTAssertLessThan(l.apply.y + l.apply.h, body.y + body.h, "Apply Now is inside the window")
        // Nothing overlaps anything else.
        let rects = l.interfaces.map(\.hit) + [l.status, l.dhcp.hit, l.manual.hit, l.revert, l.apply]
            + NetworkField.allCases.map { l.fields[$0]! }
        for (i, a) in rects.enumerated() {
            for b in rects[(i + 1)...] {
                XCTAssertFalse(a.x < b.x + b.w && b.x < a.x + a.w && a.y < b.y + b.h && b.y < a.y + a.h,
                               "\(a) overlaps \(b)")
            }
        }
    }
}
