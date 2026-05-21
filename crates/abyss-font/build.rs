// SPDX-License-Identifier: BSD-2-Clause

//! Compile the C font shim and link the freetype + harfbuzz ports.
//!
//! No build-dependency crates: the system C compiler (`cc` — clang on
//! macOS and the BSDs) and `ar` are invoked directly, and the libraries
//! are located with `pkg-config`. All three are part of the toolchain,
//! not vendored dependencies (`DESIGN.md` §3.2).

use std::env;
use std::path::PathBuf;
use std::process::Command;

/// Run `pkg-config` and return its whitespace-split output.
fn pkg_config(flag: &str, package: &str) -> Vec<String> {
    let output = Command::new("pkg-config")
        .arg(flag)
        .arg(package)
        .output()
        .expect("pkg-config must be installed to build abyss-font");
    assert!(
        output.status.success(),
        "pkg-config could not find `{package}` — is the font stack installed?"
    );
    String::from_utf8_lossy(&output.stdout)
        .split_whitespace()
        .map(str::to_owned)
        .collect()
}

fn main() {
    println!("cargo:rerun-if-changed=c/font_shim.c");
    println!("cargo:rerun-if-changed=build.rs");
    println!("cargo:rerun-if-env-changed=CC");

    const PACKAGES: [&str; 2] = ["freetype2", "harfbuzz"];

    let out_dir = PathBuf::from(env::var("OUT_DIR").expect("OUT_DIR is set for build scripts"));
    let object = out_dir.join("font_shim.o");
    let archive = out_dir.join("libabyss_font_shim.a");

    // Compile the shim with the system C compiler, with the libraries'
    // include paths from pkg-config.
    let mut includes = Vec::new();
    for package in PACKAGES {
        includes.extend(pkg_config("--cflags-only-I", package));
    }
    let cc = env::var("CC").unwrap_or_else(|_| "cc".to_owned());
    let compiled = Command::new(&cc)
        .args(["-c", "-O2", "-fPIC"])
        .args(&includes)
        .arg("c/font_shim.c")
        .arg("-o")
        .arg(&object)
        .status()
        .expect("a C compiler (cc) is required to build abyss-font");
    assert!(compiled.success(), "compiling the font shim failed");

    // Archive the object into a static library cargo can link.
    let archived = Command::new("ar")
        .arg("crs")
        .arg(&archive)
        .arg(&object)
        .status()
        .expect("ar is required to build abyss-font");
    assert!(archived.success(), "archiving the font shim failed");

    println!("cargo:rustc-link-search=native={}", out_dir.display());
    println!("cargo:rustc-link-lib=static=abyss_font_shim");

    // Link freetype and harfbuzz themselves.
    for package in PACKAGES {
        for flag in pkg_config("--libs-only-L", package) {
            if let Some(dir) = flag.strip_prefix("-L") {
                println!("cargo:rustc-link-search=native={dir}");
            }
        }
        for flag in pkg_config("--libs-only-l", package) {
            if let Some(lib) = flag.strip_prefix("-l") {
                println!("cargo:rustc-link-lib={lib}");
            }
        }
    }
}
