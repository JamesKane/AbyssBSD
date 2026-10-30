//! ventsctl: read the machine through the FreeBSD-native bridges (Rust; the
//! Swift is main.swift beside it). One tool with subcommands, which
//! `abyss/tests/live-vents.sh` drives:
//!
//! ```text
//! ventsctl sysctl <name>        print a sysctl (string or number)
//! ventsctl kenv [name]          a kernel-environment variable, or the
//!                               machine's identity with no argument
//! ventsctl volume [percent]     read, or set, the master OSS level
//! ventsctl battery              charge, and whether it's charging
//! ventsctl devd [seconds]       stream devd events (default 5s)
//! ventsctl network [--wait s]   the network, as the kernel has it now
//! ventsctl sound [set|mute …]   devices, controls, who is playing
//! ```
//!
//! Every subcommand exits 2 when the facility is absent, so a caller can
//! tell "no battery in this machine" from "the battery is at 0%".

use std::process::exit;
use std::time::{Duration, Instant};
use vents::network::{self, Watch};
use vents::{kenv, sound, sysctl, Battery, Devd, Mixer, VolumeLevel};

fn unavailable(s: &str) -> ! {
    eprintln!("ventsctl: {s}");
    exit(2)
}

fn fail(s: &str) -> ! {
    eprintln!("ventsctl: {s}");
    exit(1)
}

/// Milliseconds left before `deadline`, for poll.
fn remaining(deadline: Instant) -> i32 {
    deadline.saturating_duration_since(Instant::now()).as_millis().min(i32::MAX as u128) as i32
}

fn seconds(arg: Option<&String>) -> f64 {
    arg.and_then(|s| s.parse::<f64>().ok()).filter(|s| s.is_finite() && *s >= 0.0).unwrap_or(5.0)
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let Some(cmd) = args.first() else {
        fail("usage: ventsctl sysctl <name> | kenv [name] | volume [pct] | battery | devd [secs] | sound [set|mute …] | network [--wait secs]")
    };
    match cmd.as_str() {
        // **kenv is not sysctl**, and the machine's own identity lives only
        // there (PHASE12 §4.2).
        "kenv" => {
            if !kenv::is_supported() {
                unavailable("no kernel environment on this platform");
            }
            if let Some(name) = args.get(1) {
                match kenv::string(name) {
                    Some(v) => println!("{v}"),
                    None => unavailable(&format!("{name} is not set")),
                }
            } else {
                match kenv::machine() {
                    Some((maker, product)) => println!("{maker}\t{product}"),
                    None => unavailable("this machine does not identify itself"),
                }
            }
        }
        "sysctl" => {
            let Some(name) = args.get(1) else { fail("sysctl needs a name") };
            if !sysctl::is_supported() {
                unavailable("no sysctl on this platform");
            }
            // Printable text first: `kern.ostype` is "FreeBSD\0", exactly 8
            // bytes, and as an integer it prints 19231843050418758.
            match sysctl::display(name) {
                Some(v) => println!("{v}"),
                None => unavailable(&format!("unknown sysctl '{name}'")),
            }
        }
        "volume" => {
            let mixer = Mixer::open(None).unwrap_or_else(|e| unavailable(&format!("no mixer ({})", words(&e))));
            if let Some(a) = args.get(1) {
                let pct = a.parse::<u8>().ok().filter(|p| *p <= 100).unwrap_or_else(|| fail("volume wants 0..100"));
                let applied = mixer.set_level(VolumeLevel::both(pct)).unwrap_or_else(|| fail("could not set the volume"));
                println!("volume {} {}", applied.left, applied.right);
            } else {
                let level = mixer.level().unwrap_or_else(|| fail("could not read the volume"));
                println!("volume {} {}", level.left, level.right);
            }
        }
        "battery" => {
            let Some(b) = Battery::read() else { unavailable("no battery") };
            let minutes = b.minutes_remaining.map_or(String::new(), |m| format!(" {m}min"));
            println!("battery {} {}{minutes}", b.label(), if b.is_charging { "charging" } else { "discharging" });
        }
        "devd" => {
            let secs = seconds(args.get(1));
            let Some(mut devd) = Devd::connect(Devd::DEFAULT_PATH) else {
                unavailable(&format!("devd isn't running (no {})", Devd::DEFAULT_PATH))
            };
            println!("watching devd for {}s", secs as i64);
            // Poll the socket the way a shell component folds it into its loop.
            let deadline = Instant::now() + Duration::from_secs_f64(secs);
            while Instant::now() < deadline {
                if abyss_sys::vents::poll_readable(devd.fd(), remaining(deadline)) {
                    for e in devd.read() {
                        println!("{}", e.summary());
                    }
                }
            }
            println!("done");
        }
        // The network, as the kernel has it now (PHASE14 P14.4): real on
        // Linux too. `--wait` blocks on the routing socket until something
        // changes, which is how the Network pane stays current.
        "network" => {
            if args.len() >= 3 && args[1] == "--wait" {
                let Some(watch) = Watch::open() else { unavailable("no routing socket") };
                let deadline = Instant::now() + Duration::from_secs_f64(seconds(args.get(2)));
                println!("watching");
                let mut changed = false;
                while !changed && Instant::now() < deadline {
                    if abyss_sys::vents::poll_readable(watch.fd(), remaining(deadline)) {
                        changed = watch.drain();
                    }
                }
                println!("{}", if changed { "changed" } else { "no change" });
            }
            show_network();
        }
        "sound" => {
            if args.len() >= 2 {
                sound_verb(&args);
            }
            let devices = sound::devices();
            let default = sound::default_unit();
            if devices.is_empty() {
                println!("no sound devices");
                exit(0);
            }
            println!("default {}", default.map_or("none".into(), |u| format!("pcm{u}")));
            for d in devices {
                fn flag(on: bool, s: &str) -> &str { if on { s } else { "" } }
                println!(
                    "device {} unit {}{}{}{}{} {}",
                    d.name,
                    d.unit,
                    flag(d.playback, " play"),
                    flag(d.recording, " rec"),
                    flag(d.from_user, " user"),
                    flag(Some(d.unit) == default, " default"),
                    d.description
                );
                for c in sound::controls(d.unit) {
                    println!("  control {} {}:{}{}{}", c.name, c.left, c.right, flag(c.muted, " muted"), flag(c.recordable, " rec"));
                }
                for c in d.playing() {
                    println!("  playing {} {} {}:{}", c.pid.unwrap_or(-1), c.command, c.left, c.right);
                }
            }
        }
        _ => fail(&format!("unknown command '{cmd}'")),
    }
}

fn show_network() {
    let st = network::status();
    for i in &st.interfaces {
        let ipv4 = if i.ipv4.is_empty() { "none".into() } else { i.ipv4.iter().map(|a| format!("{}/{}", a.address, a.prefix)).collect::<Vec<_>>().join(",") };
        println!(
            "interface {} {} link {} ipv4 {ipv4}{}{}",
            i.name,
            if i.up { "up" } else { "down" },
            i.link.as_str(),
            i.mac.as_ref().map_or(String::new(), |m| format!(" mac {m}")),
            if i.loopback { " loopback" } else { "" }
        );
    }
    println!("{}", st.router.map_or("router none".into(), |r| format!("router {} via {}", r.address, r.interface)));
    println!("dns {}", if st.name_servers.is_empty() { "none".into() } else { st.name_servers.join(" ") });
}

/// `sound set UNIT CONTROL LEVEL` or `sound mute UNIT CONTROL on|off`.
fn sound_verb(args: &[String]) {
    let usage = "usage: ventsctl sound [set UNIT CONTROL LEVEL | mute UNIT CONTROL on|off]";
    if args.len() != 5 {
        fail(usage);
    }
    let unit: i64 = args[2].parse().unwrap_or_else(|_| fail(usage));
    let why = match args[1].as_str() {
        "set" => {
            let v = args[4].parse::<i64>().ok().filter(|v| (0..=100).contains(v)).unwrap_or_else(|| fail(&format!("a level is 0..100, not {}", args[4])));
            sound::set(unit, &args[3], v, v)
        }
        "mute" => match args[4].as_str() {
            "on" | "off" => sound::set_muted(unit, &args[3], args[4] == "on"),
            other => fail(&format!("mute is on or off, not {other}")),
        },
        verb => fail(&format!("unknown sound verb '{verb}'")),
    };
    if let Some(why) = why {
        fail(&format!("pcm{unit} {}: {why}", args[3]));
    }
}

fn words(e: &std::io::Error) -> String {
    let s = e.to_string();
    s.rfind(" (os error ").map_or(s.clone(), |i| s[..i].to_owned())
}
