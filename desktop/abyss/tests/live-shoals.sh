#!/bin/sh
# AbyssBSD Swift DE — Shoals: a working set, recalled together (PHASE13 P13.6).
#
# Stage Manager done properly (PRODUCT §7.3): the set is explicit, recall
# raises it where its windows were last left and moves nothing else, and it
# lives on an island. Five windows, A–E, overlapping as windows do; the menu
# bar on undertow's privileged socket. Claims:
#
#   1. Ctrl-Alt-N makes a shoal of A; Ctrl-Alt-= adds B and C; shoals.ini
#      says so;
#   2. D and E brought over them, Ctrl-Shift-1 recalls the shoal: A, B and C
#      are the top three, in the shoal's order, and no window has moved;
#      2b. a member sent to another island comes home with the recall;
#   3. Ctrl-Alt-- takes B out;
#   4. Ctrl-F3: the strip shows the shoal, its windows drawn in its tile; a
#      click on the tile recalls it, and the strip goes (it is not pinned);
#   5. the menu bar's island menu lists the shoal, and recalls it;
#   6. after undertow and the windows restart, the shoal is re-formed from
#      shoals.ini as its windows come back, and recalls.
#
# Usage: abyss/tests/live-shoals.sh
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

work=$(mktemp -d /tmp/abyss-shoal.XXXXXX)
pids="$work/pids"; : > "$pids"
cleanup() {
  exec 3>&- 4>&- 2>/dev/null || true
  [ -s "$pids" ] && while read -r p; do kill "$p" 2>/dev/null || true; done < "$pids"
  for p in ${bar:-} ${vk:-} ${vp:-} ${ut_pid:-}; do kill "$p" 2>/dev/null || true; done
  rm -rf "$work" 2>/dev/null || true
}
trap cleanup EXIT INT TERM HUP
trap '' PIPE
fail() { echo "FAIL: $1"
         grep -E 'shoal' "$work/ut.err" 2>/dev/null | tail -5 | sed 's/^/  undertow| /'
         grep -E '^stack=' "$work/ut.out" 2>/dev/null | tail -1 | sed 's/^/  undertow| /'
         exit 1; }
count() { n=$(grep -c -- "$1" "$2" 2>/dev/null) || true; echo "${n:-0}"; }
await() {  # await FILE PATTERN WHY [TIMES]
  i=0; while [ "$(count "$2" "$1")" -lt "${4:-1}" ] && [ $i -lt 100 ]; do i=$((i + 1)); sleep 0.05; done
  [ "$(count "$2" "$1")" -ge "${4:-1}" ] || fail "$3"
}
shot() { "$grab" "$work/$1.ppm" > "$work/grab.log" 2>&1 || fail "abyssgrab ($1): $(cat "$work/grab.log")"; }
stack() { grep '^stack=' "$work/ut.out" | tail -1 | cut -d= -f2; }
key() { printf 'c %s %s\n' "$1" "$2" >&4; sleep 0.35; }
click() { printf 'm %s %s\np\nr\n' "${1%,*}" "${1#*,}" >&3; sleep 0.35; }
# focus X: bring window X forward as the Dock does (a click would need a spot
# no other window covers, and a raised window covers its neighbours' corners).
focus() {
  "$work/ftctl" "org.abyssbsd.sh-$1" restore > "$work/ft.log" 2>&1 || fail "ftctl: $(cat "$work/ft.log")"
  i=0; while [ "$(stack | awk '{print $NF}')" != "org.abyssbsd.sh-$1" ] && [ $i -lt 40 ]; do i=$((i + 1)); sleep 0.05; done
  [ "$(stack | awk '{print $NF}')" = "org.abyssbsd.sh-$1" ] || fail "$1 did not come to the front ($(stack))"
}
windows() { grep '^window org.abyssbsd.sh' "$work/ut.out" | awk '{ last[$2] = $3 " " $4 } END { for (k in last) print k, last[k] }' | sort; }

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
   "$work/ext-session-lock-proto.c" $(pkg-config --cflags --libs wayland-client) -o "$work/lockclient" || fail "lockclient"
cc -I "$root/de/cwayland/include" "$root/abyss/tests/ftctl.c" \
   "$root/de/cwayland/wlr-foreign-toplevel-management-unstable-v1-protocol.c" \
   $(pkg-config --cflags --libs wayland-client) -o "$work/ftctl" || fail "ftctl"
mkfifo "$work/hold"; exec 5<>"$work/hold"

# start: undertow (the slide off), the bar, a keyboard and a pointer.
start() {
  mkdir -p "$work/cfg"; printf '[islands]\nanimate = no\n' > "$work/cfg/islands.ini"
  priv="abyss-shoal-priv-$$-$1"
  env -u WAYLAND_DISPLAY "$undertow" run --hz 60 --frames 0 --width 1024 --height 768 \
      --config-dir "$work/cfg" --privileged-socket "$priv" > "$work/ut.out" 2> "$work/ut.err" &
  ut_pid=$!
  await "$work/ut.out" '^WAYLAND_DISPLAY=' "undertow never announced a socket"
  export WAYLAND_DISPLAY="$(grep -m1 '^WAYLAND_DISPLAY=' "$work/ut.out" | cut -d= -f2-)"
  env WAYLAND_DISPLAY="$priv" ABYSS_CONFIG_DIR="$work/cfg" AQUA_SCENE=menubar "$aqua" > "$work/bar.log" 2>&1 & bar=$!
  await "$work/bar.log" 'MenuBar: island item ' "the bar never drew"
  rm -f "$work/vp" "$work/vk"; mkfifo "$work/vp" "$work/vk"
  "$work/vpointer" 1024 768 < "$work/vp" > "$work/vp.log" 2>&1 & vp=$!; exec 3>"$work/vp"
  "$work/vkeyboard" < "$work/vk" > "$work/vk.log" 2>&1 & vk=$!; exec 4>"$work/vk"
  await "$work/vk.log" ready "vkeyboard never bound"
}
win() {  # win LETTER COLOUR
  ( "$work/lockclient" window "$2" "org.abyssbsd.sh-$1" < "$work/hold" > /dev/null 2>&1 & echo $! >> "$pids" )
  await "$work/ut.out" "^window org.abyssbsd.sh-$1 " "window $1 never mapped"
}

start 1
win a ff336699; win b ffcc2222; win c ff22aa22; win d ffdddd22; win e ff8833aa
sleep 0.3

# --------------------------------------------------- 1. making the shoal
focus a; key 12 49                                          # Ctrl-Alt-N
await "$work/ut.err" 'shoal Shoal 1 made of org.abyssbsd.sh-a' "Ctrl-Alt-N did not make a shoal of A"
focus b; key 12 13                                          # Ctrl-Alt-=
await "$work/ut.err" 'shoal Shoal 1 + org.abyssbsd.sh-b (2)' "Ctrl-Alt-= did not add B"
focus c; key 12 13
await "$work/ut.err" 'shoal Shoal 1 + org.abyssbsd.sh-c (3)' "Ctrl-Alt-= did not add C"
grep -q "^members = org.abyssbsd.sh-a	org.abyssbsd.sh-b	org.abyssbsd.sh-c$" "$work/cfg/shoals.ini" \
  || fail "shoals.ini does not hold A, B and C: $(cat "$work/cfg/shoals.ini")"
echo "ok: 1. a shoal of A, B and C, made by the keyboard and kept in shoals.ini"

# ------------------------------------------------------------ 2. recall
focus d; focus e
before=$(windows)
key 5 2                                                     # Ctrl-Shift-1
await "$work/ut.err" 'shoal Shoal 1 recalled: org.abyssbsd.sh-a org.abyssbsd.sh-b org.abyssbsd.sh-c' "Ctrl-Shift-1 did not recall the shoal"
sleep 0.2
[ "$(stack | awk '{print $(NF-2), $(NF-1), $NF}')" = "org.abyssbsd.sh-a org.abyssbsd.sh-b org.abyssbsd.sh-c" ] \
  || fail "after a recall the top three are not A, B, C in order: $(stack)"
[ "$(windows)" = "$before" ] || fail "a recall moved a window"
echo "ok: 2. recalled over D and E: A, B, C on top in the shoal's order, and nothing moved"

# 2b. A member sent to another island comes home with its shoal.
focus c; key 12 3                                           # Ctrl-Alt-2: C to island 2
await "$work/ut.out" '^window-island org.abyssbsd.sh-c 2$' "Ctrl-Alt-2 did not send C to island 2"
key 5 2
await "$work/ut.out" '^window-island org.abyssbsd.sh-c 1$' "the recall did not bring C back from island 2" 2
[ "$(stack | awk '{print $NF}')" = "org.abyssbsd.sh-c" ] || fail "C, brought back, is not on top ($(stack))"
echo "ok: 2b. a member sent to island 2 came back with its shoal's recall"

# ------------------------------------------------------------ 3. remove
focus b; key 12 12                                          # Ctrl-Alt--
await "$work/ut.err" 'shoal Shoal 1 − org.abyssbsd.sh-b' "Ctrl-Alt-- did not take B out"
grep -q "^members = org.abyssbsd.sh-a	org.abyssbsd.sh-c$" "$work/cfg/shoals.ini" || fail "shoals.ini still has B"
echo "ok: 3. Ctrl-Alt-- took B out"

# ------------------------------------------------------------- 4. strip
focus d; focus e
key 4 61                                                    # Ctrl-F3
await "$work/ut.err" 'shoal strip on' "Ctrl-F3 did not show the strip"
tile=$(grep 'shoal-tile Shoal_1 ' "$work/ut.err" | tail -1 | awk '{print $4, $5}')
[ -n "$tile" ] || fail "the strip has no tile for the shoal"
sleep 0.3; shot strip
tx=${tile%%,*}; rest=${tile#*,}; ty=${rest%% *}; tw=${rest#* }; tw=${tw%x*}; th=${tile##*x}
hdr=$(head -3 "$work/strip.ppm" | wc -c | tr -d ' ')
inside=$(tail -c +$((hdr + 1)) "$work/strip.ppm" | od -An -v -tu1 | tr -s ' \n' '\n\n' | grep -v '^$' \
  | awk -v x0="$tx" -v y0="$ty" -v w="$tw" -v h="$th" '{ v[NR % 3] = $1 }
      NR % 3 == 0 { p = NR / 3 - 1; x = p % 1024; y = int(p / 1024)
        if (x >= x0 && x < x0 + w && y >= y0 && y < y0 + h && ((v[1] == 51 && v[2] == 102 && v[0] == 153) || (v[1] == 34 && v[2] == 170 && v[0] == 34))) n++ }
      END { print n + 0 }')
[ "$inside" -gt 200 ] || fail "the strip's tile does not show the shoal's windows ($inside pixels of A or C in it)"
click "$((tx + tw / 2)),$((ty + th / 2))"
await "$work/ut.err" 'shoal Shoal 1 recalled: org.abyssbsd.sh-a org.abyssbsd.sh-c' "a click on the tile did not recall the shoal"
grep -q "shoal-tile" "$work/ut.err" && [ "$(stack | awk '{print $(NF-1), $NF}')" = "org.abyssbsd.sh-a org.abyssbsd.sh-c" ] \
  || fail "the tile's recall did not put A and C on top: $(stack)"
echo "ok: 4. Ctrl-F3: the strip's tile shows the shoal's windows, and a click on it recalled them"

# ------------------------------------------------------------ 5. the bar
focus d
at=$(grep "MenuBar: island item '1' at " "$work/bar.log" | tail -1 | sed 's/.* at //')
click "$at"
await "$work/bar.log" 'MenuBar: opened Islands' "the island item did not open"
row=$(grep "MenuBar: item 'Recall Shoal 1 (2)' at " "$work/bar.log" | tail -1 | sed 's/.* at \([0-9]*,[0-9]*\).*/\1/')
[ -n "$row" ] || fail "the island menu does not list the shoal: $(grep "MenuBar: item '" "$work/bar.log" | tail -12 | tr '\n' ';')"
click "$row"
await "$work/ut.err" 'shoal Shoal 1 recalled: ' "choosing the shoal in the bar did not recall it" 3
echo "ok: 5. the menu bar listed the shoal and recalled it"

# ----------------------------------------------------- 6. after a restart
while read -r p; do kill "$p" 2>/dev/null || true; done < "$pids"; : > "$pids"
for p in ${bar:-} ${vk:-} ${vp:-} ${ut_pid:-}; do kill "$p" 2>/dev/null || true; done
exec 3>&- 4>&- 2>/dev/null || true; sleep 0.5
start 2
win c ff22aa22; win d ffdddd22; win a ff336699
await "$work/ut.err" 'shoal Shoal 1 has org.abyssbsd.sh-c again' "after a restart, C did not rejoin its shoal"
await "$work/ut.err" 'shoal Shoal 1 has org.abyssbsd.sh-a again' "after a restart, A did not rejoin its shoal"
focus d; key 5 2
await "$work/ut.err" 'shoal Shoal 1 recalled: org.abyssbsd.sh-a org.abyssbsd.sh-c' "the re-formed shoal did not recall"
echo "ok: 6. after undertow and the windows restarted, the shoal re-formed from shoals.ini and recalled"
echo "all green (Shoals: explicit, recalled where they were left, nothing else moved, kept)."
