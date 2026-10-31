//! The installer's privileged half, as a service (Service.swift, Peer.swift,
//! Runner.swift and Probe.swift beside it).
//!
//! Three methods, and the shape of them is the argument of PHASE5 §1: the
//! caller describes what it wants, and this decides whether that may happen
//! and then makes it happen. The GUI never names a command.
//!
//!   disks    {}          → the machine: every disk, what is mounted from it,
//!                          which one holds the running root, which pools exist
//!   check    {plan…}     → the refusals, and the step list a good plan
//!                          compiles to, so a summary page can show both
//!                          without anything being written
//!   install  {plan…}     → the same compile, then run it, streaming one
//!                          message per step and a final `finished`
//!
//! `check` is not a formality. It is the same `compile` that `install` calls,
//! so a plan that passes here is a plan that will not be refused there, and
//! one that fails here never becomes a step list at all.

pub mod probe;
pub mod runner;

pub use probe::{probe_machine, ProbeError};
pub use runner::execute;

use current_ipc::Msg;
use install::DiskInventory;
use std::cell::Cell;
use std::os::fd::AsFd;
use std::os::unix::net::UnixStream;

// MARK: who may command an installer (Peer.swift)
//
// `abyss-install` runs as root and is driven by an unprivileged GUI. Socket
// permissions cannot answer who may: CurrentIPC's sockets are 0600, which a
// root-owned socket makes unreachable, and a wider mode hands the installer
// to every process on the machine. So the socket is opened to one uid and the
// service **asks the kernel who is calling**.

/// Whether a caller may command this installer.
#[derive(Clone, Copy, Debug)]
pub struct Authority {
    /// The uid the service was started for. By default the uid running it,
    /// which for a root installer means root alone: a safe default that a
    /// session sets explicitly when it starts one for a user.
    pub allowed: u32,
}

impl Authority {
    pub fn new(allowed: u32) -> Authority {
        Authority { allowed }
    }

    /// Only the uid this process runs as.
    pub fn own() -> Authority {
        Authority { allowed: abyss_sys::platform::euid() }
    }

    /// Yes, or the sentence to log when it is no.
    pub fn admits(&self, client: &UnixStream) -> Result<(), String> {
        // Never fall back to "allow": a mechanism that fails open is worse
        // than none, because it looks like one.
        let Ok(uid) = abyss_sys::platform::peer_uid(client.as_fd()) else {
            return Err("the kernel would not identify the caller".into());
        };
        if uid == self.allowed {
            Ok(())
        } else {
            Err(format!("uid {uid} may not command an installer started for uid {}", self.allowed))
        }
    }
}

// MARK: the service

pub type Machine = Box<dyn Fn() -> Result<DiskInventory, ProbeError>>;

pub struct InstallService {
    pub authority: Authority,
    /// Run everything except the commands. The events are identical, so a
    /// caller can be developed, and a live test can check the *protocol*,
    /// without a disk in the room.
    pub dry_run: bool,
    /// Where the inventory comes from: a test hands in a machine instead of
    /// asking the kernel about this one.
    pub machine: Machine,
    installs_run: Cell<u32>,
}

impl InstallService {
    pub fn new(authority: Authority, dry_run: bool) -> InstallService {
        InstallService::with_machine(authority, dry_run, Box::new(probe_machine))
    }

    pub fn with_machine(authority: Authority, dry_run: bool, machine: Machine) -> InstallService {
        InstallService { authority, dry_run, machine, installs_run: Cell::new(0) }
    }

    pub fn installs_run(&self) -> u32 {
        self.installs_run.get()
    }

    /// Serve one connection to completion. Returns what to log about it.
    ///
    /// The caller owns the socket and closes it; this never does, because the
    /// last thing an install sends is the one message that says whether it
    /// worked, and closing under it would turn "failed" into "hung up".
    pub fn serve(&self, client: &UnixStream, log: &mut dyn FnMut(&str)) -> String {
        // Before anything is read: may this caller speak at all? Here rather
        // than per method, because there is no method on an installer that an
        // unauthorised caller should get to try.
        if let Err(why) = self.authority.admits(client) {
            let mut deny = Msg::new();
            deny.set_bool("ok", false);
            deny.set_string("error", &format!("refused: {why}"));
            let _ = current_ipc::send(&deny, client);
            return format!("refused a caller: {why}");
        }
        let mut request = match current_ipc::receive(client) {
            Ok(r) => r,
            Err(e) => return format!("a client connected and said nothing useful: {e}"),
        };
        request.close_fds(); // no method here takes a descriptor
        match request.string("method").unwrap_or("") {
            "disks" => self.disks(client),
            "check" => self.check(client, &request),
            "install" => self.install(client, &request, log),
            other => {
                let mut reply = Msg::new();
                reply.set_bool("ok", false);
                let why = if other.is_empty() { "no method named in the request".to_owned() } else { format!("no such method: {other}") };
                reply.set_string("error", &why);
                let _ = current_ipc::send(&reply, client);
                format!("unknown method '{other}'")
            }
        }
    }

    fn disks(&self, client: &UnixStream) -> String {
        let mut reply = Msg::new();
        match (self.machine)() {
            Ok(inv) => {
                reply.set_bool("ok", true);
                install_wire::encode_inventory(&inv, &mut reply);
                let _ = current_ipc::send(&reply, client);
                format!("disks: {} disk(s), pools {}", inv.disks.len(), inv.imported_pools.join(","))
            }
            Err(e) => {
                reply.set_bool("ok", false);
                reply.set_string("error", &e.to_string());
                let _ = current_ipc::send(&reply, client);
                format!("disks: {e}")
            }
        }
    }

    fn check(&self, client: &UnixStream, request: &Msg) -> String {
        let plan = install_wire::decode_plan(request);
        let mut reply = Msg::new();
        let inv = match (self.machine)() {
            Ok(inv) => inv,
            Err(e) => {
                reply.set_bool("ok", false);
                reply.set_u64("problems.count", 1);
                reply.set_string("problem.0", &e.to_string());
                reply.set_string("error", &e.to_string());
                let _ = current_ipc::send(&reply, client);
                return format!("check: {e}");
            }
        };
        let refusals: Vec<String> = install::problems(&plan, &inv).iter().map(|r| r.message()).collect();
        reply.set_bool("ok", refusals.is_empty());
        reply.set_u64("problems.count", refusals.len() as u64);
        for (i, r) in refusals.iter().enumerate() {
            reply.set_string(&format!("problem.{i}"), r);
        }
        if refusals.is_empty() {
            match install::compile(&plan, &inv) {
                Ok(list) => {
                    reply.set_u64("steps.count", list.len() as u64);
                    reply.set_string("render", &install::render(&list));
                }
                // `problems` found nothing that `compile` refuses: a bug, and
                // said as a refusal rather than an empty list.
                Err(r) => {
                    reply.set_bool("ok", false);
                    reply.set_u64("problems.count", 1);
                    reply.set_string("problem.0", &r.message());
                    let _ = current_ipc::send(&reply, client);
                    return format!("check: refused — {}", r.message());
                }
            }
        }
        let _ = current_ipc::send(&reply, client);
        if refusals.is_empty() { format!("check: {} is installable", plan.disk) } else { format!("check: refused — {}", refusals.join("; ")) }
    }

    fn install(&self, client: &UnixStream, request: &Msg, log: &mut dyn FnMut(&str)) -> String {
        let plan = install_wire::decode_plan(request);
        let steps = (self.machine)().map_err(|e| e.to_string()).and_then(|inv| install::compile(&plan, &inv).map_err(|r| r.message()));
        let steps = match steps {
            Ok(s) => s,
            Err(why) => {
                // A refusal is not a failed install; it is an install that
                // never started, and the caller is told which.
                let mut reply = Msg::new();
                reply.set_string("event", "finished");
                reply.set_bool("ok", false);
                reply.set_string("error", &format!("refused: {why}"));
                let _ = current_ipc::send(&reply, client);
                return format!("install refused: {why}");
            }
        };
        self.installs_run.set(self.installs_run.get() + 1);
        let mut send_failed = false;
        let failure = execute(&steps, self.dry_run, &mut |event| {
            // A client that hangs up mid-install does not stop the install:
            // the disk is already half-rewritten, and abandoning it there is
            // strictly worse than finishing. We stop *talking*, not working.
            if send_failed {
                return;
            }
            if current_ipc::send(&install_wire::encode_event(&event), client).is_err() {
                send_failed = true;
                log("the client stopped listening; finishing anyway");
            }
        });
        if send_failed {
            return "install ran to completion with nobody listening".into();
        }
        match failure {
            None => format!("install: {} steps, ok{}", steps.len(), if self.dry_run { " (dry run)" } else { "" }),
            Some(e) => format!("install: failed — {e}"),
        }
    }
}

#[cfg(test)]
mod tests;
