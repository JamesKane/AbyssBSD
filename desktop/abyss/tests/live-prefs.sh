#!/bin/sh
# AbyssBSD Swift DE — System Preferences is an application (PHASE14 P14.1).
#
# Until Phase 14 it was a painting of a pane grid. Driven here on our own
# compositor three ways, each checked on the application's own word and the
# compositor's:
#
#   - the pointer: a click on a pane opens its page, and the window's title
#     becomes the pane's name (undertow sees the title change);
#   - the keyboard: ⌘L shows all, arrows walk the grid, Return opens, Escape
#     goes back;
#   - the vocabulary (Phase 10): `abyssmenu` lists System Preferences, opens
#     a pane by its verb, and is refused — with a reason — what cannot be done.
#
# Coordinates come from the application's own published layout, never from
# this script (§2.46).
#
# Usage: abyss/tests/live-prefs.sh
set -eu
root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"
. "$root/abyss/common.sh"
abyss_ensure_runtime_dir

undertow="$root/.build/debug/undertow"
client="$root/.build/debug/AquaDemo"
menu="$root/.build/debug/abyssmenu"
[ -x "$undertow" ] && [ -x "$client" ] && [ -x "$menu" ] || swift build
command -v wayland-scanner >/dev/null 2>&1 || { echo "note: no wayland-scanner, skipping"; exit 0; }

W=1024; H=768
work=$(mktemp -d /tmp/abyss-prefs.XXXXXX)
rundir=$(mktemp -d /tmp/abyss-prefsr.XXXXXX)
cleanup() {
  exec 3>&- 2>/dev/null || true
  exec 4>&- 2>/dev/null || true
  for p in ${vk_pid:-} ${vp_pid:-} ${app_pid:-} ${ut_pid:-}; do kill "$p" 2>/dev/null || true; done
  rm -rf "$work" "$rundir" 2>/dev/null || true
}
trap cleanup EXIT INT TERM HUP
export ABYSS_RUNTIME_DIR="$rundir"
mkdir -p "$work/cfg"
export ABYSS_CONFIG_DIR="$work/cfg"
fail() { echo "FAIL: $1"; [ -s "$work/app.log" ] && sed 's/^/  app| /' "$work/app.log" | tail -15; exit 1; }

# Wait for a line that appears AFTER mark (a count of earlier matches), so a
# line printed before the action cannot satisfy it (HANDOFF §2.61).
mark() { grep -c -- "$1" "$work/app.log" 2>/dev/null || true; }
await() {  # await PATTERN BEFORE WHY
  i=0
  while [ $i -lt 60 ]; do
    [ "$(mark "$1")" -gt "$2" ] && return 0
    sleep 0.05; i=$((i + 1))
  done
  fail "$3 (no new '$1' in the log)"
}

for t in vpointer:wlr-virtual-pointer-unstable-v1 vkeyboard:virtual-keyboard-unstable-v1; do
  n=${t%%:*}; x=${t#*:}
  wayland-scanner client-header "$root/abyss/tests/$x.xml" "$work/$n-proto.h"
  wayland-scanner private-code  "$root/abyss/tests/$x.xml" "$work/$n-proto.c"
done
cc -I"$work" "$root/abyss/tests/vpointer.c" "$work/vpointer-proto.c" \
   $(pkg-config --cflags --libs wayland-client) -o "$work/vpointer" || fail "could not build vpointer"
cc -I"$work" "$root/abyss/tests/vkeyboard.c" "$work/vkeyboard-proto.c" \
   $(pkg-config --cflags --libs wayland-client xkbcommon) -o "$work/vkeyboard" || fail "could not build vkeyboard"

wd="abyss-prefs-$$"
"$undertow" run --frames 0 --width "$W" --height "$H" --socket "$wd" \
   --config-dir "$work/cfg" > "$work/ut.out" 2> "$work/ut.err" &
ut_pid=$!
i=0; while [ ! -S "$XDG_RUNTIME_DIR/$wd" ] && [ $i -lt 100 ]; do i=$((i+1)); sleep 0.05; done
[ -S "$XDG_RUNTIME_DIR/$wd" ] || fail "undertow never bound $wd"

env WAYLAND_DISPLAY="$wd" AQUA_SCENE=sysprefs ABYSS_PREFS_DUMP=1 "$client" > "$work/app.log" 2>&1 &
app_pid=$!
await "System Preferences is up" 0 "the application never started"
await "SystemPreferences: layout " 0 "it never drew its grid"
echo "ok: $(grep -o 'System Preferences is up.*' "$work/app.log")"

# Where the window is, from the compositor, and where each pane is, from the app.
i=0; geom=""
while [ -z "$geom" ] && [ $i -lt 60 ]; do
  geom=$(grep '^window org.abyssbsd.preferences/' "$work/ut.out" | head -1 | awk '{print $(NF-1)}')
  sleep 0.05; i=$((i + 1))
done
[ -n "$geom" ] || fail "undertow never reported the window"
wx=${geom%,*}; wy=${geom#*,}
at() {  # at NAME -> "X Y" on the output, from the latest layout line
  p=$(grep 'SystemPreferences: layout ' "$work/app.log" | tail -1 | tr ' ' '\n' | sed -n "s/^$1=//p")
  [ -n "$p" ] || fail "the layout does not say where $1 is"
  echo "$((wx + ${p%,*})) $((wy + ${p#*,}))"
}

fifo="$work/vp.fifo"; mkfifo "$fifo"
env WAYLAND_DISPLAY="$wd" "$work/vpointer" "$W" "$H" < "$fifo" > "$work/vp.log" 2>&1 &
vp_pid=$!; exec 3>"$fifo"
kfifo="$work/vk.fifo"; mkfifo "$kfifo"
env WAYLAND_DISPLAY="$wd" "$work/vkeyboard" < "$kfifo" > "$work/vk.log" 2>&1 &
vk_pid=$!; exec 4>"$kfifo"
i=0; while { ! grep -q ready "$work/vp.log" || ! grep -q ready "$work/vk.log"; } 2>/dev/null && [ $i -lt 60 ]; do
  i=$((i+1)); sleep 0.1; done
grep -q ready "$work/vp.log" && grep -q ready "$work/vk.log" || fail "the virtual pointer or keyboard never bound"
sleep 0.5

# ------------------------------------------------------------ the pointer
b=$(mark "showing network")
printf 'm %s\np\nr\n' "$(at network)" >&3
await "showing network" "$b" "a click on Network did not open it"
i=0; while ! grep -q '^window org.abyssbsd.preferences/Network ' "$work/ut.out" && [ $i -lt 60 ]; do
  sleep 0.05; i=$((i + 1)); done
grep -q '^window org.abyssbsd.preferences/Network ' "$work/ut.out" \
  || fail "the window's title did not become the pane's (undertow: $(grep '^window org.abyssbsd.preferences' "$work/ut.out" | tail -1))"
echo "ok: a click on Network opened its page, and the compositor sees the window titled Network"

b=$(mark "showing all")
printf 'm %s\np\nr\n' "$(at showAll)" >&3
await "showing all" "$b" "Show All did not go back to the grid"
echo "ok: Show All went back to the grid"

# ----------------------------------------------------------- the keyboard
# Focus stays on the pane last visited (Network), as a Mac's does: one → from
# there is Sharing, the row's last (QuickTime, between them, is gone).
b=$(mark "focus sharing")
printf 'k 106\n' >&4                                             # →
await "focus sharing" "$b" "the arrows did not walk the grid from the pane last visited"
b=$(mark "showing sharing")
printf 'k 28\n' >&4                                              # Return
await "showing sharing" "$b" "Return did not open the focused pane"
b=$(mark "showing all")
printf 'c 64 38\n' >&4                                           # ⌘L
await "showing all" "$b" "⌘L (Show All Preferences) did nothing"
echo "ok: the keyboard walks the grid, Return opens, ⌘L shows all"

# --------------------------------------------------------- the vocabulary
"$menu" list > "$work/list.out" || fail "abyssmenu list failed"
grep -q "^System Preferences	menus.systempreferences.$app_pid$" "$work/list.out" || fail "list does not show System Preferences: $(cat "$work/list.out")"
"$menu" describe systempreferences > "$work/describe.out" || fail "describe failed: $(cat "$work/describe.out")"
grep -q '^  view.pane.sound	Sound	' "$work/describe.out" || fail "describe has no Sound in the View menu"
grep -q '^  view.showAll	Show All Preferences	⌘L	disabled (every pane is showing)$' "$work/describe.out" \
  || fail "Show All is not disabled-with-a-reason on the grid: $(grep showAll "$work/describe.out")"
b=$(mark "showing sound")
"$menu" run systempreferences view.pane.sound > /dev/null || fail "run view.pane.sound failed"
await "showing sound" "$b" "the vocabulary's view.pane.sound did not open Sound"
set +e
"$menu" run systempreferences view.pane.sound > "$work/r.out" 2>&1; rc=$?
set -e
[ "$rc" = 1 ] && grep -q "that pane is showing" "$work/r.out" \
  || fail "opening the showing pane again was not refused with a reason: rc=$rc $(cat "$work/r.out")"
echo "ok: abyssmenu lists it, opens Sound by its verb, and is refused what cannot be done — with a reason"

exec 3>&- 4>&- 2>/dev/null || true
echo "all green (System Preferences is an application: pointer, keyboard and vocabulary)."
