// secctx — a sandbox engine's half of wp_security_context_v1, for tests
// (PHASE18 P18.3).
//
// It does what the session will do for each jail: binds a listening socket at
// PATH, registers it with the compositor through wp_security_context_manager_v1
// (engine, app id, instance), and keeps it registered until stdin closes. Every
// client that connects to PATH is then that context's — jailed.
//
// Not part of the product: compiled on demand by live-jail-wayland.sh.
//
// Usage: secctx PATH ENGINE APP_ID INSTANCE
//        prints "registered" once the compositor has the listener; on stdin's
//        EOF, closes its end of close_fd (the compositor stops listening) and
//        exits.

#include <wayland-client.h>
#include "security-context-proto.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

static struct wp_security_context_manager_v1 *g_mgr;

static void reg_global(void *data, struct wl_registry *reg, uint32_t name,
                       const char *iface, uint32_t version) {
    (void)data; (void)version;
    if (strcmp(iface, wp_security_context_manager_v1_interface.name) == 0)
        g_mgr = wl_registry_bind(reg, name, &wp_security_context_manager_v1_interface, 1);
}
static void reg_remove(void *data, struct wl_registry *reg, uint32_t name) {
    (void)data; (void)reg; (void)name;
}
static const struct wl_registry_listener reg_listener = { reg_global, reg_remove };

int main(int argc, char **argv) {
    if (argc != 5) { fprintf(stderr, "usage: secctx PATH ENGINE APP_ID INSTANCE\n"); return 2; }
    struct wl_display *d = wl_display_connect(NULL);
    if (!d) { fprintf(stderr, "secctx: cannot connect\n"); return 1; }
    struct wl_registry *reg = wl_display_get_registry(d);
    wl_registry_add_listener(reg, &reg_listener, NULL);
    wl_display_roundtrip(d);
    if (!g_mgr) { fprintf(stderr, "secctx: no wp_security_context_manager_v1\n"); return 1; }

    int ls = socket(AF_UNIX, SOCK_STREAM, 0);
    struct sockaddr_un sa = { .sun_family = AF_UNIX };
    snprintf(sa.sun_path, sizeof sa.sun_path, "%s", argv[1]);
    unlink(argv[1]);
    if (bind(ls, (struct sockaddr *)&sa, sizeof sa) < 0 || listen(ls, 8) < 0) { perror("secctx: bind"); return 1; }
    int closer[2];
    if (pipe(closer) < 0) { perror("secctx: pipe"); return 1; }

    struct wp_security_context_v1 *ctx = wp_security_context_manager_v1_create_listener(g_mgr, ls, closer[0]);
    wp_security_context_v1_set_sandbox_engine(ctx, argv[2]);
    wp_security_context_v1_set_app_id(ctx, argv[3]);
    wp_security_context_v1_set_instance_id(ctx, argv[4]);
    wp_security_context_v1_commit(ctx);
    wp_security_context_v1_destroy(ctx);
    close(ls); close(closer[0]);
    if (wl_display_roundtrip(d) < 0) { fprintf(stderr, "secctx: the compositor refused the context\n"); return 1; }
    printf("registered\n"); fflush(stdout);

    char buf[64];
    while (read(0, buf, sizeof buf) > 0) {}
    close(closer[1]);
    wl_display_roundtrip(d);
    printf("closed\n"); fflush(stdout);
    wl_display_disconnect(d);
    return 0;
}
