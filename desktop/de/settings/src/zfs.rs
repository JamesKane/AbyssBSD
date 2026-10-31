//! ZFS datasets and snapshots as `zfs list -H -p` prints them, ported from
//! de/volumes/Volumes.swift (P15.8). Here because the helper's volume
//! refusals read them; Disk Utility will read them from here too.

/// One filesystem: `zfs list -H -p -o name,used,avail,mountpoint,mounted -t filesystem`.
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

    /// How deep it is under its pool: `zroot` 0, `zroot/usr/obj` 2.
    pub fn depth(&self) -> usize {
        self.name.split('/').filter(|c| !c.is_empty()).count().saturating_sub(1)
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

/// One snapshot: `zfs list -H -p -o name,creation,used -t snapshot`.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct Snapshot {
    /// `dataset@name`.
    pub name: String,
    pub created: i64,
    pub used: u64,
}

impl Snapshot {
    pub fn dataset(&self) -> &str {
        self.name.split_once('@').map_or(&self.name, |(d, _)| d)
    }

    pub fn short(&self) -> &str {
        self.name.split_once('@').map_or(&self.name, |(_, s)| s)
    }
}

fn rows(text: &str) -> impl Iterator<Item = Vec<&str>> {
    text.split('\n').filter(|l| !l.is_empty()).map(|l| l.split('\t').collect())
}

/// The datasets, in zfs's order; a row that is not one is skipped.
pub fn datasets(text: &str) -> Vec<Dataset> {
    rows(text)
        .filter_map(|f| {
            if f.len() < 5 {
                return None;
            }
            Some(Dataset {
                name: f[0].to_owned(),
                used: f[1].parse().ok()?,
                available: f[2].parse().ok()?,
                mountpoint: f[3].to_owned(),
                mounted: f[4] == "yes",
            })
        })
        .collect()
}

/// The snapshots, oldest first (by name when two were taken together).
pub fn snapshots(text: &str) -> Vec<Snapshot> {
    let mut out: Vec<Snapshot> = rows(text)
        .filter_map(|f| {
            if f.len() < 3 || !f[0].contains('@') {
                return None;
            }
            Some(Snapshot { name: f[0].to_owned(), created: f[1].parse().ok()?, used: f[2].parse().ok()? })
        })
        .collect();
    out.sort_by(|a, b| a.created.cmp(&b.created).then_with(|| a.name.cmp(&b.name)));
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn datasets_and_snapshots_are_read_from_zfs_list() {
        let d = datasets("zroot\t100\t900\tnone\tno\nzroot/usr/home\t5\t900\t/home\tyes\nbad\tx\t1\t/\tyes\n");
        assert_eq!(d.len(), 2);
        assert_eq!((d[1].pool(), d[1].depth(), d[1].leaf(), d[1].mountable(), d[1].mounted), ("zroot", 2, "home", true, true));
        assert!(!d[0].mountable());
        let s = snapshots("zroot/home@b\t20\t1\nzroot/home@a\t10\t1\nzroot/home@c\t20\t1\nnot-a-snapshot\t1\t1\n");
        assert_eq!(s.iter().map(Snapshot::short).collect::<Vec<_>>(), ["a", "b", "c"]);
        assert_eq!(s[0].dataset(), "zroot/home");
    }
}
