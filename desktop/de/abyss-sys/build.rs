// Build the desktop's C shims (de/c*), straight from the repository, and
// link cairo/freetype/harfbuzz/fontconfig through pkg-config (cdraw has no
// dependencies; ctext compiles against freetype2, harfbuzz and fontconfig;
// the drawing links cairo).
//
// Cross-building: the cc crate honours CC / CC_<target> / CFLAGS /
// CFLAGS_<target> / AR. pkg-config is run as `$PKG_CONFIG` (or
// `$PKG_CONFIG_<target>`, else `pkg-config`) with the environment passed
// through untouched, so PKG_CONFIG_SYSROOT_DIR, PKG_CONFIG_LIBDIR and
// PKG_CONFIG_PATH work as they do for any autotools build.

use std::env;
use std::path::PathBuf;
use std::process::Command;

const PACKAGES: &[&str] = &["cairo", "freetype2", "harfbuzz", "fontconfig"];

fn pkg_config(args: &[&str]) -> Vec<String> {
    pkg_config_of(args, PACKAGES)
}

fn pkg_config_of(args: &[&str], packages: &[&str]) -> Vec<String> {
    let target = env::var("TARGET").unwrap_or_default();
    let target_var = format!("PKG_CONFIG_{}", target.replace('-', "_"));
    let tool = env::var(&target_var)
        .or_else(|_| env::var("PKG_CONFIG"))
        .unwrap_or_else(|_| "pkg-config".to_string());
    let out = Command::new(&tool)
        .args(args)
        .args(packages)
        .output()
        .unwrap_or_else(|e| panic!("could not run {tool}: {e}"));
    if !out.status.success() {
        panic!(
            "{tool} {} {} failed: {}",
            args.join(" "),
            packages.join(" "),
            String::from_utf8_lossy(&out.stderr)
        );
    }
    String::from_utf8_lossy(&out.stdout)
        .split_whitespace()
        .map(str::to_string)
        .collect()
}

fn here_dir() -> PathBuf {
    PathBuf::from(env::var("CARGO_MANIFEST_DIR").unwrap())
}

fn main() {
    let target = env::var("TARGET").unwrap_or_default();
    for v in [
        "PKG_CONFIG",
        "PKG_CONFIG_PATH",
        "PKG_CONFIG_LIBDIR",
        "PKG_CONFIG_SYSROOT_DIR",
    ] {
        println!("cargo:rerun-if-env-changed={v}");
    }
    println!("cargo:rerun-if-env-changed=PKG_CONFIG_{}", target.replace('-', "_"));

    // The shims, from their own directories beside this one.
    let de = PathBuf::from(env::var("CARGO_MANIFEST_DIR").unwrap()).join("..");
    let cdraw = de.join("cdraw");
    let ctext = de.join("ctext");
    for f in [cdraw.join("cdraw.c"), cdraw.join("include/cdraw.h"), ctext.join("ctext.c"), ctext.join("include/ctext.h")] {
        println!("cargo:rerun-if-changed={}", f.display());
    }

    // CDraw: plain C, no dependencies.
    cc::Build::new()
        .file(cdraw.join("cdraw.c"))
        .include(cdraw.join("include"))
        .compile("cdraw");

    // CText: against freetype2, harfbuzz, fontconfig (their --cflags).
    let mut text = cc::Build::new();
    text.file(ctext.join("ctext.c")).include(ctext.join("include"));
    for flag in pkg_config(&["--cflags"]) {
        if let Some(dir) = flag.strip_prefix("-I") {
            text.include(dir);
        } else if let Some(def) = flag.strip_prefix("-D") {
            match def.split_once('=') {
                Some((k, v)) => text.define(k, v),
                None => text.define(def, None),
            };
        } else {
            text.flag(&flag);
        }
    }
    text.compile("ctext");

    // CPlatform (src/platform.rs): descriptor passing, peers, and the rest of
    // cplatform.c; crypt(3) for its password hashing.
    let cplatform = de.join("cplatform");
    println!("cargo:rerun-if-changed={}", cplatform.join("cplatform.c").display());
    cc::Build::new()
        .file(cplatform.join("cplatform.c"))
        .include(cplatform.join("include"))
        .compile("cplatform");
    println!("cargo:rustc-link-lib=crypt");

    // CPoolWatch (src/poolwatch.rs): the config directory watch PoolConfig
    // uses, inotify or kqueue by #ifdef.
    let cpoolwatch = de.join("cpoolwatch");
    println!("cargo:rerun-if-changed={}", cpoolwatch.join("cpoolwatch.c").display());
    cc::Build::new()
        .file(cpoolwatch.join("cpoolwatch.c"))
        .include(cpoolwatch.join("include"))
        .compile("cpoolwatch");

    // CVents (src/vents.rs): sysctl, kenv, the OSS mixer, sndstat, the
    // process table; libnv and libmixer on FreeBSD.
    let cvents = de.join("cvents");
    println!("cargo:rerun-if-changed={}", cvents.join("cvents.c").display());
    cc::Build::new()
        .file(cvents.join("cvents.c"))
        .include(cvents.join("include"))
        .compile("cvents");
    if target.contains("freebsd") {
        println!("cargo:rustc-link-lib=nv");
        println!("cargo:rustc-link-lib=mixer");
    }

    // CProc (src/proc.rs): every child a pollable descriptor, the signal
    // pipe; setusercontext(3) from libutil on FreeBSD.
    let cproc = de.join("cproc");
    println!("cargo:rerun-if-changed={}", cproc.join("cproc.c").display());
    cc::Build::new()
        .file(cproc.join("cproc.c"))
        .include(cproc.join("include"))
        .compile("cproc");
    if target.contains("freebsd") {
        println!("cargo:rustc-link-lib=util");
    }

    // CPAM (src/pam.rs): the authenticator's PAM conversation; OpenPAM is
    // FreeBSD's base, and without its headers the C says so instead.
    let cpam = de.join("cpam");
    println!("cargo:rerun-if-changed={}", cpam.join("cpam.c").display());
    cc::Build::new()
        .file(cpam.join("cpam.c"))
        .include(cpam.join("include"))
        .compile("cpam");
    if target.contains("freebsd") {
        println!("cargo:rustc-link-lib=pam");
    }

    // CJail (src/jail.rs): jail(2), jail and process descriptors, and the
    // login class's limits for abyss-jaild (PHASE18 P18.2); ENOSYS stubs
    // off FreeBSD, so everything above compiles and is tested on Linux.
    let cjail = de.join("cjail");
    println!("cargo:rerun-if-changed={}", cjail.join("cjail.c").display());
    cc::Build::new()
        .file(cjail.join("cjail.c"))
        .include(cjail.join("include"))
        .compile("cjail");
    if target.contains("freebsd") {
        println!("cargo:rustc-link-lib=jail");
    }

    // CTLS (src/tls.rs), with the `tls` feature: a verified TLS client
    // over OpenSSL, base's on FreeBSD (P18.12a).
    if env::var_os("CARGO_FEATURE_TLS").is_some() {
        let ctls = de.join("ctls");
        println!("cargo:rerun-if-changed={}", ctls.join("ctls.c").display());
        cc::Build::new().file(ctls.join("ctls.c")).include(ctls.join("include")).compile("ctls");
        println!("cargo:rustc-link-lib=ssl");
        println!("cargo:rustc-link-lib=crypto");
    }

    // CWlroots (src/wlr.rs), with the `wlroots` feature: the listener
    // trampoline undertow's listeners go through, and the accessors Rust needs
    // because it cannot read wlroots' headers (tw-access.h, RUST.md R4b).
    if env::var_os("CARGO_FEATURE_WLROOTS").is_some() {
        let cwlroots = de.join("cwlroots");
        let mut w = cc::Build::new();
        for f in ["cwlroots.c", "access.c", "menus.c", "include/cwlroots.h", "include/tw-access.h"] {
            println!("cargo:rerun-if-changed={}", cwlroots.join(f).display());
        }
        // And the menus (menus.c, P10.3) over the protocols' generated code,
        //.
        let protocols = de.join("cabyssprotocols");
        w.file(cwlroots.join("cwlroots.c")).file(cwlroots.join("access.c")).file(cwlroots.join("menus.c")).include(cwlroots.join("include"));
        // The protocols' tables are the client library's, below: one copy
        // for both halves.
        let _ = &protocols;
        let wlroots = ["wlroots-0.20", "wayland-server", "pixman-1", "xkbcommon"];
        for flag in pkg_config_of(&["--cflags"], &wlroots) {
            if let Some(dir) = flag.strip_prefix("-I") {
                w.include(dir);
            } else if let Some(def) = flag.strip_prefix("-D") {
                match def.split_once('=') {
                    Some((k, v)) => w.define(k, v),
                    None => w.define(def, None),
                };
            } else {
                w.flag(&flag);
            }
        }
        w.compile("cwlroots");
        println!("cargo:rustc-link-lib=m");
        for flag in pkg_config_of(&["--libs"], &wlroots) {
            if let Some(dir) = flag.strip_prefix("-L") {
                println!("cargo:rustc-link-search=native={dir}");
            } else if let Some(lib) = flag.strip_prefix("-l") {
                println!("cargo:rustc-link-lib={lib}");
            }
        }
    }

    // CCapsicum (src/sandbox.rs): capability mode, FreeBSD's; elsewhere it
    // says it is not there (P7.3).
    let ccap = de.join("ccap");
    println!("cargo:rerun-if-changed={}", ccap.join("ccap.c").display());
    cc::Build::new().file(ccap.join("ccap.c")).include(ccap.join("include")).compile("ccap");

    // The guard (guard.c): a supervised child stopped from a signal handler.
    println!("cargo:rerun-if-changed={}", here_dir().join("guard.c").display());
    cc::Build::new().file(here_dir().join("guard.c")).compile("abguard");

    // The Wayland client (src/wl.rs): the requests wl.c exports, over the
    // scanner's xdg-shell code and cwayland's shm helper (de/cwayland,
    // de/cabyssprotocols).
    let cwayland = de.join("cwayland");
    let protocols = de.join("cabyssprotocols");
    let here = PathBuf::from(env::var("CARGO_MANIFEST_DIR").unwrap());
    // With the keeper's half of wp_security_context_v1 (cwayland_jail.c,
    // P18.5), abyss-idle's ext-idle-notify (idle.c, P16.3), and those
    // protocols' code.
    // And the generated client glue (wlc.c, abyss/tools/gen-wl-client.py)
    // with every protocol table the toolkit binds, shared with the server
    // half (cwlroots) so each exists once.
    let tables = [
        protocols.join("abyss-menu-v1-protocol.c"),
        protocols.join("abyss-window-v1-protocol.c"),
        protocols.join("gtk-shell-protocol.c"),
        cwayland.join("wlr-layer-shell-unstable-v1-protocol.c"),
        cwayland.join("wlr-foreign-toplevel-management-unstable-v1-protocol.c"),
        cwayland.join("xdg-activation-v1-protocol.c"),
        cwayland.join("wlr-screencopy-unstable-v1-protocol.c"),
        cwayland.join("wlr-output-management-unstable-v1-protocol.c"),
        cwayland.join("ext-session-lock-v1-protocol.c"),
    ];
    for f in tables.iter().chain([&here.join("wlc.c")]) {
        println!("cargo:rerun-if-changed={}", f.display());
    }
    for f in [
        here.join("wl.c"),
        protocols.join("xdg-shell-protocol.c"),
        cwayland.join("cwayland_shm.c"),
        cwayland.join("cwayland_jail.c"),
        cwayland.join("security-context-v1-protocol.c"),
        here.join("idle.c"),
        cwayland.join("ext-idle-notify-v1-protocol.c"),
    ] {
        println!("cargo:rerun-if-changed={}", f.display());
    }
    let mut wl = cc::Build::new();
    wl.files(&tables).file(here.join("wlc.c"));
    wl.file(here.join("wl.c"))
        .file(protocols.join("xdg-shell-protocol.c"))
        .file(cwayland.join("cwayland_shm.c"))
        .file(cwayland.join("cwayland_jail.c"))
        .file(cwayland.join("security-context-v1-protocol.c"))
        .file(here.join("idle.c"))
        .file(cwayland.join("ext-idle-notify-v1-protocol.c"))
        .include(cwayland.join("include"));
    // xkbcommon with it: the toolkit's keyboard (src/xkb.rs).
    for flag in pkg_config_of(&["--cflags"], &["wayland-client", "xkbcommon"]) {
        if let Some(dir) = flag.strip_prefix("-I") {
            wl.include(dir);
        } else {
            wl.flag(&flag);
        }
    }
    wl.compile("abw");
    for flag in pkg_config_of(&["--libs"], &["wayland-client", "xkbcommon"]) {
        if let Some(dir) = flag.strip_prefix("-L") {
            println!("cargo:rustc-link-search=native={dir}");
        } else if let Some(lib) = flag.strip_prefix("-l") {
            println!("cargo:rustc-link-lib={lib}");
        }
    }

    // Link: cairo (cairo-ft lives in libcairo) and the text stack.
    for flag in pkg_config(&["--libs"]) {
        if let Some(dir) = flag.strip_prefix("-L") {
            println!("cargo:rustc-link-search=native={dir}");
        } else if let Some(lib) = flag.strip_prefix("-l") {
            println!("cargo:rustc-link-lib={lib}");
        } else {
            println!("cargo:rustc-link-arg={flag}");
        }
    }
}
