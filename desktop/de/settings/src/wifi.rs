//! Wifi.swift: the plan, wpa_supplicant.conf, and what a scan found
//! (PHASE14 P14.5).
//!
//! Joining a network on FreeBSD is three things rc does: `wlans_<radio>`
//! makes a `wlanN` on the radio, `ifconfig_wlanN="WPA DHCP"` has netif start
//! wpa_supplicant on it, and `/etc/wpa_supplicant.conf` holds the networks it
//! may join. The plan writes those and restarts the interface; forgetting a
//! network takes its block out and tells wpa_supplicant to read the file
//! again.
//!
//! **A network's name is written in hex** (`ssid=6162…`), which
//! wpa_supplicant reads as readily as a quoted one: an SSID is 32 arbitrary
//! bytes, and a name holding a quote or a newline could otherwise write
//! configuration of its own into a root-owned file. **Its key is the PSK,
//! never the passphrase** ([`key`](crate::key)).

use crate::key;
use crate::steps::{ConfFile, SettingsStep};
use crate::SettingsRefusal;
use std::collections::HashMap;

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum WifiAction {
    /// `psk` is 64 hex digits ([`key::psk`]), or None for an open network.
    Join { ssid: String, psk: Option<String> },
    Forget { ssid: String },
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct WifiPlan {
    /// The radio: `iwn0`, `iwlwifi0`, `wtap1`: a name in `net.wlan.devices`.
    pub device: String,
    /// The wlan interface rc makes on it.
    pub interface: String,
    pub action: WifiAction,
}

impl WifiPlan {
    /// On `wlan0`, the interface rc makes first.
    pub fn new(device: &str, action: WifiAction) -> WifiPlan {
        WifiPlan { device: device.to_owned(), interface: "wlan0".to_owned(), action }
    }

    pub fn ssid(&self) -> &str {
        match &self.action {
            WifiAction::Join { ssid, .. } | WifiAction::Forget { ssid } => ssid,
        }
    }
}

/// Letters then digits, as FreeBSD names a radio (`iwn0`, `rtwn0`, `wtap1`).
pub fn is_radio_name(s: &str) -> bool {
    let Some(d) = s.find(|c: char| c.is_ascii_digit()) else { return false };
    d != 0 && s.len() <= 15 && s[..d].bytes().all(|b| b.is_ascii_lowercase()) && s[d..].bytes().all(|b| b.is_ascii_digit())
}

pub(crate) fn problems(w: &WifiPlan) -> Vec<SettingsRefusal> {
    let mut out = Vec::new();
    if !is_radio_name(&w.device) {
        let d = if w.device.is_empty() { "no radio" } else { &w.device };
        out.push(SettingsRefusal::new(format!("{d} is not a wireless device's name")));
    }
    if !w.interface.strip_prefix("wlan").is_some_and(|n| n.parse::<i64>().is_ok()) {
        out.push(SettingsRefusal::new(format!("{} is not a wlan interface (wlan0, wlan1 …)", w.interface)));
    }
    let bytes = w.ssid().len();
    if bytes == 0 || bytes > 32 {
        out.push(SettingsRefusal::new(format!("a network's name is 1 to 32 bytes, not {bytes}")));
    }
    if let WifiAction::Join { psk: Some(psk), .. } = &w.action
        && !key::is_psk(psk)
    {
        out.push(SettingsRefusal::new("the network key is not a WPA key (64 hex digits)"));
    }
    out
}

pub(crate) fn compile(w: &WifiPlan) -> Vec<SettingsStep> {
    let key = wpa::key(w.ssid());
    match &w.action {
        // The network first, then the interface that uses it, then netif:
        // which creates wlanN on the radio and starts wpa_supplicant.
        WifiAction::Join { .. } => vec![
            SettingsStep::set_var(ConfFile::WpaSupplicant, &key, wpa::value(w).as_deref()),
            SettingsStep::rc_conf(&format!("wlans_{}", w.device), Some(&w.interface)),
            SettingsStep::rc_conf(&format!("ifconfig_{}", w.interface), Some("WPA DHCP")),
            SettingsStep::service("netif", &["restart", &w.interface], false),
        ],
        // Not running is not a failure: the file is what forgetting is.
        WifiAction::Forget { .. } => vec![
            SettingsStep::set_var(ConfFile::WpaSupplicant, &key, None),
            SettingsStep::tool(&["wpa_cli", "-i", &w.interface, "reconfigure"], true),
        ],
    }
}

/// wpa_supplicant.conf (Swift: WpaConf).
pub mod wpa {
    use super::{WifiAction, WifiPlan};
    use crate::key;

    /// The key a network's block is found by: its SSID, in hex.
    pub fn key(ssid: &str) -> String {
        format!("ssid={}", hex(ssid))
    }

    /// What the plan writes for a join: the block's body, one setting a line.
    pub(crate) fn value(w: &WifiPlan) -> Option<String> {
        let WifiAction::Join { ssid, psk } = &w.action else { return None };
        Some(format!("ssid={}\n{}", hex(ssid), psk.as_ref().map_or("key_mgmt=NONE".to_owned(), |p| format!("psk={p}"))))
    }

    pub fn hex(s: &str) -> String {
        key::hex(s.as_bytes())
    }

    /// Hex digits, two a byte, as text (leniently: an SSID is bytes). Only
    /// hex digits (Swift's `UInt8(_:radix:)` also takes a sign).
    pub fn unhex(s: &str) -> Option<String> {
        let b = s.as_bytes();
        if !b.len().is_multiple_of(2) || !b.iter().all(u8::is_ascii_hexdigit) {
            return None;
        }
        let bytes: Vec<u8> = b.chunks(2).map(|p| u8::from_str_radix(std::str::from_utf8(p).unwrap(), 16).unwrap()).collect();
        Some(String::from_utf8_lossy(&bytes).into_owned())
    }

    struct Block {
        lines: Vec<String>,
        ssid: Option<String>,
    }

    impl Block {
        fn new(lines: Vec<String>) -> Block {
            let ssid = ssid_of(&lines);
            Block { lines, ssid }
        }
    }

    fn blank_trimmed(l: &str) -> &str {
        l.trim_start_matches([' ', '\t'])
    }

    /// Split into the text outside blocks and the `network={…}` blocks.
    fn split(text: &str) -> (Vec<String>, Vec<Block>) {
        let (mut head, mut blocks) = (Vec::new(), Vec::new());
        let mut current: Option<Vec<String>> = None;
        for line in text.split('\n') {
            let t = blank_trimmed(line);
            match &mut current {
                None if t.starts_with("network={") => current = Some(vec![line.to_owned()]),
                Some(c) => {
                    c.push(line.to_owned());
                    if t.starts_with('}') {
                        blocks.push(Block::new(current.take().unwrap()));
                    }
                }
                None => head.push(line.to_owned()),
            }
        }
        if let Some(c) = current {
            blocks.push(Block::new(c)); // unterminated: kept as found
        }
        (head, blocks)
    }

    fn ssid_of(lines: &[String]) -> Option<String> {
        // A CRLF file's CR is not part of the name.
        let v = lines.iter().find_map(|l| blank_trimmed(l).strip_prefix("ssid="))?.trim_end_matches('\r');
        match v.strip_prefix('"').and_then(|q| q.strip_suffix('"')) {
            Some(quoted) if v.len() >= 2 => Some(quoted.to_owned()),
            _ => unhex(v),
        }
    }

    /// The networks the file holds, by name, in order.
    pub fn networks(text: &str) -> Vec<String> {
        split(text).1.into_iter().filter_map(|b| b.ssid).collect()
    }

    /// `text` with the network named `ssid` set to `body` (its block's
    /// lines), or removed for None. A block for the same network (written by
    /// us in hex or by hand in quotes) is replaced where it was; otherwise it
    /// is added last. A file with no control socket gets one, so `wpa_cli`
    /// can reach the supplicant.
    pub fn edit(text: &str, ssid: &str, body: Option<&str>) -> String {
        let (mut head, blocks) = split(text);
        // Replaced where the first was; any other copy of it dropped.
        let at = blocks.iter().position(|b| b.ssid.as_deref() == Some(ssid)).unwrap_or(blocks.len());
        let mut kept: Vec<Block> = blocks.into_iter().filter(|b| b.ssid.as_deref() != Some(ssid)).collect();
        if let Some(body) = body {
            let mut lines = vec!["network={".to_owned()];
            lines.extend(body.split('\n').filter(|l| !l.is_empty()).map(|l| format!("\t{l}")));
            lines.push("}".to_owned());
            let block = Block { lines, ssid: Some(ssid.to_owned()) };
            kept.insert(at.min(kept.len()), block);
        }
        while head.last().is_some_and(String::is_empty) {
            head.pop();
        }
        if !head.iter().any(|l| l.starts_with("ctrl_interface=")) {
            head.insert(0, "ctrl_interface=/var/run/wpa_supplicant".to_owned());
        }
        let mut out: Vec<String> = head;
        out.extend(kept.into_iter().flat_map(|b| b.lines));
        out.join("\n") + "\n"
    }
}

// MARK: what a scan found

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct WifiNetwork {
    pub ssid: String,
    pub bssid: String,
    pub channel: i64,
    /// The signal, as ifconfig reports it (`S` of `S:N`).
    pub signal: i64,
    /// WPA/WPA2 (an RSN or WPA element), or at least privacy.
    pub secured: bool,
}

/// `ifconfig wlanN scan` (or `list scan`). A row is found by its BSSID
/// (everything before it is the SSID, which may hold spaces), and a network
/// seen by several access points is listed once, at its strongest.
pub fn parse_scan(text: &str) -> Vec<WifiNetwork> {
    let mut best: HashMap<String, WifiNetwork> = HashMap::new();
    let mut order: Vec<String> = Vec::new();
    for line in text.split('\n').filter(|l| !l.is_empty()).skip(1) {
        let words: Vec<&str> = line.split(' ').filter(|w| !w.is_empty()).collect();
        let Some(bi) = words.iter().position(|w| is_bssid(w)) else { continue };
        if bi + 4 >= words.len() {
            continue;
        }
        // A word of the line: where it starts is where the SSID ends.
        let ssid_end = words[bi].as_ptr() as usize - line.as_ptr() as usize;
        let ssid = line[..ssid_end].trim_end_matches(' ');
        let Ok(channel) = words[bi + 1].parse::<i64>() else { continue };
        if ssid.is_empty() {
            continue;
        }
        let signal = words[bi + 3].split(':').find(|s| !s.is_empty()).and_then(|s| s.parse().ok()).unwrap_or(0);
        let rest = words[bi + 5..].join(" ");
        let caps = words.get(bi + 5).copied().unwrap_or("");
        let secured = rest.contains("RSN") || rest.contains("WPA") || caps.contains('P');
        let n = WifiNetwork { ssid: ssid.to_owned(), bssid: words[bi].to_owned(), channel, signal, secured };
        match best.get(&n.ssid) {
            Some(b) if n.signal > b.signal => {
                best.insert(n.ssid.clone(), n);
            }
            Some(_) => {}
            None => {
                order.push(n.ssid.clone());
                best.insert(n.ssid.clone(), n);
            }
        }
    }
    let mut out: Vec<WifiNetwork> = order.into_iter().filter_map(|s| best.remove(&s)).collect();
    out.sort_by_key(|n| std::cmp::Reverse(n.signal));
    out
}

/// Six pairs of hex digits between colons (Swift's split drops empty
/// fields, so `aa::bb:…` counted).
pub fn is_bssid(w: &str) -> bool {
    let p: Vec<&str> = w.split(':').collect();
    p.len() == 6 && p.iter().all(|x| x.len() == 2 && x.bytes().all(|b| b.is_ascii_hexdigit()))
}
