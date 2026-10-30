//! org.freedesktop.portal.Settings (Settings.swift, P8.3): what the desktop
//! tells a foreign toolkit about how it looks.
//!
//! A real GTK 3 app's first act, before it asked for a file or drew a
//! window, was `ReadAll(["org.gnome.*"])`; so this interface. From its XML
//! on disk, three rules:
//!
//!  1. **`Read` answers in TWO layers of variant**, and that is the
//!     contract: the documentation says one was intended and two shipped.
//!     `ReadOne` (version 2) answers in one. Both are served.
//!  2. **Only `org.freedesktop.appearance` is standardised**; everything
//!     else is the implementation's. A request for another namespace gets
//!     an empty answer, not an invention.
//!  3. **Globbing is trailing-only**, and an empty list or an empty pattern
//!     matches everything.
//!
//! Pure: a table and three lookups over it.

use dbus::Value;
use pool_config::Config;

pub const INTERFACE: &str = "org.freedesktop.portal.Settings";
/// 2, because 2 is what is implemented: the version that added `ReadOne`.
pub const VERSION: u32 = 2;
pub const APPEARANCE: &str = "org.freedesktop.appearance";
/// The loaded theme's colours (P11.10): not standard, ours.
pub const PALETTE: &str = "org.abyssbsd.palette";

/// One setting that differs (`changes`).
#[derive(Clone, Debug, PartialEq)]
pub struct Change {
    pub namespace: String,
    pub key: String,
    pub value: Value,
}

#[derive(Clone, Debug, PartialEq)]
pub struct PortalSettings {
    /// Namespace → keys, in the order they are published.
    pub namespaces: Vec<(String, Vec<(String, Value)>)>,
}

fn rgb(r: f64, g: f64, b: f64) -> Value {
    Value::Struct(vec![Value::Double(r), Value::Double(g), Value::Double(b)])
}

impl PortalSettings {
    /// The desktop's own answer. `color-scheme` is 2, prefer light: Aqua
    /// has no dark variant, and "no preference" gets GTK's default, which
    /// on some systems is dark. The accent is the Aqua menu-selection blue,
    /// three literals rather than a dependency on the toolkit (a test keeps
    /// them from drifting).
    pub fn aqua() -> PortalSettings {
        PortalSettings {
            namespaces: vec![(
                APPEARANCE.into(),
                vec![
                    ("color-scheme".into(), Value::UInt32(2)),
                    ("accent-color".into(), rgb(f64::from(0x3f) / 255.0, f64::from(0x6f) / 255.0, f64::from(0xdf) / 255.0)),
                    ("contrast".into(), Value::UInt32(0)),
                    ("reduced-motion".into(), Value::UInt32(0)),
                ],
            )],
        }
    }

    /// The answer made from a theme's palette (`abyss-theme palette`): its
    /// color-scheme, accent and contrast, and the colours beside them. None
    /// when the text is not a palette.
    pub fn from_palette(text: &str) -> Option<PortalSettings> {
        let c = Config::parse(text);
        let colour = |v: &str| {
            let n: Vec<f64> = v.split(' ').filter(|s| !s.is_empty()).filter_map(|s| s.parse().ok()).collect();
            (n.len() == 3 && n.iter().all(|x| (0.0..=1.0).contains(x))).then(|| rgb(n[0], n[1], n[2]))
        };
        let scheme = c.string("appearance", "color-scheme")?.parse::<u32>().ok().filter(|s| *s <= 2)?;
        let accent = colour(c.string("appearance", "accent-color")?)?;
        let contrast = c.string("appearance", "contrast").and_then(|s| s.parse::<u32>().ok()).unwrap_or(0);
        let colours = c.pairs("palette").into_iter().filter_map(|(k, v)| Some((k.to_owned(), colour(v)?))).collect();
        Some(PortalSettings {
            namespaces: vec![
                (
                    APPEARANCE.into(),
                    vec![
                        ("color-scheme".into(), Value::UInt32(scheme)),
                        ("accent-color".into(), accent),
                        ("contrast".into(), Value::UInt32(contrast.min(1))),
                        ("reduced-motion".into(), Value::UInt32(0)),
                    ],
                ),
                (PALETTE.into(), colours),
            ],
        })
    }

    /// Every key whose value in `new` differs from this one's, including
    /// keys `new` adds, in `new`'s order: what `SettingChanged` says when
    /// the theme changes (P14.2). A key `new` drops is not reported: the
    /// spec has no signal for a setting that went.
    pub fn changes(&self, new: &PortalSettings) -> Vec<Change> {
        let mut out = vec![];
        for (ns, keys) in &new.namespaces {
            for (k, v) in keys {
                if self.value(ns, k) != Some(v) {
                    out.push(Change { namespace: ns.clone(), key: k.clone(), value: v.clone() });
                }
            }
        }
        out
    }

    /// The spec's rule exactly. `org.gnome.*` does **not** match the bare
    /// `org.gnome`: the `.` is part of the prefix.
    pub fn matches(namespace: &str, patterns: &[String]) -> bool {
        patterns.is_empty()
            || patterns.iter().any(|p| match p.strip_suffix('*') {
                _ if p.is_empty() => true,
                Some(prefix) => namespace.starts_with(prefix),
                None => p == namespace,
            })
    }

    /// `ReadAll(as) -> a{sa{sv}}`.
    pub fn read_all(&self, patterns: &[String]) -> Value {
        Value::Array(
            "{sa{sv}}".into(),
            self.namespaces
                .iter()
                .filter(|(n, _)| Self::matches(n, patterns))
                .map(|(n, keys)| Value::DictEntry(Box::new(Value::String(n.clone())), Box::new(Value::options(keys.iter().map(|(k, v)| (k.as_str(), v.clone())).collect()))))
                .collect(),
        )
    }

    /// The raw value of one key. None is the caller's cue for an error: the
    /// spec says an unknown namespace or key is one, and a plausible default
    /// is how a toolkit renders a setting the desktop never made.
    pub fn value(&self, namespace: &str, key: &str) -> Option<&Value> {
        self.namespaces.iter().filter(|(n, _)| n == namespace).flat_map(|(_, keys)| keys).find(|(k, _)| k == key).map(|(_, v)| v)
    }

    /// `ReadOne(s, s) -> v`: one variant.
    pub fn read_one(&self, namespace: &str, key: &str) -> Option<Value> {
        self.value(namespace, key).map(|v| Value::Variant(Box::new(v.clone())))
    }

    /// `Read(s, s) -> v`: two variants, wrong on purpose (see the top).
    pub fn read(&self, namespace: &str, key: &str) -> Option<Value> {
        self.read_one(namespace, key).map(|v| Value::Variant(Box::new(v)))
    }
}
