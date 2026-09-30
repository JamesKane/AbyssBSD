// Wi-Fi page tests (PHASE14 P14.5c): status in words, the layout for paint
// and hit, and the ifconfig parser the status comes from.

import XCTest
@testable import Aqua
@testable import AquaDraw
import Settings
import Vents

final class WifiPaneTests: XCTestCase {
    func testStatusIsReadFromIfconfig() {
        let text = """
        wlan0: flags=8843<UP,BROADCAST,RUNNING,SIMPLEX,MULTICAST> metric 0 mtu 1500
        \tether 00:98:9a:98:96:98
        \tgroups: wlan
        \tssid "Café Wi-Fi 5G" channel 40 (5200 MHz 11a ht/20) bssid aa:bb:cc:dd:ee:02
        \tregdomain FCC country US authmode WPA2/802.11i privacy ON
        \tstatus: associated
        """
        let s = Vents.Wifi.parseIfconfig(text, interface: "wlan0")
        XCTAssertTrue(s.associated)
        XCTAssertEqual(s.ssid, "Café Wi-Fi 5G", "a quoted name keeps its spaces")
        XCTAssertEqual(s.channel, 40)
        XCTAssertEqual(s.bssid, "aa:bb:cc:dd:ee:02")
        let plain = Vents.Wifi.parseIfconfig("\tssid abyss-lab channel 1 (2412 MHz 11b) bssid 00:98:9a:98:96:97\n\tstatus: no carrier\n", interface: "wlan0")
        XCTAssertEqual(plain.ssid, "abyss-lab")
        XCTAssertFalse(plain.associated)
    }

    func testThePageInWords() {
        XCTAssertEqual(WifiWords.status(WifiPaneState.sample.status), "Associated with “Home”, channel 6")
        XCTAssertEqual(WifiWords.status(Vents.Wifi.Status(interface: "wlan0", exists: false)),
                       "Not set up: this radio has no wlan interface yet")
        XCTAssertEqual(WifiWords.statusLine(.sample), "iwn0 wlan0 associated Home known Home,Café Wi-Fi")
        XCTAssertEqual(WifiWords.bars(-41), 3)
        XCTAssertEqual(WifiWords.bars(-65), 2)
        XCTAssertEqual(WifiWords.bars(-85), 1)
        XCTAssertEqual(WifiWords.bars(10), 2, "wtap's S of 10 reads as -60 dBm: fair, not full")
    }

    func testOneLayoutForPaintAndHit() {
        let s = WifiPaneState.sample
        let l = wifiLayout(body: Rect(0, 80, 760, 540), top: 140, s)
        func at(_ r: Rect) -> WifiHit? { wifiHit(l, s, x: r.x + r.w / 2, y: r.y + r.h / 2) }
        XCTAssertEqual(at(l.scan), .scan)
        XCTAssertEqual(at(l.networks[2]), .network("Library"))
        XCTAssertEqual(at(l.field), .field)
        XCTAssertEqual(at(l.join), .join)
        XCTAssertEqual(at(l.forgets[1]), .forget("Café Wi-Fi"))
        XCTAssertLessThan(l.noteBaseline, 620)
    }
}
