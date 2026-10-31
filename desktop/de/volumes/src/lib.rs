//! ZFS datasets and snapshots, for Disk Utility (Volumes.swift, P15.8).
//!
//! Reading needs no privilege (`zfs list` answers anyone), so it happens in
//! the person's own process; changing anything is a typed plan for the
//! settings helper (`VolumeAction`). The parsing is pure and tested against
//! captured output: `-H` (no header, tabs between fields) and `-p` (exact
//! numbers, not "1.2G").

#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct Dataset {
    pub name: String,
    pub used: u64,
    pub available: u64,
    /// A path, or `none` / `legacy` / `-` as zfs says.
    pub mountpoint: String,
    pub mounted: bool,
}

impl Dataset {
    pub fn pool(&self) -> &str {
        self.name.split('/').next().unwrap_or(&self.name)
    }
    /// How deep under its pool: `zroot` 0, `zroot/usr/obj` 2.
    pub fn depth(&self) -> usize {
        self.name.split('/').count() - 1
    }
    /// Its last component: what a sidebar shows.
    pub fn leaf(&self) -> &str {
        self.name.rsplit('/').next().unwrap_or(&self.name)
    }
    /// Whether it has somewhere to be mounted (not `none` or `legacy`).
    pub fn mountable(&self) -> bool {
        self.mountpoint.starts_with('/')
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct Snapshot {
    /// `dataset@name`.
    pub name: String,
    pub created: i64,
    pub used: u64,
}

impl Snapshot {
    pub fn dataset(&self) -> &str {
        self.name.split_once('@').map_or("", |(d, _)| d)
    }
    pub fn short(&self) -> &str {
        self.name.split_once('@').map_or(&self.name, |(_, s)| s)
    }
}

/// `zfs list -H -p -o name,used,avail,mountpoint,mounted -t filesystem`.
pub fn parse_datasets(text: &str) -> Vec<Dataset> {
    text.lines()
        .filter_map(|line| {
            let f: Vec<&str> = line.split('\t').collect();
            if f.len() < 5 {
                return None;
            }
            Some(Dataset { name: f[0].into(), used: f[1].parse().ok()?, available: f[2].parse().ok()?, mountpoint: f[3].into(), mounted: f[4] == "yes" })
        })
        .collect()
}

/// `zfs list -H -p -o name,creation,used -t snapshot`, oldest first.
pub fn parse_snapshots(text: &str) -> Vec<Snapshot> {
    let mut s: Vec<Snapshot> = text
        .lines()
        .filter_map(|line| {
            let f: Vec<&str> = line.split('\t').collect();
            if f.len() < 3 || !f[0].contains('@') {
                return None;
            }
            Some(Snapshot { name: f[0].into(), created: f[1].parse().ok()?, used: f[2].parse().ok()? })
        })
        .collect();
    s.sort_by(|a, b| a.created.cmp(&b.created).then_with(|| a.name.cmp(&b.name)));
    s
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct State {
    pub datasets: Vec<Dataset>,
    pub snapshots: Vec<Snapshot>,
    /// Why there is nothing to show, when there is not.
    pub unavailable: Option<String>,
}

impl State {
    pub fn snapshots_of<'a>(&'a self, dataset: &'a str) -> impl DoubleEndedIterator<Item = &'a Snapshot> + 'a {
        self.snapshots.iter().filter(move |s| s.dataset() == dataset)
    }
}

/// What the machine's pools hold now, or why that cannot be said.
pub fn read() -> State {
    let mut s = State::default();
    let Some(zfs) = spawn::resolve_executable("zfs", None) else {
        s.unavailable = Some("ZFS is not installed on this machine".into());
        return s;
    };
    let run = |args: &[&str]| {
        let argv: Vec<&str> = std::iter::once(zfs.as_str()).chain(args.iter().copied()).collect();
        spawn::run_with(&argv, spawn::Options { stderr: spawn::ErrorOutput::Merge, limit: 4 << 20, ..spawn::Options::default() })
    };
    let d = run(&["list", "-H", "-p", "-o", "name,used,avail,mountpoint,mounted", "-t", "filesystem"]);
    if !d.succeeded() {
        s.unavailable = Some(format!("zfs could not list the pools: {}", d.stdout_text().lines().next().unwrap_or("")));
        return s;
    }
    s.datasets = parse_datasets(&d.stdout_text());
    let n = run(&["list", "-H", "-p", "-o", "name,creation,used", "-t", "snapshot"]);
    if n.succeeded() {
        s.snapshots = parse_snapshots(&n.stdout_text())
    }
    if s.datasets.is_empty() {
        s.unavailable = Some("this machine has no ZFS pools".into())
    }
    s
}

/// A snapshot named for when it was taken: `abyss-2026-10-01-153007`.
pub fn snapshot_name(year: i32, month: i32, day: i32, hour: i32, minute: i32, second: i32) -> String {
    format!("abyss-{year}-{month:02}-{day:02}-{hour:02}{minute:02}{second:02}")
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Captured from the 16-CURRENT build guest (`-H -p`).
    const DATASETS: &str = "zroot\t42719010816\t45561032704\tnone\tno\nzroot/ROOT\t13056704512\t45561032704\tnone\tno\nzroot/ROOT/default\t13056270336\t45561032704\t/\tyes\nzroot/home\t6774800384\t45561032704\t/home\tyes\nzroot/usr/obj\t430080\t45561032704\t/usr/obj\tyes\n";

    #[test]
    fn datasets_are_parsed_with_their_mountpoints_and_depth() {
        let d = parse_datasets(DATASETS);
        assert_eq!(d.len(), 5);
        assert_eq!((d[2].name.as_str(), d[2].mountpoint.as_str(), d[2].mounted, d[2].depth(), d[2].leaf()), ("zroot/ROOT/default", "/", true, 2, "default"));
        assert_eq!(d[0].pool(), "zroot");
        assert!(!d[0].mountable(), "`none` is nowhere");
        assert_eq!(d[3].used, 6_774_800_384);
        assert!(parse_datasets("garbage\nzroot\tx\ty\tnone\tno\n").is_empty(), "a line that is not five fields of numbers");
    }

    #[test]
    fn snapshots_are_oldest_first_and_know_their_dataset() {
        let s = parse_snapshots("zroot/home@b\t1759300000\t4096\nzroot/home@a\t1759200000\t8192\nzroot/usr@x\t1759250000\t0\n");
        assert_eq!(s.iter().map(Snapshot::short).collect::<Vec<_>>(), ["a", "x", "b"]);
        assert_eq!(s[0].dataset(), "zroot/home");
        let st = State { snapshots: s, ..State::default() };
        assert_eq!(st.snapshots_of("zroot/home").map(Snapshot::short).collect::<Vec<_>>(), ["a", "b"]);
    }

    #[test]
    fn a_snapshot_is_named_for_when_it_was_taken() {
        assert_eq!(snapshot_name(2026, 10, 1, 9, 5, 7), "abyss-2026-10-01-090507");
    }
}
