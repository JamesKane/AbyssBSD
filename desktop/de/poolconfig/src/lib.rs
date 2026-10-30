//! PoolConfig in Rust (RUST.md R2): ADE's `~/.config/abyss/*.ini`, ported
//! from the Swift beside it. The same text in and out, the same coercions,
//! the same files, locks and atomic renames, so a Swift and a Rust
//! component share a config (the fixtures in abyss/tests/wire/pool hold
//! both to that), and the same directory watch.

mod agents;
mod config;
mod desktop_keys;
mod energy;
mod graphemes;
mod islands;
mod keyboard;
mod pool;
mod setup;
mod text;

pub use agents::Agents;
pub use config::{parse_i64, parse_u64, Config};
pub use desktop_keys::DesktopKeys;
pub use energy::EnergyPrefs;
pub use islands::IslandsConfig;
pub use keyboard::KeyboardPrefs;
pub use pool::{config_dir, load, Watcher};
pub use setup::SetupState;

/// PoolError.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Error {
    /// A system call failed: what, and strerror's words.
    Io(String),
    /// None of `ABYSS_CONFIG_DIR`, `XDG_CONFIG_HOME` or `HOME` is set.
    NoConfigDir,
}

impl std::fmt::Display for Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Error::Io(s) => f.write_str(s),
            Error::NoConfigDir => f.write_str("no config directory"),
        }
    }
}

impl std::error::Error for Error {}
