#ifndef ABYSS_CCAIRO_SHIM_H
#define ABYSS_CCAIRO_SHIM_H

/* Cairo is the Phase-1 software 2D backend for the Aqua toolkit: gradients,
 * rounded rects, soft shadows, gloss. The pkgConfig "cairo" in Package.swift
 * supplies the -I/usr/include/cairo include flag that resolves <cairo.h>. */
#include <cairo.h>

/* cairo-ft is the bridge to real text: Aqua shapes a run with HarfBuzz (see
 * de/ctext) then paints the glyphs through a cairo font face built from the
 * shared FT_Face via cairo_ft_font_face_create_for_ft_face. cairo's own cflags
 * already carry the freetype2 include dir, so this needs no extra flags; it
 * also imports the FT_Face type for the Swift side. */
#include <cairo-ft.h>

#endif /* ABYSS_CCAIRO_SHIM_H */
