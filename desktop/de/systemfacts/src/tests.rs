//! SystemFactsTests.swift, ported: the parsers, on text captured from the
//! FreeBSD guest and an arm64 board, and the formatting.

use super::*;

#[test]
fn pci_displays_named_and_unnamed() {
    // The build VM's own `pciconf -lv`: QEMU's VGA has no names in the
    // database, so its ids; and the NIC is not a display.
    let vm = "vgapci0@pci0:0:1:0:\tclass=0x030000 rev=0x02 hdr=0x00 vendor=0x1234 device=0x1111 subvendor=0x1af4 subdevice=0x1100
    class      = display
    subclass   = VGA
virtio_pci0@pci0:0:2:0:\tclass=0x020000 rev=0x00 hdr=0x00 vendor=0x1af4 device=0x1000 subvendor=0x1af4 subdevice=0x0001
    vendor     = 'Red Hat, Inc.'
    device     = 'Virtio network device'
    class      = network";
    assert_eq!(parse::pci_displays(vm), ["PCI display 0x1234:0x1111"]);
    let pc = "vgapci0@pci0:3:0:0:\tclass=0x030000 rev=0xc1 hdr=0x00 vendor=0x1002 device=0x73df subvendor=0x1849 subdevice=0x5219
    vendor     = 'Advanced Micro Devices, Inc. [AMD/ATI]'
    device     = 'Navi 22 [Radeon RX 6700/6700 XT/6750 XT / 6800M/6850M XT]'
    class      = display
    subclass   = VGA";
    assert_eq!(parse::pci_displays(pc), ["AMD Navi 22 [Radeon RX 6700/6700 XT/6750 XT / 6800M/6850M XT]"]);
    assert!(parse::pci_displays("").is_empty(), "an SoC: no PCI display at all");
    // CRLF reads as its lines (to Swift, CRLF is one Character).
    assert_eq!(parse::pci_displays(&pc.replace('\n', "\r\n")).len(), 1);
}

#[test]
fn an_socs_gpu_is_its_drm_driver() {
    let k = " 1   80 0xffff000000000000  2b4e9a8 kernel\n 7    1 0xffff0000ab000000   400000 msm.ko\n";
    assert_eq!(parse::drm_driver(k), Some("Qualcomm Adreno (msm)"));
    assert_eq!(parse::drm_driver(" 1 80 0x0 1 kernel\n"), None);
}

#[test]
fn a_boards_model_from_its_device_tree() {
    assert_eq!(parse::ofw_model("Node 0x38:\n  model:\n    'Radxa Dragon Q8B'\n"), Some("Radxa Dragon Q8B"));
    assert_eq!(parse::ofw_model(""), None);
}

#[test]
fn swap_one_device_several_and_none() {
    let one = "Device          1K-blocks     Used    Avail Capacity\n/dev/gpt/swapfs   1048576        0  1048576     0%\n";
    assert_eq!(parse::swap(one), Some((0, 1048576 * 1024)));
    let two = "Device          1K-blocks     Used    Avail Capacity
/dev/ada0p3       2097152   524288  1572864    25%
/dev/ada1p3       2097152        0  2097152     0%
Total             4194304   524288  3670016    13%";
    assert_eq!(parse::swap(two), Some((524288 * 1024, 4194304 * 1024)));
    assert_eq!(parse::swap("Device          1K-blocks     Used    Avail Capacity\n"), None);
    assert_eq!(parse::swap("/dev/x 18446744073709551615 0 0 0%"), None, "Swift traps here");
}

#[test]
fn memory_counts_what_is_neither_free_nor_idle() {
    let used = parse::memory_used(4096, 4080261, 2282077, 364488, 23);
    assert_eq!(used, (4080261 - 2282077 - 364488 - 23) * 4096);
    assert_eq!(parse::memory_used(4096, 10, 20, 0, 0), 0);
    assert_eq!(parse::memory_used(4096, u64::MAX, u64::MAX, u64::MAX, 1), 0, "Swift traps here");
}

#[test]
fn fastfetchs_formatting() {
    assert_eq!(format::bytes(0), "0 B");
    assert_eq!(format::bytes(1023), "1023 B");
    assert_eq!(format::bytes(1536), "1.50 KiB");
    assert_eq!(format::bytes(16_706_928_640), "15.56 GiB");
    assert_eq!(format::usage(1 << 30, 4 << 30), "1.00 GiB / 4.00 GiB (25%)");
    assert_eq!(format::uptime(0), "0 mins");
    assert_eq!(format::uptime(86400 + 46 * 60), "1 day, 46 mins");
    assert_eq!(format::uptime(2 * 86400 + 3 * 3600 + 60), "2 days, 3 hours, 1 min");
    assert_eq!(format::frequency(2710), "2.71 GHz");
    assert_eq!(format::frequency(800), "800 MHz");
}

#[test]
fn the_report_says_unknown_rather_than_leaving_out() {
    let f = SystemFacts { title: "ada@jaguar".into(), facts: vec![Fact::new(Section::Hardware, "CPU", Some("x")), Fact::new(Section::Hardware, "Battery", None)] };
    assert_eq!(f.text(), "ada@jaguar\n----------\nCPU: x\nBattery: unknown\n");
    assert_eq!(SystemFacts::sample().value("GPU"), Some("Qualcomm Adreno (msm)"));
    assert_eq!(SystemFacts::sample().value("Battery"), None);
}

#[test]
fn boot_time_is_a_timeval() {
    let mut tv = 1_790_000_000i64.to_ne_bytes().to_vec();
    tv.extend(123i64.to_ne_bytes());
    assert_eq!(parse::boot_seconds(&tv), Some(1_790_000_000));
    assert_eq!(parse::boot_seconds(&[1, 2]), None);
}
