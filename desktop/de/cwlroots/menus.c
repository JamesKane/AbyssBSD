/* CWlroots — the menu protocols undertow implements itself (PHASE10.md P10.3).
 * See the "menus" section of include/cwlroots.h for why this is C. */
#include "cwlroots.h"
#include "abyss-menu-v1-protocol.h"
#include "abyss-window-v1-protocol.h"
#include <wlr/types/wlr_xdg_shell.h>
#include "gtk-shell-protocol.h"

#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>

struct tw_menus {
    struct wl_display *display;
    struct tw_menu_hooks hooks;
    struct wl_global *manager_global;
    struct wl_global *window_global;      /* P11.6 */
    struct wl_global *menubar_global;
    /* Other globals only the privileged socket's clients are offered: the
     * session lock (PHASE16 P16.2c). */
    const struct wl_global *privileged_globals[4];
    int nprivileged_globals;
    struct wl_global *gtk_shell_global;   /* P10.6 */
    uint32_t gtk_capabilities;            /* sent on bind */
    struct wlr_security_context_manager_v1 *security;   /* PHASE18 P18.3 */
    struct wl_list menubars;        /* wl_resource links */
    struct wl_list privileged;      /* struct privileged_client */
    int privileged_fd;
    struct wl_event_source *privileged_source;
    char privileged_path[108];
};

struct tw_gtk_surface {
    struct tw_menus *menus;
    struct wl_resource *surface;   /* the wl_surface it decorates */
};

struct privileged_client {
    struct wl_client *client;
    struct wl_listener destroy;
    struct wl_list link;
};

/* ------------------------------------------------------------ abyss_menu_manager_v1 */

static void manager_destroy(struct wl_client *client, struct wl_resource *resource) {
    (void)client;
    wl_resource_destroy(resource);
}

static void manager_set_address(struct wl_client *client, struct wl_resource *resource,
                                struct wl_resource *surface, const char *address) {
    (void)client;
    struct tw_menus *m = wl_resource_get_user_data(resource);
    /* The surface argument is an object of THIS client's — libwayland resolves
     * the id in the sender's own namespace — so a client can only ever name its
     * own surfaces. That is the whole binding, and it is free. */
    struct wlr_surface *s = wlr_surface_from_resource(surface);
    if (m && s && m->hooks.set_address)
        m->hooks.set_address(m->hooks.ctx, s, address ? address : "");
}

/* Every request of the bound version gets a slot: a NULL one is a crash the
 * first time a client sends it (HANDOFF §2.3, from the server side). */
static const struct abyss_menu_manager_v1_interface manager_impl = {
    .destroy = manager_destroy,
    .set_address = manager_set_address,
};

static void manager_bind(struct wl_client *client, void *data, uint32_t version, uint32_t id) {
    struct wl_resource *r = wl_resource_create(client, &abyss_menu_manager_v1_interface,
                                               (int)version, id);
    if (!r) { wl_client_post_no_memory(client); return; }
    wl_resource_set_implementation(r, &manager_impl, data, NULL);
}

/* ------------------------------------------------------- abyss_window_manager_v1 */

static void window_manager_destroy(struct wl_client *client, struct wl_resource *resource) {
    (void)client;
    wl_resource_destroy(resource);
}

static void window_manager_lower(struct wl_client *client, struct wl_resource *resource,
                                 struct wl_resource *toplevel) {
    (void)client;
    struct tw_menus *m = wl_resource_get_user_data(resource);
    /* As with set_address: the id resolves in the sender's own namespace, so a
     * client can only ever lower its own windows. */
    struct wlr_xdg_toplevel *t = wlr_xdg_toplevel_from_resource(toplevel);
    if (m && t && t->base && t->base->surface && m->hooks.lower)
        m->hooks.lower(m->hooks.ctx, t->base->surface);
}

static void window_query_destroy(struct wl_client *client, struct wl_resource *resource) {
    (void)client;
    wl_resource_destroy(resource);
}

static const struct abyss_window_query_v1_interface window_query_impl = {
    .destroy = window_query_destroy,
};

static void window_manager_window_at(struct wl_client *client, struct wl_resource *resource,
                                     uint32_t id, int32_t x, int32_t y) {
    struct tw_menus *m = wl_resource_get_user_data(resource);
    struct wl_resource *q = wl_resource_create(client, &abyss_window_query_v1_interface, 1, id);
    if (!q) { wl_client_post_no_memory(client); return; }
    wl_resource_set_implementation(q, &window_query_impl, NULL, NULL);
    int32_t box[4] = {0, 0, 0, 0};
    char *app_id = NULL, *title = NULL;
    /* Answered at once: the question is about this instant's layout. */
    if (m && m->hooks.window_at && m->hooks.window_at(m->hooks.ctx, x, y, box, &app_id, &title)) {
        abyss_window_query_v1_send_window(q, box[0], box[1], box[2], box[3],
                                          app_id ? app_id : "", title ? title : "");
    } else {
        abyss_window_query_v1_send_none(q);
    }
    free(app_id);
    free(title);
}

static const struct abyss_window_manager_v1_interface window_manager_impl = {
    .destroy = window_manager_destroy,
    .lower = window_manager_lower,
    .window_at = window_manager_window_at,
};

static void window_manager_bind(struct wl_client *client, void *data, uint32_t version, uint32_t id) {
    struct wl_resource *r = wl_resource_create(client, &abyss_window_manager_v1_interface,
                                               (int)version, id);
    if (!r) { wl_client_post_no_memory(client); return; }
    wl_resource_set_implementation(r, &window_manager_impl, data, NULL);
}

/* ----------------------------------------------------------------- abyss_menubar_v1 */

static void menubar_destroy_request(struct wl_client *client, struct wl_resource *resource) {
    (void)client;
    wl_resource_destroy(resource);
}

static void menubar_force_quit(struct wl_client *client, struct wl_resource *resource,
                               const char *app_id) {
    (void)client;
    struct tw_menus *m = wl_resource_get_user_data(resource);
    if (m && app_id && m->hooks.force_quit) m->hooks.force_quit(m->hooks.ctx, app_id);
}

static void menubar_list_islands(struct wl_client *client, struct wl_resource *resource) {
    (void)client;
    struct tw_menus *m = wl_resource_get_user_data(resource);
    if (m && m->hooks.list_islands) m->hooks.list_islands(m->hooks.ctx, resource);
    else abyss_menubar_v1_send_islands_done(resource, "");
}

static void menubar_switch_island(struct wl_client *client, struct wl_resource *resource,
                                  const char *display, uint32_t island) {
    (void)client;
    struct tw_menus *m = wl_resource_get_user_data(resource);
    if (m && m->hooks.switch_island) m->hooks.switch_island(m->hooks.ctx, display ? display : "", island);
}

static void menubar_activate_window(struct wl_client *client, struct wl_resource *resource,
                                    uint32_t id) {
    (void)client;
    struct tw_menus *m = wl_resource_get_user_data(resource);
    if (m && m->hooks.activate_window) m->hooks.activate_window(m->hooks.ctx, id);
}

static void menubar_shoal_command(struct wl_client *client, struct wl_resource *resource,
                                  const char *verb, uint32_t arg) {
    (void)client;
    struct tw_menus *m = wl_resource_get_user_data(resource);
    if (m && verb && m->hooks.shoal_command) m->hooks.shoal_command(m->hooks.ctx, verb, arg);
}

static const struct abyss_menubar_v1_interface menubar_impl = {
    .destroy = menubar_destroy_request,
    .force_quit = menubar_force_quit,
    .list_islands = menubar_list_islands,
    .switch_island = menubar_switch_island,
    .activate_window = menubar_activate_window,
    .shoal_command = menubar_shoal_command,
};

static void menubar_resource_destroyed(struct wl_resource *resource) {
    /* Safe after tw_menus_destroy too: that re-initialises every link, and
     * removing a self-linked element touches nothing else. */
    wl_list_remove(wl_resource_get_link(resource));
}

static void menubar_bind(struct wl_client *client, void *data, uint32_t version, uint32_t id) {
    struct tw_menus *m = data;
    /* The filter already hid this global from everybody else; this is the
     * second lock on the same door, for a client that guesses the name. */
    if (!tw_client_is_privileged(m, client)) {
        wl_client_post_implementation_error(client, "abyss_menubar_v1 is not offered to you");
        return;
    }
    struct wl_resource *r = wl_resource_create(client, &abyss_menubar_v1_interface,
                                               (int)version, id);
    if (!r) { wl_client_post_no_memory(client); return; }
    wl_resource_set_implementation(r, &menubar_impl, m, menubar_resource_destroyed);
    wl_list_insert(&m->menubars, wl_resource_get_link(r));
    if (m->hooks.menubar_bound) m->hooks.menubar_bound(m->hooks.ctx, r);
}

void tw_menubar_send_focused(struct wl_resource *menubar, uint32_t kind,
                             const char *address, const char *app_id) {
    abyss_menubar_v1_send_focused(menubar, kind, address ? address : "",
                                  app_id ? app_id : "");
}

void tw_menubar_send_focused_all(struct tw_menus *m, uint32_t kind,
                                 const char *address, const char *app_id) {
    struct wl_resource *r;
    wl_resource_for_each(r, &m->menubars) {
        tw_menubar_send_focused(r, kind, address, app_id);
    }
}

int tw_menubar_count(struct tw_menus *m) { return wl_list_length(&m->menubars); }

void tw_menubar_send_island(struct wl_resource *menubar, const char *display, uint32_t island,
                            const char *name, uint32_t count, uint32_t is_main) {
    if (wl_resource_get_version(menubar) < ABYSS_MENUBAR_V1_ISLAND_SINCE_VERSION) return;
    abyss_menubar_v1_send_island(menubar, display ? display : "", island, name ? name : "",
                                 count, is_main);
}

void tw_menubar_send_island_all(struct tw_menus *m, const char *display, uint32_t island,
                                const char *name, uint32_t count, uint32_t is_main) {
    struct wl_resource *r;
    wl_resource_for_each(r, &m->menubars) {
        tw_menubar_send_island(r, display, island, name, count, is_main);
    }
}

void tw_menubar_send_window(struct wl_resource *menubar, uint32_t id, const char *display,
                            uint32_t island, const char *app_id, const char *title) {
    if (wl_resource_get_version(menubar) < ABYSS_MENUBAR_V1_WINDOW_SINCE_VERSION) return;
    abyss_menubar_v1_send_window(menubar, id, display ? display : "", island,
                                 app_id ? app_id : "", title ? title : "");
}

void tw_menubar_send_shoal(struct wl_resource *menubar, const char *display, uint32_t island,
                           uint32_t index, const char *name, uint32_t open) {
    if (wl_resource_get_version(menubar) < ABYSS_MENUBAR_V1_SHOAL_SINCE_VERSION) return;
    abyss_menubar_v1_send_shoal(menubar, display ? display : "", island, index, name ? name : "", open);
}

void tw_menubar_send_islands_done(struct wl_resource *menubar, const char *names) {
    if (wl_resource_get_version(menubar) < ABYSS_MENUBAR_V1_ISLANDS_DONE_SINCE_VERSION) return;
    abyss_menubar_v1_send_islands_done(menubar, names ? names : "");
}

/* ---------------------------------------------------------------- who may see what */

/* What a jailed client may bind (PHASE18 P18.3). Drawing, input while
 * focused, its own windows and its own menus. Not here, so hidden:
 * screencopy, virtual pointer and keyboard, input-method (a keyboard by
 * another name), session lock, layer shell, foreign-toplevel, output
 * management, idle notification (it watches the person), abyss's window and
 * menu-bar globals (window_at names other windows), and the security-context
 * manager itself (a jail does not make more jails). */
static const char *const jailed_allowlist[] = {
    "wl_compositor", "wl_subcompositor", "wl_shm", "wl_seat", "wl_output",
    "wl_data_device_manager", "wl_drm",
    "xdg_wm_base", "zxdg_decoration_manager_v1", "zxdg_output_manager_v1",
    "wp_viewporter", "wp_fractional_scale_manager_v1", "wp_presentation",
    "wp_single_pixel_buffer_manager_v1", "wp_cursor_shape_manager_v1",
    "wp_linux_drm_syncobj_manager_v1", "zwp_linux_dmabuf_v1",
    "xdg_activation_v1", "zwp_text_input_manager_v3",
    "zwp_pointer_constraints_v1", "zwp_relative_pointer_manager_v1",
    "zwp_idle_inhibit_manager_v1",
    "gtk_shell1", "abyss_menu_manager_v1",
};

bool tw_jailed_may_bind(const char *interface) {
    for (size_t i = 0; i < sizeof jailed_allowlist / sizeof jailed_allowlist[0]; i++)
        if (strcmp(interface, jailed_allowlist[i]) == 0) return true;
    return false;
}

struct wlr_security_context_manager_v1 *tw_menus_enable_jails(struct tw_menus *m) {
    if (!m) return NULL;
    if (!m->security) m->security = wlr_security_context_manager_v1_create(m->display);
    return m->security;
}

bool tw_client_jail(struct tw_menus *m, struct wl_client *client,
                    const char **engine, const char **app_id, const char **instance) {
    if (!m || !m->security || !client) return false;
    const struct wlr_security_context_v1_state *s =
        wlr_security_context_manager_v1_lookup_client(m->security, client);
    if (!s) return false;
    if (engine) *engine = s->sandbox_engine;
    if (app_id) *app_id = s->app_id;
    if (instance) *instance = s->instance_id;
    return true;
}

static bool global_filter(const struct wl_client *client, const struct wl_global *global,
                          void *data) {
    struct tw_menus *m = data;
    /* A jail first: nothing below may widen what it sees. */
    if (m->security && wlr_security_context_manager_v1_lookup_client(m->security, client))
        return tw_jailed_may_bind(wl_global_get_interface(global)->name);
    if (global == m->menubar_global)
        return tw_client_is_privileged(m, (struct wl_client *)client);
    for (int i = 0; i < m->nprivileged_globals; i++)
        if (global == m->privileged_globals[i])
            return tw_client_is_privileged(m, (struct wl_client *)client);
    return true;
}

void tw_menus_add_privileged_global(struct tw_menus *m, const struct wl_global *global) {
    if (m && global && m->nprivileged_globals < 4)
        m->privileged_globals[m->nprivileged_globals++] = global;
}

bool tw_client_is_privileged(struct tw_menus *m, struct wl_client *client) {
    struct privileged_client *p;
    wl_list_for_each(p, &m->privileged, link) {
        if (p->client == client) return true;
    }
    return false;
}

static void privileged_client_destroyed(struct wl_listener *listener, void *data) {
    (void)data;
    struct privileged_client *p = wl_container_of(listener, p, destroy);
    wl_list_remove(&p->link);
    free(p);
}

/* A connection on the privileged socket: WE create the client, which is the
 * only way to know which socket it came through — libwayland does not record
 * it for sockets it accepted itself. */
static int privileged_accept(int fd, uint32_t mask, void *data) {
    struct tw_menus *m = data;
    (void)mask;
    int c = accept(fd, NULL, NULL);
    if (c < 0) return 0;
    struct wl_client *client = wl_client_create(m->display, c);   /* takes the fd */
    if (!client) { close(c); return 0; }
    struct privileged_client *p = calloc(1, sizeof(*p));
    if (!p) { wl_client_destroy(client); return 0; }
    p->client = client;
    p->destroy.notify = privileged_client_destroyed;
    wl_client_add_destroy_listener(client, &p->destroy);
    wl_list_insert(&m->privileged, &p->link);
    return 0;
}

int tw_privileged_socket_add(struct tw_menus *m, const char *path) {
    if (m->privileged_fd >= 0) return -EEXIST;
    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    if (strlen(path) >= sizeof(addr.sun_path)) return -ENAMETOOLONG;
    strcpy(addr.sun_path, path);
    int fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (fd < 0) return -errno;
    unlink(path);   /* a socket left by a crash would make bind fail */
    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0 || chmod(path, 0600) != 0
        || listen(fd, 16) != 0) {
        int e = errno;
        close(fd);
        unlink(path);
        return -e;
    }
    struct wl_event_loop *loop = wl_display_get_event_loop(m->display);
    m->privileged_source = wl_event_loop_add_fd(loop, fd, WL_EVENT_READABLE,
                                                privileged_accept, m);
    if (!m->privileged_source) { close(fd); unlink(path); return -ENOMEM; }
    m->privileged_fd = fd;
    strcpy(m->privileged_path, path);
    return 0;
}

/* -------------------------------------------------------- gtk_shell1 (P10.6) */
/* GTK's own protocol, answered so that GTK says where its menus are
 * (set_dbus_properties) and — told the desktop shows a global menu bar — stops
 * drawing its own. Everything else it can ask is answered with nothing, and
 * every slot is filled: a NULL one is a crash on first use (HANDOFF §2.3). */

static void gs_noop(struct wl_client *c, struct wl_resource *r) { (void)c; (void)r; }
static void gs_noop_u(struct wl_client *c, struct wl_resource *r, uint32_t u) { (void)c; (void)r; (void)u; }
static void gs_noop_s(struct wl_client *c, struct wl_resource *r, const char *s) { (void)c; (void)r; (void)s; }
static void gs_noop_o(struct wl_client *c, struct wl_resource *r, struct wl_resource *o) { (void)c; (void)r; (void)o; }
static void gs_release(struct wl_client *c, struct wl_resource *r) { (void)c; wl_resource_destroy(r); }
static void gs_gesture(struct wl_client *c, struct wl_resource *r, uint32_t serial,
                       struct wl_resource *seat, uint32_t gesture) {
    (void)c; (void)r; (void)serial; (void)seat; (void)gesture;
}

static void gs_set_dbus_properties(struct wl_client *client, struct wl_resource *resource,
                                   const char *application_id, const char *app_menu_path,
                                   const char *menubar_path, const char *window_object_path,
                                   const char *application_object_path,
                                   const char *unique_bus_name) {
    (void)client;
    /* The gtk_surface1's user data names its wl_surface; see gs_get_gtk_surface. */
    struct tw_gtk_surface *g = wl_resource_get_user_data(resource);
    if (!g || !g->menus || !g->menus->hooks.set_gtk_properties) return;
    struct wlr_surface *s = wlr_surface_from_resource(g->surface);
    if (!s) return;
    g->menus->hooks.set_gtk_properties(g->menus->hooks.ctx, s,
        application_id ? application_id : "", app_menu_path ? app_menu_path : "",
        menubar_path ? menubar_path : "", window_object_path ? window_object_path : "",
        application_object_path ? application_object_path : "",
        unique_bus_name ? unique_bus_name : "");
}

static const struct gtk_surface1_interface gtk_surface_impl = {
    .set_dbus_properties = gs_set_dbus_properties,
    .set_modal = gs_noop,
    .unset_modal = gs_noop,
    .present = gs_noop_u,
    .request_focus = gs_noop_s,
    .release = gs_release,
    .titlebar_gesture = gs_gesture,
};

static void gtk_surface_destroyed(struct wl_resource *resource) {
    free(wl_resource_get_user_data(resource));
}

static void gs_get_gtk_surface(struct wl_client *client, struct wl_resource *resource,
                               uint32_t id, struct wl_resource *surface) {
    struct tw_gtk_surface *g = calloc(1, sizeof(*g));
    if (!g) { wl_client_post_no_memory(client); return; }
    g->menus = wl_resource_get_user_data(resource);
    g->surface = surface;
    struct wl_resource *r = wl_resource_create(client, &gtk_surface1_interface,
                                               wl_resource_get_version(resource), id);
    if (!r) { free(g); wl_client_post_no_memory(client); return; }
    wl_resource_set_implementation(r, &gtk_surface_impl, g, gtk_surface_destroyed);
}

static const struct gtk_shell1_interface gtk_shell_impl = {
    .get_gtk_surface = gs_get_gtk_surface,
    .set_startup_id = gs_noop_s,
    .system_bell = gs_noop_o,
    .notify_launch = gs_noop_s,
};

static void gtk_shell_bind(struct wl_client *client, void *data, uint32_t version, uint32_t id) {
    struct tw_menus *m = data;
    struct wl_resource *r = wl_resource_create(client, &gtk_shell1_interface, (int)version, id);
    if (!r) { wl_client_post_no_memory(client); return; }
    wl_resource_set_implementation(r, &gtk_shell_impl, m, NULL);
    gtk_shell1_send_capabilities(r, m->gtk_capabilities);
}

void tw_gtk_set_global_menus(struct tw_menus *m, bool on) {
    /* A bit per capability, `1 << (value - 1)` — which is how GTK reads it:
     * global_app_menu = 1 → bit 0, global_menu_bar = 2 → bit 1. */
    m->gtk_capabilities = on ? (1u << 0) | (1u << 1) : 0;
}

/* --------------------------------------------------------------------------- setup */

struct tw_menus *tw_menus_create(struct wl_display *display, const struct tw_menu_hooks *h) {
    struct tw_menus *m = calloc(1, sizeof(*m));
    if (!m) return NULL;
    m->display = display;
    m->hooks = *h;
    m->privileged_fd = -1;
    wl_list_init(&m->menubars);
    wl_list_init(&m->privileged);
    m->manager_global = wl_global_create(display, &abyss_menu_manager_v1_interface, 1,
                                         m, manager_bind);
    m->window_global = wl_global_create(display, &abyss_window_manager_v1_interface, 2,
                                        m, window_manager_bind);
    m->menubar_global = wl_global_create(display, &abyss_menubar_v1_interface, 4,
                                         m, menubar_bind);
    m->gtk_shell_global = wl_global_create(display, &gtk_shell1_interface, 5, m, gtk_shell_bind);
    if (!m->manager_global || !m->window_global || !m->menubar_global || !m->gtk_shell_global) {
        tw_menus_destroy(m); return NULL;
    }
    wl_display_set_global_filter(display, global_filter, m);
    return m;
}

void tw_menus_destroy(struct tw_menus *m) {
    if (!m) return;
    wl_display_set_global_filter(m->display, NULL, NULL);
    if (m->manager_global) wl_global_destroy(m->manager_global);
    if (m->window_global) wl_global_destroy(m->window_global);
    if (m->menubar_global) wl_global_destroy(m->menubar_global);
    if (m->gtk_shell_global) wl_global_destroy(m->gtk_shell_global);
    if (m->privileged_source) wl_event_source_remove(m->privileged_source);
    if (m->privileged_fd >= 0) { close(m->privileged_fd); unlink(m->privileged_path); }
    /* Detach whatever outlives us: resources and clients free their own
     * entries later, and must not write into this struct when they do. */
    struct wl_resource *r, *rt;
    wl_resource_for_each_safe(r, rt, &m->menubars) {
        wl_list_init(wl_resource_get_link(r));
        wl_resource_set_user_data(r, NULL);
    }
    struct privileged_client *p, *pt;
    wl_list_for_each_safe(p, pt, &m->privileged, link) wl_list_init(&p->link);
    free(m);
}

/* Who is on the other end of a toplevel: its client's process (P10.8). */
int tw_client_pid_of(struct wl_resource *resource) {
    if (!resource) return -1;
    pid_t pid = -1; uid_t uid; gid_t gid;
    wl_client_get_credentials(wl_resource_get_client(resource), &pid, &uid, &gid);
    return (int)pid;
}
