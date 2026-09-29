#!/bin/sh
# AbyssBSD Swift DE — the pointer, locked and confined (BACKLOG U.6).
#
# relative-pointer-v1 and pointer-constraints-v1: what a game turning its
# camera, or Blender rotating a view, needs. `locktest` stands where they
# would: a window that asks for a lock or a confinement and prints what
# undertow tells it. Claims, each on the CLIENT's word:
#
#   1. every motion also arrives as a delta (relative-pointer);
#   2. locked, the pointer stays put — no motion, however far the mouse or an
#      absolute device goes — and the deltas still arrive;
#   3. the lock's cursor hint is honoured: unlocked, the pointer is where the
#      client said it drew it;
#   4. a lock holds only for the focused window: another window taking focus
#      ends it; the persistent lock takes effect again when its window is
#      focused and has the pointer;
#   5. confined to a rectangle, the pointer stops at its edges.
#
# Usage: abyss/tests/live-lock.sh
set -eu
root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"
. "$root/abyss/common.sh"
abyss_ensure_runtime_dir

undertow="$root/.build/debug/undertow"
[ -x "$undertow" ] || swift build
command -v wayland-scanner >/dev/null 2>&1 || { echo "note: no wayland-scanner, skipping"; exit 0; }

work=$(mktemp -d /tmp/abyss-lock.XXXXXX)
cleanup() {
  exec 3>&- 5>&- 6>&- 2>/dev/null || true
  for p in ${bp:-} ${ap:-} ${vp:-} ${ut_pid:-}; do kill "$p" 2>/dev/null || true; done
  rm -rf "$work" 2>/dev/null || true
}
trap cleanup EXIT INT TERM HUP
# A write to a helper that has died must fail loudly, not end the script with
# SIGPIPE and no message (HANDOFF §2.82).
trap '' PIPE
fail() {
  echo "FAIL: $1"
  sed 's/^/  locktest| /' "$work/a.log" 2>/dev/null | tail -10
  grep '^pointer-constraints' "$work/ut.out" 2>/dev/null | sed 's/^/  undertow| /' | tail -3
  grep -m1 -E 'Assertion|Fatal|abort' "$work/ut.err" 2>/dev/null | sed 's/^/  undertow| /' || true
  exit 1
}
alive() { kill -0 "$ut_pid" 2>/dev/null || fail "undertow died ($1)"; }
mark() { grep -c -- "$1" "$work/a.log" 2>/dev/null || true; }
await() {  # await PATTERN BEFORE WHY
  i=0
  while [ $i -lt 60 ]; do
    [ "$(mark "$1")" -gt "$2" ] && return 0
    sleep 0.05; i=$((i + 1))
  done
  fail "$3 (no new '$1' from locktest)"
}
last_motion() { grep '^motion ' "$work/a.log" | tail -1 | cut -d' ' -f2-; }

wayland-scanner client-header "$root/abyss/tests/wlr-virtual-pointer-unstable-v1.xml" "$work/vpointer-proto.h"
wayland-scanner private-code  "$root/abyss/tests/wlr-virtual-pointer-unstable-v1.xml" "$work/vpointer-proto.c"
for n in relative-pointer pointer-constraints; do
  wayland-scanner client-header "$root/protocols/$n-unstable-v1.xml" "$work/$n-proto.h"
  wayland-scanner private-code  "$root/protocols/$n-unstable-v1.xml" "$work/$n-proto.c"
done
cc -I"$work" "$root/abyss/tests/vpointer.c" "$work/vpointer-proto.c" \
   $(pkg-config --cflags --libs wayland-client) -o "$work/vpointer" || fail "could not build vpointer"
cc -I"$work" -I"$root/de/cwayland/include" "$root/abyss/tests/locktest.c" \
   "$root/de/cabyssprotocols/xdg-shell-protocol.c" "$work/relative-pointer-proto.c" "$work/pointer-constraints-proto.c" \
   $(pkg-config --cflags --libs wayland-client) -o "$work/locktest" || fail "could not build locktest"

W=800; H=600
wd="abyss-lock-$$"
env -u WAYLAND_DISPLAY "$undertow" run --hz 60 --frames 0 --width $W --height $H --socket "$wd" \
    --config-dir "$work" > "$work/ut.out" 2> "$work/ut.err" &
ut_pid=$!
i=0; while [ ! -S "$XDG_RUNTIME_DIR/$wd" ] && [ $i -lt 100 ]; do i=$((i+1)); sleep 0.05; done
[ -S "$XDG_RUNTIME_DIR/$wd" ] || fail "undertow never bound $wd"
export WAYLAND_DISPLAY="$wd"

# The pointer first, so the seat has one when the window asks for it.
mkfifo "$work/vp.in" "$work/a.in" "$work/b.in"
"$work/vpointer" $W $H < "$work/vp.in" > "$work/vp.log" 2>&1 &
vp=$!; exec 3>"$work/vp.in"
i=0; while ! grep -q ready "$work/vp.log" 2>/dev/null && [ $i -lt 60 ]; do sleep 0.1; i=$((i + 1)); done
"$work/locktest" < "$work/a.in" > "$work/a.log" 2>&1 &
ap=$!; exec 5>"$work/a.in"
await '^ready' 0 "the window never mapped"
# undertow reports windows after its warm-up (240 frames, 4 s): wait for it.
i=0; win=""
while [ -z "$win" ] && [ $i -lt 160 ]; do
  win=$(grep '^window org.abyssbsd.locktest[/ ]' "$work/ut.out" | tail -1) || true; sleep 0.05; i=$((i + 1)); done
[ -n "$win" ] || fail "undertow never reported the window"
pos=$(printf '%s' "$win" | awk '{print $3}'); wx=${pos%,*}; wy=${pos#*,}
pc() { grep '^pointer-constraints' "$work/ut.out" | tail -1; }

# ------------------------------------------------------ 1. deltas
b=$(mark '^enter ')
printf 'm %s %s\n' $((wx + 200)) $((wy + 150)) >&3
await '^enter ' "$b" "the pointer never entered the window"
b=$(mark '^rel 5 3$')
printf 'd 5 3\n' >&3
await '^rel 5 3$' "$b" "a relative motion did not arrive as a delta"
i=0; while [ "$(last_motion)" != "205 153" ] && [ $i -lt 40 ]; do sleep 0.05; i=$((i + 1)); done
[ "$(last_motion)" = "205 153" ] || fail "the pointer did not move by the delta: at $(last_motion)"
echo "ok: 1. a motion arrives as a delta (rel 5 3), and the pointer moved by it"

# ------------------------------------------------------ 2. locked
b=$(mark '^locked$')
printf 'l\n' >&5
await '^locked$' "$b" "asking for a lock (the pointer over the focused window) did not lock it"
m=$(mark '^motion '); r=$(mark '^rel ')
printf 'd 40 0\n' >&3; sleep 0.1; printf 'd 40 0\n' >&3; sleep 0.1; printf 'd 40 0\n' >&3; sleep 0.1
n=$(mark '^rel -')
printf 'm 10 10\n' >&3                                  # an absolute device, far away
await '^rel -' "$n" "the absolute move's delta did not arrive while locked"
alive "the lock"
[ "$(mark '^motion ')" = "$m" ] || fail "the pointer moved while locked: $(grep '^motion ' "$work/a.log" | tail -1)"
[ $(( $(mark '^rel ') - r )) -ge 4 ] || fail "only $(( $(mark '^rel ') - r )) deltas arrived while locked, not 4"
echo "ok: 2. locked, the pointer stayed at 205,153 through 120 px of motion and an absolute jump — and 4 deltas arrived"

# ------------------------------------------------------ 3. the hint
printf 'h 10 20\n' >&5; sleep 0.2
printf 'u\n' >&5; sleep 0.2
b=$(mark '^motion ')
printf 'd 1 1\n' >&3
await '^motion ' "$b" "no motion after the lock was released"
[ "$(last_motion)" = "11 21" ] || fail "unlocked, the pointer was not where the hint put it (10,20 then +1,+1): at $(last_motion)"
pc | grep -q ' warps=1 ' || fail "undertow does not count the warp: $(pc)"
echo "ok: 3. released, the pointer was where the client drew it (the hint 10,20; then 11,21)"

# ------------------------------------------------------ 4. focus
b=$(mark '^locked$')
printf 'l\n' >&5
await '^locked$' "$b" "a second lock did not take"
u=$(mark '^unlocked$')
"$work/locktest" org.abyssbsd.locktest2 < "$work/b.in" > "$work/b.log" 2>&1 &
bp=$!; exec 6>"$work/b.in"
await '^unlocked$' "$u" "another window taking focus did not end the lock"
echo "ok: 4. another window taking focus ended the lock (unlocked)"
b=$(mark '^locked$')
exec 6>&-; wait "$bp" 2>/dev/null || true; bp=""       # it goes; the first is focused again
sleep 0.3
printf 'd 0 0\n' >&3; sleep 0.1; printf 'd 1 0\n' >&3
await '^locked$' "$b" "focused again with the pointer over it, the persistent lock did not take effect again"
alive "the second window going"
echo "ok: 4b. that window gone, the first focused again: the persistent lock took effect again (locked)"
printf 'u\n' >&5; sleep 0.2

# ------------------------------------------------------ 5. confined
printf 'c 50 50 100 100\n' >&5; sleep 0.2
b=$(mark '^confined$')
printf 'm %s %s\n' $((wx + 100)) $((wy + 100)) >&3
await '^confined$' "$b" "the pointer entering the region did not confine it"
printf 'd 500 0\n' >&3; sleep 0.2
[ "$(last_motion)" = "149 100" ] || fail "confined to 50..149, a move right ended at $(last_motion)"
printf 'd -500 -500\n' >&3; sleep 0.2
[ "$(last_motion)" = "50 50" ] || fail "confined to 50..149, a move up-left ended at $(last_motion)"
echo "ok: 5. confined to (50,50 100x100): a move right stopped at 149,100, up-left at 50,50"

alive "the end"
i=0; while ! pc | grep -q 'confines=1 .*active=yes' && [ $i -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
pc | grep -Eq '^pointer-constraints locks=3 confines=1 held=[1-9][0-9]* warps=1 active=yes$' \
  || fail "undertow's counts: $(pc)"
echo "ok: undertow: $(pc)"

echo "all green (the pointer locks, confines, and lets go — through undertow)."
