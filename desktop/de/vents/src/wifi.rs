//! The radios, and what a wlan interface is doing, without privilege
//! (Wifi.swift, PHASE14 P14.5). `net.wlan.devices` names the radios (on
//! FreeBSD 14+ a radio is the parent a `wlanN` is made on), and `ifconfig
//! wlanN`, which any user may run, says what it is associated with: 802.11
//! association, which comes before WPA's handshake.

use crate::hardware::sysctl;

#[derive(Clone, Debug, PartialEq, Eq, Default)]
pub struct Status {
    pub interface: String,
    pub exists: bool,
    pub associated: bool,
    pub ssid: Option<String>,
    pub bssid: Option<String>,
    pub channel: Option<i64>,
}

/// The radios, in the kernel's order; empty where there are none.
pub fn radios() -> Vec<String> {
    sysctl::string("net.wlan.devices").unwrap_or_default().split(' ').filter(|r| !r.is_empty()).map(str::to_owned).collect()
}

pub fn status(interface: &str) -> Status {
    let r = spawn::run_with(&["ifconfig", interface], spawn::Options { limit: 16384, ..Default::default() });
    if !r.succeeded() {
        return Status { interface: interface.into(), ..Status::default() };
    }
    parse_ifconfig(&r.stdout_text(), interface)
}

/// `ifconfig wlanN`: its `ssid … channel … bssid …` line, and `status:`.
pub fn parse_ifconfig(text: &str, interface: &str) -> Status {
    let mut s = Status { interface: interface.into(), exists: true, ..Status::default() };
    for line in text.split('\n') {
        let w: Vec<&str> = line.split([' ', '\t']).filter(|w| !w.is_empty()).collect();
        let Some(&first) = w.first() else { continue };
        if first == "status:" {
            s.associated = w[1..].join(" ") == "associated";
        }
        if first == "ssid" && w.len() >= 2 {
            // The name may hold spaces, and ifconfig quotes it then.
            let rest = line.trim_start_matches([' ', '\t']).get(5..).unwrap_or("");
            let name = match rest.strip_prefix('"') {
                Some(q) => q.split('"').next().unwrap_or(""),
                None => rest.split(' ').next().unwrap_or(""),
            };
            s.ssid = (!name.is_empty()).then(|| name.to_owned());
            let after = |key: &str| w.iter().position(|x| *x == key).and_then(|i| w.get(i + 1));
            s.channel = after("channel").and_then(|c| c.parse().ok());
            s.bssid = after("bssid").map(|b| (*b).to_owned());
        }
    }
    s
}
