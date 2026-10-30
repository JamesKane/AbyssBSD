//! What the helper will do, and the two files it edits itself.

use crate::wifi::wpa;
use std::fmt;

/// A file this helper edits: with `sysrc -f` when it is shell variables.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum ConfFile {
    /// `/etc/rc.conf`: the machine's configuration.
    RcConf,
    /// `/etc/resolvconf.conf`: where name servers a person chose live, for
    /// `resolvconf -u` to put into resolv.conf beside what DHCP says.
    Resolvconf,
    /// `/etc/sysctl.conf`: kernel settings applied at boot (the default
    /// sound device). Not an sh file, so not `sysrc`'s: the helper edits it
    /// itself ([`edit_sysctl_conf`]), in the same staged copy.
    SysctlConf,
    /// `/etc/wpa_supplicant.conf`: the Wi-Fi networks this machine may join
    /// (P14.5). Not sh either; the helper edits it itself ([`wpa`]).
    WpaSupplicant,
}

impl ConfFile {
    pub const ALL: [ConfFile; 4] = [ConfFile::RcConf, ConfFile::Resolvconf, ConfFile::SysctlConf, ConfFile::WpaSupplicant];

    /// The file's name in /etc.
    pub fn name(self) -> &'static str {
        match self {
            ConfFile::RcConf => "rc.conf",
            ConfFile::Resolvconf => "resolvconf.conf",
            ConfFile::SysctlConf => "sysctl.conf",
            ConfFile::WpaSupplicant => "wpa_supplicant.conf",
        }
    }

    /// Whether `sysrc` can edit it (sh variable assignments).
    pub fn is_shell_variables(self) -> bool {
        !matches!(self, ConfFile::SysctlConf | ConfFile::WpaSupplicant)
    }

    /// The mode a new copy is made with: a file of network keys is root's
    /// alone.
    pub fn new_file_mode(self) -> u32 {
        if self == ConfFile::WpaSupplicant { 0o600 } else { 0o644 }
    }

    /// Where it is on a running machine.
    pub fn etc_path(self) -> String {
        format!("/etc/{}", self.name())
    }
}

/// One thing the helper will do.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum SettingsStep {
    /// Set a variable in one of the helper's files, or remove it (None) so
    /// the default applies. Written into a **staged copy** of that file; the
    /// real files are replaced only when every write succeeded.
    SetVar { file: ConfFile, key: String, value: Option<String> },
    /// `service NAME ACTION…`, after the files are in place. `may_fail` when
    /// the action's failure is not the plan's: stopping what is not running.
    Service { name: String, action: Vec<String>, may_fail: bool },
    /// A base tool, run after the files are in place (`resolvconf -u`).
    Tool { argv: Vec<String>, may_fail: bool },
    /// `pw -R ROOT ARGS…`, with `input` on stdin: a password hash, which
    /// must never be in argv, the journal or the pane (P16.6a). `what` is how
    /// it is described; ROOT is the helper's (`/`, or a test's scratch root).
    Pw { args: Vec<String>, input: Option<String>, what: String },
}

fn strings(s: &[&str]) -> Vec<String> {
    s.iter().map(|&x| x.to_owned()).collect()
}

impl SettingsStep {
    /// Set or remove an rc.conf variable: the common case.
    pub fn rc_conf(key: &str, value: Option<&str>) -> SettingsStep {
        SettingsStep::set_var(ConfFile::RcConf, key, value)
    }

    pub fn set_var(file: ConfFile, key: &str, value: Option<&str>) -> SettingsStep {
        SettingsStep::SetVar { file, key: key.to_owned(), value: value.map(str::to_owned) }
    }

    pub fn service(name: &str, action: &[&str], may_fail: bool) -> SettingsStep {
        SettingsStep::Service { name: name.to_owned(), action: strings(action), may_fail }
    }

    pub fn tool(argv: &[&str], may_fail: bool) -> SettingsStep {
        SettingsStep::Tool { argv: strings(argv), may_fail }
    }

    /// Whether it acts on the running machine, rather than writing a file.
    pub fn acts(&self) -> bool {
        !matches!(self, SettingsStep::SetVar { .. })
    }

    /// The exact command, `pw` working in `/`; `path(file)` is the file
    /// `sysrc` edits (the staged copy).
    pub fn command(&self, path: &dyn Fn(ConfFile) -> String) -> Vec<String> {
        self.command_in(path, "/")
    }

    /// The same, `pw` working in `pw_root` (a test's scratch root). Swift
    /// keeps that in a global; here whoever runs the step says.
    pub fn command_in(&self, path: &dyn Fn(ConfFile) -> String, pw_root: &str) -> Vec<String> {
        match self {
            // No command: the helper edits the file itself.
            SettingsStep::SetVar { file, .. } if !file.is_shell_variables() => Vec::new(),
            SettingsStep::SetVar { file, key, value: Some(v) } => vec!["sysrc".into(), "-f".into(), path(*file), format!("{key}={v}")],
            SettingsStep::SetVar { file, key, value: None } => {
                vec!["sysrc".into(), "-f".into(), path(*file), "-x".into(), key.clone()]
            }
            SettingsStep::Service { name, action, .. } => ["service".to_owned(), name.clone()].into_iter().chain(action.iter().cloned()).collect(),
            SettingsStep::Tool { argv, .. } => argv.clone(),
            SettingsStep::Pw { args, .. } => ["pw", "-R", pw_root].map(str::to_owned).into_iter().chain(args.iter().cloned()).collect(),
        }
    }

    /// The command with rc.conf at `rc_conf` and the other files in /etc.
    pub fn command_rc_conf(&self, rc_conf: &str) -> Vec<String> {
        self.command(&|f| if f == ConfFile::RcConf { rc_conf.to_owned() } else { f.etc_path() })
    }
}

/// What a person reads in the journal and the pane.
impl fmt::Display for SettingsStep {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            // **Never the key.** This line is what `check` shows, the journal
            // keeps and the pane says; a network is named, its PSK is not.
            SettingsStep::SetVar { file: ConfFile::WpaSupplicant, key, value } => {
                let name = wpa::unhex(drop5(key)).map_or_else(|| key.clone(), |n| format!("\"{n}\""));
                match value {
                    None => write!(f, "forget network {name} in wpa_supplicant.conf"),
                    Some(_) => write!(f, "add network {name} to wpa_supplicant.conf"),
                }
            }
            SettingsStep::SetVar { file, key, value: Some(v) } => write!(f, "set {key}=\"{v}\" in {}", file.name()),
            SettingsStep::SetVar { file, key, value: None } => write!(f, "remove {key} from {}", file.name()),
            SettingsStep::Service { name, action, .. } => {
                // "restart the netif service for wlan0", not "restart wlan0 the …".
                write!(f, "{} the {name} service", action.first().map_or("", String::as_str))?;
                if action.len() > 1 {
                    write!(f, " for {}", action[1..].join(" "))?;
                }
                Ok(())
            }
            SettingsStep::Tool { argv, .. } => write!(f, "run {}", argv.join(" ")),
            SettingsStep::Pw { what, .. } => f.write_str(what),
        }
    }
}

/// The list, as the commands it will run: for `check`, the journal, and a
/// person reading either.
pub fn render(steps: &[SettingsStep], path: &dyn Fn(ConfFile) -> String) -> String {
    steps
        .iter()
        .enumerate()
        .map(|(i, s)| {
            let c = s.command(path);
            let how = if c.is_empty() { "(the helper edits the file itself)".to_owned() } else { format!("$ {}", c.join(" ")) };
            format!("{}. {s}\n   {how}", i + 1)
        })
        .collect::<Vec<_>>()
        .join("\n")
}

/// `render`, every file where it is on a running machine.
pub fn render_etc(steps: &[SettingsStep]) -> String {
    render(steps, &|f| f.etc_path())
}

/// Edit a file the helper edits itself (not sh): the one place that knows
/// which editor each such file has.
pub fn edit_file(file: ConfFile, text: &str, key: &str, value: Option<&str>) -> String {
    match file {
        ConfFile::WpaSupplicant => {
            let ssid = wpa::unhex(drop5(key)).unwrap_or_else(|| key.to_owned());
            wpa::edit(text, &ssid, value)
        }
        _ => edit_sysctl_conf(text, key, value),
    }
}

/// A wpa_supplicant.conf step's key without its `ssid=`.
fn drop5(key: &str) -> &str {
    key.char_indices().nth(5).map_or("", |(i, _)| &key[i..])
}

// MARK: sysctl.conf

/// Blanks around a key or a value: spaces, tabs, and a CRLF file's CR.
const BLANK: [char; 3] = [' ', '\t', '\r'];

/// `text` with `key` set to `value` (or removed, for None): the first
/// assignment of the key is replaced in place and any later ones dropped
/// (sysctl.conf applies lines in order, so a later one would win);
/// otherwise the line is appended. Comments and everything else are kept.
/// Lines end at `\n`, a CR before it being a blank (Swift: a CRLF is one
/// Character, so its file is one line, and the rest of it is dropped).
pub fn edit_sysctl_conf(text: &str, key: &str, value: Option<&str>) -> String {
    let mut out: Vec<String> = Vec::new();
    let mut done = false;
    for line in text.split('\n') {
        if sysctl_conf_key(line) == Some(key) {
            if let (false, Some(v)) = (done, value) {
                out.push(format!("{key}={v}"));
            }
            done = true;
            continue;
        }
        out.push(line.to_owned());
    }
    if let (false, Some(v)) = (done, value) {
        if out.last().is_some_and(String::is_empty) {
            out.pop();
        }
        out.push(format!("{key}={v}"));
        out.push(String::new());
    }
    out.join("\n")
}

/// The value sysctl.conf gives `key` (the last assignment, as sysctl(8)
/// would leave it), or None.
pub fn sysctl_conf_value(text: &str, key: &str) -> Option<String> {
    let mut found = None;
    for line in text.split('\n').filter(|l| sysctl_conf_key(l) == Some(key)) {
        let v = &line[line.find('=').unwrap() + 1..];
        let v = v.split('#').next().unwrap_or("");
        found = Some(v.trim_matches(BLANK).to_owned());
    }
    found
}

fn sysctl_conf_key(line: &str) -> Option<&str> {
    let t = line.trim_start_matches(BLANK);
    if t.starts_with('#') {
        return None;
    }
    let k = t[..t.find('=')?].trim_end_matches(BLANK);
    (!k.is_empty()).then_some(k)
}
