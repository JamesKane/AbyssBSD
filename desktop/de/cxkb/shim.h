#ifndef ABYSS_CXKB_SHIM_H
#define ABYSS_CXKB_SHIM_H

/* xkbcommon translates raw evdev keycodes (from wl_keyboard.key) into keysyms
 * and UTF-8 text, honouring the keymap the compositor hands us over a fd.
 * Unlike libwayland's requests these are ordinary exported symbols, so Swift
 * calls them directly through this system module — no aw_* shim needed. */
#include <xkbcommon/xkbcommon.h>
#include <xkbcommon/xkbcommon-keysyms.h>  /* XKB_KEY_BackSpace, _Return, … */

#endif /* ABYSS_CXKB_SHIM_H */
