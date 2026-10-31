//! The Islands pane (IslandsPane.swift, P13.7): how many islands each
//! display has and whether a switch slides, written to islands.ini at once;
//! undertow follows the file itself, so an editor is as good. The keys are
//! shown as bound: the defaults, with keys.ini's rows over them. Read, not
//! remembered.

use super::{at, log, Pane, PrefsHost};
use aquadraw::canvas::Canvas;
use aquadraw::drawlist::Role;
use aquadraw::runner::Rect;
use aquadraw::text::Style;
use pool_config::{Config, DesktopKeys, IslandsConfig};
use std::cell::RefCell;
use std::rc::Rc;

#[derive(Clone, Debug, Default, PartialEq)]
pub struct IslandsLayout {
    /// (count, hit, control).
    pub counts: Vec<(i64, Rect, Rect)>,
    pub slide: (Rect, Rect),
    /// Label, right edge, baseline.
    pub headings: Vec<(&'static str, f64, f64)>,
    pub names_top: f64,
    pub keys_top: f64,
    pub x: f64,
}

pub fn islands_layout(body: Rect, c: &IslandsConfig) -> IslandsLayout {
    let label_right = body.x + 170.0;
    let x = label_right + 12.0;
    let mut y = body.y + 30.0;
    let mut l = IslandsLayout { x, ..IslandsLayout::default() };
    l.headings.push(("Islands:", label_right, y + 15.0));
    l.counts = (1..=IslandsConfig::MAX_COUNT).map(|n| {
        let cx = x + (n - 1) as f64 * 34.0;
        (n, Rect::new(cx, y, 32.0, 22.0), Rect::new(cx, y + 3.0, 16.0, 16.0))
    }).collect();
    y += 36.0;
    l.headings.push(("Switching:", label_right, y + 15.0));
    l.slide = (Rect::new(x, y, 260.0, 22.0), Rect::new(x, y + 3.0, 16.0, 16.0));
    y += 36.0;
    l.headings.push(("Names:", label_right, y + 15.0));
    l.names_top = y;
    y += 22.0 * ((c.count - 1) / 5 + 1) as f64 + 30.0;
    l.headings.push(("Keys:", label_right, y + 15.0));
    l.keys_top = y;
    l
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum IslandsHit {
    Count(i64),
    Slide,
}

pub fn islands_hit(l: &IslandsLayout, x: f64, y: f64) -> Option<IslandsHit> {
    if let Some((n, _, _)) = l.counts.iter().find(|(_, h, _)| h.contains(x, y)) {
        return Some(IslandsHit::Count(*n));
    }
    l.slide.0.contains(x, y).then_some(IslandsHit::Slide)
}

/// Each action's name, and its action in keys.ini; one with an island
/// number is shown with N.
pub const KEY_ROWS: [(&str, &str); 12] = [
    ("Show island N", "island 1"),
    ("Next / previous island", "island next"),
    ("Send window to island N", "move-to-island 1"),
    ("…and go with it", "move-to-island 1 follow"),
    ("Ebb: this island", "ebb island"),
    ("Ebb: every island", "ebb archipelago"),
    ("Ebb: this application", "ebb app"),
    ("New shoal from window", "shoal new"),
    ("Add window to shoal", "shoal add"),
    ("Take window out", "shoal remove"),
    ("Recall shoal N", "shoal recall 1"),
    ("Show the shoals strip", "shoal strip"),
];

/// A key spec as a Mac menu shows it: "Ctrl+Alt+Shift+1" → "⌃⌥⇧1".
pub fn pretty(spec: &str) -> String {
    spec.split('+')
        .filter(|p| !p.is_empty())
        .map(|part| match part.to_lowercase().as_str() {
            "ctrl" | "control" => "⌃".into(),
            "alt" | "option" | "opt" => "⌥".into(),
            "shift" => "⇧".into(),
            "cmd" | "command" | "super" | "logo" | "meta" => "⌘".into(),
            "left" => "←".into(),
            "right" => "→".into(),
            "up" => "↑".into(),
            "down" => "↓".into(),
            "equal" => "=".into(),
            "minus" => "−".into(),
            _ if part.chars().count() == 1 => part.to_uppercase(),
            _ => part.to_string(),
        })
        .collect()
}

/// Each row's key from `table` (the defaults with keys.ini over them). An
/// island number is shown as the digits it can be, "1…9", not "N", which
/// is also a key (⌃⌥N makes a shoal); unbound is said.
pub fn shown(table: &[(String, String)]) -> Vec<(&'static str, String)> {
    let find = |action: &str| table.iter().find(|(_, a)| a.to_lowercase() == action).map(|(k, _)| k.clone());
    KEY_ROWS
        .iter()
        .map(|&(label, action)| {
            let Some(spec) = find(action) else { return (label, "none".to_string()) };
            let mut keys = pretty(&spec);
            if action.contains(" 1") {
                keys.pop();
                keys += "1…9"
            }
            if action == "island next"
                && let Some(prev) = find("island previous")
            {
                keys = format!("{} / {keys}", pretty(&prev))
            }
            (label, keys)
        })
        .collect()
}

pub fn paint_islands(c: &mut Canvas, l: &IslandsLayout, cfg: &IslandsConfig, keys: &[(&str, String)]) {
    let t = c.theme.tokens.clone();
    let left = |c: &mut Canvas, s: &str, x: f64, y: f64, k, size| c.text_left(s, x, y, k, size, Style::Regular, Role::Interface);
    for (text, right, baseline) in &l.headings {
        let w = c.text_width(text, 13.0, Style::Regular, Role::Interface);
        left(c, text, right - w, *baseline, t.body_text, 13.0)
    }
    for (n, _, ctl) in &l.counts {
        c.radio_button(ctl.x + 8.0, ctl.y + 8.0, 7.0, *n == cfg.count);
        left(c, &n.to_string(), ctl.x + 19.0, ctl.y + 12.0, t.body_text, 12.0)
    }
    let ctl = l.slide.1;
    c.checkbox(ctl, cfg.animate);
    left(c, "Slide from one island to the next", ctl.x + 24.0, ctl.y + 12.0, t.body_text, 13.0);
    for n in 1..=cfg.count {
        let (col, row) = ((n - 1) % 5, (n - 1) / 5);
        let name = cfg.name(n);
        let name = if name == n.to_string() { format!("Island {n}") } else { name };
        left(c, &name, l.x + col as f64 * 80.0, l.names_top + 15.0 + row as f64 * 22.0, t.body_text, 12.0)
    }
    left(c, "Named in islands.ini (name.1 = …).", l.x, l.names_top + 15.0 + ((cfg.count - 1) / 5 + 1) as f64 * 22.0, t.secondary_text, 11.0);
    for (i, (label, key)) in keys.iter().enumerate() {
        let y = l.keys_top + 15.0 + i as f64 * 18.0;
        left(c, label, l.x, y, t.body_text, 12.0);
        left(c, key, l.x + 200.0, y, t.secondary_text, 12.0)
    }
}

/// A click changes one thing and keeps the rest (names, the slide's length).
pub fn next_config(hit: IslandsHit, c: &IslandsConfig) -> IslandsConfig {
    let mut n = c.clone();
    match hit {
        IslandsHit::Count(k) => n.count = k.clamp(1, IslandsConfig::MAX_COUNT),
        IslandsHit::Slide => n.animate = !n.animate,
    }
    n
}

pub fn store(c: &IslandsConfig, dir: Option<&str>) -> Result<(), pool_config::Error> {
    let mut f = pool_config::load("islands", dir).unwrap_or_else(|_| Config::new());
    f.set("islands", "count", &c.count.to_string()).set_bool("islands", "animate", c.animate).set("islands", "slide_ms", &c.slide_ms.to_string());
    for (i, name) in c.names.iter().enumerate().filter(|(_, n)| !n.is_empty()) {
        f.set("islands", &format!("name.{}", i + 1), name);
    }
    f.store("islands", dir)
}

#[derive(Default)]
pub struct IslandsPane {
    layout: RefCell<IslandsLayout>,
    note: RefCell<Option<String>>,
    dumped: RefCell<Option<IslandsLayout>>,
}

impl Pane for IslandsPane {
    fn id(&self) -> &'static str {
        "islands"
    }
    fn note(&self) -> Option<String> {
        self.note.borrow().clone()
    }
    fn paint(&self, c: &mut Canvas, body: Rect) {
        let cfg = IslandsConfig::load(None);
        let l = islands_layout(body, &cfg);
        paint_islands(c, &l, &cfg, &shown(&DesktopKeys::effective(None)));
        *self.layout.borrow_mut() = l
    }
    /// Its controls, and what it shows of the key table.
    fn dump(&self) -> Vec<String> {
        let l = self.layout.borrow().clone();
        if self.dumped.borrow().as_ref() == Some(&l) {
            return vec![];
        }
        let mut line = "islands layout".to_string();
        for (n, _, ctl) in &l.counts {
            line += &format!(" count.{n}={}", at(ctl))
        }
        line += &format!(" slide={}", at(&l.slide.1));
        let mut out = vec![line];
        out.extend(shown(&DesktopKeys::effective(None)).into_iter().map(|(label, key)| format!("islands key '{label}' = {key}")));
        *self.dumped.borrow_mut() = Some(l);
        out
    }
    fn press(&self, h: &Rc<PrefsHost>, x: f64, y: f64) -> bool {
        let Some(hit) = islands_hit(&self.layout.borrow(), x, y) else { return false };
        let next = next_config(hit, &IslandsConfig::load(None));
        match store(&next, None) {
            Ok(()) => {
                *self.note.borrow_mut() = None;
                log(&format!("islands -> {} island(s), slide {}", next.count, if next.animate { "on" } else { "off" }))
            }
            Err(e) => {
                *self.note.borrow_mut() = Some(format!("Could not save: {e}"));
                log(&format!("islands: could not write islands.ini: {e}"))
            }
        }
        h.redraw();
        true
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn keys_read_as_a_mac_menu_shows_them() {
        assert_eq!(pretty("Ctrl+Alt+Shift+1"), "⌃⌥⇧1");
        assert_eq!(pretty("Ctrl+Left"), "⌃←");
        assert_eq!(pretty("F3"), "F3");
        assert_eq!(pretty("Ctrl+Alt+minus"), "⌃⌥−");
    }

    #[test]
    fn the_keys_are_shown_as_bound_with_keys_ini_over_the_defaults() {
        let mut table = DesktopKeys::defaults();
        let get = |t: &[(String, String)], label: &str| shown(t).into_iter().find(|(l, _)| *l == label).unwrap().1;
        assert_eq!(get(&table, "Show island N"), "⌃1…9");
        assert_eq!(get(&table, "New shoal from window"), "⌃⌥N", "the letter N, which is why numbers are not shown as N");
        assert_eq!(get(&table, "Next / previous island"), "⌃← / ⌃→");
        assert_eq!(get(&table, "…and go with it"), "⌃⌥⇧1…9");
        assert_eq!(get(&table, "Ebb: this island"), "F3");
        assert_eq!(get(&table, "Recall shoal N"), "⌃⇧1…9");
        table.retain(|(k, _)| k != "F3");
        table.push(("F4".into(), "ebb island".into()));
        assert_eq!(get(&table, "Ebb: this island"), "F4");
        table.retain(|(_, a)| a != "shoal strip");
        assert_eq!(get(&table, "Show the shoals strip"), "none");
    }

    #[test]
    fn a_click_changes_one_thing_and_keeps_the_rest() {
        let c = IslandsConfig::new(4, vec!["Home".into(), "Mail".into()], true, 300);
        let six = next_config(IslandsHit::Count(6), &c);
        assert_eq!((six.count, six.names.clone(), six.slide_ms), (6, vec!["Home".to_string(), "Mail".into()], 300));
        assert!(!next_config(IslandsHit::Slide, &c).animate);
        assert_eq!(next_config(IslandsHit::Count(40), &c).count, IslandsConfig::MAX_COUNT);
    }
}
