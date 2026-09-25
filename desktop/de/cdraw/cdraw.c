/* CDraw — see include/cdraw.h. */
#include "cdraw.h"
#include <string.h>

static void box_h(const uint8_t *src, uint8_t *dst, int w, int h, int stride, int r) {
    int div = 2 * r + 1;
    for (int y = 0; y < h; y++) {
        const uint8_t *row = src + y * stride; uint8_t *out = dst + y * w;
        int s = 0;
        for (int x = -r; x <= r; x++) s += row[x < 0 ? 0 : (x >= w ? w - 1 : x)];
        for (int x = 0; x < w; x++) {
            out[x] = (uint8_t)(s / div);
            int add = x + r + 1, sub = x - r;
            s += row[add >= w ? w - 1 : add] - row[sub < 0 ? 0 : sub];
        }
    }
}

static void box_v(const uint8_t *src, uint8_t *dst, int w, int h, int stride, int r) {
    int div = 2 * r + 1;
    for (int x = 0; x < w; x++) {
        int s = 0;
        for (int y = -r; y <= r; y++) s += src[(y < 0 ? 0 : (y >= h ? h - 1 : y)) * w + x];
        for (int y = 0; y < h; y++) {
            dst[y * stride + x] = (uint8_t)(s / div);
            int add = y + r + 1, sub = y - r;
            s += src[(add >= h ? h - 1 : add) * w + x] - src[(sub < 0 ? 0 : sub) * w + x];
        }
    }
}

void cd_blur_a8(uint8_t *a, uint8_t *scratch, int w, int h, int stride, int radius) {
    if (radius <= 0 || w <= 0 || h <= 0) return;
    int r = radius / 3 + 1;
    for (int pass = 0; pass < 3; pass++) {
        box_h(a, scratch, w, h, stride, r);   /* a → scratch (packed) */
        box_v(scratch, a, w, h, stride, r);   /* scratch → a (strided) */
    }
}

static uint32_t hash(uint32_t x) {        /* a small integer hash (lowbias32) */
    x ^= x >> 16; x *= 0x7feb352dU; x ^= x >> 15; x *= 0x846ca68bU; x ^= x >> 16;
    return x;
}

void cd_noise_a8(uint8_t *a, int w, int h, int stride, uint32_t seed, int alpha) {
    /* Two octaves of value noise over a 4 px and a 2 px lattice, then fine
     * grain — enough texture to read as anodized metal, and wraps at the tile. */
    for (int y = 0; y < h; y++) {
        for (int x = 0; x < w; x++) {
            uint32_t g = hash(seed ^ (uint32_t)(x * 73856093) ^ (uint32_t)(y * 19349663));
            uint32_t c1 = hash(seed + 1 + (uint32_t)((x / 4) * 83492791) ^ (uint32_t)((y / 4) * 2654435761U));
            uint32_t c2 = hash(seed + 2 + (uint32_t)((x / 2) * 3266489917U) ^ (uint32_t)((y / 2) * 668265263));
            int v = (int)((g & 0xff) / 2 + (c1 & 0xff) / 3 + (c2 & 0xff) / 6);   /* 0..255 */
            a[y * stride + x] = (uint8_t)(v * alpha / 255);
        }
    }
}
