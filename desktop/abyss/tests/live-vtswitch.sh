#!/bin/sh
# AbyssBSD Swift DE — a VT switched away and back (PHASE16, found on metal).
#
# wlroots 0.20 destroys every DRM output when the session is paused — Ctrl-Alt-F2,
# or fast user switching — and announces them again when it resumes. undertow
# assumed its outputs lived for ever: the first Ctrl-Alt-F2 on the 12700KF
# aborted it in wlr_output_finish (HANDOFF §2.114). `--stand-in-vt` does the
# same to headless outputs: `away` destroys them all, `back` announces them
# again by the same names. Claims:
#
#   1. away: undertow lives; it says the output is gone, and the desktop
#      picture (a layer surface) is parked, not lost;
#   2. while away, clients are still served: a new window connects and maps;
#   3. back: the output is taken up again — the desktop picture on it, the
#      windows drawn, and a screencopy of the new output works;
#   4. again, twice: nothing accumulates (the same counts, the same picture);
#   5. locked when the VT goes, locked when it comes back: no pixel of the
#      desktop on the returned output, only the lock's colour.
#
# Usage: abyss/tests/live-vtswitch.sh
set -eu
root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"
. "$root/abyss/common.sh"
abyss_ensure_runtime_dir

undertow="$root/.build/debug/undertow"
grab="$root/.build/debug/abyssgrab"
aqua="$root/.build/debug/AquaDemo"
[ -x "$undertow" ] && [ -x "$grab" ] && [ -x "$aqua" ] || swift build
command -v wayland-scanner >/dev/null 2>&1 || { echo "note: no wayland-scanner, skipping"; exit 0; }

work=$(mktemp -d /tmp/abyss-vt.XXXXXX)
cleanup() {
  exec 3>&- 5>&- 6>&- 7>&- 2>/dev/null || true
  for p in ${lk:-} ${wb:-} ${wa:-} ${wall:-} ${ut_pid:-}; do kill "$p" 2>/dev/null || true; done
  rm -rf "$work" 2>/dev/null || true
}
trap cleanup EXIT INT TERM HUP
trap '' PIPE
fail() { echo "FAIL: $1"
         grep -E '^output|gone|back|stand-in' "$work/ut.out" "$work/ut.err" 2>/dev/null | tail -6 | sed 's/^/  undertow| /'
         grep -m1 -E 'Assertion|Fatal' "$work/ut.err" 2>/dev/null | sed 's/^/  undertow| /' || true
         exit 1; }
count() { n=$(grep -c -- "$1" "$2" 2>/dev/null) || true; echo "${n:-0}"; }
await() {  # await FILE PATTERN WHY [TIMES]
  i=0; while [ "$(count "$2" "$1")" -lt "${4:-1}" ] && [ $i -lt 100 ]; do i=$((i + 1)); sleep 0.05; done
  [ "$(count "$2" "$1")" -ge "${4:-1}" ] || fail "$3"
}
alive() { kill -0 "$ut_pid" 2>/dev/null || fail "undertow died ($1)"; }
shot() { "$grab" "$work/$1.ppm" > "$work/grab.log" 2>&1 || fail "abyssgrab ($1): $(cat "$work/grab.log")"; }
has() {  # has NAME R G B: pixels of exactly that colour in the capture
  hdr=$(head -3 "$work/$1.ppm" | wc -c | tr -d ' ')
  tail -c +$((hdr + 1)) "$work/$1.ppm" | od -An -v -tu1 | tr -s ' \n' '\n\n' | grep -v '^$' \
    | awk -v r="$2" -v g="$3" -v b="$4" '{ v[NR % 3] = $1 } NR % 3 == 0 && v[1] == r && v[2] == g && v[0] == b { n++ } END { print n + 0 }'
}

protos=$(pkg-config --variable=pkgdatadir wayland-protocols)
wayland-scanner client-header "$protos/staging/ext-session-lock/ext-session-lock-v1.xml" "$work/ext-session-lock-proto.h"
wayland-scanner private-code  "$protos/staging/ext-session-lock/ext-session-lock-v1.xml" "$work/ext-session-lock-proto.c"
cc -I"$work" -I"$root/de/cwayland/include" "$root/abyss/tests/lockclient.c" "$root/de/cabyssprotocols/xdg-shell-protocol.c" \
   "$work/ext-session-lock-proto.c" $(pkg-config --cflags --libs wayland-client) -o "$work/lockclient" || fail "could not build lockclient"

mkfifo "$work/vt" "$work/a" "$work/b" "$work/l"
env -u WAYLAND_DISPLAY "$undertow" run --hz 60 --frames 0 --width 800 --height 600 \
    --config-dir "$work" --stand-in-vt "$work/vt" > "$work/ut.out" 2> "$work/ut.err" &
ut_pid=$!
exec 3>"$work/vt"
await "$work/ut.out" '^WAYLAND_DISPLAY=' "undertow never announced a socket"
export WAYLAND_DISPLAY="$(grep -m1 '^WAYLAND_DISPLAY=' "$work/ut.out" | cut -d= -f2-)"

env ABYSS_CONFIG_DIR="$work/cfg" AQUA_SCENE=wallpaper "$aqua" > "$work/wall.log" 2>&1 & wall=$!
await "$work/wall.log" "Surface.LayerSurface: mapped .*abyss.wallpaper" "the desktop picture never mapped"
"$work/lockclient" window ff336699 org.abyssbsd.vt-a < "$work/a" > "$work/a.log" 2>&1 & wa=$!; exec 5>"$work/a"
await "$work/ut.out" '^window org.abyssbsd.vt-a ' "window A was never placed"
sleep 0.5; shot before
blue0=$(has before 51 102 153); bare0=$(has before 61 102 161)
[ "$blue0" -gt 1000 ] || fail "before: window A's blue is not on screen ($blue0 pixels)"

# ------------------------------------------------------------------ 1. away
printf 'away\n' >&3
await "$work/ut.out" '^output HEADLESS-1 gone' "undertow did not say the output was gone"
await "$work/ut.err" 'output HEADLESS-1 gone — 1 layer surface(s) wait for it' "the desktop picture was not parked"
sleep 0.5; alive "the VT went away"
kill -0 "$wall" 2>/dev/null || fail "the desktop picture's client died with the output"
echo "ok: 1. away: undertow lives, the output is gone, the desktop picture waits for it"

# ------------------------------------------------------- 2. served while away
"$work/lockclient" window ffcc2222 org.abyssbsd.vt-b < "$work/b" > "$work/b.log" 2>&1 & wb=$!; exec 6>"$work/b"
await "$work/b.log" ready "a window could not connect while the VT was away"
await "$work/ut.out" '^window org.abyssbsd.vt-b ' "a window that connected while away was never placed"
alive "a client connected while away"
echo "ok: 2. while away, a new window connected and was placed"

# ------------------------------------------------------------------ 3. back
printf 'back\n' >&3
await "$work/ut.out" '^output HEADLESS-1 back' "undertow did not take the output up again"
await "$work/ut.err" 'output HEADLESS-1 back — 1 layer surface(s) on it again' "the desktop picture did not go back on its output"
sleep 0.5; alive "the VT came back"
shot back1
[ "$(has back1 204 34 34)" -gt 1000 ] || fail "back: window B (mapped while away) is not drawn"
[ "$(has back1 51 102 153)" -gt 0 ] || fail "back: window A is not drawn"
bare1=$(has back1 61 102 161)
[ "$bare1" -le "$bare0" ] || fail "back: more bare background than before ($bare1 > $bare0) — the desktop picture is not on the output"
echo "ok: 3. back: the output taken up again, both windows and the desktop picture drawn, screencopy works"

# ------------------------------------------------------------- 4. and again
for n in 2 3; do
  printf 'away\n' >&3; await "$work/ut.out" '^output HEADLESS-1 gone' "away #$n: not said" "$n"
  printf 'back\n' >&3; await "$work/ut.out" '^output HEADLESS-1 back' "back #$n: not said" "$n"
done
sleep 0.5; alive "three switches"; shot back3
[ "$(has back3 204 34 34)" = "$(has back1 204 34 34)" ] && [ "$(has back3 61 102 161)" = "$bare1" ] \
  || fail "after three switches the picture differs from after one"
[ "$(count 'output HEADLESS-1 back — 1 layer surface' "$work/ut.err")" = 3 ] || fail "the desktop picture was not re-homed every time"
echo "ok: 4. three times over: the same picture, the desktop picture re-homed each time"

# -------------------------------------------------------- 5. locked across it
"$work/lockclient" lock ff2a5a2a < "$work/l" > "$work/l.log" 2>&1 & lk=$!; exec 7>"$work/l"
await "$work/l.log" ready "the lock client never started"
printf 'l\n' >&7
await "$work/l.log" '^locked$' "the session did not lock"
sleep 0.3
printf 'away\n' >&3; await "$work/ut.out" '^output HEADLESS-1 gone' "locked, away: not said" 4
printf 'back\n' >&3; await "$work/ut.out" '^output HEADLESS-1 back' "locked, back: not said" 4
sleep 0.5; alive "a switch while locked"
await "$work/ut.out" '^session-lock locked ' "undertow does not say it is still locked"
shot locked
for c in "51 102 153" "204 34 34"; do
  [ "$(has locked $c)" = 0 ] || fail "locked, after the VT came back a window shows ($c: $(has locked $c) pixels)"
done
[ "$(has locked 61 102 161)" = 0 ] || fail "locked, after the VT came back the desktop's background shows"
echo "ok: 5. locked when the VT went, locked when it came back: no pixel of the desktop"
echo "all green (a VT switched away and back: undertow keeps the session, and the lock)."
