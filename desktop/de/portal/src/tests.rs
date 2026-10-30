//! PortalTests.swift, ported. The security-relevant part of this component
//! is *what it refuses*, so that is what most of these test.

use super::*;
use current_ipc::Msg;
use std::fs;

fn msg(pairs: &[(&str, &str)]) -> Msg {
    let mut m = Msg::new();
    for (k, v) in pairs {
        m.set_string(k, v);
    }
    m
}

/// A scratch runtime directory, and a service that uses it.
fn service(picker: &str, grabber: &str, tag: &str) -> (PortalService, String) {
    let dir = std::env::temp_dir().join(format!("abyss-portal-{tag}-{}", std::process::id()));
    fs::create_dir_all(&dir).unwrap();
    let dir = dir.to_str().unwrap().to_owned();
    let mut s = PortalService::new(Some(picker), Some(grabber));
    s.runtime_dir = Some(dir.clone());
    (s, dir)
}

fn true_path() -> &'static str {
    if std::path::Path::new("/usr/bin/true").exists() { "/usr/bin/true" } else { "/bin/true" }
}

// MARK: the confused-deputy rule

/// **A request cannot name the file that gets opened.**
#[test]
fn a_request_cannot_name_the_file_to_open() {
    let m = msg(&[("method", "file.open"), ("path", "/etc/master.passwd"), ("file", "/etc/master.passwd"), ("dir", "/home/build")]);
    assert_eq!(PortalRequest::parse(&m), PortalRequest::OpenFile { start_dir: Some("/home/build".into()) }, "only the directory hint survives");
}

#[test]
fn a_suggested_directory_must_be_absolute() {
    for bad in ["relative/path", "..", "../../etc", ""] {
        assert_eq!(PortalRequest::parse(&msg(&[("method", "file.open"), ("dir", bad)])), PortalRequest::OpenFile { start_dir: None }, "'{bad}'");
    }
    assert_eq!(PortalRequest::parse(&msg(&[("method", "file.open"), ("dir", "/home/build/Documents")])), PortalRequest::OpenFile { start_dir: Some("/home/build/Documents".into()) });
}

#[test]
fn a_suggested_name_must_be_a_single_path_component() {
    for bad in ["../../.ssh/authorized_keys", "a/b", "..", ".", ""] {
        assert_eq!(PortalRequest::parse(&msg(&[("method", "file.save"), ("name", bad)])), PortalRequest::SaveFile { start_dir: None, suggested_name: None }, "'{bad}'");
    }
    assert_eq!(PortalRequest::parse(&msg(&[("method", "file.save"), ("name", "Untitled.txt")])), PortalRequest::SaveFile { start_dir: None, suggested_name: Some("Untitled.txt".into()) });
}

#[test]
fn unknown_methods_are_preserved_for_the_reply() {
    assert_eq!(PortalRequest::parse(&msg(&[("method", "file.delete")])), PortalRequest::Unknown("file.delete".into()));
    assert_eq!(PortalRequest::parse(&Msg::new()), PortalRequest::Unknown(String::new()));
}

#[test]
fn notify_needs_a_summary() {
    assert_eq!(PortalRequest::parse(&msg(&[("method", "notify")])), PortalRequest::Unknown("notify (no summary)".into()));
    let mut full = msg(&[("method", "notify"), ("summary", "Build finished"), ("body", "all tests green")]);
    full.set_u64("timeout", 8);
    assert_eq!(PortalRequest::parse(&full), PortalRequest::Notify { summary: "Build finished".into(), body: Some("all tests green".into()), timeout: Some(8) });
    assert_eq!(PortalRequest::parse(&msg(&[("method", "notify"), ("summary", "Done")])), PortalRequest::Notify { summary: "Done".into(), body: None, timeout: None });
}

// MARK: the picker's answer

/// Exit status and result file, read together (§6.2).
#[test]
fn choice_cancel_and_crash_are_distinguishable() {
    assert_eq!(PickerOutcome::from(0, false, Some("/home/x/a.txt".into())), PickerOutcome::Chose("/home/x/a.txt".into()));
    assert_eq!(PickerOutcome::from(1, false, None), PickerOutcome::Cancelled);
    assert!(matches!(PickerOutcome::from(11, true, None), PickerOutcome::Failed(_)), "a crash is not a cancel");
    assert!(matches!(PickerOutcome::from(127, false, None), PickerOutcome::Failed(_)));
    assert!(matches!(PickerOutcome::from(0, false, None), PickerOutcome::Failed(_)), "exit 0 with no result is not a choice");
}

#[test]
fn reply_shapes() {
    let ok = picker_reply(&PickerOutcome::Chose("/home/x/a.txt".into()), OpenMode::Read);
    assert_eq!((ok.bool("ok"), ok.string("path"), ok.string("mode")), (Some(true), Some("/home/x/a.txt"), Some("r")));
    assert_eq!(picker_reply(&PickerOutcome::Chose("/x".into()), OpenMode::Write).string("mode"), Some("w"));
    let cancelled = picker_reply(&PickerOutcome::Cancelled, OpenMode::Read);
    assert_eq!((cancelled.bool("ok"), cancelled.string("error"), cancelled.string("path")), (Some(false), Some("cancelled"), None), "nothing to open");
    let failed = picker_reply(&PickerOutcome::Failed("the picker exited 3".into()), OpenMode::Read);
    assert_eq!((failed.bool("ok"), failed.string("error")), (Some(false), Some("the picker exited 3")));
}

#[test]
fn the_result_reader_refuses_anything_but_an_absolute_path() {
    let dir = std::env::temp_dir().join(format!("abyss-portal-result-{}", std::process::id()));
    fs::create_dir_all(&dir).unwrap();
    let w = |name: &str, contents: &str| {
        let p = dir.join(name);
        fs::write(&p, contents).unwrap();
        p.to_str().unwrap().to_owned()
    };
    assert_eq!(read_picker_result(&w("good", "/home/x/a.txt\n")).as_deref(), Some("/home/x/a.txt"));
    assert_eq!(read_picker_result(&w("crlf", "/home/x/b.txt\r\n")).as_deref(), Some("/home/x/b.txt"));
    assert_eq!(read_picker_result(&w("relative", "relative.txt\n")), None);
    assert_eq!(read_picker_result(&w("empty", "")), None);
    assert_eq!(read_picker_result(dir.join("absent").to_str().unwrap()), None);
    fs::remove_dir_all(dir).unwrap();
}

#[test]
fn the_picker_binary_can_be_overridden() {
    assert_eq!(PortalService::new(Some("/usr/bin/true"), None).picker_binary, "/usr/bin/true");
    assert_eq!(choose_binary(None, Some("/usr/bin/false"), Some("/x/AquaDemo".into()), "AquaDemo"), "/usr/bin/false", "$ABYSS_PICKER");
    assert_eq!(choose_binary(None, Some(""), Some("/x/AquaDemo".into()), "AquaDemo"), "/x/AquaDemo", "an empty variable is unset");
    assert_eq!(choose_binary(None, None, None, "AquaDemo"), "AquaDemo");
}

/// A picker that cannot run is a clean refusal, not a hang or a success.
#[test]
fn a_picker_that_cannot_run_is_reported_as_failed() {
    let (mut s, dir) = service("/nonexistent/picker", "/nonexistent/grabber", "cannot-run");
    assert!(matches!(s.run_picker(None, None), PickerOutcome::Failed(_)));
    fs::remove_dir_all(dir).unwrap();
}

/// `true` exits 0 and writes nothing: the broken picker, end to end.
#[test]
fn a_picker_that_writes_nothing_is_not_a_choice() {
    let (mut s, dir) = service(true_path(), true_path(), "writes-nothing");
    assert!(matches!(s.run_picker(None, None), PickerOutcome::Failed(_)));
    fs::remove_dir_all(dir).unwrap();
}

/// A picker that does choose: the portal opens the file the person picked,
/// and that file only, and hands back its descriptor.
#[test]
fn a_chosen_file_comes_back_as_a_descriptor() {
    let (_, dir) = service(true_path(), true_path(), "chooses");
    let chosen = format!("{dir}/chosen.txt");
    fs::write(&chosen, "what the person picked").unwrap();
    let picker = format!("{dir}/picker");
    fs::write(&picker, format!("#!/bin/sh\nprintf '%s\\n' '{chosen}' > \"$ABYSS_FINDER_PICK\"\n")).unwrap();
    std::process::Command::new("chmod").args(["755", &picker]).status().unwrap();
    let mut s = PortalService::new(Some(&picker), Some(true_path()));
    s.runtime_dir = Some(dir.clone());
    let (reply, fd) = s.handle(&PortalRequest::OpenFile { start_dir: None });
    assert_eq!((reply.bool("ok"), reply.string("path")), (Some(true), Some(chosen.as_str())));
    let mut text = String::new();
    std::io::Read::read_to_string(&mut fs::File::from(fd.expect("a descriptor")), &mut text).unwrap();
    assert_eq!(text, "what the person picked");
    assert!(!std::path::Path::new(&format!("{dir}/pick.{}", std::process::id())).exists(), "the result file is gone");
    fs::remove_dir_all(dir).unwrap();
}

// MARK: screenshot (P7.5)

#[test]
fn a_screenshot_request_carries_nothing_an_app_sent() {
    let mut m = msg(&[("method", "screenshot"), ("output", "HEADLESS-2"), ("path", "/etc/master.passwd"), ("dir", "/home/build")]);
    m.set_u64("window", 42);
    assert_eq!(PortalRequest::parse(&m), PortalRequest::Screenshot);
}

#[test]
fn the_screenshot_reply_names_no_path() {
    let r = screenshot_reply(&GrabOutcome::Captured { width: 520, height: 400 });
    assert_eq!((r.bool("ok"), r.u64("width"), r.u64("height"), r.string("mode"), r.string("path")), (Some(true), Some(520), Some(400), Some("r"), None));
}

#[test]
fn a_grab_that_wrote_no_image_is_not_a_capture() {
    let png = Some(PngSize { width: 8, height: 8 });
    assert_eq!(GrabOutcome::from(0, false, png), GrabOutcome::Captured { width: 8, height: 8 });
    assert!(matches!(GrabOutcome::from(0, false, None), GrabOutcome::Failed(_)));
    assert!(matches!(GrabOutcome::from(1, false, png), GrabOutcome::Failed(_)), "the status is the authority");
    assert!(matches!(GrabOutcome::from(11, true, png), GrabOutcome::Failed(_)));
}

#[test]
fn png_header_reads_size_and_rejects_everything_else() {
    let mut png = PNG_SIGNATURE.to_vec();
    png.extend([0, 0, 0, 13]);
    png.extend(b"IHDR");
    png.extend([0, 0, 0x02, 0x08, 0, 0, 0x01, 0x90]);
    assert_eq!(png_size(&png), Some(PngSize { width: 520, height: 400 }));
    assert_eq!(png_size(&png[..20]), None, "truncated");
    let mut not_png = vec![0xAB; 24];
    not_png[0] = 0xFF;
    not_png[1] = 0xD8;
    assert_eq!(png_size(&not_png), None);
    let mut no_ihdr = png.clone();
    no_ihdr[12..16].copy_from_slice(b"IEND");
    assert_eq!(png_size(&no_ihdr), None);
    let mut zero = png.clone();
    zero[16..20].fill(0);
    assert_eq!(png_size(&zero), None);
    assert_eq!(png_size(&[]), None);
}

/// A failed capability request hands over nothing at all.
#[test]
fn a_grabber_that_cannot_run_yields_no_descriptor() {
    let (mut s, dir) = service("/nonexistent/picker", "/nonexistent/grabber", "grab-cannot-run");
    let (reply, fd) = s.handle(&PortalRequest::Screenshot);
    assert_eq!(reply.bool("ok"), Some(false));
    assert!(reply.string("error").is_some());
    assert!(fd.is_none(), "a failed capture must not hand back a descriptor");
    fs::remove_dir_all(dir).unwrap();
}

#[test]
fn a_grabber_that_writes_no_image_yields_no_descriptor() {
    let (mut s, dir) = service(true_path(), true_path(), "grab-writes-nothing");
    let (reply, fd) = s.handle(&PortalRequest::Screenshot);
    assert_eq!(reply.bool("ok"), Some(false));
    assert!(fd.is_none());
    assert!(!std::path::Path::new(&format!("{dir}/shot.{}.png", std::process::id())).exists(), "it left nothing behind");
    fs::remove_dir_all(dir).unwrap();
}
