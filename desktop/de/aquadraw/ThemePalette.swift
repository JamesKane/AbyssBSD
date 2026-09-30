// ThemePalette — what a foreign toolkit is told about the look (P11.10).
//
// GTK draws its own widgets; what they can be told is a colour scheme,
// an accent, a contrast preference — `org.freedesktop.appearance`, through the
// portal's Settings (P8.3) — and, for anything that asks, a palette. Until now
// the portal said Aqua's answer in literals whatever the theme was. This makes
// the answer from the theme that is loaded, in the one shape the portal reads.
//
// The portal does not link the toolkit (cairo, FreeType, HarfBuzz), so it is
// handed this as text: `abyss-theme palette` prints it, and abyss-dbus reads
// it at start (de/dbusportal/Settings.swift, `PortalSettings.from`).

public enum ThemePalette {
    /// The palette of `t`, as INI text. `name` and `scheme` are for the record.
    public static func ini(_ t: ThemeTokens, name: String, scheme: String?) -> String {
        func rgb(_ c: Color) -> String {
            let o = Legibility.over(c, Legibility.over(t.contentBackground, Color(0, 0, 0, 1)))
            return "\(r4(o.r)) \(r4(o.g)) \(r4(o.b))"
        }
        let window = Legibility.over(t.contentBackground, Color(0, 0, 0, 1))
        // Dark when the window's own background is darker than mid-grey.
        let dark = Legibility.luminance(window) < 0.18
        // High contrast only when every body pair clears WCAG AAA's 7:1 — a
        // measurement, not a scheme's name.
        let high = Legibility.minimumBodyRatio(t) >= 7
        var s = "# The palette of the loaded theme (P11.10), for the portal.\n"
        s += "[theme]\nname = \(name)\n" + (scheme.map { "scheme = \($0)\n" } ?? "")
        s += "\n[appearance]\n"
        s += "color-scheme = \(dark ? 1 : 2)\n"      // 1 prefer dark, 2 prefer light
        s += "accent-color = \(rgb(t.menuHighlight))\n"
        s += "contrast = \(high ? 1 : 0)\n"
        s += "\n[palette]\n"
        for (k, c) in [("window-background", t.contentBackground), ("window-foreground", t.bodyText),
                       ("view-background", t.listBackground), ("view-foreground", t.bodyText),
                       ("selected-background", t.menuHighlight), ("selected-foreground", t.menuTextOnHighlight),
                       ("headerbar-background", t.titleBarBottom), ("headerbar-foreground", t.titleText),
                       ("button-background", t.buttonWhiteBottom), ("button-foreground", t.buttonTextOnWhite),
                       ("border", t.windowBorder), ("focus", t.glowFocus),
                       ("secondary-foreground", t.secondaryText), ("alert", t.alert)] {
            s += "\(k) = \(rgb(c))\n"
        }
        return s
    }

    static func r4(_ v: Double) -> String {
        let n = Int((max(0, min(1, v)) * 10000).rounded())
        return n == 10000 ? "1" : n == 0 ? "0" : "0." + String(repeating: "0", count: 4 - String(n).count) + String(n)
    }
}

extension Legibility {
    /// The lowest body-text contrast among the pairs the toolkit draws.
    public static func minimumBodyRatio(_ t: ThemeTokens) -> Double {
        let key = Dictionary(uniqueKeysWithValues: ThemeTokens.colorKeys)
        let window = over(t.contentBackground, Color(0, 0, 0, 1))
        var lo = 21.0
        for (fg, surfaces, weight) in pairs where weight == .body {
            guard let fk = key[fg] else { continue }
            for sName in surfaces {
                guard let sk = key[sName] else { continue }
                let surface = over(t[keyPath: sk], window)
                lo = min(lo, ratio(over(t[keyPath: fk], surface), surface))
            }
        }
        return lo
    }
}
