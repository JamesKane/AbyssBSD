// SPDX-License-Identifier: BSD-2-Clause

//! End to end: the broker spawns components, and each one bootstraps,
//! confines itself, and finds the capabilities the broker wired it
//! (`broker-and-transport.md` §5.2–§5.4).

#![cfg(target_os = "freebsd")]

use std::collections::HashMap;
use std::path::PathBuf;

use abyss_broker::graph::Graph;
use abyss_broker::manifest::Manifest;
use abyss_broker::session::{Program, Session};
use abyss_broker::spawn::spawn_component;
use abyss_bundle::Bundle;
use abyss_msg::{Envelope, Header, MessageKind, Value};

/// The bootstrap probe binary — the fixture component.
fn probe() -> PathBuf {
    PathBuf::from(env!("CARGO_BIN_EXE_component-probe"))
}

/// A complete, valid manifest with the given name, interface, and an
/// optional run of `[capability]` blocks spliced in.
fn manifest(name: &str, interface: &str, caps: &str) -> Manifest {
    let text = format!(
        "name = {name}\ninterface = {interface}\nversion = 1\n{caps}\
         [jail]\nroot = /\nnetwork = none\nuser = _{name}\n\
         [budget]\nmemory = 1M\nfds = 8\n[restart]\npolicy = always\n",
    );
    Manifest::parse(&text).expect("the test manifest parses")
}

fn peer(interface: &str) -> String {
    format!("[capability]\nkind = peer\ninterface = {interface}\nrights = recv\n")
}

/// The `(confined, grant count, client capabilities claimed)` a probe
/// reports back.
fn read_report(report: &Envelope) -> (i64, i64, i64) {
    let Value::List(items) = &report.payload else {
        panic!("unexpected probe report payload: {:?}", report.payload);
    };
    assert_eq!(items.len(), 3, "the probe report has three fields");
    let field = |index: usize| match &items[index] {
        Value::Int(n) => *n,
        other => panic!("report[{index}] is not an int: {other:?}"),
    };
    (field(0), field(1), field(2))
}

#[test]
fn a_spawned_component_bootstraps_and_confines_itself() {
    // An empty bundle — no grants — carried as a real `Bundle` payload.
    let (envelope, fds) = Envelope::from_message(
        Header {
            kind: MessageKind::Event,
            interface_id: 9,
            method_id: 2,
        },
        &Bundle { grants: Vec::new() },
    );
    assert!(fds.is_empty(), "an empty bundle carries no descriptors");

    let name = format!("bootstrap-test-{}", std::process::id());
    let component =
        spawn_component(&name, &probe(), &[], &envelope, &[]).expect("spawn the probe component");

    // Wait for the probe to finish before reading its report: if it sent
    // one it is buffered on the socket, and if it crashed the closed
    // channel reports an error rather than the read blocking forever.
    component.wait().expect("the component runs and exits");
    let (report, _fds) = component
        .bootstrap()
        .recv()
        .expect("the component reports back over the bootstrap channel");
    component.shutdown().expect("remove the component jail");

    let (confined, grants, client_caps) = read_report(&report);
    assert_eq!(
        confined, 1,
        "the component entered Capsicum capability mode"
    );
    assert_eq!(grants, 0, "an empty bundle carried no grants");
    assert_eq!(client_caps, 0, "and so no client capabilities to claim");
}

#[test]
fn a_wired_session_delivers_each_components_grants() {
    // compositor → input is one connection; `log` peers no one.
    let graph = Graph::build(vec![
        manifest("compositor", "display", &peer("input")),
        manifest("input", "input", ""),
        manifest("log", "log", ""),
    ])
    .expect("the graph builds");

    // Wire the session — a ring per connection, a bundle per component —
    // and spawn every component as the bootstrap probe.
    let session = Session::wire(&graph).expect("the session wires");
    let binary = probe();
    let wired = session
        .spawn(|_name| Program {
            path: binary.clone(),
            args: Vec::new(),
        })
        .expect("spawn the wired session");
    assert_eq!(wired.len(), 3);

    // Per component: (grant count, client capabilities claimed).
    let mut reports: HashMap<String, (i64, i64)> = HashMap::new();
    for wired_component in wired {
        wired_component
            .component
            .wait()
            .expect("the component runs and exits");
        let (report, _fds) = wired_component
            .component
            .bootstrap()
            .recv()
            .expect("the component reports back");
        let (confined, grants, client_caps) = read_report(&report);
        assert_eq!(
            confined, 1,
            "{} is in capability mode",
            wired_component.name
        );
        reports.insert(wired_component.name.clone(), (grants, client_caps));
        wired_component
            .component
            .shutdown()
            .expect("remove the component jail");
    }

    // Each component received exactly the grants its connections imply,
    // and claimed a client capability for each connection it requested:
    // compositor requests `input` (one client grant); input provides it
    // (one grant, but a server one — no client cap); log peers no one.
    assert_eq!(reports["compositor"], (1, 1));
    assert_eq!(reports["input"], (1, 0));
    assert_eq!(reports["log"], (0, 0));
}
