//! Config.swift: one config domain, parsed and owned, with typed reads, and
//! the INI text it reads and writes.

use crate::pool;
use crate::text;
use crate::Error;
use std::collections::BTreeMap;

/// A parsed, owned snapshot of one config domain: sections of key/value
/// strings, with typed accessors. The default (unnamed) section is "".
///
/// Names are compared, and sorted, byte for byte. Swift compares them by
/// canonical equivalence, so where a file's section names or keys are not
/// all in NFC the two can differ (RUST.md R2, poolconfig note; the
/// fixtures' `.rust.txt` files say how).
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
    /// Lines, trimming and delimiters are Swift's Characters (text.rs).
    pub fn parse(text: &str) -> Config {
        let mut config = Config::new();
        let mut current = String::new();
        for raw in text::lines(text) {
            let line = text::trim(raw);
            if line.is_empty() || text::starts_with(line, b'#') || text::starts_with_semicolon(line) {
                continue;
            }
            if text::starts_with(line, b'[') && text::ends_with(line, b']') {
                current = text::trim(&line[1..line.len() - 1]).to_owned();
                continue;
            }
            let Some(eq) = text::find(line, b'=') else { continue };
            let key = text::trim(&line[..eq]);
            if key.is_empty() {
                continue;
            }
            let value = text::trim(&line[eq + 1..]);
            config.set(&current, key, value);
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

/// Swift's `UInt64(_: String)`: an optional `+` or `-`, then one or more
/// ASCII digits, in range. `-` is accepted for zero ("-0" is 0).
pub fn parse_u64(s: &str) -> Option<u64> {
    let (neg, digits) = sign(s)?;
    let mut v: u64 = 0;
    for &d in digits {
        v = v.checked_mul(10)?.checked_add((d - b'0') as u64)?;
    }
    if neg && v != 0 { None } else { Some(v) }
}

/// Swift's `Int64(_: String)`: an optional `+` or `-`, then one or more
/// ASCII digits, in range.
pub fn parse_i64(s: &str) -> Option<i64> {
    let (neg, digits) = sign(s)?;
    // Accumulated on the side of the sign, so i64::MIN parses.
    let mut v: i64 = 0;
    for &d in digits {
        let d = (d - b'0') as i64;
        v = v.checked_mul(10)?;
        v = if neg { v.checked_sub(d)? } else { v.checked_add(d)? };
    }
    Some(v)
}

fn sign(s: &str) -> Option<(bool, &[u8])> {
    let b = s.as_bytes();
    let (neg, digits) = match b.first()? {
        b'-' => (true, &b[1..]),
        b'+' => (false, &b[1..]),
        _ => (false, b),
    };
    if digits.is_empty() || !digits.iter().all(u8::is_ascii_digit) {
        return None;
    }
    Some((neg, digits))
}
