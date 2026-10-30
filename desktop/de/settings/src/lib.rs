//! Settings in Rust (RUST.md R2): what System Preferences may ask the
//! machine to change, as values (PHASE14 P14.3), ported from the Swift beside
//! it.
//!
//! The installer's shape (PHASE14 §3): an unprivileged pane describes what it
//! wants as a typed **plan**; this decides whether that may happen (refusals,
//! in words) and compiles it to the exact **steps** a root helper will run.
//! Nothing here runs anything, and it depends on nothing, so every refusal
//! and every step list is tested on a machine with no rc.conf.
//!
//! **The pane never names a command, a file or a key.** A plan says "powerd
//! on, adaptive on AC"; which rc.conf variables that means, and which service
//! to restart, is decided here and nowhere else. A caller that could send
//! "set this variable to that" would be handing root to whoever can reach the
//! socket.

pub mod key;
mod plan;
mod steps;
mod wifi;

pub use plan::{
    AccountAction, EnergyPlan, IPv4, IPv4Config, NetworkPlan, PowerProfile, PowerdMode, SettingsPlan, SignalPlan, SoundPlan,
    VolumeAction,
};
pub use steps::{edit_file, edit_sysctl_conf, render, render_etc, sysctl_conf_value, ConfFile, SettingsStep};
pub use wifi::{is_bssid, is_radio_name, parse_scan, wpa, WifiAction, WifiNetwork, WifiPlan};

use std::collections::HashMap;
use std::fmt;

/// Why a plan must not be carried out, in words a pane shows as they are.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SettingsRefusal {
    pub message: String,
}

impl SettingsRefusal {
    pub fn new(message: impl Into<String>) -> SettingsRefusal {
        SettingsRefusal { message: message.into() }
    }
}

impl fmt::Display for SettingsRefusal {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.message)
    }
}

impl std::error::Error for SettingsRefusal {}

/// Space-separated words, empty ones dropped.
pub(crate) fn words(s: &str) -> Vec<&str> {
    s.split(' ').filter(|w| !w.is_empty()).collect()
}

fn refuse(message: impl Into<String>) -> Vec<SettingsRefusal> {
    vec![SettingsRefusal::new(message)]
}

/// Why a plan must not be carried out, in words; empty when it may be. A
/// typed plan leaves little to refuse (the modes are an enumeration, not a
/// string), which is the point of typing it.
pub fn problems(plan: &SettingsPlan) -> Vec<SettingsRefusal> {
    match plan {
        SettingsPlan::Energy(_) | SettingsPlan::PowerProfile(_) => Vec::new(),
        SettingsPlan::Network(n) => network_problems(n),
        SettingsPlan::Sound(s) if s.default_unit < 0 => refuse(format!("pcm{} is not a sound device's unit", s.default_unit)),
        SettingsPlan::Sound(_) => Vec::new(),
        SettingsPlan::Wifi(w) => wifi::problems(w),
        SettingsPlan::Signal(s) if s.pid == 1 => refuse("pid 1 is init: quitting it would stop the machine"),
        SettingsPlan::Signal(s) if s.pid <= 1 => refuse(format!("{} is not a process", s.pid)),
        SettingsPlan::Signal(s) if s.name.is_empty() => refuse("a quit must name the process it means"),
        SettingsPlan::Signal(_) => Vec::new(),
        SettingsPlan::Volume(v) => volume_problems(v),
        SettingsPlan::Accounts(a) => account_problems(a),
    }
}

/// The step list, or the first refusal. The same function `check` and
/// `apply` call, so a plan that checks is a plan that applies.
pub fn compile(plan: &SettingsPlan) -> Result<Vec<SettingsStep>, SettingsRefusal> {
    if let Some(first) = problems(plan).into_iter().next() {
        return Err(first);
    }
    let rc = SettingsStep::rc_conf;
    Ok(match plan {
        // Off: say so in rc.conf, drop the policy, and stop it, which may
        // well not be running, and that is not a failure.
        SettingsPlan::Energy(e) if !e.powerd => vec![
            rc("powerd_enable", Some("NO")),
            rc("powerd_flags", None),
            SettingsStep::service("powerd", &["onestop"], true),
        ],
        SettingsPlan::Energy(e) => {
            let flags = format!("-a {} -b {}", e.on_ac.as_str(), e.on_battery.as_str());
            vec![
                rc("powerd_enable", Some("YES")),
                rc("powerd_flags", if e.modes_from_profile { None } else { Some(&flags) }),
                SettingsStep::service("powerd", &["onerestart"], false),
            ]
        }
        // The profile, then powerd's own flags cleared: rc.d/power_profile
        // chooses powerd's mode only when `powerd_flags` is empty, so a policy
        // the Energy pane once set would silently outrank the profile. Then
        // applied now, as boot would.
        SettingsPlan::PowerProfile(p) => vec![
            rc("power_profile", Some(p.as_str())),
            rc("powerd_flags", None),
            SettingsStep::service("power_profile", &["start"], false),
        ],
        SettingsPlan::Wifi(w) => wifi::compile(w),
        SettingsPlan::Signal(s) => {
            vec![SettingsStep::tool(&["kill", "-s", if s.force { "KILL" } else { "TERM" }, &s.pid.to_string()], false)]
        }
        SettingsPlan::Volume(v) => compile_volume(v),
        SettingsPlan::Accounts(a) => compile_account(a),
        // For the next boot, then for now. The kernel refuses a unit with no
        // device behind it, which fails the plan, after sysctl.conf is
        // written, so the helper checks the unit exists first.
        SettingsPlan::Sound(s) => {
            let unit = s.default_unit.to_string();
            vec![
                SettingsStep::set_var(ConfFile::SysctlConf, "hw.snd.default_unit", Some(&unit)),
                SettingsStep::tool(&["sysctl", &format!("hw.snd.default_unit={unit}")], false),
            ]
        }
        SettingsPlan::Network(n) => {
            let ifconfig = format!("ifconfig_{}", n.interface);
            let mut steps = match n.ipv4 {
                // SYNCDHCP, as the installer writes: rc waits for the lease,
                // so what starts after the network finds one.
                IPv4Config::Dhcp => vec![rc(&ifconfig, Some("SYNCDHCP")), rc("defaultrouter", None)],
                IPv4Config::Manual { address, prefix, router } => vec![
                    rc(&ifconfig, Some(&format!("inet {address} netmask {}", IPv4::mask(prefix)))),
                    rc("defaultrouter", router.map(|r| r.to_string()).as_deref()),
                ],
            };
            let servers = n.dns.iter().map(IPv4::to_string).collect::<Vec<_>>().join(" ");
            steps.push(SettingsStep::set_var(
                ConfFile::Resolvconf,
                "name_servers",
                if n.dns.is_empty() { None } else { Some(&servers) },
            ));
            // Then act: the interface again, the routes again, and the
            // resolver's file written from what is now configured.
            steps.push(SettingsStep::service("netif", &["restart", &n.interface], false));
            steps.push(SettingsStep::service("routing", &["restart"], false));
            steps.push(SettingsStep::tool(&["resolvconf", "-u"], false));
            steps
        }
    })
}

// MARK: network

/// A wired interface's name as FreeBSD spells it (letters, then a unit
/// number: `em0`, `igc0`, `vtnet0`), and not the loopback.
pub fn is_interface_name(s: &str) -> bool {
    is_radio_name(s) && !s.starts_with("lo")
}

fn network_problems(n: &NetworkPlan) -> Vec<SettingsRefusal> {
    let mut out = Vec::new();
    let mut no = |m: String| out.push(SettingsRefusal::new(m));
    if !is_interface_name(&n.interface) {
        let i = if n.interface.is_empty() { "no interface" } else { &n.interface };
        no(format!("{i} is not a wired interface's name"));
    }
    if let IPv4Config::Manual { address: a, prefix: p, router } = n.ipv4 {
        if !(8..=30).contains(&p) {
            no(format!("a /{p} network is not one a wired interface is given (8 to 30)"));
        } else {
            let mask = IPv4::mask(p).value();
            let host = a.value() & !mask;
            if host == 0 {
                no(format!("{a} is the network's own address, not a host's"));
            }
            if host == !mask {
                no(format!("{a} is the network's broadcast address"));
            }
            if let Some(r) = router {
                if r.value() & mask != a.value() & mask {
                    no(format!("the router {r} is not on {a}'s network (/{p}) — it could not be reached"));
                } else if r == a {
                    no("the router cannot be this machine's own address".into());
                }
            }
        }
        if a.0[0] == 0 || a.0[0] == 127 || a.0[0] >= 224 {
            no(format!("{a} cannot be an interface's address"));
        }
    }
    if n.dns.len() > 3 {
        no(format!("{} name servers: the resolver uses three at most", n.dns.len()));
    }
    for d in n.dns.iter().filter(|d| d.value() == 0 || d.0[0] >= 224) {
        no(format!("{d} cannot be a name server"));
    }
    out
}

// MARK: accounts (PHASE16 P16.6a)

/// The groups a new account is given: the installer's (P5.4), so a user
/// made here is like one made there.
pub fn account_groups(admin: bool) -> &'static [&'static str] {
    if admin { &["wheel", "operator", "audio", "video"] } else { &["audio", "video"] }
}

/// An account name FreeBSD's `pw` takes and a person may have: lower-case
/// letters, digits, `_` and `-`, starting with a letter, at most 16.
pub fn is_account_name(s: &str) -> bool {
    s.as_bytes().first().is_some_and(u8::is_ascii_lowercase)
        && s.len() <= 16
        && s.bytes().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'_' || b == b'-')
}

/// The system's own accounts, which no plan adds or deletes.
pub const RESERVED_ACCOUNTS: &[&str] = &[
    "root", "toor", "daemon", "operator", "bin", "tty", "kmem", "games", "news", "man", "sshd", "smmsp", "mailnull", "bind",
    "unbound", "proxy", "pflogd", "dhcp", "uucp", "pop", "auditdistd", "www", "ntpd", "nobody", "hast", "tests",
    "messagebus", "polkitd", "avahi", "cups", "abyss",
];

fn is_reserved(name: &str) -> bool {
    RESERVED_ACCOUNTS.contains(&name)
}

fn account_problems(a: &AccountAction) -> Vec<SettingsRefusal> {
    match a {
        AccountAction::Add { name, full_name, password_hash: hash, .. } => {
            let mut out = Vec::new();
            if !is_account_name(name) {
                let n = if name.is_empty() { "an empty name".to_owned() } else { format!("\"{name}\"") };
                out.push(SettingsRefusal::new(format!(
                    "{n} is not an account name (lower-case letters, digits, _ and -, starting with a letter, at most 16)"
                )));
            } else if is_reserved(name) {
                out.push(SettingsRefusal::new(format!("{name} is one of the system's accounts")));
            }
            if full_name.contains([':', '\n', ',']) {
                out.push(SettingsRefusal::new("a full name cannot contain a colon, a comma or a new line"));
            }
            if !(hash.starts_with("$6$") || hash.starts_with("$2b$")) || hash.contains([':', '\n']) {
                out.push(SettingsRefusal::new("the password did not arrive hashed"));
            }
            out
        }
        AccountAction::Delete { name, .. } if !is_account_name(name) => refuse(format!("{name} is not an account name")),
        AccountAction::Delete { name, .. } if is_reserved(name) => refuse(format!("{name} is one of the system's accounts")),
        AccountAction::AutoLogin(Some(name)) if !is_account_name(name) => refuse(format!("{name} is not an account name")),
        AccountAction::Delete { .. } | AccountAction::AutoLogin(_) => Vec::new(),
    }
}

fn compile_account(a: &AccountAction) -> Vec<SettingsStep> {
    let rc = SettingsStep::rc_conf;
    match a {
        AccountAction::Add { name, full_name, password_hash, admin } => {
            let mut args: Vec<String> = ["useradd", "-n", name, "-m", "-s", "/bin/sh", "-G", &account_groups(*admin).join(","), "-H", "0"]
                .map(str::to_owned)
                .to_vec();
            if !full_name.is_empty() {
                args.extend(["-c".to_owned(), full_name.clone()]);
            }
            let what = format!("create the account {name}{}", if *admin { ", an administrator" } else { "" });
            vec![SettingsStep::Pw { args, input: Some(password_hash.clone()), what }]
        }
        AccountAction::Delete { name, remove_home } => {
            let mut args = vec!["userdel".to_owned(), "-n".to_owned(), name.clone()];
            if *remove_home {
                args.push("-r".into());
            }
            let rest = if *remove_home { " and its home folder" } else { ", keeping its home folder" };
            vec![SettingsStep::Pw { args, input: None, what: format!("delete the account {name}{rest}") }]
        }
        // The owner's desktop at boot (rc.d/abyss_desktop), and not the
        // login window as well: two sessions on one display at boot.
        AccountAction::AutoLogin(Some(name)) => vec![
            rc("abyss_desktop_enable", Some("YES")),
            rc("abyss_desktop_user", Some(name)),
            rc("abyss_loginwindow_greeter", Some("NO")),
        ],
        AccountAction::AutoLogin(None) => vec![
            rc("abyss_desktop_enable", Some("NO")),
            rc("abyss_desktop_user", None),
            rc("abyss_loginwindow_greeter", Some("YES")),
        ],
    }
}

// MARK: volumes (P15.8)

/// A ZFS dataset name: components of letters, digits and `_ . : -`
/// separated by `/`, none empty, none `.` or `..`, none starting with `-`.
pub fn is_dataset_name(s: &str) -> bool {
    !s.is_empty() && s.len() <= 255 && s.split('/').all(is_zfs_component)
}

fn is_zfs_component(c: &str) -> bool {
    !c.is_empty() && c != "." && c != ".." && !c.starts_with('-') && c.bytes().all(|b| b.is_ascii_alphanumeric() || b"_.:-".contains(&b))
}

pub fn is_snapshot_name(s: &str) -> bool {
    let parts: Vec<&str> = s.split('@').collect();
    matches!(parts[..], [ds, name] if is_dataset_name(ds) && is_zfs_component(name))
}

/// Mounts no plan unmounts: the running system's own.
pub const SYSTEM_MOUNTS: &[&str] = &["/", "/usr", "/var", "/boot", "/tmp", "/dev", "/proc", "/compat"];

pub fn is_system_mount(path: &str) -> bool {
    SYSTEM_MOUNTS.contains(&path) || path.starts_with("/dev/") || path.starts_with("/proc/")
}

fn volume_problems(v: &VolumeAction) -> Vec<SettingsRefusal> {
    match v {
        VolumeAction::Snapshot { dataset, .. } if !is_dataset_name(dataset) => refuse(format!("{dataset} is not a dataset's name")),
        VolumeAction::Snapshot { name, .. } if !is_zfs_component(name) => {
            refuse(format!("{name} is not a snapshot's name (letters, digits and _ . : -)"))
        }
        VolumeAction::Rollback { snapshot } if !is_snapshot_name(snapshot) => {
            refuse(format!("{snapshot} is not a snapshot (dataset@name)"))
        }
        VolumeAction::MountDataset(ds) | VolumeAction::UnmountDataset(ds) if !is_dataset_name(ds) => {
            refuse(format!("{ds} is not a dataset's name"))
        }
        VolumeAction::Unmount { path } if !path.starts_with('/') || path.split('/').any(|c| c == "..") || path.contains('\0') => {
            refuse(format!("{path} is not a mount point"))
        }
        VolumeAction::Unmount { path } if is_system_mount(path) => refuse(format!("{path} is the system's own, and is not unmounted")),
        _ => Vec::new(),
    }
}

fn compile_volume(v: &VolumeAction) -> Vec<SettingsStep> {
    let tool = |argv: &[&str]| vec![SettingsStep::tool(argv, false)];
    match v {
        VolumeAction::Snapshot { dataset, name } => tool(&["zfs", "snapshot", &format!("{dataset}@{name}")]),
        VolumeAction::Rollback { snapshot } => tool(&["zfs", "rollback", snapshot]),
        VolumeAction::MountDataset(ds) => tool(&["zfs", "mount", ds]),
        VolumeAction::UnmountDataset(ds) => tool(&["zfs", "unmount", ds]),
        VolumeAction::Unmount { path } => tool(&["umount", path]),
    }
}

// MARK: reading the machine back

/// The variables a plan kind reads back, and the file each is read from, so
/// the pane can show what the machine says now. For network, `interface`
/// names the interface whose line is read.
pub fn keys(kind: &str, interface: &str) -> Option<Vec<(ConfFile, String)>> {
    let rc = |k: &str| (ConfFile::RcConf, k.to_owned());
    Some(match kind {
        "energy" => vec![rc("powerd_enable"), rc("powerd_flags")],
        "power-profile" => vec![rc("power_profile")],
        "network" if is_interface_name(interface) => {
            vec![rc(&format!("ifconfig_{interface}")), rc("defaultrouter"), (ConfFile::Resolvconf, "name_servers".to_owned())]
        }
        "sound" => vec![(ConfFile::SysctlConf, "hw.snd.default_unit".to_owned())],
        _ => return None,
    })
}

/// The plan the machine is carrying out now, from those variables.
pub fn current(kind: &str, interface: &str, values: &HashMap<String, String>) -> Option<SettingsPlan> {
    let v = |k: &str| values.get(k).map(String::as_str);
    match kind {
        "energy" => Some(SettingsPlan::Energy(EnergyPlan::from(v("powerd_enable"), v("powerd_flags")))),
        "power-profile" => v("power_profile").and_then(PowerProfile::from_name).map(SettingsPlan::PowerProfile),
        "network" => NetworkPlan::from(interface, v(&format!("ifconfig_{interface}")), v("defaultrouter"), v("name_servers"))
            .map(SettingsPlan::Network),
        "sound" => v("hw.snd.default_unit")
            .and_then(|u| u.parse().ok())
            .map(|default_unit| SettingsPlan::Sound(SoundPlan { default_unit })),
        _ => None,
    }
}

/// Why a plan kind cannot be shown or applied on this machine at all, from
/// what reading its keys found; None when it can. Power profiles are the one
/// that depends on the base: `sysrc -n` answers from /etc/defaults/rc.conf,
/// which declares `power_profile` in the AbyssBSD base and not upstream.
pub fn unavailable(kind: &str, values: &HashMap<String, String>) -> Option<String> {
    if kind != "power-profile" {
        return None;
    }
    let Some(v) = values.get("power_profile") else {
        return Some("this FreeBSD offers no power profiles — its rc.d/power_profile is the older AC-line script".into());
    };
    if v.to_uppercase() == "NONE" {
        return Some("power profiles are turned off on this machine (power_profile=NONE)".into());
    }
    PowerProfile::from_name(v).is_none().then(|| format!("power_profile is \"{v}\", which is not a profile this pane knows"))
}

#[cfg(test)]
mod tests;
