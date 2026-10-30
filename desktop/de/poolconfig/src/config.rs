//! Config.swift: one config domain, parsed and owned, with typed reads, and
//! the INI text it reads and writes.

use crate::pool;
use crate::Error;
use std::collections::BTreeMap;

/// A parsed, owned snapshot of one config domain: sections of key/value
/// strings, with typed accessors. The default (unnamed) section is "".
///
/// Names are compared, and sorted, byte for byte (Swift: by canonical
/// equivalence; RUST.md R2, the poolconfig note).
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Config {
    sections: BTreeMap<String, BTreeMap<String, String>>,
}

impl Config {
    pub fn new() -> Config {
        Config::default()
    }

    // MARK: typed reads

    pub fn string(&self, section: &str, key: &str) -> Option<&str> {
        self.sections.get(section)?.get(key).map(String::as_str)
    }

    pub fn uint64(&self, section: &str, key: &str) -> Option<u64> {
        self.string(section, key).and_then(parse_u64)
    }

    pub fn int64(&self, section: &str, key: &str) -> Option<i64> {
        self.string(section, key).and_then(parse_i64)
    }

    /// true/1/yes/on and false/0/no/off, any case. Anything else is None.
    pub fn bool(&self, section: &str, key: &str) -> Option<bool> {
        match self.string(section, key)?.to_lowercase().as_str() {
            "true" | "1" | "yes" | "on" => Some(true),
            "false" | "0" | "no" | "off" => Some(false),
            _ => None,
        }
    }

    /// Every key/value in a section, sorted by key: for a table, whose
    /// reader does not know the keys (the keybind file, P9.5).
    pub fn pairs(&self, section: &str) -> Vec<(&str, &str)> {
        self.sections
            .get(section)
            .map(|kv| kv.iter().map(|(k, v)| (k.as_str(), v.as_str())).collect())
            .unwrap_or_default()
    }

    /// The schema version from the default section (0 if unset).
    pub fn schema_version(&self) -> u64 {
        self.uint64("", "schema_version").unwrap_or(0)
    }

    /// Every section present, sorted (a theme refuses the ones it does not
    /// know, P11.2).
    pub fn section_names(&self) -> Vec<&str> {
        self.sections.keys().map(String::as_str).collect()
    }

    // MARK: typed writes (chainable)

    pub fn set(&mut self, section: &str, key: &str, value: &str) -> &mut Config {
        self.sections.entry(section.to_owned()).or_default().insert(key.to_owned(), value.to_owned());
        self
    }

    pub fn set_u64(&mut self, section: &str, key: &str, value: u64) -> &mut Config {
        self.set(section, key, &value.to_string())
    }

    pub fn set_bool(&mut self, section: &str, key: &str, value: bool) -> &mut Config {
        self.set(section, key, if value { "true" } else { "false" })
    }

    // MARK: parse / serialize

    /// Parse INI text: `[section]` headers, `key = value` pairs, `#`/`;`
    /// full-line comments, blank lines ignored. Keys before any header land
    /// in the default section. Lenient: unparseable lines are skipped.
    /// Lines end at `\n`, and space, tab, CR and LF are trimmed, so a CRLF
    /// file reads as an LF one.
    pub fn parse(text: &str) -> Config {
        let ws: &[char] = &[' ', '\t', '\r', '\n'];
        let mut config = Config::new();
        let mut current = String::new();
        for raw in text.split('\n') {
            let line = raw.trim_matches(ws);
            if line.is_empty() || line.starts_with('#') || line.starts_with(';') {
                continue;
            }
            if line.len() >= 2 && line.starts_with('[') && line.ends_with(']') {
                current = line[1..line.len() - 1].trim_matches(ws).to_owned();
                continue;
            }
            let Some((key, value)) = line.split_once('=') else { continue };
            let key = key.trim_matches(ws);
            if key.is_empty() {
                continue;
            }
            config.set(&current, key, value.trim_matches(ws));
        }
        config
    }

    /// The bytes of a file, decoded as Swift's `String(decoding:as:)` does
    /// (each ill-formed sequence one U+FFFD), then parsed.
    pub fn parse_bytes(bytes: &[u8]) -> Config {
        Config::parse(&String::from_utf8_lossy(bytes))
    }

    /// Serialize to INI text. Deterministic: the default section's keys
    /// first, then the named sections, sections and keys sorted.
    pub fn to_ini(&self) -> String {
        let mut out = String::new();
        for (name, kv) in &self.sections {
            if kv.is_empty() {
                continue;
            }
            if !name.is_empty() {
                if !out.is_empty() {
                    out.push('\n');
                }
                out.push_str(&format!("[{name}]\n"));
            }
            for (k, v) in kv {
                out.push_str(&format!("{k} = {v}\n"));
            }
        }
        out
    }

    // MARK: persist

    /// Atomically write this config as `<domain>.ini` in `dir` (default:
    /// the config directory): temp file, fsync, rename, under a `.lock`.
    pub fn store(&self, domain: &str, dir: Option<&str>) -> Result<(), Error> {
        let d = match dir {
            Some(d) => d.to_owned(),
            None => pool::config_dir()?,
        };
        pool::atomic_write(&d, domain, self.to_ini().as_bytes())
    }
}

/// An optional `+`, then one or more ASCII digits, in range.
pub fn parse_u64(s: &str) -> Option<u64> {
    s.parse().ok()
}

/// An optional `+` or `-`, then one or more ASCII digits, in range.
pub fn parse_i64(s: &str) -> Option<i64> {
    s.parse().ok()
}
