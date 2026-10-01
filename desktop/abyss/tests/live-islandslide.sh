#!/bin/sh
# AbyssBSD Swift DE — the island slide is decoration (PHASE13 P13.3, PRODUCT §7.2).
#
# Commit first, animate second: the island, the focus and the keys change on
# the frame the switch is asked for, and the slide only moves pixels. Slowed to
# 2 s here (islands.ini `slide_ms`, allowed up to 2 s for exactly this) so a
# screencopy can catch it in the middle. Windows: A blue on island 1, B red on
# island 2, C green on island 3. Claims:
#
#   1. Ctrl-2: undertow says island 2 at once, and a key reaches B at once —
#      while the slide has most of its 2 s still to run;
#   2. mid-slide, both islands are on screen — A leaving, B arriving — and
#      neither is drawn whole;
#   3. it ends: only B;
#   4. re-targeted: Ctrl-1 then, mid-slide, Ctrl-3 — island 3 is committed at
#      once and the slide ends on C alone, never queueing a stop at island 1;
#   5. off (`animate = no`, even with a 2 s slide configured): the first frame
#      after the switch is the new island, whole.
#
# Usage: abyss/tests/live-islandslide.sh
set -eu
root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"
. "$root/abyss/common.sh"
abyss_ensure_runtime_dir

undertow="$root/.build/debug/undertow"
grab="$root/.build/debug/abyssgrab"
[ -x "$undertow" ] && [ -x "$grab" ] || swift build
command -v wayland-scanner >/dev/null 2>&1 || { echo "note: no wayland-scanner, skipping"; exit 0; }

work=$(mktemp -d /tmp/abyss-slide.XXXXXX)
cleanup() {
  exec 4>&- 5>&- 6>&- 7>&- 2>/dev/null || true
  for p in ${wc:-} ${wb:-} ${wa:-} ${vk:-} ${ut_pid:-}; do kill "$p" 2>/dev/null || true; done
  rm -rf "$work" 2>/dev/null || true
}
trap cleanup EXIT INT TERM HUP
trap '' PIPE
fail() { echo "FAIL: $1"
         grep -E '^(islands|window-island|island-commit)' "$work/ut.out" 2>/dev/null | tail -4 | sed 's/^/  undertow| /'
         exit 1; }
count() { n=$(grep -c -- "$1" "$2" 2>/dev/null) || true; echo "${n:-0}"; }
await() {  # await FILE PATTERN WHY [TIMES]
  i=0; while [ "$(count "$2" "$1")" -lt "${4:-1}" ] && [ $i -lt 100 ]; do i=$((i + 1)); sleep 0.05; done
  [ "$(count "$2" "$1")" -ge "${4:-1}" ] || fail "$3"
}
shot() { "$grab" "$work/$1.ppm" > "$work/grab.log" 2>&1 || fail "abyssgrab ($1): $(cat "$work/grab.log")"; }
has() {
  hdr=$(head -3 "$work/$1.ppm" | wc -c | tr -d ' ')
  tail -c +$((hdr + 1)) "$work/$1.ppm" | od -An -v -tu1 | tr -s ' \n' '\n\n' | grep -v '^$' \
    | awk -v r="$2" -v g="$3" -v b="$4" '{ v[NR % 3] = $1 } NR % 3 == 0 && v[1] == r && v[2] == g && v[0] == b { n++ } END { print n + 0 }'
}
blue() { has "$1" 51 102 153; }; red() { has "$1" 204 34 34; }; green() { has "$1" 34 170 34; }

protos=$(pkg-config --variable=pkgdatadir wayland-protocols)
wayland-scanner client-header "$protos/staging/ext-session-lock/ext-session-lock-v1.xml" "$work/ext-session-lock-proto.h"
wayland-scanner private-code  "$protos/staging/ext-session-lock/ext-session-lock-v1.xml" "$work/ext-session-lock-proto.c"
wayland-scanner client-header "$root/abyss/tests/virtual-keyboard-unstable-v1.xml" "$work/vkeyboard-proto.h"
wayland-scanner private-code  "$root/abyss/tests/virtual-keyboard-unstable-v1.xml" "$work/vkeyboard-proto.c"
cc -I"$work" "$root/abyss/tests/vkeyboard.c" "$work/vkeyboard-proto.c" $(pkg-config --cflags --libs wayland-client xkbcommon) -o "$work/vkeyboard" || fail "vkeyboard"
cc -I"$work" -I"$root/de/cwayland/include" "$root/abyss/tests/lockclient.c" "$root/de/cabyssprotocols/xdg-shell-protocol.c" \
   "$work/ext-session-lock-proto.c" $(pkg-config --cflags --libs wayland-client) -o "$work/lockclient" || fail "lockclient"

# start CONFIG-LINES: undertow with an islands.ini, a keyboard, and A, B and C
# on islands 1, 2 and 3.
start() {
  for p in ${wc:-} ${wb:-} ${wa:-} ${vk:-} ${ut_pid:-}; do kill "$p" 2>/dev/null || true; done
  exec 4>&- 5>&- 6>&- 7>&- 2>/dev/null || true
  sleep 0.3; rm -rf "$work/cfg" "$work/vk" "$work/a" "$work/b" "$work/c"; mkdir -p "$work/cfg"
  printf '[islands]\n%s\n' "$1" > "$work/cfg/islands.ini"
  env -u WAYLAND_DISPLAY "$undertow" run --hz 60 --frames 0 --width 800 --height 600 \
      --config-dir "$work/cfg" > "$work/ut.out" 2> "$work/ut.err" &
  ut_pid=$!
  await "$work/ut.out" '^WAYLAND_DISPLAY=' "undertow never announced a socket"
  export WAYLAND_DISPLAY="$(grep -m1 '^WAYLAND_DISPLAY=' "$work/ut.out" | cut -d= -f2-)"
  mkfifo "$work/vk" "$work/a" "$work/b" "$work/c"
  "$work/vkeyboard" < "$work/vk" > "$work/vk.log" 2>&1 & vk=$!; exec 4>"$work/vk"
  await "$work/vk.log" ready "vkeyboard never bound"
  "$work/lockclient" window ff336699 org.abyssbsd.sl-a < "$work/a" > "$work/a.log" 2>&1 & wa=$!; exec 5>"$work/a"
  await "$work/ut.out" '^window-island org.abyssbsd.sl-a 1$' "A did not open on island 1"
  printf 'c 4 3\n' >&4; await "$work/ut.out" '^islands HEADLESS-1=2$' "could not reach island 2 to open B"
  "$work/lockclient" window ffcc2222 org.abyssbsd.sl-b < "$work/b" > "$work/b.log" 2>&1 & wb=$!; exec 6>"$work/b"
  await "$work/ut.out" '^window-island org.abyssbsd.sl-b 2$' "B did not open on island 2"
  printf 'c 4 4\n' >&4; await "$work/ut.out" '^islands HEADLESS-1=3$' "could not reach island 3 to open C"
  "$work/lockclient" window ff22aa22 org.abyssbsd.sl-c < "$work/c" > "$work/c.log" 2>&1 & wc=$!; exec 7>"$work/c"
  await "$work/ut.out" '^window-island org.abyssbsd.sl-c 3$' "C did not open on island 3"
  printf 'c 4 2\n' >&4; await "$work/ut.out" '^islands HEADLESS-1=1$' "could not get back to island 1" 2
  sleep "$2"                                     # let the setup's slides finish
}

start 'slide_ms = 2000' 2.3
shot still
[ "$(blue still)" -gt 1000 ] && [ "$(red still)" = 0 ] || fail "at rest on island 1, the screen is not A alone"
whole=$(blue still)

# ------------------------------------------------- 1. committed at once
# Both windows are partly on screen only between ~30 % and ~70 % of the travel,
# which the ease-out covers between ~0.12 and ~0.32 of the time: 0.25–0.65 s.
printf 'c 4 3\n' >&4
await "$work/ut.out" '^islands HEADLESS-1=2$' "Ctrl-2 was not committed" 2
sleep 0.35; shot mid
k=$(count '^key ' "$work/b.log"); printf 'k 30\n' >&4; sleep 0.2
[ "$(count '^key ' "$work/b.log")" -gt "$k" ] || fail "mid-slide, a key did not reach B, on the island already shown"
echo "ok: 1. Ctrl-2 committed at once: undertow says island 2, and a key reached B with the slide still running"

# --------------------------------------------------------- 2. mid-slide
b=$(blue mid); r=$(red mid)
[ "$b" -gt 0 ] && [ "$r" -gt 0 ] || fail "mid-slide, not both islands on screen (A $b, B $r pixels)"
[ "$b" -lt "$whole" ] && [ "$r" -lt "$whole" ] || fail "mid-slide, one window is drawn whole (A $b, B $r of $whole)"
echo "ok: 2. mid-slide, A leaving and B arriving, neither whole (A $b, B $r of $whole pixels)"

# ------------------------------------------------------------- 3. it ends
sleep 1.6; shot end
[ "$(red end)" -ge "$whole" ] && [ "$(blue end)" = 0 ] || fail "after the slide, not B alone (A $(blue end), B $(red end))"
echo "ok: 3. the slide ended on B alone"

# ------------------------------------------------------- 4. re-targeted
printf 'c 4 2\n' >&4; sleep 0.3
printf 'c 4 4\n' >&4
await "$work/ut.out" '^islands HEADLESS-1=3$' "Ctrl-3 mid-slide was not committed at once" 2
sleep 2.3; shot retarget
[ "$(green retarget)" -ge "$whole" ] && [ "$(blue retarget)" = 0 ] && [ "$(red retarget)" = 0 ] \
  || fail "re-targeted, the slide did not end on C alone (A $(blue retarget), B $(red retarget), C $(green retarget))"
# Queued, the slide to 1 would finish (~1.7 s more) before one to 3 began (2 s):
# C could not be whole 2.3 s after Ctrl-3. Both requests are committed, though —
# undertow showing island 1 for 0.3 s is right; travelling there is not.
echo "ok: 4. re-targeted mid-slide: island 3 committed at once, and the slide ended on C alone"

# ---------------------------------------------------------------- 5. off
# With a 2 s slide configured too, so ignoring `animate = no` cannot hide behind
# a default slide that is nearly over by the time of the capture.
start "$(printf 'animate = no\nslide_ms = 2000')" 0.3
printf 'c 4 3\n' >&4
await "$work/ut.out" '^islands HEADLESS-1=2$' "with the slide off, Ctrl-2 was not committed" 2
sleep 0.1; shot off
[ "$(red off)" -ge "$whole" ] && [ "$(blue off)" = 0 ] || fail "with the slide off, the first frame was not B whole (A $(blue off), B $(red off))"
echo "ok: 5. off: the next frame is the new island, whole"
echo "all green (the island slide: decoration after the commit, re-targeted, never queued, and skippable)."
