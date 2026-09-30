/*
 * CDraw — the two pixel loops the draw-list interpreter needs (PHASE11 P11.3).
 *
 * In C for one measured reason: the whole harness runs **debug** builds, where
 * a Swift loop over pixels is tens of times slower than this, and a glow has to
 * be cheap in the build that is actually tested (PHASE11 §4.2 measured 59 us for
 * a menu row at -O2 in C). Nothing here knows about themes; it is arithmetic on
 * byte buffers.
 */
#ifndef ABYSS_CDRAW_H
#define ABYSS_CDRAW_H
#include <stdint.h>

/* Three passes of a box blur on an 8-bit alpha buffer — a Gaussian, near
 * enough — with a total radius of about `radius` pixels. `stride` in bytes.
 * `scratch` must hold width*height bytes. */
void cd_blur_a8(uint8_t *a, uint8_t *scratch, int width, int height, int stride, int radius);

/* Fill an 8-bit alpha tile with deterministic value noise, scaled to `alpha`
 * (0..255). The same seed gives the same tile on every machine, which is what
 * lets a noise material sit under a golden image. */
void cd_noise_a8(uint8_t *a, int width, int height, int stride, uint32_t seed, int alpha);

#endif
