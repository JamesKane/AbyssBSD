//! abyss-settingsctl: the command-line face of the settings helper (P14.3),
//! ported from main.swift beside it.
//!
//!   abyss-settingsctl read  energy
//!   abyss-settingsctl check energy --powerd on|off [--ac MODE] [--battery MODE]
//!   abyss-settingsctl apply energy --powerd on|off [--ac MODE] [--battery MODE]
//!   abyss-settingsctl read  power-profile
//!   abyss-settingsctl check|apply power-profile --profile power-saver|balanced|performance
//!   abyss-settingsctl read  network --interface IF
//!   abyss-settingsctl check network --interface IF (--dhcp |
//!                     --address A --netmask M [--router R]) [--dns "A B"]
//!   abyss-settingsctl apply network …
//!   abyss-settingsctl read  sound
//!   abyss-settingsctl check|apply sound --default pcmN
//!   abyss-settingsctl read  wifi --device RADIO
//!   abyss-settingsctl scan  wifi --device RADIO [--interface wlanN]
//!   abyss-settingsctl check|apply wifi --device RADIO [--interface wlanN]
//!                     (--join SSID (--passphrase P | --open) | --forget SSID)
//!   abyss-settingsctl check|apply accounts --add NAME [--full-name F] [--admin]
//!                     (the password on stdin, hashed here: none crosses the socket)
//!   abyss-settingsctl check|apply accounts --delete NAME [--remove-home]
//!   abyss-settingsctl check|apply accounts --autologin NAME | --no-autologin
//!
//! It links `settings-wire` and not `settings-run`, as the pane does: a
//! client speaks the protocol and carries none of the code that runs
//! `sysrc`. It exists so every plan is testable without a GUI (PHASE14
//! P14.3), and so a machine whose display is broken can still be told to
//! change something.

use current_ipc::Msg;
use settings::{IPv4Config, PowerdMode, SettingsPlan};
use settings_wire::SettingsEvent;
use std::collections::HashMap;
use std::os::unix::net::UnixStream;
use std::process::exit;

fn usage() -> ! {
    let modes: Vec<&str> = PowerdMode::ALL.iter().map(|m| m.as_str()).collect();
    println!(
        "usage: abyss-settingsctl <read|check|apply|scan> <energy|network|sound|wifi> [options]
  --powerd on|off      energy: whether powerd runs
  --ac MODE            its policy on AC: {}
  --battery MODE       its policy on battery
  --interface IF       network: the wired interface (em0, igc0, vtnet0)
  --dhcp               network: its address by DHCP
  --address A --netmask M [--router R]
                       network: a manual IPv4 address
  --dns \"A B\"          network: name servers
  --default pcmN       sound: the device /dev/dsp means
  --device RADIO       wifi: the radio (iwn0, wtap1)
  --join SSID          wifi: a network to join, with --passphrase P or --open
  --forget SSID        wifi: a network to forget
  --service NAME       the service to talk to (default settings)",
        modes.join(", ")
    );
    exit(2)
}

fn die(why: impl std::fmt::Display) -> ! {
    eprintln!("abyss-settingsctl: {why}");
    exit(2)
}

const VALUED: [&str; 27] = [
    "powerd", "ac", "battery", "profile", "interface", "address", "netmask", "router", "dns", "default", "device", "join", "forget",
    "passphrase", "pid", "started", "name", "dataset", "snapshot", "rollback", "mount", "unmount", "unmount-path", "add", "full-name",
    "delete", "autologin",
];

/// The plan's fields, as typed: the helper decides what is an address, a
/// profile or a device, not this.
fn plan_fields(kind: &str, f: &HashMap<String, String>, request: &mut Msg) {
    let get = |k: &str| f.get(k).map(String::as_str);
    match kind {
        "energy" => {
            let on = match get("powerd") {
                Some("on") => true,
                Some("off") => false,
                _ => die("--powerd on|off is required"),
            };
            request.set_bool("energy.powerd", on);
            if let Some(a) = get("ac") {
                request.set_string("energy.ac", a);
            }
            if let Some(b) = get("battery") {
                request.set_string("energy.battery", b);
            }
        }
        "power-profile" => request.set_string("power-profile", get("profile").unwrap_or("")),
        "network" => {
            request.set_string("network.interface", get("interface").unwrap_or(""));
            let mode = get("mode").unwrap_or(if f.contains_key("address") { "manual" } else { "" });
            request.set_string("network.mode", mode);
            for k in ["address", "netmask", "router", "dns"] {
                if let Some(v) = get(k) {
                    request.set_string(&format!("network.{k}"), v);
                }
            }
        }
        "wifi" => {
            if let Some(ssid) = get("join") {
                request.set_string("wifi.action", "join");
                request.set_string("wifi.ssid", ssid);
                if let Some(pass) = get("passphrase") {
                    // The key, derived here: the passphrase goes no further.
                    let Some(psk) = settings::key::psk(pass, ssid) else { die("a WPA passphrase is 8 to 63 characters") };
                    request.set_string("wifi.psk", &psk);
                } else if !f.contains_key("open") {
                    die("--join needs --passphrase P, or --open for an open network");
                }
            } else if let Some(ssid) = get("forget") {
                request.set_string("wifi.action", "forget");
                request.set_string("wifi.ssid", ssid);
            } else {
                die("wifi needs --join SSID or --forget SSID");
            }
        }
        "sound" => {
            let Some(d) = get("default") else { die("--default pcmN is required") };
            request.set_string("sound.default", d);
        }
        // Disk Utility (P15.8).
        "volume" => {
            let mut set = |pairs: &[(&str, &str)]| pairs.iter().for_each(|(k, v)| request.set_string(k, v));
            if let (Some(d), Some(n)) = (get("dataset"), get("snapshot")) {
                set(&[("volume.action", "snapshot"), ("volume.dataset", d), ("volume.name", n)]);
            } else if let Some(s) = get("rollback") {
                set(&[("volume.action", "rollback"), ("volume.snapshot", s)]);
            } else if let Some(d) = get("mount") {
                set(&[("volume.action", "mount"), ("volume.dataset", d)]);
            } else if let Some(d) = get("unmount") {
                set(&[("volume.action", "unmount"), ("volume.dataset", d)]);
            } else if let Some(p) = get("unmount-path") {
                set(&[("volume.action", "unmount"), ("volume.path", p)]);
            } else {
                die("volume needs --dataset D --snapshot NAME, --rollback D@S, --mount D, --unmount D or --unmount-path P");
            }
        }
        // The Accounts pane (PHASE16 P16.6a).
        "accounts" => {
            if let Some(name) = get("add") {
                let mut pw = String::new();
                let _ = std::io::stdin().read_line(&mut pw);
                let pw = pw.strip_suffix('\n').unwrap_or(&pw);
                let hash = (!pw.is_empty()).then(|| abyss_sys::platform::crypt_sha512(pw)).flatten();
                let Some(hash) = hash else { die("--add needs a password on stdin") };
                request.set_string("accounts.action", "add");
                request.set_string("accounts.name", name);
                request.set_string("accounts.fullname", get("full-name").unwrap_or(""));
                request.set_string("accounts.hash", &hash);
                request.set_bool("accounts.admin", f.contains_key("admin"));
            } else if let Some(name) = get("delete") {
                request.set_string("accounts.action", "delete");
                request.set_string("accounts.name", name);
                request.set_bool("accounts.removehome", f.contains_key("remove-home"));
            } else if let Some(name) = get("autologin") {
                request.set_string("accounts.action", "autologin");
                request.set_string("accounts.name", name);
            } else if f.contains_key("no-autologin") {
                request.set_string("accounts.action", "autologin");
            } else {
                die("accounts needs --add NAME, --delete NAME, --autologin NAME or --no-autologin");
            }
        }
        // Quit another user's process (P15.7): which one, as the caller saw it.
        "signal" => {
            let (Some(pid), Some(started), Some(name)) = (get("pid"), get("started"), get("name")) else {
                die("signal needs --pid N --started SECONDS --name NAME [--force]")
            };
            request.set_string("signal.pid", pid);
            request.set_string("signal.started", started);
            request.set_string("signal.name", name);
            request.set_bool("signal.force", f.contains_key("force"));
        }
        _ => die(format!("there is no {kind} plan")),
    }
}

fn receive(sock: &UnixStream) -> Msg {
    current_ipc::receive(sock).unwrap_or_else(|e| {
        eprintln!("abyss-settingsctl: the helper hung up: {e}");
        exit(1)
    })
}

/// The reply, when it says yes; otherwise its words, and out.
fn accepted(r: Msg) -> Msg {
    if r.bool("ok") != Some(true) {
        eprintln!("abyss-settingsctl: {}", r.string("error").unwrap_or("refused"));
        exit(1)
    }
    r
}

fn main() {
    let mut args: Vec<String> = std::env::args().skip(1).collect();
    if args.len() < 2 || !["read", "check", "apply", "scan"].contains(&args[0].as_str()) {
        usage()
    }
    let rest = args.split_off(2);
    let (verb, kind) = (args[0].as_str(), args[1].as_str());
    let mut service_name = "settings".to_owned();
    let mut fields: HashMap<String, String> = HashMap::new();
    let mut i = 0;
    while i < rest.len() {
        let flag = rest[i].as_str();
        match flag {
            "--dhcp" => {
                fields.insert("mode".into(), "dhcp".into());
            }
            // Flags with no value (P16.6a).
            "--open" | "--force" | "--admin" | "--remove-home" | "--no-autologin" => {
                fields.insert(flag[2..].into(), "1".into());
            }
            _ => {
                let Some(value) = rest.get(i + 1) else { die(format!("{flag} needs a value")) };
                match flag.strip_prefix("--") {
                    Some("service") => service_name = value.clone(),
                    Some(f) if VALUED.contains(&f) => {
                        fields.insert(f.into(), value.clone());
                    }
                    _ => die(format!("unknown option '{flag}'")),
                }
                i += 1;
            }
        }
        i += 1;
    }

    let mut request = Msg::new();
    request.set_string("method", verb);
    request.set_string("kind", kind);
    if let Some(iface) = fields.get("interface") {
        request.set_string("interface", iface);
    }
    if kind == "wifi" {
        request.set_string("wifi.device", fields.get("device").map_or("", String::as_str));
        request.set_string("wifi.interface", fields.get("interface").map_or("wlan0", String::as_str));
    }
    if verb != "read" && verb != "scan" {
        plan_fields(kind, &fields, &mut request);
    }

    let sock = current_ipc::connect(&service_name).unwrap_or_else(|e| {
        eprintln!("abyss-settingsctl: cannot reach the settings helper ({service_name}): {e}");
        exit(1)
    });
    if let Err(e) = current_ipc::send(&request, &sock) {
        eprintln!("abyss-settingsctl: could not send: {e}");
        exit(1)
    }

    match verb {
        "read" if kind == "wifi" => {
            let k = settings_wire::decode_known(&accepted(receive(&sock)));
            let nets: Vec<String> = k.networks.iter().map(|n| format!("\"{n}\"")).collect();
            let nets = if nets.is_empty() { "none".to_owned() } else { nets.join(" ") };
            println!("wifi {}: {}, networks: {nets}", k.device, k.interface.as_deref().unwrap_or("no wlan"));
        }
        "scan" => {
            let nets = settings_wire::decode_scan(&accepted(receive(&sock)));
            if nets.is_empty() {
                println!("no networks");
            }
            for n in nets {
                println!("network \"{}\" signal {} channel {} {}", n.ssid, n.signal, n.channel, if n.secured { "secured" } else { "open" });
            }
        }
        "read" => match settings_wire::decode_plan(&accepted(receive(&sock))) {
            Ok(SettingsPlan::Energy(e)) => {
                println!("energy: powerd {}, ac {}, battery {}", if e.powerd { "on" } else { "off" }, e.on_ac.as_str(), e.on_battery.as_str())
            }
            Ok(SettingsPlan::Network(n)) => {
                let dns: Vec<String> = n.dns.iter().map(|d| d.to_string()).collect();
                let dns = if dns.is_empty() { String::new() } else { format!(", dns {}", dns.join(" ")) };
                match n.ipv4 {
                    IPv4Config::Dhcp => println!("network {}: dhcp{dns}", n.interface),
                    IPv4Config::Manual { address, prefix, router } => {
                        let via = router.map(|r| format!(" via {r}")).unwrap_or_default();
                        println!("network {}: {address}/{prefix}{via}{dns}", n.interface)
                    }
                }
            }
            Ok(SettingsPlan::Sound(s)) => println!("sound: default pcm{}", s.default_unit),
            Ok(SettingsPlan::PowerProfile(p)) => println!("power profile: {}", p.as_str()),
            Ok(SettingsPlan::Signal(_)) => println!("signal: nothing to read"),
            Ok(SettingsPlan::Volume(_)) => println!("volume: nothing to read"),
            Ok(SettingsPlan::Accounts(_)) => println!("accounts: nothing to read"),
            Ok(SettingsPlan::Wifi(_)) => {
                eprintln!("abyss-settingsctl: read wifi is answered separately");
                exit(1)
            }
            Err(why) => {
                eprintln!("abyss-settingsctl: {}", why.message);
                exit(1)
            }
        },
        "check" => {
            let r = receive(&sock);
            if let Some(e) = r.string("error") {
                eprintln!("abyss-settingsctl: {e}");
                exit(1)
            }
            for p in 0..r.u64("problems.count").unwrap_or(0) {
                println!("refused: {}", r.string(&format!("problem.{p}")).unwrap_or(""));
            }
            if let Some(render) = r.string("render") {
                println!("{render}");
            }
            exit(if r.bool("ok") == Some(true) { 0 } else { 1 })
        }
        _ => loop {
            let m = receive(&sock);
            if let Some(e) = m.string("error")
                && m.string("event").is_none()
            {
                eprintln!("abyss-settingsctl: {e}");
                exit(1)
            }
            match settings_wire::decode_event(&m) {
                Some(SettingsEvent::Starting { index, total, what }) => println!("[{}/{total}] {what}", index + 1),
                Some(SettingsEvent::Skipped { why, .. }) => println!("    (skipped) {why}"),
                Some(SettingsEvent::Failed { why, ignored, .. }) => {
                    println!("{}{why}", if ignored { "    (allowed to fail) " } else { "    FAILED: " })
                }
                Some(SettingsEvent::Finished { ok, error }) => {
                    println!("{}", if ok { "done".to_owned() } else { format!("not applied: {error}") });
                    exit(if ok { 0 } else { 1 })
                }
                Some(SettingsEvent::Ok { .. }) | None => {}
            }
        },
    }
}
