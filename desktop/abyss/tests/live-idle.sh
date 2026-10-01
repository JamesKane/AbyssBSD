#!/bin/sh
# AbyssBSD Swift DE — the displays sleep, something can hold them awake, and
# the primary selection pastes (BACKLOG U.9).
#
# `idletest` is the client: a window that draws on every frame callback, as a
# video does, and so feels the compositor's clock. With --display-sleep 1.5
# (energy.ini's minutes, in seconds, for a test):
#
#   1. with no input the displays sleep, and the client's clock drops to the
#      1 Hz a minimised window gets;
#   2. input wakes them, and the clock is the display's again;
#   3. ext-idle-notify tells a client it has been idle for the time it asked,
#      and when it no longer is;
#   4. an idle inhibitor on a visible window holds the displays awake — and
#      ext-idle-notify's idleness with them: one idea of idle;
#   5. minimised, the same window's inhibitor no longer counts, and the
#      displays sleep;
#   6. the primary selection: one window offers text, another, focused after,
#      is given it and reads it.
#
# Usage: abyss/tests/live-idle.sh
set -eu
root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"
. "$root/abyss/common.sh"
abyss_ensure_runtime_dir

undertow="$root/.build/debug/undertow"
[ -x "$undertow" ] || swift build
command -v wayland-scanner >/dev/null 2>&1 || { echo "note: no wayland-scanner, skipping"; exit 0; }

work=$(mktemp -d /tmp/abyss-idle.XXXXXX)
cleanup() {
  exec 3>&- 4>&- 5>&- 6>&- 2>/dev/null || true
  for p in ${bp:-} ${ap:-} ${vp:-} ${kp:-} ${ut_pid:-}; do kill "$p" 2>/dev/null || true; done
  rm -rf "$work" 2>/dev/null || true
}
trap cleanup EXIT INT TERM HUP
trap '' PIPE          # a dead helper fails the test, not the shell (§2.82)
fail() {
  echo "FAIL: $1"
  sed 's/^/  idletest| /' "$work/a.log" 2>/dev/null | tail -8
  grep -E '^(display-sleep|displays|primary)' "$work/ut.out" 2>/dev/null | sed 's/^/  undertow| /' | tail -5
  grep -m1 -E 'Assertion|Fatal|abort' "$work/ut.err" 2>/dev/null | sed 's/^/  undertow| /' || true
  exit 1
}
# 0, not nothing, when the file is not there yet: an empty count made the
# wait's test an error, which ended the wait at once (HANDOFF §2.106).
count() { n=$(grep -c -- "$1" "$2" 2>/dev/null) || true; echo "${n:-0}"; }
await() {  # await PATTERN FILE BEFORE SECONDS WHY
  i=0
  while [ $i -lt $(($4 * 20)) ]; do
    [ "$(count "$1" "$2")" -gt "$3" ] && return 0
    sleep 0.05; i=$((i + 1))
  done
  fail "$5"
}
frames_in() {  # frames_in SECONDS -> the client's frame callbacks in that time
  printf 'f\n' >&5; sleep "$1"
  n=$(count '^frames ' "$work/a.log")
  printf 'f\n' >&5
  await '^frames ' "$work/a.log" "$n" 2 "the client did not report its frames"
  grep '^frames ' "$work/a.log" | tail -1 | cut -d' ' -f2
}

protos=$(pkg-config --variable=pkgdatadir wayland-protocols)
for x in "vpointer:$root/abyss/tests/wlr-virtual-pointer-unstable-v1.xml" \
         "vkeyboard:$root/abyss/tests/virtual-keyboard-unstable-v1.xml" \
         "idle-inhibit:$protos/unstable/idle-inhibit/idle-inhibit-unstable-v1.xml" \
         "ext-idle-notify:$protos/staging/ext-idle-notify/ext-idle-notify-v1.xml" \
         "primary-selection:$protos/unstable/primary-selection/primary-selection-unstable-v1.xml"; do
  n=${x%%:*}; f=${x#*:}
  wayland-scanner client-header "$f" "$work/$n-proto.h"
  wayland-scanner private-code  "$f" "$work/$n-proto.c"
done
cc -I"$work" "$root/abyss/tests/vpointer.c" "$work/vpointer-proto.c" \
   $(pkg-config --cflags --libs wayland-client) -o "$work/vpointer" || fail "could not build vpointer"
cc -I"$work" "$root/abyss/tests/vkeyboard.c" "$work/vkeyboard-proto.c" \
   $(pkg-config --cflags --libs wayland-client xkbcommon) -o "$work/vkeyboard" || fail "could not build vkeyboard"
cc -I"$work" -I"$root/de/cwayland/include" "$root/abyss/tests/idletest.c" \
   "$root/de/cabyssprotocols/xdg-shell-protocol.c" "$work/idle-inhibit-proto.c" "$work/ext-idle-notify-proto.c" \
   "$work/primary-selection-proto.c" $(pkg-config --cflags --libs wayland-client) -o "$work/idletest" \
   || fail "could not build idletest"

start() {  # start [undertow args...]: an unbounded undertow, WAYLAND_DISPLAY set
  env -u WAYLAND_DISPLAY "$undertow" run --hz 60 --frames 0 --width 800 --height 600 \
      --config-dir "$work/cfg" "$@" > "$work/ut.out" 2> "$work/ut.err" &
  ut_pid=$!
  i=0; wd=""
  while [ $i -lt 60 ]; do
    wd=$(grep -m1 '^WAYLAND_DISPLAY=' "$work/ut.out" 2>/dev/null | cut -d= -f2-) || wd=""
    [ -n "$wd" ] && break
    sleep 0.1; i=$((i + 1))
  done
  [ -n "$wd" ] || fail "undertow never announced a socket"
  export WAYLAND_DISPLAY="$wd"
}
mkdir -p "$work/cfg"

# ================================================= run 1: display sleep
start --display-sleep 1.5
mkfifo "$work/vp.in" "$work/a.in"
"$work/vpointer" 800 600 < "$work/vp.in" > "$work/vp.log" 2>&1 &
vp=$!; exec 3>"$work/vp.in"
"$work/idletest" < "$work/a.in" > "$work/a.log" 2>&1 &
ap=$!; exec 5>"$work/a.in"
await '^ready' "$work/a.log" 0 5 "the window never mapped"
# The loop reports, and the clock ticks, after undertow's 4 s warm-up (§2.83).
await '^display-sleep ' "$work/ut.out" 0 8 "undertow never reported display sleep"

# ------------------------------------------------------ 1. asleep
await '^displays asleep$' "$work/ut.out" 0 4 "with no input for 1.5 s the displays did not sleep"
slow=$(frames_in 2)
[ "$slow" -le 4 ] || fail "asleep, the client still had $slow frame callbacks in 2 s (want the 1 Hz clock)"
! grep -q 'could not turn' "$work/ut.err" || fail "an output refused to turn off: $(grep 'could not turn' "$work/ut.err" | head -1)"
echo "ok: 1. no input for 1.5 s: the displays slept, and the client's clock fell to $slow frames in 2 s"

# ------------------------------------------------------ 2. awake
b=$(count '^displays awake$' "$work/ut.out")
printf 'd 1 0\n' >&3
await '^displays awake$' "$work/ut.out" "$b" 2 "a motion did not wake the displays"
fast=$(frames_in 1)
[ "$fast" -ge 30 ] || fail "awake, the client had only $fast frame callbacks in a second"
echo "ok: 2. a motion woke them, and the clock is the display's again ($fast frames in 1 s)"

# ------------------------------------------------------ 3. idle-notify
printf 'd 1 0\n' >&3
printf 'n 800\n' >&5
await '^idled$' "$work/a.log" 0 3 "ext-idle-notify never said the client was idle for 800 ms"
printf 'd 1 0\n' >&3
await '^resumed$' "$work/a.log" 0 2 "ext-idle-notify never said idleness ended on input"
echo "ok: 3. ext-idle-notify: idled after 800 ms without input, resumed on the next"

# ------------------------------------------------------ 4. inhibited
printf 'i\n' >&5
await 'inhibited=yes' "$work/ut.out" 0 2 "an inhibitor on a visible window was not counted"
s=$(count '^displays asleep$' "$work/ut.out"); idl=$(count '^idled$' "$work/a.log")
sleep 3
[ "$(count '^displays asleep$' "$work/ut.out")" = "$s" ] || fail "the displays slept under an inhibitor"
[ "$(count '^idled$' "$work/a.log")" = "$idl" ] || fail "ext-idle-notify said idle under an inhibitor"
held=$(frames_in 1)
[ "$held" -ge 30 ] || fail "under an inhibitor, the clock ran at $held frames in a second"
echo "ok: 4. an inhibitor held the displays awake through 3 s without input — and ext-idle-notify's idleness with them"

# ------------------------------------------------------ 5. minimised
printf 'm\n' >&5
await 'inhibited=no' "$work/ut.out" 0 2 "minimised, the window's inhibitor still counted"
await '^displays asleep$' "$work/ut.out" "$s" 4 "with the inhibiting window minimised the displays did not sleep"
echo "ok: 5. minimised, its inhibitor no longer counted, and the displays slept"
kill -0 "$ut_pid" 2>/dev/null || fail "undertow died"
exec 3>&- 5>&-
kill "$ap" "$vp" "$ut_pid" 2>/dev/null || true; wait "$ut_pid" 2>/dev/null || true
ap=""; vp=""; ut_pid=""

# ================================================= run 2: the primary selection
start
mkfifo "$work/vk.in" "$work/b.in"
"$work/vkeyboard" < "$work/vk.in" > "$work/vk.log" 2>&1 &
kp=$!; exec 4>"$work/vk.in"
i=0; while ! grep -q ready "$work/vk.log" 2>/dev/null && [ $i -lt 60 ]; do sleep 0.1; i=$((i + 1)); done
: > "$work/a.log"
"$work/idletest" < "$work/a.in" > "$work/a.log" 2>&1 &
ap=$!; exec 5>"$work/a.in"
await '^focus$' "$work/a.log" 0 5 "the first window never got the keyboard"
printf 'c hello-primary\n' >&5
await '^primary-selections-accepted=1$' "$work/ut.out" 0 8 "undertow did not accept the primary selection"
"$work/idletest" org.abyssbsd.idletest2 < "$work/b.in" > "$work/b.log" 2>&1 &
bp=$!; exec 6>"$work/b.in"
await '^pasted hello-primary$' "$work/b.log" 0 5 "the second window, focused, was not given the primary selection ($(cat "$work/b.log" | tr '\n' ' '))"
echo "ok: 6. one window's primary selection reached the next one focused: it read 'hello-primary'"

echo "all green (the displays sleep and wake, an inhibitor holds them, and the primary selection pastes — through undertow)."
