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
    /// The object-rights classes the requester asked for on this
    /// connection — the `rights` of its `peer` capability (§3.3). The
    /// broker resolves these against the interface's catalogue to mint the
    /// connection's object-rights mask.
    pub rights: Vec<String>,
}

/// The validated authority graph.
///
/// Built by [`Graph::build`] from the boot manifest set; a delegated
/// child may join it later through [`Graph::add`] (§5.6), validated the
/// same way. Component identity is the manifest `name`, which the graph
/// guarantees is unique.
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
        let mut graph = Graph {
            components: Vec::with_capacity(manifests.len()),
            by_name: HashMap::with_capacity(manifests.len()),
            by_interface: HashMap::with_capacity(manifests.len()),
            connections: Vec::new(),
        };
        // Two passes: every node first, so a `peer` may resolve to a
        // component declared either before or after the requester.
        for manifest in manifests {
            graph.insert_node(manifest)?;
        }
        let mut connections = Vec::new();
        for manifest in &graph.components {
            connections.extend(graph.connections_for(manifest)?);
        }
        graph.connections = connections;
        Ok(graph)
    }

    /// Add one component to a built graph — a delegated child joining a
    /// running session (`broker-and-transport.md` §5.6).
    ///
    /// Validates and connects the new node exactly as [`build`](Self::build)
    /// does — a duplicate name or interface, or a `peer` capability that
    /// resolves to no exporter, is rejected. Its connections resolve
    /// against the components already in the graph. A rejected add leaves
    /// the graph unchanged.
    pub fn add(&mut self, manifest: Manifest) -> Result<(), GraphError> {
        // Resolve the new node's connections first — it is not yet in the
        // graph, so this mutates nothing and a rejection leaves it pristine.
        let connections = self.connections_for(&manifest)?;
        self.insert_node(manifest)?;
        self.connections.extend(connections);
        Ok(())
    }

    /// Insert a node — its name and interface — rejecting a duplicate of
    /// either. Checks both before mutating, so a rejection changes nothing.
    fn insert_node(&mut self, manifest: Manifest) -> Result<(), GraphError> {
        if self.by_name.contains_key(&manifest.name) {
            return Err(GraphError::DuplicateComponent {
                name: manifest.name.clone(),
            });
        }
        if let Some(&prior) = self.by_interface.get(&manifest.interface) {
            return Err(GraphError::DuplicateInterface {
                interface: manifest.interface.clone(),
                first: self.components[prior].name.clone(),
                second: manifest.name.clone(),
            });
        }
        let index = self.components.len();
        self.by_name.insert(manifest.name.clone(), index);
        self.by_interface.insert(manifest.interface.clone(), index);
        self.components.push(manifest);
        Ok(())
    }

    /// The `peer` connections `manifest` forms against the components
    /// already in the graph — non-mutating.
    ///
    /// Rejects a `peer` capability that resolves to no exporter, or to the
    /// requester itself. A component naming the same peer interface twice
    /// still forms just one connection.
    pub fn connections_for(&self, manifest: &Manifest) -> Result<Vec<Connection>, GraphError> {
        let mut connections = Vec::new();
        let mut wired: HashSet<&str> = HashSet::new();
        for cap in &manifest.capabilities {
            if cap.kind != CapabilityKind::Peer || !wired.insert(cap.target.as_str()) {
                continue;
            }
            let provider = self
                .by_interface
                .get(&cap.target)
                .map(|&i| &self.components[i])
                .ok_or_else(|| GraphError::UnresolvedPeer {
                    component: manifest.name.clone(),
                    interface: cap.target.clone(),
                })?;
            if provider.name == manifest.name {
                return Err(GraphError::SelfConnection {
                    component: manifest.name.clone(),
                    interface: cap.target.clone(),
                });
            }
            connections.push(Connection {
                requester: manifest.name.clone(),
                provider: provider.name.clone(),
                interface: cap.target.clone(),
                rights: cap.rights.clone(),
            });
        }
        Ok(connections)
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

    #[test]
    fn add_extends_a_built_graph_with_a_delegated_child() {
        let mut g = Graph::build(vec![manifest("input", "input", "")]).expect("the graph builds");
        assert!(g.connections().is_empty());

        // A delegated child that peers the already-running `input`.
        g.add(manifest("compositor", "display", &peer("input")))
            .expect("the child joins the graph");

        assert_eq!(
            g.component("compositor").map(|m| m.name.as_str()),
            Some("compositor"),
        );
        assert_eq!(g.connections().len(), 1);
        let c = &g.connections()[0];
        assert_eq!(c.requester, "compositor");
        assert_eq!(c.provider, "input");
        assert_eq!(g.connections_of("input").count(), 1);
        assert_eq!(g.connections_of("compositor").count(), 1);
    }

    #[test]
    fn add_rejects_a_duplicate_name_and_changes_nothing() {
        let mut g = Graph::build(vec![manifest("twin", "alpha", "")]).expect("the graph builds");
        let err = g.add(manifest("twin", "beta", "")).unwrap_err();
        assert_eq!(
            err,
            GraphError::DuplicateComponent {
                name: "twin".to_string(),
            },
        );
        assert_eq!(
            g.components().len(),
            1,
            "the rejected add left the graph unchanged"
        );
    }

    #[test]
    fn add_rejects_an_unresolved_peer_and_changes_nothing() {
        let mut g = Graph::build(vec![manifest("input", "input", "")]).expect("the graph builds");
        let err = g
            .add(manifest("shell", "shell", &peer("nonesuch")))
            .unwrap_err();
        assert_eq!(
            err,
            GraphError::UnresolvedPeer {
                component: "shell".to_string(),
                interface: "nonesuch".to_string(),
            },
        );
        assert_eq!(
            g.components().len(),
            1,
            "the rejected add left the graph unchanged"
        );
        assert!(g.connections().is_empty());
    }
}
