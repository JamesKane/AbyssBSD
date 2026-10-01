#!/bin/sh
# AbyssBSD Swift DE — the Islands pane (PHASE13 P13.7).
#
# System Preferences writes islands.ini as you click, and undertow follows the
# file itself — the pane tells nobody anything. The keys are shown as bound:
# the defaults, with keys.ini over them. The real pane on undertow; clicks at
# the places it publishes. Claims:
#
#   1. the pane shows the keys as bound — keys.ini's F4 for Ebb, not the
#      default F3 — and the rest as their defaults;
#   2. a click on 6 writes count = 6, undertow takes it while running, and
#      Ctrl-6 shows island 6;
#   3. the slide checkbox writes animate = false, and undertow takes that;
#   4. down to 2 while the pane itself is on island 6: undertow brings the
#      display and the window to island 2 — fewer islands lose nothing.
#
# Usage: abyss/tests/live-islands-pane.sh
set -eu
root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"
. "$root/abyss/common.sh"
abyss_ensure_runtime_dir

undertow="$root/.build/debug/undertow"
aqua="$root/.build/debug/AquaDemo"
[ -x "$undertow" ] && [ -x "$aqua" ] || swift build
command -v wayland-scanner >/dev/null 2>&1 || { echo "note: no wayland-scanner, skipping"; exit 0; }

work=$(mktemp -d /tmp/abyss-ip.XXXXXX)
cleanup() {
  exec 3>&- 4>&- 2>/dev/null || true
  for p in ${app:-} ${vk:-} ${vp:-} ${ut_pid:-}; do kill "$p" 2>/dev/null || true; done
  rm -rf "$work" 2>/dev/null || true
}
trap cleanup EXIT INT TERM HUP
trap '' PIPE
fail() { echo "FAIL: $1"
         grep -E 'islands' "$work/ut.err" "$work/ut.out" 2>/dev/null | tail -4 | sed 's/^/  undertow| /'
         grep -E 'islands' "$work/app.log" 2>/dev/null | tail -3 | sed 's/^/  pane| /'
         exit 1; }
count() { n=$(grep -c -- "$1" "$2" 2>/dev/null) || true; echo "${n:-0}"; }
await() {  # await FILE PATTERN WHY [TIMES]
  i=0; while [ "$(count "$2" "$1")" -lt "${4:-1}" ] && [ $i -lt 100 ]; do i=$((i + 1)); sleep 0.05; done
  [ "$(count "$2" "$1")" -ge "${4:-1}" ] || fail "$3"
}
ini() { sed -n "s/^$1 *= *//p" "$work/cfg/islands.ini" 2>/dev/null; }
# at NAME: where the pane's control NAME is on the output, from its layout line.
at() {
  geom=$(grep '^window org.abyssbsd.preferences/' "$work/ut.out" | tail -1 | awk '{print $(NF-1)}')
  p=$(grep 'islands layout' "$work/app.log" | tail -1 | tr ' ' '\n' | sed -n "s/^$1=//p")
  [ -n "$geom" ] && [ -n "$p" ] || fail "cannot find $1 on the pane"
  echo "$(( ${geom%,*} + ${p%,*} )) $(( ${geom#*,} + ${p#*,} ))"
}
click() { printf 'm %s\np\nr\n' "$(at "$1")" >&3; sleep 0.4; }

for x in vpointer:wlr-virtual-pointer-unstable-v1 vkeyboard:virtual-keyboard-unstable-v1; do
  n=${x%%:*}; f=${x#*:}
  wayland-scanner client-header "$root/abyss/tests/$f.xml" "$work/$n-proto.h"
  wayland-scanner private-code  "$root/abyss/tests/$f.xml" "$work/$n-proto.c"
done
cc -I"$work" "$root/abyss/tests/vpointer.c" "$work/vpointer-proto.c" $(pkg-config --cflags --libs wayland-client) -o "$work/vpointer" || fail "vpointer"
cc -I"$work" "$root/abyss/tests/vkeyboard.c" "$work/vkeyboard-proto.c" $(pkg-config --cflags --libs wayland-client xkbcommon) -o "$work/vkeyboard" || fail "vkeyboard"

mkdir -p "$work/cfg"
printf '[keys]\nF4 = ebb island\nF3 = run: true\n' > "$work/cfg/keys.ini"
env -u WAYLAND_DISPLAY "$undertow" run --hz 60 --frames 0 --width 1024 --height 768 \
    --config-dir "$work/cfg" > "$work/ut.out" 2> "$work/ut.err" &
ut_pid=$!
await "$work/ut.out" '^WAYLAND_DISPLAY=' "undertow never announced a socket"
export WAYLAND_DISPLAY="$(grep -m1 '^WAYLAND_DISPLAY=' "$work/ut.out" | cut -d= -f2-)"
mkfifo "$work/vp" "$work/vk"
"$work/vpointer" 1024 768 < "$work/vp" > "$work/vp.log" 2>&1 & vp=$!; exec 3>"$work/vp"
"$work/vkeyboard" < "$work/vk" > "$work/vk.log" 2>&1 & vk=$!; exec 4>"$work/vk"
await "$work/vk.log" ready "vkeyboard never bound"
env ABYSS_CONFIG_DIR="$work/cfg" AQUA_SCENE=sysprefs ABYSS_PREFS_DUMP=1 ABYSS_PREFS_PANE=islands \
    "$aqua" > "$work/app.log" 2>&1 & app=$!
await "$work/app.log" 'islands layout' "the Islands pane never published its layout"
await "$work/ut.out" '^window org.abyssbsd.preferences/' "undertow never reported the window"
sleep 0.5

# ---------------------------------------------------------- 1. the keys
grep -q "islands key 'Ebb: this island' = F4$" "$work/app.log" || fail "the pane does not show keys.ini's F4 for Ebb"
grep -q "islands key 'Show island N' = ⌃1…9$" "$work/app.log" || fail "the pane does not show ⌃1…9 for an island"
grep -q "islands key 'Recall shoal N' = ⌃⇧1…9$" "$work/app.log" || fail "the pane does not show ⌃⇧1…9 for a shoal"
echo "ok: 1. the keys shown as bound: keys.ini's F4 for Ebb, the defaults for the rest"

# ------------------------------------------------------- 2. six islands
click count.6
await "$work/app.log" 'SystemPreferences: islands -> 6 island(s), slide on' "a click on 6 did not write it"
[ "$(ini count)" = 6 ] || fail "islands.ini count is $(ini count), not 6"
await "$work/ut.err" 'undertow: islands.ini: 6 island(s), slide on' "undertow did not take the new count"
printf 'c 4 7\n' >&4                                         # Ctrl-6
await "$work/ut.out" '^islands HEADLESS-1=6$' "Ctrl-6 did not show island 6"
printf 'c 4 2\n' >&4                                         # Ctrl-1, back to the pane
await "$work/ut.out" '^islands HEADLESS-1=1$' "Ctrl-1 did not come back" 2
echo "ok: 2. a click on 6 wrote count = 6, undertow took it running, and Ctrl-6 showed island 6"

# ---------------------------------------------------------- 3. the slide
sleep 0.3; click slide
await "$work/app.log" 'SystemPreferences: islands -> 6 island(s), slide off' "the checkbox did not turn the slide off"
[ "$(ini animate)" = false ] || fail "islands.ini animate is '$(ini animate)'"
await "$work/ut.err" 'undertow: islands.ini: 6 island(s), slide off' "undertow did not take the slide off"
echo "ok: 3. the slide checkbox wrote animate = false, and undertow took it"

# ---------------------------------------------- 4. fewer, nothing lost
printf 'c 13 7\n' >&4                                        # Ctrl-Alt-Shift-6: the pane to 6, and go
await "$work/ut.out" '^window-island org.abyssbsd.preferences/[^ ]* 6$' "the pane did not go to island 6"
await "$work/ut.out" '^islands HEADLESS-1=6$' "the view did not follow the pane to island 6" 2
sleep 0.4; click count.2
await "$work/ut.err" 'undertow: islands.ini: 2 island(s)' "undertow did not take two islands"
await "$work/ut.out" '^islands HEADLESS-1=2$' "with two islands, the display was not brought to island 2"
await "$work/ut.out" '^window-island org.abyssbsd.preferences/[^ ]* 2$' "with two islands, the window on 6 was not brought to 2"
echo "ok: 4. down to 2 from island 6: the display and the window came to island 2"
echo "all green (the Islands pane: written as clicked, followed by undertow, keys as bound)."
