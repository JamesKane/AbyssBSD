#!/bin/sh
# AbyssBSD Swift DE — rearranging the displays, by protocol (PHASE14 P14.7b).
#
# undertow with two headless outputs, driven by `abyss-displays` over
# wlr-output-management-v1 — the protocol wlr-randr and kanshi speak, and the
# Displays pane will. Claims:
#
#   1. a client is told every display, its modes and where it is;
#   2. a TEST that would work says so and changes nothing;
#   3. an arrangement that overlaps is refused, and undertow says why;
#   4. an APPLY moves a display, gives it a new mode and a scale of 2: the
#      layout, xdg-output and the protocol all agree, the display is drawn at
#      its mode (its capture is 1024x768) and laid out at mode ÷ scale;
#   5. a window that was on that display, left on no display by the move, is
#      brought to the main one — not lost;
#   6. displays.ini holds what was applied, and a new undertow starts with it.
#
# Usage: abyss/tests/live-displays-config.sh
set -eu
root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"
. "$root/abyss/common.sh"
abyss_ensure_runtime_dir

undertow="$root/.build/debug/undertow"
client="$root/.build/debug/AquaDemo"
ctl="$root/.build/debug/abyss-displays"
[ -x "$undertow" ] && [ -x "$client" ] && [ -x "$ctl" ] || swift build
command -v wayland-scanner >/dev/null 2>&1 || { echo "note: no wayland-scanner, skipping"; exit 0; }

work=$(mktemp -d /tmp/abyss-dispcfg.XXXXXX)
cleanup() {
  exec 3>&- 2>/dev/null || true
  for p in ${vp_pid:-} ${win_pid:-} ${ut_pid:-}; do kill "$p" 2>/dev/null || true; done
  rm -rf "$work" 2>/dev/null || true
}
trap cleanup EXIT INT TERM HUP
mkdir -p "$work/cfg"
fail() {
  echo "FAIL: $1"
  [ -s "$work/ut.err" ] && grep -E 'output-config|displays.ini|no display' "$work/ut.err" | sed 's/^/  undertow| /' | tail -8
  exit 1
}

protos=$(pkg-config --variable=pkgdatadir wayland-protocols)
wayland-scanner client-header "$protos/unstable/xdg-output/xdg-output-unstable-v1.xml" "$work/xdgoutput-proto.h"
wayland-scanner private-code  "$protos/unstable/xdg-output/xdg-output-unstable-v1.xml" "$work/xdgoutput-proto.c"
cc -I"$work" "$root/abyss/tests/xdgoutput.c" "$work/xdgoutput-proto.c" \
   $(pkg-config --cflags --libs wayland-client) -o "$work/xdgoutput" || fail "could not build xdgoutput"
wayland-scanner client-header "$root/abyss/tests/wlr-virtual-pointer-unstable-v1.xml" "$work/vpointer-proto.h"
wayland-scanner private-code  "$root/abyss/tests/wlr-virtual-pointer-unstable-v1.xml" "$work/vpointer-proto.c"
cc -I"$work" "$root/abyss/tests/vpointer.c" "$work/vpointer-proto.c" \
   $(pkg-config --cflags --libs wayland-client) -o "$work/vpointer" || fail "could not build vpointer"

start() {  # start FRAMES [CAPTURE]
  env -u WAYLAND_DISPLAY "$undertow" run --hz 60 --frames "$1" --width 640 --height 480 \
      --output 800x600 --config-dir "$work/cfg" ${2:+--capture "$2"} > "$work/ut.out" 2> "$work/ut.err" &
  ut_pid=$!
  i=0; wd=""
  while [ $i -lt 60 ]; do
    wd=$(grep -m1 '^WAYLAND_DISPLAY=' "$work/ut.out" 2>/dev/null | cut -d= -f2-) || wd=""
    [ -n "$wd" ] && break
    kill -0 "$ut_pid" 2>/dev/null || fail "undertow exited early: $(tail -5 "$work/ut.err")"
    sleep 0.1; i=$((i + 1))
  done
  [ -n "$wd" ] || fail "undertow never announced a socket"
}
disp() { env WAYLAND_DISPLAY="$wd" "$ctl" "$@"; }

start 900 "$work/end.ppm"

# ------------------------------------------------------------- 1. told
disp list > "$work/list.out" || fail "list: $(cat "$work/list.out")"
grep -qx 'display HEADLESS-1 640x480@60000 at 0,0 scale 1.0' "$work/list.out" || fail "list: $(cat "$work/list.out")"
grep -qx 'display HEADLESS-2 800x600@60000 at 640,0 scale 1.0' "$work/list.out" || fail "list: $(cat "$work/list.out")"
grep -qx '  mode 800x600@60000 current' "$work/list.out" || fail "no current mode listed: $(cat "$work/list.out")"
echo "ok: 1. a client is told both displays, where they are and their modes"

# A window, dragged onto HEADLESS-2 (the pointer spans the layout: 1440x600).
env WAYLAND_DISPLAY="$wd" AQUA_SCENE=window "$client" > "$work/win.log" 2>&1 &
win_pid=$!
i=0; win=""
while [ -z "$win" ] && [ $i -lt 80 ]; do win=$(grep '^window org.abyssbsd.aquademo' "$work/ut.out" | tail -1) || true; sleep 0.1; i=$((i+1)); done
[ -n "$win" ] || fail "the window never mapped"
key=$(printf '%s' "$win" | awk '{print $2}'); pos=$(printf '%s' "$win" | awk '{print $3}')
wx=${pos%,*}; wy=${pos#*,}
fifo="$work/vp.fifo"; mkfifo "$fifo"
env WAYLAND_DISPLAY="$wd" "$work/vpointer" 1440 600 < "$fifo" > "$work/vp.log" 2>&1 &
vp_pid=$!; exec 3>"$fifo"
i=0; while ! grep -q ready "$work/vp.log" 2>/dev/null && [ $i -lt 60 ]; do i=$((i+1)); sleep 0.1; done
sleep 0.5
tx=$((wx + 220)); ty=$((wy + 11)); dx=$((700 - wx))
printf 'm %s %s\np\n' "$tx" "$ty" >&3; sleep 0.1
for k in 1 2 3 4 5; do printf 'm %s %s\n' "$((tx + dx * k / 5))" "$ty" >&3; sleep 0.08; done
printf 'r\n' >&3
sleep 0.5
nx=$(grep "^window $key " "$work/ut.out" | tail -1 | awk '{print $3}'); nx=${nx%,*}
[ "$nx" -ge 640 ] || fail "the window was not dragged onto HEADLESS-2: $(grep "^window $key " "$work/ut.out" | tail -1)"

# ------------------------------------------------------------- 2. a test
before=$(grep -c '^outputs ' "$work/ut.out" || true)
r=$(disp test HEADLESS-2:1024x768:640,0) || fail "a test that should pass failed: $r"
[ "$r" = "test succeeded" ] || fail "test said: $r"
sleep 0.3
[ "$(grep -c '^outputs ' "$work/ut.out" || true)" = "$before" ] || fail "a test changed the layout"
echo "ok: 2. a test of a new mode succeeded, and nothing changed"

# ------------------------------------------------------------- 3. refused
rc=0; r=$(disp apply HEADLESS-2:800x600:320,0) || rc=$?
[ "$rc" = 1 ] && [ "$r" = "apply failed: the compositor refused it" ] || fail "an overlap was not refused: rc=$rc $r"
grep -q 'output-config apply refused: HEADLESS-1 and HEADLESS-2 overlap' "$work/ut.err" || fail "undertow did not say why"
echo "ok: 3. an overlapping arrangement was refused, and undertow said why"

# ------------------------------------------------------------- 4. applied
disp apply HEADLESS-2:1024x768:-512,100:2 > "$work/apply.out" || fail "apply: $(cat "$work/apply.out")"
head -1 "$work/apply.out" | grep -qx applied || fail "apply said: $(cat "$work/apply.out")"
grep -qx 'display HEADLESS-2 1024x768@0 at -512,100 scale 2.0' "$work/apply.out" \
  || grep -q '^display HEADLESS-2 1024x768@[0-9]* at -512,100 scale 2.0$' "$work/apply.out" \
  || fail "after the apply, the protocol says: $(grep HEADLESS-2 "$work/apply.out")"
i=0; while ! grep -qx 'outputs HEADLESS-1 640x480@0,0 main; HEADLESS-2 512x384@-512,100 scale 2.0' "$work/ut.out" && [ $i -lt 30 ]; do
  sleep 0.1; i=$((i+1)); done
grep -qx 'outputs HEADLESS-1 640x480@0,0 main; HEADLESS-2 512x384@-512,100 scale 2.0' "$work/ut.out" \
  || fail "undertow's layout: $(grep '^outputs' "$work/ut.out" | tail -1)"
env WAYLAND_DISPLAY="$wd" "$work/xdgoutput" > "$work/xdg.out" 2>&1
grep -qx 'output HEADLESS-2 -512,100 512x384' "$work/xdg.out" || fail "xdg-output says: $(cat "$work/xdg.out")"
echo "ok: 4a. applied: HEADLESS-2 is 1024x768 at scale 2 at -512,100 — the protocol, the layout (512x384) and xdg-output agree"

# ------------------------------------------------------------- 5. rescued
i=0; line=""
while [ $i -lt 30 ]; do
  line=$(grep "^window $key " "$work/ut.out" | tail -1)
  x=$(printf '%s' "$line" | awk '{print $3}'); x=${x%,*}
  [ "$x" -lt 640 ] 2>/dev/null && break
  sleep 0.1; i=$((i+1))
done
x=$(printf '%s' "$line" | awk '{print $3}'); y=${x#*,}; x=${x%,*}
[ "$x" -ge 0 ] && [ "$x" -lt 640 ] && [ "$y" -ge 0 ] && [ "$y" -lt 480 ] || fail "the window left on no display was not brought back: $line"
grep -q "was on no display; brought to the main one" "$work/ut.err" || fail "undertow did not say it moved the window"
echo "ok: 5. the window left on no display by the move was brought to the main one ($x,$y)"

exec 3>&-
wait "$ut_pid" 2>/dev/null || true; ut_pid=""
[ -s "$work/end.HEADLESS-2.ppm" ] || fail "HEADLESS-2 was not captured"
[ "$(sed -n 2p "$work/end.HEADLESS-2.ppm")" = "1024 768" ] || fail "HEADLESS-2's capture is $(sed -n 2p "$work/end.HEADLESS-2.ppm"), not its new mode"
# The scene re-aimed at its new size and scale: the desktop is painted to the
# far corner of the new buffer, not only over the old 800x600.
hdr=$(head -3 "$work/end.HEADLESS-2.ppm" | wc -c | tr -d ' ')
corner=$(dd if="$work/end.HEADLESS-2.ppm" bs=1 skip=$((hdr + (760 * 1024 + 1020) * 3)) count=3 2>/dev/null | od -An -tu1 | awk '{print $1, $2, $3}')
[ "$corner" = "61 102 161" ] || fail "HEADLESS-2's far corner is '$corner', not the desktop: its scene was not re-aimed"
echo "ok: 4b. HEADLESS-2 is drawn at its new mode: its capture is 1024x768, desktop to the far corner"

# ---------------------------------------------------------- 6. kept
grep -qx 'HEADLESS-2 = -512,100 1024x768@0 2' "$work/cfg/displays.ini" \
  || grep -q '^HEADLESS-2 = -512,100 1024x768@[0-9]* 2$' "$work/cfg/displays.ini" \
  || fail "displays.ini: $(cat "$work/cfg/displays.ini")"
start 30
wait "$ut_pid" 2>/dev/null || true; ut_pid=""
grep -qx 'outputs HEADLESS-1 640x480@0,0 main; HEADLESS-2 512x384@-512,100 scale 2.0' "$work/ut.out" \
  || fail "a new undertow did not start with displays.ini: $(grep '^outputs' "$work/ut.out")"
echo "ok: 6. displays.ini holds what was applied, and a new undertow starts with it"

# ------------------------------------------------ 7. a client that is not ours
# wlr-randr, where it is installed (FreeBSD packages it; the guest has it):
# the same protocol from someone else's code, so undertow is not only
# agreeing with the client written beside it.
if command -v wlr-randr >/dev/null 2>&1; then
  rm -f "$work/cfg/displays.ini"
  start 0
  env WAYLAND_DISPLAY="$wd" wlr-randr > "$work/randr.out" 2>&1 || fail "wlr-randr: $(cat "$work/randr.out")"
  grep -q '^HEADLESS-2 ' "$work/randr.out" && grep -q 'Position: 640,0' "$work/randr.out" || fail "wlr-randr sees: $(cat "$work/randr.out")"
  env WAYLAND_DISPLAY="$wd" wlr-randr --output HEADLESS-2 --pos 0,480 --scale 1.5 > "$work/randr.out" 2>&1 \
    || fail "wlr-randr could not apply: $(cat "$work/randr.out")"
  i=0; while ! grep -qx 'outputs HEADLESS-1 640x480@0,0 main; HEADLESS-2 533x400@0,480 scale 1.5' "$work/ut.out" && [ $i -lt 30 ]; do sleep 0.1; i=$((i+1)); done
  grep -qx 'outputs HEADLESS-1 640x480@0,0 main; HEADLESS-2 533x400@0,480 scale 1.5' "$work/ut.out" \
    || fail "after wlr-randr: $(grep '^outputs' "$work/ut.out" | tail -1)"
  rc=0; env WAYLAND_DISPLAY="$wd" wlr-randr --output HEADLESS-2 --pos 100,0 > "$work/randr.out" 2>&1 || rc=$?
  [ "$rc" != 0 ] || fail "wlr-randr's overlapping arrangement was applied"
  kill "$ut_pid" 2>/dev/null; wait "$ut_pid" 2>/dev/null || true; ut_pid=""
  echo "ok: 7. wlr-randr — someone else's client — lists them, moves one at scale 1.5, and is refused an overlap"
else
  echo "ok: 7. (wlr-randr is not installed here; the guest runs this half)"
fi

echo "all green (the displays, rearranged by protocol — tested, refused, applied, kept)."
