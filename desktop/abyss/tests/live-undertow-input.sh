#!/bin/sh
# AbyssBSD Swift DE — input, through our own compositor (PHASE6.md P6.4).
#
# The claim: a pointer event enters `undertow`, is routed to the right surface,
# and the CLIENT ACTS ON IT. Not "the compositor received input" — that proves
# nothing a log line couldn't fake — but that AquaDemo's window visibly changed
# because of a click that travelled through our seat.
#
# The pointer is driven by `abyss/tests/vpointer.c`, **completely unmodified**.
# It speaks `wlr-virtual-pointer-unstable-v1`, which is how this harness has
# driven sway since Phase 1 — implementing that protocol's server side means the
# existing tool drives us with no idea it is talking to a different compositor.
#
# Usage: abyss/tests/live-undertow-input.sh
set -eu

root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"
. "$root/abyss/common.sh"
abyss_ensure_runtime_dir

undertow="$root/.build/debug/undertow"
client="$root/.build/debug/AquaDemo"
[ -x "$undertow" ] && [ -x "$client" ] || swift build

W=800
H=600
# AquaDemo's .window scene is 460x360, centred by `Compositor.place` — so the
# window sits at (170,120) and its "Click Me" gel button is at about (540,415)
# in output coordinates.
CLICK_X=540
CLICK_Y=415

work=$(mktemp -d /tmp/abyss-utinput.XXXXXX)
before="$work/before.ppm"
after="$work/after.ppm"
fifo="$work/vp.fifo"
cleanup() {
  for p in ${vk_pid:-} ${vp_pid:-} ${client_pid:-} ${ut_pid:-}; do
    kill "$p" 2>/dev/null || true
  done
  rm -rf "$work" "${vp_dir:-}" 2>/dev/null || true
}
trap cleanup EXIT

# --------------------------------------------------------- the virtual pointer
vp_dir=$(mktemp -d)
xml="$root/abyss/tests/wlr-virtual-pointer-unstable-v1.xml"
wayland-scanner client-header "$xml" "$vp_dir/vpointer-proto.h"
wayland-scanner private-code  "$xml" "$vp_dir/vpointer-proto.c"
cc -I"$vp_dir" "$root/abyss/tests/vpointer.c" "$vp_dir/vpointer-proto.c" \
   $(pkg-config --cflags --libs wayland-client) -o "$vp_dir/vpointer"

# ...and a virtual keyboard, which this test uses for one thing only: to go
# away again. See "the devices leave" at the bottom.
kxml="$root/abyss/tests/virtual-keyboard-unstable-v1.xml"
wayland-scanner client-header "$kxml" "$vp_dir/vkeyboard-proto.h"
wayland-scanner private-code  "$kxml" "$vp_dir/vkeyboard-proto.c"
cc -I"$vp_dir" "$root/abyss/tests/vkeyboard.c" "$vp_dir/vkeyboard-proto.c" \
   $(pkg-config --cflags --libs wayland-client xkbcommon) -o "$vp_dir/vkeyboard"

# ------------------------------------------------------------ the compositor
env -u WAYLAND_DISPLAY "$undertow" run --hz 60 --frames 900 \
    --width "$W" --height "$H" --capture-early "$before" --capture "$after" \
    > "$work/ut.out" 2> "$work/ut.err" &
ut_pid=$!
wd=""
i=0
while [ $i -lt 60 ]; do
  wd=$(grep -m1 '^WAYLAND_DISPLAY=' "$work/ut.out" 2>/dev/null | cut -d= -f2-) || wd=""
  [ -n "$wd" ] && break
  kill -0 "$ut_pid" 2>/dev/null || { echo "FAIL: undertow exited early"; cat "$work/ut.err"; exit 1; }
  sleep 0.1; i=$((i + 1))
done
[ -n "$wd" ] || { echo "FAIL: undertow never announced a socket"; cat "$work/ut.err"; exit 1; }

# ----------------------------------------------------------------- the client
env WAYLAND_DISPLAY="$wd" AQUA_SCENE=window "$client" > "$work/aqua.log" 2>&1 &
client_pid=$!

# Wait for the EARLY CAPTURE rather than sleeping: undertow writes it a few
# frames after the first window maps, so its existence means "the client has
# drawn" — a real synchronisation point instead of a guess.
i=0
while [ $i -lt 150 ]; do
  [ -s "$before" ] && break
  kill -0 "$ut_pid" 2>/dev/null || { echo "FAIL: undertow exited before the client drew"
                                     cat "$work/ut.err" "$work/aqua.log"; exit 1; }
  sleep 0.1; i=$((i + 1))
done
[ -s "$before" ] || { echo "FAIL: the client never drew a window"
                      cat "$work/ut.err" "$work/aqua.log"; exit 1; }
echo "ok: the client drew its window (captured before any input)"

# ------------------------------------------------------------------ the click
mkfifo "$fifo"
env WAYLAND_DISPLAY="$wd" "$vp_dir/vpointer" "$W" "$H" < "$fifo" > "$work/vp.log" 2>&1 &
vp_pid=$!
exec 3>"$fifo"
i=0
while [ $i -lt 30 ]; do grep -q ready "$work/vp.log" && break; sleep 0.15; i=$((i + 1)); done
grep -q ready "$work/vp.log" \
  || { echo "FAIL: the virtual pointer never bound — does undertow offer"
       echo "      zwlr_virtual_pointer_manager_v1?"; cat "$work/vp.log"; exit 1; }
echo "ok: an unmodified vpointer bound to our compositor"

sleep 0.5                                   # let AquaDemo bind wl_pointer
printf 'm %s %s\np\nr\n' "$CLICK_X" "$CLICK_Y" >&3
sleep 1.0

# ------------------------------------------------------------ the devices leave
# **A compositor must outlive its input** (HANDOFF §2.41). Both virtual devices
# belong to a *client*: when that client disconnects, wlroots destroys the device
# and asserts that nothing is still listening to it. `Seat` used to free a
# device's listeners on its own lifetime rather than the device's, so this — a
# harness letting go of its input, the most ordinary thing a test does — aborted
# the compositor. It went unseen for a whole phase because every test until now
# killed undertow *first*.
#
# So: connect a keyboard, drop both devices, and let undertow run out its frames.
# The `rc` check below is the assertion; injected once by deleting the keyboard's
# destroy listener, which reproduced `wlr_keyboard_finish: Assertion
# \`wl_list_empty(&kb->events.key.listener_list)\' failed` and exit 134.
kfifo="$work/vk.fifo"
mkfifo "$kfifo"
env WAYLAND_DISPLAY="$wd" "$vp_dir/vkeyboard" < "$kfifo" > "$work/vk.log" 2>&1 &
vk_pid=$!
exec 4>"$kfifo"
sleep 0.8
printf 'q\n' >&4; exec 4>&-
wait "$vk_pid" 2>/dev/null || true
vk_pid=""

exec 3>&-                                   # and the pointer's client with it
wait "$vp_pid" 2>/dev/null || true
vp_pid=""
echo "ok: both virtual input devices disconnected while the compositor ran on"

rc=0; wait "$ut_pid" 2>/dev/null || rc=$?
ut_pid=""
[ "$rc" = 0 ] || { echo "FAIL: undertow exited $rc — a compositor must outlive"
                   echo "      its input clients (HANDOFF §2.41)"
                   tail -20 "$work/ut.err"; exit 1; }
echo "ok: undertow finished cleanly after its input went away"

# ------------------------------------------------------------------ the proof

grep -q "^cursor=$CLICK_X,$CLICK_Y" "$work/ut.out" \
  || { echo "FAIL: the cursor is not where the pointer was driven"
       grep '^cursor=' "$work/ut.out"; exit 1; }
echo "ok: the pointer moved our cursor to $CLICK_X,$CLICK_Y"

grep -q '^focused=yes' "$work/ut.out" \
  || { echo "FAIL: clicking a window did not focus it"; cat "$work/ut.out"; exit 1; }
echo "ok: click-to-focus gave the window keyboard focus"

# THE ONE THAT MATTERS: the client re-rendered because of the click.
# AquaDemo's .window scene shows "Clicks: N", so that text changes 0 -> 1. The
# region is chosen to be somewhere the cursor never goes (it starts centred at
# 400,300 and ends at 540,415), so a difference there cannot be the cursor.
hdr_len=$(printf 'P6\n%s %s\n255\n' "$W" "$H" | wc -c | tr -d ' ')
region_bytes() {  # region_bytes FILE X Y W H -> the raw bytes of those rows
  f=$1; rx=$2; ry=$3; rw=$4; rh=$5
  r=0
  while [ "$r" -lt "$rh" ]; do
    dd if="$f" bs=1 skip=$((hdr_len + ((((ry + r) * W) + rx) * 3))) count=$((rw * 3)) \
       2>/dev/null | od -An -v -tu1
    r=$((r + 1))
  done
}
CLK_X=200; CLK_Y=265; CLK_W=64; CLK_H=26
region_bytes "$before" $CLK_X $CLK_Y $CLK_W $CLK_H > "$work/clk.before"
region_bytes "$after"  $CLK_X $CLK_Y $CLK_W $CLK_H > "$work/clk.after"
if cmp -s "$work/clk.before" "$work/clk.after"; then
  echo "FAIL: the click counter region is byte-identical before and after"
  echo "      the click reached our seat but never reached the client"
  exit 1
fi
echo "ok: the client redrew its click counter — the click reached the app"

# The negative control, so the diff above means something. A patch of bare
# desktop must be UNCHANGED: if the whole frame differs, the test proves only
# that two captures of an animating scene are not identical.
region_bytes "$before" 20 20 40 40 > "$work/bg.before"
region_bytes "$after"  20 20 40 40 > "$work/bg.after"
cmp -s "$work/bg.before" "$work/bg.after" \
  || { echo "FAIL: the desktop background changed too — the diff above is noise,"
       echo "      not evidence that the client responded"; exit 1; }
echo "ok: ...and bare desktop is unchanged, so that diff is the client, not noise"

echo "all green (input reaches the app, through our compositor)."
