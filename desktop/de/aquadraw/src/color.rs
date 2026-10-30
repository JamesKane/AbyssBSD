//! Color (Theme.swift) and the reached parts of ThemeLoader.swift: hex
//! parsing and the OKLCH mix.

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Color {
    pub r: f64,
    pub g: f64,
    pub b: f64,
    pub a: f64,
}

impl Color {
    pub const fn new(r: f64, g: f64, b: f64, a: f64) -> Color {
        Color { r, g, b, a }
    }
    /// Color(hex:a:).
    pub fn hex(hex: u32, a: f64) -> Color {
        Color::new(
            ((hex >> 16) & 0xff) as f64 / 255.0,
            ((hex >> 8) & 0xff) as f64 / 255.0,
            (hex & 0xff) as f64 / 255.0,
            a,
        )
    }
    pub fn with_a(self, a: f64) -> Color {
        Color::new(self.r, self.g, self.b, a)
    }
}

/// Swift's `trimmingSpaces`: spaces and tabs off both ends.
pub fn trim_spaces(s: &str) -> &str {
    s.trim_matches(|c| c == ' ' || c == '\t')
}

/// Swift `split(separator:)`: empty pieces are dropped.
pub fn split_nonempty(s: &str, sep: char) -> Vec<&str> {
    s.split(sep).filter(|p| !p.is_empty()).collect()
}

/// `UInt32(s, radix: 16)`.
pub fn parse_hex_u32(s: &str) -> Option<u32> {
    u32::from_str_radix(s, 16).ok()
}

/// Swift `Double(String)`: the whole string a number.
pub fn parse_double(s: &str) -> Option<f64> {
    if s.is_empty() || s.contains(|c: char| c.is_whitespace()) {
        return None;
    }
    s.parse::<f64>().ok()
}

/// ThemeLoader.color with a lookup that knows no names (as DrawList calls it).
pub fn theme_color(s: &str) -> Option<Color> {
    let v = trim_spaces(s);
    if v.starts_with("mix(") && v.ends_with(')') {
        let inner = &v[4..v.len() - 1];
        let args: Vec<&str> = split_nonempty(inner, ',').into_iter().map(trim_spaces).collect();
        if args.len() != 3 {
            return None;
        }
        let f = parse_double(args[2])?;
        if !(0.0..=1.0).contains(&f) {
            return None;
        }
        let a = theme_color(args[0])?;
        let b = theme_color(args[1])?;
        return Some(mix_oklch(a, b, f));
    }
    if let Some(body) = v.strip_prefix('#') {
        let parts: Vec<&str> = split_nonempty(body, '/').into_iter().map(trim_spaces).collect();
        let hexs = *parts.first()?;
        if hexs.chars().count() != 6 {
            return None;
        }
        let hex = parse_hex_u32(hexs)?;
        if parts.len() == 1 {
            return Some(Color::hex(hex, 1.0));
        }
        if parts.len() != 2 {
            return None;
        }
        let a = parse_double(parts[1])?;
        if !(0.0..=1.0).contains(&a) {
            return None;
        }
        return Some(Color::hex(hex, a));
    }
    let words = split_nonempty(v, ' ');
    let f: Vec<f64> = words.iter().filter_map(|w| parse_double(w)).collect();
    if !(f.len() == 3 || f.len() == 4) || !f.iter().all(|x| (0.0..=1.0).contains(x)) || words.len() != f.len() {
        return None;
    }
    Some(Color::new(f[0], f[1], f[2], if f.len() == 4 { f[3] } else { 1.0 }))
}

// MARK: OKLCH (ThemeLoader.mixOKLCH, same operation order)

pub fn mix_oklch(a: Color, b: Color, t: f64) -> Color {
    let (la, ca, ha) = oklch(a);
    let (lb, cb, hb) = oklch(b);
    let mut h1 = ha;
    let mut h2 = hb;
    if ca < 1e-4 {
        h1 = hb;
    }
    if cb < 1e-4 {
        h2 = h1;
    }
    let mut dh = h2 - h1;
    if dh > std::f64::consts::PI {
        dh -= 2.0 * std::f64::consts::PI;
    } else if dh < -std::f64::consts::PI {
        dh += 2.0 * std::f64::consts::PI;
    }
    let l = la + (lb - la) * t;
    let c = ca + (cb - ca) * t;
    let h = h1 + dh * t;
    let (r, g, bl) = srgb_from_oklab(l, c * h.cos(), c * h.sin());
    Color::new(r, g, bl, a.a + (b.a - a.a) * t)
}

fn lin(x: f64) -> f64 {
    if x <= 0.04045 {
        x / 12.92
    } else {
        ((x + 0.055) / 1.055).powf(2.4)
    }
}

fn gam(x: f64) -> f64 {
    let y = if x <= 0.0031308 { 12.92 * x } else { 1.055 * x.powf(1.0 / 2.4) - 0.055 };
    y.max(0.0).min(1.0)
}

fn oklch(c: Color) -> (f64, f64, f64) {
    let r = lin(c.r);
    let g = lin(c.g);
    let b = lin(c.b);
    let l = (0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b).cbrt();
    let m = (0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b).cbrt();
    let s = (0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b).cbrt();
    let ll = 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s;
    let aa = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s;
    let bb = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s;
    (ll, (aa * aa + bb * bb).sqrt(), bb.atan2(aa))
}

fn srgb_from_oklab(l0: f64, a: f64, b: f64) -> (f64, f64, f64) {
    let l = (l0 + 0.3963377774 * a + 0.2158037573 * b).powf(3.0);
    let m = (l0 - 0.1055613458 * a - 0.0638541728 * b).powf(3.0);
    let s = (l0 - 0.0894841775 * a - 1.2914855480 * b).powf(3.0);
    (
        gam(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s),
        gam(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s),
        gam(-0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s),
    )
}
