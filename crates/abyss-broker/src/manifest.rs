// SPDX-License-Identifier: BSD-2-Clause

//! Component manifests — the declarative grant.
//!
//! A manifest is a component's *entire* declared authority: its identity,
//! the capabilities it needs, the jail it runs in, its resource budget, and
//! its restart policy (`docs/design/broker-and-transport.md` §4.1). The
//! union of every component's manifest is the static authority graph
//! ([`crate::graph`]) — knowable, and auditable, before anything runs.
//!
//! The on-disk syntax is a small, fixed-schema declarative text format
//! (§4.2): `#` comments, `key = value`, `[section]` headers, and a
//! repeatable `[capability]` block. There is deliberately no general
//! configuration language and no vendored parser — the broker is the
//! most-audited thing in the TCB, so the parser is a first-party walk over
//! a fixed set of known keys.
//!
//! ```text
//! name      = compositor
//! interface = display
//! version   = 1
//!
//! [capability]
//! kind   = device
//! class  = gpu
//! rights = mmap, ioctl
//!
//! [jail]
//! root    = /
//! network = none
//! user    = _compositor
//!
//! [budget]
//! memory = 96M
//! fds    = 64
//!
//! [restart]
//! policy = always
//! ```
//!
//! Parsing is total: malformed input is always a [`ManifestError`] naming
//! the offending line, never a panic. A malformed *system* manifest is a
//! boot fault (§5.1), so every rejection path is tested.

use std::fmt;
use std::path::PathBuf;

/// A parsed component manifest — a component's whole declared authority.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Manifest {
    /// The component's name, unique within the authority graph.
    pub name: String,
    /// The interface the component exports (its role: `display`, `input`, …).
    pub interface: String,
    /// The manifest schema version this component was authored against.
    pub version: u32,
    /// Every capability the component requests (§4.1).
    pub capabilities: Vec<CapabilityRequest>,
    /// The jail the component runs in.
    pub jail: Jail,
    /// The component's resource budget.
    pub budget: Budget,
    /// What the broker does when the component exits.
    pub restart: RestartPolicy,
}

/// The kind of authority a [`CapabilityRequest`] asks for.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CapabilityKind {
    /// A connection to a peer component (a `SOCK_SEQPACKET` ring).
    Peer,
    /// A kernel device (a GPU, an input device).
    Device,
    /// A shareable memory handle (`memfd`/shm).
    Memory,
    /// A Casper service channel (`broker-and-transport.md` §5.7).
    Casper,
    /// A scoped connection to the settings service.
    Settings,
}

/// One capability a component requests in its manifest.
///
/// The request names a [`CapabilityKind`], a `target` (the peer interface,
/// the device class, the settings subtree, the Casper service — empty only
/// for [`CapabilityKind::Memory`]), and the object rights asked for. The
/// broker maps the object rights to a `cap_rights_t` mask before handing
/// over the fd (§3.3).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CapabilityRequest {
    /// What kind of authority this is.
    pub kind: CapabilityKind,
    /// What the capability names (interface / class / subtree / service).
    pub target: String,
    /// The object rights requested — interface-specific tokens (§3.3).
    pub rights: Vec<String>,
}

/// The jail a component runs in (`broker-and-transport.md` §5.3).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Jail {
    /// The filesystem root the component sees.
    pub root: PathBuf,
    /// The component's network access — almost always [`Network::None`].
    pub network: Network,
    /// The principal (user) the component runs as.
    pub user: String,
}

/// A jail's network exposure.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Network {
    /// No network at all — the default for a desktop component.
    None,
    /// The host network stack (a deliberate, audited exception).
    Host,
}

/// A component's resource budget (`DESIGN.md` §3.6).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Budget {
    /// The memory ceiling, in bytes.
    pub memory: u64,
    /// The maximum number of open file descriptors.
    pub fds: u32,
    /// An optional CPU-time cap, as a percentage of one core.
    pub cpu: Option<u32>,
}

/// What the broker does when a component exits (`broker-and-transport.md` §5.5).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RestartPolicy {
    /// Restart on any exit, clean or crash.
    Always,
    /// Restart only on a non-zero exit.
    OnFailure,
    /// Never restart — a one-shot component.
    Never,
}

/// A manifest that could not be parsed. Every variant names the line.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ManifestError {
    /// A line that is neither blank, a comment, a `[section]`, nor `key = value`.
    Syntax { line: usize },
    /// A `[section]` name the schema does not define.
    UnknownSection { line: usize, name: String },
    /// A `[jail]`, `[budget]`, or `[restart]` section appearing twice.
    DuplicateSection { line: usize, name: &'static str },
    /// A key not valid in the section it appears in.
    UnknownKey {
        line: usize,
        section: &'static str,
        key: String,
    },
    /// A key given a value the schema cannot accept.
    BadValue {
        line: usize,
        key: String,
        reason: &'static str,
    },
    /// A key set twice in one section.
    DuplicateKey { line: usize, key: String },
    /// A required field that never appeared.
    Missing {
        section: &'static str,
        field: &'static str,
    },
}

impl fmt::Display for ManifestError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Syntax { line } => {
                write!(f, "line {line}: expected `key = value` or `[section]`")
            }
            Self::UnknownSection { line, name } => {
                write!(f, "line {line}: unknown section `[{name}]`")
            }
            Self::DuplicateSection { line, name } => {
                write!(f, "line {line}: section `[{name}]` appears more than once")
            }
            Self::UnknownKey { line, section, key } => {
                write!(f, "line {line}: key `{key}` is not valid in `[{section}]`")
            }
            Self::BadValue { line, key, reason } => {
                write!(f, "line {line}: key `{key}` has a bad value ({reason})")
            }
            Self::DuplicateKey { line, key } => {
                write!(f, "line {line}: key `{key}` is set more than once")
            }
            Self::Missing { section, field } => {
                write!(f, "missing required key `{field}` in `[{section}]`")
            }
        }
    }
}

impl std::error::Error for ManifestError {}

impl Manifest {
    /// Parse a manifest from its text form.
    ///
    /// Total: any malformed input is a [`ManifestError`], never a panic.
    pub fn parse(text: &str) -> Result<Self, ManifestError> {
        let mut b = Builder::default();
        let mut section = Section::Identity;

        for (i, raw) in text.lines().enumerate() {
            let line = i + 1;
            // A `#` anywhere starts a comment; values never contain one.
            let content = raw.split_once('#').map_or(raw, |(head, _)| head);
            let s = content.trim();
            if s.is_empty() {
                continue;
            }

            if s.starts_with('[') {
                let name = s
                    .strip_prefix('[')
                    .and_then(|r| r.strip_suffix(']'))
                    .ok_or(ManifestError::Syntax { line })?
                    .trim();
                section = b.open_section(name, line)?;
                continue;
            }

            let (key, value) = s.split_once('=').ok_or(ManifestError::Syntax { line })?;
            let key = key.trim();
            let value = value.trim();
            if key.is_empty() {
                return Err(ManifestError::Syntax { line });
            }
            b.assign(section, key, value, line)?;
        }

        b.finish()
    }
}

/// The section a `key = value` line belongs to.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Section {
    /// The implicit top section, before any `[header]`.
    Identity,
    /// The most recently opened `[capability]` block.
    Capability,
    Jail,
    Budget,
    Restart,
}

/// Accumulates fields as lines are read, then validates in [`Builder::finish`].
#[derive(Default)]
struct Builder {
    name: Option<String>,
    interface: Option<String>,
    version: Option<u32>,
    caps: Vec<CapBuilder>,
    jail_root: Option<PathBuf>,
    jail_network: Option<Network>,
    jail_user: Option<String>,
    budget_memory: Option<u64>,
    budget_fds: Option<u32>,
    budget_cpu: Option<u32>,
    restart: Option<RestartPolicy>,
    seen_jail: bool,
    seen_budget: bool,
    seen_restart: bool,
}

/// A `[capability]` block being accumulated.
#[derive(Default)]
struct CapBuilder {
    kind: Option<CapabilityKind>,
    target: Option<String>,
    rights: Option<Vec<String>>,
}

/// Store a value into an empty slot, or reject a duplicate key.
fn set_once<T>(
    slot: &mut Option<T>,
    value: T,
    key: &str,
    line: usize,
) -> Result<(), ManifestError> {
    if slot.is_some() {
        return Err(ManifestError::DuplicateKey {
            line,
            key: key.to_string(),
        });
    }
    *slot = Some(value);
    Ok(())
}

impl Builder {
    /// Switch to a named section, pushing a fresh block for `[capability]`.
    fn open_section(&mut self, name: &str, line: usize) -> Result<Section, ManifestError> {
        match name {
            "capability" => {
                self.caps.push(CapBuilder::default());
                Ok(Section::Capability)
            }
            "jail" => Self::open_unique(&mut self.seen_jail, "jail", Section::Jail, line),
            "budget" => Self::open_unique(&mut self.seen_budget, "budget", Section::Budget, line),
            "restart" => {
                Self::open_unique(&mut self.seen_restart, "restart", Section::Restart, line)
            }
            _ => Err(ManifestError::UnknownSection {
                line,
                name: name.to_string(),
            }),
        }
    }

    /// Mark a once-only section seen, rejecting a second occurrence.
    fn open_unique(
        seen: &mut bool,
        name: &'static str,
        section: Section,
        line: usize,
    ) -> Result<Section, ManifestError> {
        if *seen {
            return Err(ManifestError::DuplicateSection { line, name });
        }
        *seen = true;
        Ok(section)
    }

    /// Assign one `key = value` line within `section`.
    fn assign(
        &mut self,
        section: Section,
        key: &str,
        value: &str,
        line: usize,
    ) -> Result<(), ManifestError> {
        match section {
            Section::Identity => match key {
                "name" => set_once(&mut self.name, value.to_string(), key, line),
                "interface" => set_once(&mut self.interface, value.to_string(), key, line),
                "version" => set_once(&mut self.version, parse_u32(value, key, line)?, key, line),
                _ => Err(unknown_key("identity", key, line)),
            },
            Section::Capability => {
                // `open_section` always pushes before the section becomes current.
                let cap = self.caps.last_mut().expect("a capability block is open");
                match key {
                    "kind" => {
                        let kind = parse_kind(value).ok_or_else(|| ManifestError::BadValue {
                            line,
                            key: key.to_string(),
                            reason: "expected peer|device|memory|casper|settings",
                        })?;
                        set_once(&mut cap.kind, kind, key, line)
                    }
                    "interface" | "class" | "subtree" | "service" | "target" => {
                        set_once(&mut cap.target, value.to_string(), "target", line)
                    }
                    "rights" => set_once(&mut cap.rights, parse_rights(value), key, line),
                    _ => Err(unknown_key("capability", key, line)),
                }
            }
            Section::Jail => match key {
                "root" => set_once(&mut self.jail_root, PathBuf::from(value), key, line),
                "network" => {
                    let net = parse_network(value).ok_or_else(|| ManifestError::BadValue {
                        line,
                        key: key.to_string(),
                        reason: "expected none|host",
                    })?;
                    set_once(&mut self.jail_network, net, key, line)
                }
                "user" => set_once(&mut self.jail_user, value.to_string(), key, line),
                _ => Err(unknown_key("jail", key, line)),
            },
            Section::Budget => match key {
                "memory" => {
                    let bytes = parse_size(value).ok_or_else(|| ManifestError::BadValue {
                        line,
                        key: key.to_string(),
                        reason: "expected a byte count, optionally K/M/G-suffixed",
                    })?;
                    set_once(&mut self.budget_memory, bytes, key, line)
                }
                "fds" => set_once(
                    &mut self.budget_fds,
                    parse_u32(value, key, line)?,
                    key,
                    line,
                ),
                "cpu" => set_once(
                    &mut self.budget_cpu,
                    parse_u32(value, key, line)?,
                    key,
                    line,
                ),
                _ => Err(unknown_key("budget", key, line)),
            },
            Section::Restart => match key {
                "policy" => {
                    let policy = parse_restart(value).ok_or_else(|| ManifestError::BadValue {
                        line,
                        key: key.to_string(),
                        reason: "expected always|on-failure|never",
                    })?;
                    set_once(&mut self.restart, policy, key, line)
                }
                _ => Err(unknown_key("restart", key, line)),
            },
        }
    }

    /// Validate that every required field appeared and build the [`Manifest`].
    fn finish(self) -> Result<Manifest, ManifestError> {
        let mut capabilities = Vec::with_capacity(self.caps.len());
        for cap in self.caps {
            let kind = cap.kind.ok_or(ManifestError::Missing {
                section: "capability",
                field: "kind",
            })?;
            // Every kind names a target except a memory handle.
            let target = match cap.target {
                Some(t) => t,
                None if kind == CapabilityKind::Memory => String::new(),
                None => {
                    return Err(ManifestError::Missing {
                        section: "capability",
                        field: "target",
                    });
                }
            };
            capabilities.push(CapabilityRequest {
                kind,
                target,
                rights: cap.rights.unwrap_or_default(),
            });
        }

        Ok(Manifest {
            name: require(self.name, "identity", "name")?,
            interface: require(self.interface, "identity", "interface")?,
            version: require(self.version, "identity", "version")?,
            capabilities,
            jail: Jail {
                root: require(self.jail_root, "jail", "root")?,
                network: require(self.jail_network, "jail", "network")?,
                user: require(self.jail_user, "jail", "user")?,
            },
            budget: Budget {
                memory: require(self.budget_memory, "budget", "memory")?,
                fds: require(self.budget_fds, "budget", "fds")?,
                cpu: self.budget_cpu,
            },
            restart: require(self.restart, "restart", "policy")?,
        })
    }
}

/// Unwrap a required field or report it missing.
fn require<T>(
    slot: Option<T>,
    section: &'static str,
    field: &'static str,
) -> Result<T, ManifestError> {
    slot.ok_or(ManifestError::Missing { section, field })
}

fn unknown_key(section: &'static str, key: &str, line: usize) -> ManifestError {
    ManifestError::UnknownKey {
        line,
        section,
        key: key.to_string(),
    }
}

fn parse_u32(value: &str, key: &str, line: usize) -> Result<u32, ManifestError> {
    value.parse().map_err(|_| ManifestError::BadValue {
        line,
        key: key.to_string(),
        reason: "expected a non-negative integer",
    })
}

fn parse_kind(value: &str) -> Option<CapabilityKind> {
    Some(match value {
        "peer" => CapabilityKind::Peer,
        "device" => CapabilityKind::Device,
        "memory" => CapabilityKind::Memory,
        "casper" => CapabilityKind::Casper,
        "settings" => CapabilityKind::Settings,
        _ => return None,
    })
}

fn parse_network(value: &str) -> Option<Network> {
    Some(match value {
        "none" => Network::None,
        "host" => Network::Host,
        _ => return None,
    })
}

fn parse_restart(value: &str) -> Option<RestartPolicy> {
    Some(match value {
        "always" => RestartPolicy::Always,
        "on-failure" => RestartPolicy::OnFailure,
        "never" => RestartPolicy::Never,
        _ => return None,
    })
}

/// Split a comma-separated rights list, trimming and dropping empty entries.
fn parse_rights(value: &str) -> Vec<String> {
    value
        .split(',')
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(str::to_string)
        .collect()
}

/// Parse a byte count with an optional binary `K`/`M`/`G` suffix.
fn parse_size(value: &str) -> Option<u64> {
    let value = value.trim();
    let (digits, mult): (&str, u64) = match value.as_bytes().last()? {
        b'K' | b'k' => (&value[..value.len() - 1], 1 << 10),
        b'M' | b'm' => (&value[..value.len() - 1], 1 << 20),
        b'G' | b'g' => (&value[..value.len() - 1], 1 << 30),
        _ => (value, 1),
    };
    digits.trim().parse::<u64>().ok()?.checked_mul(mult)
}

#[cfg(test)]
mod tests {
    use super::*;

    const EXAMPLE: &str = "\
# the compositor's manifest
name      = compositor
interface = display
version   = 1

[capability]
kind   = device
class  = gpu
rights = mmap, ioctl

[capability]
kind      = peer
interface = input
rights    = recv

[jail]
root    = /
network = none
user    = _compositor

[budget]
memory = 96M
fds    = 64

[restart]
policy = always
";

    #[test]
    fn parses_the_example_manifest() {
        let m = Manifest::parse(EXAMPLE).expect("the example manifest parses");
        assert_eq!(m.name, "compositor");
        assert_eq!(m.interface, "display");
        assert_eq!(m.version, 1);

        assert_eq!(m.capabilities.len(), 2);
        assert_eq!(m.capabilities[0].kind, CapabilityKind::Device);
        assert_eq!(m.capabilities[0].target, "gpu");
        assert_eq!(m.capabilities[0].rights, ["mmap", "ioctl"]);
        assert_eq!(m.capabilities[1].kind, CapabilityKind::Peer);
        assert_eq!(m.capabilities[1].target, "input");
        assert_eq!(m.capabilities[1].rights, ["recv"]);

        assert_eq!(m.jail.root, PathBuf::from("/"));
        assert_eq!(m.jail.network, Network::None);
        assert_eq!(m.jail.user, "_compositor");

        assert_eq!(m.budget.memory, 96 * 1024 * 1024);
        assert_eq!(m.budget.fds, 64);
        assert_eq!(m.budget.cpu, None);

        assert_eq!(m.restart, RestartPolicy::Always);
    }

    /// The smallest legal manifest — no capabilities, optional `cpu` omitted.
    #[test]
    fn parses_a_minimal_manifest() {
        let m = Manifest::parse(
            "name = x\ninterface = y\nversion = 2\n\
             [jail]\nroot = /\nnetwork = host\nuser = _x\n\
             [budget]\nmemory = 4096\nfds = 8\ncpu = 25\n\
             [restart]\npolicy = never\n",
        )
        .expect("minimal manifest parses");
        assert!(m.capabilities.is_empty());
        assert_eq!(m.budget.memory, 4096);
        assert_eq!(m.budget.cpu, Some(25));
        assert_eq!(m.jail.network, Network::Host);
        assert_eq!(m.restart, RestartPolicy::Never);
    }

    /// A memory capability needs no target.
    #[test]
    fn memory_capability_needs_no_target() {
        let m = Manifest::parse(
            "name = x\ninterface = y\nversion = 1\n\
             [capability]\nkind = memory\nrights = mmap\n\
             [jail]\nroot = /\nnetwork = none\nuser = _x\n\
             [budget]\nmemory = 1M\nfds = 4\n\
             [restart]\npolicy = on-failure\n",
        )
        .expect("memory capability parses without a target");
        assert_eq!(m.capabilities[0].kind, CapabilityKind::Memory);
        assert_eq!(m.capabilities[0].target, "");
    }

    #[test]
    fn comments_and_blank_lines_are_ignored() {
        let m = Manifest::parse(
            "\n  # a comment\nname = x  # trailing comment\n\n\
             interface = y\nversion = 0\n\
             [jail]\nroot = /\nnetwork = none\nuser = _x\n\
             [budget]\nmemory = 0\nfds = 0\n\
             [restart]\npolicy = always\n",
        )
        .expect("comments and blank lines parse");
        assert_eq!(m.name, "x");
    }

    #[test]
    fn rejects_a_garbage_line() {
        assert_eq!(
            Manifest::parse("name = x\nthis is not valid\n"),
            Err(ManifestError::Syntax { line: 2 }),
        );
    }

    #[test]
    fn rejects_an_unknown_section() {
        assert_eq!(
            Manifest::parse("name = x\n[mystery]\n"),
            Err(ManifestError::UnknownSection {
                line: 2,
                name: "mystery".to_string(),
            }),
        );
    }

    #[test]
    fn rejects_a_repeated_section() {
        assert_eq!(
            Manifest::parse("[jail]\nroot = /\n[jail]\n"),
            Err(ManifestError::DuplicateSection {
                line: 3,
                name: "jail",
            }),
        );
    }

    #[test]
    fn rejects_an_unknown_key() {
        assert_eq!(
            Manifest::parse("name = x\ncolour = blue\n"),
            Err(ManifestError::UnknownKey {
                line: 2,
                section: "identity",
                key: "colour".to_string(),
            }),
        );
    }

    #[test]
    fn rejects_a_duplicate_key() {
        assert_eq!(
            Manifest::parse("name = x\nname = y\n"),
            Err(ManifestError::DuplicateKey {
                line: 2,
                key: "name".to_string(),
            }),
        );
    }

    #[test]
    fn rejects_a_bad_enum_value() {
        let err = Manifest::parse(
            "name = x\ninterface = y\nversion = 1\n\
             [jail]\nroot = /\nnetwork = carrier-pigeon\nuser = _x\n",
        );
        assert!(matches!(err, Err(ManifestError::BadValue { line: 6, .. })));
    }

    #[test]
    fn rejects_a_non_numeric_version() {
        assert!(matches!(
            Manifest::parse("version = twelve\n"),
            Err(ManifestError::BadValue { line: 1, .. })
        ));
    }

    #[test]
    fn reports_a_missing_required_field() {
        // No `[restart]` section at all.
        assert_eq!(
            Manifest::parse(
                "name = x\ninterface = y\nversion = 1\n\
                 [jail]\nroot = /\nnetwork = none\nuser = _x\n\
                 [budget]\nmemory = 1M\nfds = 4\n",
            ),
            Err(ManifestError::Missing {
                section: "restart",
                field: "policy",
            }),
        );
    }

    #[test]
    fn reports_a_capability_missing_its_kind() {
        assert_eq!(
            Manifest::parse("name = x\n[capability]\nclass = gpu\n"),
            Err(ManifestError::Missing {
                section: "capability",
                field: "kind",
            }),
        );
    }

    #[test]
    fn size_suffixes_are_binary() {
        assert_eq!(parse_size("0"), Some(0));
        assert_eq!(parse_size("512"), Some(512));
        assert_eq!(parse_size("4K"), Some(4 * 1024));
        assert_eq!(parse_size("8m"), Some(8 * 1024 * 1024));
        assert_eq!(parse_size("2G"), Some(2 * 1024 * 1024 * 1024));
        assert_eq!(parse_size(""), None);
        assert_eq!(parse_size("notanumber"), None);
        // u64 overflow on the multiply is rejected, not wrapped.
        assert_eq!(parse_size("999999999999G"), None);
    }

    #[test]
    fn two_target_aliases_collide() {
        // `class` and `interface` both set the one target slot.
        assert_eq!(
            Manifest::parse("[capability]\nclass = gpu\ninterface = input\n"),
            Err(ManifestError::DuplicateKey {
                line: 3,
                key: "target".to_string(),
            }),
        );
    }
}
