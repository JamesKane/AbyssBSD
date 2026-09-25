// Legibility — the floor a theme may not go below (PHASE11 P11.10, PRODUCT §8.4).
//
// A theme is data a person can write, and a person can write one nobody can
// read. The floor is checked **when the theme is loaded**, in every scheme, on
// the pairs the toolkit actually draws — which text token sits on which
// surface is the toolkit's knowledge, so it is a table here, not a guess from
// the lists — and a failure is said in words: the pair, both colours, the
// ratio and the bar.
//
// PHASE11 §6.2 (pending confirmation with the rest of §6):
//   - **body** text under WCAG AA's 4.5:1 on its surface **refuses** the theme;
//   - **secondary** text (dim labels, placeholders, disabled items) under 3:1
//     is a **warning** — shown, never swallowed;
//   - a control a pointer cannot hit (a gadget under 12 pt, a menu or list row
//     under 16) refuses the theme.
//
// Translucent colours are composited before they are measured: a foreground
// over its surface, and a surface over the window's background
// (`contentBackground`) when it is itself translucent — which is what the eye
// is shown.

public enum Legibility {
    public enum Weight: Sendable { case body, secondary }

    /// Text token → the surfaces the toolkit draws it on.
    static let pairs: [(String, [String], Weight)] = [
        ("bodyText", ["contentBackground", "listBackground", "sheetBackground", "tabPaneBackground"], .body),
        ("controlLabel", ["contentBackground"], .body),
        ("titleText", ["titleBarTop", "titleBarBottom"], .body),
        ("menuText", ["menuBackground"], .body),
        ("menuTextOnHighlight", ["menuHighlight"], .body),
        ("menuBarText", ["menuBarTop", "menuBarBottom"], .body),
        ("fieldText", ["fieldBackground"], .body),
        ("buttonTextOnWhite", ["buttonWhiteTop", "buttonWhiteBottom"], .body),
        // A default button's label sits on its gel's middle band (the top is
        // under the gloss, the bottom below the text), so that is its surface.
        ("buttonTextOnBlue", ["buttonBlueMid"], .body),
        ("tabText", ["tabSelectedTop", "tabSelectedBottom"], .body),
        ("iconLabelText", ["contentBackground", "listBackground"], .body),
        ("dockLabelText", ["dockLabelBackground"], .body),
        ("readoutText", ["readoutBackground"], .body),
        ("secondaryText", ["contentBackground"], .secondary),
        ("sectionTitleText", ["contentBackground"], .secondary),
        ("fieldPlaceholder", ["fieldBackground"], .secondary),
        ("menuTextDisabled", ["menuBackground"], .secondary),
        ("toolbarLabelText", ["toolbarTop", "toolbarBottom", "prefsToolbarTop", "prefsToolbarBottom"], .secondary),
        ("attentionText", ["attentionBackground"], .secondary),
    ]

    public static let bodyFloor = 4.5, secondaryFloor = 3.0
    public static let gadgetFloor = 12.0, rowFloor = 16.0

    /// WCAG 2's relative luminance of an opaque sRGB colour.
    public static func luminance(_ c: Color) -> Double {
        func lin(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : ((v + 0.055) / 1.055).pow(2.4) }
        return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b)
    }

    /// `top` over `bottom`, in sRGB (as the compositor blends).
    public static func over(_ top: Color, _ bottom: Color) -> Color {
        let a = top.a
        return Color(top.r * a + bottom.r * (1 - a), top.g * a + bottom.g * (1 - a),
                     top.b * a + bottom.b * (1 - a), 1)
    }

    public static func ratio(_ a: Color, _ b: Color) -> Double {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// What is wrong with `t`: problems refuse it, warnings are shown.
    public static func check(_ t: ThemeTokens) -> (problems: [String], warnings: [String]) {
        var problems: [String] = [], warnings: [String] = []
        let key = Dictionary(uniqueKeysWithValues: ThemeTokens.colorKeys)
        let window = over(t.contentBackground, Color(0, 0, 0, 1))
        func hex(_ c: Color) -> String {
            func b(_ v: Double) -> String {
                let n = Int((max(0, min(1, v)) * 255).rounded()); let s = String(n, radix: 16)
                return s.count == 1 ? "0" + s : s
            }
            return "#" + b(c.r) + b(c.g) + b(c.b)
        }
        for (fgName, surfaces, weight) in pairs {
            guard let fk = key[fgName] else { continue }
            for sName in surfaces {
                guard let sk = key[sName] else { continue }
                let surface = over(t[keyPath: sk], window)
                let fg = over(t[keyPath: fk], surface)
                let r = ratio(fg, surface)
                let floor = weight == .body ? bodyFloor : secondaryFloor
                guard r < floor else { continue }
                let line = "\(fgName) \(hex(fg)) on \(sName) \(hex(surface)) is \(fmt(r)):1 — "
                    + (weight == .body ? "body text needs \(fmt(bodyFloor)):1" : "secondary text needs \(fmt(secondaryFloor)):1")
                if weight == .body { problems.append("[legibility] " + line) } else { warnings.append("legibility: " + line) }
            }
        }
        if t.trafficRadius * 2 < gadgetFloor {
            problems.append("[legibility] a title-bar gadget is \(fmt(t.trafficRadius * 2)) pt — a pointer needs \(fmt(gadgetFloor))")
        }
        for (name, v) in [("menu.itemHeight", t.menuItemHeight), ("finder.rowHeight", t.finderRowHeight)] where v < rowFloor {
            problems.append("[legibility] \(name) = \(fmt(v)) — a row a pointer can hit is \(fmt(rowFloor)) pt")
        }
        return (problems, warnings)
    }

    static func fmt(_ v: Double) -> String {
        let r = (v * 100).rounded() / 100
        return r == r.rounded() ? String(Int(r)) : String(r)
    }
}

private extension Double {
    func pow(_ e: Double) -> Double {
        #if canImport(Glibc)
        return Glibc.pow(self, e)
        #else
        return Darwin.pow(self, e)
        #endif
    }
}

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
