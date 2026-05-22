// SPDX-License-Identifier: BSD-2-Clause

//! A minimal AbyssBSD component — the bootstrap probe.
//!
//! It runs the startup shim and reports back to the broker over the
//! bootstrap channel: it echoes the bundle's header, reports whether the
//! process is in Capsicum capability mode, and decodes its bootstrap
//! bundle and reports how many capability grants it carried. It is the
//! fixture the broker's spawn, wiring, and bootstrap path
//! (`broker-and-transport.md` §5.2–§5.4) is tested against.

#[cfg(target_os = "freebsd")]
fn main() {
    use abyss_bundle::Bundle;
    use abyss_msg::{Envelope, Value};

    let startup = abyss_bootstrap::enter().expect("component bootstrap");

    // `enter` has called `cap_enter`; confirm the process is confined.
    let confined = freebsd_capsicum_sys::cap_getmode().expect("cap_getmode");

    // Decode the bootstrap bundle: each grant is a capability the broker
    // wired in (§5.2). The probe only counts them — turning a grant into a
    // live capability is the startup shim's job (§5.4, §3.5).
    let header = startup.bundle.header.clone();
    let bundle = startup
        .bundle
        .into_message::<Bundle>(startup.handles)
        .expect("decode the bootstrap bundle");
    let grant_count = i64::try_from(bundle.grants.len()).expect("the grant count fits an i64");

    // Report to the broker over the bootstrap channel — which, being an
    // already-open descriptor, stays usable in capability mode.
    let report = Envelope {
        header,
        payload: Value::List(vec![
            Value::Int(i64::from(confined)),
            Value::Int(grant_count),
        ]),
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
