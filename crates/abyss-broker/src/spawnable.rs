// SPDX-License-Identifier: BSD-2-Clause

//! The spawnable manifest set — the catalogue of delegated spawn (§5.6).
//!
//! The boot manifest set (`docs/design/broker-and-transport.md` §5.2) is
//! everything spawned *at* boot. The **spawnable set** is everything that
//! *may* be spawned later, on request: the apps and on-demand services.
//! The broker reads it at boot the same way as the boot set, but spawns
//! nothing from it — each manifest is spawned only when a `SpawnChild`
//! request names it (§5.6).
//!
//! A component never supplies a manifest; it names one. So a name must
//! resolve to exactly one manifest: the set rejects two that share a name.

use std::collections::HashMap;
use std::collections::hash_map::Entry;
use std::fmt;
use std::path::Path;

use crate::manifest::{LoadError, Manifest};

/// The broker's set of on-demand-spawnable manifests (§5.6), by name.
#[derive(Debug, Default, Clone)]
pub struct SpawnableSet {
    by_name: HashMap<String, Manifest>,
}

impl SpawnableSet {
    /// An empty spawnable set — a broker that delegates no spawns.
    pub fn new() -> SpawnableSet {
        SpawnableSet::default()
    }

    /// Assemble a spawnable set from a manifest list.
    ///
    /// Rejects two manifests that share a name: a `SpawnChild` names a
    /// manifest, so a name must resolve to exactly one.
    pub fn build(manifests: Vec<Manifest>) -> Result<SpawnableSet, SpawnableError> {
        let mut by_name: HashMap<String, Manifest> = HashMap::with_capacity(manifests.len());
        for manifest in manifests {
            match by_name.entry(manifest.name.clone()) {
                Entry::Occupied(_) => {
                    return Err(SpawnableError::DuplicateManifest {
                        name: manifest.name,
                    });
                }
                Entry::Vacant(slot) => {
                    slot.insert(manifest);
                }
            }
        }
        Ok(SpawnableSet { by_name })
    }

    /// Load and assemble the spawnable set from a directory of manifests
    /// (§5.1, §5.6) — every manifest in `dir`, by [`Manifest::load_dir`].
    pub fn load(dir: &Path) -> Result<SpawnableSet, SpawnableError> {
        SpawnableSet::build(Manifest::load_dir(dir)?)
    }

    /// The spawnable manifest of the given name, if the set holds one.
    pub fn get(&self, name: &str) -> Option<&Manifest> {
        self.by_name.get(name)
    }

    /// How many manifests the set holds.
    pub fn len(&self) -> usize {
        self.by_name.len()
    }

    /// Whether the set holds no manifest.
    pub fn is_empty(&self) -> bool {
        self.by_name.is_empty()
    }
}

/// Why a spawnable set could not be assembled.
#[derive(Debug)]
pub enum SpawnableError {
    /// A manifest in the spawnable directory could not be loaded.
    Load(LoadError),
    /// Two spawnable manifests share a name — a `SpawnChild` could not say
    /// which one it meant.
    DuplicateManifest { name: String },
}

impl From<LoadError> for SpawnableError {
    fn from(err: LoadError) -> Self {
        SpawnableError::Load(err)
    }
}

impl fmt::Display for SpawnableError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            SpawnableError::Load(err) => write!(f, "loading the spawnable set: {err}"),
            SpawnableError::DuplicateManifest { name } => {
                write!(f, "two spawnable manifests are named `{name}`")
            }
        }
    }
}

impl std::error::Error for SpawnableError {}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::path::PathBuf;

    /// The text of a minimal valid manifest for `name`.
    fn manifest_text(name: &str) -> String {
        format!(
            "name = {name}\ninterface = {name}-iface\nversion = 1\n\
             [jail]\nroot = /\nnetwork = none\nuser = _{name}\n\
             [budget]\nmemory = 1M\nfds = 8\n[restart]\npolicy = always\n",
        )
    }

    /// A parsed minimal manifest named `name`.
    fn manifest(name: &str) -> Manifest {
        Manifest::parse(&manifest_text(name)).expect("the test manifest parses")
    }

    /// A temp directory unique to the calling test, removed when dropped.
    struct TempDir(PathBuf);

    impl TempDir {
        fn new(tag: &str) -> TempDir {
            let mut path = std::env::temp_dir();
            path.push(format!("abyss-spawnable-{}-{tag}", std::process::id()));
            let _ = fs::remove_dir_all(&path);
            fs::create_dir(&path).expect("create the temp directory");
            TempDir(path)
        }

        fn write(&self, name: &str, contents: &str) {
            fs::write(self.0.join(name), contents).expect("write a temp manifest");
        }
    }

    impl Drop for TempDir {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    #[test]
    fn build_indexes_manifests_by_name() {
        let set = SpawnableSet::build(vec![manifest("editor"), manifest("browser")])
            .expect("the spawnable set assembles");
        assert_eq!(set.len(), 2);
        assert_eq!(set.get("editor").map(|m| m.name.as_str()), Some("editor"));
        assert_eq!(set.get("browser").map(|m| m.name.as_str()), Some("browser"));
        assert!(set.get("absent").is_none());
    }

    #[test]
    fn an_empty_set_holds_nothing() {
        let set = SpawnableSet::build(Vec::new()).expect("the empty set assembles");
        assert!(set.is_empty());
        assert!(set.get("anything").is_none());
    }

    #[test]
    fn build_rejects_two_manifests_of_one_name() {
        match SpawnableSet::build(vec![manifest("twin"), manifest("twin")]) {
            Err(SpawnableError::DuplicateManifest { name }) => assert_eq!(name, "twin"),
            other => panic!("expected a duplicate-manifest error, got {other:?}"),
        }
    }

    #[test]
    fn load_reads_a_directory_of_spawnable_manifests() {
        let dir = TempDir::new("load");
        dir.write("editor.manifest", &manifest_text("editor"));
        dir.write("browser.manifest", &manifest_text("browser"));

        let set = SpawnableSet::load(&dir.0).expect("the spawnable directory loads");
        assert_eq!(set.len(), 2);
        assert!(set.get("editor").is_some());
    }
}
