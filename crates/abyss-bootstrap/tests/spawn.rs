// SPDX-License-Identifier: BSD-2-Clause

//! End to end: the broker spawns a component, and the component bootstraps
//! and confines itself (`broker-and-transport.md` §5.3–§5.4).

#![cfg(target_os = "freebsd")]

use std::path::Path;

use abyss_broker::spawn::spawn_component;
use abyss_msg::{Envelope, Header, MessageKind, Value};

#[test]
fn a_spawned_component_bootstraps_and_confines_itself() {
    let bundle = Envelope {
        header: Header {
            kind: MessageKind::Event,
            interface_id: 9,
            method_id: 2,
        },
        payload: Value::Int(0),
        handles: Vec::new(),
    };

    let probe = Path::new(env!("CARGO_BIN_EXE_component-probe"));
    let name = format!("bootstrap-test-{}", std::process::id());
    let component = spawn_component(&name, probe, &[], &bundle).expect("spawn the probe component");

    // Wait for the probe to finish before reading its report: if it sent
    // one it is buffered on the socket, and if it crashed the closed
    // channel reports an error rather than the read blocking forever.
    component.wait().expect("the component runs and exits");
    let (report, _fds) = component
        .bootstrap()
        .recv()
        .expect("the component reports back over the bootstrap channel");
    component.shutdown().expect("remove the component jail");

    assert_eq!(
        report.header, bundle.header,
        "the component received the bundle the broker sent",
    );
    assert_eq!(
        report.payload,
        Value::Int(1),
        "the component entered Capsicum capability mode",
    );
}
