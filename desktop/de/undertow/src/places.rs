//! Remembered window positions (WindowPlaces.swift, PHASE6.md P6.7;
//! HANDOFF §2.22). A Wayland client cannot position its own windows, so
//! remembering where they were is the compositor's. Stored in
//! `~/.config/abyss/windows.ini` through pool-config, inspectable with
//! `cat`, written atomically.

use pool_config::Config;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct WindowPlace {
    pub x: i32,
    pub y: i32,
}

const DOMAIN: &str = "windows";
const SECTION: &str = "windows";

pub struct WindowPlaces {
    config: Config,
    dir: Option<String>,
}

/// `/` separates a key's halves and `=` would break the INI line.
fn safe(s: &str) -> String {
    s.chars().map(|c| if c == '/' || c == '=' { '_' } else { c }).collect()
}

impl WindowPlaces {
    pub fn new(config_dir: Option<&str>) -> WindowPlaces {
        let dir = config_dir.map(str::to_owned);
        WindowPlaces { config: pool_config::load(DOMAIN, dir.as_deref()).unwrap_or_default(), dir }
    }

    /// The key for a window. `app_id` alone is wrong: the spatial Finder
    /// opens one window per folder, and they must not share a position, so
    /// the title (the folder's name) is the other half. Neither half may
    /// hold the separator, or two windows could collide on one key.
    pub fn key(app_id: Option<&str>, title: Option<&str>) -> Option<String> {
        let trim = |s: Option<&str>| s.unwrap_or("").trim_matches([' ', '\t', '\n']).to_owned();
        let (app, name) = (trim(app_id), trim(title));
        if app.is_empty() && name.is_empty() {
            return None;
        }
        Some(if name.is_empty() { safe(&app) } else { format!("{}/{}", safe(&app), safe(&name)) })
    }

    pub fn place(&self, key: &str) -> Option<WindowPlace> {
        let (x, y) = self.config.string(SECTION, key)?.split_once(',')?;
        Some(WindowPlace { x: x.parse().ok()?, y: y.parse().ok()? })
    }

    /// Remember, written straight through: a session that ends in a crash
    /// still remembers where its windows were.
    pub fn remember(&mut self, place: WindowPlace, key: &str) {
        self.config.set(SECTION, key, &format!("{},{}", place.x, place.y));
        let _ = self.config.store(DOMAIN, self.dir.as_deref());
    }

    /// Read again from disk: for tests, and a session that shares the file.
    pub fn reload(&mut self) {
        self.config = pool_config::load(DOMAIN, self.dir.as_deref()).unwrap_or_default();
    }
}
