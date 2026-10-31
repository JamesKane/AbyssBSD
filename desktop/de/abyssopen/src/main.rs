//! abyssopen: the point of the portal, demonstrated (PHASE7.md P7.3),
//! ported from main.swift beside it.
//!
//! This process enters **Capsicum capability mode** and so has no
//! filesystem and no global namespace at all: it cannot `open` a path or
//! `connect` to an address. It *then* asks the desktop to let the user pick
//! a file. The portal runs the picker, opens the chosen file, and hands back
//! the descriptor over SCM_RIGHTS, and this process reads a file it could
//! not possibly have opened itself.
//!
//!     abyssopen [dir]      # pick a file (optionally suggesting a start dir)
//!     abyssopen --screenshot
//!
//! The chosen file's contents go to stdout, an already-open descriptor.
//! `--screenshot` is the same claim with a sharper control (P7.5): this
//! process cannot reach the compositor, yet ends up holding a PNG of the
//! display, from a file the portal unlinked before sending it.
//!
//! ORDER MATTERS (§6.4): capability mode forbids `connect(2)` as surely as
//! `open(2)`, so the portal connection is made **before** entering the
//! sandbox, and is then the process's only capability apart from stdio.

use abyss_sys::sandbox;
use current_ipc::Msg;
use std::fs::File;
use std::io::{Read, Write};
use std::os::unix::net::UnixStream;
use std::process::exit;

fn note(s: &str) {
    eprintln!("{s}");
}

fn die(s: impl std::fmt::Display) -> ! {
    eprintln!("abyssopen: {s}");
    exit(1)
}

/// Where the compositor is listening, resolved as libwayland does, so the
/// control tries the connection a screen capture would really need.
fn compositor_socket() -> String {
    let name = std::env::var("WAYLAND_DISPLAY").unwrap_or_else(|_| "wayland-0".into());
    if name.starts_with('/') {
        return name;
    }
    format!("{}/{name}", std::env::var("XDG_RUNTIME_DIR").unwrap_or_else(|_| "/tmp".into()))
}

fn main() {
    let first = std::env::args().nth(1);
    let (start_dir, screenshot) = match first.as_deref() {
        Some("-h" | "--help") => {
            println!("usage: abyssopen [dir] | abyssopen --screenshot");
            exit(0)
        }
        Some("--screenshot") => (None, true),
        other => (other.map(str::to_owned), false),
    };

    // ---- 1. Connect FIRST. After cap_enter there is no connect(2). ----
    let service = std::env::var("ABYSS_PORTAL_SERVICE").unwrap_or_else(|_| "portal".into());
    let sock = current_ipc::connect(&service).unwrap_or_else(|e| die(format!("cannot reach the '{service}' portal (is the desktop running?): {e}")));

    // ---- 2. Drop into capability mode. No way back. ----
    if sandbox::supported() {
        if let Err(e) = sandbox::enter() {
            die(format!("cap_enter failed: {e}"))
        }
        note("sandbox: capability mode entered — no filesystem, no namespace");
    } else {
        // Say so plainly rather than implying a confinement we don't have.
        note("sandbox: NOT AVAILABLE on this platform (Capsicum is FreeBSD-only) — running unsandboxed; the capability claim is only proven on FreeBSD");
    }

    // ---- 3. Ask. We name a directory at most; never a file, never a screen.
    let mut request = Msg::new();
    if screenshot {
        // Nothing accompanies it. There is nothing that *could*.
        request.set_string("method", "screenshot");
        note("requested: screenshot (no arguments — the request type has no room for any)");
    } else {
        request.set_string("method", "file.open");
        if let Some(d) = &start_dir {
            request.set_string("dir", d);
        }
        note(&format!("requested: dir={}", start_dir.as_deref().unwrap_or("(none)")));
    }
    if let Err(e) = current_ipc::send(&request, &sock) {
        die(format!("could not ask the portal: {e}"))
    }
    // A person chooses at their own pace.
    let _ = sock.set_read_timeout(None);
    let mut reply = current_ipc::receive(&sock).unwrap_or_else(|e| die(format!("no reply from the portal: {e}")));
    drop(sock);

    if reply.bool("ok") != Some(true) {
        let why = reply.string("error").unwrap_or("unknown").to_owned();
        note(&format!("portal: {why}"));
        exit(if why == "cancelled" { 2 } else { 1 })
    }
    let path = reply.string("path").map(str::to_owned);
    if screenshot {
        let (w, h) = (reply.u64("width").unwrap_or(0), reply.u64("height").unwrap_or(0));
        note(&format!("portal: handed us a {w}x{h} screenshot — and no path for it (path in reply: {})", path.as_deref().unwrap_or("none")));
    } else {
        note(&format!("portal: handed us {}", path.as_deref().unwrap_or("(unnamed)")));
    }
    let Some(fd) = reply.take_fd("file") else { die("the reply carried no descriptor") };

    // ---- 4. The control: prove we could NOT have got this ourselves. ----
    if screenshot {
        // Capability mode forbids naming an address, `connect(2)` to a path,
        // which is exactly what talking to a compositor requires.
        let socket = compositor_socket();
        match UnixStream::connect(&socket) {
            Ok(_) if sandbox::active() => die("connect(2) to the compositor SUCCEEDED inside capability mode — the sandbox is not real"),
            Ok(_) => note(&format!("control: connect(2) to {socket} succeeded (expected: we are not sandboxed here)")),
            Err(e) => note(&format!("control: connect(2) to {socket} failed — {} — this process cannot reach the compositor to capture anything", words(&e))),
        }
    } else {
        // Reading a file proves nothing unless the same path is
        // demonstrably unopenable from in here.
        match File::open(path.as_deref().unwrap_or("")) {
            Ok(_) if sandbox::active() => die("open(2) SUCCEEDED inside capability mode — the sandbox is not real"),
            Ok(_) => note("control: open(2) succeeded (expected: we are not sandboxed here)"),
            Err(e) => note(&format!("control: open(2) on that path failed — {} — this process cannot reach the file by name", words(&e))),
        }
    }

    // ---- 5. Read through the capability we were given. ----
    let mut file = File::from(fd);
    let (mut total, mut head) = (0usize, Vec::with_capacity(24));
    let mut buf = [0u8; 4096];
    let mut out = std::io::stdout().lock();
    loop {
        let n = match file.read(&mut buf) {
            Ok(0) | Err(_) => break,
            Ok(n) => n,
        };
        if head.len() < 24 {
            head.extend_from_slice(&buf[..n.min(24 - head.len())]);
        }
        total += n;
        let _ = out.write_all(&buf[..n]);
    }
    let _ = out.flush();
    note(&format!("read {total} bytes through the descriptor the portal handed over"));

    // The client checks the bytes ITSELF rather than trusting the portal's
    // word for what they are: an independent check is the only kind worth
    // anything, which is why this does not link the portal's parser.
    if screenshot {
        let magic = [0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A];
        if head.len() < 24 || head[..8] != magic || &head[12..16] != b"IHDR" {
            die("what we were handed is not a PNG")
        }
        let be32 = |at: usize| u32::from_be_bytes([head[at], head[at + 1], head[at + 2], head[at + 3]]);
        note(&format!("verified: a real PNG, {}x{}, read through a descriptor for a file with no name", be32(16), be32(20)));
    }
}

fn words(e: &std::io::Error) -> String {
    let s = e.to_string();
    s.rfind(" (os error ").map_or(s.clone(), |i| s[..i].to_owned())
}
