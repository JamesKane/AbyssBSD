/* AbyssBSD Swift DE — a stock GtkApplication with a menubar (PHASE10 §4.1).
 *
 * The other end of Phase 10's foreign half: File (New, Open…, Quit) and Edit
 * (Copy, Paste — Paste disabled) as app.* actions, exported by GTK's own code on
 * the session bus as org.gtk.Menus / org.gtk.Actions. Quit is bound to
 * <Primary>q with set_accels_for_action, which is how §4.1 found that GTK does
 * NOT put accelerators in the exported model.
 *
 * dlopen'd rather than linked, for gtkpick.c's reasons. It prints, for a script:
 *
 *     ready shows-menubar=N    GTK's gtk-shell-shows-menubar, once the window maps
 *     activated=NAME           an action ran, whoever activated it
 *
 * Usage: gtkmenu   (exits 77 when there is no GTK 3 runtime)
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef void *gp;
static void *gtk;
static void *need(const char *n) {
  void *s = dlsym(gtk, n);
  if (!s) { fprintf(stderr, "no %s\n", n); exit(2); }
  return s;
}
#define F(ret, name, ...) static ret (*name)(__VA_ARGS__)
F(gp, gtk_application_new, const char *, int);
F(int, g_application_run, gp, int, char **);
F(unsigned long, g_signal_connect_data, gp, const char *, void *, gp, gp, int);
F(gp, g_menu_new, void);
F(void, g_menu_append, gp, const char *, const char *);
F(void, g_menu_append_submenu, gp, const char *, gp);
F(void, gtk_application_set_menubar, gp, gp);
F(gp, g_simple_action_new, const char *, gp);
F(void, g_action_map_add_action, gp, gp);
F(gp, gtk_application_window_new, gp);
F(void, gtk_widget_show_all, gp);
F(void, gtk_application_set_accels_for_action, gp, const char *, const char *const *);
F(const char *, g_action_get_name, gp);
F(void, g_simple_action_set_enabled, gp, int);
F(gp, gtk_settings_get_default, void);
F(void, g_object_get, gp, const char *, ...);

static gp menubar_model;
static int grown;
static void activated(gp action, gp param, gp data) {
  printf("activated=%s\n", g_action_get_name(action));
  fflush(stdout);
  // P10.9: with GTKMENU_GROW=1, New adds a Tools menu to the menubar while
  // the app runs — GTK announces it with org.gtk.Menus.Changed.
  if (getenv("GTKMENU_GROW") && !grown && !strcmp(g_action_get_name(action), "new")) {
    gp tools = g_menu_new();
    g_menu_append(tools, "Frobnicate", "app.frobnicate");
    g_menu_append_submenu(menubar_model, "Tools", tools);
    grown = 1;
    printf("grew Tools\n");
    fflush(stdout);
  }
}
static void startup(gp app, gp data) {
  const char *names[] = {"new", "open", "copy", "paste", "quit", "export-png", "export-pdf", "export-svg", "frobnicate"};
  for (int i = 0; i < 9; i++) {
    gp a = g_simple_action_new(names[i], NULL);
    g_signal_connect_data(a, "activate", activated, NULL, NULL, 0);
    if (i == 3 || i == 6) g_simple_action_set_enabled(a, 0);
    g_action_map_add_action(app, a);
  }
  const char *qa[] = {"<Primary>q", NULL};
  gtk_application_set_accels_for_action(app, "app.quit", qa);
  gp bar = g_menu_new(), file = g_menu_new(), edit = g_menu_new();
  g_menu_append(file, "New", "app.new");
  g_menu_append(file, "Open…", "app.open");
  // P10.8: with GTKMENU_SUBMENUS=1, File > Export ▸ (As PNG, As PDF —
  // disabled — and More ▸ As SVG): a submenu two deep, as real apps have.
  if (getenv("GTKMENU_SUBMENUS")) {
    gp export = g_menu_new(), more = g_menu_new();
    g_menu_append(export, "As PNG", "app.export-png");
    g_menu_append(export, "As PDF", "app.export-pdf");
    g_menu_append(more, "As SVG", "app.export-svg");
    g_menu_append_submenu(export, "More", more);
    g_menu_append_submenu(file, "Export", export);
  }
  g_menu_append(file, "Quit", "app.quit");
  g_menu_append(edit, "Copy", "app.copy");
  g_menu_append(edit, "Paste", "app.paste");
  g_menu_append_submenu(bar, "File", file);
  g_menu_append_submenu(bar, "Edit", edit);
  menubar_model = bar;
  gtk_application_set_menubar(app, bar);
}
static void activate(gp app, gp data) {
  gp w = gtk_application_window_new(app);
  gtk_widget_show_all(w);
  int shows = -1;
  g_object_get(gtk_settings_get_default(), "gtk-shell-shows-menubar", &shows, NULL);
  printf("ready shows-menubar=%d\n", shows);
  fflush(stdout);
}
int main(int argc, char **argv) {
  gtk = dlopen("libgtk-3.so.0", RTLD_NOW | RTLD_GLOBAL);
  if (!gtk) { fprintf(stderr, "%s\n", dlerror()); return 77; }
#define L(n) *(void **)&n = need(#n)
  L(gtk_application_new); L(g_application_run); L(g_signal_connect_data);
  L(g_menu_new); L(g_menu_append); L(g_menu_append_submenu);
  L(gtk_application_set_menubar); L(g_simple_action_new); L(g_action_map_add_action);
  L(gtk_application_window_new); L(gtk_widget_show_all);
  L(gtk_application_set_accels_for_action); L(g_action_get_name);
  L(g_simple_action_set_enabled); L(gtk_settings_get_default); L(g_object_get);
  gp app = gtk_application_new("org.abyss.MenuSpike", 0);
  g_signal_connect_data(app, "startup", startup, NULL, NULL, 0);
  g_signal_connect_data(app, "activate", activate, NULL, NULL, 0);
  return g_application_run(app, 1, argv);
}
