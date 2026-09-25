/* CWlroots — the menu protocols undertow implements itself (PHASE10.md P10.3).
 * See the "menus" section of include/cwlroots.h for why this is C. */
#include "cwlroots.h"
#include "abyss-menu-v1-protocol.h"

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
    struct wl_global *menubar_global;
    struct wl_list menubars;        /* wl_resource links */
    struct wl_list privileged;      /* struct privileged_client */
    int privileged_fd;
    struct wl_event_source *privileged_source;
    char privileged_path[108];
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

/* ----------------------------------------------------------------- abyss_menubar_v1 */

static void menubar_destroy_request(struct wl_client *client, struct wl_resource *resource) {
    (void)client;
    wl_resource_destroy(resource);
}

static const struct abyss_menubar_v1_interface menubar_impl = {
    .destroy = menubar_destroy_request,
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

/* ---------------------------------------------------------------- who may see what */

static bool global_filter(const struct wl_client *client, const struct wl_global *global,
                          void *data) {
    struct tw_menus *m = data;
    if (global == m->menubar_global)
        return tw_client_is_privileged(m, (struct wl_client *)client);
    return true;
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
    m->menubar_global = wl_global_create(display, &abyss_menubar_v1_interface, 1,
                                         m, menubar_bind);
    if (!m->manager_global || !m->menubar_global) { tw_menus_destroy(m); return NULL; }
    wl_display_set_global_filter(display, global_filter, m);
    return m;
}

void tw_menus_destroy(struct tw_menus *m) {
    if (!m) return;
    wl_display_set_global_filter(m->display, NULL, NULL);
    if (m->manager_global) wl_global_destroy(m->manager_global);
    if (m->menubar_global) wl_global_destroy(m->menubar_global);
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
