#ifndef ABYSS_CCAIRO_SHIM_H
#define ABYSS_CCAIRO_SHIM_H

/* Cairo is the Phase-1 software 2D backend for the Aqua toolkit: gradients,
 * rounded rects, soft shadows, gloss. FreeType/HarfBuzz text integration
 * arrives via cairo-ft later. The pkgConfig "cairo" in Package.swift supplies
 * the -I/usr/include/cairo include flag that resolves <cairo.h>. */
#include <cairo.h>

#endif /* ABYSS_CCAIRO_SHIM_H */
