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

public enum Text {
    /// Whether a real font is loaded. When false, `Draw` falls back to toy text.
    public static let available: Bool = at_font_init() != 0

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

    /// Shape `s` at `px` pixels into a glyph run (indices + pixel positions +
    /// the face each came from). Empty when no font is loaded or `s` is empty.
    public static func shape(_ s: String, px: Int32) -> [at_glyph] {
        guard available, !s.isEmpty, px > 0 else { return [] }
        return s.withCString { cstr in
            var cap = Int32(s.utf8.count + 16)
            while true {
                var buf = [at_glyph](repeating: at_glyph(), count: Int(cap))
                let n = buf.withUnsafeMutableBufferPointer {
                    at_font_shape(cstr, -1, px, $0.baseAddress, cap)
                }
                if n < 0 { return [] }
                if n <= cap { buf.removeLast(Int(cap - n)); return buf }
                cap = n // buffer was too small (rare: a decomposition overran) — retry
            }
        }
    }

    /// Total pen advance of a shaped run, in pixels.
    public static func width(_ glyphs: [at_glyph]) -> Double {
        glyphs.reduce(0) { $0 + $1.x_advance }
    }

    public static func metrics(px: Int32) -> Metrics {
        Metrics(ascent: at_font_ascent(px), descent: at_font_descent(px))
    }

    /// Paint a shaped run with its origin pen at `x` on text `baselineY`. The
    /// caller sets the source colour first. Consecutive glyphs from the same
    /// face are batched into one cairo_show_glyphs call.
    public static func drawShaped(_ cr: OpaquePointer, _ glyphs: [at_glyph],
                                  x: Double, baselineY: Double, px: Int32) {
        var penX = x, penY = baselineY, i = 0
        while i < glyphs.count {
            let face = glyphs[i].face
            var batch: [cairo_glyph_t] = []
            while i < glyphs.count && glyphs[i].face == face {
                let g = glyphs[i]
                var cg = cairo_glyph_t()
                cg.index = g.index
                cg.x = penX + g.x_offset
                cg.y = penY - g.y_offset // HarfBuzz y is up; cairo y is down
                batch.append(cg)
                penX += g.x_advance
                penY -= g.y_advance
                i += 1
            }
            guard let cf = cairoFace(face) else { continue }
            cairo_set_font_face(cr, cf)
            cairo_set_font_size(cr, Double(px))
            batch.withUnsafeBufferPointer {
                cairo_show_glyphs(cr, $0.baseAddress, Int32($0.count))
            }
        }
    }

    /// Round a logical point size to the integer pixel size we shape/hint at.
    static func px(_ size: Double) -> Int32 { Int32(size.rounded()) }
}
