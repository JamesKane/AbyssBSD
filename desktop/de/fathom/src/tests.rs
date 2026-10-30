//! FathomTests.swift, ported. **For every probe the absent case comes
//! first**: a suite proves nothing by saying "ok" on a machine that has the
//! hardware. Fixtures are captured from the build VM, never invented.

use super::report::mark;
use super::*;
use ProbeStatus::{Absent, Present, Unknown};

/// `cat /dev/sndstat` on a machine with no sound card: prose, not a missing
/// file.
const SNDSTAT_NONE: &str = "No devices installed.\nNo devices installed from userspace.";

/// `kldstat` in the build VM: a kernel, zfs, and nothing graphical.
const KLDSTAT_NO_GRAPHICS: &str = "Id Refs Address                Size Name
 1   25 0xffffffff80200000  1f4dcd8 kernel
 2    1 0xffffffff8214e000   620f30 zfs.ko
 3    1 0xffffffff83018000     4250 ichsmb.ko
 4    1 0xffffffff8301d000     2178 smbus.ko
 5    1 0xffffffff83200000   340438 vmm.ko
 6    1 0xffffffff83020000     21dc nmdm.ko";

fn kldstat_with_amdgpu() -> String {
    KLDSTAT_NO_GRAPHICS.to_owned() + "\n 7    1 0xffffffff83400000   b2f000 amdgpu.ko\n 8    3 0xffffffff83100000    5a000 drm.ko"
}

fn r(name: &str, s: ProbeStatus, d: &str) -> ProbeResult {
    ProbeResult::new(name, s, d)
}

// MARK: absent: the answers the build VM gives

#[test]
fn no_gpu_is_absent_and_says_why() {
    let r = probe_gpu(Some(&[]));
    assert_eq!(r.status, Absent);
    assert!(r.detail.contains("card"), "{}", r.detail);
}

#[test]
fn a_render_node_alone_is_not_a_display() {
    let r = probe_gpu(Some(&["renderD128"]));
    assert_eq!(r.status, Absent);
    assert!(r.detail.contains("not a display"), "{}", r.detail);
}

#[test]
fn no_wifi_is_absent_from_an_empty_string_not_a_missing_sysctl() {
    assert_eq!(probe_wifi(Some(""), None).status, Absent);
    assert_eq!(probe_wifi(Some("   "), None).status, Absent);
}

#[test]
fn no_audio_is_absent_and_the_sentence_is_parsed() {
    assert_eq!(probe_audio(Some(SNDSTAT_NONE)).status, Absent);
}

#[test]
fn no_graphics_modules_is_absent() {
    assert_eq!(probe_modules(Some(KLDSTAT_NO_GRAPHICS)).status, Absent);
}

#[test]
fn no_battery_is_absent_not_unknown() {
    let r = probe_battery(None, false, true);
    assert_eq!(r.status, Absent);
    assert!(r.detail.contains("mains"), "{}", r.detail);
}

#[test]
fn only_loopback_is_absent() {
    assert_eq!(probe_network(Some("lo0")).status, Absent);
}

// MARK: unknown is not absent (§6.1)

#[test]
fn every_probe_separates_could_not_ask_from_is_not_there() {
    assert_eq!(probe_gpu(None).status, Unknown);
    assert_eq!(probe_wifi(None, None).status, Unknown);
    assert_eq!(probe_audio(None).status, Unknown);
    assert_eq!(probe_modules(None).status, Unknown);
    assert_eq!(probe_network(None).status, Unknown);
    assert_eq!(probe_boot_method(None, None).status, Unknown);
    assert_eq!(probe_machine(None, None).status, Unknown);
    assert_eq!(probe_cpu(None, None).status, Unknown);
    assert_eq!(probe_memory(None).status, Unknown);
}

#[test]
fn a_battery_that_will_not_answer_is_unknown_not_empty() {
    assert_eq!(probe_battery(None, true, true).status, Unknown);
    assert_eq!(probe_battery(Some(250), true, true).status, Unknown);
}

#[test]
fn half_an_identity_is_not_an_identity() {
    assert_eq!(probe_machine(Some("Apple Inc."), Some("")).status, Unknown);
    assert_eq!(probe_machine(Some(""), Some("MacPro6,1")).status, Unknown);
}

// MARK: present: the positive control

#[test]
fn the_probes_can_also_say_yes() {
    assert_eq!(probe_gpu(Some(&["card0", "renderD128"])).status, Present);
    assert_eq!(probe_wifi(Some("wlan0"), None).status, Present);
    assert_eq!(probe_network(Some("igc0 lo0")).status, Present);
    assert_eq!(probe_modules(Some(&kldstat_with_amdgpu())).status, Present);
    assert_eq!(probe_battery(Some(87), true, true).status, Present);
}

#[test]
fn the_gpu_report_names_the_card() {
    let r = probe_gpu(Some(&["card0", "renderD128"]));
    assert_eq!(r.detail, "card0 (+ renderD128)");
}

#[test]
fn audio_names_the_devices_it_found() {
    let stat = "Installed devices:\npcm0: <Realtek ALC1220 (Rear Analog)> (play/rec) default\npcm1: <Realtek ALC1220 (Front Analog)> (play/rec)";
    let r = probe_audio(Some(stat));
    assert_eq!(r.status, Present);
    assert_eq!(r.detail, "pcm0, pcm1");
}

#[test]
fn both_boot_methods_are_an_answer_and_neither_is_a_failure() {
    assert_eq!(probe_boot_method(Some("UEFI"), None).status, Present);
    assert_eq!(probe_boot_method(Some("BIOS"), None).status, Present);
    assert!(probe_boot_method(Some("BIOS"), None).detail.contains("legacy"));
    assert_eq!(probe_boot_method(Some("something else"), None).status, Unknown);
}

#[test]
fn cpu_and_memory_render_for_a_person() {
    assert_eq!(probe_cpu(Some("AMD Ryzen 7 9700X 8-Core Processor   "), Some(8)).detail, "AMD Ryzen 7 9700X 8-Core Processor (8 cores)");
    assert_eq!(probe_memory(Some(17_135_251_456)).detail, "15.9 GiB");
    assert_eq!(probe_memory(Some(i64::MAX)).detail, "8589934591.9 GiB", "Swift traps here");
}

// MARK: the report

#[test]
fn the_summary_names_unknowns_instead_of_letting_them_blend_in() {
    let report = FathomReport::new(vec![r("GPU", Present, "card0"), r("Wi-Fi", Absent, "none"), r("Audio", Unknown, "could not read /dev/sndstat")]);
    let text = render_text(&report, "Fathom");
    assert!(text.contains("1 present, 1 absent, 1 COULD NOT BE ASKED"), "{text}");
}

#[test]
fn a_complete_report_does_not_mention_unknowns_at_all() {
    let report = FathomReport::new(vec![r("GPU", Absent, "none"), r("Network", Present, "igc0")]);
    assert!(report.is_complete());
    assert!(!render_text(&report, "Fathom").contains("COULD NOT"));
}

#[test]
fn absent_and_unknown_do_not_look_alike() {
    assert_ne!(mark(Absent), mark(Unknown));
    assert_ne!(mark(Present), mark(Absent));
    assert!(ProbeStatus::ALL.iter().all(|s| mark(*s).len() == 4));
}

#[test]
fn completeness_is_not_suitability() {
    let no_gpu = FathomReport::new(vec![r("GPU", Absent, "no /dev/dri/card*"), r("Network", Present, "igc0")]);
    assert!(no_gpu.is_complete(), "nothing went unasked —");
    assert_eq!(no_gpu.counts().absent, 1, "— and the machine still has no GPU");
}

#[test]
fn the_text_rendering_stays_plain_enough_for_a_broken_machine() {
    let text = render_text(
        &FathomReport::new(vec![r("GPU", Present, "card0 (+ renderD128)"), r("Power", Unknown, "no way to ask this platform about power")]),
        "Fathom",
    );
    assert!(text.is_ascii());
    assert!(text.lines().all(|l| l.len() <= 80), "{text}");
}

#[test]
fn a_probe_detail_written_carelessly_degrades_rather_than_corrupts() {
    let text = render_text(&FathomReport::new(vec![r("GPU", Absent, "no card \u{2014} \u{201C}none\u{201D}\u{2026}")]), "Fathom");
    assert!(text.contains("no card - \"none\"..."), "{text}");
    assert!(text.is_ascii());
}

#[test]
fn disks_are_reported_as_hardware_and_not_as_somewhere_to_install() {
    let r = probe_disks(&[DiskFact { name: "nvd0".into(), bytes: 1_000_204_886_016, model: "Samsung SSD 980".into() }]);
    assert_eq!(r.status, Present);
    assert_eq!(r.detail, "nvd0 931.5 GiB (Samsung SSD 980)");
    assert_eq!(probe_disks(&[]).status, Absent);
}

#[test]
fn no_way_to_ask_about_power_is_not_the_same_as_no_battery() {
    assert_eq!(probe_battery(None, false, false).status, Unknown);
    assert_eq!(probe_battery(None, false, true).status, Absent);
}

// MARK: the measurement

/// `undertow run --backend auto --frames 300` on the RX 6750 XT, 2026-09-05.
const METAL_RUN: &str = "WAYLAND_DISPLAY=wayland-0
usable=0,0,2560x1440
surfaces-created=0
layers=0 of 0
wake-late-p99-us=715
composite-p99-us=9
margin-us=8000
missed=45 of 300
period-us=16666
vblank-source=hardware
backend=drm
verdict ok";

#[test]
fn the_frame_contract_is_read_off_undertows_own_output() {
    let r = probe_frame_contract(Some(METAL_RUN));
    assert_eq!(r.status, Present);
    assert_eq!(r.detail, "45 of 300 missed (150 per mille), composite p99 9us, period 16666us [hardware clock, DRM]");
}

#[test]
fn only_drm_with_a_hardware_clock_counts_as_a_measurement() {
    let detail = |backend: &str, clock: &str| probe_frame_contract(Some(&format!("missed=45 of 300\nbackend={backend}\nvblank-source={clock}"))).detail;
    assert!(detail("drm", "hardware").contains("hardware clock, DRM"));
    assert!(detail("nested-wayland", "hardware").contains("NOT APPLICABLE"));
    assert!(detail("nested-x11", "hardware").contains("NOT APPLICABLE"));
    assert!(detail("headless", "nominal").contains("HEADLESS"));
    assert!(detail("drm", "nominal").contains("provisional"));
}

#[test]
fn an_unstated_clock_is_not_silently_assumed_to_be_hardware() {
    assert!(probe_frame_contract(Some("missed=0 of 300\ncomposite-p99-us=9")).detail.contains("unstated"));
    assert!(probe_frame_contract(Some("missed=0 of 300\nvblank-source=hardware")).detail.contains("backend unstated"));
}

#[test]
fn no_frames_is_an_answer_about_the_machine_not_a_failure_to_ask() {
    assert_eq!(probe_frame_contract(Some("missed=0 of 0\nvblank-source=hardware")).status, Absent);
}

#[test]
fn the_probe_reports_numbers_and_refuses_a_verdict() {
    let bad = probe_frame_contract(Some("missed=299 of 300\nvblank-source=hardware"));
    let good = probe_frame_contract(Some("missed=0 of 300\nvblank-source=hardware"));
    assert_eq!(bad.status, good.status);
    for word in ["ok", "fail", "pass", "good", "bad", "verdict"] {
        assert!(!bad.detail.to_lowercase().contains(word), "the probe rendered a verdict: {}", bad.detail);
    }
}

#[test]
fn unreadable_output_is_unknown() {
    for out in [None, Some(""), Some("nothing useful here"), Some("missed=lots of frames")] {
        assert_eq!(probe_frame_contract(out).status, Unknown, "{out:?}");
    }
    // A count Swift's `missed * 1000` would trap on.
    assert_eq!(probe_frame_contract(Some("missed=9223372036854775807 of 1")).status, Present);
}

#[test]
fn a_missed_frame_report_says_which_term_ate_it() {
    let out = "missed=58 of 300\ncomposite-p99-us=12\nperiod-us=16680\nmargin-wake-us=300\nmargin-cost-us=12\nmargin-commit-us=7000\nmargin-safety-us=400\nmargin-pinned=yes\nbackend=drm\nvblank-source=hardware";
    let d = probe_frame_contract(Some(out)).detail;
    assert!(d.contains("margin dominated by display commit (7000us)"), "{d}");
    assert!(d.contains("PINNED"), "{d}");
    // Two equal largest: the first named, as Swift chooses.
    let tie = probe_frame_contract(Some("missed=1 of 300\nmargin-cost-us=5\nmargin-wake-us=5")).detail;
    assert!(tie.contains("dominated by waking late"), "{tie}");
}

#[test]
fn a_perfect_run_says_nothing_about_margins() {
    let d = probe_frame_contract(Some("missed=0 of 300\nmargin-commit-us=7000\nmargin-pinned=yes\nbackend=drm\nvblank-source=hardware")).detail;
    assert!(!d.contains("dominated") && !d.contains("PINNED"), "{d}");
}

#[test]
fn a_pinned_margin_is_distinguished_from_a_merely_large_one() {
    let base = "missed=10 of 300\nmargin-commit-us=7000\nbackend=drm\nvblank-source=hardware";
    assert!(!probe_frame_contract(Some(&format!("{base}\nmargin-pinned=no"))).detail.contains("PINNED"));
    assert!(probe_frame_contract(Some(&format!("{base}\nmargin-pinned=yes"))).detail.contains("PINNED"));
}

// MARK: getting the report off the machine

#[test]
fn the_filename_identifies_the_machine_and_not_the_person() {
    assert_eq!(report_filename(Some("Apple Inc."), Some("MacPro6,1")), "fathom-apple-inc-macpro6-1.txt");
    assert_eq!(report_filename(Some("Micro-Star International Co., Ltd."), Some("MS-7D25")), "fathom-micro-star-international-co-ltd-ms-7d25.txt");
}

#[test]
fn two_machines_on_one_stick_get_two_files() {
    let a = report_filename(Some("Apple Inc."), Some("MacPro6,1"));
    assert_ne!(a, report_filename(Some("Apple Inc."), Some("MacBookPro11,3")));
    assert_eq!(a, report_filename(Some("Apple Inc."), Some("MacPro6,1")));
}

#[test]
fn the_filename_is_safe_on_a_filesystem_we_do_not_control() {
    let long = "x".repeat(200);
    for (mk, pr) in [("Wéird Ünïcode", "Ma/chine\\Name"), ("   ", "  "), ("A", long.as_str())] {
        let f = report_filename(Some(mk), Some(pr));
        assert!(f.starts_with("fathom-") && f.ends_with(".txt") && f.len() <= 64, "{f}");
        let middle = &f[7..f.len() - 4];
        assert!(middle.chars().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-'), "{f}");
    }
}

#[test]
fn a_machine_that_will_not_say_what_it_is_still_gets_a_file() {
    assert_eq!(report_filename(None, None), "fathom-unknown.txt");
    assert_eq!(report_filename(Some(""), Some("")), "fathom-unknown.txt");
}

// MARK: the tunable that has been unconditional

#[test]
fn only_a_mac_pro_asks_for_pcie_hotplug_to_be_disabled() {
    assert!(needs_pcie_hotplug_disabled(Some("Apple Inc."), Some("MacPro6,1")));
    assert!(needs_pcie_hotplug_disabled(Some("Apple Inc."), Some("MacPro5,1")));
}

#[test]
fn every_other_machine_is_left_alone() {
    assert!(!needs_pcie_hotplug_disabled(Some("Micro-Star International Co., Ltd."), Some("MS-7D25")));
    assert!(!needs_pcie_hotplug_disabled(Some("QEMU"), Some("Standard PC (Q35 + ICH9, 2009)")));
    assert!(!needs_pcie_hotplug_disabled(None, None));
    assert!(!needs_pcie_hotplug_disabled(Some("Apple Inc."), Some("MacBookPro11,3")));
}

#[test]
fn the_maker_and_the_model_both_have_to_match() {
    assert!(!needs_pcie_hotplug_disabled(Some("QEMU"), Some("MacPro6,1")));
    assert!(!needs_pcie_hotplug_disabled(None, Some("MacPro6,1")));
}

#[test]
fn arm64_boots_through_uefi_without_the_x86_sysctl() {
    assert_eq!(probe_boot_method(None, Some("aarch64")).status, Present);
    assert!(probe_boot_method(None, Some("aarch64")).detail.starts_with("UEFI"));
    assert_eq!(probe_boot_method(None, Some("amd64")).status, Unknown);
    assert_eq!(probe_boot_method(Some("BIOS"), Some("amd64")).detail, "BIOS (legacy)");
}

#[test]
fn the_adrenos_driver_is_a_graphics_module() {
    let k = "Id Refs Address                Size Name\n 1   80 0xffff000000000000  2b4e9a8 kernel\n 7    1 0xffff0000ab000000   400000 msm.ko\n 8    2 0xffff0000ac000000   100000 drm.ko";
    assert_eq!(probe_modules(Some(k)).detail, "drm, msm loaded");
}

#[test]
fn no_wlan_module_means_no_wireless() {
    assert_eq!(probe_wifi(None, Some(false)).status, Absent);
    assert_eq!(probe_wifi(None, Some(true)).status, Unknown);
    assert_eq!(probe_wifi(None, None).status, Unknown, "not asked: unknown, as before");
    assert_eq!(probe_wifi(Some("iwm0"), Some(true)).status, Present);
}

/// A CRLF capture reads as its lines (to Swift, CRLF is one Character, so
/// it neither trims nor splits).
#[test]
fn a_crlf_capture_reads_as_its_lines() {
    assert_eq!(probe_wifi(Some("iwm0\r\n"), None).detail, "iwm0");
    assert_eq!(probe_audio(Some("pcm0: <a>\r\npcm1: <b>\r\n")).detail, "pcm0, pcm1");
}
