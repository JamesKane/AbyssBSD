#!/bin/sh
# AbyssBSD Swift DE — Ebb, the Exposé (PHASE13 P13.5, PRODUCT §7.3).
#
# Every window of a scope, scaled into its own slot and side by side, the
# desktop dimmed behind; one click to pick; Escape puts the tide back. A view,
# not a layout: no window's position is ever touched. Windows: A (blue), B
# (red) and C (green) on island 1, overlapping as windows do; D (yellow) on
# island 2; E (purple), a second window of A's application, on island 1.
# Claims:
#
#   1. F3: every window of this island, each in a slot, none overlapping, all
#      drawn; island 2's D not among them;
#   2. while it is open, keys reach no window, and no window has moved;
#   3. Escape puts the tide back: the screen is what it was, pixel for pixel;
#   4. a click on B's slot brings B to the front and closes Ebb;
#   5. Ctrl-↑, the archipelago: D too, and a click on it goes to island 2;
#   6. Ctrl-↓, this application: A's two windows and no others.
#
# Usage: abyss/tests/live-ebb.sh
set -eu
root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"
. "$root/abyss/common.sh"
abyss_ensure_runtime_dir

undertow="$root/.build/debug/undertow"
grab="$root/.build/debug/abyssgrab"
[ -x "$undertow" ] && [ -x "$grab" ] || swift build
command -v wayland-scanner >/dev/null 2>&1 || { echo "note: no wayland-scanner, skipping"; exit 0; }

work=$(mktemp -d /tmp/abyss-ebb.XXXXXX)
cleanup() {
  exec 3>&- 4>&- 5>&- 6>&- 7>&- 8>&- 9>&- 2>/dev/null || true
  for p in ${we:-} ${wd:-} ${wc:-} ${wb:-} ${wa:-} ${vk:-} ${vp:-} ${ut_pid:-}; do kill "$p" 2>/dev/null || true; done
  rm -rf "$work" 2>/dev/null || true
}
trap cleanup EXIT INT TERM HUP
trap '' PIPE
fail() { echo "FAIL: $1"
         grep -E 'ebb' "$work/ut.err" 2>/dev/null | tail -6 | sed 's/^/  undertow| /'
         grep -m1 -E 'Assertion|Fatal' "$work/ut.err" 2>/dev/null | sed 's/^/  undertow| /' || true
         exit 1; }
count() { n=$(grep -c -- "$1" "$2" 2>/dev/null) || true; echo "${n:-0}"; }
await() {  # await FILE PATTERN WHY [TIMES]
  i=0; while [ "$(count "$2" "$1")" -lt "${4:-1}" ] && [ $i -lt 100 ]; do i=$((i + 1)); sleep 0.05; done
  [ "$(count "$2" "$1")" -ge "${4:-1}" ] || fail "$3"
}
shot() { "$grab" "$work/$1.ppm" > "$work/grab.log" 2>&1 || fail "abyssgrab ($1): $(cat "$work/grab.log")"; }
has() {
  hdr=$(head -3 "$work/$1.ppm" | wc -c | tr -d ' ')
  tail -c +$((hdr + 1)) "$work/$1.ppm" | od -An -v -tu1 | tr -s ' \n' '\n\n' | grep -v '^$' \
    | awk -v r="$2" -v g="$3" -v b="$4" '{ v[NR % 3] = $1 } NR % 3 == 0 && v[1] == r && v[2] == g && v[0] == b { n++ } END { print n + 0 }'
}
# pixel NAME X Y: "R G B" at (X, Y) of a 1024-wide capture.
pixel() {
  hdr=$(head -3 "$work/$1.ppm" | wc -c | tr -d ' ')
  tail -c +$((hdr + ($3 * 1024 + $2) * 3 + 1)) "$work/$1.ppm" | head -c 3 | od -An -tu1 | awk '{print $1, $2, $3}'
}
top() { grep '^stack=' "$work/ut.out" | tail -1 | awk '{print $NF}'; }
key() { printf 'c %s %s\n' "$1" "$2" >&4; sleep 0.4; }
# slots: the last Ebb's slot lines, "KEY x,y WxH".
slots() { awk '/undertow: ebb [^ ]* on /{ buf="" } /undertow: ebb-slot /{ buf = buf $3 " " $4 " " $5 "\n" } END { printf "%s", buf }' "$work/ut.err"; }
centre() { slots | awk -v k="$1" '$1 == k { split($2, p, ","); split($3, s, "x"); print p[1] + int(s[1] / 2) "," p[2] + int(s[2] / 2) }'; }
click() { printf 'm %s %s\np\nr\n' "${1%,*}" "${1#*,}" >&3; sleep 0.5; }
windows() { grep '^window org.abyssbsd.eb' "$work/ut.out" | awk '{ last[$2] = $3 " " $4 } END { for (k in last) print k, last[k] }' | sort; }

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

env -u WAYLAND_DISPLAY "$undertow" run --hz 60 --frames 0 --width 1024 --height 768 \
    --config-dir "$work" > "$work/ut.out" 2> "$work/ut.err" &
ut_pid=$!
await "$work/ut.out" '^WAYLAND_DISPLAY=' "undertow never announced a socket"
export WAYLAND_DISPLAY="$(grep -m1 '^WAYLAND_DISPLAY=' "$work/ut.out" | cut -d= -f2-)"
mkfifo "$work/vp" "$work/vk" "$work/a" "$work/b" "$work/c" "$work/d" "$work/e"
"$work/vpointer" 1024 768 < "$work/vp" > "$work/vp.log" 2>&1 & vp=$!; exec 3>"$work/vp"
"$work/vkeyboard" < "$work/vk" > "$work/vk.log" 2>&1 & vk=$!; exec 4>"$work/vk"
await "$work/vk.log" ready "vkeyboard never bound"
win() {  # win FIFO FD COLOUR APP_ID ISLAND
  "$work/lockclient" window "$3" "$4" < "$work/$1" > "$work/$1.log" 2>&1 &
  eval "exec $2>\"$work/$1\""
  await "$work/ut.out" "^window-island $4 $5\$" "$4 did not open on island $5"
}
win a 5 ff336699 org.abyssbsd.eb-a 1; wa=$!
win b 6 ffcc2222 org.abyssbsd.eb-b 1; wb=$!
win c 7 ff22aa22 org.abyssbsd.eb-c 1; wc=$!
key 4 3; await "$work/ut.out" '^islands HEADLESS-1=2$' "could not reach island 2"
win d 8 ffdddd22 org.abyssbsd.eb-d 2; wd=$!
key 4 2; await "$work/ut.out" '^islands HEADLESS-1=1$' "could not get back to island 1" 2
sleep 0.5; shot before; before=$(windows)

# ------------------------------------------------------------- 1. F3
key 0 61                                              # F3
await "$work/ut.err" 'undertow: ebb HEADLESS-1 on island: 3 window(s)' "F3 did not open Ebb on this island's three windows"
sleep 0.4; shot ebb
n=$(slots | wc -l | tr -d ' ')
[ "$n" = 3 ] || fail "Ebb has $n slots, not 3"
slots | grep -q 'org.abyssbsd.eb-d' && fail "island 2's window is in an island-scope Ebb"
slots | awk '{ split($2, p, ","); split($3, s, "x"); x[NR] = p[1]; y[NR] = p[2]; w[NR] = s[1]; h[NR] = s[2] }
  END { for (i = 1; i <= NR; i++) for (j = i + 1; j <= NR; j++)
          if (!(x[i] + w[i] <= x[j] || x[j] + w[j] <= x[i] || y[i] + h[i] <= y[j] || y[j] + h[j] <= y[i])) exit 1 }' \
  || fail "two slots overlap: $(slots | tr '\n' ';')"
for kc in "org.abyssbsd.eb-a:51 102 153" "org.abyssbsd.eb-b:204 34 34" "org.abyssbsd.eb-c:34 170 34"; do
  k=${kc%%:*}; c=${kc#*:}; at=$(centre "$k")
  got=$(pixel ebb "${at%,*}" "${at#*,}")
  [ "$got" = "$c" ] || fail "in Ebb, the middle of $k's slot ($at) is $got, not its colour $c"
done
echo "ok: 1. F3: this island's three windows, each in its own slot, none overlapping, all drawn; D not among them"

# ------------------------------------------- 2. keys go nowhere, nothing moved
n=$(count '^key ' "$work/c.log"); printf 'k 30\n' >&4; sleep 0.3
[ "$(count '^key ' "$work/c.log")" = "$n" ] || fail "with Ebb open, a key reached the focused window"
[ "$(windows)" = "$before" ] || fail "Ebb moved a window: $(windows | tr '\n' ';')"
echo "ok: 2. while Ebb is open, keys reach no window and no window has moved"

# ------------------------------------------------------------ 3. Escape
key 0 1                                               # Escape
await "$work/ut.err" 'undertow: ebb HEADLESS-1 off' "Escape did not put the tide back"
sleep 0.5; shot after
cmp -s "$work/before.ppm" "$work/after.ppm" || fail "after Escape the screen is not what it was"
echo "ok: 3. Escape: the screen is what it was, pixel for pixel"

# ---------------------------------------------------------- 4. click B
key 0 61
await "$work/ut.err" 'undertow: ebb HEADLESS-1 on island' "F3 did not open Ebb a second time" 2
sleep 0.4; at=$(centre org.abyssbsd.eb-b); [ -n "$at" ] || fail "no slot for B"
click "$at"
await "$work/ut.err" 'undertow: ebb picked org.abyssbsd.eb-b' "a click on B's slot did not pick B"
[ "$(top)" = org.abyssbsd.eb-b ] || fail "picking B did not bring it to the front ($(top))"
await "$work/ut.err" 'undertow: ebb HEADLESS-1 off' "picking B did not close Ebb" 2
echo "ok: 4. a click on B's slot brought B to the front and closed Ebb"

# --------------------------------------------------- 5. the archipelago
key 4 103                                             # Ctrl-↑
await "$work/ut.err" 'undertow: ebb HEADLESS-1 on archipelago: 4 window(s)' "Ctrl-↑ did not show all four windows"
sleep 0.4; at=$(centre org.abyssbsd.eb-d); [ -n "$at" ] || fail "no slot for D"
click "$at"
await "$work/ut.out" '^islands HEADLESS-1=2$' "picking D did not go to island 2" 2
[ "$(top)" = org.abyssbsd.eb-d ] || fail "picking D did not bring it to the front ($(top))"
echo "ok: 5. Ctrl-↑: all four windows; picking D went to island 2"

# ----------------------------------------------------- 6. one application
key 4 2; await "$work/ut.out" '^islands HEADLESS-1=1$' "could not get back to island 1" 3
# E has A's app id, so its window-island line is A's: wait instead for it to
# take the focus, which puts an eb-a window on top of the stack.
"$work/lockclient" window ff8833aa org.abyssbsd.eb-a < "$work/e" > "$work/e.log" 2>&1 & we=$!; exec 9>"$work/e"
i=0; while [ "$(top)" != org.abyssbsd.eb-a ] && [ $i -lt 100 ]; do i=$((i + 1)); sleep 0.05; done
[ "$(top)" = org.abyssbsd.eb-a ] || fail "E (A's application) did not open and take the focus"
key 4 108                                             # Ctrl-↓, with E (A's app) focused
await "$work/ut.err" 'undertow: ebb HEADLESS-1 on app: 2 window(s)' "Ctrl-↓ did not show A's application's two windows"
[ "$(slots | awk '{print $1}' | sort -u)" = "org.abyssbsd.eb-a" ] || fail "an application's Ebb shows another's windows: $(slots | tr '\n' ';')"
key 0 1
echo "ok: 6. Ctrl-↓: the focused application's two windows, and no others"
echo "all green (Ebb: every window in sight, one click to pick, and everything where it was)."
