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

/// The `confined` flag and grant count a probe reports back.
fn read_report(report: &Envelope) -> (i64, i64) {
    match &report.payload {
        Value::List(items) if items.len() == 2 => {
            let confined = match &items[0] {
                Value::Int(n) => *n,
                other => panic!("report[0] not an int: {other:?}"),
            };
            let grants = match &items[1] {
                Value::Int(n) => *n,
                other => panic!("report[1] not an int: {other:?}"),
            };
            (confined, grants)
        }
        other => panic!("unexpected probe report payload: {other:?}"),
    }
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

    assert_eq!(
        report.header, envelope.header,
        "the component received the bundle the broker sent",
    );
    let (confined, grants) = read_report(&report);
    assert_eq!(
        confined, 1,
        "the component entered Capsicum capability mode"
    );
    assert_eq!(grants, 0, "an empty bundle carried no grants");
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

    let mut grant_counts: HashMap<String, i64> = HashMap::new();
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
        let (confined, grants) = read_report(&report);
        assert_eq!(
            confined, 1,
            "{} is in capability mode",
            wired_component.name
        );
        grant_counts.insert(wired_component.name.clone(), grants);
        wired_component
            .component
            .shutdown()
            .expect("remove the component jail");
    }

    // Each component received exactly the grants its connections imply:
    // the requester and the provider one ring end each, `log` none.
    assert_eq!(grant_counts["compositor"], 1);
    assert_eq!(grant_counts["input"], 1);
    assert_eq!(grant_counts["log"], 0);
}
