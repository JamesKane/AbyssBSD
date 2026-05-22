// SPDX-License-Identifier: BSD-2-Clause

//! Wiring a manifest set — compiled only on FreeBSD.
//!
//! [`Session`] is the broker's pre-wiring of one spawn phase
//! (`docs/design/broker-and-transport.md` §5.2): from an authority
//! [`Graph`] it pre-creates a `SOCK_SEQPACKET` ring for every connection
//! and assembles each component's bootstrap [`Bundle`], then spawns each
//! component holding its bundle.
//!
//! Activation is eager and pre-wired: every ring exists before any
//! component is spawned, so each component is born with both ends of every
//! ring it touches already assigned.

use std::collections::HashMap;
use std::io;
use std::os::fd::{AsFd, BorrowedFd};
use std::path::PathBuf;

use abyss_bundle::{Bundle, CapBody, Grant, Role};
use abyss_msg::{Envelope, Header, MessageKind};
use abyss_transport::Channel;

use crate::graph::Graph;
use crate::spawn::{Component, spawn_component};

/// The program to exec for a component — its binary and argument vector.
pub struct Program {
    /// The component binary.
    pub path: PathBuf,
    /// The argument vector after `argv[0]`.
    pub args: Vec<String>,
}

/// A component the broker has wired and spawned.
pub struct WiredComponent {
    /// The component's name.
    pub name: String,
    /// Its live process and the broker's end of its bootstrap channel.
    pub component: Component,
}

/// The broker's pre-wiring of one manifest set (§5.2).
///
/// [`Session::wire`] computes it — a `SOCK_SEQPACKET` ring per connection,
/// and each component's assembled [`Bundle`] — without spawning anything;
/// [`Session::spawn`] then brings every component into being.
pub struct Session {
    /// Each component, in graph order, paired with its bundle. A component
    /// with no connections still appears here, with an empty bundle.
    bundles: Vec<(String, Bundle)>,
}

impl Session {
    /// Pre-wire `graph`: create a `SOCK_SEQPACKET` ring for every
    /// connection and assemble each component's bundle. No process is
    /// spawned — every ring is created here, before [`spawn`](Self::spawn).
    pub fn wire(graph: &Graph) -> io::Result<Session> {
        // Seed every component with a grant list — one with no connections
        // still gets a bundle, an empty one.
        let mut grants: HashMap<String, Vec<Grant>> = graph
            .components()
            .iter()
            .map(|manifest| (manifest.name.clone(), Vec::new()))
            .collect();

        // One ring per connection: the requester holds the client end, the
        // provider the server end (§5.2).
        for connection in graph.connections() {
            let (client_end, server_end) = Channel::pair()?;
            push_grant(
                &mut grants,
                &connection.requester,
                &connection.interface,
                Role::Client,
                client_end,
            );
            push_grant(
                &mut grants,
                &connection.provider,
                &connection.interface,
                Role::Server,
                server_end,
            );
        }

        // Assemble the bundles in graph component order.
        let bundles = graph
            .components()
            .iter()
            .map(|manifest| {
                let grants = grants
                    .remove(&manifest.name)
                    .expect("every component was seeded with a grant list");
                (manifest.name.clone(), Bundle { grants })
            })
            .collect();

        Ok(Session { bundles })
    }

    /// The wired components, in graph order, each paired with its bundle.
    pub fn bundles(&self) -> &[(String, Bundle)] {
        &self.bundles
    }

    /// Spawn every wired component, each holding its bootstrap bundle.
    ///
    /// `program` resolves a component name to the binary to exec. If a
    /// spawn fails, the components already spawned are torn down before the
    /// error is returned, so a failed session leaves no jails behind.
    pub fn spawn<F>(self, program: F) -> io::Result<Vec<WiredComponent>>
    where
        F: Fn(&str) -> Program,
    {
        let mut spawned: Vec<WiredComponent> = Vec::with_capacity(self.bundles.len());
        for (name, bundle) in self.bundles {
            let program = program(&name);
            // `from_message` duplicates each grant's endpoint onto the
            // handle table; `fds` are those duplicates, sent via
            // `SCM_RIGHTS` and dropped once the datagram is away.
            let (envelope, fds) = Envelope::from_message(bundle_header(), &bundle);
            let borrowed: Vec<BorrowedFd<'_>> = fds.iter().map(AsFd::as_fd).collect();
            let args: Vec<&str> = program.args.iter().map(String::as_str).collect();
            match spawn_component(&name, &program.path, &args, &envelope, &borrowed) {
                Ok(component) => spawned.push(WiredComponent { name, component }),
                Err(err) => {
                    for wired in spawned {
                        let _ = wired.component.shutdown();
                    }
                    return Err(err);
                }
            }
        }
        Ok(spawned)
    }
}

/// Push one ring endpoint onto a component's grant list.
fn push_grant(
    grants: &mut HashMap<String, Vec<Grant>>,
    component: &str,
    interface: &str,
    role: Role,
    endpoint: Channel,
) {
    grants
        .get_mut(component)
        .expect("a connection names only components in the graph")
        .push(Grant {
            interface: interface.to_owned(),
            role,
            rights: minted_rights(),
            endpoint: endpoint.into_fd(),
        });
}

/// The rights a freshly minted ring capability carries.
///
/// Zero for now: the §3.3 mapping from a manifest's rights tokens to a
/// `cap_rights` mask and an object-rights set is not yet built, and nothing
/// enforces the mask until it is. See `docs/TECH-DEBT.md`.
fn minted_rights() -> CapBody {
    CapBody {
        cap_rights: [0u8; 16],
        object_rights: 0,
    }
}

/// The header of a bootstrap-bundle envelope. The bundle rides on no
/// interface ring, so its interface and method ids are zero (§5.3).
fn bundle_header() -> Header {
    Header {
        kind: MessageKind::Event,
        interface_id: 0,
        method_id: 0,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::manifest::Manifest;

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

    /// The single bundle of the component named `name`.
    fn bundle_of<'s>(session: &'s Session, name: &str) -> &'s Bundle {
        &session
            .bundles()
            .iter()
            .find(|(component, _)| component == name)
            .expect("the component is in the session")
            .1
    }

    #[test]
    fn wire_assembles_a_bundle_per_component() {
        // compositor → input is one connection; `log` peers no one.
        let graph = Graph::build(vec![
            manifest("compositor", "display", &peer("input")),
            manifest("input", "input", ""),
            manifest("log", "log", ""),
        ])
        .expect("the graph builds");

        let session = Session::wire(&graph).expect("the session wires");
        assert_eq!(session.bundles().len(), 3);

        // The requester holds the client end of the ring …
        let compositor = bundle_of(&session, "compositor");
        assert_eq!(compositor.grants.len(), 1);
        assert_eq!(compositor.grants[0].interface, "input");
        assert_eq!(compositor.grants[0].role, Role::Client);

        // … the provider the server end.
        let input = bundle_of(&session, "input");
        assert_eq!(input.grants.len(), 1);
        assert_eq!(input.grants[0].interface, "input");
        assert_eq!(input.grants[0].role, Role::Server);

        // A component that peers no one is wired an empty bundle.
        assert!(bundle_of(&session, "log").grants.is_empty());
    }

    #[test]
    fn an_empty_manifest_set_wires_to_an_empty_session() {
        let session = Session::wire(&Graph::build(vec![]).expect("graph")).expect("wire");
        assert!(session.bundles().is_empty());
    }
}
