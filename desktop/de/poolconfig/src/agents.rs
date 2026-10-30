//! Agents.swift: agents, on or off (PHASE18 P18.13).
//!
//! **Off is one file, absent** (PRODUCT §10). Without `agents.ini` in the
//! config directory there is no Agent menu item, no chord, no spend
//! indicator, no Ask the Agent on a crash, no Agent tile, and the keeper
//! starts no agent process. Everything that would show an agent asks this
//! first.

use crate::pool::{self, strerror};
use std::fs::{self, DirBuilder, OpenOptions};
use std::io::{ErrorKind, Write};
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt};

pub struct Agents;

impl Agents {
    pub const FILE: &'static str = "agents.ini";

    /// Whether agents are on: `agents.ini` exists in `dir` (default: the
    /// config directory).
    pub fn on(dir: Option<&str>) -> bool {
        let Some(d) = dir.map(str::to_owned).or_else(|| pool::config_dir().ok()) else { return false };
        fs::metadata(format!("{d}/{}", Self::FILE)).is_ok()
    }

    /// Turn them on (write the file) or off (remove it). None, or why not.
    pub fn set(on: bool, dir: Option<&str>) -> Option<String> {
        let Some(d) = dir.map(str::to_owned).or_else(|| pool::config_dir().ok()) else {
            return Some("no config directory".into());
        };
        let path = format!("{d}/{}", Self::FILE);
        if !on {
            return match fs::remove_file(&path) {
                Ok(()) => None,
                Err(e) if e.kind() == ErrorKind::NotFound => None,
                Err(e) => Some(strerror(&e)),
            };
        }
        let _ = DirBuilder::new().mode(0o700).create(&d);
        let mut f = match OpenOptions::new().write(true).create_new(true).mode(0o600).open(&path) {
            Ok(f) => f,
            Err(e) if e.kind() == ErrorKind::AlreadyExists => return None,
            Err(e) => return Some(strerror(&e)),
        };
        let text = "# Agents are on while this file exists (PHASE18 P18.13).\n# Remove it, or turn them off in System Preferences ▸ Agents, and there are none.\n[agents]\n";
        let _ = f.write(text.as_bytes());
        None
    }
}
