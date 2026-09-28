// Real text for Aqua: FreeType faces shaped by HarfBuzz (the CText C shim),
// painted through cairo-ft's cairo_show_glyphs. This replaces cairo's toy text
// API — the most visible fidelity gap — with a properly shaped, hinted,
// anti-aliased glyph run (kerning and ligatures included).
//
// `available` is false when no font could be opened; the drawing code then
// keeps its cairo toy-text path, so text always renders. Single-threaded use
// (the UI thread paints one frame at a time), hence the nonisolated(unsafe)
// caches; the shared FT_Face's size is set per shape while cairo sets its own
// size at render, so the two never collide.

import CCairo
import CText

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

public enum Text {
    /// Whether a real font is loaded. When false, `Draw` falls back to toy text.
    public static let available: Bool = at_font_init() != 0

    /// Say, once, what the text stack got — and say it whether or not it worked.
    ///
    /// The fallback to toy text is deliberate and silent, which is right for a
    /// desktop that is merely missing a face and wrong for one that has no fonts
    /// at all: the whole shell is text, and a machine that lost all of it still
    /// draws chrome, still composites three layers, and still looks correct to
    /// anything examining pixels. A live medium built without its fonts passed
    /// every assertion in `abyss/tests/live-medium.sh` until this line existed
    /// (PHASE5 P5.3). Absence has to be *reported*, not merely survived.
    public static func announce() {
        let line: String
        if available {
            var styles: [String] = []
            if styleAvailable(.bold) { styles.append("bold") }
            if styleAvailable(.italic) { styles.append("italic") }
            if styleAvailable(.boldItalic) { styles.append("bold-italic") }
            let gaps = missing(menuGlyphs)
            line = "Text: \(at_font_face_count()) face(s)"
                + (styles.isEmpty ? "" : " (\(styles.joined(separator: ", ")))")
                // Said, not silent (§2.45): a menu whose key column is boxes
                // looks like it works in every test that does not read it.
                + (gaps.isEmpty ? "" : "; NO GLYPHS for \(gaps) — menu key equivalents will be boxes")
                + "\n"
        } else {
            line = "Text: NO FONTS — falling back to toy text; install DejaVu\n"
        }
        line.withCString { _ = write(2, $0, strlen($0)) }
    }

    /// The glyphs a menu's key column is made of (P10.4). Missing, they draw as
    /// empty boxes — legible to nobody, and invisible to every pixel test that
    /// asks only whether *something* was drawn.
    public static let menuGlyphs = "⌘⇧⌥⌃⌫⌦↑↓←→↩⎋⇥"

    /// Which characters of `s` no loaded face can draw.
    public static func missing(_ s: String) -> String {
        guard available else { return s }
        return String(String.UnicodeScalarView(s.unicodeScalars.filter { at_font_covers($0.value) == 0 }))
    }

    /// A weight/slant. Maps to the AT_* face groups in the CText shim; a style
    /// with no dedicated face falls back to `.regular` (text still renders).
    public enum Style: Int32, Sendable {
        case regular = 0, bold = 1, italic = 2, boldItalic = 3
    }

    /// What a run of text is *for* (PHASE11 P11.7): the theme names a family
    /// per role, `[fonts]` in theme.ini. Maps to the AT_ROLE_* face lists in
    /// CText; a role whose family is not here draws with the default chain.
    public enum Role: Int32, Sendable, CaseIterable {
        case interface = 0   // body text, controls, menus
        case chrome = 1      // window titles, the menu bar
        case readout = 2     // an LCD, a clock
        case mono = 3        // fixed pitch

        public var name: String {
            switch self {
            case .interface: return "interface"
            case .chrome: return "chrome"
            case .readout: return "readout"
            case .mono: return "mono"
            }
        }
    }

    /// Where fontconfig should look besides the system (P11.7): the vendored
    /// fonts, next to the themes — and a theme's own `fonts/`. Each directory
    /// once, but **not only the first time**: this used to add one set and
    /// ignore every later call, so a theme switched to while running (P14.2)
    /// could never find the fonts it ships.
    nonisolated(unsafe) private static var dirsAdded: Set<String> = []
    public static func addFontDirs(_ dirs: [String]) {
        for d in dirs where !dirsAdded.contains(d) {
            dirsAdded.insert(d)
            at_font_add_dir(d)
        }
    }

    /// Each role's case and tracking (em), from the theme (P11.9).
    nonisolated(unsafe) private static var upperRoles: Set<String> = []
    nonisolated(unsafe) private static var trackingRoles: [String: Double] = [:]
    public static func useRoleStyle(upper: Set<String>, tracking: [String: Double]) {
        guard upper != upperRoles || tracking != trackingRoles else { return }
        upperRoles = upper; trackingRoles = tracking
        shapeCache.removeAll(keepingCapacity: true)
    }

    /// What each role got: its family when found, and what it asked for.
    nonisolated(unsafe) public private(set) static var roleRequest: [Role: String] = [:]
    nonisolated(unsafe) private static var roleApplied: [Role: String] = [:]

    /// Give every role the family `families` names (the theme's `[fonts]`).
    /// Cheap to repeat: a role already holding that family is not re-matched.
    public static func useRoles(_ families: [Role: String]) {
        guard available else { return }
        for r in Role.allCases {
            let f = families[r] ?? ""
            roleRequest[r] = f
            guard roleApplied[r] != f else { continue }
            roleApplied[r] = f
            // A fixed-pitch role must not fall back to a proportional face: mono
            // falls back to fontconfig's `monospace` before the default chain.
            if at_font_set_role(r.rawValue, f) == 0 && r == .mono {
                _ = at_font_set_role(r.rawValue, "monospace")
            }
            shapeCache.removeAll(keepingCapacity: true)
        }
    }

    /// The family `role` actually draws with, its file, and whether that is
    /// the one the theme asked for.
    public static func resolved(_ role: Role) -> (family: String, file: String, wanted: Bool) {
        let fam = at_font_role_family(role.rawValue).map { String(cString: $0) } ?? "?"
        let file = at_font_role_file(role.rawValue).map { String(cString: $0) } ?? "?"
        let want = roleRequest[role] ?? ""
        return (fam, file, !want.isEmpty && fam.lowercased() == want.lowercased())
    }

    /// One line per role: what it asked for and what it got (§2.45 — a role
    /// that fell back draws text that looks fine and is the wrong typeface).
    public static func announceRoles() {
        guard available else { return }
        for r in Role.allCases {
            let (fam, file, ok) = resolved(r)
            let want = roleRequest[r] ?? ""
            let line = ok
                ? "Text: role \(r.name) = \(fam) (\(file))\n"
                : "Text: role \(r.name) wants \(want.isEmpty ? "nothing" : want) — not found, drawing with \(fam) (\(file))\n"
            line.withCString { _ = write(2, $0, strlen($0)) }
        }
    }

    /// Whether `style` loaded its own face (vs. falling back to regular).
    public static func styleAvailable(_ style: Style) -> Bool {
        at_font_style_available(style.rawValue) != 0
    }

    // Shaped runs are position-independent (advances/offsets are relative to the
    // pen, keyed only by string+size+style), so we cache them across frames —
    // the same static labels are otherwise re-shaped through HarfBuzz every
    // redraw. Single-threaded UI paints, hence nonisolated(unsafe) (as with the
    // face cache). Cleared wholesale past a cap so it can't grow unbounded.
    private struct ShapeKey: Hashable { let s: String; let px: Int32; let style: Int32; let role: Int32 }
    nonisolated(unsafe) private static var shapeCache: [ShapeKey: [at_glyph]] = [:]
    private static let shapeCacheCap = 1024

    /// The current render buffer scale (device px per logical px). The renderer
    /// sets this before painting a frame so text is shaped and hinted on the
    /// device pixel grid — advances then line up with the device-rasterised
    /// glyphs instead of a coarser logical grid. Single-threaded UI paint.
    nonisolated(unsafe) public static var renderScale: Int32 = 1

    /// Font vertical metrics at a pixel size — both positive (px above/below
    /// the baseline).
    public struct Metrics: Sendable {
        public var ascent: Double
        public var descent: Double
    }

    /// One cairo font face per FT face index, built lazily from the shared
    /// FT_Face and cached for the process lifetime (cairo ref-counts it).
    nonisolated(unsafe) private static var faceCache: [Int32: OpaquePointer] = [:]

    private static func cairoFace(_ idx: Int32) -> OpaquePointer? {
        if let f = faceCache[idx] { return f }
        guard let raw = at_font_face(idx),
              let cf = cairo_ft_font_face_create_for_ft_face(
                  raw.assumingMemoryBound(to: FT_FaceRec_.self), 0)
        else { return nil }
        faceCache[idx] = cf
        return cf
    }

    /// Shape `s` at `px` pixels in `style` into a glyph run (indices + pixel
    /// positions + the face each came from). Cached across frames. Empty when no
    /// font is loaded or `s` is empty.
    public static func shape(_ s: String, px: Int32,
                             style: Style = .regular, role: Role = .interface) -> [at_glyph] {
        guard available, !s.isEmpty, px > 0 else { return [] }
        let key = ShapeKey(s: s, px: px, style: style.rawValue, role: role.rawValue)
        if let g = shapeCache[key] { return g }
        // The role's case and tracking, applied here, so a measurement and
        // the drawing it lays out agree (§2.9).
        let text = upperRoles.contains(role.name) ? s.uppercased() : s
        let track = (trackingRoles[role.name] ?? 0) * Double(px)
        var glyphs: [at_glyph] = text.withCString { cstr in
            var cap = Int32(text.utf8.count + 16)
            while true {
                var buf = [at_glyph](repeating: at_glyph(), count: Int(cap))
                let n = buf.withUnsafeMutableBufferPointer {
                    at_font_shape_role(cstr, -1, px, style.rawValue, role.rawValue, $0.baseAddress, cap)
                }
                if n < 0 { return [] }
                if n <= cap { buf.removeLast(Int(cap - n)); return buf }
                cap = n // buffer was too small (rare: a decomposition overran) — retry
            }
        }
        if track != 0 { for i in glyphs.indices { glyphs[i].x_advance += track } }
        if shapeCache.count >= shapeCacheCap { shapeCache.removeAll(keepingCapacity: true) }
        shapeCache[key] = glyphs
        return glyphs
    }

    /// Total pen advance of a shaped run, in pixels.
    public static func width(_ glyphs: [at_glyph]) -> Double {
        glyphs.reduce(0) { $0 + $1.x_advance }
    }

    public static func metrics(px: Int32, role: Role = .interface) -> Metrics {
        Metrics(ascent: at_font_ascent_role(px, role.rawValue), descent: at_font_descent_role(px, role.rawValue))
    }

    /// Paint a shaped run with its origin pen at logical (`x`, `baselineY`). The
    /// run was shaped at device px (`px`); positions/advances are divided by the
    /// render scale into user space, and the font size likewise, so the current
    /// CTM (which scales user→device by `renderScale`) rasterises them back at
    /// device px — crisp, without disturbing the CTM (so translated contexts like
    /// the sliding sheet still position text correctly). The caller sets the
    /// source colour first. Consecutive glyphs from one face are batched.
    public static func drawShaped(_ cr: OpaquePointer, _ glyphs: [at_glyph],
                                  x: Double, baselineY: Double, px: Int32) {
        let s = Double(renderScale)
        var penX = x, penY = baselineY, i = 0
        while i < glyphs.count {
            let face = glyphs[i].face
            var batch: [cairo_glyph_t] = []
            while i < glyphs.count && glyphs[i].face == face {
                let g = glyphs[i]
                var cg = cairo_glyph_t()
                cg.index = g.index
                cg.x = penX + g.x_offset / s
                cg.y = penY - g.y_offset / s // HarfBuzz y is up; cairo y is down
                batch.append(cg)
                penX += g.x_advance / s
                penY -= g.y_advance / s
                i += 1
            }
            guard let cf = cairoFace(face) else { continue }
            cairo_set_font_face(cr, cf)
            cairo_set_font_size(cr, Double(px) / s)
            batch.withUnsafeBufferPointer {
                cairo_show_glyphs(cr, $0.baseAddress, Int32($0.count))
            }
        }
    }

    /// The integer device pixel size to shape/hint at for a logical point
    /// `size` — scaled by `renderScale` so glyphs snap to the device grid. At
    /// scale 1 this is just `round(size)`.
    /// Public since P9.6: the toolkit measures labels with it, and the toolkit
    /// is a different module now.
    public static func px(_ size: Double) -> Int32 {
        Int32((size * Double(renderScale)).rounded())
    }
}
