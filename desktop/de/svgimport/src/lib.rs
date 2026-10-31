//! SVGImport: vector artwork into a draw list, at build time (PHASE11
//! P11.8), ported from SVGImport.swift beside it.
//!
//! A theme's icons are draw lists; an artist's are SVG. This turns the second
//! into the first **once, when the theme is made**, so no process on the
//! desktop ever parses SVG (PHASE11 §6.3, §4.4: an SVG renderer is a large
//! parser of theme-supplied files living in the process that holds your
//! windows — the surface PRODUCT §8.3 rejects).
//!
//! A deliberately small subset, and strict about it: anything outside it is
//! refused by name rather than approximated, because an icon that imported
//! "mostly" looks right in the file and wrong on the desktop.
//!
//! ```text
//!   elements   svg (viewBox), g, path, rect (rx), circle, ellipse, line,
//!              polyline, polygon, defs, linearGradient, stop; title, desc and
//!              metadata are skipped
//!   path d     M L H V C S Q T A Z, absolute and relative — Q, T and A are
//!              converted to cubic curves
//!   paint      fill, stroke, stroke-width, fill-opacity, stroke-opacity,
//!              opacity (attributes or style="…"), #rgb, #rrggbb, rgb(), none,
//!              url(#gradient) for a linearGradient (userSpaceOnUse or the
//!              object's bounding box)
//!   transform  translate() scale() rotate() skewX() skewY() matrix() — all
//!              affine, applied to the points (curves transform exactly)
//!   gradients  linearGradient and radialGradient (centre and radius; a focal
//!              point is not read)
//! ```
//!
//! Coordinates come out as fractions of the list's rect — `w*0.25 h*0.5` — so
//! the icon draws at any size.
//!
//! Where the Swift traps or hangs, this refuses instead: a number too large
//! (or not a number) to write, a transform whose `)` comes before its `(`,
//! and numbers after a `Z` with no command. The root `<svg>`'s own
//! presentation attributes and transform apply to its children (the Swift
//! skipped them), and `\r\n` is whitespace like `\r` and `\n`.

use std::cell::Cell;
use std::collections::HashMap;
use std::f64::consts::PI;
use std::fmt;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SvgImportError {
    pub message: String,
}

impl fmt::Display for SvgImportError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.message)
    }
}

impl std::error::Error for SvgImportError {}

type Result<T> = std::result::Result<T, SvgImportError>;

fn err(m: impl Into<String>) -> SvgImportError {
    SvgImportError { message: m.into() }
}

/// Convert `svg` into a draw list called `name`.
pub fn draw_list(name: &str, svg: &str) -> Result<String> {
    let mut p = XmlReader { b: svg.as_bytes(), i: 0 };
    let root = p.document()?;
    if root.name != "svg" {
        return Err(err(format!("the document is <{}>, not <svg>", root.name)));
    }
    let mut c = Converter::default();
    c.run(&root)?;
    if let Some(v) = c.unwritable.get() {
        return Err(err(format!("{v:?} is a number the draw-list format cannot write")));
    }
    let body: Vec<String> = c.lines.iter().map(|l| format!("  {l}")).collect();
    Ok(format!("list {name}\n{}\nend\n", body.join("\n")))
}

// MARK: - Swift's semantics, where Rust's differ

/// Swift's `min(x, y)`: `y < x ? y : x`.
fn smin(x: f64, y: f64) -> f64 {
    if y < x { y } else { x }
}

/// Swift's `max(x, y)`: `y >= x ? y : x`.
fn smax(x: f64, y: f64) -> f64 {
    if y >= x { y } else { x }
}

/// `Sequence.min()` on a non-empty slice.
fn seq_min(v: &[f64]) -> f64 {
    v[1..].iter().fold(v[0], |r, &e| if e < r { e } else { r })
}

/// `Sequence.max()` on a non-empty slice.
fn seq_max(v: &[f64]) -> f64 {
    v[1..].iter().fold(v[0], |r, &e| if r < e { e } else { r })
}

/// Swift's `Double(String)`: strtod in the C locale, which must take the
/// whole string — no surrounding space, but `inf`, `nan`, `nan(…)` and hex
/// floats (`0x1.8p3`) as well as decimals.
fn swift_double(s: &str) -> Option<f64> {
    if s.is_empty() {
        return None;
    }
    if let Ok(v) = s.parse::<f64>() {
        return Some(v);
    }
    let (neg, rest) = match s.as_bytes()[0] {
        b'-' => (true, &s[1..]),
        b'+' => (false, &s[1..]),
        _ => (false, s),
    };
    let lower = rest.to_ascii_lowercase();
    if let Some(inner) = lower.strip_prefix("nan(").and_then(|r| r.strip_suffix(')')) {
        if inner.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_') {
            return Some(f64::NAN);
        }
        return None;
    }
    let v = hex_double(lower.strip_prefix("0x")?)?;
    Some(if neg { -v } else { v })
}

/// The part of a hex float after `0x`, lower-cased.
fn hex_double(h: &str) -> Option<f64> {
    let b = h.as_bytes();
    let mut i = 0;
    let (mut m, mut exp, mut sticky, mut digits, mut dot) = (0u64, 0i64, false, 0, false);
    while i < b.len() {
        let c = b[i];
        if c == b'.' && !dot {
            dot = true;
        } else if let Some(d) = (c as char).to_digit(16) {
            digits += 1;
            if m < 1 << 60 {
                m = m * 16 + d as u64;
                if dot {
                    exp -= 4;
                }
            } else {
                sticky |= d != 0;
                if !dot {
                    exp += 4;
                }
            }
        } else {
            break;
        }
        i += 1;
    }
    if digits == 0 {
        return None;
    }
    if i < b.len() {
        if b[i] != b'p' {
            return None;
        }
        i += 1;
        let neg = match b.get(i) {
            Some(b'-') => {
                i += 1;
                true
            }
            Some(b'+') => {
                i += 1;
                false
            }
            _ => false,
        };
        let e = &h[i..];
        if e.is_empty() || !e.bytes().all(|c| c.is_ascii_digit()) {
            return None;
        }
        let e: i64 = e.parse().unwrap_or(i64::MAX / 4).min(1 << 20);
        exp += if neg { -e } else { e };
    }
    // A lost low digit only has to break a tie, and bit 0 of 61+ bits does.
    let mut v = (m | sticky as u64) as f64;
    while exp > 1000 {
        v *= 2f64.powi(1000);
        exp -= 1000;
    }
    while exp < -1000 {
        v *= 2f64.powi(-1000);
        exp += 1000;
    }
    Some(v * 2f64.powi(exp as i32))
}

/// String.trimmed: spaces, tabs, newlines and returns off both ends.
fn trimmed(s: &str) -> &str {
    s.trim_matches(|c| matches!(c, ' ' | '\t' | '\n' | '\r'))
}

/// `s.split(separator: sep, maxSplits: 1)`, which omits empty pieces — and
/// an omitted one does not count as the split.
fn split_once_nonempty(s: &str, sep: char) -> Vec<&str> {
    let mut out = Vec::new();
    let mut start = 0;
    for (i, c) in s.char_indices() {
        if c == sep {
            if i > start {
                out.push(&s[start..i]);
            }
            start = i + c.len_utf8();
            if out.len() == 1 {
                break;
            }
        }
    }
    if start < s.len() {
        out.push(&s[start..]);
    }
    out
}

// MARK: - XML, enough of it

struct Element {
    name: String,
    attrs: HashMap<String, String>,
    children: Vec<Element>,
}

struct XmlReader<'a> {
    b: &'a [u8],
    i: usize,
}

fn is_space(c: u8) -> bool {
    matches!(c, b' ' | b'\t' | b'\n' | b'\r')
}

impl XmlReader<'_> {
    fn fail(&self, m: &str) -> SvgImportError {
        err(format!("XML: {m} (at byte {})", self.i))
    }

    fn at(&self, s: &str) -> bool {
        self.b[self.i.min(self.b.len())..].starts_with(s.as_bytes())
    }

    fn skip_until(&mut self, s: &str) -> Result<()> {
        while self.i < self.b.len() && !self.at(s) {
            self.i += 1;
        }
        if !self.at(s) {
            return Err(self.fail(&format!("unterminated {s}")));
        }
        self.i += s.len();
        Ok(())
    }

    fn space(&mut self) {
        while self.i < self.b.len() && is_space(self.b[self.i]) {
            self.i += 1;
        }
    }

    fn misc(&mut self) -> Result<()> {
        loop {
            self.space();
            if self.at("<?") {
                self.skip_until("?>")?;
            } else if self.at("<!--") {
                self.skip_until("-->")?;
            } else if self.at("<!") {
                self.skip_until(">")?;
            } else {
                return Ok(());
            }
        }
    }

    fn name(&mut self) -> String {
        let s = self.i;
        while self.i < self.b.len() && !(is_space(self.b[self.i]) || matches!(self.b[self.i], b'/' | b'>' | b'=')) {
            self.i += 1;
        }
        String::from_utf8_lossy(&self.b[s..self.i]).into_owned()
    }

    fn document(&mut self) -> Result<Element> {
        self.misc()?;
        self.element()
    }

    fn element(&mut self) -> Result<Element> {
        if !self.at("<") {
            return Err(self.fail("expected <"));
        }
        self.i += 1;
        let mut e = Element { name: self.name(), attrs: HashMap::new(), children: vec![] };
        loop {
            self.space();
            if self.at("/>") {
                self.i += 2;
                return Ok(e);
            }
            if self.at(">") {
                self.i += 1;
                break;
            }
            let k = self.name();
            if k.is_empty() {
                return Err(self.fail(&format!("bad attribute in <{}>", e.name)));
            }
            self.space();
            if !self.at("=") {
                return Err(self.fail(&format!("attribute {k} has no value")));
            }
            self.i += 1;
            self.space();
            if !(self.i < self.b.len() && (self.b[self.i] == b'"' || self.b[self.i] == b'\'')) {
                return Err(self.fail(&format!("attribute {k} is not quoted")));
            }
            let q = self.b[self.i];
            self.i += 1;
            let s = self.i;
            while self.i < self.b.len() && self.b[self.i] != q {
                self.i += 1;
            }
            if self.i >= self.b.len() {
                return Err(self.fail(&format!("unterminated attribute {k}")));
            }
            e.attrs.insert(k, unescape(&String::from_utf8_lossy(&self.b[s..self.i])));
            self.i += 1;
        }
        loop {
            while self.i < self.b.len() && self.b[self.i] != b'<' {
                self.i += 1; // text content is ignored
            }
            if self.at("<!--") {
                self.skip_until("-->")?;
                continue;
            }
            if self.at("<![CDATA[") {
                self.skip_until("]]>")?;
                continue;
            }
            if self.at("</") {
                self.i += 2;
                let n = self.name();
                if n != e.name {
                    return Err(self.fail(&format!("</{n}> closes <{}>", e.name)));
                }
                self.space();
                if !self.at(">") {
                    return Err(self.fail(&format!("bad </{n}>")));
                }
                self.i += 1;
                return Ok(e);
            }
            if self.i >= self.b.len() {
                return Err(self.fail(&format!("<{}> is not closed", e.name)));
            }
            let child = self.element()?;
            e.children.push(child);
        }
    }
}

fn unescape(s: &str) -> String {
    s.replace("&lt;", "<").replace("&gt;", ">").replace("&quot;", "\"").replace("&apos;", "'").replace("&amp;", "&")
}

// MARK: - Conversion

#[derive(Clone, Copy)]
struct Rgba {
    r: f64,
    g: f64,
    b: f64,
    a: f64,
}

const BLACK: Rgba = Rgba { r: 0.0, g: 0.0, b: 0.0, a: 1.0 };

#[derive(Clone)]
enum PaintSpec {
    None,
    Color(Rgba),
    Gradient(String),
}

#[derive(Clone)]
struct Style {
    fill: PaintSpec,
    stroke: PaintSpec,
    stroke_width: f64,
    fill_opacity: f64,
    stroke_opacity: f64,
    opacity: f64,
    round: bool, // stroke-linejoin / -linecap round
    dash: Vec<f64>,
}

impl Default for Style {
    fn default() -> Style {
        Style {
            fill: PaintSpec::Color(BLACK), // SVG's default fill is black
            stroke: PaintSpec::None,
            stroke_width: 1.0,
            fill_opacity: 1.0,
            stroke_opacity: 1.0,
            opacity: 1.0,
            round: false,
            dash: vec![],
        }
    }
}

/// A 2-D affine transform, as SVG writes it: x' = a x + c y + e, y' = b x + d y + f.
#[derive(Clone, Copy)]
struct Affine {
    a: f64,
    b: f64,
    c: f64,
    d: f64,
    e: f64,
    f: f64,
}

const IDENTITY: Affine = Affine { a: 1.0, b: 0.0, c: 0.0, d: 1.0, e: 0.0, f: 0.0 };

impl Affine {
    fn apply(&self, x: f64, y: f64) -> (f64, f64) {
        (self.a * x + self.c * y + self.e, self.b * x + self.d * y + self.f)
    }
    /// self applied first, then m
    fn then(&self, m: &Affine) -> Affine {
        Affine {
            a: m.a * self.a + m.c * self.b,
            b: m.b * self.a + m.d * self.b,
            c: m.a * self.c + m.c * self.d,
            d: m.b * self.c + m.d * self.d,
            e: m.a * self.e + m.c * self.f + m.e,
            f: m.b * self.e + m.d * self.f + m.f,
        }
    }
    fn scale(&self) -> f64 {
        (self.a * self.d - self.b * self.c).abs().sqrt()
    }
    fn translate(e: f64, f: f64) -> Affine {
        Affine { e, f, ..IDENTITY }
    }
}

struct Gradient {
    x1: f64,
    y1: f64,
    x2: f64,
    y2: f64,
    radial: bool,
    cx: f64,
    cy: f64,
    r: f64,
    user_space: bool,
    stops: Vec<(f64, Rgba)>,
}

#[derive(Clone, Copy)]
enum Seg {
    Move(f64, f64),
    Line(f64, f64),
    Curve(f64, f64, f64, f64, f64, f64),
    Close,
}

#[derive(Clone, Copy)]
struct ViewBox {
    x: f64,
    y: f64,
    w: f64,
    h: f64,
}

#[derive(Clone, Copy)]
struct BBox {
    x: f64,
    y: f64,
    w: f64,
    h: f64,
}

struct Converter {
    lines: Vec<String>,
    vb: ViewBox,
    gradients: HashMap<String, Gradient>,
    /// The first number `fmt` could not write (the Swift traps on it).
    unwritable: Cell<Option<f64>>,
}

impl Default for Converter {
    fn default() -> Converter {
        Converter {
            lines: vec![],
            vb: ViewBox { x: 0.0, y: 0.0, w: 1.0, h: 1.0 },
            gradients: HashMap::new(),
            unwritable: Cell::new(None),
        }
    }
}

/// Presentation attributes and `style="k: v; …"`, merged (style wins).
fn style_attrs(e: &Element) -> HashMap<String, String> {
    let mut out = e.attrs.clone();
    if let Some(s) = e.attrs.get("style") {
        for decl in s.split(';').filter(|d| !d.is_empty()) {
            let kv = split_once_nonempty(decl, ':');
            if kv.len() == 2 {
                out.insert(trimmed(kv[0]).to_string(), trimmed(kv[1]).to_string());
            }
        }
    }
    out
}

/// A number, or a percentage of one: `50%` is 0.5.
fn fraction(v: &str) -> Option<f64> {
    match v.strip_suffix('%') {
        Some(p) => swift_double(p).map(|d| d / 100.0),
        None => swift_double(v),
    }
}

fn length(v: &str) -> Option<f64> {
    let s = trimmed(v);
    swift_double(s.strip_suffix("px").unwrap_or(s))
}

fn num(e: &Element, k: &str) -> f64 {
    e.attrs.get(k).and_then(|v| length(v)).unwrap_or(0.0)
}

fn color(v: &str) -> Option<Rgba> {
    let s = trimmed(v);
    if let Some(h) = s.strip_prefix('#') {
        let h: Vec<char> = h.chars().collect();
        let hex: Vec<char> = if h.len() == 3 { h.iter().flat_map(|&c| [c, c]).collect() } else { h };
        // Hex digits only: the Swift's UInt32(_:radix:) took a sign, so
        // `#+12345` and `#-00000` were colours.
        if hex.len() != 6 || !hex.iter().all(char::is_ascii_hexdigit) {
            return None;
        }
        let n = u32::from_str_radix(&hex.iter().collect::<String>(), 16).ok()?;
        return Some(Rgba {
            r: ((n >> 16) & 0xff) as f64 / 255.0,
            g: ((n >> 8) & 0xff) as f64 / 255.0,
            b: (n & 0xff) as f64 / 255.0,
            a: 1.0,
        });
    }
    if let Some(inner) = s.strip_prefix("rgb(").and_then(|r| r.strip_suffix(')')) {
        let n: Vec<f64> = inner.split(',').filter(|p| !p.is_empty()).filter_map(|p| swift_double(trimmed(p))).collect();
        if n.len() != 3 {
            return None;
        }
        return Some(Rgba { r: n[0] / 255.0, g: n[1] / 255.0, b: n[2] / 255.0, a: 1.0 });
    }
    match s {
        "black" => Some(BLACK),
        "white" => Some(Rgba { r: 1.0, g: 1.0, b: 1.0, a: 1.0 }),
        _ => None,
    }
}

fn paint(v: &str) -> Result<PaintSpec> {
    let s = trimmed(v);
    if s == "none" {
        return Ok(PaintSpec::None);
    }
    if s.starts_with("url(#") && s.ends_with(')') {
        return Ok(PaintSpec::Gradient(s[5..s.len() - 1].to_string()));
    }
    match color(s) {
        Some(c) => Ok(PaintSpec::Color(c)),
        None => Err(err(format!("{s} is not a colour svg2dl reads (#rgb #rrggbb rgb() none url(#id))"))),
    }
}

fn transform(t: &str) -> Result<Affine> {
    let mut m = IDENTITY;
    let mut rest = trimmed(t);
    while !rest.is_empty() {
        let (Some(open), Some(close)) = (rest.find('('), rest.find(')')) else {
            return Err(err(format!("transform=\"{t}\" is not understood")));
        };
        if close < open {
            return Err(err(format!("transform=\"{t}\" is not understood")));
        }
        let fn_name = trimmed(&rest[..open]);
        let n = numbers(&rest[open + 1..close]);
        let first = n.first().copied();
        let step = match fn_name {
            "translate" => Affine::translate(first.unwrap_or(0.0), if n.len() > 1 { n[1] } else { 0.0 }),
            "scale" => Affine {
                a: first.unwrap_or(1.0),
                d: if n.len() > 1 { n[1] } else { first.unwrap_or(1.0) },
                ..IDENTITY
            },
            "rotate" => {
                let a = first.unwrap_or(0.0) * PI / 180.0;
                let (c, sn) = (a.cos(), a.sin());
                let r = Affine { a: c, b: sn, c: -sn, d: c, ..IDENTITY };
                if n.len() == 3 {
                    // about (cx, cy)
                    Affine::translate(-n[1], -n[2]).then(&r).then(&Affine::translate(n[1], n[2]))
                } else {
                    r
                }
            }
            "skewX" => Affine { c: (first.unwrap_or(0.0) * PI / 180.0).tan(), ..IDENTITY },
            "skewY" => Affine { b: (first.unwrap_or(0.0) * PI / 180.0).tan(), ..IDENTITY },
            "matrix" => {
                if n.len() != 6 {
                    return Err(err("matrix() wants six numbers"));
                }
                Affine { a: n[0], b: n[1], c: n[2], d: n[3], e: n[4], f: n[5] }
            }
            _ => {
                return Err(err(format!(
                    "transform {fn_name}() is not in the subset (translate, scale, rotate, skewX, skewY, matrix)"
                )));
            }
        };
        m = step.then(&m); // listed left to right, applied right to left
        rest = rest[close + 1..].trim_start_matches([' ', ',']);
    }
    Ok(m)
}

impl Converter {
    fn run(&mut self, root: &Element) -> Result<()> {
        if let Some(v) = root.attrs.get("viewBox") {
            let n = numbers(v);
            if !(n.len() == 4 && n[2] > 0.0 && n[3] > 0.0) {
                return Err(err(format!("viewBox=\"{v}\" is not four numbers with a size")));
            }
            self.vb = ViewBox { x: n[0], y: n[1], w: n[2], h: n[3] };
        } else if let (Some(w), Some(h)) =
            (root.attrs.get("width").and_then(|v| length(v)), root.attrs.get("height").and_then(|v| length(v)))
            && w > 0.0
            && h > 0.0
        {
            self.vb = ViewBox { x: 0.0, y: 0.0, w, h };
        } else {
            return Err(err("<svg> has neither a viewBox nor a width and height"));
        }
        self.collect_gradients(root);
        // The root itself, so its fill, stroke and transform reach its
        // children (the Swift walked only the children).
        self.walk(std::slice::from_ref(root), &Style::default(), &IDENTITY)
    }

    fn collect_gradients(&mut self, e: &Element) {
        for c in &e.children {
            if (c.name == "linearGradient" || c.name == "radialGradient")
                && let Some(id) = c.attrs.get("id")
            {
                let coord = |k: &str, d: f64| -> f64 {
                    let Some(v) = c.attrs.get(k) else { return d };
                    match v.strip_suffix('%') {
                        Some(p) => swift_double(p).unwrap_or(d * 100.0) / 100.0,
                        None => swift_double(v).unwrap_or(d),
                    }
                };
                let mut g = Gradient {
                    x1: coord("x1", 0.0),
                    y1: coord("y1", 0.0),
                    x2: coord("x2", 1.0),
                    y2: coord("y2", 0.0),
                    radial: c.name == "radialGradient",
                    cx: coord("cx", 0.5),
                    cy: coord("cy", 0.5),
                    r: coord("r", 0.5),
                    user_space: c.attrs.get("gradientUnits").map(String::as_str) == Some("userSpaceOnUse"),
                    stops: vec![],
                };
                for s in c.children.iter().filter(|s| s.name == "stop") {
                    let st = style_attrs(s);
                    let off = s.attrs.get("offset").map(|v| fraction(v).unwrap_or(0.0)).unwrap_or(0.0);
                    let col = st.get("stop-color").and_then(|v| color(v)).unwrap_or(BLACK);
                    let op = st.get("stop-opacity").and_then(|v| swift_double(v)).unwrap_or(1.0);
                    g.stops.push((smin(1.0, smax(0.0, off)), Rgba { a: col.a * op, ..col }));
                }
                self.gradients.insert(id.clone(), g);
            }
            self.collect_gradients(c);
        }
    }

    fn walk(&mut self, els: &[Element], parent: &Style, parent_m: &Affine) -> Result<()> {
        for e in els {
            if matches!(e.name.as_str(), "title" | "desc" | "metadata" | "defs" | "linearGradient" | "radialGradient") {
                continue;
            }
            let mut st = parent.clone();
            let a = style_attrs(e);
            if a.get("fill-rule").map(String::as_str) == Some("evenodd") {
                return Err(err(format!("<{}> fill-rule=evenodd: the draw-list format fills nonzero only", e.name)));
            }
            if let Some(v) = a.get("fill") {
                st.fill = paint(v)?;
            }
            if let Some(v) = a.get("stroke") {
                st.stroke = paint(v)?;
            }
            if let Some(v) = a.get("stroke-width") {
                st.stroke_width = length(v).unwrap_or(st.stroke_width);
            }
            if let Some(v) = a.get("fill-opacity").and_then(|v| swift_double(v)) {
                st.fill_opacity = v;
            }
            if let Some(v) = a.get("stroke-opacity").and_then(|v| swift_double(v)) {
                st.stroke_opacity = v;
            }
            if let Some(v) = a.get("opacity").and_then(|v| swift_double(v)) {
                st.opacity *= v;
            }
            if let Some(v) = a.get("stroke-linejoin") {
                st.round = v == "round" || st.round;
            }
            if let Some(v) = a.get("stroke-linecap") {
                st.round = v == "round" || st.round;
            }
            if let Some(v) = a.get("stroke-dasharray") {
                st.dash = numbers(v);
            }
            let mut m = *parent_m;
            if let Some(t) = e.attrs.get("transform") {
                m = transform(t)?.then(parent_m);
            }
            match e.name.as_str() {
                "g" | "svg" => self.walk(&e.children, &st, &m)?,
                "path" => {
                    let Some(d) = e.attrs.get("d") else { return Err(err("<path> with no d")) };
                    let segs = PathParser::new(d).parse()?;
                    self.emit(&segs, &st, &m, true)?;
                }
                "rect" => {
                    let (x, y, w, h) = (num(e, "x"), num(e, "y"), num(e, "width"), num(e, "height"));
                    let mut rx = e
                        .attrs
                        .get("rx")
                        .and_then(|v| length(v))
                        .or_else(|| e.attrs.get("ry").and_then(|v| length(v)))
                        .unwrap_or(0.0);
                    rx = smin(smin(rx, w / 2.0), h / 2.0);
                    if rx > 0.0 {
                        // A rounded rect as four arcs' worth of curves, so a
                        // transform applies to it like any other path.
                        let k = 0.5522847498 * rx;
                        let s = [
                            Seg::Move(x + rx, y),
                            Seg::Line(x + w - rx, y),
                            Seg::Curve(x + w - rx + k, y, x + w, y + rx - k, x + w, y + rx),
                            Seg::Line(x + w, y + h - rx),
                            Seg::Curve(x + w, y + h - rx + k, x + w - rx + k, y + h, x + w - rx, y + h),
                            Seg::Line(x + rx, y + h),
                            Seg::Curve(x + rx - k, y + h, x, y + h - rx + k, x, y + h - rx),
                            Seg::Line(x, y + rx),
                            Seg::Curve(x, y + rx - k, x + rx - k, y, x + rx, y),
                            Seg::Close,
                        ];
                        self.emit(&s, &st, &m, true)?;
                    } else {
                        let s =
                            [Seg::Move(x, y), Seg::Line(x + w, y), Seg::Line(x + w, y + h), Seg::Line(x, y + h), Seg::Close];
                        self.emit(&s, &st, &m, true)?;
                    }
                }
                "circle" | "ellipse" => {
                    let (cx, cy) = (num(e, "cx"), num(e, "cy"));
                    let rx = if e.name == "circle" { num(e, "r") } else { num(e, "rx") };
                    let ry = if e.name == "circle" { rx } else { num(e, "ry") };
                    let k = 0.5522847498;
                    let s = [
                        Seg::Move(cx + rx, cy),
                        Seg::Curve(cx + rx, cy + k * ry, cx + k * rx, cy + ry, cx, cy + ry),
                        Seg::Curve(cx - k * rx, cy + ry, cx - rx, cy + k * ry, cx - rx, cy),
                        Seg::Curve(cx - rx, cy - k * ry, cx - k * rx, cy - ry, cx, cy - ry),
                        Seg::Curve(cx + k * rx, cy - ry, cx + rx, cy - k * ry, cx + rx, cy),
                        Seg::Close,
                    ];
                    self.emit(&s, &st, &m, true)?;
                }
                "line" => {
                    let s = [Seg::Move(num(e, "x1"), num(e, "y1")), Seg::Line(num(e, "x2"), num(e, "y2"))];
                    self.emit(&s, &st, &m, false)?;
                }
                "polyline" | "polygon" => {
                    let n = numbers(e.attrs.get("points").map(String::as_str).unwrap_or(""));
                    if !(n.len() >= 4 && n.len().is_multiple_of(2)) {
                        return Err(err(format!("<{}> points is not pairs", e.name)));
                    }
                    let mut s = vec![Seg::Move(n[0], n[1])];
                    s.extend(n[2..].chunks(2).map(|p| Seg::Line(p[0], p[1])));
                    let polygon = e.name == "polygon";
                    if polygon {
                        s.push(Seg::Close);
                    }
                    self.emit(&s, &st, &m, polygon)?;
                }
                _ => {
                    return Err(err(format!(
                        "<{}> is not in the subset svg2dl imports (svg g path rect circle ellipse line polyline polygon linearGradient)",
                        e.name
                    )));
                }
            }
        }
        Ok(())
    }

    // MARK: output

    /// Five decimals, trailing zeros dropped, never exponent notation (the
    /// draw-list grammar reads plain decimals).
    fn fmt(&self, v: f64) -> String {
        let r = (v.abs() * 100_000.0).round();
        // Int64(r) traps in the Swift: refuse it, at the end, instead.
        if r.is_nan() || r >= 9_223_372_036_854_775_808.0 {
            if self.unwritable.get().is_none() {
                self.unwritable.set(Some(v));
            }
            return "0".to_string();
        }
        let scaled = r as i64;
        if scaled == 0 {
            return "0".to_string();
        }
        let (ip, fp) = (scaled / 100_000, scaled % 100_000);
        let frac = format!("{fp:05}");
        let frac = frac.trim_end_matches('0');
        format!("{}{ip}{}{frac}", if v < 0.0 { "-" } else { "" }, if frac.is_empty() { "" } else { "." })
    }

    fn px(&self, x: f64) -> String {
        format!("w*{}", self.fmt((x - self.vb.x) / self.vb.w))
    }

    fn py(&self, y: f64) -> String {
        format!("h*{}", self.fmt((y - self.vb.y) / self.vb.h))
    }

    fn colour(&self, c: Rgba, alpha: f64) -> String {
        format!(
            "rgba({}, {}, {}, {})",
            self.fmt(c.r),
            self.fmt(c.g),
            self.fmt(c.b),
            self.fmt(smin(1.0, smax(0.0, c.a * alpha)))
        )
    }

    fn emit(&mut self, segs: &[Seg], st: &Style, m: &Affine, fill: bool) -> Result<()> {
        // Transform, and split into subpaths.
        let mut subs: Vec<Vec<Seg>> = vec![];
        let (mut xs, mut ys): (Vec<f64>, Vec<f64>) = (vec![], vec![]);
        for s in segs {
            match *s {
                Seg::Move(x, y) => {
                    let (a, b) = m.apply(x, y);
                    xs.push(a);
                    ys.push(b);
                    subs.push(vec![Seg::Move(a, b)]);
                }
                Seg::Line(x, y) => {
                    let (a, b) = m.apply(x, y);
                    xs.push(a);
                    ys.push(b);
                    if subs.is_empty() {
                        subs.push(vec![]);
                    }
                    subs.last_mut().unwrap().push(Seg::Line(a, b));
                }
                Seg::Curve(x1, y1, x2, y2, x, y) => {
                    let (p1, p2, p) = (m.apply(x1, y1), m.apply(x2, y2), m.apply(x, y));
                    xs.extend([p1.0, p2.0, p.0]);
                    ys.extend([p1.1, p2.1, p.1]);
                    if subs.is_empty() {
                        subs.push(vec![]);
                    }
                    subs.last_mut().unwrap().push(Seg::Curve(p1.0, p1.1, p2.0, p2.1, p.0, p.1));
                }
                Seg::Close => {
                    if let Some(last) = subs.last_mut() {
                        last.push(Seg::Close);
                    }
                }
            }
        }
        subs.retain(|s| s.len() >= 2);
        if subs.is_empty() {
            return Ok(());
        }
        for (i, sub) in subs.iter().enumerate() {
            let mut words: Vec<String> = vec![if i == 0 { "path" } else { "and path" }.to_string()];
            let mut closed = false;
            for s in sub {
                match *s {
                    Seg::Move(x, y) | Seg::Line(x, y) => words.extend([self.px(x), self.py(y)]),
                    Seg::Curve(x1, y1, x2, y2, x, y) => words.extend([
                        "curve".to_string(),
                        self.px(x1),
                        self.py(y1),
                        self.px(x2),
                        self.py(y2),
                        self.px(x),
                        self.py(y),
                    ]),
                    Seg::Close => closed = true,
                }
            }
            if closed {
                words.push("close".to_string());
            }
            self.lines.push(words.join(" "));
        }
        let (minx, miny) = (seq_min(&xs), seq_min(&ys));
        let bbox = BBox { x: minx, y: miny, w: seq_max(&xs) - minx, h: seq_max(&ys) - miny };
        if fill && let Some(f) = self.paint_words(&st.fill, st.fill_opacity * st.opacity, bbox, m)? {
            self.lines.push(format!("fill {f}"));
        }
        if let Some(s) = self.paint_words(&st.stroke, st.stroke_opacity * st.opacity, bbox, m)? {
            let mut line = format!("stroke {s} w*{}", self.fmt(st.stroke_width * m.scale() / self.vb.w));
            if st.round {
                line += " round";
            }
            if !st.dash.is_empty() {
                // Dashes are in the SVG's units; the list's are points at the
                // drawn size, which svg2dl cannot know — so they are written at
                // the viewBox's own scale (a 64-unit icon drawn at 64 pt).
                let d: Vec<String> = st.dash.iter().map(|v| self.fmt(v * m.scale())).collect();
                line += &format!(" dash={}", d.join(","));
            }
            self.lines.push(line);
        }
        Ok(())
    }

    fn paint_words(&self, p: &PaintSpec, alpha: f64, bbox: BBox, m: &Affine) -> Result<Option<String>> {
        let id = match p {
            PaintSpec::None => return Ok(None),
            PaintSpec::Color(c) => return Ok(Some(self.colour(*c, alpha))),
            PaintSpec::Gradient(id) => id,
        };
        let Some(g) = self.gradients.get(id) else {
            return Err(err(format!("url(#{id}): no linearGradient with that id")));
        };
        if g.stops.len() < 2 {
            return Err(err(format!("url(#{id}): a gradient wants two stops")));
        }
        let stops: Vec<String> = g.stops.iter().map(|(o, c)| format!("{} {}", self.fmt(*o), self.colour(*c, alpha))).collect();
        let stops = stops.join(" ");
        if g.radial {
            let (mut cx, mut cy, mut r) = (g.cx, g.cy, g.r);
            if g.user_space {
                (cx, cy) = m.apply(cx, cy);
                r *= m.scale();
            } else {
                cx = bbox.x + cx * bbox.w;
                cy = bbox.y + cy * bbox.h;
                r *= smax(bbox.w, bbox.h);
            }
            return Ok(Some(format!(
                "radial {} {} w*{} stops {stops}",
                self.px(cx),
                self.py(cy),
                self.fmt(r / self.vb.w)
            )));
        }
        let ((x1, y1), (x2, y2)) = if g.user_space {
            (m.apply(g.x1, g.y1), m.apply(g.x2, g.y2))
        } else {
            (
                (bbox.x + g.x1 * bbox.w, bbox.y + g.y1 * bbox.h),
                (bbox.x + g.x2 * bbox.w, bbox.y + g.y2 * bbox.h),
            )
        };
        Ok(Some(format!("linear {} {} {} {} stops {stops}", self.px(x1), self.py(y1), self.px(x2), self.py(y2))))
    }
}

/// Every number in a list like `0 0 10,10` or `1-2.5.5e3`.
fn numbers(s: &str) -> Vec<f64> {
    let mut out = vec![];
    let mut cur = String::new();
    let flush = |cur: &mut String, out: &mut Vec<f64>| {
        if let Some(d) = swift_double(cur) {
            out.push(d);
        }
        cur.clear();
    };
    for ch in s.chars() {
        if ch == '-' && !cur.is_empty() && !cur.ends_with('e') {
            flush(&mut cur, &mut out);
        }
        if ch.is_numeric() || matches!(ch, '.' | '-' | 'e' | '+') {
            if ch == '.' && cur.contains('.') && !cur.contains('e') {
                flush(&mut cur, &mut out);
            }
            cur.push(ch);
        } else {
            flush(&mut cur, &mut out);
        }
    }
    flush(&mut cur, &mut out);
    out
}

// MARK: - Path data

struct PathParser {
    c: Vec<char>,
    i: usize,
}

impl PathParser {
    fn new(d: &str) -> PathParser {
        PathParser { c: d.chars().collect(), i: 0 }
    }

    fn fail(&self, m: &str) -> SvgImportError {
        err(format!("path d: {m}"))
    }

    fn skip(&mut self) {
        while self.i < self.c.len() && matches!(self.c[self.i], ' ' | ',' | '\n' | '\t' | '\r') {
            self.i += 1;
        }
    }

    fn sign_at(&self, i: usize) -> bool {
        i < self.c.len() && (self.c[i] == '-' || self.c[i] == '+')
    }

    fn number(&mut self) -> Result<f64> {
        self.skip();
        let s = self.i;
        if self.sign_at(self.i) {
            self.i += 1;
        }
        let (mut dot, mut exp) = (false, false);
        while self.i < self.c.len() {
            let ch = self.c[self.i];
            if ch.is_numeric() {
                self.i += 1;
            } else if ch == '.' && !dot && !exp {
                dot = true;
                self.i += 1;
            } else if (ch == 'e' || ch == 'E') && !exp {
                exp = true;
                self.i += 1;
                if self.sign_at(self.i) {
                    self.i += 1;
                }
            } else {
                break;
            }
        }
        let text: String = self.c[s..self.i].iter().collect();
        match swift_double(&text) {
            Some(d) if self.i > s => Ok(d),
            _ => Err(self.fail(&format!("expected a number at {s}"))),
        }
    }

    fn flag(&mut self) -> Result<bool> {
        self.skip();
        if !(self.i < self.c.len() && (self.c[self.i] == '0' || self.c[self.i] == '1')) {
            return Err(self.fail(&format!("expected an arc flag at {}", self.i)));
        }
        self.i += 1;
        Ok(self.c[self.i - 1] == '1')
    }

    fn more_numbers(&mut self) -> bool {
        self.skip();
        self.i < self.c.len() && {
            let ch = self.c[self.i];
            ch.is_numeric() || matches!(ch, '-' | '+' | '.')
        }
    }

    fn pt(&mut self, rel: bool, x: f64, y: f64) -> Result<(f64, f64)> {
        let a = self.number()?;
        let b = self.number()?;
        Ok(if rel { (x + a, y + b) } else { (a, b) })
    }

    fn parse(&mut self) -> Result<Vec<Seg>> {
        let mut out = vec![];
        let (mut x, mut y, mut sx, mut sy) = (0.0, 0.0, 0.0, 0.0);
        let mut last_ctrl: Option<(f64, f64)> = None;
        let mut last_q: Option<(f64, f64)> = None;
        let mut cmd = ' ';
        loop {
            self.skip();
            if self.i >= self.c.len() {
                break;
            }
            if self.c[self.i].is_alphabetic() {
                cmd = self.c[self.i];
                self.i += 1;
            } else if cmd == ' ' || cmd == 'Z' || cmd == 'z' {
                // After a Z, numbers with no command: the Swift looped there
                // for ever.
                return Err(self.fail(&format!("expected a command at {}", self.i)));
            }
            let rel = cmd.is_lowercase();
            let up = cmd.to_ascii_uppercase();
            match up {
                'M' => {
                    let p = self.pt(rel, x, y)?;
                    (x, y) = p;
                    (sx, sy) = (x, y);
                    out.push(Seg::Move(x, y));
                    cmd = if rel { 'l' } else { 'L' }; // further pairs are line-tos
                    last_ctrl = None;
                    last_q = None;
                    continue;
                }
                'L' => {
                    (x, y) = self.pt(rel, x, y)?;
                    out.push(Seg::Line(x, y));
                    last_ctrl = None;
                    last_q = None;
                }
                'H' => {
                    let a = self.number()?;
                    x = if rel { x + a } else { a };
                    out.push(Seg::Line(x, y));
                    last_ctrl = None;
                    last_q = None;
                }
                'V' => {
                    let a = self.number()?;
                    y = if rel { y + a } else { a };
                    out.push(Seg::Line(x, y));
                    last_ctrl = None;
                    last_q = None;
                }
                'C' => {
                    let p1 = self.pt(rel, x, y)?;
                    let p2 = self.pt(rel, x, y)?;
                    let p = self.pt(rel, x, y)?;
                    out.push(Seg::Curve(p1.0, p1.1, p2.0, p2.1, p.0, p.1));
                    last_ctrl = Some(p2);
                    last_q = None;
                    (x, y) = p;
                }
                'S' => {
                    let p1 = last_ctrl.map(|c| (2.0 * x - c.0, 2.0 * y - c.1)).unwrap_or((x, y));
                    let p2 = self.pt(rel, x, y)?;
                    let p = self.pt(rel, x, y)?;
                    out.push(Seg::Curve(p1.0, p1.1, p2.0, p2.1, p.0, p.1));
                    last_ctrl = Some(p2);
                    last_q = None;
                    (x, y) = p;
                }
                'Q' | 'T' => {
                    let q = if up == 'Q' {
                        self.pt(rel, x, y)?
                    } else {
                        last_q.map(|c| (2.0 * x - c.0, 2.0 * y - c.1)).unwrap_or((x, y))
                    };
                    let p = self.pt(rel, x, y)?;
                    // A quadratic is a cubic with its controls two thirds of the way.
                    out.push(Seg::Curve(
                        x + 2.0 / 3.0 * (q.0 - x),
                        y + 2.0 / 3.0 * (q.1 - y),
                        p.0 + 2.0 / 3.0 * (q.0 - p.0),
                        p.1 + 2.0 / 3.0 * (q.1 - p.1),
                        p.0,
                        p.1,
                    ));
                    last_q = Some(q);
                    last_ctrl = None;
                    (x, y) = p;
                }
                'A' => {
                    let rx = self.number()?.abs();
                    let ry = self.number()?.abs();
                    let rot = self.number()?;
                    let large = self.flag()?;
                    let sweep = self.flag()?;
                    let p = self.pt(rel, x, y)?;
                    out.extend(arc(x, y, rx, ry, rot, large, sweep, p.0, p.1));
                    last_ctrl = None;
                    last_q = None;
                    (x, y) = p;
                }
                'Z' => {
                    out.push(Seg::Close);
                    (x, y) = (sx, sy);
                    last_ctrl = None;
                    last_q = None;
                    continue;
                }
                _ => return Err(self.fail(&format!("{cmd} is not a path command"))),
            }
            self.more_numbers();
        }
        Ok(out)
    }
}

/// An elliptical arc as cubic curves (SVG 1.1 §F.6.5: endpoint to centre
/// parameterisation, then quarter-turn-or-less pieces).
#[allow(clippy::too_many_arguments)]
fn arc(x1: f64, y1: f64, rx_in: f64, ry_in: f64, rot_deg: f64, large: bool, sweep: bool, x2: f64, y2: f64) -> Vec<Seg> {
    if rx_in == 0.0 || ry_in == 0.0 || (x1 == x2 && y1 == y2) {
        return vec![Seg::Line(x2, y2)];
    }
    let (mut rx, mut ry) = (rx_in, ry_in);
    let phi = rot_deg * PI / 180.0;
    let (cp, sp) = (phi.cos(), phi.sin());
    let (dx, dy) = ((x1 - x2) / 2.0, (y1 - y2) / 2.0);
    let (x1p, y1p) = (cp * dx + sp * dy, -sp * dx + cp * dy);
    let lam = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry);
    if lam > 1.0 {
        rx *= lam.sqrt();
        ry *= lam.sqrt();
    }
    let num = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p;
    let den = rx * rx * y1p * y1p + ry * ry * x1p * x1p;
    let mut co = (smax(0.0, num) / den).sqrt();
    if large == sweep {
        co = -co;
    }
    let (cxp, cyp) = (co * rx * y1p / ry, -co * ry * x1p / rx);
    let (cx, cy) = (cp * cxp - sp * cyp + (x1 + x2) / 2.0, sp * cxp + cp * cyp + (y1 + y2) / 2.0);
    let ang = |ux: f64, uy: f64, vx: f64, vy: f64| (ux * vy - uy * vx).atan2(ux * vx + uy * vy);
    let t1 = ang(1.0, 0.0, (x1p - cxp) / rx, (y1p - cyp) / ry);
    let mut dt = ang((x1p - cxp) / rx, (y1p - cyp) / ry, (-x1p - cxp) / rx, (-y1p - cyp) / ry);
    if !sweep && dt > 0.0 {
        dt -= 2.0 * PI;
    } else if sweep && dt < 0.0 {
        dt += 2.0 * PI;
    }
    let n = ((dt.abs() / (PI / 2.0)).ceil() as i64).max(1);
    let step = dt / n as f64;
    let k = 4.0 / 3.0 * (step / 4.0).tan();
    let point = |t: f64| (cx + rx * t.cos() * cp - ry * t.sin() * sp, cy + rx * t.cos() * sp + ry * t.sin() * cp);
    let deriv = |t: f64| (-rx * t.sin() * cp - ry * t.cos() * sp, -rx * t.sin() * sp + ry * t.cos() * cp);
    let mut out = vec![];
    let mut t = t1;
    for _ in 0..n {
        let (a, da, b, db) = (point(t), deriv(t), point(t + step), deriv(t + step));
        out.push(Seg::Curve(a.0 + k * da.0, a.1 + k * da.1, b.0 - k * db.0, b.1 - k * db.1, b.0, b.1));
        t += step;
    }
    out
}

#[cfg(test)]
mod tests;
