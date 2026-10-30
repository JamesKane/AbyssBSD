//! What a jail contains, as data (JailClass.swift, PHASE18 P18.1).
//!
//! A class is a row in `jails.ini`, not code: the system it sees, the
//! devices it may open, whether it has a network and a Wayland socket. The
//! shipped classes are below; a `[name]` section replaces one or adds one.
//! Every class gets the same private home and the same read-only system:
//! what varies is reach, and reach is what a person should be able to read
//! in one file.

use pool_config::Config;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Network {
    /// No address at all: `ip4=disable ip6=disable`.
    None,
    /// The host's stack (§6.5): a browser reaches the network and nothing
    /// of yours. Per-jail `vnet` behind an egress gate is 18b's.
    Host,
}

impl Network {
    pub fn as_str(self) -> &'static str {
        match self {
            Network::None => "none",
            Network::Host => "host",
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct JailClass {
    pub name: String,
    /// Host directories mounted read-only at the same path inside.
    pub system: Vec<String>,
    /// devfs paths unhidden on top of ruleset 4 (`devfsrules_jail`): "dri"
    /// gives `/dev/dri/*`, "dsp" gives `/dev/dsp*`.
    pub devices: Vec<String>,
    pub network: Network,
    /// A Wayland socket of its own, and with it the D-Bus bridge, portal
    /// and menu bridge a GTK application needs.
    pub wayland: bool,
    /// An agent class (P18.8): what runs in it is `abyss-agent`, and each
    /// session gets a model socket of its own with `budget` tokens.
    pub agent: bool,
    pub budget: i64,
    /// Where an agent session's model comes from, as `abyss-model serve`
    /// takes it; empty: none is set, and a session is refused saying so.
    pub model: String,
    /// A vocabulary bridge to the applications a session is given (P18.10).
    pub vocabulary: bool,
    /// A fetch bridge to the web, host by host as the person allows (P18.12b).
    pub fetch: bool,
}

/// Tokens per agent session, unless the row says otherwise.
pub const DEFAULT_BUDGET: i64 = 200_000;

/// The system every class sees unless its row says otherwise. `/usr`
/// carries `/usr/local`, so ports' toolkits come with it.
pub const BASE_SYSTEM: [&str; 4] = ["/bin", "/lib", "/libexec", "/usr"];

/// `[apps]`: which applications run confined, and in what (P18.5), read by
/// abyss-appgen, not a class.
pub const APPS_SECTION: &str = "apps";

/// The devices a row may name, and what each unhides. Anything else is
/// refused, not passed to devfs: a typo must not become `unhide` on a path
/// nobody reviewed.
pub fn known_devices(name: &str) -> Option<&'static [&'static str]> {
    match name {
        "dri" => Some(&["dri", "dri/*", "drm", "drm/*"]),
        "dsp" => Some(&["dsp*", "mixer*", "sndstat"]),
        _ => None,
    }
}

impl JailClass {
    /// A class with every default: the base system, no devices, no
    /// network, a Wayland socket, not an agent.
    pub fn new(name: &str) -> JailClass {
        JailClass {
            name: name.to_owned(),
            system: BASE_SYSTEM.map(str::to_owned).into(),
            devices: vec![],
            network: Network::None,
            wayland: true,
            agent: false,
            budget: DEFAULT_BUDGET,
            model: String::new(),
            vocabulary: false,
            fetch: false,
        }
    }

    pub fn shipped() -> Vec<JailClass> {
        let agent = |name: &str| JailClass { wayland: false, agent: true, ..JailClass::new(name) };
        vec![
            JailClass::new("app"),
            JailClass { devices: vec!["dri".into()], ..JailClass::new("app-gl") },
            JailClass { devices: vec!["dri".into(), "dsp".into()], network: Network::Host, ..JailClass::new("app-net") },
            // Agents (P18.8): no display, no bus, no devices, no network: a
            // model socket and nothing else. `debug` is the crash path's
            // (P18.9), whose tool is lldb, already in /usr.
            JailClass { vocabulary: true, fetch: true, ..agent("agent") },
            agent("debug"),
        ]
    }

    /// The classes as they stand: the shipped ones, with `jails.ini`'s
    /// sections over them. An unknown key keeps the shipped value, so a
    /// one-line override does not restate the rest; a value that is not
    /// one (a network word, a budget) keeps it too.
    pub fn table(c: Option<&Config>) -> Vec<JailClass> {
        let mut out = JailClass::shipped();
        let Some(c) = c else { return out };
        for section in c.section_names() {
            if section.is_empty() || section == APPS_SECTION {
                continue;
            }
            let mut k = out.iter().find(|k| k.name == section).cloned().unwrap_or_else(|| JailClass::new(section));
            if let Some(s) = c.string(section, "system") {
                k.system = words(s);
            }
            if let Some(s) = c.string(section, "devices") {
                k.devices = words(s);
            }
            match c.string(section, "network").map(str::to_lowercase).as_deref() {
                Some("none") => k.network = Network::None,
                Some("host") => k.network = Network::Host,
                _ => {}
            }
            let flag = |key: &str, v: &mut bool| {
                if let Some(b) = c.bool(section, key) {
                    *v = b;
                }
            };
            flag("wayland", &mut k.wayland);
            flag("agent", &mut k.agent);
            flag("vocabulary", &mut k.vocabulary);
            flag("fetch", &mut k.fetch);
            if let Some(n) = c.string(section, "budget").and_then(|s| s.parse::<i64>().ok()).filter(|&n| n > 0) {
                k.budget = n;
            }
            if let Some(s) = c.string(section, "model") {
                k.model = s.to_owned();
            }
            out.retain(|x| x.name != section);
            out.push(k);
        }
        out
    }

    /// The table from `jails.ini` in `config_dir` (default: the person's);
    /// the shipped classes if it cannot be read.
    pub fn load(config_dir: Option<&str>) -> Vec<JailClass> {
        JailClass::table(pool_config::load("jails", config_dir).ok().as_ref())
    }
}

/// A row's list: words between spaces, commas and tabs.
pub(crate) fn words(s: &str) -> Vec<String> {
    s.split([' ', ',', '\t']).filter(|w| !w.is_empty()).map(str::to_owned).collect()
}
