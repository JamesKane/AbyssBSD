//! SettingsWire in Rust (RUST.md R2): the settings plan on the wire
//! (PHASE14 P14.3), ported from Wire.swift beside it. The same fields, so a
//! Swift pane talks to a Rust helper and the other way about (the fixtures
//! in abyss/tests/wire/settings hold both to that).
//!
//! Its own crate for the installer's reason (install-wire): System
//! Preferences must be able to speak the protocol **without linking the code
//! that runs `sysrc` as root**. `Msg` has scalars and no arrays, so a plan is
//! a few named fields and a list is indexed ones: verbose, and trivially
//! readable in a log, which is where a root helper's messages end up being
//! read.

use current_ipc::{Msg, Value};
use settings::{
    AccountAction, EnergyPlan, IPv4, IPv4Config, NetworkPlan, PowerProfile, PowerdMode, SettingsPlan, SettingsRefusal, SignalPlan,
    SoundPlan, VolumeAction, WifiAction, WifiNetwork, WifiPlan,
};
use std::collections::BTreeMap;

/// What an apply reports as it happens: the vocabulary both ends share.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum SettingsEvent {
    Starting { index: u64, total: u64, what: String },
    Ok { index: u64 },
    Failed { index: u64, what: String, why: String, ignored: bool },
    /// Not run, on purpose: a write-only helper (a test's) leaves the
    /// machine alone and says so, rather than calling it done.
    Skipped { index: u64, why: String },
    Finished { ok: bool, error: String },
}

// MARK: the plan

pub fn encode_plan(p: &SettingsPlan, m: &mut Msg) {
    m.set_string("kind", p.kind());
    match p {
        SettingsPlan::Energy(e) => {
            m.set_bool("energy.powerd", e.powerd);
            m.set_string("energy.ac", e.on_ac.as_str());
            m.set_string("energy.battery", e.on_battery.as_str());
            if e.modes_from_profile {
                m.set_bool("energy.modes-from-profile", true);
            }
        }
        SettingsPlan::PowerProfile(pp) => m.set_string("power-profile", pp.as_str()),
        SettingsPlan::Network(n) => {
            m.set_string("network.interface", &n.interface);
            match n.ipv4 {
                IPv4Config::Dhcp => m.set_string("network.mode", "dhcp"),
                IPv4Config::Manual { address, prefix, router } => {
                    m.set_string("network.mode", "manual");
                    m.set_string("network.address", &address.to_string());
                    m.set_string("network.netmask", &IPv4::mask(prefix).to_string());
                    if let Some(r) = router {
                        m.set_string("network.router", &r.to_string());
                    }
                }
            }
            m.set_string("network.dns", &n.dns.iter().map(IPv4::to_string).collect::<Vec<_>>().join(" "));
        }
        SettingsPlan::Sound(s) => m.set_string("sound.default", &s.default_unit.to_string()),
        SettingsPlan::Volume(v) => {
            let (action, fields): (&str, &[(&str, &str)]) = match v {
                VolumeAction::Snapshot { dataset, name } => ("snapshot", &[("volume.dataset", dataset), ("volume.name", name)]),
                VolumeAction::Rollback { snapshot } => ("rollback", &[("volume.snapshot", snapshot)]),
                VolumeAction::MountDataset(ds) => ("mount", &[("volume.dataset", ds)]),
                VolumeAction::UnmountDataset(ds) => ("unmount", &[("volume.dataset", ds)]),
                VolumeAction::Unmount { path } => ("unmount", &[("volume.path", path)]),
            };
            m.set_string("volume.action", action);
            for (k, v) in fields {
                m.set_string(k, v);
            }
        }
        SettingsPlan::Accounts(a) => match a {
            AccountAction::Add { name, full_name, password_hash, admin } => {
                m.set_string("accounts.action", "add");
                m.set_string("accounts.name", name);
                m.set_string("accounts.fullname", full_name);
                m.set_string("accounts.hash", password_hash);
                m.set_bool("accounts.admin", *admin);
            }
            AccountAction::Delete { name, remove_home } => {
                m.set_string("accounts.action", "delete");
                m.set_string("accounts.name", name);
                m.set_bool("accounts.removehome", *remove_home);
            }
            AccountAction::AutoLogin(name) => {
                m.set_string("accounts.action", "autologin");
                if let Some(n) = name {
                    m.set_string("accounts.name", n);
                }
            }
        },
        SettingsPlan::Signal(s) => {
            m.set_string("signal.pid", &s.pid.to_string());
            m.set_bool("signal.force", s.force);
            m.set_string("signal.started", &s.started.to_string());
            m.set_string("signal.name", &s.name);
        }
        SettingsPlan::Wifi(w) => {
            m.set_string("wifi.device", &w.device);
            m.set_string("wifi.interface", &w.interface);
            m.set_string("wifi.ssid", w.ssid());
            match &w.action {
                WifiAction::Join { psk, .. } => {
                    m.set_string("wifi.action", "join");
                    if let Some(p) = psk {
                        m.set_string("wifi.psk", p); // the derived key; never a passphrase
                    }
                }
                WifiAction::Forget { .. } => m.set_string("wifi.action", "forget"),
            }
        }
    }
}

fn no<T>(why: impl Into<String>) -> Result<T, SettingsRefusal> {
    Err(SettingsRefusal::new(why))
}

fn or_else<'a>(s: &'a str, empty: &'a str) -> &'a str {
    if s.is_empty() { empty } else { s }
}

/// The plan a message describes, or why it describes none. An unknown kind
/// or an unknown mode is refused rather than defaulted: a helper that guessed
/// what a caller meant is a helper that does something nobody asked.
pub fn decode_plan(m: &Msg) -> Result<SettingsPlan, SettingsRefusal> {
    let s = |k: &str| m.string(k);
    match s("kind").unwrap_or("") {
        "energy" => {
            let Some(powerd) = m.bool("energy.powerd") else { return no("an energy plan must say whether powerd runs") };
            let ac = s("energy.ac").unwrap_or(PowerdMode::Hiadaptive.as_str());
            let bat = s("energy.battery").unwrap_or(PowerdMode::Adaptive.as_str());
            let (Some(on_ac), Some(on_battery)) = (PowerdMode::from_name(ac), PowerdMode::from_name(bat)) else {
                let bad = if PowerdMode::from_name(ac).is_none() { ac } else { bat };
                let all: Vec<&str> = PowerdMode::ALL.iter().map(|m| m.as_str()).collect();
                return no(format!("powerd has no mode {bad} (it has: {})", all.join(", ")));
            };
            let modes_from_profile = m.bool("energy.modes-from-profile").unwrap_or(false);
            Ok(SettingsPlan::Energy(EnergyPlan { powerd, on_ac, on_battery, modes_from_profile }))
        }
        "power-profile" => match s("power-profile").and_then(PowerProfile::from_name) {
            Some(p) => Ok(SettingsPlan::PowerProfile(p)),
            None => no("a power-profile plan must name power-saver, balanced or performance"),
        },
        "network" => {
            let interface = s("network.interface").unwrap_or("").to_owned();
            let mut dns = Vec::new();
            for w in s("network.dns").unwrap_or("").split(' ').filter(|w| !w.is_empty()) {
                let Some(d) = IPv4::parse(w) else { return no(format!("{w} is not an IPv4 address (a name server)")) };
                dns.push(d);
            }
            let ipv4 = match s("network.mode").unwrap_or("") {
                "dhcp" => IPv4Config::Dhcp,
                "manual" => {
                    let (a, mask) = (s("network.address").unwrap_or(""), s("network.netmask").unwrap_or(""));
                    let Some(address) = IPv4::parse(a) else {
                        return no(format!("{} is not an IPv4 address", or_else(a, "no address")));
                    };
                    let Some(prefix) = IPv4::parse(mask).and_then(IPv4::prefix_length) else {
                        return no(format!("{} is not a subnet mask", or_else(mask, "no subnet mask")));
                    };
                    let router = match s("network.router").filter(|r| !r.is_empty()) {
                        None => None,
                        Some(r) => match IPv4::parse(r) {
                            Some(rv) => Some(rv),
                            None => return no(format!("{r} is not a router's IPv4 address")),
                        },
                    };
                    IPv4Config::Manual { address, prefix, router }
                }
                "" => return no("a network plan must say DHCP or manual"),
                other => return no(format!("{other} is not DHCP or manual")),
            };
            Ok(SettingsPlan::Network(NetworkPlan { interface, ipv4, dns }))
        }
        "accounts" => {
            let name = s("accounts.name").map(str::to_owned);
            Ok(SettingsPlan::Accounts(match s("accounts.action").unwrap_or("") {
                "add" => {
                    let (Some(name), Some(hash)) = (name, s("accounts.hash")) else {
                        return no("a new account needs a name and a password");
                    };
                    AccountAction::Add {
                        name,
                        full_name: s("accounts.fullname").unwrap_or("").to_owned(),
                        password_hash: hash.to_owned(),
                        admin: m.bool("accounts.admin").unwrap_or(false),
                    }
                }
                "delete" => {
                    let Some(name) = name else { return no("a deletion must name the account") };
                    AccountAction::Delete { name, remove_home: m.bool("accounts.removehome").unwrap_or(false) }
                }
                "autologin" => AccountAction::AutoLogin(name),
                "" => return no("an accounts plan must say what to do"),
                other => return no(format!("{other} is not something the Accounts pane does")),
            }))
        }
        "volume" => {
            let (ds, path) = (s("volume.dataset").map(str::to_owned), s("volume.path").map(str::to_owned));
            Ok(SettingsPlan::Volume(match s("volume.action").unwrap_or("") {
                "snapshot" => {
                    let (Some(dataset), Some(name)) = (ds, s("volume.name")) else {
                        return no("a snapshot needs a dataset and a name");
                    };
                    VolumeAction::Snapshot { dataset, name: name.to_owned() }
                }
                "rollback" => {
                    let Some(snap) = s("volume.snapshot") else { return no("a rollback needs a snapshot") };
                    VolumeAction::Rollback { snapshot: snap.to_owned() }
                }
                "mount" => {
                    let Some(ds) = ds else { return no("a mount needs a dataset") };
                    VolumeAction::MountDataset(ds)
                }
                "unmount" => match (ds, path) {
                    (Some(ds), _) => VolumeAction::UnmountDataset(ds),
                    (None, Some(path)) => VolumeAction::Unmount { path },
                    (None, None) => return no("an unmount needs a dataset or a mount point"),
                },
                "" => return no("a volume plan must say what to do"),
                other => return no(format!("{other} is not something Disk Utility does")),
            }))
        }
        "signal" => {
            let pid = s("signal.pid").and_then(|p| p.parse().ok());
            let started = s("signal.started").and_then(|p| p.parse().ok());
            let (Some(pid), Some(started)) = (pid, started) else {
                return no("a quit must say which process, and when it started");
            };
            let force = m.bool("signal.force").unwrap_or(false);
            Ok(SettingsPlan::Signal(SignalPlan { pid, force, started, name: s("signal.name").unwrap_or("").to_owned() }))
        }
        "sound" => {
            let said = s("sound.default").unwrap_or("");
            match said.strip_prefix("pcm").unwrap_or(said).parse() {
                Ok(default_unit) => Ok(SettingsPlan::Sound(SoundPlan { default_unit })),
                Err(_) if said.is_empty() => no("a sound plan must say which device is the default"),
                Err(_) => no(format!("{said} is not a sound device (pcm0, pcm1 …)")),
            }
        }
        "wifi" => {
            let device = s("wifi.device").unwrap_or("").to_owned();
            let interface = s("wifi.interface").unwrap_or("wlan0").to_owned();
            let ssid = s("wifi.ssid").unwrap_or("").to_owned();
            let action = match s("wifi.action").unwrap_or("") {
                "join" => WifiAction::Join { ssid, psk: s("wifi.psk").map(str::to_owned) },
                "forget" => WifiAction::Forget { ssid },
                "" => return no("a Wi-Fi plan must say join or forget"),
                other => return no(format!("{other} is not join or forget")),
            };
            Ok(SettingsPlan::Wifi(WifiPlan { device, interface, action }))
        }
        "" => no("the request names no kind of plan"),
        other => no(format!("there is no {other} plan (there is: energy, network, power-profile, sound, wifi)")),
    }
}

// MARK: events

pub fn encode_event(e: &SettingsEvent) -> Msg {
    let mut m = Msg::new();
    match e {
        SettingsEvent::Starting { index, total, what } => {
            m.set_string("event", "starting");
            m.set_u64("index", *index);
            m.set_u64("total", *total);
            m.set_string("what", what);
        }
        SettingsEvent::Ok { index } => {
            m.set_string("event", "ok");
            m.set_u64("index", *index);
        }
        SettingsEvent::Failed { index, what, why, ignored } => {
            m.set_string("event", "failed");
            m.set_u64("index", *index);
            m.set_string("what", what);
            m.set_string("why", why);
            m.set_bool("ignored", *ignored);
        }
        SettingsEvent::Skipped { index, why } => {
            m.set_string("event", "skipped");
            m.set_u64("index", *index);
            m.set_string("why", why);
        }
        SettingsEvent::Finished { ok, error } => {
            m.set_string("event", "finished");
            m.set_bool("ok", *ok);
            m.set_string("error", error);
        }
    }
    m
}

/// The event a message is, or None. Swift traps on an index past `Int.max`;
/// here it is only a large index.
pub fn decode_event(m: &Msg) -> Option<SettingsEvent> {
    let index = m.u64("index").unwrap_or(0);
    let text = |k: &str| m.string(k).unwrap_or("").to_owned();
    Some(match m.string("event")? {
        "starting" => SettingsEvent::Starting { index, total: m.u64("total").unwrap_or(0), what: text("what") },
        "ok" => SettingsEvent::Ok { index },
        "failed" => SettingsEvent::Failed { index, what: text("what"), why: text("why"), ignored: m.bool("ignored").unwrap_or(false) },
        "skipped" => SettingsEvent::Skipped { index, why: text("why") },
        "finished" => SettingsEvent::Finished { ok: m.bool("ok").unwrap_or(false), error: text("error") },
        _ => return None,
    })
}

// MARK: Wi-Fi: what the machine knows, and what a scan found (P14.5)

/// A radio's configuration as rc.conf and wpa_supplicant.conf have it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct WifiKnown {
    pub device: String,
    /// The wlan interface rc makes on it, or None when `wlans_<device>` is
    /// unset.
    pub interface: Option<String>,
    /// The networks wpa_supplicant.conf holds, in order.
    pub networks: Vec<String>,
}

pub fn encode_known(k: &WifiKnown, m: &mut Msg) {
    m.set_string("wifi.device", &k.device);
    if let Some(i) = &k.interface {
        m.set_string("wifi.interface", i);
    }
    m.set_u64("wifi.known.count", k.networks.len() as u64);
    for (i, n) in k.networks.iter().enumerate() {
        m.set_string(&format!("wifi.known.{i}"), n);
    }
}

/// The fields named `<prefix><i><suffix>` with `i` below `count`, by `i`:
/// read from the message, so a count far past what it holds costs nothing
/// (Swift counts up to it).
fn indexed<'a>(m: &'a Msg, prefix: &str, suffix: &str, count: u64) -> BTreeMap<u64, &'a Value> {
    m.fields()
        .iter()
        .filter_map(|(name, value)| {
            let digits = name.strip_prefix(prefix)?.strip_suffix(suffix)?;
            let i: u64 = digits.parse().ok()?;
            (i < count && i.to_string() == digits).then_some((i, value))
        })
        .collect()
}

pub fn decode_known(m: &Msg) -> WifiKnown {
    let count = m.u64("wifi.known.count").unwrap_or(0);
    let networks = indexed(m, "wifi.known.", "", count)
        .into_values()
        .filter_map(|v| if let Value::String(s) = v { Some(s.clone()) } else { None })
        .collect();
    WifiKnown { device: m.string("wifi.device").unwrap_or("").to_owned(), interface: m.string("wifi.interface").map(str::to_owned), networks }
}

pub fn encode_scan(nets: &[WifiNetwork], m: &mut Msg) {
    m.set_u64("scan.count", nets.len() as u64);
    for (i, n) in nets.iter().enumerate() {
        m.set_string(&format!("scan.{i}.ssid"), &n.ssid);
        m.set_string(&format!("scan.{i}.bssid"), &n.bssid);
        m.set_u64(&format!("scan.{i}.channel"), n.channel.max(0) as u64);
        m.set_string(&format!("scan.{i}.signal"), &n.signal.to_string());
        m.set_bool(&format!("scan.{i}.secured"), n.secured);
    }
}

pub fn decode_scan(m: &Msg) -> Vec<WifiNetwork> {
    let count = m.u64("scan.count").unwrap_or(0);
    indexed(m, "scan.", ".ssid", count)
        .into_iter()
        .filter_map(|(i, v)| {
            let Value::String(ssid) = v else { return None };
            let f = |k: &str| format!("scan.{i}.{k}");
            Some(WifiNetwork {
                ssid: ssid.clone(),
                bssid: m.string(&f("bssid")).unwrap_or("").to_owned(),
                // Swift traps past Int.max.
                channel: m.u64(&f("channel")).map_or(0, |c| i64::try_from(c).unwrap_or(i64::MAX)),
                signal: m.string(&f("signal")).and_then(|s| s.parse().ok()).unwrap_or(0),
                secured: m.bool(&f("secured")).unwrap_or(false),
            })
        })
        .collect()
}
