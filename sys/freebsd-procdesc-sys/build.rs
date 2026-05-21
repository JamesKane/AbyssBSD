// SPDX-License-Identifier: BSD-2-Clause

//! Compile the process-descriptor C shim — FreeBSD only.
//!
//! `c/procdesc_shim.c` does the `pdfork`-then-`execve` in C so that no Rust
//! runs in the forked child — the only safe way to fork a process that may
//! be multi-threaded (`docs/design/broker-and-transport.md` §5.3, §6). It
//! is compiled with the system C compiler (`cc`) and archived with `ar` —
//! no build-dependency crates (`DESIGN.md` §3.2), the `abyss-font` pattern.
//!
//! On any non-FreeBSD host the shim is not built: the crate compiles to an
//! empty library so the workspace still builds on the macOS dev bed.

use std::env;
use std::path::PathBuf;
use std::process::Command;

fn main() {
    println!("cargo:rerun-if-changed=c/procdesc_shim.c");
    println!("cargo:rerun-if-changed=build.rs");
    println!("cargo:rerun-if-env-changed=CC");

    // The shim binds FreeBSD kernel facilities; it builds only on FreeBSD.
    if env::var("CARGO_CFG_TARGET_OS").as_deref() != Ok("freebsd") {
        return;
    }

    let out_dir = PathBuf::from(env::var("OUT_DIR").expect("OUT_DIR is set for build scripts"));
    let object = out_dir.join("procdesc_shim.o");
    let archive = out_dir.join("libabyss_procdesc_shim.a");

    let cc = env::var("CC").unwrap_or_else(|_| "cc".to_owned());
    let compiled = Command::new(&cc)
        .args(["-c", "-O2", "-fPIC"])
        .arg("c/procdesc_shim.c")
        .arg("-o")
        .arg(&object)
        .status()
        .expect("a C compiler (cc) is required to build freebsd-procdesc-sys");
    assert!(compiled.success(), "compiling the procdesc shim failed");

    let archived = Command::new("ar")
        .arg("crs")
        .arg(&archive)
        .arg(&object)
        .status()
        .expect("ar is required to build freebsd-procdesc-sys");
    assert!(archived.success(), "archiving the procdesc shim failed");

    println!("cargo:rustc-link-search=native={}", out_dir.display());
    println!("cargo:rustc-link-lib=static=abyss_procdesc_shim");
}
