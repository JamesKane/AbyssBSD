#!/bin/sh
# AbyssBSD Swift DE — a surface's buffer, cropped, turned and scaled (BACKLOG U.8).
#
# undertow drew every client buffer whole and upright. `vptest` is the client,
# one mode per run of undertow, each checked in undertow's own capture:
#
#   1. viewporter: a buffer cropped to its right half and stretched to 300x200
#      shows only that half — green, its blue stripe in the middle, no red;
#   2. a buffer transform (90) is undone: a portrait buffer, red over green,
#      is a landscape window, green left and red right — not squashed;
#   3. fractional-scale: on a display at 1.5 the client is told 180/120 (and
#      2, the integer wl_surface v6 scale) once each, renders at 1.5x and says
#      through its viewport how big that is — and its one-pixel checkerboard
#      reaches the screen pixel for pixel.
#
# Usage: abyss/tests/live-viewport.sh
set -eu
root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"
. "$root/abyss/common.sh"
abyss_ensure_runtime_dir

undertow="$root/.build/debug/undertow"
[ -x "$undertow" ] || swift build
command -v wayland-scanner >/dev/null 2>&1 || { echo "note: no wayland-scanner, skipping"; exit 0; }

work=$(mktemp -d /tmp/abyss-viewport.XXXXXX)
cleanup() {
  for p in ${cp:-} ${ut_pid:-}; do kill "$p" 2>/dev/null || true; done
  rm -rf "$work" 2>/dev/null || true
}
trap cleanup EXIT INT TERM HUP
fail() {
  echo "FAIL: $1"
  sed 's/^/  vptest| /' "$work/c.log" 2>/dev/null | tail -6
  grep -E '^window org.abyssbsd.vptest' "$work/ut.out" 2>/dev/null | sed 's/^/  undertow| /' | tail -2
  exit 1
}
pixel() {  # pixel FILE X Y -> "R G B"
  hdr=$(head -3 "$1" | wc -c | tr -d ' ')
  wid=$(sed -n 2p "$1" | cut -d' ' -f1)
  dd if="$1" bs=1 skip=$(($hdr + ($3 * wid + $2) * 3)) count=3 2>/dev/null | od -An -tu1 | awk '{print $1, $2, $3}'
}

protos=$(pkg-config --variable=pkgdatadir wayland-protocols)
for x in "viewporter:$protos/stable/viewporter/viewporter.xml" \
         "fractional-scale:$protos/staging/fractional-scale/fractional-scale-v1.xml"; do
  n=${x%%:*}; f=${x#*:}
  wayland-scanner client-header "$f" "$work/$n-proto.h"
  wayland-scanner private-code  "$f" "$work/$n-proto.c"
done
cc -I"$work" -I"$root/de/cwayland/include" "$root/abyss/tests/vptest.c" \
   "$root/de/cabyssprotocols/xdg-shell-protocol.c" "$work/viewporter-proto.c" "$work/fractional-scale-proto.c" \
   $(pkg-config --cflags --libs wayland-client) -o "$work/vptest" || fail "could not build vptest"

# run MODE WIDTH HEIGHT [displays.ini line]: one undertow run of 6 s with the
# client, a capture at its end, and the window's box in WX WY WW WH.
run() {
  rm -rf "$work/cfg" 2>/dev/null || true; mkdir -p "$work/cfg"
  [ -z "${4:-}" ] || printf '[displays]\n%s\n' "$4" > "$work/cfg/displays.ini"
  env -u WAYLAND_DISPLAY "$undertow" run --hz 60 --frames 360 --width "$2" --height "$3" \
      --config-dir "$work/cfg" --capture "$work/$1.ppm" > "$work/ut.out" 2> "$work/ut.err" &
  ut_pid=$!
  i=0; wd=""
  while [ $i -lt 60 ]; do
    wd=$(grep -m1 '^WAYLAND_DISPLAY=' "$work/ut.out" 2>/dev/null | cut -d= -f2-) || wd=""
    [ -n "$wd" ] && break
    sleep 0.1; i=$((i + 1))
  done
  [ -n "$wd" ] || fail "undertow never announced a socket ($1)"
  WAYLAND_DISPLAY="$wd" "$work/vptest" "$1" > "$work/c.log" 2>&1 &
  cp=$!
  wait "$ut_pid" 2>/dev/null || true; ut_pid=""
  kill "$cp" 2>/dev/null || true; cp=""
  win=$(grep -E '^window org.abyssbsd.vptest[/ ]?[^ ]* -?[0-9]+,-?[0-9]+ [0-9]+x[0-9]+' "$work/ut.out" | tail -1)
  [ -n "$win" ] || fail "undertow never reported the $1 window ($(grep -c . "$work/c.log") client lines)"
  pos=$(printf '%s' "$win" | awk '{print $3}'); size=$(printf '%s' "$win" | awk '{print $4}')
  WX=${pos%,*}; WY=${pos#*,}; WW=${size%x*}; WH=${size#*x}
}

# ------------------------------------------------------ 1. crop
run crop 800 600
[ "${WW}x${WH}" = "300x200" ] || fail "the viewport's destination is 300x200; the window is ${WW}x${WH}"
# Sampled at y+160: the pointer rests mid-display, which is mid-window.
left=$(pixel "$work/crop.ppm" $((WX + 10)) $((WY + 160)))
mid=$(pixel "$work/crop.ppm" $((WX + 150)) $((WY + 160)))
right=$(pixel "$work/crop.ppm" $((WX + 290)) $((WY + 160)))
[ "$left" = "0 255 0" ] || fail "the cropped window's left edge is $left, not green (the crop's outside is drawn)"
[ "$mid" = "0 0 255" ] || fail "the cropped window's middle is $mid, not the blue stripe (the crop is not scaled into place)"
[ "$right" = "0 255 0" ] || fail "the cropped window's right edge is $right, not green"
echo "ok: 1. cropped to its right half and stretched to 300x200: green at both edges, the blue stripe in the middle, no red"

# ------------------------------------------------------ 2. turn
run turn 800 600
[ "${WW}x${WH}" = "200x100" ] || fail "a 100x200 buffer turned 90 is 200x100; the window is ${WW}x${WH}"
tl=$(pixel "$work/turn.ppm" $((WX + 50)) $((WY + 10))); bl=$(pixel "$work/turn.ppm" $((WX + 50)) $((WY + 90)))
tr=$(pixel "$work/turn.ppm" $((WX + 150)) $((WY + 10))); br=$(pixel "$work/turn.ppm" $((WX + 150)) $((WY + 90)))
[ "$tl" = "$bl" ] && [ "$tr" = "$br" ] || fail "the turned window is split top from bottom (tl $tl, bl $bl): drawn upright, squashed"
[ "$tl" = "0 255 0" ] && [ "$tr" = "255 0 0" ] \
  || fail "turned 90, the buffer's top (red) is on the right and its bottom (green) on the left; left is $tl, right $tr"
echo "ok: 2. a portrait buffer with transform 90 is a landscape window: green left, red right"

# ------------------------------------------------------ 3. fractional
run frac 1200 900 'HEADLESS-1 = 0,0 1200x900@0 1.5'
grep -q '^scale 180$' "$work/c.log" || fail "on a display at 1.5 the client was not told 180/120"
[ "$(grep -c '^scale ' "$work/c.log")" = 1 ] || fail "the preferred scale was sent $(grep -c '^scale ' "$work/c.log") times, not once"
grep -q '^bufscale 2$' "$work/c.log" || fail "the integer preferred_buffer_scale (2) was not sent"
[ "$(grep -c '^bufscale ' "$work/c.log")" = 1 ] || fail "preferred_buffer_scale was sent $(grep -c '^bufscale ' "$work/c.log") times, not once"
grep -q '^drew 300x150$' "$work/c.log" || fail "the client did not draw at 1.5x: $(grep '^drew' "$work/c.log" | tail -1)"
[ "${WW}x${WH}" = "200x100" ] || fail "its viewport says 200x100; the window is ${WW}x${WH}"
# Its box on the capture, in device pixels, and a run of pixels mid-window: a
# checkerboard drawn 1:1 alternates black and white exactly.
dx=$(awk "BEGIN{printf \"%d\", $WX * 1.5 + 0.5}"); dy=$(awk "BEGIN{printf \"%d\", $WY * 1.5 + 0.5}")
seq=""
for i in 0 1 2 3; do seq="$seq$(pixel "$work/frac.ppm" $((dx + 150 + i)) $((dy + 30)) | cut -d' ' -f1),"; done
case "$seq" in
  "255,0,255,0,"|"0,255,0,255,") ;;
  *) fail "mid-window the capture's pixels are $seq — not a checkerboard drawn pixel for pixel" ;;
esac
echo "ok: 3. at 1.5 the client was told 180/120 and 2 (once each), drew 300x150 into a 200x100 viewport, and reached the screen pixel for pixel ($seq)"

echo "all green (a buffer is cropped, turned and drawn at a fractional scale — through undertow)."
