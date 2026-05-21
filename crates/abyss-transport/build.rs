// SPDX-License-Identifier: BSD-2-Clause

//! Compile the C shims — FreeBSD only.
//!
//! The transport's `SCM_RIGHTS` control-message API and the `kqueue` event
//! API (`EV_SET`) are C macros, uncallable over Rust's FFI
//! (`docs/design/broker-and-transport.md` §6). The shims in `c/` expose
//! them as flat ABIs; they are compiled with the system C compiler (`cc`)
//! and archived with `ar` into one static library — no build-dependency
//! crates, the `abyss-font` pattern.
//!
//! On any non-FreeBSD host the shims are not built: the crate compiles to
//! an empty library so the workspace still builds on the macOS dev bed.

use std::env;
use std::path::PathBuf;
use std::process::Command;

/// The C shims, compiled and archived together into one static library.
const SHIMS: [&str; 2] = ["cmsg_shim.c", "kqueue_shim.c"];

fn main() {
    for shim in SHIMS {
        println!("cargo:rerun-if-changed=c/{shim}");
    }
    println!("cargo:rerun-if-changed=build.rs");
    println!("cargo:rerun-if-env-changed=CC");

    if env::var("CARGO_CFG_TARGET_OS").as_deref() != Ok("freebsd") {
        return;
    }

    let out_dir = PathBuf::from(env::var("OUT_DIR").expect("OUT_DIR is set for build scripts"));
    let cc = env::var("CC").unwrap_or_else(|_| "cc".to_owned());
    let archive = out_dir.join("libabyss_transport_shim.a");

    let mut objects = Vec::new();
    for shim in SHIMS {
        let object = out_dir.join(shim).with_extension("o");
        let compiled = Command::new(&cc)
            .args(["-c", "-O2", "-fPIC"])
            .arg(format!("c/{shim}"))
            .arg("-o")
            .arg(&object)
            .status()
            .expect("a C compiler (cc) is required to build abyss-transport");
        assert!(compiled.success(), "compiling {shim} failed");
        objects.push(object);
    }

    let mut ar = Command::new("ar");
    ar.arg("crs").arg(&archive);
    for object in &objects {
        ar.arg(object);
    }
    let archived = ar
        .status()
        .expect("ar is required to build abyss-transport");
    assert!(archived.success(), "archiving the transport shims failed");

    println!("cargo:rustc-link-search=native={}", out_dir.display());
    println!("cargo:rustc-link-lib=static=abyss_transport_shim");
}
