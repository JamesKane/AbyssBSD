//! ipcprobe, in Rust (main.swift beside it): two real processes, one
//! descriptor. Same modes, same output, so either half of a pair can be
//! either language (abyss/tests/live-ipc-mixed.sh runs all four).
//!
//!   ipcprobe serve <service>          bind, handle one request, print what
//!                                     came through the descriptor, reply
//!   ipcprobe send  <service> <text>   put <text> in a file, hand the
//!                                     descriptor to the service, print the reply
//!   ipcprobe portal-open <service> [dir]

use current_ipc::{call, Msg, Server};
use std::fs::{self, File};
use std::io::{Read, Seek, SeekFrom, Write};
use std::os::fd::{AsRawFd, OwnedFd};
use std::process::exit;

fn die(msg: impl std::fmt::Display) -> ! {
    eprintln!("ipcprobe: {msg}");
    exit(1)
}

/// Everything readable from a descriptor, from its start.
fn read_all(fd: OwnedFd) -> Vec<u8> {
    let mut f = File::from(fd);
    let _ = f.seek(SeekFrom::Start(0));
    let mut all = Vec::new();
    let _ = f.read_to_end(&mut all);
    all
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 3 {
        die("usage: ipcprobe serve <service> | send <service> <text> | portal-open <service> [dir]");
    }
    let (mode, service) = (args[1].as_str(), args[2].as_str());
    match mode {
        "serve" => {
            let server = Server::new(service).unwrap_or_else(|e| die(format!("serve failed: {e}")));
            println!("serving {}", server.path);
            let mut handler = |req: &mut Msg| {
                let mut reply = Msg::new();
                reply.set_bool("ok", true);
                if let Some(fd) = req.take_fd("buffer") {
                    let bytes = read_all(fd);
                    let text = String::from_utf8_lossy(&bytes).into_owned();
                    // The proof: this process read the sender's file through
                    // a descriptor that arrived over the socket.
                    println!("got fd, contents: {text}");
                    reply.set_string("echo", &text);
                    reply.set_u64("bytes", bytes.len() as u64);
                } else {
                    println!("got a message with no descriptor");
                    reply.set_bool("ok", false);
                }
                reply
            };
            // serve_one is true once a request was handled and answered.
            loop {
                match server.serve_one(&mut handler) {
                    Ok(true) => break,
                    Ok(false) => continue,
                    Err(e) => die(format!("serve failed: {e}")),
                }
            }
        }
        "send" => {
            let Some(text) = args.get(3) else { die("send needs <text>") };
            // A real descriptor: a temp file, unlinked at once so only the
            // descriptor keeps it alive, as a handed-over shm buffer is.
            let path = std::env::temp_dir().join(format!("ipcprobe-{}", std::process::id()));
            let mut f = File::options()
                .read(true)
                .write(true)
                .create_new(true)
                .open(&path)
                .unwrap_or_else(|e| die(format!("temp file: {e}")));
            let _ = fs::remove_file(&path);
            f.write_all(text.as_bytes()).unwrap_or_else(|e| die(format!("write: {e}")));
            let mut req = Msg::new();
            req.set_string("method", "Buffer.Hand");
            req.set_fd("buffer", f.as_raw_fd());
            req.set_u64("bytes", text.len() as u64);
            let reply = call(service, &req).unwrap_or_else(|e| die(format!("send failed: {e}")));
            drop(f);
            if reply.bool("ok") != Some(true) {
                die("service replied not-ok");
            }
            println!("reply ok, echo: {}", reply.string("echo").unwrap_or(""));
            println!("reply bytes: {}", reply.u64("bytes").unwrap_or(0));
        }
        "portal-open" => {
            // The requesting app in the portal story (PHASE7.md P7.2): a
            // suggested directory and no path, then the file it is handed.
            let mut req = Msg::new();
            req.set_string("method", "file.open");
            if let Some(dir) = args.get(3) {
                req.set_string("dir", dir);
            }
            println!("requested: dir={}", args.get(3).map_or("(none)", |s| s.as_str()));
            let mut reply = call(service, &req).unwrap_or_else(|e| die(format!("portal call failed: {e}")));
            if reply.bool("ok") != Some(true) {
                die(format!("portal refused: {}", reply.string("error").unwrap_or("unknown")));
            }
            println!("path: {}", reply.string("path").unwrap_or("?"));
            let fd = reply.take_fd("file").unwrap_or_else(|| die("no descriptor in the reply"));
            println!("contents: {}", String::from_utf8_lossy(&read_all(fd)));
        }
        _ => die(format!("unknown mode '{mode}'")),
    }
}
