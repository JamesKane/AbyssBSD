// xdgoutput — print every output as xdg-output describes it, one line each:
//
//     output NAME X,Y WxH
//
// The logical position and size a client is told (P14.7a) — which is the
// compositor's layout, as the only party that can see it says it. A test
// helper, not part of the product, compiled on demand against the system's
// wayland-protocols copy of xdg-output-unstable-v1 (present on Fedora and
// FreeBSD, where `wayland-info` is not).
//
// Usage: xdgoutput

#include <wayland-client.h>
#include "xdgoutput-proto.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define MAX_OUTPUTS 16

struct out {
    struct wl_output *output;
    struct zxdg_output_v1 *xdg;
    char name[64];
    int x, y, w, h;
};

static struct out outs[MAX_OUTPUTS];
static int nouts;
static struct zxdg_output_manager_v1 *manager;

static void reg_global(void *data, struct wl_registry *reg, uint32_t id,
                       const char *iface, uint32_t version) {
    (void)data;
    if (strcmp(iface, wl_output_interface.name) == 0 && nouts < MAX_OUTPUTS) {
        outs[nouts++].output = wl_registry_bind(reg, id, &wl_output_interface, 1);
    } else if (strcmp(iface, zxdg_output_manager_v1_interface.name) == 0) {
        manager = wl_registry_bind(reg, id, &zxdg_output_manager_v1_interface, version < 3 ? version : 3);
    }
}
static void reg_remove(void *d, struct wl_registry *r, uint32_t id) { (void)d; (void)r; (void)id; }
static const struct wl_registry_listener reg_listener = { reg_global, reg_remove };

static void xo_position(void *d, struct zxdg_output_v1 *x, int32_t px, int32_t py) {
    (void)x; struct out *o = d; o->x = px; o->y = py;
}
static void xo_size(void *d, struct zxdg_output_v1 *x, int32_t w, int32_t h) {
    (void)x; struct out *o = d; o->w = w; o->h = h;
}
static void xo_done(void *d, struct zxdg_output_v1 *x) { (void)d; (void)x; }
static void xo_name(void *d, struct zxdg_output_v1 *x, const char *name) {
    (void)x; struct out *o = d; snprintf(o->name, sizeof o->name, "%s", name);
}
static void xo_desc(void *d, struct zxdg_output_v1 *x, const char *desc) { (void)d; (void)x; (void)desc; }
static const struct zxdg_output_v1_listener xo_listener = { xo_position, xo_size, xo_done, xo_name, xo_desc };

int main(void) {
    struct wl_display *dpy = wl_display_connect(NULL);
    if (!dpy) { fprintf(stderr, "xdgoutput: cannot connect\n"); return 1; }
    struct wl_registry *reg = wl_display_get_registry(dpy);
    wl_registry_add_listener(reg, &reg_listener, NULL);
    wl_display_roundtrip(dpy);
    if (!manager) { fprintf(stderr, "xdgoutput: the compositor offers no zxdg_output_manager_v1\n"); return 2; }
    for (int i = 0; i < nouts; i++) {
        outs[i].xdg = zxdg_output_manager_v1_get_xdg_output(manager, outs[i].output);
        zxdg_output_v1_add_listener(outs[i].xdg, &xo_listener, &outs[i]);
    }
    wl_display_roundtrip(dpy);
    wl_display_roundtrip(dpy);
    for (int i = 0; i < nouts; i++)
        printf("output %s %d,%d %dx%d\n", outs[i].name, outs[i].x, outs[i].y, outs[i].w, outs[i].h);
    wl_display_disconnect(dpy);
    return 0;
}
