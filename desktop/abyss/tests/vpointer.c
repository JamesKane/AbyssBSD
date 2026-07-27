// vpointer — a wlr-virtual-pointer test client for driving synthetic input.
//
// The headless sway backend attaches no input devices, so its seat advertises
// capabilities:0 and a client never binds wl_pointer — the pointer path can't
// be tested. This tool binds zwlr_virtual_pointer_manager_v1 and creates a
// virtual pointer, which registers as a real input device: the seat then gains
// the pointer capability and the app under test binds wl_pointer and receives
// events. It then reads commands from stdin and injects them, staying alive
// (holding the pointer capability) until stdin closes.
//
// Not part of the product — a test helper, compiled on demand by live-sway.sh
// against the vendored wlr-virtual-pointer XML. Pure C, so the generated
// static-inline request wrappers are callable directly (no shim needed).
//
// Usage:  vpointer <width> <height>   (output size, for absolute coordinates)
// Commands (one per line on stdin):
//   m <x> <y>   move the cursor to output pixel (x, y)
//   p           press   the left button
//   r           release the left button
//   P           press   the right button (contextual menus)
//   R           release the right button
//   a <value>   vertical scroll by <value> logical px (positive = down)
//   q           quit (also on EOF)

#include <wayland-client.h>
#include "vpointer-proto.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define BTN_LEFT 0x110u
#define BTN_RIGHT 0x111u

static struct zwlr_virtual_pointer_manager_v1 *g_mgr = NULL;

static void reg_global(void *data, struct wl_registry *reg, uint32_t name,
                       const char *iface, uint32_t version) {
    (void)data;
    if (strcmp(iface, zwlr_virtual_pointer_manager_v1_interface.name) == 0) {
        uint32_t v = version < 2 ? version : 2;
        g_mgr = wl_registry_bind(reg, name, &zwlr_virtual_pointer_manager_v1_interface, v);
    }
}
static void reg_remove(void *data, struct wl_registry *reg, uint32_t name) {
    (void)data; (void)reg; (void)name;
}
static const struct wl_registry_listener reg_listener = { reg_global, reg_remove };

int main(int argc, char **argv) {
    unsigned w = argc > 1 ? (unsigned)atoi(argv[1]) : 1200;
    unsigned h = argc > 2 ? (unsigned)atoi(argv[2]) : 820;

    struct wl_display *dpy = wl_display_connect(NULL);
    if (dpy == NULL) { fprintf(stderr, "vpointer: cannot connect to WAYLAND_DISPLAY\n"); return 1; }

    struct wl_registry *reg = wl_display_get_registry(dpy);
    wl_registry_add_listener(reg, &reg_listener, NULL);
    wl_display_roundtrip(dpy);
    if (g_mgr == NULL) {
        fprintf(stderr, "vpointer: compositor lacks zwlr_virtual_pointer_manager_v1\n");
        return 2;
    }

    // seat NULL → compositor's default seat (seat0, the one the app uses).
    struct zwlr_virtual_pointer_v1 *vp =
        zwlr_virtual_pointer_manager_v1_create_virtual_pointer(g_mgr, NULL);
    wl_display_roundtrip(dpy); // let the compositor register the new device
    fprintf(stderr, "vpointer: ready %ux%u\n", w, h);
    fflush(stderr);

    uint32_t t = 0;
    char line[256];
    while (fgets(line, sizeof line, stdin) != NULL) {
        char cmd = 0;
        unsigned x = 0, y = 0;
        if (sscanf(line, " %c", &cmd) != 1) continue;
        t += 10;
        switch (cmd) {
        case 'm':
            if (sscanf(line, " m %u %u", &x, &y) == 2) {
                zwlr_virtual_pointer_v1_motion_absolute(vp, t, x, y, w, h);
                zwlr_virtual_pointer_v1_frame(vp);
            }
            break;
        case 'p':
            zwlr_virtual_pointer_v1_button(vp, t, BTN_LEFT, WL_POINTER_BUTTON_STATE_PRESSED);
            zwlr_virtual_pointer_v1_frame(vp);
            break;
        case 'r':
            zwlr_virtual_pointer_v1_button(vp, t, BTN_LEFT, WL_POINTER_BUTTON_STATE_RELEASED);
            zwlr_virtual_pointer_v1_frame(vp);
            break;
        case 'P':
            zwlr_virtual_pointer_v1_button(vp, t, BTN_RIGHT, WL_POINTER_BUTTON_STATE_PRESSED);
            zwlr_virtual_pointer_v1_frame(vp);
            break;
        case 'R':
            zwlr_virtual_pointer_v1_button(vp, t, BTN_RIGHT, WL_POINTER_BUTTON_STATE_RELEASED);
            zwlr_virtual_pointer_v1_frame(vp);
            break;
        case 'a': {
            // Vertical scroll by <value> logical px (positive = down). The
            // protocol's axis value is wl_fixed (24.8), so scale by 256.
            int v = 0;
            if (sscanf(line, " a %d", &v) == 1) {
                zwlr_virtual_pointer_v1_axis(vp, t, WL_POINTER_AXIS_VERTICAL_SCROLL,
                                             wl_fixed_from_int(v));
                zwlr_virtual_pointer_v1_frame(vp);
            }
            break;
        }
        case 'q':
            goto done;
        default:
            break;
        }
        wl_display_flush(dpy);
    }
done:
    zwlr_virtual_pointer_v1_destroy(vp);
    wl_display_roundtrip(dpy);
    wl_display_disconnect(dpy);
    return 0;
}
