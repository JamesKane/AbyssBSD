#ifndef ABYSS_CWAYLANDCLIENT_SHIM_H
#define ABYSS_CWAYLANDCLIENT_SHIM_H

/* libwayland-client, reached through pkg-config rather than assumed to sit in
 * /usr/include. That assumption held on Linux and broke on FreeBSD, where the
 * headers live under /usr/local/include and nothing puts that on the compiler's
 * search path by default.
 *
 * Nothing imports this module from Swift: every wl_* request is `static inline`
 * and therefore invisible to Swift's C importer (HANDOFF §2.1), so calls go
 * through CWayland's aw_* shims. The module exists so that CWayland — an
 * ordinary C target, which cannot carry a pkgConfig of its own — inherits the
 * include dir and the -lwayland-client link flag by depending on it. */
#include <wayland-client.h>

#endif /* ABYSS_CWAYLANDCLIENT_SHIM_H */
