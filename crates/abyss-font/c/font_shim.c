/* AbyssBSD font shim.
 *
 * A flat C API over freetype + harfbuzz. Every freetype/harfbuzz struct is
 * touched only here, in C, where the compiler knows the layout — the Rust
 * side (src/ffi.rs) sees only the small, AbyssBSD-defined structs below.
 *
 * Single-threaded use: the freetype library is process-global and is not
 * guarded. Fine for one looper and for host tests; a locked or per-thread
 * library is a later concern (see docs/design/toolkit.md).
 */

#include <ft2build.h>
#include FT_FREETYPE_H
#include <hb.h>
#include <hb-ft.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    FT_Face    ft_face;
    hb_font_t *hb_font;
} AbyssFont;

/* Mirrors `ffi::ShapedGlyph`. */
typedef struct {
    unsigned int glyph;
    float        x_advance;
    float        x_offset;
    float        y_offset;
} AbyssShapedGlyph;

/* Mirrors `ffi::GlyphInfo`. */
typedef struct {
    int   width;
    int   rows;
    int   left;
    int   top;
    float advance;
} AbyssGlyphInfo;

/* Mirrors `ffi::FontMetrics`. */
typedef struct {
    float ascent;
    float descent;
    float line_gap;
    float line_height;
} AbyssFontMetrics;

static FT_Library g_ft = NULL;

/* Set the working size to `px` pixels — fractional, via a 26.6 char size
 * at 72 dpi, where one point equals one pixel. */
static void abyss_set_size(AbyssFont *f, float px) {
    FT_F26Dot6 size = (FT_F26Dot6)(px * 64.0f + 0.5f);
    FT_Set_Char_Size(f->ft_face, 0, size, 72, 72);
}

AbyssFont *abyss_font_open(const char *path, unsigned int index) {
    if (g_ft == NULL && FT_Init_FreeType(&g_ft) != 0) {
        return NULL;
    }
    FT_Face face;
    if (FT_New_Face(g_ft, path, (FT_Long)index, &face) != 0) {
        return NULL;
    }
    hb_font_t *hb = hb_ft_font_create_referenced(face);
    if (hb == NULL) {
        FT_Done_Face(face);
        return NULL;
    }
    AbyssFont *f = (AbyssFont *)malloc(sizeof(AbyssFont));
    if (f == NULL) {
        hb_font_destroy(hb);
        FT_Done_Face(face);
        return NULL;
    }
    f->ft_face = face;
    f->hb_font = hb;
    return f;
}

void abyss_font_close(AbyssFont *f) {
    if (f == NULL) {
        return;
    }
    hb_font_destroy(f->hb_font);
    FT_Done_Face(f->ft_face);
    free(f);
}

AbyssFontMetrics abyss_font_metrics(AbyssFont *f, float px) {
    abyss_set_size(f, px);
    FT_Size_Metrics m = f->ft_face->size->metrics;
    AbyssFontMetrics r;
    r.ascent = (float)m.ascender / 64.0f;
    r.descent = -(float)m.descender / 64.0f; /* descender is negative */
    r.line_height = (float)m.height / 64.0f;
    r.line_gap = r.line_height - (r.ascent + r.descent);
    return r;
}

/* Shape `text` (UTF-8, `len` bytes). Writes up to `cap` glyphs into `out`
 * and returns the total glyph count — which may exceed `cap`. */
size_t abyss_font_shape(AbyssFont *f, const char *text, size_t len, float px,
                        AbyssShapedGlyph *out, size_t cap) {
    abyss_set_size(f, px);
    hb_ft_font_changed(f->hb_font);

    hb_buffer_t *buf = hb_buffer_create();
    hb_buffer_add_utf8(buf, text, (int)len, 0, (int)len);
    hb_buffer_guess_segment_properties(buf);
    hb_shape(f->hb_font, buf, NULL, 0);

    unsigned int count = hb_buffer_get_length(buf);
    hb_glyph_info_t *infos = hb_buffer_get_glyph_infos(buf, NULL);
    hb_glyph_position_t *pos = hb_buffer_get_glyph_positions(buf, NULL);

    size_t emit = (size_t)count < cap ? (size_t)count : cap;
    for (size_t i = 0; i < emit; i++) {
        out[i].glyph = infos[i].codepoint; /* a glyph index after shaping */
        out[i].x_advance = (float)pos[i].x_advance / 64.0f;
        out[i].x_offset = (float)pos[i].x_offset / 64.0f;
        out[i].y_offset = (float)pos[i].y_offset / 64.0f;
    }
    hb_buffer_destroy(buf);
    return (size_t)count;
}

/* Render glyph `glyph` (a glyph index) at `px`. Fills `info`; the coverage
 * bytes stay in the face's glyph slot for `abyss_font_copy_coverage`. */
int abyss_font_rasterize(AbyssFont *f, unsigned int glyph, float px,
                         AbyssGlyphInfo *info) {
    abyss_set_size(f, px);
    if (FT_Load_Glyph(f->ft_face, glyph, FT_LOAD_DEFAULT) != 0) {
        return 0;
    }
    FT_GlyphSlot slot = f->ft_face->glyph;
    if (FT_Render_Glyph(slot, FT_RENDER_MODE_NORMAL) != 0) {
        return 0;
    }
    info->width = (int)slot->bitmap.width;
    info->rows = (int)slot->bitmap.rows;
    info->left = slot->bitmap_left;
    info->top = slot->bitmap_top;
    info->advance = (float)slot->advance.x / 64.0f;
    return 1;
}

/* Copy the last-rasterized glyph's 8-bit coverage, row-major and tightly
 * packed, into `out` (`out_len` bytes). */
void abyss_font_copy_coverage(AbyssFont *f, unsigned char *out, size_t out_len) {
    FT_Bitmap *bm = &f->ft_face->glyph->bitmap;
    size_t width = (size_t)bm->width;
    size_t rows = (size_t)bm->rows;
    int pitch = bm->pitch;
    for (size_t y = 0; y < rows; y++) {
        size_t dst = y * width;
        if (dst + width > out_len) {
            return;
        }
        memcpy(out + dst, bm->buffer + (ptrdiff_t)y * pitch, width);
    }
}
