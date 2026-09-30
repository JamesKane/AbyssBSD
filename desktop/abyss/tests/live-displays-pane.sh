#!/bin/sh
# AbyssBSD Swift DE — the Displays pane (PHASE14 P14.7c).
#
# System Preferences on undertow with two headless outputs, its Displays pane
# driven by the virtual pointer. Claims:
#
#   1. the page is the compositor's: its status line agrees with
#      `abyss-displays list` (itself checked against the layout in P14.7b);
#   2. dragging the second display's rectangle from beside the main one to
#      below it moves that display there — undertow's layout says so, snapped
#      to touch the main display's bottom edge;
#   3. choosing a scale of 2 for it applies — the layout halves its box;
#   4. a change made by someone else (`abyss-displays apply`) reaches the page.
#
# The same on both platforms: the one settings pane with no FreeBSD-only half.
# Coordinates come from the application's published layout (§2.46).
#
# Usage: abyss/tests/live-displays-pane.sh
set -eu
root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"
. "$root/abyss/common.sh"
abyss_ensure_runtime_dir

undertow="$root/.build/debug/undertow"
client="$root/.build/debug/AquaDemo"
menu="$root/.build/debug/abyssmenu"
ctl="$root/.build/debug/abyss-displays"
for b in "$undertow" "$client" "$menu" "$ctl"; do [ -x "$b" ] || { swift build; break; }; done
command -v wayland-scanner >/dev/null 2>&1 || { echo "note: no wayland-scanner, skipping"; exit 0; }

work=$(mktemp -d /tmp/abyss-disppane.XXXXXX)
rundir=$(mktemp -d /tmp/abyss-disppaner.XXXXXX)
cleanup() {
  exec 3>&- 2>/dev/null || true
  for p in ${vp_pid:-} ${app_pid:-} ${ut_pid:-}; do kill "$p" 2>/dev/null || true; done
  rm -rf "$work" "$rundir" 2>/dev/null || true
}
trap cleanup EXIT INT TERM HUP
export ABYSS_RUNTIME_DIR="$rundir"
mkdir -p "$work/cfg"
export ABYSS_CONFIG_DIR="$work/cfg"
fail() {
  echo "FAIL: $1"
  [ -s "$work/app.log" ] && grep 'displays' "$work/app.log" | sed 's/^/  app| /' | tail -10
  [ -s "$work/ut.err" ] && grep 'output-config' "$work/ut.err" | sed 's/^/  undertow| /' | tail -4
  exit 1
}
mark() { grep -c -- "$1" "$work/app.log" 2>/dev/null || true; }
await() {
  i=0
  while [ $i -lt 100 ]; do
    [ "$(mark "$1")" -gt "$2" ] && return 0
    sleep 0.05; i=$((i + 1))
  done
  fail "$3 (no new '$1' in the log)"
}
last() { grep -- "$1" "$work/app.log" | tail -1; }
ut_last_outputs() { grep '^outputs ' "$work/ut.out" | tail -1; }

wayland-scanner client-header "$root/abyss/tests/wlr-virtual-pointer-unstable-v1.xml" "$work/vpointer-proto.h"
wayland-scanner private-code  "$root/abyss/tests/wlr-virtual-pointer-unstable-v1.xml" "$work/vpointer-proto.c"
cc -I"$work" "$root/abyss/tests/vpointer.c" "$work/vpointer-proto.c" \
   $(pkg-config --cflags --libs wayland-client) -o "$work/vpointer" || fail "could not build vpointer"

wd="abyss-disppane-$$"
"$undertow" run --frames 0 --width 1024 --height 768 --output 800x600 --socket "$wd" \
   --config-dir "$work/cfg" > "$work/ut.out" 2> "$work/ut.err" &
ut_pid=$!
i=0; while [ ! -S "$XDG_RUNTIME_DIR/$wd" ] && [ $i -lt 100 ]; do i=$((i+1)); sleep 0.05; done
[ -S "$XDG_RUNTIME_DIR/$wd" ] || fail "undertow never bound $wd"
export WAYLAND_DISPLAY="$wd"

env AQUA_SCENE=sysprefs ABYSS_PREFS_DUMP=1 "$client" > "$work/app.log" 2>&1 &
app_pid=$!
await "System Preferences is up" 0 "the application never started"
i=0; geom=""
while [ -z "$geom" ] && [ $i -lt 60 ]; do
  geom=$(grep '^window org.abyssbsd.preferences/' "$work/ut.out" | head -1 | awk '{print $(NF-1)}')
  sleep 0.05; i=$((i + 1))
done
[ -n "$geom" ] || fail "undertow never reported the window"
wx=${geom%,*}; wy=${geom#*,}

# The virtual pointer is absolute over the layout's bounds, which a move
# changes; `v X Y` maps layout coordinates through the latest bounds.
VW=2000; VH=2000
fifo="$work/vp.fifo"; mkfifo "$fifo"
"$work/vpointer" "$VW" "$VH" < "$fifo" > "$work/vp.log" 2>&1 &
vp_pid=$!; exec 3>"$fifo"
i=0; while ! grep -q ready "$work/vp.log" 2>/dev/null && [ $i -lt 60 ]; do i=$((i+1)); sleep 0.1; done
grep -q ready "$work/vp.log" || fail "the virtual pointer never bound"
bounds() {  # -> "X0 Y0 W H" of the latest layout
  ut_last_outputs | sed 's/^outputs //' | tr ';' '\n' | awk '{
    split($2, a, "@"); split(a[1], wh, "x"); split(a[2], xy, ",");
    x = xy[1] + 0; y = xy[2] + 0; w = wh[1] + 0; h = wh[2] + 0;
    if (NR == 1 || x < x0) x0 = x; if (NR == 1 || y < y0) y0 = y;
    if (NR == 1 || x + w > x1) x1 = x + w; if (NR == 1 || y + h > y1) y1 = y + h }
    END { print x0, y0, x1 - x0, y1 - y0 }'
}
v() {  # v LAYOUT_X LAYOUT_Y -> vpointer coordinates
  set -- "$1" "$2" $(bounds)
  echo "$(( ($1 - $3) * VW / $5 )) $(( ($2 - $4) * VH / $6 ))"
}
at() {  # at NAME -> "X Y" in layout coordinates, from the pane's latest layout
  p=$(grep 'displays layout' "$work/app.log" | tail -1 | tr ' ' '\n' | sed -n "s/^$1=//p")
  [ -n "$p" ] || fail "the pane's layout does not say where $1 is"
  echo "$((wx + ${p%,*})) $((wy + ${p#*,}))"
}
sleep 0.4

# ------------------------------------------------------------ 1. the page
"$menu" run systempreferences view.pane.displays > /dev/null || fail "could not open Displays by its verb"
await "displays: status " 0 "the pane did not read the displays"
await "displays layout" 0 "the pane did not publish its layout"
status=$(last "displays: status " | sed 's/.*displays: status //')
want=$("$ctl" list | awk '/^display /{ split($3, m, "@"); s = $7; sub(/\.0$/, "", s);
       printf "%s%s %s at %s scale %s", (n++ ? "; " : ""), $2, m[1], $5, s }')
[ "$status" = "$want" ] || fail "the page is not the compositor's:
  pane:           $status
  abyss-displays: $want"
echo "ok: 1. the page is the compositor's: $status"

# ------------------------------------------------------------ 2. a drag
# HEADLESS-2 sits at 1024,0; drag it by (-1024, +768) in layout units — to
# below the main display — which is the pane's factor times that in pixels.
f=$(grep 'displays layout' "$work/app.log" | tail -1 | sed 's/.*factor=\([0-9.]*\).*/\1/')
set -- $(at disp.HEADLESS-2); sx=$1; sy=$2
dx=$(awk -v f="$f" 'BEGIN{printf "%d", -1024 * f / 1000}'); dy=$(awk -v f="$f" 'BEGIN{printf "%d", 768 * f / 1000}')
b=$(mark "displays: applied")
printf 'm %s\np\n' "$(v "$sx" "$sy")" >&3; sleep 0.1
for k in 1 2 3 4; do printf 'm %s\n' "$(v $((sx + dx * k / 4)) $((sy + dy * k / 4)))" >&3; sleep 0.08; done
printf 'r\n' >&3
await "displays: applied" "$b" "the drop was not applied"
i=0; while ! ut_last_outputs | grep -q 'HEADLESS-2 800x600@[0-9-]*,768' && [ $i -lt 30 ]; do sleep 0.1; i=$((i+1)); done
o=$(ut_last_outputs)
# Snapped: touching the main display's bottom edge, left edges lined up.
[ "$o" = "outputs HEADLESS-1 1024x768@0,0 main; HEADLESS-2 800x600@0,768" ] || fail "after the drag undertow's layout is: $o"
echo "ok: 2. dragged below the main display, snapped flush: $o"

# ------------------------------------------------------------ 3. a scale
await "displays layout .*scale.2=" 0 "no scale choices published"
sleep 0.3
b=$(mark "displays: applied")
printf 'm %s\np\nr\n' "$(v $(at scale.2))" >&3
await "displays: applied" "$b" "choosing scale 2 applied nothing"
i=0; while ! ut_last_outputs | grep -q 'HEADLESS-2 400x300@.* scale 2.0' && [ $i -lt 30 ]; do sleep 0.1; i=$((i+1)); done
ut_last_outputs | grep -qx 'outputs HEADLESS-1 1024x768@0,0 main; HEADLESS-2 400x300@0,768 scale 2.0' || fail "after scale 2: $(ut_last_outputs)"
echo "ok: 3. scale 2 for HEADLESS-2: its box halved to 400x300, still below the main display"

# ------------------------------------------------------ 4. someone else's
b=$(mark "displays: status .*HEADLESS-2 800x600 at 1024,0 scale 1")
"$ctl" apply HEADLESS-2:800x600:1024,0:1 > /dev/null || fail "abyss-displays could not apply"
await "displays: status .*HEADLESS-2 800x600 at 1024,0 scale 1" "$b" "a change made elsewhere did not reach the page"
echo "ok: 4. a change made by abyss-displays reached the page"

exec 3>&- 2>/dev/null || true
echo "all green (the Displays pane: arranged by dragging, scaled, and following the compositor)."
