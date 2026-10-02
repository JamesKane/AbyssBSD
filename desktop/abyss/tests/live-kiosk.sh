#!/bin/sh
# AbyssBSD Swift DE — a window that starts fullscreen (BACKLOG F.1).
#
# `firefox --kiosk` asks for fullscreen before its first commit and then sends
# unset_maximized for a window that was never maximized. undertow "restored"
# from the box fullscreen had just saved — the pre-map 0×0 — and the window
# was configured 0×0 with the fullscreen state: a 1×1 window, on the 12700KF
# and in the harness alike. Claims, with a client that does exactly that:
#
#   1. it is configured the whole display, fullscreen, and maps at 0,0 at
#      that size — although windows.ini remembers a place for it, which on the
#      box moved the fullscreen window off the origin;
#   2. a window that sends the same stray unset_maximized without asking for
#      fullscreen keeps the size it chose (0×0: "you choose"), and maps at it;
#   3. the mirror: a window that asks to be maximized and then sends a stray
#      unset_fullscreen stays maximized, at the usable area's size.
#
# Usage: abyss/tests/live-kiosk.sh
set -eu
root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"
. "$root/abyss/common.sh"
abyss_ensure_runtime_dir
undertow="$root/.build/debug/undertow"
[ -x "$undertow" ] || swift build
command -v wayland-scanner >/dev/null 2>&1 || { echo "note: no wayland-scanner, skipping"; exit 0; }

work=$(mktemp -d /tmp/abyss-kiosk.XXXXXX)
cleanup() { exec 3>&- 4>&- 5>&- 2>/dev/null || true; for p in ${a:-} ${b:-} ${c:-} ${ut:-}; do kill "$p" 2>/dev/null || true; done; rm -rf "$work"; }
trap cleanup EXIT INT TERM HUP
fail() { echo "FAIL: $1"; grep -E '^window' "$work/ut.out" | tail -4 | sed 's/^/  undertow| /'; exit 1; }
count() { n=$(grep -c -- "$1" "$2" 2>/dev/null) || true; echo "${n:-0}"; }
await() { i=0; while [ "$(count "$2" "$1")" -lt 1 ] && [ $i -lt 100 ]; do i=$((i + 1)); sleep 0.05; done
          [ "$(count "$2" "$1")" -ge 1 ] || fail "$3"; }

cc -I"$root/de/cwayland/include" abyss/tests/kioskclient.c de/cabyssprotocols/xdg-shell-protocol.c \
   $(pkg-config --cflags --libs wayland-client) -o "$work/kioskclient" || fail "cannot build kioskclient"

# A remembered place for the kiosk window, as the box had for Firefox: a
# fullscreen window must not go there.
printf '[windows]\norg.abyssbsd.kiosk = 24,35\n' > "$work/windows.ini"
env -u WAYLAND_DISPLAY "$undertow" run --hz 60 --frames 0 --width 2560 --height 1440 \
    --config-dir "$work" > "$work/ut.out" 2> "$work/ut.err" &
ut=$!
await "$work/ut.out" '^WAYLAND_DISPLAY=' "undertow never announced a socket"
export WAYLAND_DISPLAY="$(grep -m1 '^WAYLAND_DISPLAY=' "$work/ut.out" | cut -d= -f2-)"

# ------------------------------------------------------------- 1. kiosk
mkfifo "$work/a" "$work/b"
"$work/kioskclient" org.abyssbsd.kiosk < "$work/a" > "$work/a.log" 2>&1 & a=$!
exec 3>"$work/a"
await "$work/a.log" '^configure' "the kiosk window was never configured"
first=$(grep -m1 '^configure' "$work/a.log")
[ "$first" = "configure 2560 1440 fullscreen=1" ] || fail "the kiosk window was first configured '$first', not 2560×1440 fullscreen"
await "$work/ut.out" '^window org.abyssbsd.kiosk 0,0 2560x1440' "the kiosk window did not map at 0,0 2560×1440"
echo "ok: 1. fullscreen before the first commit, then unset_maximized: configured 2560×1440 fullscreen, mapped at 0,0 (not its remembered 24,35)"

# -------------------------------------------- 2. the stray unset, alone
"$work/kioskclient" org.abyssbsd.plain plain < "$work/b" > "$work/b.log" 2>&1 & b=$!
exec 4>"$work/b"
await "$work/b.log" '^configure' "the plain window was never configured"
first=$(grep -m1 '^configure' "$work/b.log")
[ "$first" = "configure 0 0 fullscreen=0" ] || fail "a never-maximized window's stray unset_maximized gave it '$first'"
await "$work/ut.out" '^window org.abyssbsd.plain ' "the plain window did not map"
echo "ok: 2. a stray unset_maximized on a never-maximized window changed nothing (configured 0×0, its own choice)"
# ------------------------------------------------------------- 3. the mirror
mkfifo "$work/c"
"$work/kioskclient" org.abyssbsd.maxed max < "$work/c" > "$work/c.log" 2>&1 & c=$!
exec 5>"$work/c"
await "$work/c.log" '^configure' "the maximized window was never configured"
first=$(grep -m1 '^configure' "$work/c.log")
case "$first" in
  "configure 0 0 "*|"configure 1 1 "*) fail "a maximized window's stray unset_fullscreen gave it '$first'" ;;
  "configure "*) ;;
esac
w=$(echo "$first" | awk '{print $2}')
[ "$w" -ge 2000 ] || fail "the maximized window was configured '$first' — not the display's width"
echo "ok: 3. a stray unset_fullscreen on a maximized window changed nothing ($first)"
echo "all green (a window that starts fullscreen gets the display, whatever it says next)."
