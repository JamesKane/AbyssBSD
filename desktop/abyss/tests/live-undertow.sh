#!/bin/sh
# AbyssBSD Swift DE — a real client on our own compositor (PHASE6.md P6.3).
#
# The claim: `undertow` is a compositor. Not "it schedules frames" (P6.1) and not
# "it drives wlroots" (P6.2), but the thing an application can connect to — an
# Aqua window, drawn by a client that knows nothing about us, textured into a
# frame by our own scene and composited onto our own desktop.
#
# Two processes, both real: `undertow` hosting a Wayland socket, and `AquaDemo`
# as an ordinary client. Nothing here is mocked and no other compositor is
# involved — this is the first test in the project that does NOT start sway.
#
# Usage: abyss/tests/live-undertow.sh [out.ppm]
set -eu

root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"
. "$root/abyss/common.sh"
abyss_ensure_runtime_dir

out=${1:-}
undertow="$root/.build/debug/undertow"
client="$root/.build/debug/AquaDemo"
[ -x "$undertow" ] && [ -x "$client" ] || swift build

W=800
H=600
# AquaDemo's window scene is 460x360, and `Compositor.place` centres the first
# window exactly (the cascade offset is zero for window one). So the window
# spans 170..630 x 120..480 — deterministic, which is what lets this assert on
# specific pixels rather than on "something changed".
WIN_W=460
WIN_H=360

work=$(mktemp -d /tmp/abyss-undertow.XXXXXX)
ppm="$work/frame.ppm"
cleanup() {
  [ -n "${client_pid:-}" ] && kill "$client_pid" 2>/dev/null || true
  [ -n "${ut_pid:-}" ] && kill "$ut_pid" 2>/dev/null || true
  rm -rf "$work" 2>/dev/null || true
}
trap cleanup EXIT

# ------------------------------------------------------------ the compositor
# It prints its socket on stdout before entering the loop, so we read one line
# rather than racing a sleep against startup.
env -u WAYLAND_DISPLAY "$undertow" run --hz 60 --frames 400 \
    --width "$W" --height "$H" --capture "$ppm" --assert-windows 1 \
    > "$work/ut.out" 2> "$work/ut.err" &
ut_pid=$!

wd=""
i=0
while [ $i -lt 60 ]; do
  wd=$(grep -m1 '^WAYLAND_DISPLAY=' "$work/ut.out" 2>/dev/null | cut -d= -f2-) || wd=""
  [ -n "$wd" ] && break
  kill -0 "$ut_pid" 2>/dev/null || { echo "FAIL: undertow exited before it opened a socket"
                                     cat "$work/ut.err"; exit 1; }
  sleep 0.1; i=$((i + 1))
done
[ -n "$wd" ] || { echo "FAIL: undertow never announced a socket"; cat "$work/ut.err"; exit 1; }
echo "undertow: listening on $wd"

# ----------------------------------------------------------------- the client
env WAYLAND_DISPLAY="$wd" AQUA_SCENE=window "$client" > "$work/aqua.log" 2>&1 &
client_pid=$!

rc=0; wait "$ut_pid" 2>/dev/null || rc=$?
ut_pid=""
[ "$rc" = 0 ] || { echo "FAIL: undertow exited $rc"
                   cat "$work/ut.out" "$work/ut.err" "$work/aqua.log"; exit 1; }

# ------------------------------------------------------------------ the proof

# 1. A client connected, mapped a window, and it reached our scene.
grep -q '^windows=1' "$work/ut.out" \
  || { echo "FAIL: no client window was mapped"
       cat "$work/ut.out" "$work/aqua.log"; exit 1; }
grep -q '^surfaces-composited=1' "$work/ut.out" \
  || { echo "FAIL: the window mapped but never reached the scene"
       cat "$work/ut.out"; exit 1; }
echo "ok: a real client connected and its window entered our scene"

[ -s "$ppm" ] || { echo "FAIL: no frame was captured"; cat "$work/ut.err"; exit 1; }

# 2. The pixels. A PPM needs no image library to probe — the header is
#    "P6\n<W> <H>\n255\n" and pixels follow as RGB triples (HANDOFF §2.26).
#    `od -v` because od collapses repeated lines to '*' otherwise (§2.34).
hdr_len=$(printf 'P6\n%s %s\n255\n' "$W" "$H" | wc -c | tr -d ' ')
pixel() {  # pixel X Y -> "R G B"
  off=$((hdr_len + ((($2 * W) + $1) * 3)))
  dd if="$ppm" bs=1 skip="$off" count=3 2>/dev/null | od -An -v -tu1 | awk '{print $1, $2, $3}'
}

# The desktop we chose, well outside the window.
corner=$(pixel 40 40)
[ "$corner" = "61 102 161" ] \
  || { echo "FAIL: the desktop is $corner, expected Jaguar blue 61 102 161"; exit 1; }
echo "ok: the desktop is the blue undertow painted ($corner)"

# The window's interior. SCAN A STRIP AND COUNT, rather than trusting one
# coordinate: the first version of this probed the exact centre and got 187,
# which is a control's border, not the light content it was aiming for. One
# pixel of layout drift would have turned that into a mystery failure — §2.34,
# where a status-item probe landed on bare pinstripe because the font differed.
strip_y=$((H / 2))
strip_x0=$(((W - WIN_W) / 2 + 20))
strip_len=$((WIN_W - 40))
# One byte per line before counting. `od` emits 16 bytes per line, so RGB
# triples do NOT align to its columns — the first version indexed every third
# field of each line and happily reported 466 light pixels in a 420-pixel strip.
# A count that exceeds its own denominator is the only reason that was caught.
light=$(dd if="$ppm" bs=1 \
           skip=$((hdr_len + (((strip_y * W) + strip_x0) * 3))) \
           count=$((strip_len * 3)) 2>/dev/null \
        | od -An -v -tu1 | tr -s ' \n' '\n\n' | grep -v '^$' \
        | awk 'NR % 3 == 1 && $1 > 180 { n++ } END { print n + 0 }')
[ "$light" -gt $((strip_len / 2)) ] \
  || { echo "FAIL: only $light of $strip_len pixels across the window are light"
       echo "      that strip is desktop, not a window"; exit 1; }
echo "ok: the client's window is composited into the frame"
echo "    ($light of $strip_len pixels across its middle are window-light)"

# 3. And the window really is a window, not a full-screen repaint: just outside
#    its left edge must still be desktop. Without this, a scene that ignored
#    geometry and painted the whole output would pass everything above.
edge=$(pixel $(((W - WIN_W) / 2 - 12)) $((H / 2)))
[ "$edge" = "61 102 161" ] \
  || { echo "FAIL: just outside the window is $edge, expected desktop 61 102 161"
       echo "      the surface is not being placed — it covered the whole output"; exit 1; }
echo "ok: it is placed and clipped, not painted over the whole output"

[ -n "$out" ] && cp "$ppm" "$out" && echo "wrote $out"
echo "all green (a real client, on our own compositor)."
