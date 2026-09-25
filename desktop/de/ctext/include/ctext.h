#ifndef ABYSS_CTEXT_H
#define ABYSS_CTEXT_H

/* Real text for the Aqua toolkit: FreeType-loaded faces shaped by HarfBuzz.
 *
 * The libwayland "static-inline trap" does NOT apply here — every FreeType and
 * HarfBuzz entry point is a real exported symbol Swift could call directly. We
 * still keep a thin C shim because the FreeType header dance (`ft2build.h` +
 * the `FT_FREETYPE_H` macro include) and the HarfBuzz buffer lifecycle are
 * awkward from Swift; confining them to one audited file keeps the Swift side
 * clean, mirroring `cwayland_shim.c` and the Rust sibling's `reef_font.c`.
 *
 * The Swift side (`Aqua/Text.swift`) turns the shaped glyph run below into a
 * cairo glyph array and paints it via cairo-ft's `cairo_show_glyphs`, so the
 * FT_Face here and cairo's renderer share the same face (see `at_font_face`). */

/* One shaped glyph: a glyph INDEX into face `face` (not a codepoint), its pen
 * advance and offset in pixels, and the byte `cluster` in the input UTF-8 it
 * came from. Positions are already converted out of HarfBuzz 26.6 fixed point. */
typedef struct {
    unsigned long index;
    int           face;        /* 0 = primary, >0 = a fallback face          */
    double        x_advance, y_advance;
    double        x_offset,  y_offset;
    unsigned int  cluster;
} at_glyph;

/* Text styles. The value picks the face group at_font_shape draws from; a style
 * with no dedicated face falls back to AT_REGULAR (so bold text still renders,
 * just at regular weight). Keep in sync with Aqua/Text.swift `Style`. */
enum {
    AT_REGULAR     = 0,
    AT_BOLD        = 1,
    AT_ITALIC      = 2,
    AT_BOLD_ITALIC = 3,
    AT_NSTYLES     = 4,
};

/* Open the primary face (first candidate that works) then any fallbacks.
 * Idempotent; returns 1 once a primary face is available, else 0 (the caller
 * then falls back to cairo toy-text). Candidate order: $AQUA_FONT, then a
 * metrically-appropriate sans at its common package paths. Bold/italic load
 * from $AQUA_FONT_{BOLD,ITALIC,BOLD_ITALIC} or matching sans candidates. */
int at_font_init(void);

/* Number of loaded faces (0 if none). */
int at_font_face_count(void);
/* Whether any loaded face has a glyph for the Unicode codepoint `cp`. */
int at_font_covers(unsigned int cp);

/* Whether `style` (AT_*) loaded its OWN face (not just the regular fallback).
 * AT_REGULAR is available whenever a font is loaded at all. */
int at_font_style_available(int style);

/* FT_Face for `idx` as an opaque pointer, for
 * cairo_ft_font_face_create_for_ft_face. NULL if `idx` is out of range. */
void *at_font_face(int idx);

/* Shape UTF-8 `text` (`len` bytes, or -1 for NUL-terminated) at `px` pixels in
 * `style` (AT_*) into `out` (capacity `cap` glyphs). Text is itemised by face
 * COVERAGE, so a codepoint the chosen style's face lacks is shaped from the
 * first fallback that has it. Returns the total glyph count. If that exceeds
 * `cap` nothing was written past `cap`; call again with a larger buffer.
 * Returns -1 on error / no font. */
int at_font_shape(const char *text, int len, int px, int style,
                  at_glyph *out, int cap);

/* Vertical metrics of the primary face at `px` pixels, in pixels. `ascent` is
 * positive above the baseline, `descent` positive below. */
double at_font_ascent(int px);
double at_font_descent(int px);
double at_font_line_height(int px);

#endif /* ABYSS_CTEXT_H */
