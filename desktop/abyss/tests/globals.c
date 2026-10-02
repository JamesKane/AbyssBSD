// globals — what a Wayland client is shown, for tests (PHASE18 P18.3).
//
// Prints "global NAME INTERFACE" for each global the compositor advertises to
// this client, then "done". With "bind NAME INTERFACE", it then tries to bind
// that global by number — one it may not have been shown — and prints
// "bound" if the compositor let it, or "refused" if the connection died of it.
//
// Not part of the product: compiled on demand by live-jail-wayland.sh.

#include <wayland-client.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void reg_global(void *data, struct wl_registry *reg, uint32_t name,
                       const char *iface, uint32_t version) {
    (void)data; (void)reg; (void)version;
    printf("global %u %s\n", name, iface);
}
static void reg_remove(void *data, struct wl_registry *reg, uint32_t name) {
    (void)data; (void)reg; (void)name;
}
static const struct wl_registry_listener reg_listener = { reg_global, reg_remove };

int main(int argc, char **argv) {
    struct wl_display *d = wl_display_connect(NULL);
    if (!d) { printf("cannot connect\n"); return 1; }
    struct wl_registry *reg = wl_display_get_registry(d);
    wl_registry_add_listener(reg, &reg_listener, NULL);
    wl_display_roundtrip(d);
    printf("done\n"); fflush(stdout);
    if (argc == 4 && strcmp(argv[1], "bind") == 0) {
        /* Any interface struct will do for the request: the compositor checks
         * the name against what this client may see before anything else. */
        struct wl_interface fake = wl_registry_interface;
        fake.name = argv[3];
        fake.version = 1;
        wl_registry_bind(reg, (uint32_t)strtoul(argv[2], NULL, 10), &fake, 1);
        printf(wl_display_roundtrip(d) < 0 ? "refused\n" : "bound\n");
    }
    wl_display_disconnect(d);
    return 0;
}
