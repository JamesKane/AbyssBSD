#!/bin/sh
# AbyssBSD Swift DE — the depth gadget sends a window to the back (P11.6).
#
# Depth is the one window operation Phase 11 adds, and it has two paths:
#
#   - a frame **undertow** draws (a foreign window's): the press is the
#     compositor's own, and it lowers the window directly;
#   - a frame the **toolkit** draws (an Aqua window's own chrome): the client
#     asks, over `abyss_window_manager_v1.lower` — xdg-shell has no request
#     for it — and the compositor does it.
#
# Aqua has no depth gadget (Jaguar had none), so both windows wear the test
# theme `abyss/tests/themes/chrome-test` — Aqua's look with `right = depth pill`
# — which is also the proof that a theme file lays the frame out on both sides:
# the gadget is clicked where the one layout function put it, on a frame each
# side drew for itself.
#
# What makes it assertable is undertow's `stack=` line (bottom to top): the
# gadget's only effect is where a window sits, and nothing else says.
#
# Usage: abyss/tests/live-depth.sh
set -eu

root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"
. "$root/abyss/common.sh"
abyss_ensure_runtime_dir

undertow="$root/.build/debug/undertow"
aqua="$root/.build/debug/AquaDemo"
[ -x "$undertow" ] && [ -x "$aqua" ] || swift build
command -v wayland-scanner >/dev/null 2>&1 || { echo "note: no wayland-scanner, skipping"; exit 0; }

work=$(mktemp -d /tmp/abyss-depth.XXXXXX)
cleanup() {
  exec 3>&- 2>/dev/null || true
  for p in ${vp_pid:-} ${fg_pid:-} ${app_pid:-} ${ut_pid:-}; do kill "$p" 2>/dev/null || true; done
  rm -rf "$work" 2>/dev/null || true
}
trap cleanup EXIT INT TERM HUP
fail() { echo "FAIL: $1"; exit 1; }
mkdir -p "$work/cfg"

# The test theme, for undertow and the Aqua window alike.
export ABYSS_THEME=chrome-test ABYSS_THEME_DIR="$root/abyss/tests/themes"

geom() { grep "^window $1 " "$work/ut.out" 2>/dev/null | tail -1 | cut -d' ' -f3,4; }
stack() { grep '^stack=' "$work/ut.out" 2>/dev/null | tail -1 | cut -d= -f2-; }
# Wait for the NEXT stack line to say $1 — counted from before the press, so a
# line printed earlier cannot satisfy it (HANDOFF §2.61).
expect_stack() {
  want=$1 since=$2 why=$3 i=0
  while [ $i -lt 40 ]; do
    now=$(grep -c '^stack=' "$work/ut.out" 2>/dev/null || true)
    [ "$now" -gt "$since" ] && [ "$(stack)" = "$want" ] && return 0
    sleep 0.25; i=$((i + 1))
  done
  fail "$why: the stack is '$(stack)', wanted '$want'"
}

deco_xml=""
for d in /usr/share/wayland-protocols /usr/local/share/wayland-protocols; do
  [ -f "$d/unstable/xdg-decoration/xdg-decoration-unstable-v1.xml" ] \
    && deco_xml="$d/unstable/xdg-decoration/xdg-decoration-unstable-v1.xml"
done
[ -n "$deco_xml" ] || { echo "SKIP: no xdg-decoration XML in wayland-protocols"; exit 0; }
wayland-scanner client-header "$deco_xml" "$work/xdg-decoration-unstable-v1-client-protocol.h"
wayland-scanner private-code  "$deco_xml" "$work/xdg-decoration-unstable-v1-protocol.c"
cc -I"$work" -I "$root/de/cwayland/include" "$root/abyss/tests/adversary.c" \
   "$root/de/cabyssprotocols/xdg-shell-protocol.c" "$work/xdg-decoration-unstable-v1-protocol.c" \
   $(pkg-config --cflags --libs wayland-client) -o "$work/adversary" \
  || fail "could not build the client that asks to be decorated"
xml="$root/abyss/tests/wlr-virtual-pointer-unstable-v1.xml"
wayland-scanner client-header "$xml" "$work/vpointer-proto.h"
wayland-scanner private-code  "$xml" "$work/vpointer-proto.c"
cc -I"$work" "$root/abyss/tests/vpointer.c" "$work/vpointer-proto.c" \
   $(pkg-config --cflags --libs wayland-client) -o "$work/vpointer" \
   || fail "could not build the virtual pointer"

env -u WAYLAND_DISPLAY "$undertow" run --frames 0 --width 800 --height 600 \
    --config-dir "$work/cfg" > "$work/ut.out" 2> "$work/ut.err" &
ut_pid=$!
wd=""; i=0
while [ $i -lt 80 ]; do
  wd=$(grep -m1 '^WAYLAND_DISPLAY=' "$work/ut.out" 2>/dev/null | cut -d= -f2-) || wd=""
  [ -n "$wd" ] && break
  kill -0 "$ut_pid" 2>/dev/null || fail "undertow exited before it announced a socket"
  sleep 0.25; i=$((i + 1))
done
[ -n "$wd" ] || fail "undertow never announced a socket"
grep -q "^Theme: Chrome Test from .*abyss/tests/themes/chrome-test/theme.ini" "$work/ut.err" "$work/ut.out" \
  || fail "undertow did not draw with the test theme: $(grep -h '^Theme:' "$work/ut.err" "$work/ut.out")"
echo "ok: undertow is up on $wd, with the chrome-test theme"

# ------------------------------------------------------------- two windows
aquakey="org.abyssbsd.aquademo/AbyssBSD"
fgkey="org.abyssbsd.undecorated/Foreign"
env WAYLAND_DISPLAY="$wd" ABYSS_CONFIG_DIR="$work/cfg" AQUA_SCENE=window \
    "$aqua" > "$work/app.log" 2>&1 &
app_pid=$!
i=0
while [ $i -lt 80 ]; do
  [ -n "$(geom "$aquakey")" ] && break
  kill -0 "$app_pid" 2>/dev/null || fail "the Aqua window exited: $(cat "$work/app.log")"
  sleep 0.25; i=$((i + 1))
done
[ -n "$(geom "$aquakey")" ] || fail "undertow never reported the Aqua window"
grep -q "^Theme: Chrome Test" "$work/app.log" \
  || fail "the Aqua window did not draw with the test theme: $(grep '^Theme:' "$work/app.log")"

env WAYLAND_DISPLAY="$wd" "$work/adversary" decorated 260 160 > "$work/fg.log" 2>&1 &
fg_pid=$!
i=0
while [ $i -lt 80 ]; do
  [ -n "$(geom "$fgkey")" ] && grep -q '^frame-rasterisations=[1-9]' "$work/ut.out" && break
  kill -0 "$fg_pid" 2>/dev/null || fail "the foreign client exited: $(cat "$work/fg.log")"
  sleep 0.25; i=$((i + 1))
done
[ -n "$(geom "$fgkey")" ] || fail "undertow never reported the foreign window"
[ "$(stack)" = "$aquakey $fgkey" ] || fail "the windows did not stack as opened: '$(stack)'"
echo "ok: two windows, the foreign one on top: $(stack)"

fifo="$work/pointer"
mkfifo "$fifo"
env WAYLAND_DISPLAY="$wd" "$work/vpointer" 800 600 < "$fifo" > "$work/vp.log" 2>&1 &
vp_pid=$!
exec 3> "$fifo"
sleep 1

# ------------------------------------- the foreign window's frame (undertow's)
#
# undertow's frame is the surface plus a 1 px border and the title bar. With
# `right = depth pill` and no pill on a foreign frame, depth is the last gadget
# on the right: its centre is 10 + 6.5 px in from the frame's right edge.
g=$(geom "$fgkey"); sx=${g%%,*}; rest=${g#*,}; sy=${rest%% *}; size=${g#* }; sw=${size%x*}
fx=$((sx - 1)); fw=$((sw + 2))
before=$(grep -c '^stack=' "$work/ut.out")
printf 'm %s %s\np\nr\n' "$((fx + fw - 17))" "$((sy - 22 + 11))" >&3
expect_stack "$fgkey $aquakey" "$before" "the depth gadget on undertow's frame did not lower the window"
grep -q 'lowers=1$' "$work/ut.out" || fail "undertow did not count the lower"
echo "ok: depth on undertow's frame sent the foreign window to the back"

# ------------------------------------------ the Aqua window's own chrome
#
# The toolkit's layout: the pill 8 px from the right (22 wide), depth 7 px
# left of it (13 wide) — centre 43.5 px in from the window's right edge. The
# window draws this itself; the press is the client's, and it ASKS.
g=$(geom "$aquakey"); ax=${g%%,*}; rest=${g#*,}; ay=${rest%% *}; size=${g#* }; aw=${size%x*}
before=$(grep -c '^stack=' "$work/ut.out")
printf 'm %s %s\np\nr\n' "$((ax + aw - 44))" "$((ay + 11))" >&3
expect_stack "$aquakey $fgkey" "$before" \
  "the Aqua window's own depth gadget did not lower it (abyss_window_manager_v1.lower)"
grep -q 'lowers=2$' "$work/ut.out" || fail "undertow did not count the client's lower"
echo "ok: depth on the Aqua window's own chrome asked undertow, and it went to the back"

exec 3>&- 2>/dev/null || true
echo "all green (depth, drawn and clicked on both sides from one layout)."
