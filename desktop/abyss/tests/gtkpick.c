/* AbyssBSD Swift DE — a stock GTK 3 application asking for a file (P8.3).
 *
 * This is the client the whole D-Bus phase exists for. It knows nothing about
 * AbyssBSD: it calls `gtk_file_chooser_native_new` and `gtk_native_dialog_run`,
 * which is how a GTK application has asked for a file since 3.20, and everything
 * after that — the portal check, the `handle_token`, the object path it
 * subscribes to, the D-Bus marshalling — is GTK's own code, unmodified.
 *
 * **GTK is dlopen'd, not linked.** Two reasons, in order of importance:
 *
 *   1. This repository does not acquire a build dependency on GTK. DESKTOP.md
 *      §1 rejects the stack outright ("No GTK … it pulls in D-Bus"), and it
 *      would be a poor joke for the test that proves we need none of it to be
 *      the thing that links it. Nothing in `Package.swift` changes for this file.
 *   2. It builds wherever the GTK *runtime* is installed, with no -devel package
 *      on either platform. The dev box has libgtk-3.so.0 and no headers; the
 *      guest has both. One `cc` line works on each.
 *
 * What is NOT weakened by that choice: the code path under test is GTK's, byte
 * for byte. dlsym finds the same exported functions a linker would have bound,
 * and `gtk_file_chooser_native_portal_show` runs either way.
 *
 * The one AbyssBSD-shaped thing here is what the program PRINTS, so a shell
 * script can assert on it:
 *
 *     uri=file:///…            what the portal answered
 *     path=/…                  the same, as a filename
 *     contents=…               what it read after opening that name itself
 *
 * Usage: gtkpick [directory-to-suggest]
 *
 * Note the argument: a DIRECTORY. This program has no way to name the file it
 * gets back, which is the confused-deputy property surviving the hop through
 * somebody else's protocol.
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef void *gp;

static void *gtk;

static void *need(const char *name) {
  void *s = dlsym(gtk, name);
  if (!s) {
    fprintf(stderr, "gtkpick: this libgtk has no %s\n", name);
    exit(2);
  }
  return s;
}

int main(int argc, char **argv) {
  /* "Is there a GTK on this box?" — asked without a display, a bus or a
   * compositor, so the harness can decide to skip before it starts five
   * processes. It answers with the same exit codes the real run uses. */
  int probe_only = argc > 1 && strcmp(argv[1], "--probe-only") == 0;
  const char *folder = (argc > 1 && !probe_only) ? argv[1] : NULL;

  /* The soname, not a path: the runtime linker knows where its own libraries
   * live, which differs between /usr/lib64 and /usr/local/lib. ABYSS_LIBGTK is
   * an override for an unusual install, not the normal route. */
  const char *soname = getenv("ABYSS_LIBGTK");
  if (!soname || !*soname) soname = "libgtk-3.so.0";
  gtk = dlopen(soname, RTLD_NOW | RTLD_GLOBAL);
  if (!gtk) {
    /* Exit 77, the automake convention for "skipped", so a box with no GTK
     * runtime is distinguishable from a box where GTK failed. A test that
     * cannot tell those apart eventually reports the second as the first. */
    fprintf(stderr, "gtkpick: no GTK 3 runtime (%s): %s\n", soname, dlerror());
    return 77;
  }

  int (*init_check)(int *, char ***) = need("gtk_init_check");
  /* Resolved before the probe returns, so "GTK is present" also means "this GTK
   * has a native file chooser" — a 3.18 would dlopen fine and fail later. */
  (void)need("gtk_file_chooser_native_new");
  if (probe_only) {
    fprintf(stderr, "gtkpick: %s has a native file chooser\n", soname);
    return 0;
  }

  gp (*window_new)(int) = need("gtk_window_new");
  void (*window_set_title)(gp, const char *) = need("gtk_window_set_title");
  void (*window_set_default_size)(gp, int, int) = need("gtk_window_set_default_size");
  void (*widget_show_all)(gp) = need("gtk_widget_show_all");
  int (*events_pending)(void) = need("gtk_events_pending");
  void (*main_iteration)(void) = need("gtk_main_iteration");
  gp (*native_new)(const char *, gp, int, const char *, const char *) =
      need("gtk_file_chooser_native_new");
  int (*dialog_run)(gp) = need("gtk_native_dialog_run");
  char *(*get_uri)(gp) = need("gtk_file_chooser_get_uri");
  char *(*get_filename)(gp) = need("gtk_file_chooser_get_filename");
  int (*set_folder)(gp, const char *) = need("gtk_file_chooser_set_current_folder");

  int ac = 1;
  char *av[2] = {argv[0], NULL};
  char **avp = av;
  if (!init_check(&ac, &avp)) {
    fprintf(stderr, "gtkpick: gtk_init_check failed — no display?\n");
    return 3;
  }

  /* A real toplevel. The app is a client of the compositor in its own right,
   * not merely a process that made a D-Bus call, and the live test asserts the
   * compositor is holding two windows: this one and the picker. */
  gp win = window_new(0 /* GTK_WINDOW_TOPLEVEL */);
  window_set_title(win, "Abyss GTK Client");
  window_set_default_size(win, 260, 160);
  widget_show_all(win);
  for (int i = 0; i < 500 && events_pending(); i++) main_iteration();
  fprintf(stderr, "gtkpick: window up\n");
  fflush(stderr);

  gp nat = native_new("Open a file", win, 0 /* GTK_FILE_CHOOSER_ACTION_OPEN */,
                      "Open", "Cancel");
  if (folder) set_folder(nat, folder);

  fprintf(stderr, "gtkpick: asking for a file\n");
  fflush(stderr);
  int resp = dialog_run(nat);
  fprintf(stderr, "gtkpick: response %d\n", resp);

  /* GTK_RESPONSE_ACCEPT. Anything else — including DELETE_EVENT, which is what
   * a portal error looks like from in here — is not a choice. */
  if (resp != -3) {
    printf("cancelled=%d\n", resp);
    return 1;
  }

  char *uri = get_uri(nat);
  char *path = get_filename(nat);
  printf("uri=%s\n", uri ? uri : "(none)");
  printf("path=%s\n", path ? path : "(none)");
  if (!path) return 4;

  /* Open it by name, with whatever authority this process already had. That is
   * the honest end of this protocol: FileChooser's Response carries `uris` and
   * has no descriptor in it, in any version (PHASE8.md §6.6). Our own apps get
   * an fd from `abyss-portal` and can read the file from inside a Capsicum
   * sandbox with no filesystem at all; this one cannot, and the difference is
   * the point rather than an omission. */
  FILE *f = fopen(path, "r");
  if (!f) {
    perror("gtkpick: open");
    return 4;
  }
  char buf[512];
  size_t n = fread(buf, 1, sizeof buf - 1, f);
  buf[n] = 0;
  fclose(f);
  printf("contents=%s", buf);
  return 0;
}
