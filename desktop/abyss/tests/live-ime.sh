#!/bin/sh
# AbyssBSD Swift DE — an input method, through undertow (BACKLOG U.5).
#
# text-input-v3 (the application's field) and input-method-v2 (the input
# method), relayed by undertow. The application is not ours — zenity's GTK
# entry (GTK 4 on Fedora; GTK 3, with its wayland input module, on FreeBSD) —
# and the input method is `imetest`, standing where fcitx5 or ibus would.
# Claims:
#
#   1. focusing the entry enters its text input and ACTIVATES the input method,
#      which is told the field's surrounding text;
#   2. a preedit, then a commit of 日本語, reach the field: zenity prints 日本語;
#   3. while the input method holds the keyboard, a key goes to IT and not to
#      the application; released, keys go to the application again;
#   4. when the field goes, the input method is deactivated.
#
# Usage: abyss/tests/live-ime.sh
set -eu
root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"
. "$root/abyss/common.sh"
abyss_ensure_runtime_dir

undertow="$root/.build/debug/undertow"
[ -x "$undertow" ] || swift build
command -v wayland-scanner >/dev/null 2>&1 || { echo "note: no wayland-scanner, skipping"; exit 0; }
command -v zenity >/dev/null 2>&1 || { echo "FAIL: no zenity — the test's text-input client (dnf/pkg install zenity)"; exit 1; }

work=$(mktemp -d /tmp/abyss-ime.XXXXXX)
cleanup() {
  exec 7>&- 8>&- 2>/dev/null || true
  for p in ${zp:-} ${ip:-} ${vp:-} ${ut_pid:-}; do kill "$p" 2>/dev/null || true; done
  rm -rf "$work" 2>/dev/null || true
}
trap cleanup EXIT INT TERM HUP
# A write to a helper that has died must fail loudly, not kill this shell with
# SIGPIPE and no message — which is what a crashed undertow looked like.
trap '' PIPE
alive() { kill -0 "$ut_pid" 2>/dev/null || fail "undertow died ($1): $(grep -m1 -E 'Assertion|Fatal|abort' "$work/ut.err" || tail -2 "$work/ut.err")"; }
fail() {
  echo "FAIL: $1"
  sed 's/^/  ime| /' "$work/ime.log" | tail -8
  grep -hE 'text-input|input-method' "$work/ut.err" 2>/dev/null | sed 's/^/  undertow| /' | tail -6
  tail -4 "$work/ut.log" 2>/dev/null | sed 's/^/  undertow stdout| /'
  exit 1
}
ime_mark() { grep -c -- "$1" "$work/ime.log" 2>/dev/null || true; }
ime_await() {  # ime_await PATTERN BEFORE WHY
  i=0
  while [ $i -lt 100 ]; do
    [ "$(ime_mark "$1")" -gt "$2" ] && return 0
    sleep 0.05; i=$((i + 1))
  done
  fail "$3 (no new '$1' from the input method)"
}

for t in vkeyboard:virtual-keyboard-unstable-v1 imetest:input-method-unstable-v2; do
  n=${t%%:*}; x=${t#*:}
  wayland-scanner client-header "$root/abyss/tests/$x.xml" "$work/$n-proto.h"
  wayland-scanner private-code  "$root/abyss/tests/$x.xml" "$work/$n-proto.c"
done
cc -I"$work" "$root/abyss/tests/vkeyboard.c" "$work/vkeyboard-proto.c" \
   $(pkg-config --cflags --libs wayland-client xkbcommon) -o "$work/vkeyboard" || fail "could not build vkeyboard"
cc -I"$work" "$root/abyss/tests/imetest.c" "$work/imetest-proto.c" \
   $(pkg-config --cflags --libs wayland-client) -o "$work/imetest" || fail "could not build imetest"

wd="abyss-ime-$$"
env -u WAYLAND_DISPLAY "$undertow" run --hz 60 --frames 0 --width 800 --height 600 --socket "$wd" \
    > "$work/ut.log" 2> "$work/ut.err" &
ut_pid=$!
i=0; while [ ! -S "$XDG_RUNTIME_DIR/$wd" ] && [ $i -lt 100 ]; do i=$((i+1)); sleep 0.05; done
[ -S "$XDG_RUNTIME_DIR/$wd" ] || fail "undertow never bound $wd"
export WAYLAND_DISPLAY="$wd"

# A keyboard first: headless undertow has none until one attaches, and a GTK
# app makes its text input only for a seat with a keyboard.
mkfifo "$work/vk.in" "$work/ime.in"
"$work/vkeyboard" < "$work/vk.in" > "$work/vk.log" 2>&1 &
vp=$!; exec 8>"$work/vk.in"
"$work/imetest" < "$work/ime.in" > "$work/ime.log" 2>&1 &
ip=$!; exec 7>"$work/ime.in"
i=0; while { ! grep -q ready "$work/vk.log" || ! grep -q ready "$work/ime.log"; } 2>/dev/null && [ $i -lt 60 ]; do
  sleep 0.1; i=$((i + 1)); done
grep -q ready "$work/ime.log" || fail "the input method never bound"

# GTK 3 needs its wayland input module named; GTK 4 speaks text-input natively.
GTK_IM_MODULE=wayland zenity --entry --text=Name > "$work/zen.out" 2> "$work/zen.err" &
zp=$!

# ------------------------------------------------------ 1. activated
ime_await 'done active=1' 0 "focusing the entry did not activate the input method"
alive "activating the input method"
grep -q '^activate$' "$work/ime.log" || fail "no activate before done"
grep -q '^surrounding ' "$work/ime.log" || fail "the input method was not told the surrounding text"
echo "ok: 1. the entry's focus entered its text input and activated the input method (surrounding text told)"

# ------------------------------------------------------ 3. the grab (before the commit: zenity exits on Enter)
b=$(ime_mark '^key 30 1$')
printf 'g\n' >&7; sleep 0.4
printf 't a\n' >&8
ime_await '^key 30 1$' "$b" "a key typed while the input method held the keyboard did not reach it"
printf 'u\n' >&7; sleep 0.4
alive "releasing the keyboard grab"
printf 't b\n' >&8; sleep 0.4
[ "$(ime_mark '^key 48 ')" = 0 ] || fail "a key typed after the release still went to the input method"
echo "ok: 3. with the keyboard grabbed, 'a' went to the input method; released, 'b' went to the application"

# ------------------------------------------------------ 2. preedit and commit
b=$(ime_mark '^surrounding ')
printf 'p にほんご\n' >&7; sleep 0.3
printf 'c 日本語\n' >&7
ime_await '^surrounding ' "$b" "the field's text did not change after the commit"
alive "relaying the commit"
printf 'k 28\n' >&8                                    # Return: zenity prints the entry and exits
i=0; while kill -0 "$zp" 2>/dev/null && [ $i -lt 60 ]; do sleep 0.1; i=$((i + 1)); done
got=$(cat "$work/zen.out")
[ "$got" = "b日本語" ] || fail "zenity's entry held '$got', not 'b日本語' (the b typed after the release, then the commit)"
echo "ok: 2. a preedit then a commit of 日本語 reached the field: zenity printed '$got'"

# ------------------------------------------------------ 4. deactivated
ime_await 'done active=0' 0 "the input method was not deactivated when the field went"
# undertow reports after its warm-up (240 frames, 4 s, in an unbounded run):
# wait for the line rather than read it before it can have been written.
i=0; while ! grep -q '^text-input enters=1 activations=[1-9][0-9]* commits-relayed=[1-9][0-9]* keys-grabbed=[1-9]' "$work/ut.log" \
  && [ $i -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
grep -q '^text-input enters=1 activations=[1-9][0-9]* commits-relayed=[1-9][0-9]* keys-grabbed=[1-9]' "$work/ut.log" \
  || fail "undertow's counts: $(grep '^text-input' "$work/ut.log" | tail -1)"
echo "ok: 4. the field gone, the input method was deactivated ($(grep '^text-input' "$work/ut.log" | tail -1))"

echo "all green (an input method composes into another toolkit's field, through undertow)."
