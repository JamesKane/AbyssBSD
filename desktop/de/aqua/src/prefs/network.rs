//! The Network pane (NetworkPane.swift, P14.4c): a wired interface, by DHCP
//! or by hand, and its name servers; and Wi-Fi beside it (WifiPane.swift,
//! P14.5c), as Jaguar put AirPort beside Ethernet.
//!
//! Two sources, shown side by side and never confused: **Status** is the
//! kernel's, now, read without privilege and redrawn when the routing
//! socket says something changed; **Configure** is rc.conf's, through the
//! root helper: what the next boot does, and what Apply Now writes. What
//! the pane sends is what was typed; the helper decides what is an address,
//! and its refusals are shown in its words.
//!
//! Wi-Fi's passphrase is turned into the WPA key here and only the key is
//! sent; the passphrase is never sent, stored, logged or drawn.

use super::settings_client::{self as client, Apply};
use super::{at, log, Pane, PrefsHost};
use aquadraw::canvas::Canvas;
use aquadraw::drawlist::{DrawState, Role};
use aquadraw::runner::Rect;
use aquadraw::text::Style;
use current_ipc::Msg;
use settings::{IPv4Config, NetworkPlan, SettingsPlan, WifiAction, WifiNetwork, WifiPlan, IPv4};
use std::cell::{Cell, RefCell};
use std::os::fd::AsRawFd;
use std::rc::{Rc, Weak};
use surface::keyboard::{KeyEvent, KeyModifiers, KeySym};
use vents::network::{self as net, Interface, Status};
use vents::wifi;

// MARK: - The form

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Field {
    Address,
    Netmask,
    Router,
    Dns,
}

impl Field {
    pub const ALL: [Field; 4] = [Field::Address, Field::Netmask, Field::Router, Field::Dns];

    pub fn name(self) -> &'static str {
        match self {
            Field::Address => "address",
            Field::Netmask => "netmask",
            Field::Router => "router",
            Field::Dns => "dns",
        }
    }
    pub fn label(self) -> &'static str {
        match self {
            Field::Address => "IP Address:",
            Field::Netmask => "Subnet Mask:",
            Field::Router => "Router:",
            Field::Dns => "DNS Servers:",
        }
    }
    fn index(self) -> usize {
        self as usize
    }
}

/// What the Configure half says, as typed.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct NetworkForm {
    pub interface: String,
    pub dhcp: bool,
    pub values: [String; 4],
    pub focus: Option<Field>,
}

fn printable(s: &str) -> bool {
    s.chars().all(|c| c as u32 >= 0x20 && c as u32 != 0x7f)
}

impl NetworkForm {
    pub fn new(interface: &str) -> NetworkForm {
        NetworkForm { interface: interface.into(), dhcp: true, values: Default::default(), focus: None }
    }

    /// The form rc.conf's plan fills in.
    pub fn from_plan(plan: &NetworkPlan) -> NetworkForm {
        let mut f = NetworkForm::new(&plan.interface);
        f.values[Field::Dns.index()] = plan.dns.iter().map(IPv4::to_string).collect::<Vec<_>>().join(" ");
        if let IPv4Config::Manual { address, prefix, router } = &plan.ipv4 {
            f.dhcp = false;
            f.values[Field::Address.index()] = address.to_string();
            f.values[Field::Netmask.index()] = IPv4::mask(*prefix).to_string();
            f.values[Field::Router.index()] = router.map_or(String::new(), |r| r.to_string())
        }
        f
    }

    pub fn get(&self, f: Field) -> &str {
        &self.values[f.index()]
    }

    /// The fields that mean something in this mode: with DHCP the lease says
    /// the address, mask and router, and only the name servers are yours.
    pub fn editable(&self) -> &'static [Field] {
        if self.dhcp { &[Field::Dns] } else { &Field::ALL }
    }

    pub fn type_text(&mut self, s: &str) {
        if let Some(f) = self.focus
            && !s.is_empty()
            && printable(s)
        {
            self.values[f.index()] += s
        }
    }

    pub fn backspace(&mut self) {
        if let Some(f) = self.focus {
            self.values[f.index()].pop();
        }
    }

    /// Tab: the next editable field, round again after the last.
    pub fn move_focus(&mut self, delta: i64) {
        let e = self.editable();
        let n = e.len() as i64;
        self.focus = match self.focus.and_then(|f| e.iter().position(|x| *x == f)) {
            Some(i) => Some(e[(((i as i64 + delta) % n + n) % n) as usize]),
            None => Some(e[if delta < 0 { e.len() - 1 } else { 0 }]),
        }
    }

    pub fn set_dhcp(&mut self, on: bool) {
        self.dhcp = on;
        if self.focus.is_some_and(|f| !self.editable().contains(&f)) {
            self.focus = None
        }
    }

    /// The request, as `abyss-settingsctl` would send it for the same fields.
    pub fn request(&self, method: &str) -> Msg {
        let mut m = Msg::new();
        m.set_string("method", method);
        m.set_string("kind", "network");
        m.set_string("interface", &self.interface);
        m.set_string("network.interface", &self.interface);
        m.set_string("network.mode", if self.dhcp { "dhcp" } else { "manual" });
        if !self.dhcp {
            for f in [Field::Address, Field::Netmask, Field::Router] {
                m.set_string(&format!("network.{}", f.name()), self.get(f).trim_matches(' '))
            }
        }
        // Commas and runs of spaces are how people type lists; the wire's
        // list is spaces.
        let dns: Vec<&str> = self.get(Field::Dns).split([' ', ',']).filter(|s| !s.is_empty()).collect();
        m.set_string("network.dns", &dns.join(" "));
        m
    }

    /// One line for a log: what would be sent.
    pub fn summary(&self) -> String {
        let mode = if self.dhcp { "dhcp".into() } else { format!("manual address={} netmask={} router={}", self.get(Field::Address), self.get(Field::Netmask), self.get(Field::Router)) };
        format!("{} {mode} dns={}", self.interface, self.get(Field::Dns))
    }
}

// MARK: - What the pane says

/// The interfaces offered: an Ethernet address, not the loopback, not
/// wireless (joining is more than an address, and is Wi-Fi's). The first
/// five, which is what fits in a row.
pub fn choosable(all: &[Interface]) -> Vec<&Interface> {
    all.iter().filter(|i| !i.loopback && i.mac.is_some() && !i.name.starts_with("wl")).take(5).collect()
}

fn addresses(i: &Interface, sep: &str) -> String {
    if i.ipv4.is_empty() { "none".into() } else { i.ipv4.iter().map(|a| format!("{}/{}", a.address, a.prefix)).collect::<Vec<_>>().join(sep) }
}

/// The Status box's lines for `name`, as label and value.
pub fn status_rows(s: &Status, name: &str) -> Vec<(&'static str, String)> {
    let Some(i) = s.interfaces.iter().find(|i| i.name == name) else { return vec![("Status:", format!("{name} is not on this machine now"))] };
    let state = if !i.up {
        "Turned off"
    } else {
        match i.link {
            net::Link::Up if i.ipv4.is_empty() => "Connected, with no IPv4 address",
            net::Link::Up => "Connected",
            net::Link::Down => "Cable unplugged",
            net::Link::Unknown => "On (the link state is unknown)",
        }
    };
    let router = s.router.as_ref().filter(|r| r.interface == name).map_or(format!("none through {name}"), |r| r.address.clone());
    vec![
        ("Status:", state.into()),
        ("IPv4 Address:", addresses(i, ", ")),
        ("Router:", router),
        ("DNS Servers:", if s.name_servers.is_empty() { "none".into() } else { s.name_servers.join(" ") }),
        ("Ethernet Address:", i.mac.clone().unwrap_or_else(|| "none".into())),
    ]
}

/// The status as one line, for the log a test reads.
pub fn status_line(s: &Status, name: &str) -> String {
    let Some(i) = s.interfaces.iter().find(|i| i.name == name) else { return format!("{name} absent") };
    format!(
        "{name} {} link {} ipv4 {} router {} dns {}",
        if i.up { "up" } else { "down" },
        i.link.as_str(),
        addresses(i, ","),
        s.router.as_ref().map_or("none".into(), |r| format!("{} via {}", r.address, r.interface)),
        if s.name_servers.is_empty() { "none".into() } else { s.name_servers.join(",") }
    )
}

// MARK: - Wi-Fi's page

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct WifiPaneState {
    pub device: String,
    pub interface: String,
    pub status: wifi::Status,
    pub known: Vec<String>,
    pub scanned: Vec<WifiNetwork>,
    /// The network chosen from the list.
    pub chosen: Option<String>,
    /// What was typed: never drawn, only counted.
    pub passphrase: String,
    pub field_focused: bool,
    pub note: String,
    pub busy: bool,
}

impl WifiPaneState {
    pub fn new(device: &str) -> WifiPaneState {
        WifiPaneState { device: device.into(), interface: "wlan0".into(), status: wifi::Status { interface: "wlan0".into(), ..wifi::Status::default() }, known: vec![], scanned: vec![], chosen: None, passphrase: String::new(), field_focused: false, note: String::new(), busy: false }
    }

    pub fn chosen_network(&self) -> Option<&WifiNetwork> {
        self.scanned.iter().find(|n| Some(&n.ssid) == self.chosen.as_ref())
    }

    pub fn sample() -> WifiPaneState {
        let net = |ssid: &str, b: &str, channel, signal, secured| WifiNetwork { ssid: ssid.into(), bssid: b.into(), channel, signal, secured };
        WifiPaneState {
            status: wifi::Status { interface: "wlan0".into(), exists: true, associated: true, ssid: Some("Home".into()), bssid: Some("aa:bb:cc:dd:ee:01".into()), channel: Some(6) },
            known: vec!["Home".into(), "Café Wi-Fi".into()],
            scanned: vec![net("Home", "aa:bb:cc:dd:ee:01", 6, -41, true), net("Café Wi-Fi 5G", "aa:bb:cc:dd:ee:02", 40, -58, true), net("Library", "aa:bb:cc:dd:ee:03", 11, -72, false)],
            chosen: Some("Café Wi-Fi 5G".into()),
            passphrase: "12345678".into(),
            field_focused: true,
            ..WifiPaneState::new("iwn0")
        }
    }
}

pub fn wifi_status_words(s: &wifi::Status) -> String {
    if !s.exists {
        return "Not set up: this radio has no wlan interface yet".into();
    }
    match (&s.ssid, s.associated) {
        (Some(n), true) => format!("Associated with “{n}”{}", s.channel.map_or(String::new(), |c| format!(", channel {c}"))),
        _ => "Not associated with a network".into(),
    }
}

/// The signal in three steps, 1…3 bars. Real radios report dBm (−30 strong
/// … −90 weak), the lab's wtap a small positive S: both on one scale.
pub fn bars(signal: i64) -> usize {
    let s = if signal > 0 { -40 - (30 - signal.min(30)) } else { signal };
    if s >= -55 { 3 } else if s >= -70 { 2 } else { 1 }
}

pub fn wifi_status_line(s: &WifiPaneState) -> String {
    let assoc = if s.status.associated { format!("associated {}", s.status.ssid.as_deref().unwrap_or("?")) } else { "not-associated".into() };
    format!("{} {} {assoc} known {}", s.device, s.interface, if s.known.is_empty() { "none".into() } else { s.known.join(",") })
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct WifiLayout {
    pub body: Rect,
    pub status_baseline: f64,
    pub scan: Rect,
    /// One per scanned network, in order.
    pub networks: Vec<Rect>,
    pub field: Rect,
    pub join: Rect,
    pub known_baseline: f64,
    /// One per known network.
    pub forgets: Vec<Rect>,
    pub note_baseline: f64,
}

pub fn wifi_layout(body: Rect, top: f64, s: &WifiPaneState) -> WifiLayout {
    let (left, w) = (body.x + 40.0, body.w - 80.0);
    let mut l = WifiLayout { body, status_baseline: top + 18.0, scan: Rect::new(left + w - 100.0, top + 34.0, 100.0, 24.0), ..WifiLayout::default() };
    let mut y = top + 66.0;
    for _ in s.scanned.iter().take(6) {
        l.networks.push(Rect::new(left, y, w, 22.0));
        y += 22.0
    }
    if s.scanned.is_empty() {
        y += 22.0
    }
    y += 30.0; // the password's label sits above its field
    l.field = Rect::new(left + 16.0, y, 260.0, 24.0);
    l.join = Rect::new(left + 16.0 + 270.0, y, 90.0, 24.0);
    y += 58.0;
    l.known_baseline = y;
    y += 8.0;
    for _ in s.known.iter().take(4) {
        l.forgets.push(Rect::new(left + w - 90.0, y, 90.0, 22.0));
        y += 26.0
    }
    l.note_baseline = y + 22.0;
    l
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum WifiHit {
    Scan,
    Network(String),
    Field,
    Join,
    Forget(String),
}

pub fn wifi_hit(l: &WifiLayout, s: &WifiPaneState, x: f64, y: f64) -> Option<WifiHit> {
    if l.scan.contains(x, y) {
        return Some(WifiHit::Scan);
    }
    if let Some((_, n)) = l.networks.iter().zip(&s.scanned).find(|(r, _)| r.contains(x, y)) {
        return Some(WifiHit::Network(n.ssid.clone()));
    }
    if l.field.contains(x, y) {
        return Some(WifiHit::Field);
    }
    if l.join.contains(x, y) {
        return Some(WifiHit::Join);
    }
    l.forgets.iter().zip(&s.known).find(|(r, _)| r.contains(x, y)).map(|(_, n)| WifiHit::Forget(n.clone()))
}

pub fn paint_wifi(c: &mut Canvas, l: &WifiLayout, s: &WifiPaneState) {
    let t = c.theme.tokens.clone();
    let left = l.body.x + 40.0;
    let text = |c: &mut Canvas, s: &str, x: f64, y: f64, k, size, style| c.text_left(s, x, y, k, size, style, Role::Interface);
    text(c, &format!("Status: {}", wifi_status_words(&s.status)), left, l.status_baseline, t.body_text, 13.0, Style::Regular);
    text(c, "Networks:", left, l.scan.y + 16.0, t.body_text, 13.0, Style::Bold);
    c.gel_button(l.scan, if s.busy { "…" } else { "Scan" }, false, false);
    if s.scanned.is_empty() {
        text(c, "Scan to see the networks in range.", left + 16.0, l.scan.y + 48.0, t.secondary_text, 12.0, Style::Regular)
    }
    for (r, n) in l.networks.iter().zip(&s.scanned) {
        let on = Some(&n.ssid) == s.chosen.as_ref();
        if on {
            c.paint_simple("menu.highlight", *r, DrawState::NORMAL)
        }
        let color = if on { t.menu_text_on_highlight } else { t.body_text };
        let here = s.status.associated && s.status.ssid.as_ref() == Some(&n.ssid);
        text(c, &format!("{}{}", n.ssid, if here { "  (connected)" } else { "" }), r.x + 8.0, r.y + 15.0, color, 13.0, Style::Regular);
        // The signal as three bars, drawn: no font has to hold them.
        let nb = bars(n.signal);
        for b in 0..3 {
            let (bh, bx) = (4.0 + b as f64 * 4.0, r.x + r.w - 28.0 + b as f64 * 7.0);
            c.set_color(if b < nb { color } else { color.with_a(color.a * 0.25) });
            c.cr.rectangle(bx, r.y + 17.0 - bh, 5.0, bh);
            c.cr.fill()
        }
        if n.secured {
            let w = c.text_width("WPA", 10.0, Style::Regular, Role::Interface);
            text(c, "WPA", r.x + r.w - 36.0 - w, r.y + 15.0, if on { color } else { t.secondary_text }, 10.0, Style::Regular)
        }
    }
    let label = s.chosen_network().map_or("Choose a network.".into(), |n| if n.secured { format!("Password for “{}”:", n.ssid) } else { format!("“{}” is open.", n.ssid) });
    text(c, &label, l.field.x, l.field.y - 8.0, t.body_text, 12.0, Style::Regular);
    if s.chosen_network().is_none_or(|n| n.secured) {
        // Dots, one per character: the passphrase itself is never drawn.
        c.text_field(l.field, &"•".repeat(s.passphrase.chars().count()), s.field_focused, "")
    }
    c.gel_button(l.join, "Join", s.chosen.is_some(), false);
    text(c, "Known networks:", left, l.known_baseline, t.body_text, 13.0, Style::Bold);
    if s.known.is_empty() {
        text(c, "None yet.", left + 16.0, l.known_baseline + 22.0, t.secondary_text, 12.0, Style::Regular)
    }
    for (r, n) in l.forgets.iter().zip(&s.known) {
        text(c, n, left + 16.0, r.y + 15.0, t.body_text, 13.0, Style::Regular);
        c.gel_button(*r, "Forget", false, false)
    }
    if !s.note.is_empty() {
        text(c, &s.note, left, l.note_baseline, t.body_text, 12.0, Style::Regular)
    }
}

// MARK: - Layout and paint

#[derive(Clone, Debug, PartialEq)]
pub struct Row {
    pub value: String,
    pub hit: Rect,
    pub control: Rect,
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct NetworkLayout {
    pub interfaces: Vec<Row>,
    pub status: Rect,
    pub dhcp: (Rect, Rect),
    pub manual: (Rect, Rect),
    pub fields: [Rect; 4],
    pub label_right: f64,
    pub revert: Rect,
    pub apply: Rect,
    pub note_baseline: f64,
    pub show_baseline: f64,
    pub configure_baseline: f64,
    /// Wi-Fi's page, when a radio is chosen.
    pub wifi: WifiLayout,
}

pub fn network_layout(body: Rect, interfaces: &[String], radios: &[String], wifi: Option<&WifiPaneState>) -> NetworkLayout {
    let label_right = body.x + 170.0;
    let x = label_right + 12.0;
    let mut y = body.y + 24.0;
    let mut l = NetworkLayout { label_right, show_baseline: y + 15.0, ..NetworkLayout::default() };
    let mut ix = x;
    for name in interfaces {
        l.interfaces.push(Row { value: name.clone(), hit: Rect::new(ix, y, 100.0, 22.0), control: Rect::new(ix, y + 3.0, 16.0, 16.0) });
        ix += 104.0
    }
    // A radio beside them: "wifi:<radio>".
    for r in radios {
        l.interfaces.push(Row { value: format!("wifi:{r}"), hit: Rect::new(ix, y, 150.0, 22.0), control: Rect::new(ix, y + 3.0, 16.0, 16.0) });
        ix += 154.0
    }
    y += 36.0;
    if let Some(w) = wifi {
        l.wifi = wifi_layout(body, y, w)
    }
    l.status = Rect::new(body.x + 40.0, y, body.w - 80.0, 5.0 * 20.0 + 30.0);
    y += l.status.h + 18.0;
    l.configure_baseline = y + 15.0;
    l.dhcp = (Rect::new(x, y, 200.0, 22.0), Rect::new(x, y + 3.0, 16.0, 16.0));
    l.manual = (Rect::new(x, y + 22.0, 200.0, 22.0), Rect::new(x, y + 25.0, 16.0, 16.0));
    y += 56.0;
    for f in Field::ALL {
        l.fields[f.index()] = Rect::new(x, y, if f == Field::Dns { 300.0 } else { 180.0 }, 24.0);
        y += 32.0
    }
    y += 10.0;
    let right = body.x + body.w - 40.0;
    l.apply = Rect::new(right - 110.0, y, 110.0, 24.0);
    l.revert = Rect::new(right - 110.0 - 12.0 - 90.0, y, 90.0, 24.0);
    l.note_baseline = y + 50.0;
    l
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum NetworkHit {
    Interface(String),
    Mode { dhcp: bool },
    Field(Field),
    Revert,
    Apply,
}

pub fn network_hit(l: &NetworkLayout, form: &NetworkForm, x: f64, y: f64) -> Option<NetworkHit> {
    if let Some(r) = l.interfaces.iter().find(|r| r.hit.contains(x, y)) {
        return Some(NetworkHit::Interface(r.value.clone()));
    }
    if l.dhcp.0.contains(x, y) {
        return Some(NetworkHit::Mode { dhcp: true });
    }
    if l.manual.0.contains(x, y) {
        return Some(NetworkHit::Mode { dhcp: false });
    }
    if let Some(f) = form.editable().iter().find(|f| l.fields[f.index()].contains(x, y)) {
        return Some(NetworkHit::Field(*f));
    }
    if l.revert.contains(x, y) {
        return Some(NetworkHit::Revert);
    }
    l.apply.contains(x, y).then_some(NetworkHit::Apply)
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct NetworkPaneState {
    pub status: Status,
    pub form: Option<NetworkForm>,
    pub note: String,
    pub busy: bool,
    /// The radios (`net.wlan.devices`), offered beside the wired interfaces.
    pub radios: Vec<String>,
    /// Wi-Fi's page, when a radio is the one shown.
    pub wifi: Option<WifiPaneState>,
}

impl Default for NetworkPaneState {
    fn default() -> NetworkPaneState {
        NetworkPaneState { status: Status { interfaces: vec![], router: None, name_servers: vec![] }, form: None, note: String::new(), busy: false, radios: vec![], wifi: None }
    }
}

impl NetworkPaneState {
    pub fn interfaces(&self) -> Vec<String> {
        choosable(&self.status.interfaces).into_iter().map(|i| i.name.clone()).collect()
    }

    /// A fixed machine, for the golden picture.
    pub fn sample() -> NetworkPaneState {
        let iface = |name: &str, loopback, link, ipv4: Vec<(&str, u32)>, mac: Option<&str>| Interface { name: name.into(), up: true, loopback, link, ipv4: ipv4.into_iter().map(|(a, p)| net::Address { address: a.into(), prefix: p }).collect(), mac: mac.map(Into::into) };
        let status = Status {
            interfaces: vec![iface("lo0", true, net::Link::Unknown, vec![("127.0.0.1", 8)], None), iface("em0", false, net::Link::Up, vec![("192.168.1.20", 24)], Some("52:54:00:12:34:56")), iface("igc0", false, net::Link::Down, vec![], Some("52:54:00:ab:cd:ef"))],
            router: Some(net::Router { address: "192.168.1.1".into(), interface: "em0".into() }),
            name_servers: vec!["192.168.1.1".into()],
        };
        let mut f = NetworkForm::new("em0");
        f.dhcp = false;
        f.values = ["192.168.1.20".into(), "255.255.255.0".into(), "192.168.1.1".into(), "192.168.1.1".into()];
        f.focus = Some(Field::Address);
        NetworkPaneState { status, form: Some(f), note: "Applied.".into(), ..NetworkPaneState::default() }
    }

    /// The same machine with its radio chosen.
    pub fn sample_wifi() -> NetworkPaneState {
        NetworkPaneState { radios: vec!["iwn0".into()], wifi: Some(WifiPaneState::sample()), ..NetworkPaneState::sample() }
    }
}

pub fn paint_network(c: &mut Canvas, l: &NetworkLayout, s: &NetworkPaneState) {
    let t = c.theme.tokens.clone();
    let text = |c: &mut Canvas, s: &str, x: f64, y: f64, k, size| c.text_left(s, x, y, k, size, Style::Regular, Role::Interface);
    let heading = |c: &mut Canvas, s: &str, baseline: f64| {
        let w = c.text_width(s, 13.0, Style::Regular, Role::Interface);
        text(c, s, l.label_right - w, baseline, t.body_text, 13.0)
    };
    heading(c, "Show:", l.show_baseline);
    if s.form.is_none() && s.wifi.is_none() {
        return text(c, "This machine has no wired interface to configure.", l.label_right + 12.0, l.show_baseline, t.secondary_text, 13.0);
    }
    let shown = s.wifi.as_ref().map(|w| format!("wifi:{}", w.device)).or(s.form.as_ref().map(|f| f.interface.clone()));
    for r in &l.interfaces {
        c.radio_button(r.control.x + 8.0, r.control.y + 8.0, 7.0, Some(&r.value) == shown.as_ref());
        let label = r.value.strip_prefix("wifi:").map_or(r.value.clone(), |d| format!("Wi-Fi ({d})"));
        text(c, &label, r.control.x + 24.0, r.control.y + 12.0, t.body_text, 13.0)
    }
    if let Some(w) = &s.wifi {
        return paint_wifi(c, &l.wifi, w);
    }
    let Some(form) = &s.form else { return };
    c.group_box(l.status, "Status");
    let mut y = l.status.y + 30.0;
    for (label, value) in status_rows(&s.status, &form.interface) {
        let w = c.text_width(label, 12.0, Style::Regular, Role::Interface);
        text(c, label, l.label_right - w, y, t.secondary_text, 12.0);
        text(c, &value, l.label_right + 12.0, y, t.body_text, 12.0);
        y += 20.0
    }
    heading(c, "Configure IPv4:", l.configure_baseline);
    for (row, on, words) in [(l.dhcp, form.dhcp, "Using DHCP"), (l.manual, !form.dhcp, "Manually")] {
        c.radio_button(row.1.x + 8.0, row.1.y + 8.0, 7.0, on);
        text(c, words, row.1.x + 24.0, row.1.y + 12.0, t.body_text, 13.0)
    }
    for f in Field::ALL {
        let r = l.fields[f.index()];
        heading(c, f.label(), r.y + 16.0);
        if form.editable().contains(&f) {
            c.text_field(r, form.get(f), form.focus == Some(f), if f == Field::Dns { "from DHCP, or none" } else { "" })
        } else {
            text(c, "provided by DHCP", r.x + 4.0, r.y + 16.0, t.secondary_text, 12.0)
        }
    }
    c.gel_button(l.revert, "Revert", false, false);
    c.gel_button(l.apply, if s.busy { "Applying…" } else { "Apply Now" }, !s.busy, s.busy);
    if !s.note.is_empty() {
        text(c, &s.note, l.status.x, l.note_baseline, t.body_text, 12.0)
    }
}

// MARK: - The pane

fn nlog(s: &str) {
    log(&format!("network: {s}"))
}
fn wlog(s: &str) {
    log(&format!("wifi: {s}"))
}

pub struct NetworkPane {
    me: Weak<NetworkPane>,
    state: RefCell<NetworkPaneState>,
    layout: RefCell<Option<NetworkLayout>>,
    /// The kernel says when an address, a link or a route changes, so a
    /// lease or a cable shows at once.
    watch: RefCell<Option<Rc<net::Watch>>>,
    showing: Cell<bool>,
    applying: RefCell<Option<Rc<Apply>>>,
    wifi_applying: RefCell<Option<Rc<Apply>>>,
    dumped: RefCell<Option<NetworkLayout>>,
    dumped_wifi: RefCell<Option<WifiLayout>>,
}

impl NetworkPane {
    pub fn new(state: NetworkPaneState) -> Rc<NetworkPane> {
        Rc::new_cyclic(|me| NetworkPane { me: me.clone(), state: RefCell::new(state), layout: RefCell::new(None), watch: RefCell::new(None), showing: Cell::new(false), applying: RefCell::new(None), wifi_applying: RefCell::new(None), dumped: RefCell::new(None), dumped_wifi: RefCell::new(None) })
    }

    /// Status from the kernel, the form from rc.conf through the helper.
    /// With no interface named, the one showing, else the first there is.
    fn load(&self, h: &Rc<PrefsHost>, interface: Option<&str>) {
        let name = {
            let mut s = self.state.borrow_mut();
            s.status = net::status();
            s.radios = wifi::radios();
            let names = s.interfaces();
            interface.map(String::from).or_else(|| s.form.as_ref().map(|f| f.interface.clone()).filter(|i| names.contains(i))).or(names.first().cloned())
        };
        let Some(name) = name else {
            self.state.borrow_mut().form = None;
            nlog("no wired interface");
            return h.redraw();
        };
        nlog(&format!("status {}", status_line(&self.state.borrow().status, &name)));
        let read = client::read("network", Some(&name));
        let mut s = self.state.borrow_mut();
        match read {
            Ok(SettingsPlan::Network(plan)) => {
                let f = NetworkForm::from_plan(&plan);
                nlog(&format!("read {}", f.summary()));
                s.form = Some(f);
                s.note.clear()
            }
            other => {
                // Nothing from rc.conf: the form starts at DHCP, and the page
                // says why in the helper's words.
                let why = match other {
                    Err(e) => e.message,
                    _ => "the helper answered with another kind of plan".into(),
                };
                s.form = Some(NetworkForm::new(&name));
                s.note = format!("The settings helper says: {why}");
                nlog(&format!("cannot read {name}: {why}"))
            }
        }
        drop(s);
        h.redraw()
    }

    fn changed(&self, h: &Rc<PrefsHost>) {
        let drained = self.watch.borrow().as_ref().is_some_and(|w| w.drain());
        if !drained || !self.showing.get() {
            return;
        }
        let mut s = self.state.borrow_mut();
        s.status = net::status();
        if let Some(f) = &s.form {
            nlog(&format!("changed {}", status_line(&s.status, &f.interface)))
        }
        // An association is a routing-socket event too (RTM_IEEE80211_*).
        if let Some(w) = s.wifi.as_mut() {
            let st = wifi::status(&w.interface);
            if st != w.status {
                w.status = st;
                wlog(&format!("status {}", wifi_status_line(w)))
            }
        }
        drop(s);
        h.redraw()
    }

    fn apply_network(&self, h: &Rc<PrefsHost>) {
        if self.applying.borrow().is_some() {
            return;
        }
        let Some(form) = self.state.borrow().form.clone() else { return };
        nlog(&format!("apply {}", form.summary()));
        let a = h.display.as_ref().and_then(|d| {
            let (me, step, host) = (self.me.clone(), self.me.clone(), h.clone());
            Apply::begin(
                d,
                &form.request("apply"),
                move |line| {
                    nlog(line);
                    // "[i/n] what" is also what the page says, as a step.
                    if let (Some(p), Some((count, what))) = (step.upgrade(), line.strip_prefix('[').and_then(|r| r.split_once("] ")))
                        && let Some((i, n)) = count.split_once('/')
                    {
                        p.state.borrow_mut().note = format!("Step {i} of {n}: {what}")
                    }
                },
                move |ok, said| {
                    let Some(p) = me.upgrade() else { return };
                    *p.applying.borrow_mut() = None;
                    p.state.borrow_mut().busy = false;
                    nlog(&format!("{} — {said}", if ok { "applied" } else { "not applied" }));
                    let name = p.state.borrow().form.as_ref().map(|f| f.interface.clone());
                    if ok && let Some(name) = name {
                        p.load(&host, Some(&name))
                    }
                    p.state.borrow_mut().note = said;
                    host.redraw()
                },
            )
        });
        let mut s = self.state.borrow_mut();
        match a {
            Some(a) => {
                *self.applying.borrow_mut() = Some(a);
                s.busy = true;
                s.note = "Applying…".into()
            }
            None => {
                s.note = "Not applied: the settings helper is not running on this machine".into();
                nlog(&s.note)
            }
        }
        drop(s);
        h.redraw()
    }

    fn press_network(&self, h: &Rc<PrefsHost>, hit: NetworkHit) {
        if self.state.borrow().form.is_none() {
            return;
        }
        match hit {
            NetworkHit::Interface(name) if name.starts_with("wifi:") => {
                let device = &name[5..];
                if self.state.borrow().wifi.as_ref().is_some_and(|w| w.device == device) {
                    return;
                }
                self.state.borrow_mut().wifi = Some(WifiPaneState::new(device));
                self.load_wifi(h)
            }
            NetworkHit::Interface(name) => {
                {
                    let s = self.state.borrow();
                    if s.form.as_ref().is_some_and(|f| f.interface == name) && s.wifi.is_none() {
                        return;
                    }
                }
                self.state.borrow_mut().wifi = None;
                self.load(h, Some(&name))
            }
            NetworkHit::Mode { dhcp } => {
                if let Some(f) = self.state.borrow_mut().form.as_mut() {
                    f.set_dhcp(dhcp)
                }
                nlog(&format!("mode {}", if dhcp { "dhcp" } else { "manual" }))
            }
            NetworkHit::Field(f) => {
                if let Some(form) = self.state.borrow_mut().form.as_mut() {
                    form.focus = Some(f)
                }
                nlog(&format!("focus {}", f.name()))
            }
            NetworkHit::Revert => {
                nlog("revert");
                let name = self.state.borrow().form.as_ref().map(|f| f.interface.clone());
                self.load(h, name.as_deref())
            }
            NetworkHit::Apply => self.apply_network(h),
        }
        h.redraw()
    }

    // Wi-Fi

    fn load_wifi(&self, h: &Rc<PrefsHost>) {
        let Some(device) = self.state.borrow().wifi.as_ref().map(|w| w.device.clone()) else { return };
        let read = client::read_wifi(&device);
        let mut s = self.state.borrow_mut();
        let Some(w) = s.wifi.as_mut() else { return };
        match read {
            Ok(k) => {
                w.interface = k.interface.unwrap_or_else(|| "wlan0".into());
                w.known = k.networks;
                w.note.clear()
            }
            Err(why) => {
                w.note = format!("The settings helper says: {}", why.message);
                wlog(&format!("cannot read: {}", why.message))
            }
        }
        w.status = wifi::status(&w.interface);
        wlog(&format!("status {}", wifi_status_line(w)));
        drop(s);
        h.redraw()
    }

    fn press_wifi(&self, h: &Rc<PrefsHost>, hit: WifiHit) {
        let Some(mut w) = self.state.borrow().wifi.clone() else { return };
        match hit {
            WifiHit::Scan => {
                wlog(&format!("scan {}", w.device));
                match client::scan_wifi(&w.device, &w.interface) {
                    Ok(nets) => {
                        w.note = if nets.is_empty() { "No networks in range.".into() } else { String::new() };
                        wlog(&format!("scanned {}", if nets.is_empty() { "none".into() } else { nets.iter().enumerate().map(|(i, n)| format!("{i}={}", n.ssid)).collect::<Vec<_>>().join(";") }));
                        w.scanned = nets
                    }
                    Err(why) => {
                        w.note = format!("Could not scan: {}", why.message);
                        wlog(&w.note)
                    }
                }
            }
            WifiHit::Network(ssid) => {
                w.chosen = Some(ssid.clone());
                w.passphrase.clear();
                w.field_focused = w.chosen_network().is_some_and(|n| n.secured);
                wlog(&format!("chose {ssid}"))
            }
            WifiHit::Field => w.field_focused = true,
            WifiHit::Join => {
                self.state.borrow_mut().wifi = Some(w);
                return self.join_wifi(h);
            }
            WifiHit::Forget(ssid) => {
                self.state.borrow_mut().wifi = Some(w);
                return self.apply_wifi(h, WifiAction::Forget { ssid: ssid.clone() }, &format!("forget {ssid}"));
            }
        }
        self.state.borrow_mut().wifi = Some(w);
        h.redraw()
    }

    fn wifi_key(&self, h: &Rc<PrefsHost>, e: &KeyEvent) {
        let Some(mut w) = self.state.borrow().wifi.clone().filter(|w| w.field_focused) else { return };
        match e.keysym {
            KeySym::BACKSPACE => {
                w.passphrase.pop();
            }
            KeySym::ENTER => return self.join_wifi(h),
            _ => {
                if e.modifiers.contains(KeyModifiers::COMMAND) || e.modifiers.contains(KeyModifiers::CONTROL) || !printable(&e.text) {
                    return;
                }
                w.passphrase += &e.text
            }
        }
        // How many characters, never which.
        wlog(&format!("password {} characters", w.passphrase.chars().count()));
        self.state.borrow_mut().wifi = Some(w);
        h.redraw()
    }

    fn join_wifi(&self, h: &Rc<PrefsHost>) {
        let Some(mut w) = self.state.borrow().wifi.clone() else { return };
        let Some(n) = w.chosen_network().cloned() else { return };
        let mut psk = None;
        if n.secured {
            // The key, here: the passphrase goes no further than this process.
            let Some(k) = settings::key::psk(&w.passphrase, &n.ssid) else {
                w.note = "A WPA password is 8 to 63 characters.".into();
                wlog(&w.note);
                self.state.borrow_mut().wifi = Some(w);
                return h.redraw();
            };
            psk = Some(k)
        }
        w.passphrase.clear(); // not kept once it is a key
        self.state.borrow_mut().wifi = Some(w);
        let what = format!("join {}{}", n.ssid, if n.secured { " (secured)" } else { " (open)" });
        self.apply_wifi(h, WifiAction::Join { ssid: n.ssid, psk }, &what)
    }

    fn apply_wifi(&self, h: &Rc<PrefsHost>, action: WifiAction, what: &str) {
        if self.wifi_applying.borrow().is_some() {
            return;
        }
        let Some(w) = self.state.borrow().wifi.clone() else { return };
        wlog(&format!("apply {what}"));
        let req = client::apply_request(&SettingsPlan::Wifi(WifiPlan { device: w.device.clone(), interface: w.interface.clone(), action }));
        let a = h.display.as_ref().and_then(|d| {
            let (me, host) = (self.me.clone(), h.clone());
            Apply::begin(d, &req, wlog, move |ok, said| {
                let Some(p) = me.upgrade() else { return };
                *p.wifi_applying.borrow_mut() = None;
                if let Some(w) = p.state.borrow_mut().wifi.as_mut() {
                    w.busy = false
                }
                wlog(&format!("{} — {said}", if ok { "applied" } else { "not applied" }));
                p.load_wifi(&host);
                if let Some(w) = p.state.borrow_mut().wifi.as_mut() {
                    w.note = if ok && said == "Applied." { "Applied. Joining takes a moment.".into() } else { said }
                }
                host.redraw()
            })
        });
        let mut s = self.state.borrow_mut();
        let Some(w) = s.wifi.as_mut() else { return };
        match a {
            Some(a) => {
                *self.wifi_applying.borrow_mut() = Some(a);
                w.busy = true
            }
            None => {
                w.note = "Not changed: the settings helper is not running on this machine".into();
                wlog(&w.note)
            }
        }
        drop(s);
        h.redraw()
    }
}

impl Pane for NetworkPane {
    fn id(&self) -> &'static str {
        "network"
    }
    fn shown(&self, h: &Rc<PrefsHost>) {
        self.showing.set(true);
        if self.watch.borrow().is_none()
            && let (Some(d), Some(w)) = (&h.display, net::Watch::open())
        {
            let w = Rc::new(w);
            let (me, host) = (self.me.clone(), h.clone());
            d.add_fd(w.fd().as_raw_fd(), move || {
                if let Some(p) = me.upgrade() {
                    p.changed(&host)
                }
            });
            *self.watch.borrow_mut() = Some(w)
        }
        self.load(h, None)
    }
    fn hidden(&self, _h: &Rc<PrefsHost>) {
        self.showing.set(false)
    }
    fn paint(&self, c: &mut Canvas, body: Rect) {
        let s = self.state.borrow().clone();
        let l = network_layout(body, &s.interfaces(), &s.radios, s.wifi.as_ref());
        paint_network(c, &l, &s);
        *self.layout.borrow_mut() = Some(l)
    }
    /// `iface.<name>`, `mode.dhcp`/`mode.manual`, `field.<name>`, `revert`,
    /// `apply`; and Wi-Fi's `scan`, `net.<i>` (named in the `wifi: scanned`
    /// line), `field`, `join`, `forget.<i>`.
    fn dump(&self) -> Vec<String> {
        let Some(l) = self.layout.borrow().clone() else { return vec![] };
        let mut out = vec![];
        if self.dumped.borrow().as_ref() != Some(&l) {
            let mut line = "network layout".to_string();
            for r in &l.interfaces {
                line += &format!(" iface.{}={}", r.value, at(&r.hit))
            }
            line += &format!(" mode.dhcp={} mode.manual={}", at(&l.dhcp.0), at(&l.manual.0));
            for f in Field::ALL {
                line += &format!(" field.{}={}", f.name(), at(&l.fields[f.index()]))
            }
            line += &format!(" revert={} apply={}", at(&l.revert), at(&l.apply));
            out.push(line);
            *self.dumped.borrow_mut() = Some(l.clone())
        }
        if self.state.borrow().wifi.is_some() && self.dumped_wifi.borrow().as_ref() != Some(&l.wifi) {
            let w = &l.wifi;
            let mut line = format!("wifi layout scan={} field={} join={}", at(&w.scan), at(&w.field), at(&w.join));
            for (i, r) in w.networks.iter().enumerate() {
                line += &format!(" net.{i}={}", at(r))
            }
            for (i, r) in w.forgets.iter().enumerate() {
                line += &format!(" forget.{i}={}", at(r))
            }
            out.push(line);
            *self.dumped_wifi.borrow_mut() = Some(l.wifi.clone())
        }
        out
    }
    fn press(&self, h: &Rc<PrefsHost>, x: f64, y: f64) -> bool {
        let Some(l) = self.layout.borrow().clone() else { return false };
        let wifi = self.state.borrow().wifi.clone();
        if let Some(w) = wifi {
            // Wi-Fi's page: the "Show:" row still switches, the rest is Wi-Fi's.
            if let Some(r) = l.interfaces.iter().find(|r| r.hit.contains(x, y)) {
                self.press_network(h, NetworkHit::Interface(r.value.clone()))
            } else if let Some(hit) = wifi_hit(&l.wifi, &w, x, y) {
                self.press_wifi(h, hit)
            } else if w.field_focused {
                if let Some(w) = self.state.borrow_mut().wifi.as_mut() {
                    w.field_focused = false
                }
                h.redraw()
            }
            return true;
        }
        let form = self.state.borrow().form.clone().unwrap_or_else(|| NetworkForm::new(""));
        let Some(hit) = network_hit(&l, &form, x, y) else { return false };
        self.press_network(h, hit);
        true
    }
    fn key(&self, h: &Rc<PrefsHost>, e: &KeyEvent) {
        if self.state.borrow().wifi.is_some() {
            return self.wifi_key(h, e);
        }
        if self.state.borrow().form.is_none() {
            return;
        }
        let shift = e.modifiers.contains(KeyModifiers::SHIFT);
        {
            let mut s = self.state.borrow_mut();
            let Some(f) = s.form.as_mut() else { return };
            match e.keysym {
                KeySym::TAB if shift => f.move_focus(-1),
                KeySym::BACK_TAB => f.move_focus(-1),
                KeySym::TAB => f.move_focus(1),
                KeySym::BACKSPACE => f.backspace(),
                KeySym::ENTER => {
                    drop(s);
                    return self.apply_network(h);
                }
                _ => {
                    if e.modifiers.contains(KeyModifiers::COMMAND) || e.modifiers.contains(KeyModifiers::CONTROL) {
                        return;
                    }
                    f.type_text(&e.text)
                }
            }
        }
        h.redraw()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_plan_fills_the_form_and_the_form_sends_it_back() {
        let ip = |s| IPv4::parse(s).unwrap();
        let plan = NetworkPlan { interface: "em0".into(), ipv4: IPv4Config::Manual { address: ip("192.168.1.20"), prefix: 24, router: Some(ip("192.168.1.1")) }, dns: vec![ip("9.9.9.9"), ip("1.1.1.1")] };
        let f = NetworkForm::from_plan(&plan);
        assert!(!f.dhcp);
        assert_eq!(f.get(Field::Netmask), "255.255.255.0");
        assert_eq!(f.get(Field::Dns), "9.9.9.9 1.1.1.1");
        assert_eq!(settings_wire::decode_plan(&f.request("apply")), Ok(SettingsPlan::Network(plan)));
    }

    #[test]
    fn dhcp_sends_no_address_and_typing_edits_only_the_focused_field() {
        let mut f = NetworkForm::new("vtnet0");
        f.values[Field::Address.index()] = "10.0.0.5".into();
        f.values[Field::Dns.index()] = " 9.9.9.9,1.1.1.1  ".into();
        let m = f.request("check");
        assert_eq!(m.string("network.address"), None);
        assert_eq!(m.string("network.dns"), Some("9.9.9.9 1.1.1.1"));
        let mut f = NetworkForm::new("em0");
        f.type_text("1");
        assert_eq!(f.values, <[String; 4]>::default(), "no field has focus");
        f.set_dhcp(false);
        f.focus = Some(Field::Router);
        f.type_text("10.0.0.1");
        f.type_text("\u{8}");
        assert_eq!(f.get(Field::Router), "10.0.0.1", "control characters are not text");
        f.set_dhcp(true);
        assert_eq!(f.focus, None);
    }

    #[test]
    fn tab_walks_the_editable_fields_round_again() {
        let mut f = NetworkForm::new("em0");
        f.move_focus(1);
        assert_eq!(f.focus, Some(Field::Dns));
        f.set_dhcp(false);
        f.focus = None;
        let seen: Vec<Field> = (0..5).map(|_| { f.move_focus(1); f.focus.unwrap() }).collect();
        assert_eq!(seen, [Field::Address, Field::Netmask, Field::Router, Field::Dns, Field::Address]);
        f.move_focus(-1);
        assert_eq!(f.focus, Some(Field::Dns));
    }

    #[test]
    fn the_status_is_said_in_words() {
        let s = NetworkPaneState::sample();
        assert_eq!(s.interfaces(), ["em0", "igc0"]);
        let em = status_rows(&s.status, "em0");
        assert_eq!(em[0].1, "Connected");
        assert_eq!(em[1].1, "192.168.1.20/24");
        assert_eq!(status_rows(&s.status, "igc0")[2].1, "none through igc0");
        assert_eq!(status_line(&s.status, "em0"), "em0 up link up ipv4 192.168.1.20/24 router 192.168.1.1 via em0 dns 192.168.1.1");
    }

    #[test]
    fn wifi_in_words_and_where_it_is_hit() {
        let s = WifiPaneState::sample();
        assert_eq!(wifi_status_words(&s.status), "Associated with “Home”, channel 6");
        assert_eq!((bars(-41), bars(-58), bars(-72), bars(30), bars(5)), (3, 2, 1, 3, 2));
        assert_eq!(wifi_status_line(&s), "iwn0 wlan0 associated Home known Home,Café Wi-Fi");
        let l = wifi_layout(Rect::new(0.0, 80.0, 760.0, 540.0), 140.0, &s);
        let r = l.networks[2];
        assert_eq!(wifi_hit(&l, &s, r.x + 5.0, r.y + 5.0), Some(WifiHit::Network("Library".into())));
        let f = l.forgets[1];
        assert_eq!(wifi_hit(&l, &s, f.x + 5.0, f.y + 5.0), Some(WifiHit::Forget("Café Wi-Fi".into())));
    }

    // NetworkPaneTests and WifiPaneTests, the parts the tests above leave out.

    #[test]
    fn the_form_says_what_it_sends() {
        let ip = |s| IPv4::parse(s).unwrap();
        let plan = NetworkPlan { interface: "em0".into(), ipv4: IPv4Config::Manual { address: ip("192.168.1.20"), prefix: 24, router: Some(ip("192.168.1.1")) }, dns: vec![ip("9.9.9.9"), ip("1.1.1.1")] };
        let r = NetworkForm::from_plan(&plan).request("apply");
        assert_eq!((r.string("method"), r.string("interface")), (Some("apply"), Some("em0")));
        let mut f = NetworkForm::new("vtnet0");
        f.values[Field::Address.index()] = "10.0.0.5".into();
        let m = f.request("check");
        assert_eq!(m.string("network.mode"), Some("dhcp"));
        assert!(matches!(settings_wire::decode_plan(&m), Ok(SettingsPlan::Network(NetworkPlan { ipv4: IPv4Config::Dhcp, .. }))));
    }

    #[test]
    fn what_was_typed_is_sent_as_typed_for_the_helper_to_refuse() {
        let mut f = NetworkForm::new("em0");
        f.set_dhcp(false);
        f.focus = Some(Field::Address);
        f.type_text("10.0.0.300");
        match settings_wire::decode_plan(&f.request("apply")) {
            Err(why) => assert!(why.message.contains("10.0.0.300"), "{}", why.message),
            Ok(p) => panic!("an impossible address was accepted: {p:?}"),
        }
    }

    #[test]
    fn typing_edits_the_focused_field_only() {
        let mut f = NetworkForm::new("em0");
        f.set_dhcp(false);
        f.focus = Some(Field::Router);
        f.type_text("10.0.0.1");
        f.type_text("\t");
        assert_eq!(f.get(Field::Router), "10.0.0.1", "control characters are not text");
        f.backspace();
        assert_eq!(f.get(Field::Router), "10.0.0.");
    }

    #[test]
    fn the_status_is_said_in_words_wireless_and_missing_too() {
        let s = NetworkPaneState::sample();
        let names = |v: Vec<&Interface>| v.iter().map(|i| i.name.clone()).collect::<Vec<_>>();
        assert_eq!(names(choosable(&s.status.interfaces)), ["em0", "igc0"], "no loopback");
        let wifi = Interface { name: "wlan0".into(), up: true, loopback: false, link: net::Link::Up, ipv4: vec![], mac: Some("02:00:00:00:00:01".into()) };
        let pseudo = Interface { name: "pflog0".into(), up: true, loopback: false, link: net::Link::Unknown, ipv4: vec![], mac: None };
        let all: Vec<Interface> = [wifi, pseudo].into_iter().chain(s.status.interfaces.clone()).collect();
        assert_eq!(names(choosable(&all)), ["em0", "igc0"], "wireless is its own pane, and an interface with no hardware is nobody's");
        let em = status_rows(&s.status, "em0");
        assert_eq!(em.iter().find(|r| r.0 == "Router:").unwrap().1, "192.168.1.1");
        assert_eq!(status_rows(&s.status, "igc0")[0].1, "Cable unplugged");
        assert_eq!(status_rows(&s.status, "em9")[0].1, "em9 is not on this machine now");
    }

    #[test]
    fn one_layout_for_paint_and_hit() {
        let body = Rect::new(0.0, 80.0, 760.0, 540.0);
        let l = network_layout(body, &["em0".into(), "igc0".into()], &[], None);
        let mut f = NetworkForm::new("em0");
        let mid = |r: &Rect| (r.x + r.w / 2.0, r.y + r.h / 2.0);
        let at = |f: &NetworkForm, r: &Rect| {
            let (x, y) = mid(r);
            network_hit(&l, f, x, y)
        };
        assert_eq!(at(&f, &l.interfaces[1].hit), Some(NetworkHit::Interface("igc0".into())));
        assert_eq!(at(&f, &l.manual.0), Some(NetworkHit::Mode { dhcp: false }));
        assert_eq!(at(&f, &l.dhcp.0), Some(NetworkHit::Mode { dhcp: true }));
        assert_eq!(at(&f, &l.fields[Field::Address.index()]), None, "with DHCP the address is not a field");
        assert_eq!(at(&f, &l.fields[Field::Dns.index()]), Some(NetworkHit::Field(Field::Dns)));
        f.set_dhcp(false);
        assert_eq!(at(&f, &l.fields[Field::Address.index()]), Some(NetworkHit::Field(Field::Address)));
        assert_eq!(at(&f, &l.apply), Some(NetworkHit::Apply));
        assert_eq!(at(&f, &l.revert), Some(NetworkHit::Revert));
        assert!(l.apply.y + l.apply.h < body.y + body.h, "Apply Now is inside the window");
        let rects: Vec<Rect> = l.interfaces.iter().map(|r| r.hit).chain([l.status, l.dhcp.0, l.manual.0, l.revert, l.apply]).chain(l.fields).collect();
        for (i, a) in rects.iter().enumerate() {
            for b in &rects[i + 1..] {
                assert!(!(a.x < b.x + b.w && b.x < a.x + a.w && a.y < b.y + b.h && b.y < a.y + a.h), "{a:?} overlaps {b:?}");
            }
        }
    }

    #[test]
    fn wifi_the_page_in_words_and_where_it_is_hit() {
        assert_eq!(wifi_status_words(&wifi::Status { interface: "wlan0".into(), exists: false, ..wifi::Status::default() }), "Not set up: this radio has no wlan interface yet");
        assert_eq!((bars(-41), bars(-65), bars(-85), bars(10)), (3, 2, 1, 2), "wtap's S of 10 reads as -60 dBm: fair, not full");
        let s = WifiPaneState::sample();
        let l = wifi_layout(Rect::new(0.0, 80.0, 760.0, 540.0), 140.0, &s);
        let at = |r: &Rect| wifi_hit(&l, &s, r.x + r.w / 2.0, r.y + r.h / 2.0);
        assert_eq!(at(&l.scan), Some(WifiHit::Scan));
        assert_eq!(at(&l.networks[2]), Some(WifiHit::Network("Library".into())));
        assert_eq!(at(&l.field), Some(WifiHit::Field));
        assert_eq!(at(&l.join), Some(WifiHit::Join));
        assert_eq!(at(&l.forgets[1]), Some(WifiHit::Forget("Café Wi-Fi".into())));
        assert!(l.note_baseline < 620.0);
    }
}
