//! DrawList.swift's model and parser. The whole vocabulary, except what needs
//! a theme: colour tokens (`bodyText`) and metrics (`@name`) are parse errors
//! here, and a `text` op must say `color=` and `size=` (the theme's bodyText
//! and fontSize are its defaults in Swift).

use crate::color::{parse_double, parse_hex_u32, split_nonempty, theme_color, trim_spaces, Color};
use std::collections::HashMap;
use std::fmt;

#[derive(Debug, Clone, PartialEq)]
pub struct DrawListError {
    pub line: usize,
    pub message: String,
}

impl fmt::Display for DrawListError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "line {}: {}", self.line, self.message)
    }
}

fn err<T>(line: usize, message: impl Into<String>) -> Result<T, DrawListError> {
    Err(DrawListError { line, message: message.into() })
}

/// A widget's state, as a set (DrawState).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Default)]
pub struct DrawState(pub u8);

impl DrawState {
    pub const NORMAL: DrawState = DrawState(0);
    pub const HOVER: DrawState = DrawState(1 << 0);
    pub const PRESSED: DrawState = DrawState(1 << 1);
    pub const DISABLED: DrawState = DrawState(1 << 2);
    pub const FOCUSED: DrawState = DrawState(1 << 3);
    pub const SELECTED: DrawState = DrawState(1 << 4);
    pub const ACTIVE: DrawState = DrawState(1 << 5);

    const NAMES: [(&'static str, DrawState); 7] = [
        ("normal", DrawState::NORMAL),
        ("hover", DrawState::HOVER),
        ("pressed", DrawState::PRESSED),
        ("disabled", DrawState::DISABLED),
        ("focused", DrawState::FOCUSED),
        ("selected", DrawState::SELECTED),
        ("active", DrawState::ACTIVE),
    ];

    pub fn is_empty(self) -> bool {
        self.0 == 0
    }
    pub fn intersects(self, o: DrawState) -> bool {
        self.0 & o.0 != 0
    }
}

/// A type role (Text.Role), in CText's numbering.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Role {
    Interface = 0,
    Chrome = 1,
    Readout = 2,
    Mono = 3,
}

impl Role {
    pub const ALL: [Role; 4] = [Role::Interface, Role::Chrome, Role::Readout, Role::Mono];
    pub fn name(self) -> &'static str {
        match self {
            Role::Interface => "interface",
            Role::Chrome => "chrome",
            Role::Readout => "readout",
            Role::Mono => "mono",
        }
    }
    pub fn named(n: &str) -> Option<Role> {
        Role::ALL.into_iter().find(|r| r.name() == n)
    }
    pub fn from_raw(v: i32) -> Role {
        Role::ALL.into_iter().find(|r| *r as i32 == v).unwrap_or(Role::Interface)
    }
}

#[derive(Clone, Debug, PartialEq)]
pub enum Operand {
    Number(f64),
    Width,
    Height,
    Parameter(String),
    TextWidth(Box<Operand>, i32),
    Negate(Box<Operand>),
    Binary(Box<Operand>, char, Box<Operand>),
    Minimum(Box<Operand>, Box<Operand>),
    Maximum(Box<Operand>, Box<Operand>),
}

#[derive(Clone, Debug, PartialEq)]
pub enum ColorRef {
    Literal(Color),
    Parameter(String),
    Alpha(Box<ColorRef>, f64),
    Shift(Box<ColorRef>, f64),
    Fade(Box<ColorRef>, String),
    Mix(Box<ColorRef>, Box<ColorRef>, f64),
}

pub type Stops = Vec<(f64, ColorRef)>;

#[derive(Clone, Debug)]
pub enum Paint {
    Solid(ColorRef),
    Vertical(Stops),
    Linear(Operand, Operand, Operand, Operand, Stops),
    Radial(Operand, Operand, Operand, Operand, Operand, Operand, Stops),
    Conic(Operand, Operand, Operand, Stops),
    Stripes(f64, Operand, ColorRef, Operand, ColorRef),
    Noise(u32, f64),
    Dots(Operand, Operand, ColorRef),
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Corners {
    All,
    Top,
    Bottom,
}

#[derive(Clone, Debug, PartialEq)]
pub enum Shape {
    Rect(Operand, Operand, Operand, Operand, Option<Operand>, Corners),
    Ellipse(Operand, Operand, Operand, Operand),
    Circle(Operand, Operand, Operand),
    Arc(Operand, Operand, Operand, Operand, Operand),
    Path(Vec<PathSegment>, bool),
}

#[derive(Clone, Debug, PartialEq)]
pub enum PathSegment {
    Move(Operand, Operand),
    Line(Operand, Operand),
    Curve(Operand, Operand, Operand, Operand, Operand, Operand),
    Arc(Operand, Operand, Operand, Operand, Operand),
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum TextAlign {
    Left,
    Center,
    Right,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum RuleKind {
    Across,
    Slant,
}

/// The label stands in for `$label` (Swift's "\u{0}label").
#[derive(Clone, Debug, PartialEq)]
pub enum TextContent {
    Label,
    Literal(String),
}

#[derive(Clone, Debug, PartialEq)]
pub enum Ghost {
    Eights,
    Literal(String),
}

#[derive(Clone, Debug)]
pub struct TextOp {
    pub content: TextContent,
    pub x: Operand,
    pub y: Operand,
    pub align: TextAlign,
    pub baseline: bool,
    pub bold: bool,
    pub upper: bool,
    pub tracking: f64,
    pub size: Operand,
    pub color: ColorRef,
    pub placeholder: Option<ColorRef>,
    pub ghost: Option<Ghost>,
    pub ghost_alpha: f64,
    pub role: Role,
    pub halo: Option<ColorRef>,
    pub halo_radius: Operand,
}

#[derive(Clone, Debug)]
pub enum Op {
    Shape(Shape),
    AndShape(Shape),
    Fill(Paint),
    Stroke(Paint, Operand, bool, Vec<f64>),
    Bevel(Operand, ColorRef, ColorRef),
    InnerShadow(ColorRef, Operand, Option<Operand>),
    Glow(ColorRef, Operand, Operand),
    Shadow(ColorRef, Operand, Operand, Operand),
    Rules(RuleKind, Operand, Operand, Option<Operand>, Paint, Operand),
    Text(Box<TextOp>),
    Push,
    Pop,
    Clip,
    Move(Operand, Operand),
    Rotate(Operand),
    Scale(Operand, Operand),
}

#[derive(Clone, Debug)]
pub struct Step {
    #[allow(dead_code)] // for error reports, as in Swift
    pub line: usize,
    pub when: Option<DrawState>,
    pub unless: Option<DrawState>,
    pub op: Op,
}

#[derive(Clone, Debug)]
#[allow(dead_code)] // name and hotspot: the cursor sheet's, not this scene's
pub struct DrawList {
    pub name: String,
    pub steps: Vec<Step>,
    pub hotspot: Option<(Operand, Operand)>,
}

pub struct DrawListFile {
    pub lists: HashMap<String, DrawList>,
}

impl DrawListFile {
    pub fn parse(text: &str) -> Result<DrawListFile, DrawListError> {
        Ok(DrawListFile { lists: parse(text)? })
    }
    pub fn get(&self, name: &str) -> Option<&DrawList> {
        self.lists.get(name)
    }
}

// MARK: words

fn is_hex_color(s: &str) -> bool {
    let body: String = s.chars().skip(1).collect();
    // split(separator: "/", maxSplits: 1), empty pieces dropped
    let first = body.split('/').find(|p| !p.is_empty());
    let first = match body.split_once('/') {
        Some((a, _)) if !a.is_empty() => Some(a),
        Some((_, b)) => {
            // "/xxxxxx": the first non-empty piece is everything after the slash
            if b.is_empty() { None } else { Some(b) }
        }
        None => first,
    };
    match first {
        Some(h) => h.chars().count() == 6 && parse_hex_u32(h).is_some(),
        None => false,
    }
}

/// Split a line into words, keeping "quoted strings" and (…) groups whole,
/// and dropping a trailing # comment.
fn words(line: &str) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    let mut cur = String::new();
    let mut depth = 0i32;
    let mut quote = false;
    for ch in line.chars() {
        if quote {
            cur.push(ch);
            if ch == '"' {
                quote = false;
            }
            continue;
        }
        match ch {
            '"' => {
                quote = true;
                cur.push(ch)
            }
            '(' => {
                depth += 1;
                cur.push(ch)
            }
            ')' => {
                depth -= 1;
                cur.push(ch)
            }
            ' ' | '\t' => {
                if depth > 0 {
                    cur.push(ch)
                } else if !cur.is_empty() {
                    out.push(std::mem::take(&mut cur));
                }
            }
            _ => cur.push(ch),
        }
    }
    if !cur.is_empty() {
        out.push(cur);
    }
    if let Some(i) = out.iter().position(|w| w.starts_with('#') && !is_hex_color(w)) {
        out.truncate(i);
    }
    out
}

// MARK: the file

fn parse(text: &str) -> Result<HashMap<String, DrawList>, DrawListError> {
    let mut lists: HashMap<String, DrawList> = HashMap::new();
    let mut current: Option<(String, usize, Vec<Step>, Option<(Operand, Operand)>)> = None;
    for (i, raw) in text.split('\n').enumerate() {
        let n = i + 1;
        let mut w = words(raw);
        if w.is_empty() {
            continue;
        }
        if let Some(open) = w.iter().find(|x| x.matches('(').count() != x.matches(')').count()) {
            return err(n, format!("{open}: a ( is not closed"));
        }
        if w[0] == "list" {
            if let Some(c) = &current {
                return err(n, format!("list inside list {} (missing end?)", c.0));
            }
            if !(w.len() == 2 || (w.len() == 5 && w[2] == "hotspot")) {
                return err(n, "want: list <name> [hotspot <x> <y>]");
            }
            if lists.contains_key(&w[1]) {
                return err(n, format!("a second list called {}", w[1]));
            }
            let hot = if w.len() == 5 { Some((operand(&w[3], n)?, operand(&w[4], n)?)) } else { None };
            current = Some((w[1].clone(), n, Vec::new(), hot));
            continue;
        }
        if w[0] == "end" {
            let Some((name, _, steps, hotspot)) = current.take() else {
                return err(n, "end with no list");
            };
            lists.insert(name.clone(), DrawList { name, steps, hotspot });
            continue;
        }
        let Some(cur) = current.as_mut() else {
            return err(n, format!("{} outside a list", w[0]));
        };
        let (mut when, mut unless) = (None, None);
        if w[0] == "when" || w[0] == "unless" {
            if w.len() < 3 {
                return err(n, format!("{} wants states and an op", w[0]));
            }
            let st = states(&w[1], n)?;
            if w[0] == "when" {
                when = Some(st)
            } else {
                unless = Some(st)
            }
            w.drain(0..2);
        }
        let op = parse_op(&w, n)?;
        cur.2.push(Step { line: n, when, unless, op });
    }
    if let Some((name, line, _, _)) = current {
        return err(line, format!("list {name} has no end"));
    }
    Ok(lists)
}

fn states(s: &str, line: usize) -> Result<DrawState, DrawListError> {
    let mut out = DrawState::NORMAL;
    for name in split_nonempty(s, ',') {
        let Some((_, st)) = DrawState::NAMES.iter().find(|(n, _)| *n == name) else {
            return err(line, format!("{name} is not a state (normal hover pressed disabled focused selected active)"));
        };
        out.0 |= st.0;
    }
    Ok(out)
}

// MARK: operands

/// calc()-style arithmetic, recursive descent: + - looser than * /, both
/// left to right, as Swift evaluates the same expression.
pub fn operand(s: &str, line: usize) -> Result<Operand, DrawListError> {
    let mut p = ExprParser { chars: s.chars().collect(), i: 0, line, source: s };
    let e = p.expression()?;
    if p.i != p.chars.len() {
        let rest: String = p.chars[p.i..].iter().collect();
        return Err(p.fail(&format!("unexpected {rest}")));
    }
    Ok(e)
}

fn is_number(c: char) -> bool {
    c.is_numeric()
}

struct ExprParser<'a> {
    chars: Vec<char>,
    i: usize,
    line: usize,
    source: &'a str,
}

impl ExprParser<'_> {
    fn fail(&self, why: &str) -> DrawListError {
        DrawListError { line: self.line, message: format!("{}: {why}", self.source) }
    }
    fn peek(&self) -> Option<char> {
        self.chars.get(self.i).copied()
    }
    fn expression(&mut self) -> Result<Operand, DrawListError> {
        let mut l = self.term()?;
        while let Some(c) = self.peek().filter(|c| *c == '+' || *c == '-') {
            self.i += 1;
            l = Operand::Binary(Box::new(l), c, Box::new(self.term()?));
        }
        Ok(l)
    }
    fn term(&mut self) -> Result<Operand, DrawListError> {
        let mut l = self.factor()?;
        while let Some(c) = self.peek().filter(|c| *c == '*' || *c == '/') {
            self.i += 1;
            l = Operand::Binary(Box::new(l), c, Box::new(self.factor()?));
        }
        Ok(l)
    }
    fn skip_spaces(&mut self) {
        while self.peek() == Some(' ') {
            self.i += 1;
        }
    }
    fn factor(&mut self) -> Result<Operand, DrawListError> {
        let Some(c) = self.peek() else { return Err(self.fail("an operand is missing")) };
        if c == '-' {
            self.i += 1;
            return Ok(Operand::Negate(Box::new(self.factor()?)));
        }
        if c == '(' {
            self.i += 1;
            let e = self.expression()?;
            if self.peek() != Some(')') {
                return Err(self.fail("a ( is not closed"));
            }
            self.i += 1;
            return Ok(e);
        }
        if is_number(c) || c == '.' {
            let start = self.i;
            while self.peek().is_some_and(|d| is_number(d) || d == '.') {
                self.i += 1;
            }
            let t: String = self.chars[start..self.i].iter().collect();
            return match parse_double(&t) {
                Some(v) => Ok(Operand::Number(v)),
                None => Err(self.fail(&format!("{t} is not a number"))),
            };
        }
        if c == '@' || c == '$' {
            self.i += 1;
            let name = self.identifier(c == '@');
            if name.is_empty() {
                return Err(self.fail(&format!("{c} wants a name")));
            }
            if c == '$' {
                return Ok(Operand::Parameter(name));
            }
            return Err(self.fail(&format!("@{name}: metrics need a theme, which this interpreter does not carry")));
        }
        let name = self.identifier(false);
        match name.as_str() {
            "w" => Ok(Operand::Width),
            "h" => Ok(Operand::Height),
            "pi" => Ok(Operand::Number(std::f64::consts::PI)),
            "min" | "max" | "textw" => {
                if self.peek() != Some('(') {
                    return Err(self.fail(&format!("{name} wants (…)")));
                }
                self.i += 1;
                let a = self.expression()?;
                if name == "textw" {
                    let mut role = 0;
                    if self.peek() == Some(',') {
                        self.i += 1;
                        self.skip_spaces();
                        let rn = self.identifier(false);
                        let Some(r) = Role::named(&rn) else {
                            return Err(self.fail(&format!("{rn} is not a role (interface chrome readout mono)")));
                        };
                        role = r as i32;
                    }
                    if self.peek() != Some(')') {
                        return Err(self.fail("want textw(size) or textw(size, role)"));
                    }
                    self.i += 1;
                    return Ok(Operand::TextWidth(Box::new(a), role));
                }
                if self.peek() != Some(',') {
                    return Err(self.fail(&format!("{name} wants two operands")));
                }
                self.i += 1;
                self.skip_spaces();
                let b = self.expression()?;
                if self.peek() != Some(')') {
                    return Err(self.fail(&format!("{name} wants two operands")));
                }
                self.i += 1;
                Ok(if name == "min" {
                    Operand::Minimum(Box::new(a), Box::new(b))
                } else {
                    Operand::Maximum(Box::new(a), Box::new(b))
                })
            }
            "" => Err(self.fail(&format!(
                "{c} is not an operand (a number, w, h, @metric, $parameter, textw, min or max)"
            ))),
            _ => Err(self.fail(&format!(
                "{name} is not an operand (a number, w, h, @metric, $parameter, textw, min or max)"
            ))),
        }
    }
    fn identifier(&mut self, dotted: bool) -> String {
        let start = self.i;
        while self.peek().is_some_and(|d| d.is_alphabetic() || is_number(d) || d == '_' || (dotted && d == '.')) {
            self.i += 1;
        }
        self.chars[start..self.i].iter().collect()
    }
}

// MARK: colours

fn color(s: &str, line: usize) -> Result<ColorRef, DrawListError> {
    let fun = |name: &str| -> Option<Vec<String>> {
        let open = format!("{name}(");
        if !(s.starts_with(&open) && s.ends_with(')')) {
            return None;
        }
        let inner = &s[open.len()..s.len() - 1];
        Some(split_nonempty(inner, ',').into_iter().map(|a| trim_spaces(a).to_string()).collect())
    };
    if let Some(args) = fun("mix") {
        match (args.len() == 3).then(|| parse_double(&args[2])).flatten() {
            Some(t) if (0.0..=1.0).contains(&t) => {
                return Ok(ColorRef::Mix(Box::new(color(&args[0], line)?), Box::new(color(&args[1], line)?), t))
            }
            _ => return err(line, format!("{s}: want mix(colour, colour, 0…1)")),
        }
    }
    if let Some(args) = fun("shift") {
        match (args.len() == 2).then(|| parse_double(&args[1])).flatten() {
            Some(d) if (-1.0..=1.0).contains(&d) => return Ok(ColorRef::Shift(Box::new(color(&args[0], line)?), d)),
            _ => return err(line, format!("{s}: want shift(colour, -1…1)")),
        }
    }
    if let Some(args) = fun("rgb").or_else(|| fun("rgba")) {
        let f: Vec<f64> = args.iter().filter_map(|a| parse_double(a)).collect();
        let want = if s.starts_with("rgba(") { 4 } else { 3 };
        if f.len() != args.len() || f.len() != want || !f.iter().all(|x| (0.0..=1.0).contains(x)) {
            return err(line, format!("{s}: want rgb(r, g, b) or rgba(r, g, b, a), each 0…1"));
        }
        return Ok(ColorRef::Literal(Color::new(f[0], f[1], f[2], if f.len() == 4 { f[3] } else { 1.0 })));
    }
    if let Some(args) = fun("fade") {
        if !(args.len() == 2 && args[1].starts_with('$') && args[1].chars().count() > 1) {
            return err(line, format!("{s}: want fade(colour, $parameter)"));
        }
        return Ok(ColorRef::Fade(Box::new(color(&args[0], line)?), args[1][1..].to_string()));
    }
    if s.starts_with('#') {
        return match theme_color(s) {
            Some(c) => Ok(ColorRef::Literal(c)),
            None => err(line, format!("{s} is not a colour")),
        };
    }
    let (name, alpha) = match s.split_once('/') {
        Some((n, a)) => match parse_double(a) {
            Some(v) if (0.0..=1.0).contains(&v) => (n, Some(v)),
            _ => return err(line, format!("{s}: the alpha after / wants 0…1")),
        },
        None => (s, None),
    };
    let base = if name.starts_with('$') && name.chars().count() > 1 {
        ColorRef::Parameter(name[1..].to_string())
    } else {
        return err(line, format!("{name} is not a colour (colour tokens need a theme, which this interpreter does not carry)"));
    };
    Ok(match alpha {
        Some(a) => ColorRef::Alpha(Box::new(base), a),
        None => base,
    })
}

fn stops(w: &[String], line: usize) -> Result<Stops, DrawListError> {
    if w.first().map(String::as_str) != Some("stops") {
        return err(line, "want: stops <offset> <colour> …");
    }
    let pairs = &w[1..];
    if pairs.len() < 4 || pairs.len() % 2 != 0 {
        return err(line, "stops wants at least two offset/colour pairs");
    }
    let mut out = Vec::new();
    for i in (0..pairs.len()).step_by(2) {
        match parse_double(&pairs[i]) {
            Some(off) if (0.0..=1.0).contains(&off) => out.push((off, color(&pairs[i + 1], line)?)),
            _ => return err(line, format!("{} is not a stop offset (0…1)", pairs[i])),
        }
    }
    Ok(out)
}

// MARK: paints

/// A paint at the head of `a`, and how many words it took.
fn paint(a: &[String], line: usize) -> Result<(Paint, usize), DrawListError> {
    let Some(head) = a.first() else { return err(line, "want a paint") };
    let need = |k: usize| -> Result<(), DrawListError> {
        if a.len() < k {
            err(line, format!("{head} wants {} arguments", k - 1))
        } else {
            Ok(())
        }
    };
    let stops_at = a.iter().position(|x| x == "stops");
    let o = |i: usize| operand(&a[i], line);
    match head.as_str() {
        "vertical" => {
            if stops_at != Some(1) {
                return err(line, "want: vertical stops …");
            }
            Ok((Paint::Vertical(stops(&a[1..], line)?), a.len()))
        }
        "linear" => {
            if stops_at != Some(5) {
                return err(line, "want: linear x0 y0 x1 y1 stops …");
            }
            let st = stops(&a[5..], line)?;
            Ok((Paint::Linear(o(1)?, o(2)?, o(3)?, o(4)?, st), a.len()))
        }
        "radial" => {
            if stops_at == Some(4) {
                let st = stops(&a[4..], line)?;
                let cx = o(1)?;
                let cy = o(2)?;
                return Ok((Paint::Radial(cx.clone(), cy.clone(), Operand::Number(0.0), cx, cy, o(3)?, st), a.len()));
            }
            if stops_at != Some(7) {
                return err(line, "want: radial cx cy r stops … or radial x0 y0 r0 x1 y1 r1 stops …");
            }
            let v = (1..=6).map(o).collect::<Result<Vec<_>, _>>()?;
            let st = stops(&a[7..], line)?;
            let mut it = v.into_iter();
            let mut n = || it.next().unwrap();
            Ok((Paint::Radial(n(), n(), n(), n(), n(), n(), st), a.len()))
        }
        "conic" => {
            if stops_at != Some(4) {
                return err(line, "want: conic cx cy r stops …");
            }
            let st = stops(&a[4..], line)?;
            Ok((Paint::Conic(o(1)?, o(2)?, o(3)?, st), a.len()))
        }
        "stripes" => {
            need(6)?;
            let Some(ang) = parse_double(&a[1]) else { return err(line, "stripes wants an angle in degrees") };
            Ok((Paint::Stripes(ang, o(2)?, color(&a[3], line)?, o(4)?, color(&a[5], line)?), 6))
        }
        "dots" => {
            need(4)?;
            Ok((Paint::Dots(o(1)?, o(2)?, color(&a[3], line)?), 4))
        }
        "noise" => {
            need(3)?;
            match (a[1].parse::<u32>().ok(), parse_double(&a[2])) {
                (Some(seed), Some(al)) if (0.0..=1.0).contains(&al) => Ok((Paint::Noise(seed, al), 3)),
                _ => err(line, "noise wants a seed and an alpha 0…1"),
            }
        }
        _ => Ok((Paint::Solid(color(head, line)?), 1)),
    }
}

// MARK: ops

fn parse_op(w: &[String], line: usize) -> Result<Op, DrawListError> {
    if w[0] == "and" {
        if w.len() >= 2 {
            if let Op::Shape(sh) = parse_op(&w[1..], line)? {
                return Ok(Op::AndShape(sh));
            }
        }
        return err(line, "and wants a shape (rect ellipse circle path)");
    }
    let name = w[0].as_str();
    let args = &w[1..];
    let o = |i: usize| operand(&args[i], line);
    match name {
        "rect" => {
            if args.len() < 4 || args.len() > 6 {
                return err(line, "want: rect x y w h [radius [top|bottom]]");
            }
            let mut corners = Corners::All;
            if args.len() == 6 {
                corners = match args[5].as_str() {
                    "top" => Corners::Top,
                    "bottom" => Corners::Bottom,
                    "all" => Corners::All,
                    other => return err(line, format!("{other} is not top, bottom or all")),
                };
            }
            let r = if args.len() >= 5 { Some(o(4)?) } else { None };
            Ok(Op::Shape(Shape::Rect(o(0)?, o(1)?, o(2)?, o(3)?, r, corners)))
        }
        "ellipse" => {
            if args.len() != 4 {
                return err(line, "want: ellipse x y w h");
            }
            Ok(Op::Shape(Shape::Ellipse(o(0)?, o(1)?, o(2)?, o(3)?)))
        }
        "circle" => {
            if args.len() != 3 {
                return err(line, "want: circle cx cy r");
            }
            Ok(Op::Shape(Shape::Circle(o(0)?, o(1)?, o(2)?)))
        }
        "arc" => {
            if args.len() != 5 {
                return err(line, "want: arc cx cy r from to");
            }
            Ok(Op::Shape(Shape::Arc(o(0)?, o(1)?, o(2)?, o(3)?, o(4)?)))
        }
        "path" => {
            let closed = args.last().map(String::as_str) == Some("close");
            let a = if closed { &args[..args.len() - 1] } else { args };
            let usage = "want: path x y, then x y, curve x1 y1 x2 y2 x y or arc cx cy r from to …, [close]";
            let mut segs: Vec<PathSegment> = Vec::new();
            let mut i = 0;
            let op = |k: usize| operand(&a[k], line);
            while i < a.len() {
                if a[i] == "arc" {
                    if i + 6 > a.len() {
                        return err(line, usage);
                    }
                    segs.push(PathSegment::Arc(op(i + 1)?, op(i + 2)?, op(i + 3)?, op(i + 4)?, op(i + 5)?));
                    i += 6;
                } else if a[i] == "curve" {
                    if segs.is_empty() || i + 7 > a.len() {
                        return err(line, usage);
                    }
                    segs.push(PathSegment::Curve(op(i + 1)?, op(i + 2)?, op(i + 3)?, op(i + 4)?, op(i + 5)?, op(i + 6)?));
                    i += 7;
                } else {
                    if i + 1 >= a.len() {
                        return err(line, usage);
                    }
                    let x = op(i)?;
                    let y = op(i + 1)?;
                    segs.push(if segs.is_empty() { PathSegment::Move(x, y) } else { PathSegment::Line(x, y) });
                    i += 2;
                }
            }
            if !(segs.len() >= 2 || segs.iter().any(|s| matches!(s, PathSegment::Arc(..)))) {
                return err(line, usage);
            }
            Ok(Op::Shape(Shape::Path(segs, closed)))
        }
        "fill" => {
            let (p, used) = paint(args, line)?;
            if used != args.len() {
                return err(line, format!("fill: unexpected {}", args[used..].join(" ")));
            }
            Ok(Op::Fill(p))
        }
        "stroke" => {
            let mut a: Vec<String> = args.to_vec();
            let (mut round, mut dash) = (false, Vec::new());
            while let Some(last) = a.last().filter(|l| *l == "round" || l.starts_with("dash=")).cloned() {
                if last == "round" {
                    round = true;
                } else {
                    let d: Vec<f64> = split_nonempty(&last[5..], ',').into_iter().filter_map(parse_double).collect();
                    if d.is_empty() || !d.iter().all(|x| *x >= 0.0) || !d.iter().any(|x| *x > 0.0) {
                        return err(line, format!("{last}: want dash=on,off,… in pixels"));
                    }
                    dash = d;
                }
                a.pop();
            }
            if a.len() < 2 {
                return err(line, "want: stroke <paint> <width> [round] [dash=on,off]");
            }
            let (p, used) = paint(&a[..a.len() - 1], line)?;
            if used != a.len() - 1 {
                return err(line, "stroke: unexpected arguments");
            }
            Ok(Op::Stroke(p, operand(a.last().unwrap(), line)?, round, dash))
        }
        "bevel" => {
            if args.len() != 3 {
                return err(line, "want: bevel <width> <light> <shade>");
            }
            Ok(Op::Bevel(o(0)?, color(&args[1], line)?, color(&args[2], line)?))
        }
        "innershadow" => {
            if !(args.len() == 2 || args.len() == 3) {
                return err(line, "want: innershadow <colour> <size> [extent]");
            }
            let c = color(&args[0], line)?;
            let ext = if args.len() == 3 { Some(o(2)?) } else { None };
            Ok(Op::InnerShadow(c, o(1)?, ext))
        }
        "glow" => {
            if !(args.len() == 2 || args.len() == 3) {
                return err(line, "want: glow <colour> <radius> [strength]");
            }
            if args.len() == 3 {
                if let Some(s) = parse_double(&args[2]) {
                    if !(0.0..=4.0).contains(&s) {
                        return err(line, "glow strength wants 0…4");
                    }
                }
            }
            let c = color(&args[0], line)?;
            let st = if args.len() == 3 { o(2)? } else { Operand::Number(1.0) };
            Ok(Op::Glow(c, o(1)?, st))
        }
        "shadow" => {
            if args.len() != 4 {
                return err(line, "want: shadow <colour> <dx> <dy> <blur>");
            }
            Ok(Op::Shadow(color(&args[0], line)?, o(1)?, o(2)?, o(3)?))
        }
        "rules" => {
            let kind = match args.first().map(String::as_str) {
                Some("across") => RuleKind::Across,
                Some("slant") => RuleKind::Slant,
                _ => {
                    return err(
                        line,
                        "want: rules across FROM EVERY PAINT WIDTH, or rules slant FROM EVERY UNTIL PAINT WIDTH",
                    )
                }
            };
            let fixed = if kind == RuleKind::Across { 3 } else { 4 };
            if args.len() < fixed + 2 {
                return err(line, format!("rules {} wants a paint and a width", args[0]));
            }
            let (p, used) = paint(&args[fixed..args.len() - 1], line)?;
            if fixed + used != args.len() - 1 {
                return err(line, "rules: unexpected arguments");
            }
            let until = if kind == RuleKind::Slant { Some(o(3)?) } else { None };
            Ok(Op::Rules(kind, o(1)?, o(2)?, until, p, operand(args.last().unwrap(), line)?))
        }
        "text" => parse_text(args, line),
        "move" => {
            if args.len() != 2 {
                return err(line, "want: move dx dy");
            }
            Ok(Op::Move(o(0)?, o(1)?))
        }
        "rotate" => {
            if args.len() != 1 {
                return err(line, "want: rotate radians");
            }
            Ok(Op::Rotate(o(0)?))
        }
        "scale" => {
            if args.len() != 2 {
                return err(line, "want: scale sx sy");
            }
            Ok(Op::Scale(o(0)?, o(1)?))
        }
        "push" => Ok(Op::Push),
        "pop" => Ok(Op::Pop),
        "clip" => Ok(Op::Clip),
        _ => err(
            line,
            format!("{name} is not an op (rect ellipse circle arc path fill stroke bevel innershadow glow shadow rules text push pop clip move rotate scale)"),
        ),
    }
}

fn quoted(v: &str) -> Option<String> {
    if v.starts_with('"') && v.ends_with('"') && v.chars().count() >= 2 {
        Some(v[1..v.len() - 1].to_string())
    } else {
        None
    }
}

fn parse_text(args: &[String], line: usize) -> Result<Op, DrawListError> {
    if args.len() < 3 {
        return err(line, "want: text <\"string\"|$label> x y [options]");
    }
    let content = if let Some(q) = quoted(&args[0]) {
        TextContent::Literal(q)
    } else if args[0] == "$label" {
        TextContent::Label
    } else {
        return err(line, "text wants a \"quoted string\" or $label");
    };
    let mut t = TextOp {
        content,
        x: operand(&args[1], line)?,
        y: operand(&args[2], line)?,
        align: TextAlign::Left,
        baseline: false,
        bold: false,
        upper: false,
        tracking: 0.0,
        size: Operand::Number(0.0),
        color: ColorRef::Literal(Color::new(0.0, 0.0, 0.0, 0.0)),
        placeholder: None,
        ghost: None,
        ghost_alpha: 0.13,
        role: Role::Interface,
        halo: None,
        halo_radius: Operand::Number(6.0),
    };
    let (mut has_size, mut has_color) = (false, false);
    for opt in &args[3..] {
        match opt.as_str() {
            "left" => t.align = TextAlign::Left,
            "center" => t.align = TextAlign::Center,
            "right" => t.align = TextAlign::Right,
            "baseline" => t.baseline = true,
            "bold" => t.bold = true,
            "upper" => t.upper = true,
            _ => {
                let Some((k, v)) = opt.split_once('=') else {
                    return err(line, format!("{opt} is not a text option"));
                };
                match k {
                    "tracking" => match parse_double(v) {
                        Some(n) => t.tracking = n,
                        None => return err(line, "tracking wants a number"),
                    },
                    "size" => {
                        t.size = operand(v, line)?;
                        has_size = true
                    }
                    "color" => {
                        t.color = color(v, line)?;
                        has_color = true
                    }
                    "placeholder" => t.placeholder = Some(color(v, line)?),
                    "ghost" => {
                        if v == "eights" {
                            t.ghost = Some(Ghost::Eights)
                        } else if let Some(q) = quoted(v) {
                            t.ghost = Some(Ghost::Literal(q))
                        } else {
                            return err(line, "ghost wants a \"quoted string\" or eights");
                        }
                    }
                    "ghostalpha" => match parse_double(v) {
                        Some(a) if (0.0..=1.0).contains(&a) => t.ghost_alpha = a,
                        _ => return err(line, "ghostalpha wants 0…1"),
                    },
                    "halo" => t.halo = Some(color(v, line)?),
                    "halor" => t.halo_radius = operand(v, line)?,
                    "role" => match Role::named(v) {
                        Some(r) => t.role = r,
                        None => return err(line, format!("{v} is not a role (interface chrome readout mono)")),
                    },
                    _ => return err(line, format!("{k} is not a text option")),
                }
            }
        }
    }
    if !has_color {
        return err(line, "text without color= draws in the theme's bodyText, and this interpreter carries no theme");
    }
    if !has_size {
        return err(line, "text without size= draws at the theme's fontSize, and this interpreter carries no theme");
    }
    Ok(Op::Text(Box::new(t)))
}
