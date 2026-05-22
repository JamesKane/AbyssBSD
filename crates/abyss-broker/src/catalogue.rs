// SPDX-License-Identifier: BSD-2-Clause

//! The interface catalogue — resolving a manifest's rights tokens to an
//! object-rights mask (`docs/design/broker-and-transport.md` §3.3).
//!
//! A manifest requests a peer capability in terms of named **rights
//! classes** (`rights = read, write`); the broker mints the connection's
//! object-rights mask by resolving those names against the provider
//! interface's rights-class table — its `Method::RIGHTS_CLASSES`. The
//! broker is generic over manifests and never sees an interface's Rust
//! type, so it is *given* an [`InterfaceCatalogue`]: interface name → that
//! table. Whoever runs the broker assembles one from the interfaces of the
//! curated system image; a test builds a small one inline.

use std::collections::HashMap;
use std::error::Error;
use std::fmt;

/// Per-interface rights-class tables, by interface name (§3.3).
#[derive(Debug, Default, Clone)]
pub struct InterfaceCatalogue {
    /// Interface name → its `(class name, ordinal mask)` entries.
    classes: HashMap<String, Vec<(String, u32)>>,
}

impl InterfaceCatalogue {
    /// An empty catalogue.
    pub fn new() -> Self {
        Self::default()
    }

    /// Register interface `name`'s rights classes — typically a `Method`
    /// type's `RIGHTS_CLASSES`. A re-registration replaces the entry.
    pub fn register(&mut self, name: impl Into<String>, classes: &[(&str, u32)]) {
        let classes = classes
            .iter()
            .map(|(class, mask)| ((*class).to_owned(), *mask))
            .collect();
        self.classes.insert(name.into(), classes);
    }

    /// Resolve `tokens` — rights-class names from a manifest — against
    /// interface `name` to an object-rights mask: the union of the named
    /// classes' masks. An empty `tokens` resolves to an empty mask.
    pub fn resolve(&self, name: &str, tokens: &[String]) -> Result<u32, CatalogueError> {
        let classes = self
            .classes
            .get(name)
            .ok_or_else(|| CatalogueError::UnknownInterface(name.to_owned()))?;
        let mut mask = 0u32;
        for token in tokens {
            let (_, class_mask) = classes
                .iter()
                .find(|(class, _)| class == token)
                .ok_or_else(|| CatalogueError::UnknownRightsClass {
                    interface: name.to_owned(),
                    class: token.clone(),
                })?;
            mask |= class_mask;
        }
        Ok(mask)
    }
}

/// Why a manifest's rights tokens could not be resolved.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CatalogueError {
    /// No interface of this name is in the catalogue.
    UnknownInterface(String),
    /// The interface has no rights class of this name.
    UnknownRightsClass {
        /// The interface the class was looked up under.
        interface: String,
        /// The class name a manifest asked for.
        class: String,
    },
}

impl fmt::Display for CatalogueError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::UnknownInterface(name) => {
                write!(f, "no interface `{name}` in the catalogue")
            }
            Self::UnknownRightsClass { interface, class } => {
                write!(f, "interface `{interface}` has no rights class `{class}`")
            }
        }
    }
}

impl Error for CatalogueError {}

#[cfg(test)]
mod tests {
    use super::*;

    fn catalogue() -> InterfaceCatalogue {
        let mut catalogue = InterfaceCatalogue::new();
        catalogue.register("settings", &[("read", 0b0011), ("write", 0b1100)]);
        catalogue
    }

    #[test]
    fn resolves_a_token_set_to_the_union_of_class_masks() {
        let catalogue = catalogue();
        assert_eq!(
            catalogue.resolve("settings", &["read".to_owned()]),
            Ok(0b0011)
        );
        assert_eq!(
            catalogue.resolve("settings", &["read".to_owned(), "write".to_owned()]),
            Ok(0b1111),
        );
    }

    #[test]
    fn an_empty_token_set_resolves_to_no_rights() {
        assert_eq!(catalogue().resolve("settings", &[]), Ok(0));
    }

    #[test]
    fn an_unknown_interface_is_rejected() {
        assert_eq!(
            catalogue().resolve("display", &["read".to_owned()]),
            Err(CatalogueError::UnknownInterface("display".to_owned())),
        );
    }

    #[test]
    fn an_unknown_rights_class_is_rejected() {
        assert_eq!(
            catalogue().resolve("settings", &["admin".to_owned()]),
            Err(CatalogueError::UnknownRightsClass {
                interface: "settings".to_owned(),
                class: "admin".to_owned(),
            }),
        );
    }
}
