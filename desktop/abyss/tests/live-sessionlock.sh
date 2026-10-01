#!/bin/sh
# AbyssBSD Swift DE — the session lock, in undertow (PHASE16 P16.2a).
#
# ext-session-lock-v1 is the boundary between a locked desktop and whoever is
# standing at it (PHASE16 §6.6), so this test pushes on it from every side.
# `lockclient` plays both parts: a lock client (green) and ordinary windows
# that log any input reaching them (A blue, B red). Asserted in screencopy
# captures (`abyssgrab`) and in what each client heard:
#
#   1. locked, no pixel of the desktop is shown — only the lock's green — and
#      the lock surface keeps a frame clock (a lock screen draws more than once);
#   2. a click and a key reach the lock client, and not the window under them;
#   3. a window that maps while locked is not drawn, and gets no keys;
#   4. a keyboard-grabbing popup does not keep the keys from the lock: one held
#      when the session locks (a menu open when an idle lock comes) is ended —
#      a grab makes wlroots ignore the lock's change of focus, so left alone
#      it would hand the window the password — and one tried while locked
#      gets nothing and is not drawn;
#   5. a second lock client is refused (`finished`) while the first holds it;
#   6. the lock client dies without unlocking: the session STAYS locked —
#      the plain lock colour, no desktop, no input behind it;
#   7. a new lock client takes over the abandoned lock, and unlocking shows
#      the desktop again and gives the keys back to the window that had them;
#   7b. every window closing while locked — the focused one last — leaves the
#      keyboard with the lock screen (P16.4b: it did not);
#   8. with two displays and a lock surface on only one, the other shows the
#      lock's plain colour and nothing of the desktop — what a display plugged
#      in while locked has until the lock client covers it.
#
# Usage: abyss/tests/live-sessionlock.sh
set -eu
root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"
. "$root/abyss/common.sh"
abyss_ensure_runtime_dir

undertow="$root/.build/debug/undertow"
grab="$root/.build/debug/abyssgrab"
[ -x "$undertow" ] && [ -x "$grab" ] || swift build
command -v wayland-scanner >/dev/null 2>&1 || { echo "note: no wayland-scanner, skipping"; exit 0; }

work=$(mktemp -d /tmp/abyss-lock.XXXXXX)
cleanup() {
  exec 3>&- 4>&- 5>&- 6>&- 7>&- 8>&- 9>&- 2>/dev/null || true
  for p in ${l3:-} ${l2:-} ${l1:-} ${wb:-} ${wa:-} ${vk:-} ${vp:-} ${ut_pid:-}; do kill "$p" 2>/dev/null || true; done
  rm -rf "$work" 2>/dev/null || true
}
trap cleanup EXIT INT TERM HUP
trap '' PIPE
fail() { echo "FAIL: $1"
         grep -E '^session-lock' "$work/ut.out" 2>/dev/null | tail -3 | sed 's/^/  undertow| /'
         grep -m1 -E 'Assertion|Fatal' "$work/ut.err" 2>/dev/null | sed 's/^/  undertow| /' || true
         exit 1; }
await() {  # await FILE PATTERN WHY
  i=0; while ! grep -q -- "$2" "$1" 2>/dev/null && [ $i -lt 80 ]; do i=$((i + 1)); sleep 0.05; done
  grep -q -- "$2" "$1" 2>/dev/null || fail "$3"
}
# 0, not nothing, when the file is not there yet: an empty count made the
# wait's test an error, which ended the wait at once (HANDOFF §2.106).
count() { n=$(grep -c -- "$1" "$2" 2>/dev/null) || true; echo "${n:-0}"; }
alive() { kill -0 "$ut_pid" 2>/dev/null || fail "undertow died ($1)"; }
# shot NAME: a screencopy of the output, as P6 PPM.
shot() { "$grab" "$work/$1.ppm" > "$work/grab.log" 2>&1 || fail "abyssgrab: $(cat "$work/grab.log")"; }
# common NAME: the capture's most common colour, as "R G B".
common() {
  hdr=$(head -3 "$work/$1.ppm" | wc -c | tr -d ' ')
  tail -c +$((hdr + 1)) "$work/$1.ppm" | od -An -v -tu1 | tr -s ' \n' '\n\n' | grep -v '^$' \
    | awk '{ v[NR % 3] = $1 } NR % 3 == 0 { c[v[1] " " v[2] " " v[0]]++ } END { for (k in c) if (c[k] > m) { m = c[k]; b = k } print b }'
}
# has NAME R G B: how many pixels of exactly that colour the capture holds.
has() {
  hdr=$(head -3 "$work/$1.ppm" | wc -c | tr -d ' ')
  tail -c +$((hdr + 1)) "$work/$1.ppm" | od -An -v -tu1 | tr -s ' \n' '\n\n' | grep -v '^$' \
    | awk -v r="$2" -v g="$3" -v b="$4" '{ v[NR % 3] = $1 } NR % 3 == 0 && v[1] == r && v[2] == g && v[0] == b { n++ } END { print n + 0 }'
}

protos=$(pkg-config --variable=pkgdatadir wayland-protocols)
wayland-scanner client-header "$protos/staging/ext-session-lock/ext-session-lock-v1.xml" "$work/ext-session-lock-proto.h"
wayland-scanner private-code  "$protos/staging/ext-session-lock/ext-session-lock-v1.xml" "$work/ext-session-lock-proto.c"
for x in vpointer:wlr-virtual-pointer-unstable-v1 vkeyboard:virtual-keyboard-unstable-v1; do
  n=${x%%:*}; f=${x#*:}
  wayland-scanner client-header "$root/abyss/tests/$f.xml" "$work/$n-proto.h"
  wayland-scanner private-code  "$root/abyss/tests/$f.xml" "$work/$n-proto.c"
done
cc -I"$work" "$root/abyss/tests/vpointer.c" "$work/vpointer-proto.c" $(pkg-config --cflags --libs wayland-client) -o "$work/vpointer" || fail "vpointer"
cc -I"$work" "$root/abyss/tests/vkeyboard.c" "$work/vkeyboard-proto.c" $(pkg-config --cflags --libs wayland-client xkbcommon) -o "$work/vkeyboard" || fail "vkeyboard"
cc -I"$work" -I"$root/de/cwayland/include" "$root/abyss/tests/lockclient.c" "$root/de/cabyssprotocols/xdg-shell-protocol.c" \
   "$work/ext-session-lock-proto.c" $(pkg-config --cflags --libs wayland-client) -o "$work/lockclient" || fail "could not build lockclient"

env -u WAYLAND_DISPLAY "$undertow" run --hz 60 --frames 0 --width 800 --height 600 \
    --config-dir "$work" > "$work/ut.out" 2> "$work/ut.err" &
ut_pid=$!
i=0; wd=""
while [ $i -lt 60 ]; do
  wd=$(grep -m1 '^WAYLAND_DISPLAY=' "$work/ut.out" 2>/dev/null | cut -d= -f2-) || wd=""
  [ -n "$wd" ] && break; sleep 0.1; i=$((i + 1))
done
[ -n "$wd" ] || fail "undertow never announced a socket"
export WAYLAND_DISPLAY="$wd"

mkfifo "$work/vp" "$work/vk" "$work/a" "$work/b" "$work/l1" "$work/l2" "$work/l3"
"$work/vpointer" 800 600 < "$work/vp" > "$work/vp.log" 2>&1 & vp=$!; exec 3>"$work/vp"
"$work/vkeyboard" < "$work/vk" > "$work/vk.log" 2>&1 & vk=$!; exec 4>"$work/vk"
await "$work/vk.log" ready "vkeyboard never bound"
"$work/lockclient" window ff336699 org.abyssbsd.lockwindow-a < "$work/a" > "$work/a.log" 2>&1 & wa=$!; exec 5>"$work/a"
await "$work/a.log" ready "window A never started"
# Windows are reported after undertow's 4 s warm-up (§2.83).
i=0; while ! grep -q '^window org.abyssbsd.lockwindow-a' "$work/ut.out" && [ $i -lt 160 ]; do sleep 0.05; i=$((i + 1)); done
pos=$(grep -E '^window org.abyssbsd.lockwindow-a[^ ]* -?[0-9]+,-?[0-9]+ ' "$work/ut.out" | tail -1 | cut -d' ' -f3)
ax=$(( ${pos%,*} + 150 )); ay=$(( ${pos#*,} + 100 ))
printf 'm %s %s\np\nr\n' "$ax" "$ay" >&3; sleep 0.3      # A focused and under the pointer
k=$(count '^key ' "$work/a.log"); printf 'k 30\n' >&4; sleep 0.3
[ "$(count '^key ' "$work/a.log")" -gt "$k" ] || fail "before locking, a key did not reach window A"
shot before
[ "$(has before 51 102 153)" -gt 1000 ] || fail "before locking, window A's blue is not on screen"
# A menu is open when the lock comes: a popup holding the keyboard grab.
printf 'p\n' >&5
await "$work/a.log" 'popup grabbed' "window A did not open its grabbing popup"
sleep 0.3; k=$(count '^key ' "$work/a.log"); printf 'k 30\n' >&4; sleep 0.3
[ "$(count '^key ' "$work/a.log")" -gt "$k" ] || fail "before locking, a key did not reach window A's popup"

# ------------------------------------------------------ 1. locked, nothing shown
"$work/lockclient" lock ff2a5a2a < "$work/l1" > "$work/l1.log" 2>&1 & l1=$!; exec 6>"$work/l1"
await "$work/l1.log" ready "lock client 1 never started"
printf 'l\n' >&6
await "$work/l1.log" '^locked$' "the lock client was never told it had locked the session"
await "$work/ut.out" '^session-lock locked ' "undertow does not say it is locked"
sleep 0.3; shot locked
[ "$(has locked 51 102 153)" = 0 ] || fail "locked, window A's blue is still on screen ($(has locked 51 102 153) pixels)"
[ "$(has locked 255 0 255)" = 0 ] || fail "locked, window A's popup is still on screen"
[ "$(has locked 42 90 42)" -gt 400000 ] || fail "locked, the lock's green does not cover the output ($(has locked 42 90 42) pixels)"
printf 'f\n' >&6
await "$work/l1.log" '^frame$' "the lock surface's frame callback never came — a lock screen could draw only once"
printf 'f\n' >&6; sleep 0.2
[ "$(count '^frame$' "$work/l1.log")" -ge 2 ] || fail "the lock surface had one frame callback and not a second"
echo "ok: 1. locked: no pixel of the desktop, the lock's green over the output, and the lock keeps a frame clock"

# ------------------------------------------------------ 2. input to the lock only
ka=$(count '^key \|^button' "$work/a.log"); kl=$(count '^key \|^button' "$work/l1.log")
printf 'm %s %s\np\nr\n' "$((ax + 1))" "$ay" >&3; sleep 0.2; printf 'k 31\n' >&4; sleep 0.3
[ "$(count '^key \|^button' "$work/a.log")" = "$ka" ] || fail "a click or key reached window A through the lock"
[ "$(count '^key \|^button' "$work/l1.log")" -ge $((kl + 2)) ] || fail "the click and key did not reach the lock client"
echo "ok: 2. a click and a key on window A's place reached the lock client, and not A"

# ------------------------------------------------------ 3. a window mapped while locked
"$work/lockclient" window ffcc2222 org.abyssbsd.lockwindow-b < "$work/b" > "$work/b.log" 2>&1 & wb=$!; exec 7>"$work/b"
await "$work/b.log" ready "window B never started"
sleep 0.5; printf 'k 32\n' >&4; sleep 0.3; shot locked-b
[ "$(has locked-b 204 34 34)" = 0 ] || fail "a window that mapped while locked is drawn"
[ "$(count '^key ' "$work/b.log")" = 0 ] || fail "a window that mapped while locked got a key"
echo "ok: 3. a window that mapped while locked is not drawn and gets no keys"

# ------------------------------------------------------ 4. the grab attack
# The grab held at locking was ended (2 already showed no key reached A).
await "$work/a.log" 'popup done' "the popup grab held when the session locked was never ended"
# And one tried while locked, with the last serial A was given.
n=$(count 'popup grabbed' "$work/a.log"); printf 'p\n' >&5
i=0; while [ "$(count 'popup grabbed' "$work/a.log")" = "$n" ] && [ $i -lt 40 ]; do sleep 0.05; i=$((i + 1)); done
ka=$(count '^key ' "$work/a.log"); kl=$(count '^key ' "$work/l1.log")
sleep 0.3; printf 'k 33\n' >&4; sleep 0.3
[ "$(count '^key ' "$work/a.log")" = "$ka" ] || fail "a popup's keyboard grab took a key typed into the lock"
[ "$(count '^key ' "$work/l1.log")" -gt "$kl" ] || fail "with a popup grab attempted, the lock client lost its key"
shot grab
[ "$(has grab 255 0 255)" = 0 ] || fail "the grabbing popup is drawn over the lock"
echo "ok: 4. the popup grab held when the session locked was ended, and one tried while locked got no key and is not drawn ($(grep '^session-lock' "$work/ut.out" | tail -1 | grep -o 'grabs-broken=[0-9]*'))"

# ------------------------------------------------------ 5. one lock at a time
"$work/lockclient" lock ff802020 < "$work/l2" > "$work/l2.log" 2>&1 & l2=$!; exec 8>"$work/l2"
await "$work/l2.log" ready "lock client 2 never started"
printf 'l\n' >&8
await "$work/l2.log" '^finished$' "a second lock client was not refused while the first held the lock"
grep -q '^locked$' "$work/l2.log" && fail "the second lock client was told it had locked"
echo "ok: 5. a second lock client was refused (finished) while the first held the lock"

# ------------------------------------------------------ 6. abandoned
kill "$l1"; wait "$l1" 2>/dev/null || true; l1=""
await "$work/ut.out" '^session-lock abandoned ' "undertow does not say the lock was abandoned"
alive "the lock client died"
sleep 0.3; ka=$(count '^key \|^button' "$work/a.log")
printf 'm %s %s\np\nr\n' "$ax" "$((ay + 1))" >&3; sleep 0.2; printf 'k 34\n' >&4; sleep 0.3
shot abandoned
[ "$(has abandoned 51 102 153)" = 0 ] || fail "the lock client died and the desktop showed through"
[ "$(count '^key \|^button' "$work/a.log")" = "$ka" ] || fail "the lock client died and input reached window A"
echo "ok: 6. the lock client died without unlocking: still locked — no desktop, no input behind it"

# ------------------------------------------------------ 7. taken over, then unlocked
"$work/lockclient" lock ff2a5a2a < "$work/l3" > "$work/l3.log" 2>&1 & l3=$!; exec 9>"$work/l3"
await "$work/l3.log" ready "lock client 3 never started"
printf 'l\n' >&9
await "$work/l3.log" '^locked$' "a new lock client could not take over the abandoned lock"
printf 'u\n' >&9
await "$work/l3.log" '^unlocked$' "the lock client could not unlock"
await "$work/ut.out" '^session-lock unlocked ' "undertow does not say it is unlocked"
sleep 0.3; shot unlocked
[ "$(has unlocked 51 102 153)" -gt 1000 ] || fail "unlocked, window A is not on screen again"
ka=$(count '^key ' "$work/a.log"); printf 'k 35\n' >&4; sleep 0.3
[ "$(count '^key ' "$work/a.log")" -gt "$ka" ] || fail "unlocked, the keys did not go back to window A"
echo "ok: 7. a new lock client took the abandoned lock over and unlocked: the desktop is back, and A has the keys"
echo "ok: undertow: $(grep '^session-lock' "$work/ut.out" | tail -1)"

# ------------------------------------------------------ 7b. windows close behind the lock
mkfifo "$work/l5"
"$work/lockclient" lock ff2a5a2a < "$work/l5" > "$work/l5.log" 2>&1 & l2=$!; exec 8>"$work/l5"
await "$work/l5.log" ready "lock client 5 never started"
printf 'l\n' >&8
await "$work/l5.log" '^locked$' "lock client 5 could not lock"
sleep 0.3
printf 'q\n' >&7; wait "$wb" 2>/dev/null || true; wb=""
printf 'q\n' >&5; wait "$wa" 2>/dev/null || true; wa=""
sleep 0.4
k=$(count '^key ' "$work/l5.log"); printf 'k 36\n' >&4; sleep 0.3
[ "$(count '^key ' "$work/l5.log")" -gt "$k" ] \
  || fail "every window closed while locked, and the lock screen no longer had the keyboard"
printf 'u\n' >&8; await "$work/l5.log" '^unlocked$' "lock client 5 could not unlock"
echo "ok: 7b. every window closed behind the lock, and the keys still went to the lock screen"

# ------------------------------------------------------ 8. a display with no lock surface
for f in 3 4 5 6 7 8 9; do eval "exec $f>&-"; done
for p in $l3 $wb $wa $vk $vp $ut_pid; do kill "$p" 2>/dev/null || true; done
wait 2>/dev/null || true; l1=""; l2=""; l3=""; wa=""; wb=""; vk=""; vp=""
env -u WAYLAND_DISPLAY "$undertow" run --hz 60 --frames 0 --width 800 --height 600 \
    --output 640x480 --config-dir "$work" > "$work/ut.out" 2> "$work/ut.err" &
ut_pid=$!
i=0; wd=""
while [ $i -lt 60 ]; do
  wd=$(grep -m1 '^WAYLAND_DISPLAY=' "$work/ut.out" 2>/dev/null | cut -d= -f2-) || wd=""
  [ -n "$wd" ] && break; sleep 0.1; i=$((i + 1))
done
[ -n "$wd" ] || fail "the two-display undertow never announced a socket"
export WAYLAND_DISPLAY="$wd"
# A window on the main display, so there is more than a background to hide.
mkfifo "$work/a2"
"$work/lockclient" window ff336699 org.abyssbsd.lockwindow-a < "$work/a2" > "$work/a2.log" 2>&1 & wa=$!; exec 5>"$work/a2"
await "$work/a2.log" ready "the two-display window never started"
sleep 0.8
"$grab" "$work/two-before-0.ppm" --output 0 > "$work/grab.log" 2>&1 || fail "abyssgrab 0: $(cat "$work/grab.log")"
"$grab" "$work/two-before-1.ppm" --output 1 > "$work/grab.log" 2>&1 || fail "abyssgrab 1: $(cat "$work/grab.log")"
desk0=$(common two-before-0); desk1=$(common two-before-1)
mkfifo "$work/l4"
"$work/lockclient" lock ff2a5a2a last < "$work/l4" > "$work/l4.log" 2>&1 & l3=$!; exec 9>"$work/l4"
await "$work/l4.log" ready "the one-display lock client never started"
printf 'l\n' >&9
await "$work/l4.log" '^locked$' "the one-display lock client never locked"
sleep 0.3
"$grab" "$work/two-0.ppm" --output 0 > "$work/grab.log" 2>&1 || fail "abyssgrab 0: $(cat "$work/grab.log")"
"$grab" "$work/two-1.ppm" --output 1 > "$work/grab.log" 2>&1 || fail "abyssgrab 1: $(cat "$work/grab.log")"
g0=$(has two-0 42 90 42); g1=$(has two-1 42 90 42)
if [ "$g0" -gt "$g1" ]; then bare=two-1; desk=$desk1; else bare=two-0; desk=$desk0; fi
[ "$(has ${bare%%-*}-before-${bare#*-} 51 102 153)" -gt 1000 ] \
  || fail "the window is not on the display the lock leaves uncovered — the claim was not tried"
[ "$(has $bare 51 102 153)" = 0 ] || fail "locked, the window shows on the display with no lock surface"
[ "$(has $bare $desk)" = 0 ] || fail "locked, the display with no lock surface still shows the desktop ($desk)"
[ "$(has $bare 42 90 42)" = 0 ] || fail "the lock client covered both displays — the claim was not tried"
# The lock's plain colour everywhere but the pointer, which a lock keeps
# (undertow draws it into the output; at most 32x32 of it).
c=$(common $bare)
px=$(( $(head -2 "$work/$bare.ppm" | tail -1 | tr ' ' '*') ))
[ "$(has $bare $c)" -ge $((px - 1024)) ] || fail "the display with no lock surface is not the lock's plain colour ($(has $bare $c) of $px pixels)"
echo "ok: 8. two displays, a lock surface on one: the other is the lock's plain colour ($c), not the desktop ($desk)"

echo "all green (the session lock hides the desktop, keeps input from it, and does not open when its client dies)."
