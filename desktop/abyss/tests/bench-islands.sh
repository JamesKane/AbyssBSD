#!/bin/sh
# AbyssBSD Swift DE — C6, gating the build (PHASE13 P13.2, PRODUCT §7.2).
#
#   C6 — an island switch is committed within 2 frames of the input that asked
#   for it, and any animation is decoration that can be skipped, interrupted
#   and re-targeted without delaying the commit.
#
# Measured by undertow itself (SwitchLatency.swift): from the moment a switch is
# asked for, during the key's dispatch, to the vblank of the first frame that
# drew it, in frame periods. Counting latches would always say 1; this counts
# what a person sees, and a frame the display refused costs what it costs them.
#
# Under C2's load, because a contract that holds only on an idle desktop is not
# one: twelve windows on four islands, the eleven adversaries of
# live-undertow-c2.sh loose, and ~45 switches by the keyboard (Ctrl-N, the real
# input path), each after a jittered pause so the input lands at every phase of
# the frame. Asserted inside the binary:
#
#   1. C6: p99 ≤ 2 frames;
#   2. the switches arrived — at least 40 measured (a bench whose input never
#      reached the compositor passes beautifully and proves nothing);
#   3. C1 held while it switched: missed frames within the same 5-per-mille
#      budget bench-metronome.sh gives an idle compositor;
#   4. and while Ebb opened and closed over the same load ten times (P13.5:
#      "an Ebb drawn over the eleven adversary clients C2 already survives") —
#      counted, so an Ebb that never opened cannot pass.
#
# Usage: abyss/tests/bench-islands.sh
set -eu
root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"
. "$root/abyss/common.sh"
abyss_ensure_runtime_dir

undertow="$root/.build/debug/undertow"
[ -x "$undertow" ] || swift build
command -v wayland-scanner >/dev/null 2>&1 || { echo "note: no wayland-scanner, skipping"; exit 0; }

HZ=60
FRAMES=1800           # 30 s: room for the windows, the storm, every switch and Ebb
MISS_BUDGET=9         # 5 per mille of 1800, as bench-metronome.sh allows
SWITCHES=45
C6_FRAMES=2
HARD=8

work=$(mktemp -d /tmp/abyss-c6.XXXXXX)
pidfile="$work/adv.pids"; : > "$pidfile"
cleanup() {
  exec 4>&- 2>/dev/null || true
  [ -s "$pidfile" ] && while read -r p; do kill -9 "$p" 2>/dev/null || true; done < "$pidfile"
  for p in ${vk:-} ${ut_pid:-}; do kill -9 "$p" 2>/dev/null || true; done
  rm -rf "$work" 2>/dev/null || true
}
trap cleanup EXIT INT TERM HUP
trap '' PIPE
fail() { echo "FAIL: $1"; tail -5 "$work/ut.err" 2>/dev/null | sed 's/^/  undertow| /'; exit 1; }
count() { n=$(grep -c -- "$1" "$2" 2>/dev/null) || true; echo "${n:-0}"; }
await() { i=0; while [ "$(count "$2" "$1")" -lt "${4:-1}" ] && [ $i -lt 100 ]; do i=$((i + 1)); sleep 0.05; done
          [ "$(count "$2" "$1")" -ge "${4:-1}" ] || fail "$3"; }

protos=$(pkg-config --variable=pkgdatadir wayland-protocols)
wayland-scanner client-header "$protos/staging/ext-session-lock/ext-session-lock-v1.xml" "$work/ext-session-lock-proto.h"
wayland-scanner private-code  "$protos/staging/ext-session-lock/ext-session-lock-v1.xml" "$work/ext-session-lock-proto.c"
wayland-scanner client-header "$root/abyss/tests/virtual-keyboard-unstable-v1.xml" "$work/vkeyboard-proto.h"
wayland-scanner private-code  "$root/abyss/tests/virtual-keyboard-unstable-v1.xml" "$work/vkeyboard-proto.c"
cc -I"$work" "$root/abyss/tests/vkeyboard.c" "$work/vkeyboard-proto.c" $(pkg-config --cflags --libs wayland-client xkbcommon) -o "$work/vkeyboard" || fail "vkeyboard"
cc -I"$work" -I"$root/de/cwayland/include" "$root/abyss/tests/lockclient.c" "$root/de/cabyssprotocols/xdg-shell-protocol.c" \
   "$work/ext-session-lock-proto.c" $(pkg-config --cflags --libs wayland-client) -o "$work/lockclient" || fail "lockclient"
cc -I "$root/de/cwayland/include" "$root/abyss/tests/adversary.c" "$root/de/cabyssprotocols/xdg-shell-protocol.c" \
   $(pkg-config --cflags --libs wayland-client) -o "$work/adversary" || fail "the adversary"

env -u WAYLAND_DISPLAY "$undertow" run --hz "$HZ" --frames "$FRAMES" --width 800 --height 600 \
    --config-dir "$work" --assert-missed "$MISS_BUDGET" \
    --assert-c6-frames "$C6_FRAMES" --assert-c6-switches $((SWITCHES - 5)) \
    > "$work/ut.out" 2> "$work/ut.err" &
ut_pid=$!
await "$work/ut.out" '^WAYLAND_DISPLAY=' "undertow never announced a socket"
export WAYLAND_DISPLAY="$(grep -m1 '^WAYLAND_DISPLAY=' "$work/ut.out" | cut -d= -f2-)"
mkfifo "$work/vk"
"$work/vkeyboard" < "$work/vk" > "$work/vk.log" 2>&1 & vk=$!; exec 4>"$work/vk"
await "$work/vk.log" ready "vkeyboard never bound"

# Twelve windows, three to an island. The lockclient windows sit on their stdin;
# a fifo each that nobody writes keeps them open and quiet.
spawn() { ( "$work/lockclient" window "$1" "org.abyssbsd.c6-$2" < "$work/hold" > /dev/null 2>&1 & echo $! >> "$pidfile" ); }
mkfifo "$work/hold"; exec 5<>"$work/hold"
for island in 1 2 3 4; do
  printf 'c 4 %s\n' $((island + 1)) >&4
  await "$work/ut.out" "^islands HEADLESS-1=$island\$" "Ctrl-$island did not switch while the windows were being opened"
  for k in 1 2 3; do spawn ff336699 "$island-$k"; done
  await "$work/ut.out" "^window-island org.abyssbsd.c6-$island-3 $island\$" "island $island's windows did not open on it"
done
echo "ok: twelve windows, three on each of four islands"

spawn_adversary() { ( "$work/adversary" "$@" > /dev/null 2>&1 & echo $! >> "$pidfile" ); }
n=0; while [ "$n" -lt "$HARD" ]; do spawn_adversary hard 0; n=$((n + 1)); done
spawn_adversary zombie; spawn_adversary deaf; spawn_adversary churn 0
echo "ok: $HARD socket-flooders, a zombie, a spinning never-reader and a churner are loose"
sleep 1

# The switches: a jittered pause (90–290 ms, never a multiple of the period on
# purpose) before each, so the input lands at every phase of the frame.
awk -v n="$SWITCHES" 'BEGIN { srand(13); for (i = 0; i < n; i++) printf "%d %.3f\n", (i % 4) + 1, 0.09 + rand() * 0.2 }' \
  > "$work/plan"
last=4
while read -r island pause; do
  [ "$island" = "$last" ] && island=$(( island % 4 + 1 ))
  sleep "$pause"; printf 'c 4 %s\n' $((island + 1)) >&4; last=$island
done < "$work/plan"
echo "ok: $SWITCHES switches asked for, by the keyboard"

# Ebb over the storm: F3 open, F3 closed, ten times, on a full island.
for i in 1 2 3 4 5 6 7 8 9 10; do
  printf 'c 0 61\n' >&4; sleep 0.25; printf 'c 0 61\n' >&4; sleep 0.25
done
echo "ok: Ebb opened and closed ten times over the same load"

rc=0; wait "$ut_pid" 2>/dev/null || rc=$?
ut_pid=""
grep '^c6 ' "$work/ut.out" | sed 's/^/   /'
grep '^island-commit ' "$work/ut.out" | sed 's/.*us=//' | sort -n \
  | awk '{ a[NR] = $1 } END { if (NR) printf "   input to the vblank that showed it: min %.1f ms, median %.1f ms, max %.1f ms\n", a[1] / 1000, a[int((NR + 1) / 2)] / 1000, a[NR] / 1000 }'
[ "$rc" = 0 ] || { grep -E '^FAIL' "$work/ut.err" | sed 's/^/  /'; fail "the island switch contract did not hold (see above)"; }
opened=$(count 'undertow: ebb HEADLESS-1 on island' "$work/ut.err")
[ "$opened" -ge 10 ] || fail "Ebb opened only $opened time(s) of 10 — the load it was meant to be drawn over proves nothing"
echo "ok: C6 held — $(grep '^c6 ' "$work/ut.out" | cut -d' ' -f2-), limit p99 ≤ $C6_FRAMES; C1's budget held under load"
echo "all green (C6: an island switch reaches the screen within two frames, and Ebb draws, under C2's load)."
