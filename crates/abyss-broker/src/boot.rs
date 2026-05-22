// SPDX-License-Identifier: BSD-2-Clause

//! Bringing a session up from disk — compiled only on FreeBSD.
//!
//! [`boot`] is the broker's boot path (`docs/design/broker-and-transport.md`
//! §5.1): it reads a manifest set and the interface catalogue from disk,
//! builds and validates the static authority graph, and launches the
//! session — every component spawned into its jail, wired, and supervised.
//! The broker binary (`src/bin/broker.rs`) is a thin shell around it: call
//! `boot`, then drive [`Session::step`] for the life of the session.

use std::fmt;
use std::path::Path;

use crate::catalogue::{CatalogueLoadError, InterfaceCatalogue};
use crate::graph::{Graph, GraphError};
use crate::manifest::{LoadError, Manifest};
use crate::session::{Program, Session, SessionError};

/// Why the broker could not bring a session up — a boot fault (§5.1).
#[derive(Debug)]
pub enum BootError {
    /// The manifest set could not be loaded.
    Manifests(LoadError),
    /// The manifests do not form a valid authority graph.
    Graph(GraphError),
    /// The interface catalogue could not be loaded.
    Catalogue(CatalogueLoadError),
    /// The session could not be wired and spawned.
    Session(SessionError),
}

impl fmt::Display for BootError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            BootError::Manifests(err) => write!(f, "boot fault: {err}"),
            BootError::Graph(err) => write!(f, "boot fault: invalid authority graph: {err}"),
            BootError::Catalogue(err) => write!(f, "boot fault: {err}"),
            BootError::Session(err) => write!(f, "boot fault: {err}"),
        }
    }
}

impl std::error::Error for BootError {}

impl From<LoadError> for BootError {
    fn from(err: LoadError) -> Self {
        BootError::Manifests(err)
    }
}

impl From<GraphError> for BootError {
    fn from(err: GraphError) -> Self {
        BootError::Graph(err)
    }
}

impl From<CatalogueLoadError> for BootError {
    fn from(err: CatalogueLoadError) -> Self {
        BootError::Catalogue(err)
    }
}

impl From<SessionError> for BootError {
    fn from(err: SessionError) -> Self {
        BootError::Session(err)
    }
}

/// Bring a session up from disk (§5.1).
///
/// `manifest_dir` is the directory of component manifests (§4, §5.2);
/// `catalogue_file` is the interface catalogue (§3.3); `bin_dir` is where
/// component binaries live — a component named `n` is run from the binary
/// `bin_dir/n` (§5.3). Returns the launched [`Session`] — every component
/// spawned, wired, and supervised — for the caller to drive with
/// [`Session::step`].
///
/// Any failure along the way is a [`BootError`]: a boot fault, which the
/// broker reports before dropping to the recovery floor (§5.1, §9).
pub fn boot(
    manifest_dir: &Path,
    catalogue_file: &Path,
    bin_dir: &Path,
) -> Result<Session, BootError> {
    let manifests = Manifest::load_dir(manifest_dir)?;
    let graph = Graph::build(manifests)?;
    let catalogue = InterfaceCatalogue::load(catalogue_file)?;

    // A component is run from `bin_dir/<name>` and takes no arguments —
    // its bootstrap bundle is its whole input (§5.3).
    let bin_dir = bin_dir.to_path_buf();
    let session = Session::launch(graph, catalogue, move |name| Program {
        path: bin_dir.join(name),
        args: Vec::new(),
    })?;
    Ok(session)
}
