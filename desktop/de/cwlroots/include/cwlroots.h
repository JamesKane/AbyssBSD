/*
 * CWlroots — the C floor under `undertow` (PHASE6.md P6.2).
 *
 * The headline finding of the phase's spike (PHASE6.md §4.1) is that this file
 * is nearly empty: **Swift's C importer reads wlroots' headers directly.**
 * `wlr_backend_autocreate`, `wlr_output_commit_state`, `wlr_render_pass_add_rect`
 * and the rest are ordinary exported functions with ordinary structs, callable
 * from Swift with no binding layer at all. The sibling needed bindgen for this
 * (4946 generated lines in `wlsys`, plus a standing "regenerate in the VM and
 * pull the file back" hazard); we need none.
 *
 * What genuinely cannot cross into Swift is the same thing that could not in
 * Phase 1 (HANDOFF §2.1), one layer down: **libwayland's event model is macros.**
 *
 *   - `wl_signal_add` is a `static inline`, so Swift cannot call it.
 *   - `wl_container_of` is a `#define` doing offsetof arithmetic, so the
 *     standard "recover my struct from the embedded listener" step is
 *     unavailable — and that step is how EVERY wlroots event is delivered.
 *
 * So there is exactly one mechanism here: a listener that carries a Swift
 * context pointer and a C trampoline that recovers it. Everything wlroots
 * signals — new outputs, frame, present, commit, destroy, and every protocol
 * object in later passes — arrives through it.
 */
#ifndef ABYSS_CWLROOTS_H
#define ABYSS_CWLROOTS_H

#define WLR_USE_UNSTABLE 1

#include <wayland-server-core.h>
#include <wlr/backend.h>
#include <wlr/backend/headless.h>
/* **Which backend an output actually landed on, which is not what we asked
 * for.** `--backend auto` gives DRM on metal, a nested Wayland window inside a
 * session, or X11 — and §2.48's whole lesson is that those are three different
 * clocks wearing one name. A nested output reports *real* present timestamps
 * from somebody else's vblank, so "did we see a hardware clock" cannot tell it
 * apart from DRM. The backend can. */
#include <wlr/backend/drm.h>
#include <wlr/backend/wayland.h>
#include <wlr/backend/x11.h>
/* Phase 4: the backend that drives a real display, and the session that owns the
 * VT and the device descriptors it needs. `wlr_backend_autocreate` returns the
 * session as an out-parameter, so the type has to be visible even though we
 * never call anything on it — we only have to keep it alive. */
#include <wlr/backend/session.h>
#include <wlr/render/allocator.h>
#include <wlr/render/drm_format_set.h>
#include <wlr/render/pass.h>
#include <wlr/render/wlr_renderer.h>
#include <wlr/render/wlr_texture.h>
#include <wlr/types/wlr_buffer.h>
#include <wlr/types/wlr_compositor.h>
#include <wlr/types/wlr_data_device.h>
#include <wlr/types/wlr_foreign_toplevel_management_v1.h>
#include <wlr/types/wlr_input_device.h>
#include <wlr/types/wlr_layer_shell_v1.h>
#include <wlr/types/wlr_keyboard.h>
#include <wlr/types/wlr_output.h>
#include <wlr/types/wlr_pointer.h>
#include <wlr/types/wlr_screencopy_v1.h>
#include <wlr/types/wlr_seat.h>
#include <wlr/types/wlr_shm.h>
#include <wlr/types/wlr_subcompositor.h>
#include <wlr/types/wlr_xdg_activation_v1.h>
#include <wlr/types/wlr_xdg_decoration_v1.h>
#include <wlr/types/wlr_virtual_keyboard_v1.h>
#include <wlr/types/wlr_virtual_pointer_v1.h>
#include <wlr/types/wlr_xdg_shell.h>
#include <wlr/util/box.h>
#include <wlr/util/log.h>

/*
 * A wlroots/libwayland listener that carries a Swift context.
 *
 * `notify` is a Swift @convention(c) function; `ctx` is typically an
 * Unmanaged<T>.toOpaque(). The struct is heap-allocated because libwayland
 * keeps the pointer for the signal's life — HANDOFF §2.2, which this project
 * has now walked into twice (§2.35), so it is stated again here.
 */
typedef void (*tw_notify_fn)(void *ctx, void *data);

struct tw_listener {
    struct wl_listener listener;
    tw_notify_fn fn;
    void *ctx;
};

/* Attach to a wl_signal. Returns NULL on allocation failure. */
struct tw_listener *tw_listen(struct wl_signal *signal, tw_notify_fn fn, void *ctx);

/* Detach and free. Safe on NULL. MUST be called before the context it carries
 * is released, or the compositor delivers events into freed memory. */
void tw_listener_free(struct tw_listener *l);

/*
 * Menus (PHASE10.md P10.3) — the first protocols undertow implements itself.
 *
 * C for the same reason as the listener above, one layer over: the generated
 * `abyss_menubar_v1_send_focused` is a `static inline` around the *variadic*
 * `wl_resource_post_event`, and Swift can call neither. The rest lives here
 * because it is libwayland plumbing — implementation tables, `wl_list`s,
 * destroy listeners — and the policy (which surface has which address, what to
 * tell the bar when focus moves) is Swift's, through two hooks.
 *
 * The privileged socket is how a client earns `abyss_menubar_v1`: undertow
 * accepts its connections itself and calls `wl_client_create`, because
 * libwayland does not record which socket a client it accepted came through.
 * A global filter hides the menubar global from everyone else, and its bind
 * refuses a client that asks by name anyway.
 */
struct tw_menus;

struct tw_menu_hooks {
    void *ctx;
    /* A client set (or, with "", cleared) the menu address of one of its own
     * surfaces. */
    void (*set_address)(void *ctx, struct wlr_surface *surface, const char *address);
    /* A privileged client bound abyss_menubar_v1: send it the current state. */
    void (*menubar_bound)(void *ctx, struct wl_resource *menubar);
    /* GTK said where a surface's menus are (gtk_surface1.set_dbus_properties,
     * P10.6). Absent strings arrive as "". */
    void (*set_gtk_properties)(void *ctx, struct wlr_surface *surface,
                               const char *application_id, const char *app_menu_path,
                               const char *menubar_path, const char *window_object_path,
                               const char *application_object_path,
                               const char *unique_bus_name);
    /* A Qt/KDE client said where a surface's com.canonical.dbusmenu is
     * (org_kde_kwin_appmenu.set_address, P10.7). */
    void (*set_dbusmenu_address)(void *ctx, struct wlr_surface *surface,
                                 const char *service_name, const char *object_path);
    /* The menu bar asked to force-quit an application (abyss_menubar_v1 v2,
     * P10.8). Only a privileged client can have sent it. */
    void (*force_quit)(void *ctx, const char *app_id);
};

struct tw_menus *tw_menus_create(struct wl_display *display, const struct tw_menu_hooks *hooks);
void tw_menus_destroy(struct tw_menus *m);
/* Listen on `path` (absolute) for privileged clients. 0, or -errno. */
int tw_privileged_socket_add(struct tw_menus *m, const char *path);
bool tw_client_is_privileged(struct tw_menus *m, struct wl_client *client);
void tw_menubar_send_focused(struct wl_resource *menubar, uint32_t kind,
                             const char *address, const char *app_id);
void tw_menubar_send_focused_all(struct tw_menus *m, uint32_t kind,
                                 const char *address, const char *app_id);
int tw_menubar_count(struct tw_menus *m);
/* The pid of the client owning `resource`, or -1. */
int tw_client_pid_of(struct wl_resource *resource);
/* Tell GTK (gtk_shell1.capabilities, on bind) that the desktop shows a global
 * menu bar, so it stops drawing its own. Only when a bar will (PHASE10 §6.5). */
void tw_gtk_set_global_menus(struct tw_menus *m, bool on);

/*
 * Silence wlroots' own logging, or route it at a level. Not a macro problem —
 * a convenience, because wlr_log_init takes a callback we never want to set.
 */
void tw_log_silence(void);
void tw_log_verbose(void);

#endif /* ABYSS_CWLROOTS_H */
