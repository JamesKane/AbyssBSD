#!/bin/sh
# AbyssBSD Swift DE — the pointer's picture (BACKLOG U.7).
#
# undertow drew a white rectangle for the pointer and ignored every client's
# cursor. Now the theme draws it (`cursor.*` draw lists), the compositor picks
# it where the pixels are its own, and the client with the pointer may set it —
# by name (cursor-shape-v1), with a surface of its own, or to nothing.
# `cursortest` stands for the client. Claims:
#
#   1. the theme's arrow is what a capture shows at the pointer — its body
#      black, where the rectangle was white;
#   2. on a window's frame the pointer shows sizing arrows on the edges that
#      size (bottom, both bottom corners), and the arrow on the title bar;
#   3. a client without the pointer is refused (a shape, and later a
#      surface); with it, a shape by name is shown (text);
#   4. a client's own surface is shown, and a client may hide the pointer;
#   5. off the window, the arrow again; onto another window that sets no
#      cursor, the arrow — not the last client's picture; and back over the
#      first, its surface is where the pointer is, in the capture, hotspot
#      and all.
#
# Usage: abyss/tests/live-cursor.sh
set -eu
root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"
. "$root/abyss/common.sh"
abyss_ensure_runtime_dir

undertow="$root/.build/debug/undertow"
[ -x "$undertow" ] || swift build
command -v wayland-scanner >/dev/null 2>&1 || { echo "note: no wayland-scanner, skipping"; exit 0; }

work=$(mktemp -d /tmp/abyss-cursor.XXXXXX)
cleanup() {
  exec 3>&- 5>&- 6>&- 2>/dev/null || true
  for p in ${bp:-} ${ap:-} ${vp:-} ${ut_pid:-}; do kill "$p" 2>/dev/null || true; done
  rm -rf "$work" 2>/dev/null || true
}
trap cleanup EXIT INT TERM HUP
trap '' PIPE          # a dead helper fails the test, not the shell (§2.82)
fail() {
  echo "FAIL: $1"
  grep '^cursor ' "$work/ut.out" 2>/dev/null | sed 's/^/  undertow| /' | tail -5
  grep -m1 -E 'Assertion|Fatal|abort' "$work/ut.err" 2>/dev/null | sed 's/^/  undertow| /' || true
  exit 1
}
cur() { grep '^cursor ' "$work/ut.out" 2>/dev/null | tail -1; }
await_cursor() {  # await_cursor PATTERN WHY
  i=0
  while [ $i -lt 60 ]; do
    cur | grep -Eq "$1" && return 0
    sleep 0.05; i=$((i + 1))
  done
  fail "$2 (undertow: $(cur))"
}
pixel() {  # pixel FILE X Y -> "R G B"
  hdr=$(head -3 "$1" | wc -c | tr -d ' ')
  wid=$(sed -n 2p "$1" | cut -d' ' -f1)
  dd if="$1" bs=1 skip=$((hdr + ($3 * wid + $2) * 3)) count=3 2>/dev/null | od -An -tu1 | awk '{print $1, $2, $3}'
}

protos=$(pkg-config --variable=pkgdatadir wayland-protocols)
for x in "vpointer:$root/abyss/tests/wlr-virtual-pointer-unstable-v1.xml" \
         "cursor-shape:$root/protocols/cursor-shape-v1.xml" "tablet:$root/protocols/tablet-unstable-v2.xml" \
         "xdg-decoration:$protos/unstable/xdg-decoration/xdg-decoration-unstable-v1.xml"; do
  n=${x%%:*}; f=${x#*:}
  wayland-scanner client-header "$f" "$work/$n-proto.h"
  wayland-scanner private-code  "$f" "$work/$n-proto.c"
done
cc -I"$work" "$root/abyss/tests/vpointer.c" "$work/vpointer-proto.c" \
   $(pkg-config --cflags --libs wayland-client) -o "$work/vpointer" || fail "could not build vpointer"
cc -I"$work" -I"$root/de/cwayland/include" "$root/abyss/tests/cursortest.c" \
   "$root/de/cabyssprotocols/xdg-shell-protocol.c" "$work/cursor-shape-proto.c" "$work/tablet-proto.c" \
   "$work/xdg-decoration-proto.c" $(pkg-config --cflags --libs wayland-client wayland-cursor) -o "$work/cursortest" \
   || fail "could not build cursortest"

W=800; H=600

# ------------------------------------------------------ 1. the arrow
# Nothing connected: the pointer rests mid-display, and the capture shows it.
# The arrow's hotspot is its tip, so its tip is the pointer, (400,300), and
# (402,306) is inside its body; (409,302) was inside the old white rectangle
# (400,300 10x16) and is clear of the arrow.
env -u WAYLAND_DISPLAY "$undertow" run --hz 60 --frames 20 --width $W --height $H \
    --config-dir "$work" --capture "$work/idle.ppm" > "$work/idle.out" 2>&1 \
  || fail "the idle run failed: $(tail -2 "$work/idle.out")"
body=$(pixel "$work/idle.ppm" 402 306); old=$(pixel "$work/idle.ppm" 409 302)
[ "$body" = "0 0 0" ] || fail "the arrow's body at (402,306) is $body, not black"
[ "$old" != "255 255 255" ] || fail "(409,302) is white: the old rectangle is still drawn"
echo "ok: 1. the capture shows the theme's arrow at the pointer (its body black at 402,306; 409,302 is $old, not white)"

# ------------------------------------------------------ the live run
env -u WAYLAND_DISPLAY "$undertow" run --hz 60 --frames 900 --width $W --height $H \
    --config-dir "$work" --capture "$work/end.ppm" > "$work/ut.out" 2> "$work/ut.err" &
ut_pid=$!
i=0; wd=""
while [ $i -lt 60 ]; do
  wd=$(grep -m1 '^WAYLAND_DISPLAY=' "$work/ut.out" 2>/dev/null | cut -d= -f2-) || wd=""
  [ -n "$wd" ] && break
  sleep 0.1; i=$((i + 1))
done
[ -n "$wd" ] || fail "undertow never announced a socket"
export WAYLAND_DISPLAY="$wd"
mkfifo "$work/vp.in" "$work/a.in" "$work/b.in"
"$work/vpointer" $W $H < "$work/vp.in" > "$work/vp.log" 2>&1 &
vp=$!; exec 3>"$work/vp.in"
i=0; while ! grep -q ready "$work/vp.log" 2>/dev/null && [ $i -lt 60 ]; do sleep 0.1; i=$((i + 1)); done
"$work/cursortest" < "$work/a.in" > "$work/a.log" 2>&1 &
ap=$!; exec 5>"$work/a.in"
# Windows and the cursor are reported after undertow's 4 s warm-up (§2.83).
i=0; win=""
while [ -z "$win" ] && [ $i -lt 160 ]; do
  win=$(grep '^window org.abyssbsd.cursortest[/ ]' "$work/ut.out" | tail -1) || true; sleep 0.05; i=$((i + 1)); done
[ -n "$win" ] || fail "undertow never reported the window"
pos=$(printf '%s' "$win" | awk '{print $3}'); size=$(printf '%s' "$win" | awk '{print $4}')
wx=${pos%,*}; wy=${pos#*,}; ww=${size%x*}; wh=${size#*x}

# ------------------------------------------------------ 2. the frame
edge() {  # edge X Y SHAPE WHERE
  printf 'm %s %s\n' "$1" "$2" >&3
  await_cursor "^cursor shape:$3 " "on the frame's $4 the pointer is not $3"
}
edge $((wx + ww / 2)) $((wy + wh)) ns-resize "bottom edge"
edge $((wx + ww)) $((wy + wh)) nwse-resize "bottom-right corner"
edge $((wx - 1)) $((wy + wh)) nesw-resize "bottom-left corner"
edge $((wx + ww / 2)) $((wy - 10)) default "title bar"
echo "ok: 2. on the frame: ns-resize on the bottom edge, nwse and nesw on its corners, the arrow on the title bar"

# ------------------------------------------------------ 3. a shape by name
printf 's 9\n' >&5                                    # text, asked from the title bar: no pointer
await_cursor ' refused=1 ' "a client without the pointer was not refused"
cur | grep -q '^cursor shape:default ' || fail "a refused request changed the pointer: $(cur)"
px=$((wx + 100)); py=$((wy + 100))
printf 'm %s %s\n' $px $py >&3                        # it enters, and asks again
await_cursor '^cursor shape:text ' "over its window, the client's shape (text) was not shown"
echo "ok: 3. refused without the pointer; with it, the client's shape by name (text) is shown"

# ------------------------------------------------------ 4. its own surface, and none
printf 'c\n' >&5
await_cursor '^cursor client ' "the client's own cursor surface was not taken"
printf 'h\n' >&5
await_cursor '^cursor hidden ' "the client could not hide the pointer"
echo "ok: 4. the client's own surface is shown, and it can hide the pointer"

# ------------------------------------------------------ 5. off, and back
printf 'm 5 590\n' >&3
await_cursor '^cursor shape:default ' "off the window, the pointer did not go back to the arrow"
printf 'c\n' >&5                                       # its own surface, asked off the window
await_cursor ' refused=2 ' "a surface from a client without the pointer was not refused"
cur | grep -q '^cursor shape:default ' || fail "a refused surface replaced the arrow: $(cur)"
printf 'm %s %s\n' $px $py >&3
await_cursor '^cursor client ' "back over the window, the client's surface was not shown again"
# A second window that never sets a cursor, mapped over the first: the pointer
# moving onto it must not keep the first client's picture.
"$work/cursortest" org.abyssbsd.cursortest2 < "$work/b.in" > "$work/b.log" 2>&1 &
bp=$!; exec 6>"$work/b.in"
i=0; while ! grep -q '^window org.abyssbsd.cursortest2' "$work/ut.out" && [ $i -lt 60 ]; do sleep 0.05; i=$((i + 1)); done
printf 'm %s %s\n' $((px + 1)) $py >&3
await_cursor '^cursor shape:default ' "onto a window that sets no cursor, the last client's picture stayed"
exec 6>&-; wait "$bp" 2>/dev/null || true; bp=""
sleep 0.2
printf 'm %s %s\n' $px $py >&3
await_cursor '^cursor client ' "back over the first window, its surface was not shown again"
cur | grep -Eq ' rasterised=5$' || fail "undertow drew the shapes more than once each: $(cur)"
wait "$ut_pid" 2>/dev/null || true; ut_pid=""
# The surface is 16x16 with its hotspot at 3,4: it covers px-3..px+12, py-4..py+11.
in=$(pixel "$work/end.ppm" $((px - 2)) $((py - 3))); out=$(pixel "$work/end.ppm" $((px + 14)) $((py + 13)))
[ "$in" = "255 0 0" ] || fail "the capture at ($((px - 2)),$((py - 3))), inside the client's cursor, is $in, not its red"
[ "$out" = "51 102 153" ] || fail "at ($((px + 14)),$((py + 13))), outside it once the hotspot is applied, the capture is $out, not the window's blue"
echo "ok: 5. off the window, the arrow; onto a window that sets none, the arrow; back, the capture shows the client's surface at the pointer, offset by its hotspot (3,4)"
echo "ok: undertow: $(cur)"

echo "all green (the pointer's picture is the theme's, the frame's, or the client's — through undertow)."
