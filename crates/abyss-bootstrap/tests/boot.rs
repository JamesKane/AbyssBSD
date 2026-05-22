// SPDX-License-Identifier: BSD-2-Clause

//! End to end: the broker's boot path reads a manifest set and the
//! interface catalogue from disk, builds the authority graph, and launches
//! the session — every component spawned, wired, and conversing
//! (`broker-and-transport.md` §5.1).

#![cfg(target_os = "freebsd")]

use std::collections::HashMap;
use std::fs;
use std::os::unix::fs::symlink;
use std::path::PathBuf;

use abyss_broker::boot;
use abyss_msg::{Envelope, Value};

/// The bootstrap probe binary — the fixture component every manifest in
/// this test resolves to.
fn probe() -> PathBuf {
    PathBuf::from(env!("CARGO_BIN_EXE_component-probe"))
}

/// A temp directory tree unique to the test, removed when dropped: a
/// `manifests/` directory, a `catalogue` file, and a `bin/` directory.
struct BootTree {
    root: PathBuf,
}

impl BootTree {
    fn new() -> BootTree {
        let mut root = std::env::temp_dir();
        root.push(format!("abyss-broker-boot-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        fs::create_dir(&root).expect("create the boot tree root");
        fs::create_dir(root.join("manifests")).expect("create the manifests directory");
        fs::create_dir(root.join("bin")).expect("create the bin directory");
        BootTree { root }
    }

    /// Write a component manifest, and symlink the component's binary —
    /// `bin/<name>` — to the probe, as the broker's `bin_dir/<name>`
    /// convention expects.
    fn component(&self, name: &str, manifest: &str) {
        fs::write(self.root.join("manifests").join(name), manifest)
            .expect("write a component manifest");
        symlink(probe(), self.root.join("bin").join(name)).expect("symlink the component binary");
    }

    fn catalogue(&self, contents: &str) {
        fs::write(self.root.join("catalogue"), contents).expect("write the catalogue");
    }

    fn manifests_dir(&self) -> PathBuf {
        self.root.join("manifests")
    }

    fn catalogue_file(&self) -> PathBuf {
        self.root.join("catalogue")
    }

    fn bin_dir(&self) -> PathBuf {
        self.root.join("bin")
    }
}

impl Drop for BootTree {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.root);
    }
}

/// The text of a component manifest: `name`, the interface it exports, and
/// an optional run of `[capability]` blocks spliced in.
fn manifest(name: &str, interface: &str, caps: &str) -> String {
    format!(
        "name = {name}\ninterface = {interface}\nversion = 1\n{caps}\
         [jail]\nroot = /\nnetwork = none\nuser = _{name}\n\
         [budget]\nmemory = 1M\nfds = 8\n[restart]\npolicy = always\n",
    )
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
fn the_broker_boots_a_wired_session_from_disk() {
    // boot-compositor → boot-input over `boot-input-iface`; boot-log peers
    // no one. Distinct component names from the other end-to-end tests, so
    // they can run in parallel without colliding on jail names.
    let tree = BootTree::new();
    tree.component(
        "boot-compositor",
        &manifest(
            "boot-compositor",
            "boot-display",
            "[capability]\nkind = peer\ninterface = boot-input-iface\nrights = recv\n",
        ),
    );
    tree.component(
        "boot-input",
        &manifest("boot-input", "boot-input-iface", ""),
    );
    tree.component("boot-log", &manifest("boot-log", "boot-log-iface", ""));

    // The catalogue resolves the peer capability's `recv` class — the
    // probe's `Ping` is method ordinal 0, in the `recv` class.
    tree.catalogue("[interface]\nname = boot-input-iface\nrecv = 0\n");

    // Boot the broker: load the manifests and catalogue, build the graph,
    // launch the session. The session is not stepped — the probes run and
    // exit unsupervised; the `Session`'s `Drop` removes every jail.
    let session = boot(
        &tree.manifests_dir(),
        &tree.catalogue_file(),
        &tree.bin_dir(),
    )
    .expect("the broker boots the session");
    assert_eq!(session.components().count(), 3);

    let mut reports: HashMap<String, [i64; 4]> = HashMap::new();
    for (name, component) in session.components() {
        component.wait().expect("the component runs and exits");
        let (report, _fds) = component
            .bootstrap()
            .recv()
            .expect("the component reports back");
        reports.insert(name.to_owned(), read_report(&report));
    }

    // The conversation, end to end, from manifests and a catalogue on
    // disk: each report is `[confined, grants, client caps, outcome]`.
    assert_eq!(
        reports["boot-compositor"],
        [1, 1, 1, 41],
        "the requester claimed its cap, called, and got the echoed Ping",
    );
    assert_eq!(
        reports["boot-input"],
        [1, 1, 0, 1],
        "the provider served one request",
    );
    assert_eq!(
        reports["boot-log"],
        [1, 0, 0, 0],
        "the component that peers no one had nothing to do",
    );
}
