// SPDX-License-Identifier: BSD-2-Clause

//! End to end: the broker spawns components, and each one bootstraps,
//! confines itself, and finds the capabilities the broker wired it
//! (`broker-and-transport.md` §5.2–§5.4).

#![cfg(target_os = "freebsd")]

use std::collections::HashMap;
use std::path::PathBuf;

use abyss_broker::catalogue::InterfaceCatalogue;
use abyss_broker::graph::Graph;
use abyss_broker::manifest::Manifest;
use abyss_broker::session::{Exit, Program, Session};
use abyss_broker::spawn::spawn_component;
use abyss_broker::spawnable::SpawnableSet;
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

/// A `peer` capability that requests no rights — the broker grants it an
/// empty object-rights mask.
fn peer_unrighted(interface: &str) -> String {
    format!("[capability]\nkind = peer\ninterface = {interface}\n")
}

/// A probe's four-field report: `[confined, grant count, client
/// capabilities claimed, role outcome]`.
fn read_report(report: &Envelope) -> [i64; 4] {
    let Value::List(items) = &report.payload else {
        panic!("unexpected probe report payload: {:?}", report.payload);
    };
    assert_eq!(items.len(), 4, "the probe report has four fields");
    let field = |index: usize| match &items[index] {
        Value::Int(n) => *n,
        other => panic!("report[{index}] is not an int: {other:?}"),
    };
    [field(0), field(1), field(2), field(3)]
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

    let [confined, grants, client_caps, outcome] = read_report(&report);
    assert_eq!(
        confined, 1,
        "the component entered Capsicum capability mode"
    );
    assert_eq!(grants, 0, "an empty bundle carried no grants");
    assert_eq!(client_caps, 0, "and so no client capabilities to claim");
    assert_eq!(outcome, 0, "and no peer to converse with");
}

#[test]
fn a_wired_session_lets_its_components_converse() {
    // compositor → input is one connection; `log` peers no one.
    let graph = Graph::build(vec![
        manifest("compositor", "display", &peer("input")),
        manifest("input", "input", ""),
        manifest("log", "log", ""),
    ])
    .expect("the graph builds");

    // Launch the session — a ring per connection, a bundle per component —
    // spawning every component as the bootstrap probe. The catalogue
    // resolves the `input` peer capability's `recv` rights class. The
    // session is not stepped, so the probes run and exit unsupervised; its
    // `Drop` removes every jail.
    let mut catalogue = InterfaceCatalogue::new();
    catalogue.register("input", &[("recv", 1)]);
    let binary = probe();
    let session = Session::launch(graph, catalogue, SpawnableSet::new(), |_name| Program {
        path: binary.clone(),
        args: Vec::new(),
    })
    .expect("launch the wired session");
    assert_eq!(session.components().count(), 3);

    let mut reports: HashMap<String, [i64; 4]> = HashMap::new();
    for (name, component) in session.components() {
        component.wait().expect("the component runs and exits");
        let (report, _fds) = component
            .bootstrap()
            .recv()
            .expect("the component reports back");
        let fields = read_report(&report);
        assert_eq!(fields[0], 1, "{name} is in capability mode");
        reports.insert(name.to_owned(), fields);
    }

    // The conversation, end to end: each report is
    // `[confined, grants, client caps, outcome]`.
    //
    // compositor — the requester — claims one client capability, binds it,
    // and `call`s; its outcome is the `Ping` value (41) the server echoed.
    assert_eq!(reports["compositor"], [1, 1, 1, 41]);
    // input — the provider — has one grant, the server end (no client
    // cap); it served one request.
    assert_eq!(reports["input"], [1, 1, 0, 1]);
    // log peers no one: nothing claimed, no peer to converse with.
    assert_eq!(reports["log"], [1, 0, 0, 0]);
}

#[test]
fn a_wired_session_refuses_an_ungranted_call() {
    // `caller` peers `callee`'s interface, but its peer capability
    // requests no rights — the broker grants it an empty object-rights
    // mask. Distinct component names from the other session test, so the
    // two can run in parallel without colliding on jail names.
    let graph = Graph::build(vec![
        manifest("caller", "caller-view", &peer_unrighted("callee-svc")),
        manifest("callee", "callee-svc", ""),
    ])
    .expect("the graph builds");

    let mut catalogue = InterfaceCatalogue::new();
    catalogue.register("callee-svc", &[("recv", 1)]);

    let binary = probe();
    let session = Session::launch(graph, catalogue, SpawnableSet::new(), |_name| Program {
        path: binary.clone(),
        args: Vec::new(),
    })
    .expect("launch the wired session");
    assert_eq!(session.components().count(), 2);

    let mut caller_report = None;
    for (name, component) in session.components() {
        component.wait().expect("the component runs and exits");
        // The client reports the call's outcome; the server refuses the
        // call and never reports — it just winds down once the client
        // exits and closes the ring.
        if name == "caller" {
            let (report, _fds) = component.bootstrap().recv().expect("caller reports back");
            caller_report = Some(read_report(&report));
        }
    }

    // `caller`'s call named `Ping`, outside the empty mask it was granted;
    // the service refused it and `Cap::call` reported it — the outcome
    // field is -1, the rights-denied sentinel.
    assert_eq!(caller_report, Some([1, 1, 1, -1]));
}

#[test]
fn a_restarted_peer_is_re_wired_and_a_call_after_it_still_answers() {
    // `rt-client` → `rt-server` over `rt-echo`. The probe server answers
    // one `Ping` and exits, so the broker restarts it; the client is the
    // §5.5 durable client — it calls once, waits for the `PeerRestarted`
    // that re-wires it, and calls again. The second call must reach the
    // fresh server (`broker-and-transport.md` §5.5).
    let graph = Graph::build(vec![
        manifest("rt-client", "rt-client-iface", &peer("rt-echo")),
        manifest("rt-server", "rt-echo", ""),
    ])
    .expect("the graph builds");

    let mut catalogue = InterfaceCatalogue::new();
    catalogue.register("rt-echo", &[("recv", 1)]);

    // The `durable` argument selects the probe's §5.5 client path; the
    // server runs the ordinary serve-one-then-exit path.
    let binary = probe();
    let mut session = Session::launch(graph, catalogue, SpawnableSet::new(), |name| Program {
        path: binary.clone(),
        args: if name == "rt-client" {
            vec!["durable".to_owned()]
        } else {
            Vec::new()
        },
    })
    .expect("launch the wired session");

    // The server answers the client's first call, then exits; `step`
    // re-wires the connection and respawns the server, sending the client
    // a `PeerRestarted` over its control channel.
    let restarted = session.step().expect("supervise the server's exit");
    assert_eq!(
        restarted,
        vec![Exit {
            name: "rt-server".to_owned(),
            restarted: true,
        }],
    );

    // The client reports once its *second* call has returned — which it
    // can only do after the re-wire reached it.
    let (report, _fds) = session
        .component("rt-client")
        .expect("the client is live")
        .bootstrap()
        .recv()
        .expect("the client reports back");
    let [confined, grants, first, second] = read_report(&report);
    assert_eq!(confined, 1, "the client is in capability mode");
    assert_eq!(
        grants, 1,
        "the client holds one grant — its echo client cap"
    );
    assert_eq!(first, 41, "the first call reached the original server");
    assert_eq!(
        second, 77,
        "the second call reached the re-wired, freshly restarted server",
    );
}
