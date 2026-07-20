// vkeyboard — a virtual-keyboard test client for driving synthetic key input.
//
// The companion to vpointer.c. The headless sway backend attaches no input
// devices, so its seat advertises no keyboard capability and a client never
// binds wl_keyboard — the keyboard path can't be tested. This tool binds
// zwp_virtual_keyboard_manager_v1 and creates a virtual keyboard, which
// registers as a real input device: the seat gains the keyboard capability and
// the app under test binds wl_keyboard and receives events.
//
// The protocol requires the virtual keyboard to upload its own keymap before
// sending keys. wlroots then makes that the seat's active keymap and forwards
// it to clients (wl_keyboard.keymap), so both this tool and the app under test
// share one US keymap — the evdev keycodes we send resolve to the same letters
// the app decodes with xkbcommon. We build that keymap here with xkbcommon.
//
// Not part of the product — a test helper, compiled on demand by live-sway.sh
// against the vendored virtual-keyboard XML. Pure C, so the generated
// static-inline request wrappers are callable directly (no shim needed).
//
// Usage:  vkeyboard
// Commands (one per line on stdin):
//   t <text>       type <text> (the rest of the line), char by char
//   k <code>...     press+release each raw evdev keycode in turn (e.g. Tab=15,
//                   Space=57, Enter=28, Esc=1, Left=105, Right=106, Up=103,
//                   Down=108) — for non-text keys the toolkit reacts to by keysym
//   d <code>        press (hold down) a raw keycode — for testing key repeat
//   u <code>        release a raw keycode
//   q              quit (also on EOF)

#define _GNU_SOURCE  /* memfd_create */
#include <wayland-client.h>
#include "vkeyboard-proto.h"
#include <xkbcommon/xkbcommon.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/mman.h>

// wl_keyboard.key_state
#define KEY_RELEASED 0u
#define KEY_PRESSED  1u
// Shift as a modifier mask bit (index 0 in a standard xkb keymap).
#define MOD_SHIFT 1u

static struct wl_seat *g_seat = NULL;
static struct zwp_virtual_keyboard_manager_v1 *g_mgr = NULL;

static void reg_global(void *data, struct wl_registry *reg, uint32_t name,
                       const char *iface, uint32_t version) {
    (void)data; (void)version;
    if (strcmp(iface, wl_seat_interface.name) == 0) {
        g_seat = wl_registry_bind(reg, name, &wl_seat_interface, 1);
    } else if (strcmp(iface, zwp_virtual_keyboard_manager_v1_interface.name) == 0) {
        g_mgr = wl_registry_bind(reg, name,
                                 &zwp_virtual_keyboard_manager_v1_interface, 1);
    }
}
static void reg_remove(void *data, struct wl_registry *reg, uint32_t name) {
    (void)data; (void)reg; (void)name;
}
static const struct wl_registry_listener reg_listener = { reg_global, reg_remove };

// ASCII → (evdev keycode, needs shift). Covers the printable set a test needs;
// unknown characters are skipped. Codes are from linux/input-event-codes.h.
static int ascii_to_key(char c, unsigned *code, int *shift) {
    *shift = 0;
    if (c >= 'a' && c <= 'z') c = (char)(c - 'a' + 'A'), *shift = 0;
    else if (c >= 'A' && c <= 'Z') *shift = 1;
    switch (c) {
    case 'A': *code = 30; return 1;  case 'B': *code = 48; return 1;
    case 'C': *code = 46; return 1;  case 'D': *code = 32; return 1;
    case 'E': *code = 18; return 1;  case 'F': *code = 33; return 1;
    case 'G': *code = 34; return 1;  case 'H': *code = 35; return 1;
    case 'I': *code = 23; return 1;  case 'J': *code = 36; return 1;
    case 'K': *code = 37; return 1;  case 'L': *code = 38; return 1;
    case 'M': *code = 50; return 1;  case 'N': *code = 49; return 1;
    case 'O': *code = 24; return 1;  case 'P': *code = 25; return 1;
    case 'Q': *code = 16; return 1;  case 'R': *code = 19; return 1;
    case 'S': *code = 31; return 1;  case 'T': *code = 20; return 1;
    case 'U': *code = 22; return 1;  case 'V': *code = 47; return 1;
    case 'W': *code = 17; return 1;  case 'X': *code = 45; return 1;
    case 'Y': *code = 21; return 1;  case 'Z': *code = 44; return 1;
    case '1': *code = 2;  return 1;  case '2': *code = 3;  return 1;
    case '3': *code = 4;  return 1;  case '4': *code = 5;  return 1;
    case '5': *code = 6;  return 1;  case '6': *code = 7;  return 1;
    case '7': *code = 8;  return 1;  case '8': *code = 9;  return 1;
    case '9': *code = 10; return 1;  case '0': *code = 11; return 1;
    case ' ': *code = 57; return 1;  // KEY_SPACE
    default:  return 0;
    }
}

int main(void) {
    struct wl_display *dpy = wl_display_connect(NULL);
    if (dpy == NULL) { fprintf(stderr, "vkeyboard: cannot connect\n"); return 1; }

    struct wl_registry *reg = wl_display_get_registry(dpy);
    wl_registry_add_listener(reg, &reg_listener, NULL);
    wl_display_roundtrip(dpy);
    if (g_seat == NULL || g_mgr == NULL) {
        fprintf(stderr, "vkeyboard: compositor lacks wl_seat or "
                        "zwp_virtual_keyboard_manager_v1\n");
        return 2;
    }

    struct zwp_virtual_keyboard_v1 *vk =
        zwp_virtual_keyboard_manager_v1_create_virtual_keyboard(g_mgr, g_seat);

    // Build a default US keymap and hand it to the compositor over a fd.
    struct xkb_context *ctx = xkb_context_new(XKB_CONTEXT_NO_FLAGS);
    struct xkb_keymap *km =
        xkb_keymap_new_from_names(ctx, NULL, XKB_KEYMAP_COMPILE_NO_FLAGS);
    if (ctx == NULL || km == NULL) { fprintf(stderr, "vkeyboard: no keymap\n"); return 3; }
    char *str = xkb_keymap_get_as_string(km, XKB_KEYMAP_FORMAT_TEXT_V1);
    size_t size = strlen(str) + 1;

    int fd = memfd_create("vkeyboard-keymap", 0);
    if (fd < 0 || ftruncate(fd, (off_t)size) < 0) {
        fprintf(stderr, "vkeyboard: memfd failed\n"); return 4;
    }
    void *dst = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (dst == MAP_FAILED) { fprintf(stderr, "vkeyboard: mmap failed\n"); return 5; }
    memcpy(dst, str, size);
    munmap(dst, size);
    free(str);
    // format 1 == XKB_KEYMAP_FORMAT_TEXT_V1
    zwp_virtual_keyboard_v1_keymap(vk, 1, fd, (uint32_t)size);
    close(fd);
    wl_display_roundtrip(dpy);  // register the device + activate the keymap

    fprintf(stderr, "vkeyboard: ready\n");
    fflush(stderr);

    uint32_t t = 0;
    char line[512];
    while (fgets(line, sizeof line, stdin) != NULL) {
        if (line[0] == 'q') break;
        if (line[0] == 'k' && line[1] == ' ') {
            // Raw evdev keycodes, space-separated: press+release each.
            char *p = line + 2;
            while (*p) {
                while (*p == ' ' || *p == '\n') p++;
                if (*p < '0' || *p > '9') break;
                unsigned code = (unsigned)strtoul(p, &p, 10);
                t += 10;
                zwp_virtual_keyboard_v1_key(vk, t, code, KEY_PRESSED);
                zwp_virtual_keyboard_v1_key(vk, t + 1, code, KEY_RELEASED);
            }
            wl_display_flush(dpy);
            continue;
        }
        if ((line[0] == 'd' || line[0] == 'u') && line[1] == ' ') {
            // Hold down / release a single raw keycode (to exercise key repeat).
            unsigned code = (unsigned)strtoul(line + 2, NULL, 10);
            t += 10;
            zwp_virtual_keyboard_v1_key(vk, t, code,
                line[0] == 'd' ? KEY_PRESSED : KEY_RELEASED);
            wl_display_flush(dpy);
            continue;
        }
        if (line[0] != 't' || line[1] != ' ') continue;
        for (const char *p = line + 2; *p && *p != '\n'; p++) {
            unsigned code; int shift;
            if (!ascii_to_key(*p, &code, &shift)) continue;
            t += 10;
            if (shift) zwp_virtual_keyboard_v1_modifiers(vk, MOD_SHIFT, 0, 0, 0);
            zwp_virtual_keyboard_v1_key(vk, t, code, KEY_PRESSED);
            zwp_virtual_keyboard_v1_key(vk, t + 1, code, KEY_RELEASED);
            if (shift) zwp_virtual_keyboard_v1_modifiers(vk, 0, 0, 0, 0);
        }
        wl_display_flush(dpy);
    }

    zwp_virtual_keyboard_v1_destroy(vk);
    xkb_keymap_unref(km);
    xkb_context_unref(ctx);
    wl_display_roundtrip(dpy);
    wl_display_disconnect(dpy);
    return 0;
}
