//! `abyssclip`: the clipboard, from a shell (PHASE9.md P9.1), ported from
//! main.swift beside it.
//!
//!     abyssclip copy [TEXT]     put TEXT (or stdin) on the clipboard, and hold it
//!     abyssclip paste           print what is on the clipboard
//!
//! **`copy` has to stay running, and that is the protocol.** A Wayland
//! selection is a promise by the source client to write bytes when asked;
//! the owner exiting is the clipboard being emptied. So `copy` prints a
//! line before it waits: a caller needs to know the offer is live before it
//! pastes (§2.31).

use std::io::{Read, Write};
use std::process::exit;
use surface::Display;

fn die(s: &str) -> ! {
    eprintln!("abyssclip: {s}");
    exit(1)
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let verb = match args.first().map(String::as_str) {
        Some(v @ ("copy" | "paste")) => v.to_string(),
        _ => die("usage: abyssclip copy [TEXT] | abyssclip paste"),
    };
    let Some(display) = Display::connect() else {
        die("cannot connect to a Wayland compositor — is WAYLAND_DISPLAY set?")
    };
    // One roundtrip for the registry, a second for the data device's own
    // events (a selection we may already have been given).
    display.roundtrip();
    display.roundtrip();
    let Some(clip) = display.clipboard() else {
        die("this compositor offers no wl_data_device_manager, so there is no clipboard")
    };

    if verb == "copy" {
        let text = if args.len() > 1 {
            args[1..].join(" ")
        } else {
            let mut all = Vec::new();
            let _ = std::io::stdin().read_to_end(&mut all);
            String::from_utf8_lossy(&all).into_owned()
        };
        if !clip.write_text(&text) {
            die("the compositor refused the selection")
        }
        println!("abyssclip: offering {} bytes", text.len());
        let _ = std::io::stdout().flush();
        display.run();
    } else {
        let Some(s) = clip.read_text() else {
            // Empty is an answer: exit 2 so a caller can tell "nothing is
            // on the clipboard" from "this failed".
            eprintln!("abyssclip: the clipboard is empty");
            exit(2)
        };
        let mut out = std::io::stdout();
        let _ = out.write_all(s.as_bytes());
        let _ = out.flush();
    }
}
