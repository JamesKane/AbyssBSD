#!/bin/sh
# AbyssBSD Swift DE — Islands, in the compositor (PHASE13 P13.1).
#
# Workspaces per display: a window is on an island, a display shows one island,
# and a window on an island nobody is looking at is treated as a minimised one
# (not drawn, not hit, `suspended`). Driven by the keys of PHASE13 §6.4 through
# a virtual keyboard; asserted in screencopy captures, in what each client
# heard, and in undertow's own account (`islands …`, `window-island …`). Claims:
#
#   1. Ctrl-2: island 2 is shown — the windows of island 1 are not drawn, and an
#      Aqua window among them is told it is suspended;
#   2. a window opened there is on island 2, and has the keyboard;
#   3. Ctrl-1: island 1 again — its windows drawn, the Aqua one resumed, island
#      2's window not drawn, and the keys go to island 1's window;
#   4. Ctrl-Alt-2 sends the focused window to island 2 and you stay; with Shift
#      (Ctrl-Alt-Shift-3) you go with it;
#   5. Ctrl-← and Ctrl-→ step and wrap (§6.1: four islands);
#   6. a switch is per display: the other display keeps its island;
#   7. Cmd-Tab reaches a window on another island, and goes there (§6.3).
#
# Usage: abyss/tests/live-islands.sh
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

work=$(mktemp -d /tmp/abyss-isl.XXXXXX)
cleanup() {
  exec 3>&- 4>&- 5>&- 6>&- 2>/dev/null || true
  for p in ${aq:-} ${wb:-} ${wa:-} ${vk:-} ${vp:-} ${ut_pid:-}; do kill "$p" 2>/dev/null || true; done
  rm -rf "$work" 2>/dev/null || true
}
trap cleanup EXIT INT TERM HUP
trap '' PIPE
fail() { echo "FAIL: $1"
         grep -E '^(islands|window-island|stack=)' "$work/ut.out" 2>/dev/null | tail -5 | sed 's/^/  undertow| /'
         grep -m1 -E 'Assertion|Fatal' "$work/ut.err" 2>/dev/null | sed 's/^/  undertow| /' || true
         exit 1; }
count() { n=$(grep -c -- "$1" "$2" 2>/dev/null) || true; echo "${n:-0}"; }
await() {  # await FILE PATTERN WHY [TIMES]
  i=0; while [ "$(count "$2" "$1")" -lt "${4:-1}" ] && [ $i -lt 100 ]; do i=$((i + 1)); sleep 0.05; done
  [ "$(count "$2" "$1")" -ge "${4:-1}" ] || fail "$3"
}
shot() { "$grab" "$work/$1.ppm" > "$work/grab.log" 2>&1 || fail "abyssgrab ($1): $(cat "$work/grab.log")"; }
has() {  # has NAME R G B
  hdr=$(head -3 "$work/$1.ppm" | wc -c | tr -d ' ')
  tail -c +$((hdr + 1)) "$work/$1.ppm" | od -An -v -tu1 | tr -s ' \n' '\n\n' | grep -v '^$' \
    | awk -v r="$2" -v g="$3" -v b="$4" '{ v[NR % 3] = $1 } NR % 3 == 0 && v[1] == r && v[2] == g && v[0] == b { n++ } END { print n + 0 }'
}
islands() { grep '^islands ' "$work/ut.out" | tail -1; }
where() { grep "^window-island $1 " "$work/ut.out" | tail -1 | awk '{print $3}'; }
top() { grep '^stack=' "$work/ut.out" | tail -1 | awk '{print $NF}'; }
# key MASK CODE: a chord through the virtual keyboard (Ctrl 4, Alt 8, Shift 1, Cmd 64).
key() { printf 'c %s %s\n' "$1" "$2" >&4; sleep 0.25; }
keys_to() { n=$(count '^key ' "$work/$1.log"); printf 'k 30\n' >&4; sleep 0.3; [ "$(count '^key ' "$work/$1.log")" -gt "$n" ]; }

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

env -u WAYLAND_DISPLAY "$undertow" run --hz 60 --frames 0 --width 800 --height 600 --output 640x480 \
    --config-dir "$work" > "$work/ut.out" 2> "$work/ut.err" &
ut_pid=$!
await "$work/ut.out" '^WAYLAND_DISPLAY=' "undertow never announced a socket"
export WAYLAND_DISPLAY="$(grep -m1 '^WAYLAND_DISPLAY=' "$work/ut.out" | cut -d= -f2-)"
await "$work/ut.out" '^islands HEADLESS-1=1 HEADLESS-2=1$' "undertow did not report both displays on island 1"

mkfifo "$work/vp" "$work/vk" "$work/a" "$work/b"
"$work/vpointer" 1440 600 < "$work/vp" > "$work/vp.log" 2>&1 & vp=$!; exec 3>"$work/vp"
"$work/vkeyboard" < "$work/vk" > "$work/vk.log" 2>&1 & vk=$!; exec 4>"$work/vk"
await "$work/vk.log" ready "vkeyboard never bound"
env ABYSS_CONFIG_DIR="$work/cfg" AQUA_SCENE=window "$aqua" > "$work/aqua.log" 2>&1 & aq=$!
await "$work/ut.out" '^window-island org.abyssbsd.aquademo' "the Aqua window never mapped"
"$work/lockclient" window ff336699 org.abyssbsd.isl-a < "$work/a" > "$work/a.log" 2>&1 & wa=$!; exec 5>"$work/a"
await "$work/ut.out" '^window-island org.abyssbsd.isl-a 1$' "window A was not put on island 1"
sleep 0.5; shot one
[ "$(has one 51 102 153)" -gt 1000 ] || fail "window A is not drawn on island 1"

# ---------------------------------------------------------------- 1. Ctrl-2
key 4 3
await "$work/ut.out" '^islands HEADLESS-1=2 HEADLESS-2=1$' "Ctrl-2 did not show island 2"
sleep 0.3; shot two
[ "$(has two 51 102 153)" = 0 ] || fail "on island 2, island 1's window A is still drawn ($(has two 51 102 153) pixels)"
await "$work/aqua.log" 'Surface.Window: suspended' "the Aqua window on island 1 was not told it is suspended"
echo "ok: 1. Ctrl-2: island 2 shown, island 1's windows not drawn, the Aqua one told it is suspended"

# ------------------------------------------------- 2. a window opened there
"$work/lockclient" window ffcc2222 org.abyssbsd.isl-b < "$work/b" > "$work/b.log" 2>&1 & wb=$!; exec 6>"$work/b"
await "$work/ut.out" '^window-island org.abyssbsd.isl-b 2$' "a window opened on island 2 was not put there"
sleep 0.4
keys_to b || fail "the window opened on island 2 does not have the keyboard"
echo "ok: 2. a window opened on island 2 is on it, and has the keyboard"

# ---------------------------------------------------------------- 3. Ctrl-1
key 4 2
await "$work/ut.out" '^islands HEADLESS-1=1 HEADLESS-2=1$' "Ctrl-1 did not show island 1"
sleep 0.3; shot back
[ "$(has back 51 102 153)" -gt 1000 ] || fail "back on island 1, window A is not drawn"
[ "$(has back 204 34 34)" = 0 ] || fail "back on island 1, island 2's window B is drawn"
await "$work/aqua.log" 'Surface.Window: resumed' "the Aqua window was not told it was shown again"
b=$(count '^key ' "$work/b.log")
printf 'k 30\n' >&4; sleep 0.3
[ "$(count '^key ' "$work/b.log")" = "$b" ] || fail "back on island 1, a key reached island 2's window B"
echo "ok: 3. Ctrl-1: island 1 drawn and resumed, island 2's window not drawn and deaf"

# ------------------------------------------------------- 4. sending windows
geom=$(grep '^window org.abyssbsd.isl-a ' "$work/ut.out" | tail -1 | awk '{print $3}')
x=${geom%,*}; y=${geom#*,}
printf 'm %s %s\np\nr\n' $((x + 20)) $((y + 20)) >&3; sleep 0.3
[ "$(top)" = org.abyssbsd.isl-a ] || fail "a click on window A did not bring it to the top"
key 12 3                                              # Ctrl-Alt-2
await "$work/ut.out" '^window-island org.abyssbsd.isl-a 2$' "Ctrl-Alt-2 did not send window A to island 2"
[ "$(islands)" = "islands HEADLESS-1=1 HEADLESS-2=1" ] || fail "Ctrl-Alt-2 moved the view as well: $(islands)"
sleep 0.3; shot sent
[ "$(has sent 51 102 153)" = 0 ] || fail "window A, sent to island 2, is still drawn on island 1"
case "$(top)" in org.abyssbsd.aquademo*) ;; *) false ;; esac || fail "after sending A away, the Aqua window was not focused ($(top))"
key 13 4                                              # Ctrl-Alt-Shift-3
await "$work/ut.out" '^window-island org.abyssbsd.aquademo[^ ]* 3$' "Ctrl-Alt-Shift-3 did not send the Aqua window to island 3"
await "$work/ut.out" '^islands HEADLESS-1=3 HEADLESS-2=1$' "Ctrl-Alt-Shift-3 did not take the view with the window"
echo "ok: 4. Ctrl-Alt-2 sent a window and stayed; Ctrl-Alt-Shift-3 sent one and went with it"

# ------------------------------------------------------------ 5. stepping
key 4 106                                             # Ctrl-→ from 3
await "$work/ut.out" '^islands HEADLESS-1=4 ' "Ctrl-→ did not step from 3 to 4"
key 4 106                                             # and wraps
await "$work/ut.out" '^islands HEADLESS-1=1 ' "Ctrl-→ from the last did not wrap to the first" 3
key 4 105                                             # Ctrl-← wraps back
await "$work/ut.out" '^islands HEADLESS-1=4 ' "Ctrl-← from the first did not wrap to the last" 2
echo "ok: 5. Ctrl-← and Ctrl-→ step through four islands and wrap"

# ------------------------------------------------------- 6. per display
[ "$(islands | awk '{print $3}')" = "HEADLESS-2=1" ] || fail "the second display's island changed with the first's: $(islands)"
echo "ok: 6. every switch was the first display's; the second kept island 1"

# ------------------------------------------------------- 7. Cmd-Tab across
before=$(islands)
key 64 15                                             # Cmd-Tab, from an empty island 4
sleep 0.3
t=$(top); [ -n "$t" ] || fail "Cmd-Tab focused nothing"
want="islands HEADLESS-1=$(where "$t") HEADLESS-2=1"
[ "$(islands)" = "$want" ] && [ "$(islands)" != "$before" ] || fail "Cmd-Tab to $t did not go to its island ($(islands), wanted $want)"
echo "ok: 7. Cmd-Tab reached $t on island $(where "$t") and went there"
echo "all green (islands: one per display at a time, the hidden ones suspended, the keys of §6.4, and nothing lost)."
