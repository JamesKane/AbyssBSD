#!/bin/sh
# AbyssBSD Swift DE — the Wayland boundary of a jail (PHASE18 P18.3).
#
# A client that came in through a socket registered with wp_security_context_v1
# is jailed: it is shown an allowlist of globals, and nothing that watches,
# drives or captures anyone else. No jail is needed to prove it — the context
# is the compositor's whole knowledge of the jail — so this runs on Linux and
# FreeBSD alike. secctx.c plays the session's part. Claims:
#
#   1. an ordinary client is shown screencopy, virtual input, the session
#      lock, layer shell and the security-context manager (the comparison);
#   2. a jailed client is shown what an application needs and none of those —
#      everything it is shown is on the allowlist;
#   3. a jailed client that binds screencopy by its number (learned from an
#      ordinary listing) is refused — hidden is not merely unlisted;
#   4. a jailed window maps, and undertow says which context it came through;
#      an ordinary window is not called jailed;
#   5. when the engine lets go of the context, its socket stops taking clients.
#
# Usage: abyss/tests/live-jail-wayland.sh
set -eu
root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"
. "$root/abyss/common.sh"
abyss_ensure_runtime_dir

undertow="$root/.build/debug/undertow"
[ -x "$undertow" ] || swift build
command -v wayland-scanner >/dev/null 2>&1 || { echo "note: no wayland-scanner, skipping"; exit 0; }
protos=$(pkg-config --variable=pkgdatadir wayland-protocols)
sc="$protos/staging/security-context/security-context-v1.xml"
[ -f "$sc" ] || { echo "note: no security-context-v1.xml in wayland-protocols, skipping"; exit 0; }

work=$(mktemp -d /tmp/abyss-jw.XXXXXX)
cleanup() {
  exec 3>&- 5>&- 6>&- 2>/dev/null || true
  for p in ${sx:-} ${wj:-} ${wo:-} ${ut_pid:-}; do kill "$p" 2>/dev/null || true; done
  rm -rf "$work" 2>/dev/null || true
}
trap cleanup EXIT INT TERM HUP
trap '' PIPE
fail() { echo "FAIL: $1"; tail -3 "$work/ut.err" 2>/dev/null | sed 's/^/  undertow| /'; exit 1; }
count() { n=$(grep -c -- "$1" "$2" 2>/dev/null) || true; echo "${n:-0}"; }
await() { i=0; while [ "$(count "$2" "$1")" -lt "${4:-1}" ] && [ $i -lt 100 ]; do i=$((i + 1)); sleep 0.05; done
          [ "$(count "$2" "$1")" -ge "${4:-1}" ] || fail "$3"; }

wayland-scanner client-header "$sc" "$work/security-context-proto.h"
wayland-scanner private-code  "$sc" "$work/security-context-proto.c"
wayland-scanner client-header "$protos/staging/ext-session-lock/ext-session-lock-v1.xml" "$work/ext-session-lock-proto.h"
wayland-scanner private-code  "$protos/staging/ext-session-lock/ext-session-lock-v1.xml" "$work/ext-session-lock-proto.c"
cc -I"$work" abyss/tests/secctx.c "$work/security-context-proto.c" $(pkg-config --cflags --libs wayland-client) -o "$work/secctx" || fail "secctx"
cc abyss/tests/globals.c $(pkg-config --cflags --libs wayland-client) -o "$work/globals" || fail "globals"
cc -I"$work" -Ide/cwayland/include abyss/tests/lockclient.c de/cabyssprotocols/xdg-shell-protocol.c \
   "$work/ext-session-lock-proto.c" $(pkg-config --cflags --libs wayland-client) -o "$work/lockclient" || fail "lockclient"

env -u WAYLAND_DISPLAY "$undertow" run --hz 60 --frames 0 --width 800 --height 600 \
    --config-dir "$work" > "$work/ut.out" 2> "$work/ut.err" &
ut_pid=$!
await "$work/ut.out" '^WAYLAND_DISPLAY=' "undertow never announced a socket"
export WAYLAND_DISPLAY="$(grep -m1 '^WAYLAND_DISPLAY=' "$work/ut.out" | cut -d= -f2-)"
jsock="$work/jail-wayland"

# The interfaces that must never reach a jail, and what an application needs.
hidden="zwlr_screencopy_manager_v1 zwlr_virtual_pointer_manager_v1 zwp_virtual_keyboard_manager_v1
        ext_session_lock_manager_v1 zwlr_layer_shell_v1 zwlr_foreign_toplevel_manager_v1
        zwlr_output_manager_v1 ext_idle_notifier_v1 zwp_input_method_manager_v2
        abyss_window_manager_v1 wp_security_context_manager_v1"
needed="wl_compositor wl_shm wl_seat xdg_wm_base wl_output abyss_menu_manager_v1"
allow="wl_compositor wl_subcompositor wl_shm wl_seat wl_output wl_data_device_manager wl_drm
       xdg_wm_base zxdg_decoration_manager_v1 zxdg_output_manager_v1 wp_viewporter
       wp_fractional_scale_manager_v1 wp_presentation wp_single_pixel_buffer_manager_v1
       wp_cursor_shape_manager_v1 wp_linux_drm_syncobj_manager_v1 zwp_linux_dmabuf_v1
       xdg_activation_v1 zwp_text_input_manager_v3 zwp_pointer_constraints_v1
       zwp_relative_pointer_manager_v1 zwp_idle_inhibit_manager_v1 gtk_shell1 abyss_menu_manager_v1"
shown() { awk '$1 == "global" { print $3 }' "$1"; }

# ------------------------------------------------------------ 1. ordinary
"$work/globals" > "$work/plain" || fail "the ordinary client could not connect"
for i in $hidden; do
  shown "$work/plain" | grep -qx "$i" || fail "the ordinary client is not shown $i (the comparison proves nothing)"
done
echo "ok: 1. an ordinary client is shown all $(echo $hidden | wc -w | tr -d ' ') of the globals a jail must not have"

# ----------------------------------------------------------- 2. jailed
mkfifo "$work/sx"
"$work/secctx" "$jsock" org.abyssbsd.jail org.abyssbsd.probe 4242 < "$work/sx" > "$work/sx.log" 2>&1 & sx=$!
exec 3>"$work/sx"
await "$work/sx.log" '^registered' "the security context was not registered: $(cat "$work/sx.log")"
WAYLAND_DISPLAY="$jsock" "$work/globals" > "$work/jailed" || fail "the jailed client could not connect"
for i in $hidden; do
  shown "$work/jailed" | grep -qx "$i" && fail "a jailed client is shown $i"
done
for i in $needed; do
  shown "$work/jailed" | grep -qx "$i" || fail "a jailed client is not shown $i, which an application needs"
done
for i in $(shown "$work/jailed"); do
  echo $allow | tr ' ' '\n' | grep -qx "$i" || fail "a jailed client is shown $i, which is not on the allowlist"
done
echo "ok: 2. a jailed client is shown $(shown "$work/jailed" | wc -l | tr -d ' ') globals, all on the allowlist, none of the $(echo $hidden | wc -w | tr -d ' ')"

# ------------------------------------------------- 3. bound by number
n=$(awk '$1 == "global" && $3 == "zwlr_screencopy_manager_v1" { print $2 }' "$work/plain")
WAYLAND_DISPLAY="$jsock" "$work/globals" bind "$n" zwlr_screencopy_manager_v1 > "$work/bind" 2>&1 || true
grep -qx refused "$work/bind" || fail "a jailed client bound screencopy by its number: $(tail -1 "$work/bind")"
"$work/globals" bind "$n" zwlr_screencopy_manager_v1 > "$work/bind2" 2>&1 || true
grep -qx bound "$work/bind2" || fail "an ordinary client could not bind screencopy by number (the refusal proves nothing): $(tail -1 "$work/bind2")"
echo "ok: 3. screencopy bound by its number is refused to a jail (and allowed to an ordinary client)"

# --------------------------------------------------------- 4. a window
# Without fd 3: a client holding secctx's fifo would keep the engine from
# ever seeing EOF (HANDOFF §2.121).
mkfifo "$work/wj" "$work/wo"
WAYLAND_DISPLAY="$jsock" "$work/lockclient" window ff336699 org.abyssbsd.jailed < "$work/wj" > "$work/wj.log" 2>&1 3>&- & wj=$!
exec 5>"$work/wj"
"$work/lockclient" window ff993366 org.abyssbsd.free < "$work/wo" > "$work/wo.log" 2>&1 3>&- 5>&- & wo=$!
exec 6>"$work/wo"
await "$work/ut.out" '^window org.abyssbsd.jailed' "the jailed window did not map"
await "$work/ut.out" '^window org.abyssbsd.free' "the ordinary window did not map"
await "$work/ut.out" '^window-jail org.abyssbsd.jailed[^ ]* engine=org.abyssbsd.jail app=org.abyssbsd.probe instance=4242$' \
  "undertow did not say the jailed window came through the context"
sleep 0.3
grep -q '^window-jail org.abyssbsd.free' "$work/ut.out" && fail "the ordinary window was called jailed"
echo "ok: 4. the jailed window mapped and was named as the context's; the ordinary one was not"

# ------------------------------------------------- 5. the engine lets go
exec 3>&-
await "$work/sx.log" '^closed' "secctx did not let go"
i=0
while WAYLAND_DISPLAY="$jsock" timeout 2 "$work/globals" > "$work/after" 2>&1 && [ $i -lt 40 ]; do i=$((i + 1)); sleep 0.05; done
grep -q '^done' "$work/after" && fail "the context's socket still takes clients after the engine let go"
echo "ok: 5. once the engine let go, the jail's socket took no more clients"
exec 5>&- 6>&-
echo "all green (a jailed client sees an allowlist, cannot reach past it, and is named as the jail's)."
