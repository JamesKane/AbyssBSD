//! abyss-appgen: write an application bundle for every installed port that
//! has a desktop entry (PHASE15 P15.1), ported from main.swift beside it.
//!
//!   abyss-appgen [--from DIR]... [--to DIR] [--jails FILE] [--system DIR] [--dry-run]
//!
//! Reads `*.desktop` from each `--from` (default /usr/local/share/applications
//! and /usr/share/applications), and writes `<Name>.app` into `--to`:
//! /Applications when run as root, ~/Applications otherwise (PHASE15 §6.2).
//! `--system` is the machine's Applications folder; a run into any other is
//! a person's, and makes there only the desktop's own applications the
//! machine's folder lacks, and Agent. `--jails` is the jails.ini whose
//! `[apps]` says which applications run confined (P18.5). The rules are
//! `app-bundles`'; this is the I/O: find the entries and the icons,
//! rasterise an SVG with `rsvg-convert` when that is the best there is, and
//! write.
//!
//! **It only ever touches its own bundles.** Each carries a marker naming
//! the entry it came from; a bundle without one was put there by somebody
//! else and is neither replaced nor removed, and a generated bundle whose
//! entry has gone is removed. Every bundle is built in a temporary directory
//! and renamed into place, so the Finder never sees half of one.
//!
//! One line per decision on stdout, for a person and for the live test.

use app_bundles::{self as ab, BuiltinApp, DesktopEntry, IconChoice, BUILTIN_APPS};
use std::collections::{BTreeMap, BTreeSet};
use std::fs::{self, DirBuilder, OpenOptions};
use std::io::Write;
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt};
use std::path::Path;
use std::process::exit;

fn die(why: &str) -> ! {
    eprintln!("abyss-appgen: {why}");
    exit(2)
}

/// A directory's entries, sorted; none when it cannot be read.
fn list(dir: &str) -> Vec<String> {
    let mut v: Vec<String> = fs::read_dir(dir).map(|d| d.filter_map(|e| e.ok()).map(|e| e.file_name().to_string_lossy().into_owned()).collect()).unwrap_or_default();
    v.sort();
    v
}

fn exists(p: &str) -> bool {
    Path::new(p).exists()
}

fn read(p: &str) -> Option<String> {
    fs::read(p).ok().map(|b| String::from_utf8_lossy(&b[..b.len().min(1 << 20)]).into_owned())
}

fn write(p: &str, text: &str, mode: u32) -> bool {
    OpenOptions::new().write(true).create(true).truncate(true).mode(mode).open(p).and_then(|mut f| f.write_all(text.as_bytes())).is_ok()
}

fn mkdir(p: &str) -> bool {
    DirBuilder::new().mode(0o755).create(p).is_ok()
}

fn remove(p: &str) {
    let _ = fs::remove_dir_all(p);
}

fn run(argv: &[&str]) -> bool {
    spawn::run(argv).succeeded()
}

/// Every PNG and SVG under the icon roots, by name: walked once rather than
/// once per application (the themes on the guest hold tens of thousands).
fn index(dir: &str, depth: u32, into: &mut BTreeMap<String, Vec<String>>) {
    for name in list(dir) {
        let p = format!("{dir}/{name}");
        if depth > 0 && Path::new(&p).is_dir() {
            index(&p, depth - 1, into);
            continue;
        }
        for ext in [".png", ".svg", ".svgz"] {
            if let Some(stem) = name.strip_suffix(ext) {
                into.entry(stem.to_owned()).or_default().push(p.clone());
            }
        }
    }
}

fn icon_choice(icon: &str, idx: &BTreeMap<String, Vec<String>>) -> Option<IconChoice> {
    if icon.starts_with('/') {
        return if icon.ends_with(".svg") {
            Some(IconChoice::Svg(icon.into(), ab::WANTED))
        } else {
            exists(icon).then(|| IconChoice::Png(icon.into()))
        };
    }
    ab::choose_icon(idx.get(icon).map_or(&[][..], Vec::as_slice))
}

/// Make a bundle: in a temporary directory beside `bundle`, then renamed
/// into place, an old copy of ours moved out first. `files` are paths
/// inside it and their text; `launcher` is `Contents/MacOS/<stem>`'s.
fn make(bundle: &str, stem: &str, launcher: &str, files: &[(&str, String)], resources: bool) -> Result<String, String> {
    let (parent, _) = bundle.rsplit_once('/').unwrap_or((".", bundle));
    let tmp = format!("{parent}/.{stem}.app.tmp");
    remove(&tmp);
    let dirs = [tmp.clone(), format!("{tmp}/Contents"), format!("{tmp}/Contents/MacOS")];
    let ok = dirs.iter().all(|d| mkdir(d))
        && (!resources || mkdir(&format!("{tmp}/Contents/Resources")))
        && write(&format!("{tmp}/Contents/MacOS/{stem}"), launcher, 0o755)
        && files.iter().all(|(f, text)| write(&format!("{tmp}/{f}"), text, 0o644));
    if !ok {
        remove(&tmp);
        return Err("could not write it".into());
    }
    Ok(tmp)
}

fn put_in_place(tmp: &str, bundle: &str) -> bool {
    remove(bundle);
    fs::rename(tmp, bundle).is_ok()
}

struct Planned {
    dir: String,
    entry: DesktopEntry,
    argv: Vec<String>,
    source: String,
}

fn main() {
    let (mut froms, mut to, mut dry_run, mut jails_file, mut system_dir) = (vec![], None, false, None, "/Applications".to_owned());
    let mut args = std::env::args().skip(1);
    while let Some(a) = args.next() {
        let mut value = |what: &str| args.next().unwrap_or_else(|| die(&format!("{a} needs a {what}")));
        match a.as_str() {
            "--from" => froms.push(value("directory")),
            "--to" => to = Some(value("directory")),
            "--dry-run" => dry_run = true,
            "--system" => system_dir = value("directory"),
            "--jails" => jails_file = Some(value("file")),
            "-h" | "--help" => {
                println!("usage: abyss-appgen [--from DIR]... [--to DIR] [--jails FILE] [--system DIR] [--dry-run]");
                exit(0)
            }
            other => die(&format!("unknown option '{other}'")),
        }
    }
    if froms.is_empty() {
        froms = vec!["/usr/local/share/applications".into(), "/usr/share/applications".into()];
    }
    // Terminal, for `Terminal=true` entries: the shell binary installed
    // beside this one (P15.4), beside argv[0] as invoked, links not
    // followed (the harness's directory links each binary to its build).
    // Absolute: a launcher runs from wherever the Finder or the Dock is,
    // so a relative argv[0] would name nothing there.
    let terminal: Option<String> = std::env::args()
        .next()
        .and_then(|me| spawn::resolve_executable(&me, None))
        .and_then(|me| std::path::absolute(me).ok())
        .and_then(|me| me.parent().map(|d| d.join("AquaDemo").to_string_lossy().into_owned()))
        .filter(|t| abyss_sys::spawn::executable(t));
    let root = abyss_sys::platform::euid() == 0;
    let home = std::env::var("HOME").unwrap_or_else(|_| "/".into());
    let dest = to.unwrap_or_else(|| if root { "/Applications".into() } else { format!("{home}/Applications") });

    let mut icons = BTreeMap::new();
    for r in ["/usr/local/share/icons", "/usr/share/icons", "/usr/local/share/pixmaps", "/usr/share/pixmaps"] {
        index(r, 4, &mut icons);
    }

    // Confinement (P18.5): the machine's jails.ini as root, the person's
    // otherwise.
    let jails_path = jails_file.unwrap_or_else(|| {
        if root { "/usr/local/etc/abyss/jails.ini".into() } else { pool_config::config_dir().map(|d| format!("{d}/jails.ini")).unwrap_or_default() }
    });
    let jail_apps: Vec<(String, String)> = read(&jails_path)
        .map(|t| pool_config::Config::parse(&t).pairs("apps").into_iter().map(|(k, v)| (k.to_owned(), v.to_owned())).collect())
        .unwrap_or_default();

    // MARK: entries
    let mut planned: Vec<Planned> = vec![];
    let mut names = BTreeSet::new();
    for from in &froms {
        for file in list(from).into_iter().filter(|f| f.ends_with(".desktop")) {
            let source = format!("{from}/{file}");
            let Some(e) = read(&source).and_then(|t| DesktopEntry::parse(&t)) else {
                println!("skip {file}: not a desktop entry");
                continue;
            };
            if let Some(why) = e.skip_reason("AbyssBSD", terminal.is_some()) {
                println!("skip {file}: {why}");
                continue;
            }
            if !e.try_exec.is_empty() && spawn::resolve_executable(&e.try_exec, None).is_none() {
                println!("skip {file}: {} is not installed", e.try_exec);
                continue;
            }
            let Some((argv, _)) = e.command() else {
                println!("skip {file}: its Exec cannot be run");
                continue;
            };
            let dir = ab::directory_name(&e.name);
            if !names.insert(dir.clone()) {
                println!("skip {file}: {dir} is taken by an earlier entry");
                continue;
            }
            planned.push(Planned { dir, entry: e, argv, source });
        }
    }

    // MARK: write
    let jail_of = |p: &Planned| if p.entry.terminal { None } else { ab::jail_class(&p.entry, &p.source, &jail_apps) };
    if !dry_run && !exists(&dest) && !mkdir(&dest) {
        die(&format!("cannot create {dest}"))
    }
    for p in &planned {
        let bundle = format!("{dest}/{}", p.dir);
        if exists(&bundle) && !exists(&format!("{bundle}/{}", ab::MARKER)) {
            println!("kept {}: it is not ours (no {})", p.dir, ab::MARKER);
            continue;
        }
        let stem = &p.dir[..p.dir.len() - 4];
        let icon = icon_choice(&p.entry.icon, &icons);
        let icon_words = match &icon {
            Some(IconChoice::Png(f)) => f.clone(),
            Some(IconChoice::Svg(f, size)) => format!("{f} at {size}px"),
            None => format!("none found for '{}'", p.entry.icon),
        };
        let jail = jail_of(p);
        let confined = jail.as_ref().map_or(String::new(), |j| format!(", confined in {j}"));
        if dry_run {
            println!("would make {} from {} (icon: {icon_words}{confined})", p.dir, p.source);
            continue;
        }
        let launcher = ab::launcher(&p.argv, &p.source, if p.entry.terminal { terminal.as_deref() } else { None }, jail.as_deref());
        let files = [(ab::MARKER, format!("{}\n", p.source)), (ab::APP_ID_FILE, p.entry.app_ids(&p.source).join("\n") + "\n")];
        let tmp = match make(&bundle, stem, &launcher, &files, true) {
            Ok(t) => t,
            Err(why) => {
                println!("FAILED {}: {why}", p.dir);
                continue;
            }
        };
        let png = format!("{tmp}/Contents/Resources/{stem}.png");
        let icon_ok = match &icon {
            Some(IconChoice::Png(f)) => run(&["cp", f, &png]),
            Some(IconChoice::Svg(f, size)) => run(&["rsvg-convert", "-w", &size.to_string(), "-h", &size.to_string(), "-o", &png, f]),
            None => true,
        };
        if !icon_ok {
            println!("note {}: its icon could not be made from {icon_words}", p.dir);
        }
        if !put_in_place(&tmp, &bundle) {
            println!("FAILED {}: could not move it into place", p.dir);
            continue;
        }
        let shown = if icon.is_none() || icon_ok { icon_words } else { "none".into() };
        println!("made {} from {} (icon: {shown}{confined})", p.dir, p.source);
    }

    // MARK: the desktop's own (P18.13 loose ends)
    //
    // A bundle for each of the desktop's own applications, so the
    // Applications folder shows them as a Mac's does. Its launcher runs the
    // shell binary in the app's scene; its icon is the theme's, so it
    // follows the theme. Root's run puts them in /Applications; a person's
    // puts in ~/Applications only what /Applications lacks, and Agent, which
    // is theirs, there only while their agents are on (P18.13a).
    let mut builtins_made = BTreeSet::new();
    let bundle_of = |b: &BuiltinApp, under: &str| {
        let sub = b.folder.unwrap_or("");
        let folder = if sub.is_empty() { under.to_owned() } else { format!("{under}/{sub}") };
        format!("{folder}/{}", ab::directory_name(b.name))
    };
    let personal = dest != system_dir;
    let agents_on = pool_config::Agents::on(None);
    match &terminal {
        None => println!("skip the desktop's own applications: there is no AquaDemo beside abyss-appgen"),
        Some(binary) => {
            for b in BUILTIN_APPS.iter().filter(|b| b.folder.is_some()) {
                if b.token == "agent" {
                    if !personal {
                        println!("skip {}: it is the person's, in ~/Applications, while their agents are on", b.name);
                        continue;
                    }
                    if !agents_on {
                        continue;
                    }
                } else if personal && exists(&bundle_of(b, &system_dir)) {
                    continue; // /Applications has it
                }
                let bundle = bundle_of(b, &dest);
                let rel = bundle[dest.len() + 1..].to_owned();
                if exists(&bundle) && !exists(&format!("{bundle}/{}", ab::MARKER)) {
                    println!("kept {rel}: it is not ours (no {})", ab::MARKER);
                    continue;
                }
                builtins_made.insert(rel.clone());
                if dry_run {
                    println!("would make {rel}, the desktop's own");
                    continue;
                }
                let parent = bundle.rsplit_once('/').map_or(dest.clone(), |(p, _)| p.to_owned());
                if !exists(&parent) && !mkdir(&parent) {
                    println!("FAILED {rel}: cannot create {parent}");
                    continue;
                }
                let dir = ab::directory_name(b.name);
                let stem = &dir[..dir.len() - 4];
                let files = [(ab::MARKER, format!("{}\n", b.marker())), (ab::APP_ID_FILE, format!("{}\n", b.app_id)), (ab::THEME_ICON_FILE, format!("{}\n", b.theme_icon()))];
                let tmp = match make(&bundle, stem, &b.launcher(binary), &files, false) {
                    Ok(t) => t,
                    Err(why) => {
                        println!("FAILED {rel}: {why}");
                        continue;
                    }
                };
                if !put_in_place(&tmp, &bundle) {
                    println!("FAILED {rel}: could not move it into place");
                    continue;
                }
                println!("made {rel}, the desktop's own (scene {})", b.scene);
            }
        }
    }

    // Ours, whose entry has gone: a port's whose desktop entry went, or a
    // built-in's not wanted here any more (Agent with agents turned off).
    if !dry_run {
        for sub in ["", "Utilities"] {
            let dir = if sub.is_empty() { dest.clone() } else { format!("{dest}/{sub}") };
            for name in list(&dir).into_iter().filter(|n| n.ends_with(".app")) {
                let rel = if sub.is_empty() { name.clone() } else { format!("{sub}/{name}") };
                if (sub.is_empty() && names.contains(&name)) || builtins_made.contains(&rel) {
                    continue;
                }
                let marker = format!("{dir}/{name}/{}", ab::MARKER);
                if !exists(&marker) {
                    continue;
                }
                // Read before it goes with the bundle.
                let source = read(&marker).map_or_else(|| "?".to_owned(), |s| s.strip_suffix('\n').unwrap_or(&s).to_owned());
                remove(&format!("{dir}/{name}"));
                if source.starts_with("builtin:") {
                    println!("removed {rel}: not wanted here now");
                } else {
                    println!("removed {rel}: its entry {source} is gone");
                }
            }
        }
    }
}
