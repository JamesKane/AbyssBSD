#!/bin/sh
# AbyssBSD Swift DE — undertow drives several outputs (PHASE14 P14.7a).
#
# Three headless outputs: the main display (640x480 at 0,0), one to its right
# (800x600 at 640,0), and one to its left and lower (320x240 at -320,100) — so
# the layout has negative coordinates and gaps. Claims:
#
#   1. the layout undertow reports is the one it was given, and a client asking
#      through xdg-output is told the same;
#   2. the menu bar goes on the main display and reserves its strip there only;
#   3. a window dragged by its title bar from the main display lands on the
#      display to the right — and is DRAWN there: its pixels are in that
#      output's capture, and its old place on the main display is bare;
#   4. the pointer, driven into the gap below the left display, is kept on a
#      display;
#   5. every output keeps its own frame contract: its misses within the
#      non-RT budget (5 per mille), each at its own rate.
#
# Usage: abyss/tests/live-displays.sh
set -eu
root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"
. "$root/abyss/common.sh"
abyss_ensure_runtime_dir

undertow="$root/.build/debug/undertow"
client="$root/.build/debug/AquaDemo"
[ -x "$undertow" ] && [ -x "$client" ] || swift build
command -v wayland-scanner >/dev/null 2>&1 || { echo "note: no wayland-scanner, skipping"; exit 0; }

work=$(mktemp -d /tmp/abyss-displays.XXXXXX)
cleanup() {
  exec 3>&- 2>/dev/null || true
  for p in ${vp_pid:-} ${bar_pid:-} ${win_pid:-} ${ut_pid:-}; do kill "$p" 2>/dev/null || true; done
  rm -rf "$work" 2>/dev/null || true
}
trap cleanup EXIT INT TERM HUP
mkdir -p "$work/cfg"
fail() { echo "FAIL: $1"; [ -s "$work/ut.out" ] && grep -E '^(outputs|window|usable|cursor|missed|output )' "$work/ut.out" | sed 's/^/  undertow| /' | tail -12; exit 1; }

protos=$(pkg-config --variable=pkgdatadir wayland-protocols)
wayland-scanner client-header "$protos/unstable/xdg-output/xdg-output-unstable-v1.xml" "$work/xdgoutput-proto.h"
wayland-scanner private-code  "$protos/unstable/xdg-output/xdg-output-unstable-v1.xml" "$work/xdgoutput-proto.c"
cc -I"$work" "$root/abyss/tests/xdgoutput.c" "$work/xdgoutput-proto.c" \
   $(pkg-config --cflags --libs wayland-client) -o "$work/xdgoutput" || fail "could not build xdgoutput"
wayland-scanner client-header "$root/abyss/tests/wlr-virtual-pointer-unstable-v1.xml" "$work/vpointer-proto.h"
wayland-scanner private-code  "$root/abyss/tests/wlr-virtual-pointer-unstable-v1.xml" "$work/vpointer-proto.c"
cc -I"$work" "$root/abyss/tests/vpointer.c" "$work/vpointer-proto.c" \
   $(pkg-config --cflags --libs wayland-client) -o "$work/vpointer" || fail "could not build vpointer"

# 900 frames at 60 Hz: fifteen seconds, and the captures are taken at the end.
env -u WAYLAND_DISPLAY "$undertow" run --hz 60 --frames 900 --width 640 --height 480 \
    --output 800x600 --output 320x240@-320,100 --config-dir "$work/cfg" \
    --capture "$work/end.ppm" > "$work/ut.out" 2> "$work/ut.err" &
ut_pid=$!
i=0; wd=""
while [ $i -lt 60 ]; do
  wd=$(grep -m1 '^WAYLAND_DISPLAY=' "$work/ut.out" 2>/dev/null | cut -d= -f2-) || wd=""
  [ -n "$wd" ] && break
  kill -0 "$ut_pid" 2>/dev/null || fail "undertow exited early: $(cat "$work/ut.err")"
  sleep 0.1; i=$((i + 1))
done
[ -n "$wd" ] || fail "undertow never announced a socket"

# ------------------------------------------------------------ 1. the layout
want="outputs HEADLESS-1 640x480@0,0 main; HEADLESS-2 800x600@640,0; HEADLESS-3 320x240@-320,100"
grep -qx "$want" "$work/ut.out" || fail "the layout is not the one given: $(grep '^outputs' "$work/ut.out")"
env WAYLAND_DISPLAY="$wd" "$work/xdgoutput" > "$work/xdg.out" 2>&1 || fail "xdgoutput: $(cat "$work/xdg.out")"
for line in "output HEADLESS-1 0,0 640x480" "output HEADLESS-2 640,0 800x600" "output HEADLESS-3 -320,100 320x240"; do
  grep -qx "$line" "$work/xdg.out" || fail "xdg-output does not say '$line': $(cat "$work/xdg.out")"
done
echo "ok: 1. three outputs where they were put, and xdg-output tells a client the same"

# ---------------------------------------------------- 2. the shell and a window
env WAYLAND_DISPLAY="$wd" AQUA_SCENE=menubar "$client" > "$work/bar.log" 2>&1 &
bar_pid=$!
env WAYLAND_DISPLAY="$wd" AQUA_SCENE=window "$client" > "$work/win.log" 2>&1 &
win_pid=$!
i=0; win=""
while [ $i -lt 80 ]; do
  win=$(grep '^window org.abyssbsd.aquademo' "$work/ut.out" | tail -1) || win=""
  [ -n "$win" ] && break
  sleep 0.1; i=$((i + 1))
done
[ -n "$win" ] || fail "the window never mapped"
sleep 0.5
win=$(grep '^window org.abyssbsd.aquademo' "$work/ut.out" | tail -1)
key=$(printf '%s' "$win" | awk '{print $2}')
pos=$(printf '%s' "$win" | awk '{print $3}'); size=$(printf '%s' "$win" | awk '{print $4}')
wx=${pos%,*}; wy=${pos#*,}; ww=${size%x*}; wh=${size#*x}
[ "$wx" -ge 0 ] && [ $((wx + ww)) -le 640 ] || fail "the window did not open on the main display: $win"
echo "ok: 2. the window opened on the main display ($pos, $size)"

# ------------------------------------------------------------- 3. a drag across
# The virtual pointer is absolute over the layout's bounds: x from -320, y from 0,
# 1760 wide and 600 tall. `v X Y` turns layout coordinates into its own.
fifo="$work/vp.fifo"; mkfifo "$fifo"
env WAYLAND_DISPLAY="$wd" "$work/vpointer" 1760 600 < "$fifo" > "$work/vp.log" 2>&1 &
vp_pid=$!; exec 3>"$fifo"
i=0; while ! grep -q ready "$work/vp.log" 2>/dev/null && [ $i -lt 60 ]; do i=$((i+1)); sleep 0.1; done
grep -q ready "$work/vp.log" || fail "the virtual pointer never bound"
sleep 0.5
v() { echo "$(($1 + 320)) $2"; }
tx=$((wx + ww / 2)); ty=$((wy + 11))                   # its own title bar: the top 22 px of the surface
dx=$((640 - wx + 40))                                  # its left edge 40 px past the edge at 640
printf 'm %s\np\n' "$(v $tx $ty)" >&3; sleep 0.1
for step in 1 2 3 4 5; do printf 'm %s\n' "$(v $((tx + dx * step / 5)) $((ty + 60 * step / 5)))" >&3; sleep 0.08; done
printf 'r\n' >&3
i=0; moved=""
while [ $i -lt 40 ]; do
  moved=$(grep "^window $key " "$work/ut.out" | tail -1)
  nx=$(printf '%s' "$moved" | awk '{print $3}'); nx=${nx%,*}
  [ "$nx" -ge 640 ] 2>/dev/null && break
  sleep 0.1; i=$((i + 1))
done
nx=$(printf '%s' "$moved" | awk '{print $3}'); ny=${nx#*,}; nx=${nx%,*}
[ "$nx" -ge 640 ] || fail "the drag did not carry the window onto the right-hand display: $moved"
echo "ok: 3a. a drag by the title bar carried the window across the edge, to $nx,$ny"

# ------------------------------------------------------------ 4. into a gap
printf 'm %s\n' "$(v -200 560)" >&3        # below the left display, beside nothing
sleep 0.3
exec 3>&-

rc=0; wait "$ut_pid" 2>/dev/null || rc=$?; ut_pid=""
grep -q '^cursor=' "$work/ut.out" \
  || fail "undertow ended without its summary (exit $rc):
$(tail -15 "$work/ut.err")"
cur=$(grep '^cursor=' "$work/ut.out" | cut -d= -f2)
cx=${cur%,*}; cy=${cur#*,}
on=0
[ "$cx" -ge 0 ] && [ "$cx" -lt 1440 ] && [ "$cy" -ge 0 ] && [ "$cy" -lt 600 ] && { [ "$cx" -ge 640 ] || [ "$cy" -lt 480 ]; } && on=1
[ "$cx" -ge -320 ] && [ "$cx" -lt 0 ] && [ "$cy" -ge 100 ] && [ "$cy" -lt 340 ] && on=1
[ "$on" = 1 ] || fail "the cursor ended in a gap: $cur"
echo "ok: 4. the pointer driven into the gap below the left display was kept on one ($cur)"

# The menu bar's strip is off the main display only.
grep -qx 'usable=0,22,640x458' "$work/ut.out" || fail "the main display's usable area: $(grep '^usable' "$work/ut.out")"
grep -qx 'usable HEADLESS-2=640,0,800x600' "$work/ut.out" || fail "HEADLESS-2 lost area to a bar it does not have"
echo "ok: 2b. the menu bar reserved its strip on the main display and nowhere else"

# ------------------------------------------------ 3b. drawn where it went
[ -s "$work/end.ppm" ] && [ -s "$work/end.HEADLESS-2.ppm" ] && [ -s "$work/end.HEADLESS-3.ppm" ] \
  || fail "not every output was captured: $(ls "$work")"
px() {  # px FILE X Y -> "R G B" at output coordinates
  f=$1; w=$(sed -n 2p "$f" | awk '{print $1}')
  hdr=$(head -3 "$f" | wc -c | tr -d ' ')
  dd if="$f" bs=1 skip=$((hdr + ($3 * w + $2) * 3)) count=3 2>/dev/null | od -An -tu1 | awk '{print $1, $2, $3}'
}
bg="61 102 161"                                          # undertow's own desktop blue
inside=$(px "$work/end.HEADLESS-2.ppm" $((nx - 640 + ww / 2)) $((ny + wh / 2)))
[ "$inside" != "$bg" ] || fail "HEADLESS-2 shows bare desktop where the window should be ($((nx - 640 + ww / 2)),$((ny + wh / 2)))"
old=$(px "$work/end.ppm" $((wx + 10)) $((wy + wh - 10)))
[ "$old" = "$bg" ] || fail "the main display still shows something where the window was: $old"
left=$(px "$work/end.HEADLESS-3.ppm" 160 120)
[ "$left" = "$bg" ] || fail "the left display shows something it should not: $left"
echo "ok: 3b. the window is drawn on HEADLESS-2 where it went ($inside), its old place on the main display is bare, and the left display is empty"

# ---------------------------------------------------- 5. every contract
# The frame contract's own budget for a present thread that is not real-time
# (rtprio is Phase 4's, on metal): 5 per mille, as bench-metronome.sh and the
# C2 test use — 4 of 900, for each output, whatever the others do.
BUDGET=4
m=$(grep '^missed=' "$work/ut.out" | sed 's/missed=\([0-9]*\) .*/\1/')
[ -n "$m" ] && [ "$m" -le "$BUDGET" ] || fail "the main display missed frames: $(grep '^missed' "$work/ut.out")"
for o in HEADLESS-2 HEADLESS-3; do
  l=$(grep "^output $o missed=" "$work/ut.out") || fail "no contract line for $o"
  m=$(printf '%s' "$l" | sed 's/.*missed=\([0-9]*\) .*/\1/')
  [ "$m" -le "$BUDGET" ] || fail "$o missed frames: $l"
  n=$(printf '%s' "$l" | sed 's/.* of \([0-9]*\) .*/\1/')
  [ "$n" -ge 850 ] || fail "$o made only $n frames beside the main display's 900: $l"
done
echo "ok: 5. every output kept its own contract (within $BUDGET of 900 missed, per output), and each made its frames"

echo "all green (undertow drives several outputs)."
