// Real text for the Aqua toolkit — FreeType face management + HarfBuzz shaping.
// See ctext.h for the C API and the rationale for keeping this in C. Everything
// here runs on the UI thread (one draw at a time), so the global face table
// needs no locking; the shared FT_Face's pixel size is (re)set per call, and
// cairo resets its own size when it renders, so the two never fight.

#include "ctext.h"

#include <ft2build.h>
#include FT_FREETYPE_H
#include <hb.h>
#include <hb-ft.h>

#include <stdlib.h>
#include <string.h>

#define MAX_FACES 8

static FT_Library g_lib;
/* Two FT_Face instances per font, from the same file. `g_shape` is resized per
 * shape for HarfBuzz (which installs its own FT_Size); `g_render` is handed to
 * cairo and NEVER touched by us — cairo owns its size across all point sizes.
 * Sharing one face between the two corrupts cairo's glyph sizing (it caches at
 * whatever size the face happened to hold), so we keep them separate. */
static FT_Face    g_shape[MAX_FACES];
static FT_Face    g_render[MAX_FACES];
static int        g_nfaces = 0;
static int        g_state  = 0; /* 0 = untried, 1 = primary loaded, -1 = failed */

static void add_face(const char *path) {
    if (g_nfaces >= MAX_FACES || path == NULL || path[0] == '\0') return;
    FT_Face s, r;
    if (FT_New_Face(g_lib, path, 0, &s) != 0) return;
    if (FT_New_Face(g_lib, path, 0, &r) != 0) { FT_Done_Face(s); return; }
    g_shape[g_nfaces]  = s;
    g_render[g_nfaces] = r;
    g_nfaces++;
}

// Add every colon-separated path in environment variable `var` (if set).
static void add_env_faces(const char *var) {
    const char *v = getenv(var);
    if (v == NULL || v[0] == '\0') return;
    char *dup = strdup(v);
    if (dup == NULL) return;
    char *save = NULL;
    for (char *p = strtok_r(dup, ":", &save); p != NULL; p = strtok_r(NULL, ":", &save))
        add_face(p);
    free(dup);
}

int at_font_init(void) {
    if (g_state != 0) return g_state > 0;
    g_state = -1;
    if (FT_Init_FreeType(&g_lib) != 0) return 0;

    // Primary face: $AQUA_FONT wins; else a metrically-appropriate sans at its
    // common package paths (no Lucida Grande ships free — drop one in via
    // $AQUA_FONT for pixel-faithful text). The first that opens is face 0.
    add_env_faces("AQUA_FONT");
    if (g_nfaces == 0) {
        static const char *const primary[] = {
            "/usr/share/fonts/google-noto/NotoSans-Regular.ttf",
            "/usr/share/fonts/dejavu-sans-fonts/DejaVuSans.ttf",
            "/usr/share/fonts/dejavu/DejaVuSans.ttf",
            "/usr/local/share/fonts/dejavu/DejaVuSans.ttf",
            "/usr/share/fonts/liberation-sans/LiberationSans-Regular.ttf",
            NULL,
        };
        for (int i = 0; primary[i] != NULL && g_nfaces == 0; i++) add_face(primary[i]);
    }
    if (g_nfaces == 0) return 0; // no usable face — caller keeps toy-text

    // Fallback faces for codepoints the primary lacks (best-effort; a missing
    // one just narrows coverage). $AQUA_FONT_FALLBACK is colon-separated.
    add_env_faces("AQUA_FONT_FALLBACK");
    static const char *const fallback[] = {
        "/usr/share/fonts/dejavu-sans-fonts/DejaVuSans.ttf",
        "/usr/share/fonts/google-noto/NotoSansSymbols-Regular.ttf",
        NULL,
    };
    for (int i = 0; fallback[i] != NULL; i++) add_face(fallback[i]);

    g_state = 1;
    return 1;
}

int at_font_face_count(void) { return g_nfaces; }

void *at_font_face(int idx) {
    if (idx < 0 || idx >= g_nfaces) return NULL;
    return (void *)g_render[idx]; // cairo's dedicated face
}

// Set the shaping face's pixel size and return it, or NULL if out of range.
static FT_Face sized(int idx, int px) {
    if (idx < 0 || idx >= g_nfaces) return NULL;
    FT_Set_Pixel_Sizes(g_shape[idx], 0, (unsigned)(px > 0 ? px : 1));
    return g_shape[idx];
}

double at_font_ascent(int px) {
    FT_Face f = at_font_init() ? sized(0, px) : NULL;
    return f ? f->size->metrics.ascender / 64.0 : 0.0;
}

double at_font_descent(int px) {
    FT_Face f = at_font_init() ? sized(0, px) : NULL;
    return f ? -(f->size->metrics.descender) / 64.0 : 0.0;
}

double at_font_line_height(int px) {
    FT_Face f = at_font_init() ? sized(0, px) : NULL;
    return f ? f->size->metrics.height / 64.0 : 0.0;
}

// Decode the UTF-8 codepoint at s[i..len); set *adv to its byte length. Any
// malformed sequence yields U+FFFD and advances one byte, so we never stall.
static unsigned long utf8_next(const char *s, int len, int i, int *adv) {
    unsigned char c = (unsigned char)s[i];
    if (c < 0x80) { *adv = 1; return c; }
    if ((c >> 5) == 0x6 && i + 1 < len) {
        *adv = 2;
        return ((unsigned long)(c & 0x1F) << 6) | ((unsigned char)s[i + 1] & 0x3F);
    }
    if ((c >> 4) == 0xE && i + 2 < len) {
        *adv = 3;
        return ((unsigned long)(c & 0x0F) << 12) |
               (((unsigned char)s[i + 1] & 0x3F) << 6) | ((unsigned char)s[i + 2] & 0x3F);
    }
    if ((c >> 3) == 0x1E && i + 3 < len) {
        *adv = 4;
        return ((unsigned long)(c & 0x07) << 18) |
               (((unsigned char)s[i + 1] & 0x3F) << 12) |
               (((unsigned char)s[i + 2] & 0x3F) << 6) | ((unsigned char)s[i + 3] & 0x3F);
    }
    *adv = 1;
    return 0xFFFD;
}

// The first face that has a glyph for `cp`; face 0 if none (it renders .notdef).
static int face_for(unsigned long cp) {
    for (int i = 0; i < g_nfaces; i++)
        if (FT_Get_Char_Index(g_shape[i], cp) != 0) return i;
    return 0;
}

// Shape the byte range [start,end) of `text` (whose full length is `total`)
// with face `fi` at `px`, appending glyphs after the `written` already in
// `out`. Passing the whole string with an item offset keeps HarfBuzz clusters
// relative to the original string. Returns glyphs produced, or -1 on error.
static int shape_run(int fi, const char *text, int total, int start, int end,
                     int px, at_glyph *out, int cap, int written) {
    FT_Face face = sized(fi, px);
    if (face == NULL) return -1;
    hb_font_t *hf = hb_ft_font_create_referenced(face);
    if (hf == NULL) return -1;
    hb_buffer_t *buf = hb_buffer_create();
    hb_buffer_add_utf8(buf, text, total, (unsigned)start, end - start);
    hb_buffer_guess_segment_properties(buf);
    hb_shape(hf, buf, NULL, 0);

    unsigned int n = hb_buffer_get_length(buf);
    hb_glyph_info_t     *info = hb_buffer_get_glyph_infos(buf, NULL);
    hb_glyph_position_t *pos  = hb_buffer_get_glyph_positions(buf, NULL);
    for (unsigned int i = 0; i < n; i++) {
        int w = written + (int)i;
        if (w < cap) {
            out[w].index     = info[i].codepoint; // a glyph index after shaping
            out[w].face      = fi;
            out[w].x_advance = pos[i].x_advance / 64.0;
            out[w].y_advance = pos[i].y_advance / 64.0;
            out[w].x_offset  = pos[i].x_offset / 64.0;
            out[w].y_offset  = pos[i].y_offset / 64.0;
            out[w].cluster   = info[i].cluster;
        }
    }
    hb_buffer_destroy(buf);
    hb_font_destroy(hf);
    return (int)n;
}

int at_font_shape(const char *text, int len, int px, at_glyph *out, int cap) {
    if (!at_font_init() || text == NULL) return -1;
    if (len < 0) len = (int)strlen(text);
    if (len == 0) return 0;
    if (px <= 0) px = 1;

    // Group consecutive codepoints resolving to the same face into runs, then
    // shape each run. (Whole-run reordering for bidi is a separate concern.)
    int written = 0, run_start = 0, run_face = -1, i = 0;
    while (i < len) {
        int adv;
        unsigned long cp = utf8_next(text, len, i, &adv);
        int f = face_for(cp);
        if (run_face < 0) {
            run_face = f;
        } else if (f != run_face) {
            int a = shape_run(run_face, text, len, run_start, i, px, out, cap, written);
            if (a < 0) return -1;
            written += a;
            run_start = i;
            run_face = f;
        }
        i += adv;
    }
    if (run_face >= 0) {
        int a = shape_run(run_face, text, len, run_start, len, px, out, cap, written);
        if (a < 0) return -1;
        written += a;
    }
    return written;
}
