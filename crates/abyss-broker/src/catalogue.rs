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
//! table.
//!
//! In production the catalogue is a declarative file the broker reads at
//! boot ([`InterfaceCatalogue::load`], §5.1) — the on-disk counterpart of
//! the manifests, owned by the curated system image. Each `[interface]`
//! block names an interface and lists its rights classes, a class given
//! as the method ordinals (§2.9) it covers. A test builds a small one
//! inline with [`register`](InterfaceCatalogue::register).

use std::collections::HashMap;
use std::error::Error;
use std::fmt;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};

/// Per-interface rights-class tables, by interface name (§3.3).
#[derive(Debug, Default, Clone, PartialEq, Eq)]
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

    /// Parse an interface catalogue from its text form (§3.3).
    ///
    /// The catalogue is a declarative file: `#` comments, blank lines, and
    /// a repeated `[interface]` block. Each block sets `name`, then lists
    /// its rights classes one per line — `class = ordinal, ordinal, …`,
    /// the method ordinals (§2.9) the class covers. Parsing is total: any
    /// malformed input is a [`CatalogueSyntaxError`] naming the line.
    pub fn parse(text: &str) -> Result<InterfaceCatalogue, CatalogueSyntaxError> {
        let mut catalogue = InterfaceCatalogue::new();
        let mut block: Option<Block> = None;

        for (i, raw) in text.lines().enumerate() {
            let line = i + 1;
            // A `#` anywhere starts a comment, as in a manifest (§4.2).
            let content = raw.split_once('#').map_or(raw, |(head, _)| head);
            let s = content.trim();
            if s.is_empty() {
                continue;
            }

            if let Some(rest) = s.strip_prefix('[') {
                let name = rest
                    .strip_suffix(']')
                    .ok_or(CatalogueSyntaxError::Syntax { line })?
                    .trim();
                if name != "interface" {
                    return Err(CatalogueSyntaxError::UnknownSection { line });
                }
                // A new `[interface]` — commit the block before it.
                if let Some(done) = block.take() {
                    done.commit(&mut catalogue)?;
                }
                block = Some(Block::new(line));
                continue;
            }

            let (key, value) = s
                .split_once('=')
                .ok_or(CatalogueSyntaxError::Syntax { line })?;
            let key = key.trim();
            let value = value.trim();
            if key.is_empty() {
                return Err(CatalogueSyntaxError::Syntax { line });
            }
            let block = block
                .as_mut()
                .ok_or(CatalogueSyntaxError::Structure { line })?;
            if key == "name" {
                block.set_name(value, line)?;
            } else {
                block.add_class(key, value, line)?;
            }
        }
        if let Some(done) = block.take() {
            done.commit(&mut catalogue)?;
        }
        Ok(catalogue)
    }

    /// Load and parse the interface catalogue file at `path` (§3.3, §5.1).
    ///
    /// A read failure or a malformed catalogue is a [`CatalogueLoadError`]
    /// naming the file — a boot fault (§5.1).
    pub fn load(path: &Path) -> Result<InterfaceCatalogue, CatalogueLoadError> {
        let text = fs::read_to_string(path).map_err(|error| CatalogueLoadError::Io {
            path: path.to_path_buf(),
            error,
        })?;
        InterfaceCatalogue::parse(&text).map_err(|error| CatalogueLoadError::Syntax {
            path: path.to_path_buf(),
            error,
        })
    }
}

/// One `[interface]` block, accumulated as the catalogue file is parsed.
struct Block {
    /// The line the `[interface]` header was on — for error reports.
    line: usize,
    name: Option<String>,
    classes: Vec<(String, u32)>,
}

impl Block {
    fn new(line: usize) -> Block {
        Block {
            line,
            name: None,
            classes: Vec::new(),
        }
    }

    /// Set the block's interface name; it may be set only once.
    fn set_name(&mut self, value: &str, line: usize) -> Result<(), CatalogueSyntaxError> {
        if self.name.is_some() {
            return Err(CatalogueSyntaxError::Duplicate { line });
        }
        self.name = Some(value.to_owned());
        Ok(())
    }

    /// Add one rights class — its method-ordinal list resolved to a mask.
    fn add_class(
        &mut self,
        class: &str,
        value: &str,
        line: usize,
    ) -> Result<(), CatalogueSyntaxError> {
        if self.classes.iter().any(|(name, _)| name == class) {
            return Err(CatalogueSyntaxError::Duplicate { line });
        }
        self.classes
            .push((class.to_owned(), parse_ordinals(value, line)?));
        Ok(())
    }

    /// Record the finished block in `catalogue`.
    fn commit(self, catalogue: &mut InterfaceCatalogue) -> Result<(), CatalogueSyntaxError> {
        let name = self
            .name
            .ok_or(CatalogueSyntaxError::Structure { line: self.line })?;
        if catalogue.classes.contains_key(&name) {
            return Err(CatalogueSyntaxError::Duplicate { line: self.line });
        }
        catalogue.classes.insert(name, self.classes);
        Ok(())
    }
}

/// Resolve a rights class's value — a comma-separated list of method
/// ordinals — to the bitmask of those ordinals. An empty value is the
/// empty mask: a class that covers no method.
fn parse_ordinals(value: &str, line: usize) -> Result<u32, CatalogueSyntaxError> {
    let mut mask = 0u32;
    if value.is_empty() {
        return Ok(mask);
    }
    for token in value.split(',') {
        let ordinal: u32 = token
            .trim()
            .parse()
            .map_err(|_| CatalogueSyntaxError::BadRights { line })?;
        // The object-rights mask is a `u32` (§3.3); ordinal 32 and up has
        // no bit.
        if ordinal >= 32 {
            return Err(CatalogueSyntaxError::BadRights { line });
        }
        mask |= 1 << ordinal;
    }
    Ok(mask)
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

/// A catalogue file that could not be parsed. Every variant names the line.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CatalogueSyntaxError {
    /// A line that is neither blank, a comment, a section, nor `key = value`.
    Syntax { line: usize },
    /// A section header other than `[interface]`.
    UnknownSection { line: usize },
    /// A `key = value` line outside any `[interface]` block, or an
    /// `[interface]` block that never set its `name`.
    Structure { line: usize },
    /// A rights class whose value is not method ordinals in the range 0–31.
    BadRights { line: usize },
    /// An interface, or a rights class within one, declared twice.
    Duplicate { line: usize },
}

impl fmt::Display for CatalogueSyntaxError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Syntax { line } => {
                write!(f, "line {line}: expected `key = value` or `[interface]`")
            }
            Self::UnknownSection { line } => {
                write!(f, "line {line}: only `[interface]` sections are defined")
            }
            Self::Structure { line } => {
                write!(
                    f,
                    "line {line}: a rights class outside an `[interface]`, \
                           or an `[interface]` with no `name`"
                )
            }
            Self::BadRights { line } => {
                write!(
                    f,
                    "line {line}: a rights class must list method ordinals 0-31"
                )
            }
            Self::Duplicate { line } => {
                write!(
                    f,
                    "line {line}: an interface or rights class is declared twice"
                )
            }
        }
    }
}

impl Error for CatalogueSyntaxError {}

/// Why loading an interface catalogue file failed ([`InterfaceCatalogue::load`]).
#[derive(Debug)]
pub enum CatalogueLoadError {
    /// The catalogue file could not be read.
    Io { path: PathBuf, error: io::Error },
    /// The catalogue file did not parse.
    Syntax {
        path: PathBuf,
        error: CatalogueSyntaxError,
    },
}

impl fmt::Display for CatalogueLoadError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Io { path, error } => {
                write!(f, "reading interface catalogue {}: {error}", path.display())
            }
            Self::Syntax { path, error } => {
                write!(f, "interface catalogue {}: {error}", path.display())
            }
        }
    }
}

impl Error for CatalogueLoadError {}

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

    // --- parse / load ----------------------------------------------------

    const CATALOGUE: &str = "\
# the system interface catalogue

[interface]
name    = display
present = 0, 1
capture = 3

[interface]
name = input
recv = 0
";

    #[test]
    fn parse_reads_interfaces_and_their_rights_classes() {
        let catalogue = InterfaceCatalogue::parse(CATALOGUE).expect("the catalogue parses");

        // `present` covers method ordinals 0 and 1, `capture` ordinal 3.
        assert_eq!(
            catalogue.resolve("display", &["present".to_owned()]),
            Ok(0b0011)
        );
        assert_eq!(
            catalogue.resolve("display", &["capture".to_owned()]),
            Ok(0b1000)
        );
        assert_eq!(
            catalogue.resolve("display", &["present".to_owned(), "capture".to_owned()]),
            Ok(0b1011),
        );
        assert_eq!(catalogue.resolve("input", &["recv".to_owned()]), Ok(0b0001));
    }

    #[test]
    fn parse_accepts_a_class_that_covers_no_method() {
        // An empty ordinal list is the empty mask — a class granting nothing.
        let catalogue =
            InterfaceCatalogue::parse("[interface]\nname = void\nnone =\n").expect("parses");
        assert_eq!(catalogue.resolve("void", &["none".to_owned()]), Ok(0));
    }

    #[test]
    fn parse_rejects_a_garbage_line() {
        assert_eq!(
            InterfaceCatalogue::parse("[interface]\nname = x\nnot a key value line\n"),
            Err(CatalogueSyntaxError::Syntax { line: 3 }),
        );
    }

    #[test]
    fn parse_rejects_an_unknown_section() {
        assert_eq!(
            InterfaceCatalogue::parse("[component]\nname = x\n"),
            Err(CatalogueSyntaxError::UnknownSection { line: 1 }),
        );
    }

    #[test]
    fn parse_rejects_a_class_outside_an_interface() {
        assert_eq!(
            InterfaceCatalogue::parse("recv = 0\n"),
            Err(CatalogueSyntaxError::Structure { line: 1 }),
        );
    }

    #[test]
    fn parse_rejects_an_interface_with_no_name() {
        // The `Structure` error names the `[interface]` header line.
        assert_eq!(
            InterfaceCatalogue::parse("[interface]\nrecv = 0\n"),
            Err(CatalogueSyntaxError::Structure { line: 1 }),
        );
    }

    #[test]
    fn parse_rejects_a_non_numeric_ordinal() {
        assert_eq!(
            InterfaceCatalogue::parse("[interface]\nname = x\nrecv = 0, two\n"),
            Err(CatalogueSyntaxError::BadRights { line: 3 }),
        );
    }

    #[test]
    fn parse_rejects_an_ordinal_past_the_mask_width() {
        // The object-rights mask is a `u32` — ordinal 32 has no bit.
        assert_eq!(
            InterfaceCatalogue::parse("[interface]\nname = x\nrecv = 32\n"),
            Err(CatalogueSyntaxError::BadRights { line: 3 }),
        );
    }

    #[test]
    fn parse_rejects_a_duplicate_interface() {
        assert_eq!(
            InterfaceCatalogue::parse("[interface]\nname = dup\n[interface]\nname = dup\n"),
            Err(CatalogueSyntaxError::Duplicate { line: 3 }),
        );
    }

    #[test]
    fn parse_rejects_a_duplicate_rights_class() {
        assert_eq!(
            InterfaceCatalogue::parse("[interface]\nname = x\nrecv = 0\nrecv = 1\n"),
            Err(CatalogueSyntaxError::Duplicate { line: 4 }),
        );
    }

    #[test]
    fn load_reads_a_catalogue_file() {
        let mut path = std::env::temp_dir();
        path.push(format!("abyss-catalogue-{}.conf", std::process::id()));
        fs::write(&path, CATALOGUE).expect("write the catalogue file");

        let catalogue = InterfaceCatalogue::load(&path);
        let _ = fs::remove_file(&path);

        let catalogue = catalogue.expect("the catalogue file loads");
        assert_eq!(catalogue.resolve("input", &["recv".to_owned()]), Ok(1));
    }

    #[test]
    fn load_of_a_missing_file_is_an_io_error() {
        let mut missing = std::env::temp_dir();
        missing.push(format!(
            "abyss-catalogue-absent-{}.conf",
            std::process::id()
        ));
        match InterfaceCatalogue::load(&missing) {
            Err(CatalogueLoadError::Io { path, .. }) => assert_eq!(path, missing),
            other => panic!("expected an io error, got {other:?}"),
        }
    }
}
