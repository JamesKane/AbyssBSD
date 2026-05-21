// SPDX-License-Identifier: BSD-2-Clause

//! Compile the `SCM_RIGHTS` / cmsg C shim — FreeBSD only.
//!
//! `sendmsg`/`recvmsg` are ordinary libc functions, but the control-message
//! API that carries file descriptors — `CMSG_FIRSTHDR`, `CMSG_DATA`,
//! `CMSG_SPACE`, `CMSG_LEN` — is C macros, uncallable over Rust's FFI
//! (`docs/design/broker-and-transport.md` §6). `c/cmsg_shim.c` does the
//! cmsg work in C and exposes a flat ABI. It is compiled with the system C
//! compiler (`cc`) and archived with `ar` — no build-dependency crates.
//!
//! On any non-FreeBSD host the shim is not built: the crate compiles to an
//! empty library so the workspace still builds on the macOS dev bed.

use std::env;
use std::path::PathBuf;
use std::process::Command;

fn main() {
    println!("cargo:rerun-if-changed=c/cmsg_shim.c");
    println!("cargo:rerun-if-changed=build.rs");
    println!("cargo:rerun-if-env-changed=CC");

    if env::var("CARGO_CFG_TARGET_OS").as_deref() != Ok("freebsd") {
        return;
    }

    let out_dir = PathBuf::from(env::var("OUT_DIR").expect("OUT_DIR is set for build scripts"));
    let object = out_dir.join("cmsg_shim.o");
    let archive = out_dir.join("libabyss_cmsg_shim.a");

    let cc = env::var("CC").unwrap_or_else(|_| "cc".to_owned());
    let compiled = Command::new(&cc)
        .args(["-c", "-O2", "-fPIC"])
        .arg("c/cmsg_shim.c")
        .arg("-o")
        .arg(&object)
        .status()
        .expect("a C compiler (cc) is required to build abyss-transport");
    assert!(compiled.success(), "compiling the cmsg shim failed");

    let archived = Command::new("ar")
        .arg("crs")
        .arg(&archive)
        .arg(&object)
        .status()
        .expect("ar is required to build abyss-transport");
    assert!(archived.success(), "archiving the cmsg shim failed");

    println!("cargo:rustc-link-search=native={}", out_dir.display());
    println!("cargo:rustc-link-lib=static=abyss_cmsg_shim");
}
