// portalcall — a foreign application's half of the FileChooser portal, in
// GLib's GDBus (BACKLOG D.1).
//
// The independent witness: it is not our D-Bus code, and it hears the
// Response the way a real application does — on its own connection, because
// the Response is addressed to it and ADE's bridge lets nobody else watch
// (PRODUCT §5.6). It subscribes first (the portal's ordering rule), calls,
// and prints what came back.
//
// Usage: portalcall OpenFile|SaveFile TOKEN [CURRENT_NAME|-] [CURRENT_FOLDER]
//        prints "response CODE" and one "uri URI" per file; exits 0 on a
//        Response, 1 on none within 60 s.
#include <gio/gio.h>
#include <stdio.h>
#include <string.h>

static GMainLoop *loop;
static int got = 0;

static void on_response(GDBusConnection *c, const gchar *sender, const gchar *path, const gchar *iface,
                        const gchar *signal, GVariant *params, gpointer data) {
    (void)c; (void)sender; (void)path; (void)iface; (void)signal; (void)data;
    guint32 code; GVariant *results;
    g_variant_get(params, "(u@a{sv})", &code, &results);
    printf("response %u\n", code);
    GVariant *uris = g_variant_lookup_value(results, "uris", G_VARIANT_TYPE("as"));
    if (uris) {
        GVariantIter it; const gchar *u;
        g_variant_iter_init(&it, uris);
        while (g_variant_iter_next(&it, "&s", &u)) printf("uri %s\n", u);
        g_variant_unref(uris);
    }
    g_variant_unref(results);
    fflush(stdout);
    got = 1;
    g_main_loop_quit(loop);
}

static gboolean give_up(gpointer data) { (void)data; g_main_loop_quit(loop); return FALSE; }

int main(int argc, char **argv) {
    if (argc < 3) { fprintf(stderr, "usage: portalcall OpenFile|SaveFile TOKEN [NAME]\n"); return 2; }
    GError *err = NULL;
    GDBusConnection *c = g_bus_get_sync(G_BUS_TYPE_SESSION, NULL, &err);
    if (!c) { printf("cannot connect: %s\n", err->message); return 1; }
    /* The Request's path, from our own name and token: subscribe before calling. */
    gchar *me = g_strdup(g_dbus_connection_get_unique_name(c) + 1);
    for (gchar *p = me; *p; p++) if (*p == '.') *p = '_';
    gchar *path = g_strdup_printf("/org/freedesktop/portal/desktop/request/%s/%s", me, argv[2]);
    g_dbus_connection_signal_subscribe(c, "org.freedesktop.portal.Desktop", "org.freedesktop.portal.Request",
                                       "Response", path, NULL, G_DBUS_SIGNAL_FLAGS_NO_MATCH_RULE, on_response, NULL, NULL);
    /* The rule too: a bridge delivers a broadcast only where asked. */
    gchar *rule = g_strdup_printf("type='signal',interface='org.freedesktop.portal.Request',path='%s'", path);
    g_dbus_connection_call_sync(c, "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus",
                                "AddMatch", g_variant_new("(s)", rule), NULL, 0, -1, NULL, NULL);
    GVariantBuilder opts;
    g_variant_builder_init(&opts, G_VARIANT_TYPE("a{sv}"));
    g_variant_builder_add(&opts, "{sv}", "handle_token", g_variant_new_string(argv[2]));
    if (argc > 3 && strcmp(argv[3], "-") != 0)
        g_variant_builder_add(&opts, "{sv}", "current_name", g_variant_new_string(argv[3]));
    /* current_folder is a bytestring with its NUL, as GTK sends it. */
    if (argc > 4) g_variant_builder_add(&opts, "{sv}", "current_folder", g_variant_new_bytestring(argv[4]));
    GVariant *r = g_dbus_connection_call_sync(c, "org.freedesktop.portal.Desktop", "/org/freedesktop/portal/desktop",
                                              "org.freedesktop.portal.FileChooser", argv[1],
                                              g_variant_new("(ssa{sv})", "", "Choose", &opts), G_VARIANT_TYPE("(o)"),
                                              0, -1, NULL, &err);
    if (!r) { printf("call failed: %s\n", err->message); return 1; }
    const gchar *handle; g_variant_get(r, "(&o)", &handle);
    printf("handle %s\n", handle); fflush(stdout);
    loop = g_main_loop_new(NULL, FALSE);
    g_timeout_add_seconds(60, give_up, NULL);
    g_main_loop_run(loop);
    return got ? 0 : 1;
}
