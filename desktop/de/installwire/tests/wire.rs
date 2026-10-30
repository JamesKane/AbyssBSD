//! The protocol half of InstallRunTests.swift, ported, and what Swift could
//! not survive: a count far past what a message holds, and an index past
//! `Int.max`. (The machine those tests parse out of `geom` is installrun's,
//! R3; here it is built by hand.)

use current_ipc::Msg;
use install::{Account, Disk, DiskInventory, InstallPlan, MachineIdentity};
use install_wire::{decode_event, decode_inventory, decode_plan, encode_event, encode_inventory, encode_plan, RunEvent};

fn wire_plan(p: &InstallPlan) -> InstallPlan {
    let mut m = Msg::new();
    encode_plan(p, &mut m);
    decode_plan(&Msg::unpack(&m.pack(), vec![]).unwrap())
}

fn wire_inventory(inv: &DiskInventory) -> DiskInventory {
    let mut m = Msg::new();
    encode_inventory(inv, &mut m);
    decode_inventory(&Msg::unpack(&m.pack(), vec![]).unwrap())
}

#[test]
fn the_erase_confirmation_survives_the_wire() {
    // **A guard that stops at the socket is one that silently never lifts.**
    for erase in [true, false] {
        assert_eq!(wire_plan(&InstallPlan { erase_existing_data: erase, ..InstallPlan::new("ada0") }).erase_existing_data, erase);
    }
}

#[test]
fn a_plan_from_an_older_client_defaults_to_not_erasing() {
    let mut m = Msg::new();
    m.set_string("disk", "ada0");
    let p = decode_plan(&m);
    assert!(!p.erase_existing_data);
    assert_eq!(p, InstallPlan::new("ada0"), "every default");
}

#[test]
fn a_plan_survives_the_wire() {
    let p = InstallPlan {
        pool_name: "tank".into(),
        esp_bytes: 300 << 20,
        swap_bytes: 0,
        sets: vec!["base.txz".into()],
        dist_directory: "/d".into(),
        hostname: "h".into(),
        timezone: "UTC".into(),
        keymap: "us.kbd".into(),
        root_password_hash: "$6$r".into(),
        accounts: vec![Account { full_name: "A Person".into(), groups: vec!["wheel".into(), "operator".into()], ..Account::new("a", "$6$a") }],
        auto_login: true,
        ..InstallPlan::new("ada0")
    };
    assert_eq!(wire_plan(&p), p);
}

#[test]
fn every_fact_a_refusal_is_made_of_survives_the_wire() {
    // **The GUI judges disks against whatever crossed this socket.**
    let inv = DiskInventory {
        disks: vec![
            Disk {
                description: "Samsung 990 PRO".into(),
                mounted_at: vec!["/data".into()],
                existing_pools: vec!["zroot".into(), "tank".into()],
                partition_kinds: vec!["efi".into(), "freebsd-swap".into(), "freebsd-zfs".into()],
                free_bytes: 728_576,
                has_partition_table: true,
                ..Disk::new("nda1", 931 << 30)
            },
            Disk { holds_running_root: true, mounted_at: vec!["/".into(), "/home".into()], ..Disk::new("vtbd0", 80 << 30) },
        ],
        imported_pools: vec!["zroot".into()],
        machine: Some(MachineIdentity { maker: "Micro-Star".into(), product: "MS-7D25".into() }),
    };
    assert_eq!(wire_inventory(&inv), inv);
}

#[test]
fn a_disk_with_nothing_on_it_survives_the_wire_as_empty_not_as_missing() {
    let back = wire_inventory(&DiskInventory::new(vec![Disk::new("ada0", 1 << 30)]));
    let d = back.disk("ada0").unwrap();
    assert!(d.partition_kinds.is_empty() && !d.has_partition_table);
    assert_eq!(back.machine, None);
}

#[test]
fn half_an_identity_does_not_cross() {
    let mut m = Msg::new();
    m.set_string("machine.maker", "Apple Inc.");
    m.set_string("machine.product", "");
    assert_eq!(decode_inventory(&m).machine, None);
}

#[test]
fn every_progress_event_survives_the_wire() {
    let events = [
        RunEvent::Starting { index: 3, total: 41, what: "create the GPT".into(), destructive: true },
        RunEvent::Ok { index: 3 },
        RunEvent::Failed { index: 4, what: "add swap".into(), why: "Device busy".into(), ignored: true },
        RunEvent::Finished { ok: false, error: "it did not work".into() },
    ];
    for e in events {
        assert_eq!(decode_event(&encode_event(&e)), Some(e));
    }
    // Something that is not an event is not one: the client tells a refusal
    // apart from progress by exactly this.
    let mut not_an_event = Msg::new();
    not_an_event.set_bool("ok", false);
    assert_eq!(decode_event(&not_an_event), None);
    let mut big = Msg::new();
    big.set_string("event", "ok");
    big.set_u64("index", u64::MAX);
    assert_eq!(decode_event(&big), Some(RunEvent::Ok { index: u64::MAX }), "Swift traps here");
}

/// A count far past what the message holds reads what it holds, at once.
#[test]
fn a_list_reads_only_what_the_message_holds() {
    let mut m = Msg::new();
    m.set_u64("sets.count", u64::MAX);
    m.set_string("set.0", "base.txz");
    m.set_string("set.01", "leading zero");
    m.set_string("set.5", "sparse.txz");
    m.set_u64("accounts.count", u64::MAX);
    m.set_string("account.9.name", "ada");
    m.set_u64("disks.count", u64::MAX);
    m.set_string("disk.3.name", "ada0");
    m.set_u64("pools.count", 1);
    m.set_string("pool.0", "zroot");
    m.set_string("pool.1", "past the count");
    let p = decode_plan(&m);
    assert_eq!(p.sets, ["base.txz", "sparse.txz"]);
    assert_eq!(p.accounts, [Account { password_hash: "*".into(), ..Account::new("ada", "*") }]);
    let inv = decode_inventory(&m);
    assert_eq!(inv.disks.iter().map(|d| d.name.as_str()).collect::<Vec<_>>(), ["ada0"]);
    assert_eq!(inv.imported_pools, ["zroot"]);
}
