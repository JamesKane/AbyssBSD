// SPDX-License-Identifier: BSD-2-Clause

//! Compile the DRM/KMS C shim — FreeBSD only.
//!
//! `c/drm_shim.c` evaluates the kernel uAPI's `DRM_IOCTL_MODE_*` macros
//! at C-compile time and exposes the results as `extern const unsigned
//! long abyss_drm_ioctl_*` symbols Rust can read. The macros expand to
//! BSD's `_IOR` / `_IOWR` and so cannot be reached by Rust FFI directly
//! — the C-shim pattern of `freebsd-capsicum-sys` (see
//! `docs/design/broker-and-transport.md` §6 and the project's
//! conventions).
//!
//! `libdrm` (the FreeBSD port) supplies the headers; `pkg-config
//! --cflags-only-I libdrm` yields `-I/usr/local/include/libdrm`, the
//! ports convention (the same `pkg-config` pattern `abyss-font` uses).
//! The shim does not link libdrm.so — it borrows libdrm only for the
//! headers.
//!
//! On every non-FreeBSD host the shim is not built and the crate
//! compiles to an empty library, so the workspace still builds on the
//! macOS dev bed.

use std::env;
use std::path::PathBuf;
use std::process::Command;

/// Ask `pkg-config` for `flag` for `package`; return whitespace-split.
fn pkg_config(flag: &str, package: &str) -> Vec<String> {
    let output = Command::new("pkg-config")
        .arg(flag)
        .arg(package)
        .output()
        .expect("pkg-config must be installed to build drm-sys");
    assert!(
        output.status.success(),
        "pkg-config could not find `{package}` — is libdrm installed? (pkg install libdrm)"
    );
    String::from_utf8_lossy(&output.stdout)
        .split_whitespace()
        .map(str::to_owned)
        .collect()
}

fn main() {
    println!("cargo:rerun-if-changed=c/drm_shim.c");
    println!("cargo:rerun-if-changed=build.rs");
    println!("cargo:rerun-if-env-changed=CC");

    if env::var("CARGO_CFG_TARGET_OS").as_deref() != Ok("freebsd") {
        return;
    }

    let out_dir = PathBuf::from(env::var("OUT_DIR").expect("OUT_DIR is set for build scripts"));
    let object = out_dir.join("drm_shim.o");
    let archive = out_dir.join("libabyss_drm_shim.a");

    // libdrm's headers live under /usr/local/include/libdrm on FreeBSD.
    // `<libdrm/drm.h>` resolves with the parent dir on the include path.
    let includes = pkg_config("--cflags-only-I", "libdrm");

    let cc = env::var("CC").unwrap_or_else(|_| "cc".to_owned());
    let compiled = Command::new(&cc)
        .args(["-c", "-O2", "-fPIC"])
        .args(&includes)
        .arg("c/drm_shim.c")
        .arg("-o")
        .arg(&object)
        .status()
        .expect("a C compiler (cc) is required to build drm-sys");
    assert!(compiled.success(), "compiling the DRM shim failed");

    let archived = Command::new("ar")
        .arg("crs")
        .arg(&archive)
        .arg(&object)
        .status()
        .expect("ar is required to build drm-sys");
    assert!(archived.success(), "archiving the DRM shim failed");

    println!("cargo:rustc-link-search=native={}", out_dir.display());
    println!("cargo:rustc-link-lib=static=abyss_drm_shim");
}
