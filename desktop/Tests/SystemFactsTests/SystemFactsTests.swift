// System Profiler's facts (fastfetch's report): the parsers, on text captured
// from the FreeBSD guest and on an arm64 board's, and the formatting.

import XCTest
@testable import SystemFacts

final class SystemFactsTests: XCTestCase {
    func testPCIDisplaysNamedAndUnnamed() {
        // The build VM's own `pciconf -lv`: QEMU's VGA has no names in the
        // database — its ids, not nothing — and the NIC is not a display.
        let vm = """
        vgapci0@pci0:0:1:0:\tclass=0x030000 rev=0x02 hdr=0x00 vendor=0x1234 device=0x1111 subvendor=0x1af4 subdevice=0x1100
            class      = display
            subclass   = VGA
        virtio_pci0@pci0:0:2:0:\tclass=0x020000 rev=0x00 hdr=0x00 vendor=0x1af4 device=0x1000 subvendor=0x1af4 subdevice=0x0001
            vendor     = 'Red Hat, Inc.'
            device     = 'Virtio network device'
            class      = network
        """
        XCTAssertEqual(FactParse.pciDisplays(vm), ["PCI display 0x1234:0x1111"])
        let pc = """
        vgapci0@pci0:3:0:0:\tclass=0x030000 rev=0xc1 hdr=0x00 vendor=0x1002 device=0x73df subvendor=0x1849 subdevice=0x5219
            vendor     = 'Advanced Micro Devices, Inc. [AMD/ATI]'
            device     = 'Navi 22 [Radeon RX 6700/6700 XT/6750 XT / 6800M/6850M XT]'
            class      = display
            subclass   = VGA
        """
        XCTAssertEqual(FactParse.pciDisplays(pc), ["AMD Navi 22 [Radeon RX 6700/6700 XT/6750 XT / 6800M/6850M XT]"])
        XCTAssertEqual(FactParse.pciDisplays(""), [], "an SoC: no PCI display at all")
    }

    func testAnSoCsGPUIsItsDRMDriver() {
        let k = " 1   80 0xffff000000000000  2b4e9a8 kernel\n 7    1 0xffff0000ab000000   400000 msm.ko\n"
        XCTAssertEqual(FactParse.drmDriver(kldstat: k), "Qualcomm Adreno (msm)")
        XCTAssertNil(FactParse.drmDriver(kldstat: " 1 80 0x0 1 kernel\n"))
    }

    func testABoardsModelFromItsDeviceTree() {
        XCTAssertEqual(FactParse.ofwModel("Node 0x38:\n  model:\n    'Radxa Dragon Q8B'\n"), "Radxa Dragon Q8B")
        XCTAssertNil(FactParse.ofwModel(""))
    }

    func testSwapOneDeviceSeveralAndNone() {
        let one = "Device          1K-blocks     Used    Avail Capacity\n/dev/gpt/swapfs   1048576        0  1048576     0%\n"
        XCTAssertEqual(FactParse.swap(swapinfo: one)?.total, 1048576 * 1024)
        XCTAssertEqual(FactParse.swap(swapinfo: one)?.used, 0)
        let two = """
        Device          1K-blocks     Used    Avail Capacity
        /dev/ada0p3       2097152   524288  1572864    25%
        /dev/ada1p3       2097152        0  2097152     0%
        Total             4194304   524288  3670016    13%
        """
        XCTAssertEqual(FactParse.swap(swapinfo: two)?.total, 4194304 * 1024)
        XCTAssertEqual(FactParse.swap(swapinfo: two)?.used, 524288 * 1024)
        XCTAssertNil(FactParse.swap(swapinfo: "Device          1K-blocks     Used    Avail Capacity\n"))
    }

    func testMemoryCountsWhatIsNeitherFreeNorIdle() {
        // The guest's own counts: 4080261 pages, 2282077 free, 364488 inactive, 23 laundry.
        let used = FactParse.memoryUsed(pageSize: 4096, pages: 4080261, free: 2282077, inactive: 364488, laundry: 23)
        XCTAssertEqual(used, (4080261 - 2282077 - 364488 - 23) * 4096)
        XCTAssertEqual(FactParse.memoryUsed(pageSize: 4096, pages: 10, free: 20, inactive: 0), 0)
    }

    func testFastfetchsFormatting() {
        XCTAssertEqual(FactFormat.bytes(0), "0 B")
        XCTAssertEqual(FactFormat.bytes(1536), "1.50 KiB")
        XCTAssertEqual(FactFormat.bytes(16_706_928_640), "15.56 GiB")
        XCTAssertEqual(FactFormat.usage(used: 1 << 30, total: 4 << 30), "1.00 GiB / 4.00 GiB (25%)")
        XCTAssertEqual(FactFormat.uptime(seconds: 0), "0 mins")
        XCTAssertEqual(FactFormat.uptime(seconds: 86400 + 46 * 60), "1 day, 46 mins")
        XCTAssertEqual(FactFormat.uptime(seconds: 2 * 86400 + 3 * 3600 + 60), "2 days, 3 hours, 1 min")
        XCTAssertEqual(FactFormat.frequency(mhz: 2710), "2.71 GHz")
        XCTAssertEqual(FactFormat.frequency(mhz: 800), "800 MHz")
    }

    func testTheReportSaysUnknownRatherThanLeavingOut() {
        let f = SystemFacts(title: "ada@jaguar", facts: [Fact(.hardware, "CPU", "x"), Fact(.hardware, "Battery", nil)])
        XCTAssertEqual(f.text, "ada@jaguar\n----------\nCPU: x\nBattery: unknown\n")
    }

    func testBootTimeIsATimeval() {
        var tv: (Int64, Int64) = (1_790_000_000, 123)
        let bytes = withUnsafeBytes(of: &tv) { Array($0) }
        XCTAssertEqual(FactParse.bootSeconds(timeval: bytes), 1_790_000_000)
        XCTAssertNil(FactParse.bootSeconds(timeval: [1, 2]))
    }
}
