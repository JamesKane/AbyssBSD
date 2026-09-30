#!/bin/sh
# AbyssBSD Swift DE — a surface is told which outputs it is on (BACKLOG U.10).
#
# undertow never sent wl_surface.enter or leave, to any surface (HANDOFF §2.71),
# so a client could not learn its output — and so not its scale. With several
# outputs since P14.7 that is a window on a scale-2 display drawing at 1x.
#
# Two headless outputs: the main one at scale 1, a second at scale 2 (from
# displays.ini, as a person's choice would be). An Aqua window is dragged onto
# the second and back. Claims, each on the CLIENT's word — the toolkit picks
# its buffer scale from the outputs it has entered (Surface.Window):
#
#   1. on the main display, the window draws at 1x;
#   2. dragged onto the scale-2 display, it is told so and redraws at 2x — and
#      that display's capture holds the window;
#   3. dragged back, it leaves the scale-2 display and returns to 1x.
#
# Usage: abyss/tests/live-surface-enter.sh
set -eu
root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"
. "$root/abyss/common.sh"
abyss_ensure_runtime_dir

undertow="$root/.build/debug/undertow"
client="$root/.build/debug/AquaDemo"
[ -x "$undertow" ] && [ -x "$client" ] || swift build
command -v wayland-scanner >/dev/null 2>&1 || { echo "note: no wayland-scanner, skipping"; exit 0; }

work=$(mktemp -d /tmp/abyss-enter.XXXXXX)
cleanup() {
  exec 3>&- 2>/dev/null || true
  for p in ${vp_pid:-} ${win_pid:-} ${ut_pid:-}; do kill "$p" 2>/dev/null || true; done
  rm -rf "$work" 2>/dev/null || true
}
trap cleanup EXIT INT TERM HUP
fail() {
  echo "FAIL: $1"
  [ -s "$work/win.log" ] && grep -E 'buffer scale|output' "$work/win.log" | sed 's/^/  window| /' | tail -8
  [ -s "$work/ut.out" ] && grep -E '^(outputs|window)' "$work/ut.out" | sed 's/^/  undertow| /' | tail -6
  exit 1
}
mark() { grep -c -- "$1" "$work/win.log" 2>/dev/null || true; }
await() {  # await PATTERN BEFORE WHY
  i=0
  while [ $i -lt 100 ]; do
    [ "$(mark "$1")" -gt "$2" ] && return 0
    sleep 0.05; i=$((i + 1))
  done
  fail "$3 (no new '$1' in the window's log)"
}

wayland-scanner client-header "$root/abyss/tests/wlr-virtual-pointer-unstable-v1.xml" "$work/vpointer-proto.h"
wayland-scanner private-code  "$root/abyss/tests/wlr-virtual-pointer-unstable-v1.xml" "$work/vpointer-proto.c"
cc -I"$work" "$root/abyss/tests/vpointer.c" "$work/vpointer-proto.c" \
   $(pkg-config --cflags --libs wayland-client) -o "$work/vpointer" || fail "could not build vpointer"

# The second display at scale 2: 1600x1200 buffer pixels, 800x600 in the layout.
mkdir -p "$work/cfg"
printf '[displays]\nHEADLESS-2 = 640,0 1600x1200@0 2\n' > "$work/cfg/displays.ini"
env -u WAYLAND_DISPLAY "$undertow" run --hz 60 --frames 600 --width 640 --height 480 \
    --output 1600x1200 --config-dir "$work/cfg" --capture "$work/end.ppm" > "$work/ut.out" 2> "$work/ut.err" &
ut_pid=$!
i=0; wd=""
while [ $i -lt 60 ]; do
  wd=$(grep -m1 '^WAYLAND_DISPLAY=' "$work/ut.out" 2>/dev/null | cut -d= -f2-) || wd=""
  [ -n "$wd" ] && break
  sleep 0.1; i=$((i + 1))
done
[ -n "$wd" ] || fail "undertow never announced a socket"
grep -qx 'outputs HEADLESS-1 640x480@0,0 main; HEADLESS-2 800x600@640,0 scale 2.0' "$work/ut.out" \
  || fail "the layout: $(grep '^outputs' "$work/ut.out")"

env WAYLAND_DISPLAY="$wd" AQUA_SCENE=window "$client" > "$work/win.log" 2>&1 &
win_pid=$!
i=0; win=""
while [ -z "$win" ] && [ $i -lt 80 ]; do win=$(grep '^window org.abyssbsd.aquademo' "$work/ut.out" | tail -1) || true; sleep 0.1; i=$((i+1)); done
[ -n "$win" ] || fail "the window never mapped"
key=$(printf '%s' "$win" | awk '{print $2}'); pos=$(printf '%s' "$win" | awk '{print $3}')
size=$(printf '%s' "$win" | awk '{print $4}'); wx=${pos%,*}; wy=${pos#*,}; ww=${size%x*}; wh=${size#*x}

# ------------------------------------------------------------ 1. at 1x
sleep 0.5
grep -q 'buffer scale -> 2x' "$work/win.log" && fail "the window drew at 2x on the scale-1 display"
echo "ok: 1. on the main display the window draws at 1x"

# ------------------------------------------------------------ 2. onto 2x
fifo="$work/vp.fifo"; mkfifo "$fifo"
env WAYLAND_DISPLAY="$wd" "$work/vpointer" 1440 600 < "$fifo" > "$work/vp.log" 2>&1 &
vp_pid=$!; exec 3>"$fifo"
i=0; while ! grep -q ready "$work/vp.log" 2>/dev/null && [ $i -lt 60 ]; do i=$((i+1)); sleep 0.1; done
sleep 0.4
drag() {  # drag FROM_X FROM_Y TO_X TO_Y — by the title bar
  printf 'm %s %s\np\n' "$1" "$2" >&3; sleep 0.1
  for k in 1 2 3 4 5; do printf 'm %s %s\n' "$(($1 + ($3 - $1) * k / 5))" "$(($2 + ($4 - $2) * k / 5))" >&3; sleep 0.08; done
  printf 'r\n' >&3
}
b=$(mark 'buffer scale -> 2x')
tx=$((wx + ww / 2)); ty=$((wy + 11))
drag "$tx" "$ty" $((tx + 700 - wx)) "$ty"             # its left edge to x=700, on HEADLESS-2
await 'buffer scale -> 2x' "$b" "the window was not told it is on the scale-2 display"
nx=$(grep "^window $key " "$work/ut.out" | tail -1 | awk '{print $3}'); nx=${nx%,*}
[ "$nx" -ge 640 ] || fail "the drag did not carry the window onto HEADLESS-2 ($nx)"
echo "ok: 2. dragged onto the scale-2 display: told so (enter), and it redrew at 2x"

# ------------------------------------------------------------ 3. and back
b=$(mark 'buffer scale -> 1x')
drag $((nx + ww / 2)) "$ty" $((100 + ww / 2)) "$ty"
await 'buffer scale -> 1x' "$b" "the window was not told it left the scale-2 display"
echo "ok: 3. dragged back: it left the scale-2 display (leave), and returned to 1x"

# The capture half of claim 2 is taken at the end; put it back on HEADLESS-2.
b=$(mark 'buffer scale -> 2x')
drag $((100 + ww / 2)) "$ty" $((tx + 700 - wx)) "$ty"
await 'buffer scale -> 2x' "$b" "the second trip to the scale-2 display was not told"
exec 3>&-
wait "$ut_pid" 2>/dev/null || true; ut_pid=""
[ "$(sed -n 2p "$work/end.HEADLESS-2.ppm")" = "1600 1200" ] || fail "HEADLESS-2's capture is not its 2x mode"
nx=$(grep "^window $key [0-9-]*,[0-9-]* " "$work/ut.out" | tail -1 | awk '{print $3}'); ny=${nx#*,}; nx=${nx%,*}
hdr=$(head -3 "$work/end.HEADLESS-2.ppm" | wc -c | tr -d ' ')
cx=$(( (nx - 640 + ww / 2) * 2 )); cy=$(( (ny + wh / 2) * 2 ))
px=$(dd if="$work/end.HEADLESS-2.ppm" bs=1 skip=$((hdr + (cy * 1600 + cx) * 3)) count=3 2>/dev/null | od -An -tu1 | awk '{print $1, $2, $3}')
[ "$px" != "61 102 161" ] || fail "HEADLESS-2 shows bare desktop where the 2x window is ($cx,$cy)"
echo "ok: 2b. the scale-2 display's capture (1600x1200) holds the window ($px)"

echo "all green (a surface is told its outputs, and a window on a scale-2 display draws at 2x)."
