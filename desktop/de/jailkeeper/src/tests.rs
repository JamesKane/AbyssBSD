//! The keeper's pure parts (from Tests/JailsTests): which arguments are the
//! person's files, what a crash was, and how a class's model is started.
//! The keeper itself is live-jail-launch.sh's and live-agent*.sh's.

use super::*;
use std::collections::HashMap;

fn strings(xs: &[&str]) -> Vec<String> {
    xs.iter().map(|x| (*x).to_owned()).collect()
}

#[test]
fn a_launchs_file_arguments_are_the_persons_files_only() {
    let files: HashMap<&str, &str> =
        HashMap::from([("/home/a/doc.txt", "/home/a/doc.txt"), ("/home/a/link", "/home/a/real.txt"), ("/usr/local/share/x.ui", "/usr/local/share/x.ui")]);
    let argv = strings(&["/usr/local/bin/gedit", "--new", "/home/a/doc.txt", "relative.txt", "/home/a/link", "/usr/local/share/x.ui", "/home/a/missing", "/home/a/doc.txt"]);
    let got = launch_files(&argv, &strings(&BASE_SYSTEM), |p| files.get(p).map(|s| (*s).to_owned()));
    assert_eq!(got.iter().map(|g| g.0).collect::<Vec<_>>(), [2, 4, 7], "absolute, existing, outside the system; never argv[0]");
    assert_eq!(got.iter().map(|g| g.1.as_str()).collect::<Vec<_>>(), ["/home/a/doc.txt", "/home/a/real.txt", "/home/a/doc.txt"], "resolved");
}

#[test]
fn a_regular_file_is_resolved_and_anything_else_is_not() {
    let dir = std::env::temp_dir().join(format!("abyss-keeper-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let file = dir.join("doc.txt");
    std::fs::write(&file, "x").unwrap();
    let link = dir.join("link");
    let _ = std::os::unix::fs::symlink(&file, &link);
    let real = std::fs::canonicalize(&file).unwrap().to_string_lossy().into_owned();
    assert_eq!(regular_file(&link.to_string_lossy()).as_deref(), Some(real.as_str()));
    assert_eq!(regular_file(&dir.to_string_lossy()), None, "a directory is not a document");
    assert_eq!(regular_file("/nonexistent/abyss"), None);
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn a_wait_status_is_a_crash_only_when_a_signal_ended_it() {
    assert_eq!(Crash::signal_of(11 | 0x80), Some((11, true)));
    assert_eq!(Crash::signal_of(9), Some((9, false)), "SIGKILL: no core");
    assert_eq!(Crash::signal_of(3 << 8), None, "exit 3 is a program's own answer, not a crash");
    assert_eq!(Crash::signal_of(0), None);
    assert_eq!(Crash::signal_of(0x7f | (17 << 8)), None, "stopped is not dead");
}

#[test]
fn the_core_is_named_as_the_kernel_names_it() {
    assert_eq!(Crash::core_name("/home/abyss/crasher"), "crasher.core");
    assert_eq!(Crash::core_name("galculator"), "galculator.core");
    assert_eq!(Crash::core_name("/x/a-very-long-program-name-indeed"), "a-very-long-program.core", "cut at MAXCOMLEN (19)");
}

#[test]
fn the_binary_is_found_as_the_jail_would_find_it() {
    use std::os::unix::fs::PermissionsExt;
    let root = std::env::temp_dir().join(format!("abyss-crash-{}", std::process::id()));
    std::fs::create_dir_all(root.join("usr/local/bin")).unwrap();
    std::fs::create_dir_all(root.join("bin")).unwrap();
    let z = root.join("usr/local/bin/zenity");
    std::fs::write(&z, "").unwrap();
    std::fs::set_permissions(&z, std::fs::Permissions::from_mode(0o755)).unwrap();
    let r = root.to_string_lossy();
    assert_eq!(Crash::binary_inside("zenity", &r).as_deref(), Some("/usr/local/bin/zenity"));
    assert_eq!(Crash::binary_inside("/home/abyss/crasher", &r).as_deref(), Some("/home/abyss/crasher"));
    assert_eq!(Crash::binary_inside("nothere", &r), None);
    let _ = std::fs::remove_dir_all(&root);
}

#[test]
fn a_crash_says_what_happened() {
    let c = Crash {
        id: 1,
        program: "crasher".into(),
        jail: "abyss-1001-app".into(),
        signal: libc::SIGSEGV,
        core_dumped: true,
        core: "/r/home/abyss/crasher.core".into(),
        binary_inside: "/home/abyss/crasher".into(),
        binary: "/r/home/abyss/crasher".into(),
    };
    assert_eq!(c.summary(), "crasher was killed by SIGSEGV and left a core");
    let k = Crash { signal: libc::SIGKILL, core_dumped: false, ..c };
    assert_eq!(k.summary(), "crasher was killed by SIGKILL, leaving no core");
    assert_eq!(Crash::signal_name(99), "signal 99");
}

#[test]
fn the_keepers_model_arguments() {
    assert_eq!(JailKeeper::model_args("local:/m/a.gguf"), Some(strings(&["--local", "/m/a.gguf"])));
    assert_eq!(JailKeeper::model_args("stub:/t/r.json"), Some(strings(&["--stub", "/t/r.json"])));
    assert_eq!(JailKeeper::model_args("http://127.0.0.1:8080"), Some(strings(&["--backend", "http://127.0.0.1:8080"])));
    assert_eq!(JailKeeper::model_args("https://api.example.com"), None, "remote providers are P18.7c's");
    assert_eq!(JailKeeper::model_args("/m/a.gguf"), None);
}
