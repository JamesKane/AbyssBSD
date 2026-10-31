//! `fathom`: run the probes on this machine and report (PHASE12.md P12.3),
//! ported from main.swift beside it.
//!
//! **The gathering lives here and nowhere else.** The `fathom` crate is pure
//! functions over captured text, which is what lets every probe be tested on
//! a machine that has none of the hardware. This binary is the half that is
//! allowed to look: it runs the commands, reads the sysctls and the kernel
//! environment, and hands the text to the parsers.
//!
//!   fathom              the report, as text
//!   fathom --measure    also run the compositor and report the frame contract
//!   fathom --quiet      exit status only: 0 complete, 1 something unaskable
//!   fathom --save       also write it to the medium's ESP, so it leaves with
//!                       the stick: FAT is the one filesystem every desktop reads
//!   fathom --save-to D  write it to a directory of your choosing instead
//!
//! **Exit status is about completeness, not suitability.** A machine with no
//! battery and no Wi-Fi produces a complete report and a perfectly good
//! desktop; one where `kldstat` could not be read produces an incomplete one.

use probes::{FathomReport, ProbeResult, ProbeStatus};
use std::io::ErrorKind;
use std::process::exit;
use vents::hardware::{kenv, sysctl};

/// A command's stdout, or why there is none: it could not be run, **or it
/// failed**. None becomes `unknown` rather than `absent`, the distinction
/// the whole report turns on. stderr is never parsed as data (on Linux
/// `ifconfig: option '-l' not recognised` once read as a list of
/// interfaces); it is only quoted, its last line, as the reason.
fn run(argv: &[&str]) -> Result<String, String> {
    let r = spawn::run(argv);
    if r.raw_status.is_none() {
        return Err(r.failure.unwrap_or_else(|| format!("{} could not start", argv[0])));
    }
    if !r.succeeded() {
        let text = r.stderr_text();
        let last = text.lines().rfind(|l| !l.trim_start_matches([' ', '\t']).is_empty());
        return Err(last.map_or_else(|| format!("{} exited {} and said nothing", argv[0], r.code()), str::to_owned));
    }
    Ok(r.stdout_text())
}

fn capture(argv: &[&str]) -> Option<String> {
    run(argv).ok()
}

/// `/dev/dri`'s entries: none when it does not exist (no GPU bound, on
/// FreeBSD), None when it exists and cannot be read, which is not the same
/// answer.
fn dri_entries() -> Option<Vec<String>> {
    match std::fs::read_dir("/dev/dri") {
        Ok(d) => Some(d.filter_map(|e| e.ok()).map(|e| e.file_name().to_string_lossy().into_owned()).collect()),
        Err(e) if e.kind() == ErrorKind::NotFound => Some(vec![]),
        Err(_) => None,
    }
}

/// Write the report into `directory`; its path, or None.
fn save(text: &str, directory: &str, name: &str) -> Option<String> {
    let path = format!("{directory}/{name}");
    std::fs::write(&path, text).ok().map(|_| path)
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let has = |f: &str| args.iter().any(|a| a == f);

    // ---------------------------------------------------------------- gather
    let machine = kenv::machine();
    let (maker, product) = (machine.as_ref().map(|m| m.0.as_str()), machine.as_ref().map(|m| m.1.as_str()));
    // **"No battery" and "no way to ask about batteries" are different
    // machines.** On a platform with no sysctl at all every reading is None,
    // and reporting that as "mains only" would invent a fact about hardware
    // nobody looked at.
    let can_ask = sysctl::is_supported();
    let battery = if can_ask { sysctl::int("hw.acpi.battery.life") } else { None };
    let dri = dri_entries();
    let dri: Option<Vec<&str>> = dri.as_ref().map(|v| v.iter().map(String::as_str).collect());
    let mut results: Vec<ProbeResult> = vec![
        probes::probe_machine(maker, product),
        probes::probe_cpu(sysctl::string("hw.model").as_deref(), sysctl::int("hw.ncpu")),
        probes::probe_memory(sysctl::int("hw.physmem")),
        probes::probe_boot_method(sysctl::string("machdep.bootmethod").as_deref(), sysctl::string("hw.machine_arch").as_deref()),
        probes::probe_modules(capture(&["kldstat"]).as_deref()),
        probes::probe_gpu(dri.as_deref()),
        probes::probe_network(capture(&["ifconfig", "-l"]).as_deref()),
        // `-m` finds a module compiled into the kernel too; None where
        // kldstat itself could not be asked.
        probes::probe_wifi(sysctl::string("net.wlan.devices").as_deref(), can_ask.then(|| spawn::run(&["kldstat", "-q", "-m", "wlan"]).succeeded())),
        probes::probe_audio(std::fs::read_to_string("/dev/sndstat").ok().as_deref()),
        probes::probe_battery(battery, can_ask && battery.is_some(), can_ask),
    ];

    // ------------------------------------------------------------ measurement
    //
    // **Opt-in, because it is the one probe that costs something**: it
    // starts a compositor, takes the display, and runs for a few seconds.
    // And not measuring is said in a footer rather than left out.
    let measure = has("--measure");
    if measure {
        // The medium installs to /usr/local/bin; a developer has it on PATH.
        let installed = "/usr/local/bin/undertow";
        let undertow = if abyss_sys::spawn::executable(installed) { installed } else { "undertow" };
        match run(&[undertow, "run", "--backend", "auto", "--frames", "300"]) {
            Ok(out) => results.push(probes::probe_frame_contract(Some(&out))),
            // Quote the machine rather than paraphrase it: the line somebody
            // would otherwise have to reboot to read.
            Err(why) => results.push(ProbeResult::new("Frame contract", ProbeStatus::Unknown, format!("could not measure: {why}"))),
        }
    }
    let report = FathomReport::new(results);

    // ------------------------------------------------------------------ save
    //
    // **The matrix is populated by strangers, so retrieval cannot assume a
    // network**, and the machines whose network does not come up are the
    // ones worth hearing about. The ESP is FAT, which every desktop OS reads.
    let name = probes::report_filename(maker, product);
    let text = probes::render_text(&report, "Fathom");
    if let Some(i) = args.iter().position(|a| a == "--save-to")
        && let Some(dir) = args.get(i + 1)
    {
        match save(&text, dir, &name) {
            Some(path) => println!("fathom: wrote {path}"),
            None => {
                eprintln!("fathom: could not write into {dir}");
                exit(2)
            }
        }
    } else if has("--save") {
        // The ESP by the label the medium's own build gives it
        // (`makefs -o volume_label=EFISYS`), not by parsing a partition table.
        let (esp, mount) = ("/dev/msdosfs/EFISYS", "/tmp/fathom-esp");
        let _ = std::fs::create_dir(mount);
        // **FAT stores no permissions**: `-m 644` sets what this mount
        // synthesises, and every other reader's mount decides for itself.
        if run(&["mount_msdosfs", "-m", "644", "-M", "755", esp, mount]).is_err() {
            eprintln!("fathom: could not mount {esp} — is this the live medium, and are you root?");
            exit(2)
        }
        let saved = save(&text, mount, &name);
        let _ = run(&["umount", mount]);
        if saved.is_none() {
            eprintln!("fathom: mounted the ESP and could not write to it");
            exit(2)
        }
        // The name it will have *on the stick*, not the temporary mount.
        println!("fathom: wrote {name} to the stick's EFI partition — readable on any machine that reads FAT");
    }

    if !has("--quiet") {
        print!("{text}");
        if !measure {
            println!("\n(frame contract not measured; pass --measure to run the compositor)");
        }
    }
    exit(if report.is_complete() { 0 } else { 1 })
}
