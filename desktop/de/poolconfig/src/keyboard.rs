//! KeyboardPrefs.swift: the keyboard layout this session types with
//! (BACKLOG T.2). rc.conf's `keymap=` is the machine's; this is the
//! session's, which undertow watches and gives every keyboard without a
//! keymap of its own.
//!
//! ```ini
//! [keyboard]
//! kbdmap = uk.kbd
//! ```

use crate::{pool, Config, Error};

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct KeyboardPrefs {
    /// A `kbdmap` name (`uk.kbd`), or empty for none: rc.conf's then.
    pub kbdmap: String,
}

const DOMAIN: &str = "keyboard";
const SECTION: &str = "keyboard";

impl KeyboardPrefs {
    pub fn new(kbdmap: &str) -> KeyboardPrefs {
        KeyboardPrefs { kbdmap: kbdmap.to_owned() }
    }

    pub fn load(dir: Option<&str>) -> KeyboardPrefs {
        let Ok(c) = pool::load(DOMAIN, dir) else { return KeyboardPrefs::default() };
        KeyboardPrefs::new(c.string(SECTION, "kbdmap").unwrap_or(""))
    }

    /// Written by atomic rename, so a watcher sees one change, never half.
    pub fn store(&self, dir: Option<&str>) -> Result<(), Error> {
        let mut c = pool::load(DOMAIN, dir).unwrap_or_else(|_| Config::new());
        c.set(SECTION, "kbdmap", &self.kbdmap);
        c.store(DOMAIN, dir)
    }
}
