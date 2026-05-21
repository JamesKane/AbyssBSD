// SPDX-License-Identifier: BSD-2-Clause

//! A minimal AbyssBSD component — the bootstrap probe.
//!
//! It runs the startup shim and reports back to the broker over the
//! bootstrap channel: it echoes the bundle's header, so the broker can
//! confirm the bundle arrived intact, and reports whether the process is
//! in Capsicum capability mode. It is the fixture the broker's
//! spawn-and-bootstrap path (`broker-and-transport.md` §5.3–§5.4) is
//! tested against.

#[cfg(target_os = "freebsd")]
fn main() {
    use abyss_msg::{Envelope, Value};

    let startup = abyss_bootstrap::enter().expect("component bootstrap");

    // `enter` has called `cap_enter`; confirm the process is confined and
    // report to the broker over the bootstrap channel — which, being an
    // already-open descriptor, stays usable in capability mode.
    let confined = freebsd_capsicum_sys::cap_getmode().expect("cap_getmode");
    let report = Envelope {
        header: startup.bundle.header,
        payload: Value::Int(i64::from(confined)),
        handles: Vec::new(),
    };
    startup
        .bootstrap
        .send(&report, &[])
        .expect("report to the broker");
}

#[cfg(not(target_os = "freebsd"))]
fn main() {
    // The bootstrap probe is a FreeBSD component; elsewhere it is a stub so
    // the workspace still builds on the macOS dev bed.
}
