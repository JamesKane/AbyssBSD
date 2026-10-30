//! IslandsConfig.swift: `islands.ini` (PHASE13 P13.1), shared by undertow,
//! which keeps the islands, and the Islands pane, which writes the file.

use crate::{pool, Config};

/// How many islands each display has, and what they are called. §6.1: a
/// fixed count, so Ctrl-3 always means the same place.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct IslandsConfig {
    pub count: i64,
    /// Index 0 is island 1. A missing name is the number.
    pub names: Vec<String>,
    /// The slide (P13.3, §6.5): on by default, skippable. Decoration only.
    pub animate: bool,
    /// Its length: ~150 ms (PRODUCT §7.2), up to 2 s for a test.
    pub slide_ms: i64,
}

impl Default for IslandsConfig {
    fn default() -> IslandsConfig {
        IslandsConfig::new(Self::DEFAULT_COUNT, Vec::new(), true, 150)
    }
}

impl IslandsConfig {
    pub const DEFAULT_COUNT: i64 = 4;
    /// One per digit key.
    pub const MAX_COUNT: i64 = 9;

    /// Clamped as Swift's init clamps: 1...9 islands, 0...2000 ms.
    pub fn new(count: i64, names: Vec<String>, animate: bool, slide_ms: i64) -> IslandsConfig {
        IslandsConfig { count: count.clamp(1, Self::MAX_COUNT), names, animate, slide_ms: slide_ms.clamp(0, 2000) }
    }

    pub fn name(&self, n: i64) -> String {
        if n >= 1 && n <= self.names.len() as i64 && !self.names[(n - 1) as usize].is_empty() {
            self.names[(n - 1) as usize].clone()
        } else {
            n.to_string()
        }
    }

    pub fn from(c: &Config) -> IslandsConfig {
        let count = c.int64("islands", "count").unwrap_or(Self::DEFAULT_COUNT);
        let mut names: Vec<String> =
            (1..=Self::MAX_COUNT).map(|n| c.string("islands", &format!("name.{n}")).unwrap_or("").to_owned()).collect();
        while names.last().is_some_and(String::is_empty) {
            names.pop();
        }
        IslandsConfig::new(
            count,
            names,
            c.bool("islands", "animate").unwrap_or(true),
            c.int64("islands", "slide_ms").unwrap_or(150),
        )
    }

    pub fn load(dir: Option<&str>) -> IslandsConfig {
        pool::load("islands", dir).map(|c| IslandsConfig::from(&c)).unwrap_or_default()
    }

    /// The island one step from `n`, wrapping: Ctrl-→ from the last is the
    /// first.
    pub fn step(&self, n: i64, d: i64) -> i64 {
        ((n - 1 + d) % self.count + self.count) % self.count + 1
    }
}
