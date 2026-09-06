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
 * Silence wlroots' own logging, or route it at a level. Not a macro problem —
 * a convenience, because wlr_log_init takes a callback we never want to set.
 */
void tw_log_silence(void);
void tw_log_verbose(void);

#endif /* ABYSS_CWLROOTS_H */
