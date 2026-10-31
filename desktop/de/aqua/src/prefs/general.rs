//! The General pane (AppearancePane.swift, P14.2): the theme, its scheme
//! and its settings. A click writes appearance.ini at once, as a Mac's
//! General pane applies with no OK button, and every process that draws
//! follows through its own watch: this pane tells nobody anything, which is
//! what lets `abyss-theme set` from a terminal be as good.

use super::appearance_catalogue::{self as catalogue, InstalledTheme};
use super::{at, log, two_places, Pane, PrefsHost};
use aquadraw::canvas::Canvas;
use aquadraw::drawlist::Role;
use aquadraw::runner::Rect;
use aquadraw::text::Style;
use aquadraw::theme::{Choice, ThemeParameter};
use std::cell::RefCell;
use std::rc::Rc;
use std::collections::BTreeMap;

#[derive(Clone, Debug, PartialEq)]
pub struct Row {
    /// A theme id, a scheme, or a parameter's name.
    pub value: String,
    pub label: String,
    pub hit: Rect,
    /// The radio's circle, or the slider's track.
    pub control: Rect,
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct AppearanceLayout {
    pub themes: Vec<Row>,
    pub schemes: Vec<Row>,
    pub parameters: Vec<Row>,
    /// Text, right edge, baseline.
    pub headings: Vec<(&'static str, f64, f64)>,
}

fn capitalised(s: &str) -> String {
    let mut c = s.chars();
    c.next().map_or(String::new(), |f| f.to_uppercase().chain(c).collect())
}

/// The controls inside `body`: labels right-aligned on the left, as a Mac
/// pane's are, and the controls beside them.
pub fn appearance_layout(body: Rect, themes: &[InstalledTheme], choice: &Choice) -> AppearanceLayout {
    let mut l = AppearanceLayout::default();
    let (label_right, row_h) = (body.x + 170.0, 22.0);
    let x = label_right + 12.0;
    let mut y = body.y + 34.0;
    let radios = |items: Vec<(String, String)>, y: &mut f64| -> Vec<Row> {
        items
            .into_iter()
            .map(|(value, label)| {
                let r = Row { value, label, hit: Rect::new(x, *y, 260.0, row_h), control: Rect::new(x, *y + 3.0, 16.0, 16.0) };
                *y += row_h;
                r
            })
            .collect()
    };
    l.headings.push(("Theme:", label_right, y + 15.0));
    l.themes = radios(themes.iter().map(|t| (t.id.clone(), t.name.clone())).collect(), &mut y);
    y += 14.0;
    let theme = themes.iter().find(|t| t.id == choice.name);
    l.headings.push(("Scheme:", label_right, y + 15.0));
    match theme.filter(|t| !t.schemes.is_empty()) {
        Some(t) => l.schemes = radios(t.schemes.iter().map(|s| (s.clone(), capitalised(s))).collect(), &mut y),
        // "Standard", said, not offered.
        None => y += row_h,
    }
    y += 14.0;
    if let Some(t) = theme.filter(|t| !t.parameters.is_empty()) {
        l.headings.push(("Settings:", label_right, y + 15.0));
        for p in &t.parameters {
            l.parameters.push(Row { value: p.name.clone(), label: p.name.clone(), hit: Rect::new(x, y, 260.0, row_h), control: Rect::new(x + 70.0, y + 1.0, 150.0, 20.0) });
            y += row_h + 4.0;
        }
    }
    l
}

#[derive(Clone, Debug, PartialEq)]
pub enum AppearanceHit {
    Theme(String),
    Scheme(String),
    /// A setting, and the value the pointer's x means on its track.
    Parameter(String, f64),
}

pub fn appearance_hit(l: &AppearanceLayout, themes: &[InstalledTheme], choice: &Choice, x: f64, y: f64) -> Option<AppearanceHit> {
    if let Some(r) = l.themes.iter().find(|r| r.hit.contains(x, y)) {
        return Some(AppearanceHit::Theme(r.value.clone()));
    }
    if let Some(r) = l.schemes.iter().find(|r| r.hit.contains(x, y)) {
        return Some(AppearanceHit::Scheme(r.value.clone()));
    }
    let r = l.parameters.iter().find(|r| r.hit.contains(x, y))?;
    let p = themes.iter().find(|t| t.id == choice.name)?.parameters.iter().find(|p| p.name == r.value)?;
    Some(AppearanceHit::Parameter(r.value.clone(), appearance_value(p, r.control, x)))
}

/// The value at `x` on a setting's track, within its bounds.
pub fn appearance_value(p: &ThemeParameter, track: Rect, x: f64) -> f64 {
    let t = ((x - track.x) / track.w.max(1.0)).clamp(0.0, 1.0);
    p.min + t * (p.max - p.min)
}

/// What a choice writes: a new theme starts from its own defaults; a
/// scheme or a setting keeps the rest. A setting to two places, as shown.
pub fn next_choice(hit: &AppearanceHit, c: &Choice) -> Choice {
    match hit {
        AppearanceHit::Theme(id) if *id == c.name => c.clone(),
        AppearanceHit::Theme(id) => Choice { name: id.clone(), scheme: None, overrides: BTreeMap::new() },
        AppearanceHit::Scheme(s) => Choice { scheme: Some(s.clone()), ..c.clone() },
        AppearanceHit::Parameter(n, v) => {
            let mut next = c.clone();
            next.overrides.insert(n.clone(), (v * 100.0).round() / 100.0);
            next
        }
    }
}

pub fn paint_appearance(c: &mut Canvas, l: &AppearanceLayout, themes: &[InstalledTheme], choice: &Choice, dragging: Option<&(String, f64)>) {
    let t = c.theme.tokens.clone();
    for (text, right, baseline) in &l.headings {
        let w = c.text_width(text, 13.0, Style::Regular, Role::Interface);
        c.text_left(text, right - w, *baseline, t.body_text, 13.0, Style::Regular, Role::Interface)
    }
    let radio = |c: &mut Canvas, r: &Row, on: bool| {
        c.radio_button(r.control.x + 8.0, r.control.y + 8.0, 7.0, on);
        c.text_left(&r.label, r.control.x + 24.0, r.control.y + 12.0, t.body_text, 13.0, Style::Regular, Role::Interface)
    };
    for r in &l.themes {
        radio(c, r, r.value == choice.name)
    }
    let theme = themes.iter().find(|th| th.id == choice.name);
    let scheme = choice.scheme.clone().or_else(|| theme.and_then(|th| th.default_scheme.clone()));
    for r in &l.schemes {
        radio(c, r, Some(&r.value) == scheme.as_ref())
    }
    if l.schemes.is_empty()
        && let Some((_, right, baseline)) = l.headings.iter().find(|h| h.0 == "Scheme:")
    {
        c.text_left("Standard — this theme has one look", right + 12.0, *baseline, t.secondary_text, 13.0, Style::Regular, Role::Interface)
    }
    for r in &l.parameters {
        let Some(p) = theme.and_then(|th| th.parameters.iter().find(|p| p.name == r.value)) else { continue };
        let v = dragging.filter(|d| d.0 == r.value).map(|d| d.1).or_else(|| choice.overrides.get(&r.value).copied()).unwrap_or(p.value);
        c.text_left(&r.label, r.hit.x, r.hit.y + 15.0, t.body_text, 13.0, Style::Regular, Role::Interface);
        c.slider(r.control, (v - p.min) / (p.max - p.min).max(1e-9));
        c.text_left(&two_places(v), r.control.x + r.control.w + 10.0, r.hit.y + 15.0, t.secondary_text, 11.0, Style::Regular, Role::Interface)
    }
}

/// The pane: the themes, read as it is shown; the choice, read as drawn.
#[derive(Default)]
pub struct GeneralPane {
    themes: RefCell<Option<Vec<InstalledTheme>>>,
    layout: RefCell<AppearanceLayout>,
    /// A setting dragged, and its value under the pointer: written when the
    /// button comes up, not on every step.
    dragging: RefCell<Option<(String, f64)>>,
    note: RefCell<Option<String>>,
    dumped: RefCell<Option<AppearanceLayout>>,
}

impl GeneralPane {
    fn themes(&self) -> Vec<InstalledTheme> {
        self.themes.borrow_mut().get_or_insert_with(catalogue::installed).clone()
    }

    /// Write a choice where every process reads it, and say so. This window
    /// redraws because its own watch sees the file change, like any other.
    fn choose(&self, h: &Rc<PrefsHost>, hit: &AppearanceHit) {
        let now = catalogue::current();
        let next = next_choice(hit, &now);
        if next == now {
            return;
        }
        match aquadraw::theme::store(&next.name, next.scheme.as_deref(), &next.overrides, None) {
            Ok(()) => {
                *self.note.borrow_mut() = None;
                let params: Vec<String> = next.overrides.iter().map(|(k, v)| format!("{k}={}", two_places(*v))).collect();
                log(&format!("appearance -> {}{}{}", next.name, next.scheme.as_ref().map_or(String::new(), |s| format!(" ({s})")), if params.is_empty() { String::new() } else { format!(" {}", params.join(" ")) }))
            }
            Err(e) => {
                *self.note.borrow_mut() = Some(format!("Could not save the theme: {e}"));
                log(&format!("appearance: could not write appearance.ini: {e}"))
            }
        }
        h.redraw()
    }
}

impl Pane for GeneralPane {
    fn id(&self) -> &'static str {
        "general"
    }
    fn note(&self) -> Option<String> {
        self.note.borrow().clone()
    }
    fn shown(&self, _h: &Rc<PrefsHost>) {
        *self.themes.borrow_mut() = Some(catalogue::installed())
    }
    fn paint(&self, c: &mut Canvas, body: Rect) {
        // Read, not remembered: so a change made elsewhere shows here too.
        let (themes, choice) = (self.themes(), catalogue::current());
        let l = appearance_layout(body, &themes, &choice);
        paint_appearance(c, &l, &themes, &choice, self.dragging.borrow().as_ref());
        *self.layout.borrow_mut() = l;
    }
    /// `theme.<id>` and `scheme.<name>` at the radio, `param.<name>=x0-x1,y`
    /// along the track; they move with the theme chosen.
    fn dump(&self) -> Vec<String> {
        let l = self.layout.borrow().clone();
        if self.dumped.borrow().as_ref() == Some(&l) {
            return vec![];
        }
        let mut line = "appearance".to_string();
        for r in &l.themes {
            line += &format!(" theme.{}={}", r.value, at(&r.control))
        }
        for r in &l.schemes {
            line += &format!(" scheme.{}={}", r.value, at(&r.control))
        }
        for r in &l.parameters {
            line += &format!(" param.{}={}-{},{}", r.value, r.control.x as i64, (r.control.x + r.control.w) as i64, (r.control.y + r.control.h / 2.0) as i64)
        }
        *self.dumped.borrow_mut() = Some(l);
        vec![line]
    }
    fn pointer_moved(&self, h: &Rc<PrefsHost>, x: f64, _y: f64) {
        let Some((name, _)) = self.dragging.borrow().clone() else { return };
        let choice = catalogue::current();
        let l = self.layout.borrow().clone();
        let Some(row) = l.parameters.iter().find(|r| r.value == name) else { return };
        let Some(p) = self.themes().into_iter().find(|t| t.id == choice.name).and_then(|t| t.parameters.into_iter().find(|p| p.name == name)) else { return };
        *self.dragging.borrow_mut() = Some((name, appearance_value(&p, row.control, x)));
        h.redraw()
    }
    fn press(&self, h: &Rc<PrefsHost>, x: f64, y: f64) -> bool {
        let l = self.layout.borrow().clone();
        let Some(hit) = appearance_hit(&l, &self.themes(), &catalogue::current(), x, y) else { return false };
        match hit {
            AppearanceHit::Parameter(name, v) => {
                // Written when the button comes up.
                log(&format!("appearance: dragging {name} from {}", two_places(v)));
                *self.dragging.borrow_mut() = Some((name, v));
                h.redraw()
            }
            hit => self.choose(h, &hit),
        }
        true
    }
    fn release(&self, h: &Rc<PrefsHost>) -> bool {
        let Some((name, v)) = self.dragging.borrow_mut().take() else { return false };
        self.choose(h, &AppearanceHit::Parameter(name, v));
        true
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fixture() -> (String, Vec<InstalledTheme>) {
        let dir = std::env::temp_dir().join(format!("abyss-pane-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        for (id, body) in [("aqua", "[theme]\nname = Aqua\n"), ("zeta", "[theme]\nname = Zeta\ndefault_scheme = dark\n[parameters]\nglow = 0.5 0 1\nwidth = 2 1 4\n[colors.dark]\nmenuHighlight = #000001\n[colors.light]\nmenuHighlight = #000002\n"), ("broken", "[colors]\nmenuHighlite = #000001\n")] {
            std::fs::create_dir_all(dir.join(id)).unwrap();
            std::fs::write(dir.join(id).join("theme.ini"), body).unwrap();
        }
        let d = dir.to_str().unwrap().to_string();
        let t = catalogue::installed_in(std::slice::from_ref(&d));
        (d, t)
    }

    fn choice(name: &str, scheme: Option<&str>, o: &[(&str, f64)]) -> Choice {
        Choice { name: name.into(), scheme: scheme.map(String::from), overrides: o.iter().map(|(k, v)| (k.to_string(), *v)).collect() }
    }

    #[test]
    fn the_catalogue_offers_what_parses_aqua_first_and_every_row_is_hit_where_drawn() {
        let (dir, t) = fixture();
        assert_eq!(t.iter().map(|t| t.id.as_str()).collect::<Vec<_>>(), ["aqua", "zeta"], "a theme that does not parse is not offered");
        assert_eq!((t[1].name.as_str(), t[1].default_scheme.as_deref()), ("Zeta", Some("dark")));
        assert_eq!(t[1].schemes, ["dark", "light"]);
        assert_eq!(t[1].parameters.iter().map(|p| p.name.as_str()).collect::<Vec<_>>(), ["glow", "width"]);
        assert!(t[0].schemes.is_empty());
        let ch = choice("zeta", None, &[]);
        let l = appearance_layout(Rect::new(0.0, 100.0, 760.0, 500.0), &t, &ch);
        assert_eq!(l.schemes.iter().map(|r| r.value.as_str()).collect::<Vec<_>>(), ["dark", "light"]);
        assert_eq!(l.parameters.len(), 2);
        let mid = |r: &Rect| (r.x + r.w / 2.0, r.y + r.h / 2.0);
        for r in &l.themes {
            let (x, y) = mid(&r.control);
            assert_eq!(appearance_hit(&l, &t, &ch, x, y), Some(AppearanceHit::Theme(r.value.clone())))
        }
        for r in &l.schemes {
            let (x, y) = mid(&r.control);
            assert_eq!(appearance_hit(&l, &t, &ch, x, y), Some(AppearanceHit::Scheme(r.value.clone())))
        }
        let rows: Vec<&Row> = l.themes.iter().chain(&l.schemes).chain(&l.parameters).collect();
        for (i, a) in rows.iter().enumerate() {
            for b in &rows[i + 1..] {
                let overlap = a.hit.x < b.hit.x + b.hit.w && b.hit.x < a.hit.x + a.hit.w && a.hit.y < b.hit.y + b.hit.h && b.hit.y < a.hit.y + a.hit.h;
                assert!(!overlap, "{} overlaps {}", a.value, b.value)
            }
        }
        let aqua = appearance_layout(Rect::new(0.0, 100.0, 760.0, 500.0), &t, &choice("aqua", None, &[]));
        assert!(aqua.schemes.is_empty() && aqua.parameters.is_empty());
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn a_slider_spans_its_parameters_bounds() {
        let p = ThemeParameter { name: "width".into(), value: 2.0, min: 1.0, max: 4.0 };
        let tr = Rect::new(100.0, 0.0, 150.0, 20.0);
        assert_eq!([100.0, 250.0, 175.0, 0.0, 999.0].map(|x| appearance_value(&p, tr, x)), [1.0, 4.0, 2.5, 1.0, 4.0]);
    }

    #[test]
    fn a_new_theme_starts_from_its_defaults_and_the_rest_keep_what_was_chosen() {
        let now = choice("zeta", Some("light"), &[("glow", 0.2)]);
        assert_eq!(next_choice(&AppearanceHit::Theme("aqua".into()), &now), choice("aqua", None, &[]));
        assert_eq!(next_choice(&AppearanceHit::Theme("zeta".into()), &now), now);
        assert_eq!(next_choice(&AppearanceHit::Scheme("dark".into()), &now), choice("zeta", Some("dark"), &[("glow", 0.2)]));
        assert_eq!(next_choice(&AppearanceHit::Parameter("width".into(), 2.4567), &now).overrides, choice("", None, &[("glow", 0.2), ("width", 2.46)]).overrides);
    }
}
