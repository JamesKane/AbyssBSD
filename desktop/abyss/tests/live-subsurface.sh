#!/bin/sh
# AbyssBSD Swift DE — a window made of subsurfaces, on our own compositor (U.1).
#
# undertow advertised `wl_subcompositor` from Phase 6 and never drew, framed or
# hit-tested a subsurface (docs/API-STUDY.md §1.3): each window was one texture
# and one rectangle. Our toolkit never makes a subsurface, so nothing here could
# see it; Firefox puts its whole page in one.
#
# `abyss/tests/subsurf.c` maps a red window with three children, each placed to
# catch a different wrong implementation (see its header):
#
#   A  blue    inside, desynchronised, redrawn on every frame callback
#   B  green   half outside the parent's top-right corner
#   C  yellow  placed BELOW the parent, half outside its left edge
#
# and this asserts three separate claims, because each can hold without the
# others:
#
#   1. framed — A keeps receiving frame callbacks (a desynchronised child
#      commits on its own clock, and one nobody answers draws once);
#   2. routed — the pointer enters the LEAF under it, in the leaf's own
#      coordinates, including where only a child is (B, C) and where the parent
#      covers a child placed below it;
#   3. drawn — the final frame has each colour where the tree's stacking puts it.
#
# The window's position comes from undertow's own `window <key> x,y WxH` line
# (HANDOFF §2.46: never put coordinates in a test that clicks).
#
# Usage: abyss/tests/live-subsurface.sh
set -eu

root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"
. "$root/abyss/common.sh"
abyss_ensure_runtime_dir

undertow="$root/.build/debug/undertow"
[ -x "$undertow" ] || swift build
command -v wayland-scanner >/dev/null 2>&1 || { echo "note: no wayland-scanner, skipping"; exit 0; }

W=800
H=600
KEY="org.abyssbsd.subsurf/subsurf"

work=$(mktemp -d /tmp/abyss-subsurf.XXXXXX)
cleanup() {
  exec 3>&- 2>/dev/null || true
  for p in ${vp_pid:-} ${app_pid:-} ${ut_pid:-}; do kill "$p" 2>/dev/null || true; done
  rm -rf "$work" 2>/dev/null || true
}
trap cleanup EXIT INT TERM HUP
fail() { echo "FAIL: $1"; exit 1; }

# ------------------------------------------------------------------ the tools
cc -I "$root/de/cwayland/include" "$root/abyss/tests/subsurf.c" \
   "$root/de/cabyssprotocols/xdg-shell-protocol.c" \
   $(pkg-config --cflags --libs wayland-client) -o "$work/subsurf" \
   || fail "could not build the subsurface client"
xml="$root/abyss/tests/wlr-virtual-pointer-unstable-v1.xml"
wayland-scanner client-header "$xml" "$work/vpointer-proto.h"
wayland-scanner private-code  "$xml" "$work/vpointer-proto.c"
cc -I"$work" "$root/abyss/tests/vpointer.c" "$work/vpointer-proto.c" \
   $(pkg-config --cflags --libs wayland-client) -o "$work/vpointer" \
   || fail "could not build the virtual pointer"

# ------------------------------------------------------------- the compositor
# 600 frames is ten seconds: time to map, drive five pointer moves, and still
# be composing when the capture is taken at the end.
ppm="$work/final.ppm"
env -u WAYLAND_DISPLAY "$undertow" run --hz 60 --frames 600 --width "$W" --height "$H" \
    --config-dir "$work" --capture "$ppm" > "$work/ut.out" 2> "$work/ut.err" &
ut_pid=$!
wd=""; i=0
while [ $i -lt 80 ]; do
  wd=$(grep -m1 '^WAYLAND_DISPLAY=' "$work/ut.out" 2>/dev/null | cut -d= -f2-) || wd=""
  [ -n "$wd" ] && break
  kill -0 "$ut_pid" 2>/dev/null || { cat "$work/ut.err"; fail "undertow exited before it announced a socket"; }
  sleep 0.1; i=$((i + 1))
done
[ -n "$wd" ] || fail "undertow never announced a socket"

# ----------------------------------------------------------------- the window
env WAYLAND_DISPLAY="$wd" "$work/subsurf" > "$work/app.log" 2>&1 &
app_pid=$!
geom() { grep "^window $KEY " "$work/ut.out" 2>/dev/null | tail -1 | cut -d' ' -f3,4; }
i=0
while [ $i -lt 80 ]; do
  [ -n "$(geom)" ] && break
  kill -0 "$app_pid" 2>/dev/null || fail "the client exited: $(cat "$work/app.log")"
  sleep 0.1; i=$((i + 1))
done
g=$(geom); [ -n "$g" ] || fail "undertow never reported the window"
X=${g%%,*}; rest=${g#*,}; Y=${rest%% *}; size=${g#* }
[ "$size" = "200x150" ] || fail "the window is $size; its parent surface is 200x150"
echo "ok: the window mapped at $X,$Y ($size)"

# 1. Framed. A asks for a frame callback on every commit; only a compositor
#    that walks the tree answers it. Sixty is two seconds of a live clock,
#    which a single callback sent by accident cannot fake.
i=0
while [ $i -lt 60 ]; do
  grep -q '^subsurf: A frames 60$' "$work/app.log" && break
  sleep 0.1; i=$((i + 1))
done
grep -q '^subsurf: A frames 60$' "$work/app.log" \
  || fail "the desynchronised subsurface stopped getting frame callbacks: $(grep 'A frames' "$work/app.log" | tail -1)"
echo "ok: a desynchronised subsurface keeps its own frame clock"

# ----------------------------------------------------------------- 2. routed
fifo="$work/pointer"
mkfifo "$fifo"
env WAYLAND_DISPLAY="$wd" "$work/vpointer" "$W" "$H" < "$fifo" > "$work/vp.log" 2>&1 &
vp_pid=$!
exec 3> "$fifo"
i=0
while [ $i -lt 30 ]; do grep -q ready "$work/vp.log" && break; sleep 0.1; i=$((i + 1)); done
grep -q ready "$work/vp.log" || fail "the virtual pointer never bound"
sleep 0.5                                   # let the client bind wl_pointer

# Move to a window-relative point and wait for the NEXT enter line to be the
# one expected — counted from before the move, so an earlier line cannot
# satisfy it (HANDOFF §2.61).
enter() {  # enter DX DY "EXPECTED" WHY
  since=$(grep -c '^subsurf: enter ' "$work/app.log" || true)
  printf 'm %s %s\n' "$((X + $1))" "$((Y + $2))" >&3
  i=0
  while [ $i -lt 30 ]; do
    now=$(grep -c '^subsurf: enter ' "$work/app.log" || true)
    if [ "$now" -gt "$since" ]; then
      got=$(grep '^subsurf: enter ' "$work/app.log" | tail -1 | cut -d' ' -f3-)
      [ "$got" = "$3" ] || fail "$4: the pointer entered '$got', wanted '$3'"
      echo "ok: $4 ($3)"
      return 0
    fi
    sleep 0.1; i=$((i + 1))
  done
  fail "$4: no enter at all — wanted '$3'"
}
enter  70  50 "A 30 20"      "a child over its parent gets the pointer, in its own coordinates"
enter  10  10 "parent 10 10" "the parent where no child is"
enter 220 -10 "B 50 10"      "a child outside its parent's rectangle is still reachable"
enter -20 100 "C 10 10"      "a child placed below its parent, where the parent is not"
enter  10 100 "parent 10 100" "...and the parent, where it covers that child"
printf 'm %s %s\n' "$((W - 10))" "$((H - 10))" >&3   # park the cursor off the window
exec 3>&-
wait "$vp_pid" 2>/dev/null || true
vp_pid=""

# ------------------------------------------------------------------ 3. drawn
rc=0; wait "$ut_pid" 2>/dev/null || rc=$?
ut_pid=""
[ "$rc" = 0 ] || { tail -20 "$work/ut.err"; fail "undertow exited $rc"; }
[ -s "$ppm" ] || fail "undertow wrote no capture"

# A PPM needs no image library: "P6\n<W> <H>\n255\n", then RGB triples; `od -v`
# because od collapses repeated lines otherwise (HANDOFF §2.26, §2.34).
hdr_len=$(printf 'P6\n%s %s\n255\n' "$W" "$H" | wc -c | tr -d ' ')
pixel() {  # pixel DX DY -> "R G B", window-relative
  off=$((hdr_len + ((((Y + $2) * W) + X + $1) * 3)))
  dd if="$ppm" bs=1 skip="$off" count=3 2>/dev/null | od -An -v -tu1 | awk '{print $1, $2, $3}'
}
colour() {  # colour DX DY "R G B" WHY
  got=$(pixel "$1" "$2")
  [ "$got" = "$3" ] || fail "$4: pixel ($1,$2) of the window is $got, wanted $3"
  echo "ok: $4"
}
colour  70  50 "0 0 255"     "A is drawn over its parent"
colour  10  10 "255 0 0"     "the parent is drawn"
colour 220 -10 "0 255 0"     "B is drawn outside its parent's rectangle"
colour 185  10 "0 255 0"     "B is drawn over its parent where they overlap"
colour -20 100 "255 255 0"   "C is drawn where its parent is not"
colour  10 100 "255 0 0"     "C, placed below, is hidden where its parent covers it"

echo "all green (a window made of subsurfaces is drawn, framed and routed)."
