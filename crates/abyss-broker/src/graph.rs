// SPDX-License-Identifier: BSD-2-Clause

//! The static authority graph.
//!
//! From a set of parsed [`Manifest`]s the broker computes the authority
//! graph — every component, and every connection between them — and
//! validates it, all before a single component is spawned
//! (`docs/design/broker-and-transport.md` §5.2). Because the graph is built
//! from the shipped manifests, the entire authority structure of the
//! running desktop is knowable, and auditable, in advance (`DESIGN.md`
//! §11.9).
//!
//! A [`Connection`] is formed by a `peer` capability: it names the
//! interface of the component to connect to, which the graph resolves to a
//! provider; the broker will pre-create a `SOCK_SEQPACKET` ring for it
//! (§5.2). The other capability kinds — `device`, `memory`, `casper`,
//! `settings` — are broker-mediated grants, not edges between components;
//! they are validated by the [`manifest`](crate::manifest) layer and
//! carried unchanged.

use std::collections::HashMap;
use std::collections::HashSet;
use std::collections::hash_map::Entry;
use std::fmt;

use crate::manifest::{CapabilityKind, Manifest};

/// A connection the broker will pre-wire — one `SOCK_SEQPACKET` ring.
///
/// Formed from a `peer` capability: `requester` asked to connect to the
/// component exporting `interface`, which the graph resolved to `provider`.
/// The direction records who *requested* the wiring; the ring itself is
/// bidirectional, and the broker may realize a reciprocal pair of requests
/// as a single socket pair.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Connection {
    /// The component whose manifest requested the connection.
    pub requester: String,
    /// The component exporting the requested interface.
    pub provider: String,
    /// The interface the requester named.
    pub interface: String,
}

/// The validated static authority graph.
///
/// Built by [`Graph::build`]; immutable thereafter. Component identity is
/// the manifest `name`, which the graph guarantees is unique.
#[derive(Debug, Clone)]
pub struct Graph {
    components: Vec<Manifest>,
    by_name: HashMap<String, usize>,
    by_interface: HashMap<String, usize>,
    connections: Vec<Connection>,
}

/// A set of manifests that does not form a valid authority graph.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum GraphError {
    /// Two manifests share a component `name`.
    DuplicateComponent { name: String },
    /// Two components export the same `interface`.
    DuplicateInterface {
        interface: String,
        first: String,
        second: String,
    },
    /// A `peer` capability names an interface no component exports.
    UnresolvedPeer {
        component: String,
        interface: String,
    },
    /// A `peer` capability resolves to the requesting component itself.
    SelfConnection {
        component: String,
        interface: String,
    },
}

impl fmt::Display for GraphError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::DuplicateComponent { name } => {
                write!(f, "two components are named `{name}`")
            }
            Self::DuplicateInterface {
                interface,
                first,
                second,
            } => write!(
                f,
                "components `{first}` and `{second}` both export interface `{interface}`",
            ),
            Self::UnresolvedPeer {
                component,
                interface,
            } => write!(
                f,
                "`{component}` requests peer interface `{interface}`, which no component exports",
            ),
            Self::SelfConnection {
                component,
                interface,
            } => write!(
                f,
                "`{component}` requests peer interface `{interface}`, which it exports itself",
            ),
        }
    }
}

impl std::error::Error for GraphError {}

impl Graph {
    /// Build and validate the authority graph from a set of manifests.
    ///
    /// Rejects duplicate component names, duplicate exported interfaces,
    /// `peer` capabilities that name no exporter, and self-connections.
    pub fn build(manifests: Vec<Manifest>) -> Result<Self, GraphError> {
        let mut by_name: HashMap<String, usize> = HashMap::with_capacity(manifests.len());
        let mut by_interface: HashMap<String, usize> = HashMap::with_capacity(manifests.len());

        for (i, m) in manifests.iter().enumerate() {
            match by_name.entry(m.name.clone()) {
                Entry::Occupied(_) => {
                    return Err(GraphError::DuplicateComponent {
                        name: m.name.clone(),
                    });
                }
                Entry::Vacant(slot) => slot.insert(i),
            };
            match by_interface.entry(m.interface.clone()) {
                Entry::Occupied(prior) => {
                    return Err(GraphError::DuplicateInterface {
                        interface: m.interface.clone(),
                        first: manifests[*prior.get()].name.clone(),
                        second: m.name.clone(),
                    });
                }
                Entry::Vacant(slot) => slot.insert(i),
            };
        }

        let mut connections = Vec::new();
        for m in &manifests {
            // A component naming the same peer interface twice still wants
            // just one ring.
            let mut wired: HashSet<&str> = HashSet::new();
            for cap in &m.capabilities {
                if cap.kind != CapabilityKind::Peer || !wired.insert(cap.target.as_str()) {
                    continue;
                }
                let provider = by_interface
                    .get(&cap.target)
                    .map(|&i| &manifests[i])
                    .ok_or_else(|| GraphError::UnresolvedPeer {
                        component: m.name.clone(),
                        interface: cap.target.clone(),
                    })?;
                if provider.name == m.name {
                    return Err(GraphError::SelfConnection {
                        component: m.name.clone(),
                        interface: cap.target.clone(),
                    });
                }
                connections.push(Connection {
                    requester: m.name.clone(),
                    provider: provider.name.clone(),
                    interface: cap.target.clone(),
                });
            }
        }

        Ok(Self {
            components: manifests,
            by_name,
            by_interface,
            connections,
        })
    }

    /// Every component in the graph, in manifest order.
    pub fn components(&self) -> &[Manifest] {
        &self.components
    }

    /// The component with the given name, if any.
    pub fn component(&self, name: &str) -> Option<&Manifest> {
        self.by_name.get(name).map(|&i| &self.components[i])
    }

    /// The component exporting the given interface, if any.
    pub fn exporter(&self, interface: &str) -> Option<&Manifest> {
        self.by_interface
            .get(interface)
            .map(|&i| &self.components[i])
    }

    /// Every connection the broker will pre-wire.
    pub fn connections(&self) -> &[Connection] {
        &self.connections
    }

    /// Every connection touching a component, as requester or as provider.
    pub fn connections_of<'g>(&'g self, name: &'g str) -> impl Iterator<Item = &'g Connection> {
        self.connections
            .iter()
            .filter(move |c| c.requester == name || c.provider == name)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A complete, valid manifest with the given name, interface, and an
    /// optional run of `[capability]` blocks spliced in.
    fn manifest(name: &str, interface: &str, caps: &str) -> Manifest {
        let text = format!(
            "name = {name}\ninterface = {interface}\nversion = 1\n{caps}\
             [jail]\nroot = /\nnetwork = none\nuser = _{name}\n\
             [budget]\nmemory = 1M\nfds = 8\n[restart]\npolicy = always\n",
        );
        Manifest::parse(&text).expect("test manifest parses")
    }

    fn peer(interface: &str) -> String {
        format!("[capability]\nkind = peer\ninterface = {interface}\nrights = recv\n")
    }

    #[test]
    fn builds_a_two_component_graph() {
        let g = Graph::build(vec![
            manifest("compositor", "display", &peer("input")),
            manifest("input", "input", ""),
        ])
        .expect("the graph builds");

        assert_eq!(g.components().len(), 2);
        assert_eq!(g.exporter("input").map(|m| m.name.as_str()), Some("input"));
        assert_eq!(
            g.component("compositor").map(|m| m.name.as_str()),
            Some("compositor")
        );

        assert_eq!(g.connections().len(), 1);
        let c = &g.connections()[0];
        assert_eq!(c.requester, "compositor");
        assert_eq!(c.provider, "input");
        assert_eq!(c.interface, "input");

        assert_eq!(g.connections_of("input").count(), 1);
        assert_eq!(g.connections_of("compositor").count(), 1);
    }

    #[test]
    fn an_empty_manifest_set_builds() {
        let g = Graph::build(vec![]).expect("the empty graph builds");
        assert!(g.components().is_empty());
        assert!(g.connections().is_empty());
    }

    #[test]
    fn rejects_duplicate_component_names() {
        let err = Graph::build(vec![
            manifest("twin", "alpha", ""),
            manifest("twin", "beta", ""),
        ])
        .unwrap_err();
        assert_eq!(
            err,
            GraphError::DuplicateComponent {
                name: "twin".to_string(),
            },
        );
    }

    #[test]
    fn rejects_duplicate_interfaces() {
        let err = Graph::build(vec![
            manifest("first", "display", ""),
            manifest("second", "display", ""),
        ])
        .unwrap_err();
        assert_eq!(
            err,
            GraphError::DuplicateInterface {
                interface: "display".to_string(),
                first: "first".to_string(),
                second: "second".to_string(),
            },
        );
    }

    #[test]
    fn rejects_an_unresolved_peer() {
        let err = Graph::build(vec![manifest("shell", "shell", &peer("nonesuch"))]).unwrap_err();
        assert_eq!(
            err,
            GraphError::UnresolvedPeer {
                component: "shell".to_string(),
                interface: "nonesuch".to_string(),
            },
        );
    }

    #[test]
    fn rejects_a_self_connection() {
        let err = Graph::build(vec![manifest("echo", "echo", &peer("echo"))]).unwrap_err();
        assert_eq!(
            err,
            GraphError::SelfConnection {
                component: "echo".to_string(),
                interface: "echo".to_string(),
            },
        );
    }

    #[test]
    fn non_peer_capabilities_form_no_connections() {
        let device = "[capability]\nkind = device\nclass = gpu\nrights = mmap\n";
        let g = Graph::build(vec![manifest("compositor", "display", device)])
            .expect("a device-only component builds");
        assert!(g.connections().is_empty());
    }

    #[test]
    fn deduplicates_a_repeated_peer_capability() {
        let caps = format!("{}{}", peer("input"), peer("input"));
        let g = Graph::build(vec![
            manifest("compositor", "display", &caps),
            manifest("input", "input", ""),
        ])
        .expect("the graph builds");
        // Two identical peer requests, one ring.
        assert_eq!(g.connections().len(), 1);
    }
}
