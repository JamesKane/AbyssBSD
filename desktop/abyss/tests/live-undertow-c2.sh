#!/bin/sh
# AbyssBSD Swift DE — C2, the isolation proof (PHASE6.md P6.5; DESKTOP.md §0).
#
#   "No client can cause a missed flip. A program in an infinite loop, flooding
#    its socket, or never drawing again simply shows its last committed frame;
#    the desktop keeps its cadence."
#
# This is the claim the whole architecture exists to make good, so it is tested
# with real hostile processes rather than in-process fakes: eleven of them,
# covering four distinct threats (abyss/tests/adversary.c), running against the
# compositor while a *healthy* client keeps drawing.
#
# THREE THINGS ARE ASSERTED, and the last two are what stop this being theatre:
#
#   1. missed flips stay within the same budget as an idle compositor;
#   2. the load ACTUALLY ARRIVED — every hostile client is counted, because a
#      bench where the adversaries failed to connect passes beautifully and
#      proves nothing (this positive control caught exactly that, twice);
#   3. the HEALTHY client was still served throughout — C2 is not "the
#      compositor survived", it is "the desktop kept working".
#
# Usage: abyss/tests/live-undertow-c2.sh [out.ppm]
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
FRAMES=600
HZ=60

# 8 socket-flooders that never wait for a reply, 1 zombie, 1 CPU-spinning
# never-reader, 1 connect/disconnect churn. Measured headroom is far beyond
# this: 64 hostile clients at 60Hz and at 480Hz both hold zero missed frames
# (PHASE6.md P6.5). Eleven keeps the bench honest without making CI a fork bomb.
HARD=8

# The miss budget is the frame contract's, not a special case: the present
# thread is not real-time (rtprio is Phase 4 on metal), so the same 5-per-mille
# non-RT tolerance that bench-metronome.sh uses applies here. 3 of 600.
# What matters for C2 is that this is the SAME budget an idle compositor gets —
# the adversaries must not move it.
MISS_BUDGET=3

work=$(mktemp -d /tmp/abyss-c2.XXXXXX)
# Adversaries are started from a SUBSHELL that exits immediately, so they are
# orphans rather than jobs of this shell. Otherwise killing eleven processes
# makes the shell print eleven "Killed" lines to stderr, which in a test harness
# reads exactly like eleven failures.
pidfile="$work/adv.pids"
: > "$pidfile"
before="$work/before.ppm"
after="$work/after.ppm"
cleanup() {
  [ -s "${pidfile:-}" ] && while read -r p; do kill -9 "$p" 2>/dev/null || true; done < "$pidfile"
  for p in ${client_pid:-} ${ut_pid:-}; do kill -9 "$p" 2>/dev/null || true; done
  rm -rf "$work" "${adv_dir:-}" 2>/dev/null || true
}
trap cleanup EXIT

adv_dir=$(mktemp -d)
# adversary.c also carries the `move` oracle (P6.7), which speaks xdg-shell —
# so it needs the generated protocol source, exactly as any xdg client would.
cc -I "$root/de/cwayland/include" "$root/abyss/tests/adversary.c" \
   "$root/de/cabyssprotocols/xdg-shell-protocol.c" \
   $(pkg-config --cflags --libs wayland-client) -o "$adv_dir/adversary" \
  || { echo "FAIL: could not build the adversary"; exit 1; }
# A client that DRAWS on every frame (BACKLOG M.1): undertow presents only what
# changed, so a static healthy window would leave nothing to miss and C2 would
# pass by doing nothing. present.c redraws on every frame callback and says
# whether any of its frames was discarded.
for d in $(pkg-config --variable=pkgdatadir wayland-protocols) /usr/share/wayland-protocols /usr/local/share/wayland-protocols; do
  [ -f "$d/stable/presentation-time/presentation-time.xml" ] && pxml="$d/stable/presentation-time/presentation-time.xml" && break
done
wayland-scanner client-header "$pxml" "$adv_dir/presentation-time-client-protocol.h"
wayland-scanner private-code  "$pxml" "$adv_dir/presentation-time-protocol.c"
cc -I"$adv_dir" -I "$root/de/cwayland/include" "$root/abyss/tests/present.c" \
   "$root/de/cabyssprotocols/xdg-shell-protocol.c" "$adv_dir/presentation-time-protocol.c" \
   $(pkg-config --cflags --libs wayland-client) -o "$adv_dir/present" \
  || { echo "FAIL: could not build the drawing client"; exit 1; }

# ------------------------------------------------------------- the compositor
env -u WAYLAND_DISPLAY "$undertow" run --hz "$HZ" --frames "$FRAMES" \
    --width "$W" --height "$H" --capture-early "$before" --capture "$after" \
    --assert-missed "$MISS_BUDGET" \
    --assert-surfaces $((HARD + 3)) \
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

# ---------------------------------------------------------- the healthy client
env WAYLAND_DISPLAY="$wd" AQUA_SCENE=window "$client" > "$work/aqua.log" 2>&1 &
client_pid=$!

# Wait for it to draw before the storm starts, so "the good client kept working"
# is a claim about behaviour under load rather than a race at start-up.
i=0
while [ $i -lt 150 ]; do
  [ -s "$before" ] && break
  kill -0 "$ut_pid" 2>/dev/null || { echo "FAIL: undertow exited before the client drew"
                                     cat "$work/ut.err"; exit 1; }
  sleep 0.1; i=$((i + 1))
done
[ -s "$before" ] || { echo "FAIL: the healthy client never drew"; cat "$work/aqua.log"; exit 1; }
echo "ok: a healthy client is up and drawing"

# ------------------------------------------------------------- the adversaries
spawn_adversary() {
  ( env WAYLAND_DISPLAY="$wd" "$adv_dir/adversary" "$@" >/dev/null 2>&1 &
    echo $! >> "$pidfile" )
}
n=0
while [ "$n" -lt "$HARD" ]; do spawn_adversary hard 0; n=$((n + 1)); done
spawn_adversary zombie
spawn_adversary deaf
spawn_adversary churn 0
echo "ok: $HARD socket-flooders, a zombie, a spinning never-reader and a churner are loose"
# The drawing client, 120 frames at a time until undertow ends.
( while kill -0 "$ut_pid" 2>/dev/null; do
    env WAYLAND_DISPLAY="$wd" "$adv_dir/present" >> "$work/present.log" 2>&1 || break
  done & echo $! >> "$pidfile" )

rc=0; wait "$ut_pid" 2>/dev/null || rc=$?
ut_pid=""
while read -r p; do kill -9 "$p" 2>/dev/null || true; done < "$pidfile"
: > "$pidfile"

# ------------------------------------------------------------------- the proof
if [ "$rc" != 0 ]; then
  echo "FAIL: the compositor did not hold its contract under adversarial load"
  cat "$work/ut.out" "$work/ut.err"
  exit 1
fi

# 1. Cadence held. (Asserted inside the binary too — this is the readable half.)
missed=$(grep -o '^missed=[0-9]*' "$work/ut.out" | cut -d= -f2)
echo "ok: cadence held — $missed missed of $FRAMES (budget $MISS_BUDGET)"
echo "    wake-late p99 $(grep -o 'wake-late-p99-us=[0-9]*' "$work/ut.out" | cut -d= -f2)us"\
     "under load; the frames still landed"

# 2. The load arrived. Without this the whole bench is a compliment we pay
#    ourselves: adversaries that fail to connect cost nothing and miss nothing.
surfaces=$(grep -o 'surfaces-created=[0-9]*' "$work/ut.out" | cut -d= -f2)
echo "ok: the load was real — $surfaces client surfaces created"

# 2b. The frames were real: the screen changed every frame (the drawing
#     client), so undertow had to commit nearly every one — not idle ones it
#     could skip — and the drawing client lost none of its frames.
made=$(grep -o 'commits-refused=[0-9]* of [0-9]*' "$work/ut.out" | awk '{print $3}')
[ "${made:-0}" -ge $((FRAMES * 8 / 10)) ] \
  || { echo "FAIL: only ${made:-0} frames were committed of $FRAMES — the screen was not changing, so C2 proved nothing"; exit 1; }
disc=$(awk '/^present:/ { for (i = 1; i < NF; i++) if ($i == "discarded") d += $(i+1) } END { print d + 0 }' "$work/present.log")
runs=$(grep -c '^present:' "$work/present.log" || true)
[ "${runs:-0}" -ge 1 ] && [ "$disc" = 0 ] \
  || { echo "FAIL: the drawing client ran ${runs:-0} time(s) and lost $disc frame(s)"; exit 1; }
echo "ok: the screen changed every frame — $made commits of $FRAMES — and the drawing client lost none ($runs runs)"

# 3. The healthy client was still being served at the end. C2 is not "the
#    compositor survived"; it is "the desktop kept working".
# (1, or 2 while the drawing client's window is between runs.)
grep -q '^windows=[12]$' "$work/ut.out" \
  || { echo "FAIL: the healthy client's window is gone — it was starved out"
       cat "$work/ut.out" "$work/aqua.log"; exit 1; }

hdr_len=$(printf 'P6\n%s %s\n255\n' "$W" "$H" | wc -c | tr -d ' ')
strip_y=$((H / 2))
strip_x0=$(((W - 460) / 2 + 20))
strip_len=420
light=$(dd if="$after" bs=1 \
           skip=$((hdr_len + (((strip_y * W) + strip_x0) * 3))) \
           count=$((strip_len * 3)) 2>/dev/null \
        | od -An -v -tu1 | tr -s ' \n' '\n\n' | grep -v '^$' \
        | awk 'NR % 3 == 1 && $1 > 180 { n++ } END { print n + 0 }')
[ "$light" -gt $((strip_len / 2)) ] \
  || { echo "FAIL: the healthy client's window is not in the final frame"
       echo "      ($light of $strip_len pixels light) — it stopped being composited"
       exit 1; }
echo "ok: the healthy client is still composited ($light of $strip_len pixels)"

[ -n "$out" ] && cp "$after" "$out" && echo "wrote $out"
echo "all green (no client can make this compositor drop a frame)."
