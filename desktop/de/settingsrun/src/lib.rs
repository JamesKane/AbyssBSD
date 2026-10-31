//! The settings helper's privileged half, as a service (PHASE14 P14.3),
//! ported from Service.swift beside it.
//!
//!   read   {kind}    → what the machine says now, as a plan of that kind
//!   check  {plan…}   → the refusals, or the steps it compiles to: nothing run
//!   apply  {plan…}   → the same compile, then run it, one message per step and
//!                      a final `finished`
//!
//! `abyss-install`'s shape, deliberately (PHASE14 §3): the caller describes,
//! this decides, and the caller never names a command, a file or a variable.

pub mod runner;

pub use runner::{apply, apply_rc_conf, How};

use abyss_sys::{platform, users};
use current_ipc::Msg;
use runner::{read_text, reason, run, trimmed};
use settings::{zfs, AccountAction, ConfFile, SettingsPlan, SettingsRefusal, VolumeAction};
use settings_wire::{SettingsEvent, WifiKnown};
use std::collections::HashMap;
use std::fs::OpenOptions;
use std::io::Write;
use std::os::fd::AsFd;
use std::os::unix::net::UnixStream;

// MARK: who may change the machine (§6.1)

/// The uid this helper was started for, **and only while it is an
/// administrator.** Membership is asked at every connection rather than once
/// at startup: a person removed from `wheel` stops being able to change the
/// machine at that moment, not at the next reboot. No password is asked: a
/// trustworthy prompt is Phase 16's to build (§6.1).
#[derive(Clone, Debug)]
pub struct Authority {
    pub allowed: u32,
    /// The group that makes an administrator: `wheel`, as the installer
    /// says. A parameter so a test can name one its user is not in.
    pub admin_group: String,
}

impl Authority {
    pub fn new(allowed: u32) -> Authority {
        Authority { allowed, admin_group: "wheel".into() }
    }

    /// Yes, or the sentence to log when it is no. Never fails open.
    pub fn admits(&self, client: &UnixStream) -> Result<(), String> {
        let Ok(uid) = platform::peer_uid(client.as_fd()) else {
            return Err("the kernel would not identify the caller".into());
        };
        if uid != self.allowed {
            return Err(format!("uid {uid} may not use a settings helper started for uid {}", self.allowed));
        }
        if !Authority::is_member(uid, &self.admin_group) {
            let who = name(uid).unwrap_or_else(|| format!("uid {uid}"));
            return Err(format!(
                "{who} is not an administrator (not in {}), and only an administrator may change the machine",
                self.admin_group
            ));
        }
        Ok(())
    }

    /// Whether `uid` is in `group`, as its primary group or a listed member.
    pub fn is_member(uid: u32, group: &str) -> bool {
        users::group_names(uid).iter().any(|g| g == group)
    }
}

fn name(uid: u32) -> Option<String> {
    users::by_uid(uid).map(|a| a.name)
}

// MARK: the service

pub struct SettingsService {
    pub authority: Authority,
    /// Dry run, write-only, and the root `pw` works in.
    pub how: How,
    /// The rc.conf this helper edits: `/etc/rc.conf`, or a scratch file for
    /// a test that must not touch the machine it runs on.
    pub rc_conf: String,
    /// The resolver configuration name servers go into (P14.4).
    pub resolvconf: String,
    /// Kernel settings applied at boot: the default sound device (P14.6).
    pub sysctl_conf: String,
    /// The Wi-Fi networks this machine may join (P14.5).
    pub wpa_conf: String,
    /// Where every apply is recorded, whatever its outcome. Empty for none.
    pub journal: String,
}

impl SettingsService {
    pub fn new(authority: Authority) -> SettingsService {
        SettingsService {
            authority,
            how: How::default(),
            rc_conf: "/etc/rc.conf".into(),
            resolvconf: "/etc/resolvconf.conf".into(),
            sysctl_conf: "/etc/sysctl.conf".into(),
            wpa_conf: "/etc/wpa_supplicant.conf".into(),
            journal: "/var/log/abyss-settings.log".into(),
        }
    }

    /// Where each file this helper edits is, on this machine.
    pub fn path(&self, f: ConfFile) -> String {
        match f {
            ConfFile::RcConf => self.rc_conf.clone(),
            ConfFile::Resolvconf => self.resolvconf.clone(),
            ConfFile::SysctlConf => self.sysctl_conf.clone(),
            ConfFile::WpaSupplicant => self.wpa_conf.clone(),
        }
    }

    /// Why this machine cannot be changed by this helper at all, or None.
    /// **On Linux it refuses, and says why** (§6.4): the positive control
    /// that shows the refusal exists, rather than a skip that shows nothing.
    pub fn platform_refusal(&self) -> Option<&'static str> {
        if cfg!(target_os = "freebsd") {
            None
        } else {
            Some("this helper changes FreeBSD's rc.conf, and this machine is not FreeBSD — nothing was read or written")
        }
    }

    /// An account in the helper's password database, as `pw usershow` says:
    /// its uid, or None when there is none.
    fn account_uid(&self, name: &str) -> Option<u32> {
        let r = run(&strings(&["pw", "-R", &self.how.pw_root, "usershow", "-n", name]), None);
        if !r.succeeded() {
            return None;
        }
        r.stdout_text().split(':').nth(2).and_then(|u| u.parse().ok())
    }

    fn account_problems(&self, a: &AccountAction) -> Vec<SettingsRefusal> {
        let person = |name: &str| match self.account_uid(name) {
            None => Some(SettingsRefusal::new(format!("there is no account {name}"))),
            Some(uid) if (1000..65534).contains(&uid) => None,
            Some(_) => Some(SettingsRefusal::new(format!("{name} is one of the system's accounts"))),
        };
        match a {
            AccountAction::Add { name, .. } => match self.account_uid(name) {
                None => vec![],
                Some(_) => refuse(format!("there is already an account {name}")),
            },
            AccountAction::Delete { name, .. } => {
                if let Some(r) = person(name) {
                    return vec![r];
                }
                // Not the administrator who is asking: the account that
                // could undo a mistake must not be the one a click deletes.
                if self::name(self.authority.allowed).as_deref() == Some(name) {
                    return refuse(format!("{name} is the account you are using; log in as another administrator to delete it"));
                }
                if self.how.pw_root == "/" && run(&strings(&["pgrep", "-U", name]), None).succeeded() {
                    return refuse(format!("{name} is logged in; their session must end first"));
                }
                vec![]
            }
            AccountAction::AutoLogin(Some(name)) => person(name).into_iter().collect(),
            AccountAction::AutoLogin(None) => vec![],
        }
    }

    /// What exists on the machine now (P15.8): the dataset, the snapshot,
    /// the mount, and a rollback only to a dataset's latest snapshot, since
    /// rolling back past later ones would destroy them.
    fn volume_problems(&self, v: &VolumeAction) -> Vec<SettingsRefusal> {
        let zfs = |args: &[&str]| {
            let r = run(&strings(&[&["zfs"], args].concat()), None);
            (r.succeeded(), r.stdout_text())
        };
        let dataset = |ds: &str| {
            let (ok, out) = zfs(&["list", "-H", "-p", "-o", "name,used,avail,mountpoint,mounted", "-t", "filesystem", ds]);
            if ok { zfs::datasets(&out).into_iter().next() } else { None }
        };
        match v {
            VolumeAction::Snapshot { dataset: ds, name } => {
                if dataset(ds).is_none() {
                    return refuse(format!("there is no dataset {ds}"));
                }
                if zfs(&["list", "-H", "-t", "snapshot", &format!("{ds}@{name}")]).0 {
                    return refuse(format!("{ds}@{name} already exists"));
                }
                vec![]
            }
            VolumeAction::Rollback { snapshot } => {
                let ds = snapshot.split('@').next().unwrap_or("");
                let (ok, out) = zfs(&["list", "-H", "-p", "-o", "name,creation,used", "-t", "snapshot", "-d", "1", ds]);
                let snaps = if ok { zfs::snapshots(&out) } else { vec![] };
                if !snaps.iter().any(|s| &s.name == snapshot) {
                    return refuse(format!("there is no snapshot {snapshot}"));
                }
                match snaps.last() {
                    Some(latest) if &latest.name != snapshot => refuse(format!(
                        "{snapshot} is not {ds}'s latest snapshot ({} is): rolling back to it would destroy the snapshots after it",
                        latest.short()
                    )),
                    _ => vec![],
                }
            }
            VolumeAction::MountDataset(ds) | VolumeAction::UnmountDataset(ds) => {
                let Some(d) = dataset(ds) else { return refuse(format!("there is no dataset {ds}")) };
                if !d.mountable() {
                    return refuse(format!("{ds} has no mountpoint ({})", d.mountpoint));
                }
                if settings::is_system_mount(&d.mountpoint) {
                    return refuse(format!("{ds} is the system's own ({})", d.mountpoint));
                }
                match v {
                    VolumeAction::MountDataset(_) if d.mounted => refuse(format!("{ds} is already mounted")),
                    VolumeAction::UnmountDataset(_) if !d.mounted => refuse(format!("{ds} is not mounted")),
                    _ => vec![],
                }
            }
            VolumeAction::Unmount { path } => {
                let r = run(&strings(&["mount", "-p"]), None);
                let text = r.stdout_text();
                let mounted = text.lines().any(|line| line.split([' ', '\t']).filter(|w| !w.is_empty()).nth(1) == Some(path.as_str()));
                if mounted { vec![] } else { refuse(format!("nothing is mounted at {path}")) }
            }
        }
    }

    /// What this machine refuses that the plan alone cannot know: an
    /// interface that is not here, a pid that is now another process.
    pub fn machine_problems(&self, plan: &SettingsPlan) -> Vec<SettingsRefusal> {
        match plan {
            SettingsPlan::Energy(_) => vec![],
            SettingsPlan::PowerProfile(_) => {
                // The one plan that depends on the base: refused where
                // rc.conf has no `power_profile` at all, before anything is
                // written; upstream's rc.d/power_profile would reject `start`
                // after rc.conf had changed.
                if run(&strings(&["sysrc", "-f", &self.rc_conf, "-n", "power_profile"]), None).succeeded() {
                    vec![]
                } else {
                    refuse(settings::unavailable("power-profile", &HashMap::new()).unwrap_or_else(|| "no power profiles".into()))
                }
            }
            SettingsPlan::Network(n) => {
                if !settings::is_interface_name(&n.interface) || platform::interface_index(&n.interface).is_some() {
                    vec![] // a bad name was said already
                } else {
                    refuse(format!("there is no interface {} on this machine", n.interface))
                }
            }
            SettingsPlan::Wifi(w) => {
                let radios = radios();
                if !settings::is_radio_name(&w.device) || radios.contains(&w.device) {
                    vec![]
                } else {
                    let has = if radios.is_empty() { "none".to_owned() } else { radios.join(", ") };
                    refuse(format!("there is no wireless device {} on this machine (it has: {has})", w.device))
                }
            }
            SettingsPlan::Volume(v) => self.volume_problems(v),
            SettingsPlan::Accounts(a) => self.account_problems(a),
            SettingsPlan::Signal(s) => {
                // **The process the window showed, still.** Between the
                // person choosing it and this line its pid may have been
                // freed and given to something else; signalling that would
                // quit the wrong thing.
                let Some(now) = vents::processes::sample() else { return refuse("the process table could not be read") };
                let Some(p) = now.processes.iter().find(|p| p.pid == s.pid) else {
                    return refuse(format!("{} (pid {}) has already quit", s.name, s.pid));
                };
                if p.started != s.started || p.name != s.name {
                    return refuse(format!("pid {} is now {}, not the {} that was chosen", s.pid, p.name, s.name));
                }
                if p.system {
                    return refuse(format!("{} is part of the kernel, and is not quit", p.name));
                }
                vec![]
            }
            SettingsPlan::Sound(s) => {
                // Before sysctl.conf is written: a default the kernel then
                // refuses would leave the next boot pointing at nothing.
                if s.default_unit < 0 || std::path::Path::new(&format!("/dev/dsp{}", s.default_unit)).exists() {
                    vec![]
                } else {
                    refuse(format!("there is no sound device pcm{} on this machine", s.default_unit))
                }
            }
        }
    }

    /// Answer one connection: who, then what. Returns the line to log.
    pub fn serve(&self, client: &UnixStream, log: &mut dyn FnMut(&str)) -> String {
        if let Err(why) = self.authority.admits(client) {
            let mut deny = Msg::new();
            deny.set_bool("ok", false);
            deny.set_string("error", &format!("refused: {why}"));
            let _ = current_ipc::send(&deny, client);
            return format!("refused a caller: {why}");
        }
        let mut request = match current_ipc::receive(client) {
            Ok(r) => r,
            Err(e) => return format!("a client connected and said nothing useful: {e}"),
        };
        request.close_fds();
        match request.string("method").unwrap_or("") {
            "read" if request.string("kind") == Some("wifi") => self.read_wifi(client, &request),
            "read" => self.read(client, &request),
            "scan" => self.scan(client, &request),
            "check" => self.check(client, &request),
            "apply" => self.apply(client, &request, log),
            other => {
                let why = if other.is_empty() { "no method named in the request".to_owned() } else { format!("no such method: {other}") };
                let mut reply = Msg::new();
                reply.set_bool("ok", false);
                reply.set_string("error", &why);
                let _ = current_ipc::send(&reply, client);
                format!("unknown method '{other}'")
            }
        }
    }

    /// A radio's configuration: the wlan rc makes on it, and the networks
    /// wpa_supplicant.conf holds. Names only, never a key.
    fn read_wifi(&self, client: &UnixStream, request: &Msg) -> String {
        let device = request.string("wifi.device").unwrap_or("");
        if !settings::is_radio_name(device) {
            return refuse_to(client, &format!("{} is not a wireless device's name", if device.is_empty() { "no radio" } else { device }));
        }
        if let Some(why) = self.platform_refusal() {
            return refuse_to(client, why);
        }
        let r = run(&strings(&["sysrc", "-f", &self.rc_conf, "-n", &format!("wlans_{device}")]), None);
        let interface = if r.succeeded() { trimmed(&r.stdout_text()).to_owned() } else { String::new() };
        let known = WifiKnown {
            device: device.into(),
            interface: (!interface.is_empty()).then(|| interface.clone()),
            networks: settings::wpa::networks(&read_text(&self.wpa_conf).unwrap_or_default()),
        };
        let mut reply = Msg::new();
        reply.set_bool("ok", true);
        settings_wire::encode_known(&known, &mut reply);
        let _ = current_ipc::send(&reply, client);
        let wlan = if interface.is_empty() { "no wlan" } else { &interface };
        format!("read wifi {device}: {wlan}, {} network(s)", known.networks.len())
    }

    /// Scan from a radio, as root (`ifconfig wlanN scan` is privileged). A
    /// radio rc has not given a wlan yet gets one for the scan, removed
    /// after: a scan must not leave the machine configured differently.
    fn scan(&self, client: &UnixStream, request: &Msg) -> String {
        let device = request.string("wifi.device").unwrap_or("");
        let interface = request.string("wifi.interface").unwrap_or("wlan0");
        if !settings::is_radio_name(device) {
            return refuse_to(client, &format!("{} is not a wireless device's name", if device.is_empty() { "no radio" } else { device }));
        }
        if let Some(why) = self.platform_refusal() {
            return refuse_to(client, why);
        }
        if !radios().iter().any(|r| r == device) {
            return refuse_to(client, &format!("there is no wireless device {device} on this machine"));
        }
        let made = platform::interface_index(interface).is_none();
        if made {
            let c = run(&strings(&["ifconfig", interface, "create", "wlandev", device]), None);
            if !c.succeeded() {
                return refuse_to(client, &format!("could not make {interface} on {device}: {}", reason(&c)));
            }
            run(&strings(&["ifconfig", interface, "up"]), None);
        }
        let r = run(&strings(&["ifconfig", interface, "scan"]), None);
        if made {
            run(&strings(&["ifconfig", interface, "destroy"]), None);
        }
        if !r.succeeded() {
            return refuse_to(client, &format!("the scan failed: {}", reason(&r)));
        }
        let nets = settings::parse_scan(&r.stdout_text());
        let mut reply = Msg::new();
        reply.set_bool("ok", true);
        settings_wire::encode_scan(&nets, &mut reply);
        let _ = current_ipc::send(&reply, client);
        format!("scan {device}: {} network(s)", nets.len())
    }

    fn read(&self, client: &UnixStream, request: &Msg) -> String {
        let kind = request.string("kind").unwrap_or("");
        let iface = request.string("interface").unwrap_or("");
        let Some(keys) = settings::keys(kind, iface) else {
            let why = if kind == "network" {
                format!("{} is not a wired interface's name", if iface.is_empty() { "no interface" } else { iface })
            } else {
                format!("there is no {kind} plan")
            };
            return refuse_to(client, &why);
        };
        if let Some(why) = self.platform_refusal() {
            return refuse_to(client, why);
        }
        let mut values: HashMap<String, String> = HashMap::new();
        for (file, k) in keys {
            if !file.is_shell_variables() {
                // Not sh: read it ourselves. With no line for it, what the
                // kernel has now is what the next boot gets too.
                if let Some(v) = settings::sysctl_conf_value(&read_text(&self.path(file)).unwrap_or_default(), &k) {
                    values.insert(k, v);
                } else {
                    let r = run(&strings(&["sysctl", "-n", &k]), None);
                    if r.succeeded() {
                        values.insert(k, trimmed(&r.stdout_text()).to_owned());
                    }
                }
                continue;
            }
            // `sysrc -n` answers as rc(8) would: the defaults, then the file.
            let r = run(&strings(&["sysrc", "-f", &self.path(file), "-n", &k]), None);
            if r.succeeded() {
                values.insert(k, trimmed(&r.stdout_text()).to_owned());
            }
        }
        if let Some(why) = settings::unavailable(kind, &values) {
            return refuse_to(client, &why);
        }
        let mut sorted: Vec<(&String, &String)> = values.iter().collect();
        sorted.sort();
        let Some(plan) = settings::current(kind, iface, &values) else {
            let said: Vec<String> = sorted.iter().map(|(k, v)| format!("{k}=\"{v}\"")).collect();
            return refuse_to(client, &format!("this machine's {kind} settings are not ones this pane can show: {}", said.join(" ")));
        };
        let mut reply = Msg::new();
        reply.set_bool("ok", true);
        settings_wire::encode_plan(&plan, &mut reply);
        let _ = current_ipc::send(&reply, client);
        let said: Vec<String> = sorted.iter().map(|(k, v)| format!("{k}={v}")).collect();
        format!("read {kind}: {}", said.join(" "))
    }

    fn check(&self, client: &UnixStream, request: &Msg) -> String {
        let plan = match settings_wire::decode_plan(request) {
            Ok(p) => p,
            Err(r) => return refuse_to(client, &r.message),
        };
        let mut refusals = settings::problems(&plan);
        refusals.extend(self.machine_problems(&plan));
        let mut reply = Msg::new();
        reply.set_bool("ok", refusals.is_empty());
        reply.set_u64("problems.count", refusals.len() as u64);
        for (i, r) in refusals.iter().enumerate() {
            reply.set_string(&format!("problem.{i}"), &r.message);
        }
        if refusals.is_empty()
            && let Ok(steps) = settings::compile(&plan)
        {
            reply.set_u64("steps.count", steps.len() as u64);
            reply.set_string("render", &settings::render(&steps, &|f| self.path(f)));
        }
        let _ = current_ipc::send(&reply, client);
        format!("check {}: {}", plan.kind(), if refusals.is_empty() { "ok" } else { "refused" })
    }

    fn apply(&self, client: &UnixStream, request: &Msg, log: &mut dyn FnMut(&str)) -> String {
        let plan = match settings_wire::decode_plan(request) {
            Ok(p) => p,
            Err(r) => return refuse_to(client, &r.message),
        };
        if !self.how.dry_run
            && let Some(why) = self.platform_refusal()
        {
            return refuse_to(client, why);
        }
        if let Some(first) = self.machine_problems(&plan).into_iter().next() {
            return refuse_to(client, &first.message);
        }
        let steps = match settings::compile(&plan) {
            Ok(s) => s,
            Err(r) => return refuse_to(client, &r.message),
        };
        let mode = if self.how.dry_run {
            " (dry run)"
        } else if self.how.write_only {
            " (write only)"
        } else {
            ""
        };
        let mut record = vec![format!("apply {} for uid {}{mode}", plan.kind(), self.authority.allowed)];
        let ok = runner::apply(&steps, &|f| self.path(f), &self.how, &mut |e| {
            let _ = current_ipc::send(&settings_wire::encode_event(&e), client);
            match e {
                SettingsEvent::Starting { index, what, .. } => record.push(format!("  {}. {what}", index + 1)),
                SettingsEvent::Failed { why, ignored, .. } => {
                    record.push(format!("     {}: {why}", if ignored { "failed, and that is allowed" } else { "FAILED" }))
                }
                SettingsEvent::Skipped { why, .. } => record.push(format!("     skipped: {why}")),
                SettingsEvent::Finished { ok, error } => record.push(if ok { "  done".into() } else { format!("  NOT APPLIED: {error}") }),
                SettingsEvent::Ok { .. } => {}
            }
        });
        self.append_journal(&record);
        for line in &record {
            log(line);
        }
        format!("apply {}: {}{}", plan.kind(), if ok { "done" } else { "failed" }, if self.how.dry_run { " (dry run)" } else { "" })
    }

    fn append_journal(&self, lines: &[String]) {
        if self.journal.is_empty() {
            return;
        }
        if let Ok(mut f) = OpenOptions::new().append(true).create(true).open(&self.journal) {
            let _ = writeln!(f, "{} {}", platform::local_timestamp(), lines.join("\n"));
        }
    }
}

/// The radios the kernel has: `net.wlan.devices`.
fn radios() -> Vec<String> {
    let r = run(&strings(&["sysctl", "-n", "net.wlan.devices"]), None);
    if !r.succeeded() {
        return vec![];
    }
    trimmed(&r.stdout_text()).split(' ').filter(|w| !w.is_empty()).map(str::to_owned).collect()
}

fn refuse(message: impl Into<String>) -> Vec<SettingsRefusal> {
    vec![SettingsRefusal::new(message)]
}

/// Say no to the client, and return the line to log.
fn refuse_to(client: &UnixStream, why: &str) -> String {
    let mut reply = Msg::new();
    reply.set_bool("ok", false);
    reply.set_string("error", why);
    let _ = current_ipc::send(&reply, client);
    format!("refused: {why}")
}

fn strings(s: &[&str]) -> Vec<String> {
    s.iter().map(|&x| x.to_owned()).collect()
}

#[cfg(test)]
mod tests;
