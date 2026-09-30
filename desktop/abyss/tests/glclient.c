/*
 * glclient.c — a Wayland GLES2 client that says which GPU drew it (PHASE4 §5.13).
 *
 * live-gpu.sh's GL half runs mesa-demos' es2gears_wayland, and FreeBSD's
 * mesa-demos 9.0 ships only the X11 gears: on the build guest and on the metal
 * stick there was no Wayland GL client at all, so the GL half never ran there.
 * This is the smallest one that can answer the questions that matter: does EGL
 * on the Wayland platform come up under undertow, which renderer did it get —
 * the GPU's driver, or llvmpipe, the software fallback that also "works" — and
 * does it keep drawing, paced by frame callbacks, for as long as asked.
 *
 * It opens an xdg-shell toplevel, clears it to a colour that changes every
 * frame, and after FRAMES frames prints one line and exits 0:
 *
 *   glclient: renderer <GL_RENDERER> frames <n> elapsed-ms <ms>
 *
 * Exit 1 with a sentence on any failure. Not part of the product.
 *
 *   cc glclient.c xdg-shell-protocol.c -I<dir with xdg-shell-client-protocol.h> \
 *      $(pkg-config --cflags --libs wayland-client wayland-egl egl glesv2)
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <wayland-client.h>
#include <wayland-egl.h>
#include <EGL/egl.h>
#include <GLES2/gl2.h>
#include "xdg-shell-client-protocol.h"

static struct wl_compositor *compositor;
static struct xdg_wm_base *wm_base;
static int configured, width = 320, height = 240, frames, want = 300, done_drawing;

static void die(const char *why) { fprintf(stderr, "glclient: %s\n", why); exit(1); }

static void ping(void *d, struct xdg_wm_base *b, uint32_t serial) { (void)d; xdg_wm_base_pong(b, serial); }
static const struct xdg_wm_base_listener wm_base_listener = { ping };

static void global(void *d, struct wl_registry *r, uint32_t name, const char *iface, uint32_t v) {
    (void)d; (void)v;
    if (strcmp(iface, "wl_compositor") == 0)
        compositor = wl_registry_bind(r, name, &wl_compositor_interface, 4);
    else if (strcmp(iface, "xdg_wm_base") == 0) {
        wm_base = wl_registry_bind(r, name, &xdg_wm_base_interface, 1);
        xdg_wm_base_add_listener(wm_base, &wm_base_listener, NULL);
    }
}
static void global_remove(void *d, struct wl_registry *r, uint32_t n) { (void)d; (void)r; (void)n; }
static const struct wl_registry_listener registry_listener = { global, global_remove };

static void surface_configure(void *d, struct xdg_surface *s, uint32_t serial) {
    (void)d; xdg_surface_ack_configure(s, serial); configured = 1;
}
static const struct xdg_surface_listener xdg_surface_listener = { surface_configure };

static void top_configure(void *d, struct xdg_toplevel *t, int32_t w, int32_t h, struct wl_array *s) {
    (void)d; (void)t; (void)s;
    if (w > 0 && h > 0) { width = w; height = h; }
}
static void top_close(void *d, struct xdg_toplevel *t) { (void)d; (void)t; done_drawing = 1; }
static const struct xdg_toplevel_listener toplevel_listener = { top_configure, top_close };

static void frame_done(void *d, struct wl_callback *cb, uint32_t t);
static const struct wl_callback_listener frame_listener = { frame_done };
static struct wl_surface *surface;
static EGLDisplay edpy;
static EGLSurface esurf;

static void draw(void) {
    float f = (float)(frames % 120) / 120.0f;
    glViewport(0, 0, width, height);
    glClearColor(f, 0.3f, 1.0f - f, 1.0f);
    glClear(GL_COLOR_BUFFER_BIT);
    struct wl_callback *cb = wl_surface_frame(surface);
    wl_callback_add_listener(cb, &frame_listener, NULL);
    if (!eglSwapBuffers(edpy, esurf)) die("eglSwapBuffers failed");
    frames++;
}

static void frame_done(void *d, struct wl_callback *cb, uint32_t t) {
    (void)d; (void)t;
    wl_callback_destroy(cb);
    if (frames >= want) done_drawing = 1; else draw();
}

static long long now_ms(void) {
    struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts);
    return (long long)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

int main(int argc, char **argv) {
    if (argc > 1) want = atoi(argv[1]);
    struct wl_display *dpy = wl_display_connect(NULL);
    if (!dpy) die("no Wayland display (WAYLAND_DISPLAY?)");
    struct wl_registry *reg = wl_display_get_registry(dpy);
    wl_registry_add_listener(reg, &registry_listener, NULL);
    wl_display_roundtrip(dpy);
    if (!compositor || !wm_base) die("the compositor offers no wl_compositor or xdg_wm_base");

    surface = wl_compositor_create_surface(compositor);
    struct xdg_surface *xs = xdg_wm_base_get_xdg_surface(wm_base, surface);
    xdg_surface_add_listener(xs, &xdg_surface_listener, NULL);
    struct xdg_toplevel *top = xdg_surface_get_toplevel(xs);
    xdg_toplevel_add_listener(top, &toplevel_listener, NULL);
    xdg_toplevel_set_title(top, "glclient");
    xdg_toplevel_set_app_id(top, "org.abyssbsd.glclient");
    wl_surface_commit(surface);
    while (!configured && wl_display_dispatch(dpy) != -1) {}

    edpy = eglGetDisplay((EGLNativeDisplayType)dpy);
    if (edpy == EGL_NO_DISPLAY || !eglInitialize(edpy, NULL, NULL)) die("EGL did not initialise on the Wayland platform");
    if (!eglBindAPI(EGL_OPENGL_ES_API)) die("no OpenGL ES API");
    const EGLint cfg_attr[] = { EGL_SURFACE_TYPE, EGL_WINDOW_BIT, EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8,
                                EGL_BLUE_SIZE, 8, EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT, EGL_NONE };
    EGLConfig cfg; EGLint n = 0;
    if (!eglChooseConfig(edpy, cfg_attr, &cfg, 1, &n) || n < 1) die("no EGL config for a GLES2 window");
    const EGLint ctx_attr[] = { EGL_CONTEXT_CLIENT_VERSION, 2, EGL_NONE };
    EGLContext ctx = eglCreateContext(edpy, cfg, EGL_NO_CONTEXT, ctx_attr);
    if (ctx == EGL_NO_CONTEXT) die("no GLES2 context");
    struct wl_egl_window *ew = wl_egl_window_create(surface, width, height);
    esurf = eglCreateWindowSurface(edpy, cfg, (EGLNativeWindowType)ew, NULL);
    if (esurf == EGL_NO_SURFACE || !eglMakeCurrent(edpy, esurf, esurf, ctx)) die("no EGL window surface");

    const char *renderer = (const char *)glGetString(GL_RENDERER);
    long long t0 = now_ms();
    draw();
    while (!done_drawing && wl_display_dispatch(dpy) != -1) {}
    printf("glclient: renderer %s frames %d elapsed-ms %lld\n",
           renderer ? renderer : "(none)", frames, now_ms() - t0);
    return frames >= want ? 0 : 1;
}
