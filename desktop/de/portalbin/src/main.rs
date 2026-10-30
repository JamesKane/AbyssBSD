//! abyss-portal: host the session's `portal` service (Rust; the Swift is
//! main.swift beside it).
//!
//! ```text
//! abyss-portal [--picker PATH] [--grabber PATH] [--once]
//!
//! file.open {dir?}         → {ok, path, mode:"r"} + fd `file`  (O_RDONLY)
//! file.save {dir?, name?}  → {ok, path, mode:"w"} + fd `file`  (O_WRONLY|CREAT)
//!   both                   → {ok:false, error:"cancelled"} if the user declined
//! notify {summary, body?, timeout?}  → relayed to the shell's toast
//! screenshot {}            → {ok, mode:"r", width, height} + fd `file`
//! ```
//!
//! The requesting app never names the file that gets opened: PortalRequest
//! has nowhere to put one.

use portal::{PortalRequest, PortalService};
use std::os::fd::AsRawFd;
use std::process::exit;

fn main() {
    let (mut picker, mut grabber, mut once) = (None, None, false);
    let mut args = std::env::args().skip(1);
    while let Some(a) = args.next() {
        match a.as_str() {
            "--picker" | "--grabber" => {
                let Some(v) = args.next() else {
                    eprintln!("abyss-portal: {a} needs a path");
                    exit(2)
                };
                if a == "--picker" { picker = Some(v) } else { grabber = Some(v) }
            }
            "--once" => once = true,
            "-h" | "--help" => {
                println!("usage: abyss-portal [--picker PATH] [--grabber PATH] [--once]");
                exit(0);
            }
            _ => {
                eprintln!("abyss-portal: unknown option '{a}'");
                exit(2)
            }
        }
    }
    // A client that hangs up mid-reply is EPIPE: Rust ignores SIGPIPE.
    let mut service = PortalService::new(picker.as_deref(), grabber.as_deref());
    let mut server = match current_ipc::Server::new("portal") {
        Ok(s) => s,
        Err(e) => {
            eprintln!("abyss-portal: cannot bind the portal service: {e}");
            exit(1)
        }
    };
    eprintln!("portal: serving {} (picker: {}, grabber: {})", server.path, service.picker_binary, service.grabber_binary);
    // One request at a time, on purpose: the picker is a modal dialog.
    let mut served = 0;
    loop {
        let Ok(client) = server.accept() else { continue };
        let Ok(mut request) = current_ipc::receive(&client) else { continue };
        request.close_fds(); // a request carries no descriptors
        let (mut reply, fd) = service.handle(&PortalRequest::parse(&request));
        if let Some(f) = &fd {
            reply.set_fd("file", f.as_raw_fd());
        }
        let _ = current_ipc::send(&reply, &client);
        // SCM_RIGHTS duplicated it into the client; ours goes now.
        drop(fd);
        served += 1;
        if once {
            break;
        }
    }
    server.shutdown_and_unlink();
    eprintln!("portal: served {served} request(s)");
}
