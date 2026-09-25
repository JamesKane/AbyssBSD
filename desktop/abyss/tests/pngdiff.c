/* pngdiff — compare two PNGs pixel for pixel (PHASE11 P11.1).
 *
 *   pngdiff GOLDEN.png ACTUAL.png [DIFF.png]
 *
 * Exit 0 when every pixel is identical, 1 when any differs, 2 when an image
 * cannot be read or the sizes disagree. Prints one line saying which. With a
 * third argument, writes a picture of the difference: the golden image dimmed,
 * every differing pixel in solid red — so a failure names *where*, not just
 * *whether*.
 *
 * Identical, not "close": the gate exists to prove that re-expressing Aqua as
 * data changed nothing, and a tolerance is a place for a change to hide. A
 * rendering-stack upgrade (cairo, freetype, a font) moves pixels too; that is
 * `golden.sh --update`, done on purpose, not a threshold.
 *
 * C over cairo, like the rest of the harness's helpers: no image library, no
 * build dependency the tree does not already have.
 */
#include <cairo.h>
#include <stdint.h>
#include <stdio.h>

int main(int argc, char **argv) {
    if (argc < 3) { fprintf(stderr, "usage: pngdiff GOLDEN ACTUAL [DIFF]\n"); return 2; }
    cairo_surface_t *g = cairo_image_surface_create_from_png(argv[1]);
    cairo_surface_t *a = cairo_image_surface_create_from_png(argv[2]);
    if (cairo_surface_status(g) || cairo_surface_status(a)) {
        printf("unreadable: %s\n", cairo_surface_status(g) ? argv[1] : argv[2]);
        return 2;
    }
    int w = cairo_image_surface_get_width(g), h = cairo_image_surface_get_height(g);
    if (w != cairo_image_surface_get_width(a) || h != cairo_image_surface_get_height(a)) {
        printf("size differs: golden %dx%d, actual %dx%d\n", w, h,
               cairo_image_surface_get_width(a), cairo_image_surface_get_height(a));
        return 1;
    }
    /* Formats can differ (RGB24 vs ARGB32 from the PNG's alpha); compare the
     * 32-bit words with alpha forced for RGB24, which cairo leaves undefined. */
    int ga = cairo_image_surface_get_format(g) == CAIRO_FORMAT_ARGB32;
    int aa = cairo_image_surface_get_format(a) == CAIRO_FORMAT_ARGB32;
    unsigned char *gd = cairo_image_surface_get_data(g), *ad = cairo_image_surface_get_data(a);
    int gs = cairo_image_surface_get_stride(g), as = cairo_image_surface_get_stride(a);

    cairo_surface_t *d = NULL; unsigned char *dd = NULL; int ds = 0;
    if (argc > 3) {
        d = cairo_image_surface_create(CAIRO_FORMAT_RGB24, w, h);
        dd = cairo_image_surface_get_data(d); ds = cairo_image_surface_get_stride(d);
    }
    long differ = 0; int maxd = 0, fx = -1, fy = -1;
    for (int y = 0; y < h; y++) {
        uint32_t *gr = (uint32_t *)(gd + y * gs), *ar = (uint32_t *)(ad + y * as);
        uint32_t *dr = dd ? (uint32_t *)(dd + y * ds) : NULL;
        for (int x = 0; x < w; x++) {
            uint32_t gp = ga ? gr[x] : (gr[x] | 0xff000000u);
            uint32_t ap = aa ? ar[x] : (ar[x] | 0xff000000u);
            if (gp != ap) {
                if (differ == 0) { fx = x; fy = y; }
                differ++;
                for (int sh = 0; sh < 32; sh += 8) {
                    int dv = (int)((gp >> sh) & 0xff) - (int)((ap >> sh) & 0xff);
                    if (dv < 0) dv = -dv;
                    if (dv > maxd) maxd = dv;
                }
                if (dr) dr[x] = 0x00ff0000u;
            } else if (dr) {
                uint32_t c = gp;   /* the golden, at a third of its brightness */
                dr[x] = (((c >> 16 & 0xff) / 3) << 16) | (((c >> 8 & 0xff) / 3) << 8) | ((c & 0xff) / 3);
            }
        }
    }
    if (d) { cairo_surface_mark_dirty(d); cairo_surface_write_to_png(d, argv[3]); }
    if (differ == 0) { printf("identical (%dx%d)\n", w, h); return 0; }
    printf("%ld of %ld pixels differ (first at %d,%d; largest channel change %d)\n",
           differ, (long)w * h, fx, fy, maxd);
    return 1;
}
