//! What this machine looks like, for the refusals in `install` to judge
//! (Probe.swift).
//!
//! P5.1 made the machine an argument so that every refusal could be tested
//! on a machine that has no disks to lose. This is the other half: the one
//! place that actually looks, and it is deliberately thin: read a few
//! commands, parse them, build the value. The parsing is pure and tested
//! against **real captured output**, because a parser tested against text
//! somebody made up is a parser tested against an assumption.

use install::{Disk, DiskInventory, MachineIdentity};
use spawn::{ErrorOutput, Options};
use std::collections::{BTreeMap, BTreeSet};
use std::fmt;

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ProbeError {
    NotSupported(String),
    /// The command, and what it said.
    CommandFailed(String, String),
}

impl fmt::Display for ProbeError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            ProbeError::NotSupported(why) => f.write_str(why),
            ProbeError::CommandFailed(cmd, out) => {
                let out = trimmed(out);
                if out.is_empty() { write!(f, "`{cmd}` failed") } else { write!(f, "`{cmd}` failed: {out}") }
            }
        }
    }
}

impl std::error::Error for ProbeError {}

/// Gather the machine's disks, what is mounted from them, and which pools
/// exist.
///
/// FreeBSD only, and it says so rather than guessing. **This is a positive
/// control, not a skip:** on Linux the installer must fail loudly and name
/// what it could not find, because "the tests were green on the machine I
/// develop on" is exactly how an installer ships broken.
pub fn probe_machine() -> Result<DiskInventory, ProbeError> {
    if !cfg!(target_os = "freebsd") {
        let os = if cfg!(target_os = "linux") { "Linux" } else { "an unsupported system" };
        return Err(ProbeError::NotSupported(format!(
            "disk discovery needs FreeBSD's geom(8), mount(8) and zpool(8); this is {os}, where an AbyssBSD install cannot be performed"
        )));
    }
    let geom = capture(&["geom", "disk", "list"])?;
    let mounts = capture(&["mount", "-p"])?;
    let labels = capture(&["glabel", "status", "-s"]).unwrap_or_default();
    let pools = imported_pool_names(run(&["kldstat", "-q", "-m", "zfs"]).0 == 0, || capture(&["zpool", "list", "-H", "-o", "name"]))?;
    let pool_vdevs: BTreeMap<String, Vec<String>> =
        pools.into_iter().map(|p| { let v = parse_zpool_vdevs(&capture(&["zpool", "list", "-Hv", &p]).unwrap_or_default()); (p, v) }).collect();
    // `gpart show` for every disk at once: what is on each, and where it is
    // not. Best-effort: a machine with no partition tables at all answers
    // with an error, and that is "no partitions", not "could not tell".
    let gpart = capture(&["gpart", "show"]).unwrap_or_default();
    // **Pools that are here but not imported, which on a live medium is all
    // of them.** `zpool import` with no arguments *scans* and lists what
    // could be imported; it imports nothing. Best-effort, and deliberately
    // so: it needs root, and a medium that cannot scan should still install.
    let importable = parse_importable_pools(&capture(&["zpool", "import"]).unwrap_or_default());
    // What this machine calls itself, from the kernel environment, **not
    // sysctl**, where `smbios.system.*` is not (PHASE12 §4.2). None when the
    // machine does not say: a real answer, and what stops a Mac Pro's loader
    // tunable being written to a board that never asked for it.
    let machine = vents::hardware::kenv::machine().map(|(maker, product)| MachineIdentity { maker, product });
    Ok(inventory(&geom, &mounts, &labels, &pool_vdevs, &importable, machine, &parse_gpart_show(&gpart)))
}

/// A command's status and what it said, stderr joined to stdout and stdin
/// /dev/null.
fn run(argv: &[&str]) -> (i32, String) {
    let r = spawn::run_with(argv, Options { stderr: ErrorOutput::Merge, ..Options::default() });
    if r.raw_status.is_none() {
        return (r.code(), r.failure.clone().unwrap_or_default());
    }
    (r.code(), r.stdout_text())
}

fn capture(argv: &[&str]) -> Result<String, ProbeError> {
    let (status, text) = run(argv);
    if status != 0 {
        return Err(ProbeError::CommandFailed(argv.join(" "), text));
    }
    Ok(text)
}

pub(crate) fn trimmed(s: &str) -> &str {
    s.trim_matches([' ', '\n', '\t'])
}

fn fields(line: &str) -> Vec<&str> {
    line.split([' ', '\t']).filter(|f| !f.is_empty()).collect()
}

// MARK: the pure part

/// One disk's layout from `gpart show`: what is on it, and where it is not.
///
/// **Free space is the point.** An installer that only ever takes whole
/// disks has one answer for a machine whose disks all have something on
/// them, and it is "destroy something".
#[derive(Clone, Debug, PartialEq, Eq, Default)]
pub struct DiskLayout {
    /// `GPT`, `MBR`, or empty when the disk has no partition table at all.
    pub scheme: String,
    /// Partition types in table order: `efi`, `ms-basic-data`, `ntfs`.
    pub kinds: Vec<String>,
    /// Every gap, in sectors, largest first.
    pub free_sectors: Vec<u64>,
}

impl DiskLayout {
    /// The biggest single gap: an install needs contiguous room, not a total.
    pub fn largest_free_sectors(&self) -> u64 {
        self.free_sectors.first().copied().unwrap_or(0)
    }
}

/// `gpart show` for every disk it lists. Three line shapes: a `=>` header
/// naming the disk and scheme, partition rows whose third column is an
/// index, and free rows whose third column is `-`. MBR rows carry an extra
/// `[active]` that must not be read as a type.
pub fn parse_gpart_show(text: &str) -> BTreeMap<String, DiskLayout> {
    let mut out = BTreeMap::new();
    let mut disk = String::new();
    let mut layout = DiskLayout::default();
    let mut flush = |disk: &mut String, layout: &mut DiskLayout| {
        if !disk.is_empty() {
            let mut l = std::mem::take(layout);
            l.free_sectors.sort_by(|a, b| b.cmp(a));
            out.insert(std::mem::take(disk), l);
        }
        *layout = DiskLayout::default();
    };
    for line in text.lines() {
        let f = fields(line);
        if f.is_empty() {
            continue;
        }
        if f[0] == "=>" {
            // "=>  34  1953525101  nda0  GPT  (932G)"
            flush(&mut disk, &mut layout);
            if f.len() >= 5 {
                disk = f[3].to_owned();
                layout.scheme = f[4].to_owned();
            }
            continue;
        }
        if disk.is_empty() || f.len() < 4 {
            continue;
        }
        // "34  2014  - free -  (1.0M)" versus "2048  204800  1  efi  (100M)"
        if f[2] == "-" {
            layout.free_sectors.push(f[1].parse().unwrap_or(0));
        } else if f[2].parse::<i64>().is_ok() {
            layout.kinds.push(f[3].to_owned());
        }
    }
    flush(&mut disk, &mut layout);
    out
}

/// One disk from `geom disk list`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct GeomDisk {
    pub name: String,
    pub bytes: u64,
    pub descr: String,
    /// **`gpart show` counts in the provider's sectors, not 512-byte
    /// units.** Assuming 512 on a 4Kn disk under-reports free space
    /// eightfold: safe in direction and wrong in fact.
    pub sector_bytes: u64,
}

fn leading_number(s: &str) -> u64 {
    let digits: String = s.chars().take_while(char::is_ascii_digit).collect();
    digits.parse().unwrap_or(0)
}

/// `geom disk list`: the disks and their sizes. One command answers name,
/// size and description together, and needs no root, where `diskinfo`
/// must open the device.
pub fn parse_geom_disk_list(text: &str) -> Vec<GeomDisk> {
    let mut out = vec![];
    let mut cur: Option<GeomDisk> = None;
    for raw in text.lines() {
        let line = trimmed(raw);
        if let Some(rest) = line.strip_prefix("Geom name:") {
            out.extend(cur.take());
            cur = Some(GeomDisk { name: trimmed(rest).to_owned(), bytes: 0, descr: String::new(), sector_bytes: 0 });
            continue;
        }
        let Some(d) = cur.as_mut() else { continue };
        if let Some(rest) = line.strip_prefix("Sectorsize:") {
            d.sector_bytes = leading_number(trimmed(rest));
        } else if let Some(rest) = line.strip_prefix("Mediasize:") {
            // "Mediasize: 85899345920 (80G)": the number, not the pretty part.
            d.bytes = leading_number(trimmed(rest));
        } else if let Some(rest) = line.strip_prefix("descr:") {
            // virtio and several others report a literal "(null)"; an empty
            // description is more honest than showing that to a person.
            let s = trimmed(rest);
            d.descr = if s == "(null)" { String::new() } else { s.to_owned() };
        }
    }
    out.extend(cur);
    out.retain(|d| !d.name.is_empty());
    out
}

/// `mount -p`: (device-or-dataset, mountpoint). The first column is a
/// device for UFS and msdosfs and a **dataset name** for ZFS, which is why
/// resolving it to a disk needs the pool map as well.
pub fn parse_mount_p(text: &str) -> Vec<(String, String)> {
    text.lines().map(fields).filter(|f| f.len() >= 2).map(|f| (f[0].to_owned(), f[1].to_owned())).collect()
}

/// `glabel status -s`: label to the provider it labels (`gpt/efiboot0` to
/// `vtbd0p2`). Without this, a `/dev/gpt/…` mount cannot be traced to a
/// disk, and the disk holding it would look free.
pub fn parse_label_components(text: &str) -> BTreeMap<String, String> {
    text.lines().map(fields).filter(|f| f.len() >= 3).map(|f| (f[0].to_owned(), f[2].to_owned())).collect()
}

/// The imported pools: none when the kernel has no ZFS.
///
/// **No module is an answer, not a failure** (found on the Radxa Dragon
/// Q8B, whose root is UFS): asking `zpool` there makes it try to load
/// `zfs.ko`, which fails for a caller that is not root and threw the whole
/// probe. So the kernel is asked first. With ZFS present, a `zpool list`
/// that fails is still a failure, and still loud.
pub fn imported_pool_names(zfs_present: bool, list: impl FnOnce() -> Result<String, ProbeError>) -> Result<Vec<String>, ProbeError> {
    if !zfs_present {
        return Ok(vec![]);
    }
    Ok(list()?.lines().filter(|l| !l.is_empty()).map(str::to_owned).collect())
}

/// `zpool list -Hv <pool>`: the providers the pool is built from. The
/// pool's own line has no leading tab; the vdev lines do.
pub fn parse_zpool_vdevs(text: &str) -> Vec<String> {
    const KINDS: [&str; 10] = ["mirror", "raidz1", "raidz2", "raidz3", "draid", "logs", "cache", "spares", "special", "dedup"];
    text.lines()
        .filter(|l| l.starts_with(['\t', ' ']))
        .filter_map(|l| fields(l).first().map(|s| (*s).to_owned()))
        // Skip the vdev *kinds*, which appear as parents of the real providers.
        .filter(|name| !KINDS.iter().any(|k| name.starts_with(k)))
        .collect()
}

/// The disk a provider lives on: `vtbd0p2` is `vtbd0`, `ada0s1a` is
/// `ada0`, `/dev/gpt/efiboot0` whatever `glabel` says it labels.
pub fn disk_of(provider: &str, labels: &BTreeMap<String, String>, disks: &[String]) -> Option<String> {
    let mut name = provider.strip_prefix("/dev/").unwrap_or(provider);
    if let Some(component) = labels.get(name) {
        name = component;
    }
    // Longest match wins, so `ada1` never claims `ada10p1`.
    disks.iter().filter(|d| name.starts_with(d.as_str())).max_by_key(|d| d.len()).cloned()
}

/// True for the structural rows of a `zpool` config tree, which name a vdev
/// *kind* rather than a device: `mirror-0`, `raidz1-2`, `draid2:4d:1c:0s-0`,
/// `replacing-0`, and the bare section headings.
pub fn is_vdev_type_node(name: &str) -> bool {
    if ["logs", "cache", "spares", "dedup", "special"].contains(&name) {
        return true;
    }
    let kinds = ["mirror", "raidz", "raidz1", "raidz2", "raidz3", "draid", "replacing", "spare", "indirect"];
    // `mirror-0` and `draid2:4d:1c:0s-0` carry a trailing `-<n>`; a device
    // called `mirrorX` would not, and must not be eaten here.
    kinds.iter().any(|k| name.starts_with(k))
        && name.rsplit_once('-').is_some_and(|(_, n)| !n.is_empty() && n.chars().all(|c| c.is_ascii_digit()))
}

/// Pools `zpool import` can see but nobody has imported, and the devices
/// each lives on. The config block is a tree: the pool's own name, then vdev
/// *type* nodes, then the leaves that are real devices. Only the leaves map
/// to a disk.
pub fn parse_importable_pools(text: &str) -> BTreeMap<String, Vec<String>> {
    let trim = |s: &str| s.trim_start_matches([' ', '\t']).trim_end_matches([' ', '\t', '\r']).to_owned();
    let mut out: BTreeMap<String, Vec<String>> = BTreeMap::new();
    let mut pool: Option<String> = None;
    let mut in_config = false;
    for line in text.split('\n') {
        let t = trim(line);
        if let Some(rest) = t.strip_prefix("pool:") {
            let p = trim(rest);
            in_config = false;
            if !p.is_empty() {
                out.entry(p.clone()).or_default();
            }
            pool = Some(p);
            continue;
        }
        if t == "config:" {
            in_config = true;
            continue;
        }
        let Some(p) = pool.as_ref().filter(|_| in_config) else { continue };
        if t.is_empty() {
            continue;
        }
        // The config block is indented; anything flush left has ended it.
        if !line.starts_with(['\t', ' ']) {
            in_config = false;
            continue;
        }
        let Some(name) = t.split(' ').next() else { continue };
        if name == p || is_vdev_type_node(name) {
            continue; // the pool's own row; mirror-0, raidz2-1, logs…
        }
        out.entry(p.clone()).or_default().push(name.to_owned());
    }
    out
}

/// Build the inventory from the captured texts. Pure, so the tests feed it
/// output captured from a real machine rather than a machine.
pub fn inventory(
    geom: &str,
    mounts: &str,
    labels: &str,
    pool_vdevs: &BTreeMap<String, Vec<String>>,
    importable_pools: &BTreeMap<String, Vec<String>>,
    machine: Option<MachineIdentity>,
    layouts: &BTreeMap<String, DiskLayout>,
) -> DiskInventory {
    let found = parse_geom_disk_list(geom);
    let names: Vec<String> = found.iter().map(|d| d.name.clone()).collect();
    let label_map = parse_label_components(labels);

    // Which disks does each pool sit on?
    let pool_disks: BTreeMap<&str, BTreeSet<String>> = pool_vdevs
        .iter()
        .map(|(pool, vdevs)| (pool.as_str(), vdevs.iter().filter_map(|v| disk_of(v, &label_map, &names)).collect()))
        .collect();

    let mut mounted_at: BTreeMap<String, Vec<String>> = BTreeMap::new();
    let mut root_disks = BTreeSet::new();
    for (source, point) in parse_mount_p(mounts) {
        if ["devfs", "procfs", "fdescfs"].contains(&source.as_str()) {
            continue;
        }
        let these: BTreeSet<String> = if let Some(d) = disk_of(&source, &label_map, &names) {
            [d].into()
        } else if let Some(ds) = source.split_once('/').and_then(|(pool, _)| pool_disks.get(pool)) {
            // A ZFS dataset: `zroot/ROOT/default` belongs to the pool `zroot`.
            ds.clone()
        } else {
            pool_disks.get(source.as_str()).cloned().unwrap_or_default()
        };
        for d in these {
            if point == "/" {
                root_disks.insert(d.clone());
            }
            mounted_at.entry(d).or_default().push(point.clone());
        }
    }

    // Which disk each *un-imported* pool sits on: the same mapping.
    let mut existing: BTreeMap<String, Vec<String>> = BTreeMap::new();
    for (pool, vdevs) in importable_pools {
        for d in vdevs.iter().filter_map(|v| disk_of(v, &label_map, &names)) {
            let e = existing.entry(d).or_default();
            if !e.contains(pool) {
                e.push(pool.clone());
            }
        }
    }

    let disks = found
        .into_iter()
        .map(|f| {
            let layout = layouts.get(&f.name);
            // **Sectors to bytes with the disk's OWN sector size**, not an
            // assumed 512.
            let sector = if f.sector_bytes > 0 { f.sector_bytes } else { 512 };
            let mut at = mounted_at.remove(&f.name).unwrap_or_default();
            at.sort();
            let mut pools = existing.remove(&f.name).unwrap_or_default();
            pools.sort();
            Disk {
                holds_running_root: root_disks.contains(&f.name),
                description: f.descr,
                bytes: f.bytes,
                mounted_at: at,
                existing_pools: pools,
                partition_kinds: layout.map(|l| l.kinds.clone()).unwrap_or_default(),
                free_bytes: layout.map_or(0, |l| l.largest_free_sectors()).saturating_mul(sector),
                has_partition_table: layout.is_some_and(|l| !l.scheme.is_empty()),
                name: f.name,
            }
        })
        .collect();
    DiskInventory { disks, imported_pools: pool_vdevs.keys().cloned().collect(), machine }
}
