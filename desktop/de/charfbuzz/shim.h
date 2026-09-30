#ifndef ABYSS_CHARFBUZZ_SHIM_H
#define ABYSS_CHARFBUZZ_SHIM_H

/* Present only so CText inherits harfbuzz's pkg-config cflags/libs. The
 * HarfBuzz headers are included directly by de/ctext/ctext.c, not through this
 * module. */
#include <hb.h>
#include <hb-ft.h>

#endif /* ABYSS_CHARFBUZZ_SHIM_H */
