// SPDX-License-Identifier: BSD-2-Clause

//! A minimal AbyssBSD component — the bootstrap probe.
//!
//! It runs the startup shim and reports back to the broker over the
//! bootstrap channel: whether the process is in Capsicum capability mode,
//! how many capability grants its bootstrap bundle carried, and how many
//! of them it could claim as typed client capabilities. It is the fixture
//! the broker's spawn, wiring, and bootstrap path
//! (`broker-and-transport.md` §5.2–§5.4) is tested against.

#[cfg(target_os = "freebsd")]
fn main() {
    use abyss_bundle::Role;
    use abyss_cap::{Cap, Interface, Rights};
    use abyss_msg::{Envelope, Header, MessageKind, Value};

    // A marker interface, enough to name a `Cap`'s type. The probe never
    // sends on it — binding a claimed capability and using it is a later
    // step (§3.5).
    #[allow(dead_code)] // a marker type — only ever a type parameter
    struct ProbeInterface;
    impl Interface for ProbeInterface {
        const ID: u32 = 1;
        type Message = i64;
    }
    #[allow(dead_code)] // a marker type — only ever a type parameter
    struct AnyRights;
    impl Rights for AnyRights {}

    let mut startup = abyss_bootstrap::enter().expect("component bootstrap");

    // `enter` has called `cap_enter`; confirm the process is confined.
    let confined = freebsd_capsicum_sys::cap_getmode().expect("cap_getmode");

    let grant_count = startup.grants().len();

    // Claim each `client` grant as an unbound typed capability — exercising
    // the shim's bundle decoding and role discrimination (§5.4).
    let client_interfaces: Vec<String> = startup
        .grants()
        .iter()
        .filter(|grant| grant.role == Role::Client)
        .map(|grant| grant.interface.clone())
        .collect();
    let mut client_caps: i64 = 0;
    for interface in &client_interfaces {
        let claimed: Option<Cap<ProbeInterface, AnyRights>> = startup.take_client_cap(interface);
        if claimed.is_some() {
            client_caps += 1;
        }
    }

    // Report to the broker over the bootstrap channel — which, being an
    // already-open descriptor, stays usable in capability mode.
    let report = Envelope {
        header: Header {
            kind: MessageKind::Event,
            interface_id: 0,
            method_id: 0,
        },
        payload: Value::List(vec![
            Value::Int(i64::from(confined)),
            Value::Int(i64::try_from(grant_count).expect("the grant count fits an i64")),
            Value::Int(client_caps),
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
