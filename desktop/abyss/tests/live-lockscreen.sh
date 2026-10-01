#!/bin/sh
# AbyssBSD Swift DE — the Aqua lock screen (PHASE16 P16.2b).
#
# The lock screen (`AQUA_SCENE=lock`) over undertow, asking a stand-in
# authenticator (`abyss-loginstub`: the real Authenticator — uid from the
# kernel, the limiter, the log — with PAM replaced by a password file, because
# Linux has no PAM and the guest has no throwaway account to log in as here;
# the real daemon is live-authenticator.sh's). A window (blue) sits behind it.
# Asserted in captures (`abyssgrab --diff` says *where* two differ) and in the
# three processes' logs:
#
#   1. locked: no pixel of the window; the lock screen is drawn, not the bare
#      lock colour;
#   2. typing changes the field and nothing else — and keeps changing it
#      (the lock surface has a frame clock: P16.2a's missing one, found here);
#   3. a wrong password is refused: the panel shakes (it moves while it says
#      so), the field is emptied, and only the message line is left changed;
#   4. after the limiter's free typos, the answer is "wait": the field closes,
#      and the right password typed then is not even sent; when the wait is
#      over it is, and it unlocks — the lock screen exits 0, the window is back
#      and has the keys;
#   5. no password in anything any of the three wrote;
#   6. with no authenticator to ask, it says so and the session stays locked;
#   7. two displays: the lock screen covers both, and neither shows the window.
#
# Usage: abyss/tests/live-lockscreen.sh
set -eu
root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"
. "$root/abyss/common.sh"
abyss_ensure_runtime_dir

undertow="$root/.build/debug/undertow"
grab="$root/.build/debug/abyssgrab"
aqua="$root/.build/debug/AquaDemo"
stub="$root/.build/debug/abyss-loginstub"
for b in "$undertow" "$grab" "$aqua" "$stub"; do [ -x "$b" ] || { swift build; break; }; done
command -v wayland-scanner >/dev/null 2>&1 || { echo "note: no wayland-scanner, skipping"; exit 0; }

work=$(mktemp -d /tmp/abyss-lks.XXXXXX)
cleanup() {
  exec 4>&- 5>&- 2>/dev/null || true
  for p in ${lk:-} ${wa:-} ${vk:-} ${st:-} ${ut_pid:-}; do kill "$p" 2>/dev/null || true; done
  rm -rf "$work" 2>/dev/null || true
}
trap cleanup EXIT INT TERM HUP
trap '' PIPE
fail() { echo "FAIL: $1"
         grep -E '^LockScreen' "$work/lock.err" 2>/dev/null | tail -4 | sed 's/^/  lock| /'
         grep -E '^loginwindow' "$work/stub.log" 2>/dev/null | tail -3 | sed 's/^/  stub| /'
         exit 1; }
await() {  # await FILE PATTERN WHY
  i=0; while ! grep -q -- "$2" "$1" 2>/dev/null && [ $i -lt 100 ]; do i=$((i + 1)); sleep 0.05; done
  grep -q -- "$2" "$1" 2>/dev/null || fail "$3"
}
count() { grep -c -- "$1" "$2" 2>/dev/null || true; }
shot() { "$grab" "$work/$1.ppm" ${2:+--output $2} > "$work/grab.log" 2>&1 || fail "abyssgrab: $(cat "$work/grab.log")"; }
has() {
  hdr=$(head -3 "$work/$1.ppm" | wc -c | tr -d ' ')
  tail -c +$((hdr + 1)) "$work/$1.ppm" | od -An -v -tu1 | tr -s ' \n' '\n\n' | grep -v '^$' \
    | awk -v r="$2" -v g="$3" -v b="$4" '{ v[NR % 3] = $1 } NR % 3 == 0 && v[1] == r && v[2] == g && v[0] == b { n++ } END { print n + 0 }'
}
# diffbox A B: "same", or "X Y W H" of where they differ.
diffbox() {
  d=$("$grab" --diff "$work/$1.ppm" "$work/$2.ppm" 2>&1) || true
  case "$d" in
    same*) echo same ;;
    *within*) echo "$d" | sed -n 's/.*within \([0-9-]*\),\([0-9-]*\) \([0-9]*\)x\([0-9]*\).*/\1 \2 \3 \4/p' ;;
    *) echo "?$d" ;;
  esac
}
# inside "X Y W H" BX BY BW BH: the first box lies within the second.
inside() {
  set -- $*
  [ "$1" -ge "$5" ] && [ "$2" -ge "$6" ] && [ $(($1 + $3)) -le $(($5 + $7)) ] && [ $(($2 + $4)) -le $(($6 + $8)) ]
}

for x in vkeyboard:virtual-keyboard-unstable-v1; do
  n=${x%%:*}; f=${x#*:}
  wayland-scanner client-header "$root/abyss/tests/$f.xml" "$work/$n-proto.h"
  wayland-scanner private-code  "$root/abyss/tests/$f.xml" "$work/$n-proto.c"
done
protos=$(pkg-config --variable=pkgdatadir wayland-protocols)
wayland-scanner client-header "$protos/staging/ext-session-lock/ext-session-lock-v1.xml" "$work/ext-session-lock-proto.h"
wayland-scanner private-code  "$protos/staging/ext-session-lock/ext-session-lock-v1.xml" "$work/ext-session-lock-proto.c"
cc -I"$work" "$root/abyss/tests/vkeyboard.c" "$work/vkeyboard-proto.c" $(pkg-config --cflags --libs wayland-client xkbcommon) -o "$work/vkeyboard" || fail "vkeyboard"
cc -I"$work" -I"$root/de/cwayland/include" "$root/abyss/tests/lockclient.c" "$root/de/cabyssprotocols/xdg-shell-protocol.c" \
   "$work/ext-session-lock-proto.c" $(pkg-config --cflags --libs wayland-client) -o "$work/lockclient" || fail "lockclient"

pw="sesame-$$"
printf '%s\n' "$pw" > "$work/pw"
"$stub" --socket "$work/auth.sock" --password-file "$work/pw" 2> "$work/stub.log" & st=$!
await "$work/stub.log" 'answering at' "the stand-in authenticator never started"

# start_undertow EXTRA-ARGS…: a fresh compositor, its socket exported.
start_undertow() {
  env -u WAYLAND_DISPLAY "$undertow" run --hz 60 --frames 0 --width 800 --height 600 \
      --config-dir "$work" "$@" > "$work/ut.out" 2> "$work/ut.err" &
  ut_pid=$!
  i=0; wd=""
  while [ $i -lt 60 ]; do
    wd=$(grep -m1 '^WAYLAND_DISPLAY=' "$work/ut.out" 2>/dev/null | cut -d= -f2-) || wd=""
    [ -n "$wd" ] && break; sleep 0.1; i=$((i + 1))
  done
  [ -n "$wd" ] || fail "undertow never announced a socket"
  export WAYLAND_DISPLAY="$wd"
}
# start_lock SOCKET: the lock screen, asking SOCKET.
start_lock() {
  : > "$work/lock.err"
  env ABYSS_LOGIN_SOCKET="$1" ABYSS_CONFIG_DIR="$work/cfg" AQUA_SCENE=lock "$aqua" > "$work/lock.out" 2> "$work/lock.err" &
  lk=$!
  await "$work/lock.err" '^LockScreen: locked' "the lock screen never locked the session"
  sleep 0.4
}

start_undertow
mkfifo "$work/vk" "$work/a"
"$work/vkeyboard" < "$work/vk" > "$work/vk.log" 2>&1 & vk=$!; exec 4>"$work/vk"
await "$work/vk.log" ready "vkeyboard never bound"
"$work/lockclient" window ff336699 org.abyssbsd.lockwindow-a < "$work/a" > "$work/a.log" 2>&1 & wa=$!; exec 5>"$work/a"
await "$work/a.log" ready "the window never started"
sleep 0.6; shot desk
[ "$(has desk 51 102 153)" -gt 1000 ] || fail "before locking, the window is not on screen"

# The panel: 320x250, centred on 800x600 (LockScreen.panelRect). The field
# is 40 in from each side, 132 down, 24 tall; the message line is centred at
# 180 down — a 24-point band around it.
px=240; py=175
field="$((px + 40 - 4)) $((py + 132 - 4)) 248 32"
note="$((px + 2)) $((py + 166)) 316 28"
panelband="$((px - 20)) $((py - 2)) 360 254"

# ------------------------------------------------------------ 1. locked
start_lock "$work/auth.sock"
shot locked
[ "$(has locked 51 102 153)" = 0 ] || fail "locked, the window's blue is on screen"
[ "$(has locked 23 25 33)" -lt 1000 ] || fail "locked, the screen is the bare lock colour — the lock screen did not draw"
echo "ok: 1. locked: no pixel of the window, and the lock screen is drawn"

# ------------------------------------------------------------ 2. typing
printf 't abc\n' >&4; sleep 0.4; shot typed
b=$(diffbox locked typed)
[ "$b" != same ] || fail "typing changed nothing on screen — the lock screen drew one frame and no more"
inside "$b" $field || fail "typing changed more than the field: $b"
printf 't d\n' >&4; sleep 0.3; shot typed2
b=$(diffbox typed typed2)
[ "$b" != same ] && inside "$b" $field || fail "a second key did not redraw the field ($b)"
printf 'k 1\n' >&4; sleep 0.3; shot cleared            # Escape empties it
[ "$(diffbox locked cleared)" = same ] || fail "Escape did not empty the field ($(diffbox locked cleared))"
echo "ok: 2. typing changes the field and nothing else, each key again; Escape empties it"

# ------------------------------------------------------------ 3. refused, with a shake
asked=$(count 'loginwindow: uid' "$work/stub.log")
printf 't wrong-1\nk 28\n' >&4
moved=0; n=0
while [ $n -lt 8 ]; do
  shot shake-$n
  b=$(diffbox locked shake-$n)
  [ "$b" != same ] && ! inside "$b" $note && moved=1
  n=$((n + 1)); sleep 0.05
done
await "$work/lock.err" 'refused — shake' "a wrong password was not refused"
[ "$(count 'loginwindow: uid' "$work/stub.log")" = $((asked + 1)) ] || fail "the wrong password was not asked exactly once"
[ $moved = 1 ] || fail "the panel never moved — no shake"
sleep 0.6; shot refused
b=$(diffbox locked refused)
[ "$b" != same ] && inside "$b" $note || fail "after a refusal, more than the message line changed (or nothing did): $b"
echo "ok: 3. a wrong password is refused: the panel shook, the field is empty, only the message changed"

# ------------------------------------------------------------ 4. wait, then unlock
printf 't wrong-2\nk 28\n' >&4; await "$work/lock.err" 'refused — shake' "the second wrong password was not refused"
i=0; while [ "$(count 'refused — shake' "$work/lock.err")" -lt 2 ] && [ $i -lt 60 ]; do sleep 0.05; i=$((i + 1)); done
sleep 0.3
printf 't wrong-3\nk 28\n' >&4; await "$work/stub.log" 'refused.*waits' "the third failure did not start a wait"
sleep 0.3
printf 't %s\nk 28\n' "$pw" >&4
await "$work/lock.err" 'wait [0-9]* ms' "the lock screen was not told to wait"
tries=$(count 'asking the authenticator' "$work/lock.err")
printf 't %s\nk 28\n' "$pw" >&4
await "$work/lock.err" 'the wait is over' "the wait never ended"
# Typing takes a while, so not a count after a sleep: once the wait is over,
# the authenticator must have refused unasked exactly once — the try that was
# told to wait. Anything sent through the closed field is a second.
[ "$(count 'asked again too soon' "$work/stub.log")" = 1 ] \
  || fail "during the wait, a password was sent anyway ($(count 'asked again too soon' "$work/stub.log") refused unasked)"
[ "$(count 'asking the authenticator' "$work/lock.err")" = "$tries" ] || fail "during the wait, the lock screen asked"
sleep 0.2
printf 't %s\nk 28\n' "$pw" >&4
await "$work/lock.err" 'accepted — unlocking' "the right password, after the wait, did not unlock"
i=0; while kill -0 "$lk" 2>/dev/null && [ $i -lt 40 ]; do sleep 0.05; i=$((i + 1)); done
set +e; wait "$lk"; rc=$?; set -e; lk=""
[ "$rc" = 0 ] || fail "the lock screen exited $rc after unlocking"
await "$work/ut.out" '^session-lock unlocked ' "undertow does not say it is unlocked"
sleep 0.3; shot back
[ "$(has back 51 102 153)" -gt 1000 ] || fail "unlocked, the window is not back"
k=$(count '^key ' "$work/a.log"); printf 'k 30\n' >&4; sleep 0.3
[ "$(count '^key ' "$work/a.log")" -gt "$k" ] || fail "unlocked, the keys did not go back to the window"
[ "$(count '^key ' "$work/a.log")" = 1 ] || fail "the window was given keys typed into the lock screen ($(count '^key ' "$work/a.log"))"
echo "ok: 4. after the free typos a wait: the field closed and the password typed then was never sent; after it, unlocked (exit 0), and the window has the keys"

# ------------------------------------------------------------ 5. never written
for f in lock.err lock.out stub.log ut.out ut.err; do
  for p in "$pw" wrong-1 wrong-2 wrong-3 abcd; do
    grep -qF -- "$p" "$work/$f" && fail "$f contains a typed password ($p)"
  done
done
echo "ok: 5. no typed password in the lock screen's, the authenticator's or undertow's output"

# ------------------------------------------------------------ 6. nobody to ask
start_lock "$work/nobody.sock"
printf 't %s\nk 28\n' "$pw" >&4
await "$work/lock.err" 'could not ask' "with no authenticator, the lock screen did not say it could not ask"
sleep 0.3
grep -q '^session-lock locked ' "$work/ut.out" && [ "$(grep '^session-lock' "$work/ut.out" | tail -1 | cut -d' ' -f2)" = locked ] \
  || fail "with no authenticator to ask, the session did not stay locked"
shot nobody
[ "$(has nobody 51 102 153)" = 0 ] || fail "with no authenticator, the window showed"
kill "$lk" 2>/dev/null; wait "$lk" 2>/dev/null || true; lk=""
echo "ok: 6. with no authenticator to ask, it says so and the session stays locked"

# ------------------------------------------------------------ 7. two displays
exec 5>&-; kill "$wa" "$vk" "$ut_pid" 2>/dev/null || true; wait "$wa" "$vk" "$ut_pid" 2>/dev/null || true
wa=""; vk=""
start_undertow --output 640x480
rm -f "$work/a"; mkfifo "$work/a"
"$work/lockclient" window ff336699 org.abyssbsd.lockwindow-a < "$work/a" > "$work/a.log" 2>&1 & wa=$!; exec 5>"$work/a"
await "$work/a.log" ready "the window never started (two displays)"
start_lock "$work/auth.sock"
grep -q 'locking for .* (2 display(s))' "$work/lock.err" || fail "the lock screen did not cover two displays: $(grep 'locking for' "$work/lock.err")"
shot two-0 0; shot two-1 1
for d in two-0 two-1; do
  [ "$(has $d 51 102 153)" = 0 ] || fail "$d shows the window"
  [ "$(has $d 23 25 33)" -lt 1000 ] || fail "$d is the bare lock colour — no lock surface drawn on it"
done
echo "ok: 7. two displays: both covered by the lock screen, neither shows the window"

echo "all green (the lock screen asks the authenticator, shakes, waits, unlocks only on its yes, and fails closed)."
