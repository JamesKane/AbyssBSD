//! InstallWire in Rust (RUST.md R2): the install protocol on the control
//! plane, ported from Wire.swift beside it.
//!
//! `install` knows nothing about `current-ipc` and `current-ipc` knows
//! nothing about installing; this is the seam. **And it is its own crate so
//! the GUI can speak the protocol without linking the executor**, the code
//! that forks `gpart`: "the GUI does not touch the disk" (PHASE5 §1) is true
//! of the binary, not only of the design.
//!
//! `Msg` has scalars and no arrays, so lists are indexed field names
//! (`disk.0.name`): verbose, and trivial to read in a log, which for
//! messages that describe rewriting somebody's disk is the right trade.
//! A list reads the entries the message holds, below its count
//! ([`Msg::indexed`]), where Swift counts up to whatever count it is sent.

use current_ipc::{Msg, Value};
use install::{Account, Disk, DiskInventory, InstallPlan, MachineIdentity};

/// What an install reports as it happens: the vocabulary **both ends**
/// share, so it lives here and not with the runner the GUI must not link.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum RunEvent {
    /// About to do this. `destructive` from the first step that changes the
    /// disk: a caller that wants to confirm has until this event.
    Starting { index: u64, total: u64, what: String, destructive: bool },
    Ok { index: u64 },
    /// A step failed; `ignored` when the plan allowed it to.
    Failed { index: u64, what: String, why: String, ignored: bool },
    Finished { ok: bool, error: String },
}

/// The strings among `values`, in order.
fn strings<'a>(values: impl IntoIterator<Item = &'a Value>) -> Vec<String> {
    values.into_iter().filter_map(|v| if let Value::String(s) = v { Some(s.clone()) } else { None }).collect()
}

/// A comma-joined list, empty entries dropped.
fn list(s: Option<&str>) -> Vec<String> {
    s.unwrap_or("").split(',').filter(|e| !e.is_empty()).map(str::to_owned).collect()
}

// MARK: the plan

pub fn encode_plan(p: &InstallPlan, m: &mut Msg) {
    m.set_string("disk", &p.disk);
    m.set_string("pool", &p.pool_name);
    m.set_u64("esp", p.esp_bytes);
    m.set_u64("swap", p.swap_bytes);
    m.set_string("dist", &p.dist_directory);
    m.set_string("mountpoint", &p.mountpoint);
    m.set_string("hostname", &p.hostname);
    m.set_string("timezone", &p.timezone);
    m.set_string("keymap", &p.keymap);
    m.set_string("rootpw", &p.root_password_hash);
    // **The confirmation has to cross the wire or it does nothing**: a flag
    // that stops at the socket is a guard that silently never lifts.
    m.set_u64("erase", p.erase_existing_data.into());
    m.set_u64("autologin", p.auto_login.into());
    m.set_u64("sets.count", p.sets.len() as u64);
    for (i, s) in p.sets.iter().enumerate() {
        m.set_string(&format!("set.{i}"), s);
    }
    m.set_u64("accounts.count", p.accounts.len() as u64);
    for (i, a) in p.accounts.iter().enumerate() {
        m.set_string(&format!("account.{i}.name"), &a.name);
        m.set_string(&format!("account.{i}.full"), &a.full_name);
        m.set_string(&format!("account.{i}.hash"), &a.password_hash);
        m.set_string(&format!("account.{i}.groups"), &a.groups.join(","));
        m.set_string(&format!("account.{i}.shell"), &a.shell);
    }
}

/// A plan, with the defaults for what the message does not say: an older
/// client's plan does not erase, and an account with no hash cannot log in.
pub fn decode_plan(m: &Msg) -> InstallPlan {
    let d = InstallPlan::new("");
    let s = |k: &str, default: &str| m.string(k).unwrap_or(default).to_owned();
    let sets = strings(m.indexed("set.", "", m.u64("sets.count").unwrap_or(0)).into_values());
    let accounts = m
        .indexed("account.", ".name", m.u64("accounts.count").unwrap_or(0))
        .into_iter()
        .filter_map(|(i, name)| {
            let Value::String(name) = name else { return None };
            let f = |k: &str| m.string(&format!("account.{i}.{k}"));
            Some(Account {
                name: name.clone(),
                full_name: f("full").unwrap_or("").to_owned(),
                password_hash: f("hash").unwrap_or("*").to_owned(),
                groups: list(f("groups")),
                shell: f("shell").unwrap_or("/bin/sh").to_owned(),
            })
        })
        .collect();
    InstallPlan {
        disk: s("disk", ""),
        pool_name: s("pool", &d.pool_name),
        esp_bytes: m.u64("esp").unwrap_or(d.esp_bytes),
        swap_bytes: m.u64("swap").unwrap_or(d.swap_bytes),
        sets: if sets.is_empty() { d.sets } else { sets },
        dist_directory: s("dist", &d.dist_directory),
        mountpoint: s("mountpoint", &d.mountpoint),
        hostname: s("hostname", &d.hostname),
        timezone: s("timezone", ""),
        keymap: s("keymap", ""),
        root_password_hash: s("rootpw", "*"),
        accounts,
        erase_existing_data: m.u64("erase") == Some(1),
        auto_login: m.u64("autologin") == Some(1),
    }
}

// MARK: the machine

pub fn encode_inventory(inv: &DiskInventory, m: &mut Msg) {
    m.set_u64("disks.count", inv.disks.len() as u64);
    for (i, d) in inv.disks.iter().enumerate() {
        let k = |f: &str| format!("disk.{i}.{f}");
        m.set_string(&k("name"), &d.name);
        m.set_u64(&k("bytes"), d.bytes);
        m.set_string(&k("descr"), &d.description);
        m.set_string(&k("mounted"), &d.mounted_at.join(","));
        m.set_bool(&k("root"), d.holds_running_root);
        // **Everything a refusal is made of, or the screen judges blind**:
        // without these four every disk arrived looking empty, and the
        // erase sheet could never open (§2.46).
        m.set_string(&k("pools"), &d.existing_pools.join(","));
        m.set_string(&k("kinds"), &d.partition_kinds.join(","));
        m.set_u64(&k("free"), d.free_bytes);
        m.set_bool(&k("table"), d.has_partition_table);
    }
    m.set_u64("pools.count", inv.imported_pools.len() as u64);
    for (i, p) in inv.imported_pools.iter().enumerate() {
        m.set_string(&format!("pool.{i}"), p);
    }
    if let Some(mach) = &inv.machine {
        m.set_string("machine.maker", &mach.maker);
        m.set_string("machine.product", &mach.product);
    }
}

pub fn decode_inventory(m: &Msg) -> DiskInventory {
    let disks = m
        .indexed("disk.", ".name", m.u64("disks.count").unwrap_or(0))
        .into_iter()
        .filter_map(|(i, name)| {
            let Value::String(name) = name else { return None };
            let k = |f: &str| format!("disk.{i}.{f}");
            Some(Disk {
                name: name.clone(),
                bytes: m.u64(&k("bytes")).unwrap_or(0),
                description: m.string(&k("descr")).unwrap_or("").to_owned(),
                mounted_at: list(m.string(&k("mounted"))),
                holds_running_root: m.bool(&k("root")).unwrap_or(false),
                existing_pools: list(m.string(&k("pools"))),
                partition_kinds: list(m.string(&k("kinds"))),
                free_bytes: m.u64(&k("free")).unwrap_or(0),
                has_partition_table: m.bool(&k("table")).unwrap_or(false),
            })
        })
        .collect();
    let imported_pools = strings(m.indexed("pool.", "", m.u64("pools.count").unwrap_or(0)).into_values());
    // Half an identity is none.
    let machine = match (m.string("machine.maker"), m.string("machine.product")) {
        (Some(mk), Some(pr)) if !mk.is_empty() && !pr.is_empty() => Some(MachineIdentity { maker: mk.to_owned(), product: pr.to_owned() }),
        _ => None,
    };
    DiskInventory { disks, imported_pools, machine }
}

// MARK: progress

pub fn encode_event(event: &RunEvent) -> Msg {
    let mut m = Msg::new();
    match event {
        RunEvent::Starting { index, total, what, destructive } => {
            m.set_string("event", "starting");
            m.set_u64("index", *index);
            m.set_u64("total", *total);
            m.set_string("what", what);
            m.set_bool("destructive", *destructive);
        }
        RunEvent::Ok { index } => {
            m.set_string("event", "ok");
            m.set_u64("index", *index);
        }
        RunEvent::Failed { index, what, why, ignored } => {
            m.set_string("event", "failed");
            m.set_u64("index", *index);
            m.set_string("what", what);
            m.set_string("why", why);
            m.set_bool("ignored", *ignored);
        }
        RunEvent::Finished { ok, error } => {
            m.set_string("event", "finished");
            m.set_bool("ok", *ok);
            m.set_string("error", error);
        }
    }
    m
}

/// The event a message carries, or None: the client uses exactly this to
/// tell a refusal apart from progress.
pub fn decode_event(m: &Msg) -> Option<RunEvent> {
    let index = m.u64("index").unwrap_or(0);
    let s = |k: &str| m.string(k).unwrap_or("").to_owned();
    Some(match m.string("event")? {
        "starting" => RunEvent::Starting { index, total: m.u64("total").unwrap_or(0), what: s("what"), destructive: m.bool("destructive").unwrap_or(false) },
        "ok" => RunEvent::Ok { index },
        "failed" => RunEvent::Failed { index, what: s("what"), why: s("why"), ignored: m.bool("ignored").unwrap_or(false) },
        "finished" => RunEvent::Finished { ok: m.bool("ok").unwrap_or(false), error: s("error") },
        _ => return None,
    })
}
