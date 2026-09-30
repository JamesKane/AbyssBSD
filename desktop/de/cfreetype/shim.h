#ifndef ABYSS_CFREETYPE_SHIM_H
#define ABYSS_CFREETYPE_SHIM_H

/* Present only so CText inherits freetype2's pkg-config cflags/libs. The
 * FreeType headers are included directly by de/ctext/ctext.c (they need the
 * ft2build.h + FT_FREETYPE_H macro dance), not through this module. */
#include <ft2build.h>
#include FT_FREETYPE_H

#endif /* ABYSS_CFREETYPE_SHIM_H */
