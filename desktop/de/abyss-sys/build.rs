// Build the two C shims the Swift toolkit uses (de/cdraw, de/ctext), straight
// from the repository, and link cairo/freetype/harfbuzz/fontconfig through
// pkg-config — the same split SwiftPM makes in Package.swift (CDraw has no
// dependencies; CText compiles against freetype2, harfbuzz and fontconfig;
// AquaDraw links cairo).
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

    // The shims SwiftPM compiles, from their own directories beside this one.
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
    // the file SwiftPM compiles; crypt(3) for its password hashing.
    let cplatform = de.join("cplatform");
    println!("cargo:rerun-if-changed={}", cplatform.join("cplatform.c").display());
    cc::Build::new()
        .file(cplatform.join("cplatform.c"))
        .include(cplatform.join("include"))
        .compile("cplatform");
    println!("cargo:rustc-link-lib=crypt");

    // CPoolWatch (src/poolwatch.rs): the config directory watch PoolConfig
    // uses, inotify or kqueue by #ifdef, as SwiftPM compiles it.
    let cpoolwatch = de.join("cpoolwatch");
    println!("cargo:rerun-if-changed={}", cpoolwatch.join("cpoolwatch.c").display());
    cc::Build::new()
        .file(cpoolwatch.join("cpoolwatch.c"))
        .include(cpoolwatch.join("include"))
        .compile("cpoolwatch");

    // The Wayland client (src/wl.rs): the requests wl.c exports, over the
    // scanner's xdg-shell code and cwayland's shm helper, as SwiftPM builds
    // them for CWayland and CAbyssProtocols.
    let cwayland = de.join("cwayland");
    let protocols = de.join("cabyssprotocols");
    let here = PathBuf::from(env::var("CARGO_MANIFEST_DIR").unwrap());
    for f in [here.join("wl.c"), protocols.join("xdg-shell-protocol.c"), cwayland.join("cwayland_shm.c")] {
        println!("cargo:rerun-if-changed={}", f.display());
    }
    let mut wl = cc::Build::new();
    wl.file(here.join("wl.c"))
        .file(protocols.join("xdg-shell-protocol.c"))
        .file(cwayland.join("cwayland_shm.c"))
        .include(cwayland.join("include"));
    for flag in pkg_config_of(&["--cflags"], &["wayland-client"]) {
        if let Some(dir) = flag.strip_prefix("-I") {
            wl.include(dir);
        } else {
            wl.flag(&flag);
        }
    }
    wl.compile("abw");
    for flag in pkg_config_of(&["--libs"], &["wayland-client"]) {
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
