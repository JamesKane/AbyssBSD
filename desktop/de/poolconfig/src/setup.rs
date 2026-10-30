//! SetupState.swift: whether an account has been through the Setup
//! Assistant (PHASE16 P16.7), in its own `setup.ini`. anchor reads it to
//! decide whether to start the assistant; the assistant writes it.
//!
//! ```ini
//! [setup]
//! done = true
//! ```

use crate::{pool, Config, Error};

pub struct SetupState;

const DOMAIN: &str = "setup";
const SECTION: &str = "setup";

impl SetupState {
    pub fn done(dir: Option<&str>) -> bool {
        pool::load(DOMAIN, dir).ok().and_then(|c| c.bool(SECTION, "done")).unwrap_or(false)
    }

    /// Finished or skipped: say so, and how, for whoever looks.
    pub fn mark_done(skipped: bool, dir: Option<&str>) -> Result<(), Error> {
        let mut c = pool::load(DOMAIN, dir).unwrap_or_else(|_| Config::new());
        c.set(SECTION, "done", "true").set(SECTION, "how", if skipped { "skipped" } else { "finished" });
        c.store(DOMAIN, dir)
    }
}
