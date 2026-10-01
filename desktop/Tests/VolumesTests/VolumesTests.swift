// Volumes tests (PHASE15 P15.8): `zfs list` as the guest really prints it.

import XCTest
@testable import Volumes

final class VolumesTests: XCTestCase {
    /// Captured from the 16-CURRENT build guest (`-H -p`: tabs, exact numbers).
    let datasets = """
    zroot\t42719010816\t45561032704\tnone\tno
    zroot/ROOT\t13056704512\t45561032704\tnone\tno
    zroot/ROOT/default\t13056270336\t45561032704\t/\tyes
    zroot/home\t6774800384\t45561032704\t/home\tyes
    zroot/usr/obj\t430080\t45561032704\t/usr/obj\tyes
    """

    func testDatasetsAreParsedWithTheirMountpointsAndDepth() {
        let d = ZFSList.datasets(datasets)
        XCTAssertEqual(d.count, 5)
        XCTAssertEqual(d[2].name, "zroot/ROOT/default")
        XCTAssertEqual(d[2].mountpoint, "/")
        XCTAssertTrue(d[2].mounted)
        XCTAssertEqual(d[2].depth, 2)
        XCTAssertEqual(d[2].leaf, "default")
        XCTAssertEqual(d[0].pool, "zroot")
        XCTAssertFalse(d[0].mountable, "`none` is nowhere")
        XCTAssertEqual(d[3].used, 6_774_800_384)
        XCTAssertTrue(ZFSList.datasets("garbage\nzroot\tx\ty\tnone\tno\n").isEmpty, "a line that is not five fields of numbers")
    }

    func testSnapshotsAreOldestFirstAndKnowTheirDataset() {
        let s = ZFSList.snapshots("""
        zroot/home@b\t1759300000\t4096
        zroot/home@a\t1759200000\t8192
        zroot/usr@x\t1759250000\t0
        """)
        XCTAssertEqual(s.map(\.short), ["a", "x", "b"])
        XCTAssertEqual(s[0].dataset, "zroot/home")
        var st = Volumes.State(); st.snapshots = s
        XCTAssertEqual(st.snapshots(of: "zroot/home").map(\.short), ["a", "b"])
    }

    func testASnapshotIsNamedForWhenItWasTaken() {
        XCTAssertEqual(Volumes.snapshotName(year: 2026, month: 10, day: 1, hour: 9, minute: 5, second: 7),
                       "abyss-2026-10-01-090507")
    }
}
