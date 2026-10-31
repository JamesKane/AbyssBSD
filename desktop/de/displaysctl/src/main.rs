//! abyss-displays: the displays, as wlr-output-management-v1 tells them,
//! and a way to rearrange them (P14.7b).
//!
//!   abyss-displays list
//!   abyss-displays test  NAME:WxH[@mHz]:X,Y[:SCALE] ...
//!   abyss-displays apply NAME:WxH[@mHz]:X,Y[:SCALE] ...
//!
//! A display not named keeps what it has. The protocol the Displays pane
//! speaks (P14.7c); any wlroots compositor answers it.

use std::process::exit;
use std::time::Duration;
use surface::display_config::{DisplayConfigurator, Outcome, Setting};

fn usage() -> ! {
    eprintln!("usage: abyss-displays list | test|apply NAME:WxH[@mHz]:X,Y[:SCALE] ...");
    exit(2)
}

fn show(c: &DisplayConfigurator) {
    for h in c.displays() {
        let cur = h.current.map_or("none".into(), |m| format!("{}x{}@{}", m.width, m.height, m.refresh_mhz));
        println!("display {} {cur} at {},{} scale {:?}{}", h.name, h.x, h.y, h.scale, if h.enabled { "" } else { " disabled" });
        for m in &h.modes {
            println!("  mode {}x{}@{}{}{}", m.width, m.height, m.refresh_mhz, if m.preferred { " preferred" } else { "" }, if Some(*m) == h.current { " current" } else { "" });
        }
    }
}

fn parse(arg: &str) -> Option<Setting> {
    let f: Vec<&str> = arg.split(':').collect();
    if f.len() != 3 && f.len() != 4 {
        return None;
    }
    let (size, rate) = f[1].split_once('@').map_or((f[1], None), |(s, r)| (s, Some(r)));
    let (w, h) = size.split_once('x')?;
    let (x, y) = f[2].split_once(',')?;
    Some(Setting {
        name: f[0].into(),
        width: w.parse().ok()?,
        height: h.parse().ok()?,
        refresh_mhz: rate.map_or(Some(0), |r| r.parse().ok())?,
        x: x.parse().ok()?,
        y: y.parse().ok()?,
        scale: f.get(3).map_or(Some(1.0), |s| s.parse().ok())?,
    })
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let verb = args.first().map(String::as_str).unwrap_or_default();
    if !["list", "test", "apply"].contains(&verb) {
        usage()
    }
    let Some(c) = DisplayConfigurator::new(Duration::from_secs(2)) else {
        eprintln!("abyss-displays: no compositor, or it does not offer wlr-output-management-v1");
        exit(1)
    };
    if verb == "list" {
        show(&c);
        return;
    }
    let displays = c.displays();
    let mut all = Vec::new();
    for a in &args[1..] {
        let Some(s) = parse(a) else {
            eprintln!("abyss-displays: '{a}' is not NAME:WxH[@mHz]:X,Y[:SCALE]");
            exit(2)
        };
        if !displays.iter().any(|h| h.name == s.name) {
            eprintln!("abyss-displays: there is no display {}", s.name);
            exit(1)
        }
        all.push(s)
    }
    // Everyone else as they are: a display left out is turned off.
    for h in &displays {
        if let (false, Some(m)) = (all.iter().any(|s| s.name == h.name), h.current) {
            all.push(Setting { name: h.name.clone(), width: m.width, height: m.height, refresh_mhz: m.refresh_mhz, x: h.x, y: h.y, scale: h.scale })
        }
    }
    match c.request(&all, verb == "test", Duration::from_secs(3)) {
        Outcome::Succeeded => {
            println!("{}", if verb == "test" { "test succeeded" } else { "applied" });
            if verb == "apply" {
                c.await_update(Duration::from_secs(2));
                show(&c)
            }
        }
        Outcome::Failed => {
            println!("{verb} failed: the compositor refused it");
            exit(1)
        }
        Outcome::Cancelled => {
            println!("{verb} cancelled: the displays changed meanwhile");
            exit(1)
        }
        Outcome::TimedOut => {
            println!("{verb}: the compositor never answered");
            exit(1)
        }
    }
}
