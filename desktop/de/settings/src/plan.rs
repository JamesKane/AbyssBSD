//! The plans: one per pane, values and nothing else.

use crate::wifi::WifiPlan;
use std::fmt;

/// powerd's policy for one power source (`powerd(8)` `-a` / `-b`).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum PowerdMode {
    Adaptive,
    Hiadaptive,
    Minimum,
    Maximum,
}

impl PowerdMode {
    pub const ALL: [PowerdMode; 4] = [PowerdMode::Adaptive, PowerdMode::Hiadaptive, PowerdMode::Minimum, PowerdMode::Maximum];

    pub fn as_str(self) -> &'static str {
        match self {
            PowerdMode::Adaptive => "adaptive",
            PowerdMode::Hiadaptive => "hiadaptive",
            PowerdMode::Minimum => "min",
            PowerdMode::Maximum => "max",
        }
    }

    pub fn from_name(s: &str) -> Option<PowerdMode> {
        PowerdMode::ALL.into_iter().find(|m| m.as_str() == s)
    }
}

/// The Energy pane's machine half: whether `powerd` runs, and how.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct EnergyPlan {
    pub powerd: bool,
    pub on_ac: PowerdMode,
    pub on_battery: PowerdMode,
    /// powerd's modes are the power profile's to choose (P14.8b): run it
    /// with no flags, because rc.d/power_profile only sets powerd's mode when
    /// `powerd_flags` is empty. `on_ac`/`on_battery` are then not written.
    pub modes_from_profile: bool,
}

impl EnergyPlan {
    /// powerd on or off, with the defaults: hiadaptive on AC, adaptive on
    /// battery.
    pub fn new(powerd: bool) -> EnergyPlan {
        EnergyPlan { powerd, on_ac: PowerdMode::Hiadaptive, on_battery: PowerdMode::Adaptive, modes_from_profile: false }
    }

    /// What rc.conf says, as `sysrc -n` reports it (defaults already
    /// applied). A flags string this does not understand is kept as the
    /// defaults rather than guessed at: a pane that showed a policy nobody
    /// set would be worse.
    pub fn from(enable: Option<&str>, flags: Option<&str>) -> EnergyPlan {
        let mut p = EnergyPlan::new(enable.unwrap_or("NO").to_uppercase() == "YES");
        let words = crate::words(flags.unwrap_or(""));
        for [flag, mode] in words.as_chunks::<2>().0 {
            if let Some(m) = PowerdMode::from_name(mode) {
                match *flag {
                    "-a" => p.on_ac = m,
                    "-b" => p.on_battery = m,
                    _ => {}
                }
            }
        }
        p
    }
}

/// The base system's power profile (P14.8b): rc.conf's `power_profile`, as
/// `rc.d/power_profile` in the AbyssBSD base reads it: CPU idle depth,
/// powerd's mode and hooks such as a GPU's clocks, chosen as one thing.
/// **Upstream FreeBSD has no such variable** (its `rc.d/power_profile` is the
/// older AC-line script), so a base without it is told, not guessed at:
/// [`unavailable`](crate::unavailable).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum PowerProfile {
    PowerSaver,
    Balanced,
    Performance,
}

impl PowerProfile {
    pub const ALL: [PowerProfile; 3] = [PowerProfile::PowerSaver, PowerProfile::Balanced, PowerProfile::Performance];

    pub fn as_str(self) -> &'static str {
        match self {
            PowerProfile::PowerSaver => "power-saver",
            PowerProfile::Balanced => "balanced",
            PowerProfile::Performance => "performance",
        }
    }

    pub fn from_name(s: &str) -> Option<PowerProfile> {
        PowerProfile::ALL.into_iter().find(|p| p.as_str() == s)
    }
}

/// Everything System Preferences may ask of the machine. One case per pane.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum SettingsPlan {
    Energy(EnergyPlan),
    PowerProfile(PowerProfile),
    Network(NetworkPlan),
    Sound(SoundPlan),
    Wifi(WifiPlan),
    /// Quit another user's process (P15.7, Activity Monitor): the one plan
    /// that acts on a process rather than on the machine's configuration.
    Signal(SignalPlan),
    /// Disk Utility (P15.8): a ZFS snapshot or rollback, a mount or unmount.
    Volume(VolumeAction),
    /// The Accounts pane (PHASE16 P16.6a): add or delete a user, or choose
    /// who is logged in automatically.
    Accounts(AccountAction),
}

impl SettingsPlan {
    pub fn kind(&self) -> &'static str {
        match self {
            SettingsPlan::Energy(_) => "energy",
            SettingsPlan::PowerProfile(_) => "power-profile",
            SettingsPlan::Network(_) => "network",
            SettingsPlan::Sound(_) => "sound",
            SettingsPlan::Wifi(_) => "wifi",
            SettingsPlan::Signal(_) => "signal",
            SettingsPlan::Volume(_) => "volume",
            SettingsPlan::Accounts(_) => "accounts",
        }
    }
}

// MARK: accounts (PHASE16 P16.6a)

/// One change the Accounts pane may ask for. The password is a crypt(3)
/// hash, made in the pane: **no plan ever carries a password**, as no install
/// plan does (P5.4), and the hash itself is given to `pw` on stdin, never
/// argv.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum AccountAction {
    Add { name: String, full_name: String, password_hash: String, admin: bool },
    /// The account goes; its home stays unless `remove_home`: a person's
    /// files are not deleted by a button that said "delete user".
    Delete { name: String, remove_home: bool },
    /// Who is logged in at boot with no password; None for the login window.
    AutoLogin(Option<String>),
}

// MARK: volumes (P15.8)

/// One change Disk Utility may ask for. Names are checked here, strictly;
/// whether they exist, and whether a rollback would destroy later snapshots,
/// is the helper's to check on the machine.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum VolumeAction {
    Snapshot { dataset: String, name: String },
    /// Only to a dataset's latest snapshot: `zfs rollback -r` would destroy
    /// the ones after it, and that is not something a button does quietly.
    Rollback { snapshot: String },
    MountDataset(String),
    UnmountDataset(String),
    /// A mounted filesystem that is not a dataset: a stick, a partition.
    Unmount { path: String },
}

// MARK: quitting a process (P15.7)

/// Quit (SIGTERM) or Force Quit (SIGKILL) one process, **the one the window
/// showed**: its pid, when it started and its name travel with the request,
/// and the helper refuses a pid that has since become another process.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SignalPlan {
    pub pid: i32,
    pub force: bool,
    pub started: i64,
    pub name: String,
}

// MARK: sound (P14.6)

/// Which device `/dev/dsp` means. Levels and mute are not here: `/dev/mixerN`
/// is the user's to change, and `rc.d/mixer` saves them at shutdown and
/// restores them at boot. The default unit is a sysctl, which is root's.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct SoundPlan {
    pub default_unit: i64,
}

// MARK: network (P14.4)

/// An IPv4 address, parsed strictly: four decimal octets, nothing else.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct IPv4(pub [u8; 4]);

impl IPv4 {
    pub fn parse(s: &str) -> Option<IPv4> {
        let parts: Vec<&str> = s.split('.').collect();
        if parts.len() != 4 {
            return None;
        }
        let mut o = [0u8; 4];
        for (i, p) in parts.iter().enumerate() {
            if p.is_empty() || p.len() > 3 || !p.bytes().all(|b| b.is_ascii_digit()) || (p.len() > 1 && p.starts_with('0')) {
                return None;
            }
            o[i] = p.parse().ok()?;
        }
        Some(IPv4(o))
    }

    pub fn from_value(v: u32) -> IPv4 {
        IPv4(v.to_be_bytes())
    }

    pub fn value(self) -> u32 {
        u32::from_be_bytes(self.0)
    }

    /// A dotted netmask as a prefix length, or None when it is not a mask at
    /// all: its ones not contiguous from the top.
    pub fn prefix_length(self) -> Option<u32> {
        let v = self.value();
        let ones = v.count_ones();
        (v == mask_value(ones)).then_some(ones)
    }

    pub fn mask(prefix: u32) -> IPv4 {
        IPv4::from_value(mask_value(prefix))
    }
}

fn mask_value(prefix: u32) -> u32 {
    if prefix == 0 { 0 } else { u32::MAX << (32 - prefix.min(32)) }
}

impl fmt::Display for IPv4 {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let [a, b, c, d] = self.0;
        write!(f, "{a}.{b}.{c}.{d}")
    }
}

/// How an interface gets its IPv4 address.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum IPv4Config {
    Dhcp,
    Manual { address: IPv4, prefix: u32, router: Option<IPv4> },
}

/// The Network pane's plan for one wired interface (P14.4).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct NetworkPlan {
    pub interface: String,
    pub ipv4: IPv4Config,
    /// Name servers, in order; empty for whatever DHCP says, or none.
    pub dns: Vec<IPv4>,
}

impl NetworkPlan {
    /// What the machine says, from `ifconfig_<if>`, `defaultrouter` and
    /// resolvconf's `name_servers`. A line this does not understand (an
    /// alias, an IPv6 address, `ifconfig_DEFAULT`) reads as DHCP only when it
    /// says DHCP; otherwise the plan is None and the pane says it cannot show
    /// it.
    pub fn from(interface: &str, ifconfig: Option<&str>, router: Option<&str>, name_servers: Option<&str>) -> Option<NetworkPlan> {
        let dns = crate::words(name_servers.unwrap_or("")).into_iter().filter_map(IPv4::parse).collect();
        let words = crate::words(ifconfig.unwrap_or(""));
        let ipv4 = if words.is_empty() || words.iter().any(|w| w.to_uppercase().ends_with("DHCP")) {
            IPv4Config::Dhcp
        } else {
            let ["inet", a, "netmask", m, ..] = words[..] else { return None };
            let address = IPv4::parse(a)?;
            let prefix = IPv4::parse(m)?.prefix_length()?;
            IPv4Config::Manual { address, prefix, router: router.and_then(IPv4::parse) }
        };
        Some(NetworkPlan { interface: interface.to_owned(), ipv4, dns })
    }
}
