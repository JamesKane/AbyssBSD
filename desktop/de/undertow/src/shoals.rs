//! Shoals: a working set of windows, recalled together (Shoals.swift,
//! PHASE13 P13.6, PRODUCT §7.3).
//!
//! Stage Manager done properly: **sets are explicit** (nothing joins by
//! itself), **recall restores the places remembered** and never moves or
//! resizes anything else, and **a shoal lives on an island**. Membership is
//! by window key (app id and title), so a window closed and opened again is
//! still a member. Kept in `shoals.ini`. The book is pure: no windows, no
//! files.

use pool_config::Config;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Shoal {
    pub name: String,
    pub display: String,
    pub island: i64,
    pub members: Vec<String>,
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct ShoalBook {
    pub shoals: Vec<Shoal>,
    /// The strip stays up (§6.7: summoned by default, pinned by choice).
    pub pinned: bool,
    /// The shoal "add" means: the last one made, added to or recalled.
    pub current: Option<usize>,
}

impl ShoalBook {
    pub fn new(shoals: Vec<Shoal>, pinned: bool) -> ShoalBook {
        let current = (!shoals.is_empty()).then_some(0);
        ShoalBook { shoals, pinned, current }
    }

    /// The shoal a window key belongs to: one at most.
    pub fn shoal_of(&self, key: &str) -> Option<usize> {
        self.shoals.iter().position(|s| s.members.iter().any(|m| m == key))
    }

    /// Shoals living on an island, in the order made: what Ctrl-Shift-N
    /// numbers and the strip shows.
    pub fn on_island(&self, display: &str, island: i64) -> Vec<usize> {
        (0..self.shoals.len()).filter(|&i| self.shoals[i].display == display && self.shoals[i].island == island).collect()
    }

    /// A new shoal of one window, which leaves any other. Named "Shoal N",
    /// N one past the highest in use, so numbers are not reused.
    pub fn create(&mut self, key: &str, display: &str, island: i64) -> usize {
        self.leave(key);
        let top = self.shoals.iter().filter_map(|s| s.name.strip_prefix("Shoal ")?.parse::<i64>().ok()).max().unwrap_or(0);
        self.shoals.push(Shoal { name: format!("Shoal {}", top + 1), display: display.into(), island, members: vec![key.into()] });
        self.current = Some(self.shoals.len() - 1);
        self.shoals.len() - 1
    }

    /// Add a window to shoal `i`, leaving any other. False if there is none.
    pub fn add(&mut self, key: &str, i: usize) -> bool {
        let Some(s) = self.shoals.get(i) else { return false };
        if s.members.iter().any(|m| m == key) {
            self.current = Some(i);
            return true;
        }
        // Leaving its old shoal may remove that one and move this one's
        // index: found again by name, which is unique.
        let name = s.name.clone();
        self.leave(key);
        let Some(j) = self.shoals.iter().position(|s| s.name == name) else { return false };
        self.shoals[j].members.push(key.into());
        self.current = Some(j);
        true
    }

    /// Take a window out of its shoal; a shoal left empty is gone.
    pub fn leave(&mut self, key: &str) -> bool {
        let Some(i) = self.shoal_of(key) else { return false };
        self.shoals[i].members.retain(|m| m != key);
        if self.shoals[i].members.is_empty() {
            self.shoals.remove(i);
            self.current = match self.current {
                Some(c) if c == i => self.shoals.len().checked_sub(1),
                Some(c) if c > i => Some(c - 1),
                c => c,
            };
        }
        true
    }

    pub fn recalled(&mut self, i: usize) {
        if i < self.shoals.len() {
            self.current = Some(i);
        }
    }

    // MARK: shoals.ini

    pub fn from_config(c: &Config) -> ShoalBook {
        let shoals = (1..=64)
            .filter_map(|n| {
                let s = format!("shoal.{n}");
                let name = c.string(&s, "name")?;
                let members: Vec<String> = c.string(&s, "members").unwrap_or("").split('\t').filter(|m| !m.is_empty()).map(str::to_owned).collect();
                (!members.is_empty()).then(|| Shoal {
                    name: name.into(),
                    display: c.string(&s, "display").unwrap_or("").into(),
                    island: c.int64(&s, "island").unwrap_or(1),
                    members,
                })
            })
            .collect();
        ShoalBook::new(shoals, c.bool("strip", "pinned").unwrap_or(false))
    }

    pub fn load(config_dir: Option<&str>) -> ShoalBook {
        pool_config::load("shoals", config_dir).map(|c| ShoalBook::from_config(&c)).unwrap_or_default()
    }

    pub fn config(&self) -> Config {
        let mut c = Config::new();
        for (i, s) in self.shoals.iter().enumerate() {
            let sec = format!("shoal.{}", i + 1);
            c.set(&sec, "name", &s.name);
            c.set(&sec, "display", &s.display);
            c.set(&sec, "island", &s.island.to_string());
            c.set(&sec, "members", &s.members.join("\t"));
        }
        c.set_bool("strip", "pinned", self.pinned);
        c
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn name(b: &ShoalBook, i: Option<usize>) -> Option<&str> {
        i.map(|i| b.shoals[i].name.as_str())
    }

    #[test]
    fn a_window_is_in_one_shoal_at_most() {
        let mut b = ShoalBook::default();
        let s1 = b.create("a", "D", 1);
        assert_eq!(b.shoals[s1].name, "Shoal 1");
        assert!(b.add("b", s1));
        let s2 = b.create("c", "D", 1);
        assert_eq!(b.shoals[s2].name, "Shoal 2");
        assert!(b.add("b", s2), "b moves");
        assert_eq!(b.shoals.iter().find(|s| s.name == "Shoal 1").map(|s| s.members.clone()), Some(vec!["a".to_owned()]));
        assert_eq!(name(&b, b.shoal_of("b")), Some("Shoal 2"));
        assert_eq!(name(&b, b.current), Some("Shoal 2"), "add means the shoal last added to");
    }

    #[test]
    fn a_shoal_left_empty_is_gone_and_numbers_are_not_reused() {
        let mut b = ShoalBook::default();
        b.create("a", "D", 1);
        b.create("b", "D", 1);
        assert!(b.leave("a"));
        assert_eq!(b.shoals.iter().map(|s| s.name.as_str()).collect::<Vec<_>>(), ["Shoal 2"]);
        let c = b.create("c", "D", 1);
        assert_eq!(b.shoals[c].name, "Shoal 3");
        assert!(!b.leave("nobody"));
    }

    #[test]
    fn shoals_live_on_an_island_and_are_kept() {
        let mut b = ShoalBook::default();
        b.create("a", "D", 2);
        b.add("b/Title with spaces", 0);
        b.create("c", "D", 1);
        assert_eq!(b.on_island("D", 2), [0]);
        assert_eq!(b.on_island("D", 1), [1]);
        assert!(b.on_island("E", 1).is_empty());
        b.pinned = true;
        let again = ShoalBook::from_config(&Config::parse(&b.config().to_ini()));
        assert_eq!(again.shoals, b.shoals);
        assert!(again.pinned);
    }
}
