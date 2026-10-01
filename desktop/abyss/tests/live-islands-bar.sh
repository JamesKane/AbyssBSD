#!/bin/sh
# AbyssBSD Swift DE — islands in the menu bar and the Dock (PHASE13 P13.4).
#
# PRODUCT §7.3's fourth member: once a window can be somewhere you are not,
# something on screen must always know where it is. The menu bar's island item
# says which island you are on and lists every island's windows; the Dock's
# activate goes to a window's island first. The bar is the real one, on
# undertow's privileged socket (abyss_menubar_v1 v3); the Dock's request is
# the real protocol, through ftctl. Windows: A on island 1, B on 2, C on 3.
# Claims:
#
#   1. the bar shows the island from the start, and follows a switch made with
#      the keyboard;
#   2. its menu lists the islands, the shown one ticked, each with its own
#      windows under it;
#   3. choosing island 3 there shows island 3;
#   4. choosing window A there goes to island 1 and brings A to the front;
#   5. the Dock's activate, for B on island 2, goes there and brings B forward;
#   6. with one island (islands.ini count = 1), there is no item at all.
#
# Usage: abyss/tests/live-islands-bar.sh
set -eu
root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"
. "$root/abyss/common.sh"
abyss_ensure_runtime_dir

undertow="$root/.build/debug/undertow"
aqua="$root/.build/debug/AquaDemo"
[ -x "$undertow" ] && [ -x "$aqua" ] || swift build
command -v wayland-scanner >/dev/null 2>&1 || { echo "note: no wayland-scanner, skipping"; exit 0; }

work=$(mktemp -d /tmp/abyss-ib.XXXXXX)
cleanup() {
  exec 3>&- 4>&- 5>&- 6>&- 7>&- 2>/dev/null || true
  for p in ${bar:-} ${wc:-} ${wb:-} ${wa:-} ${vk:-} ${vp:-} ${ut_pid:-}; do kill "$p" 2>/dev/null || true; done
  rm -rf "$work" 2>/dev/null || true
}
trap cleanup EXIT INT TERM HUP
trap '' PIPE
fail() { echo "FAIL: $1"
         grep -E '^(islands|stack=)' "$work/ut.out" 2>/dev/null | tail -3 | sed 's/^/  undertow| /'
         grep -E 'MenuBar: (island|opened|chose|item)' "$work/bar.log" 2>/dev/null | tail -6 | sed 's/^/  bar| /'
         exit 1; }
count() { n=$(grep -c -- "$1" "$2" 2>/dev/null) || true; echo "${n:-0}"; }
await() {  # await FILE PATTERN WHY [TIMES]
  i=0; while [ "$(count "$2" "$1")" -lt "${4:-1}" ] && [ $i -lt 100 ]; do i=$((i + 1)); sleep 0.05; done
  [ "$(count "$2" "$1")" -ge "${4:-1}" ] || fail "$3"
}
top() { grep '^stack=' "$work/ut.out" | tail -1 | awk '{print $NF}'; }
# at PATTERN: the last logged position of a bar item matching PATTERN.
at() { grep -- "$1" "$work/bar.log" | tail -1 | sed 's/.* at \([0-9]*,[0-9]*\).*/\1/'; }
click() { printf 'm %s %s\np\nr\n' "${1%,*}" "${1#*,}" >&3; sleep 0.4; }

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

# start ISLANDS-INI: undertow (the slide off: this is about where things are),
# the bar on the privileged socket, a keyboard and a pointer.
start() {
  mkdir -p "$work/cfg"; printf '[islands]\nanimate = no\n%s\n' "$1" > "$work/cfg/islands.ini"
  priv="abyss-ib-priv-$$"
  env -u WAYLAND_DISPLAY "$undertow" run --hz 60 --frames 0 --width 1024 --height 600 \
      --config-dir "$work/cfg" --privileged-socket "$priv" > "$work/ut.out" 2> "$work/ut.err" &
  ut_pid=$!
  await "$work/ut.out" '^WAYLAND_DISPLAY=' "undertow never announced a socket"
  export WAYLAND_DISPLAY="$(grep -m1 '^WAYLAND_DISPLAY=' "$work/ut.out" | cut -d= -f2-)"
  env WAYLAND_DISPLAY="$priv" ABYSS_CONFIG_DIR="$work/cfg" AQUA_SCENE=menubar "$aqua" > "$work/bar.log" 2>&1 & bar=$!
  await "$work/bar.log" 'MenuBar: island item ' "the bar never drew"
}

start ''
mkfifo "$work/vp" "$work/vk" "$work/a" "$work/b" "$work/c"
"$work/vpointer" 1024 600 < "$work/vp" > "$work/vp.log" 2>&1 & vp=$!; exec 3>"$work/vp"
"$work/vkeyboard" < "$work/vk" > "$work/vk.log" 2>&1 & vk=$!; exec 4>"$work/vk"
await "$work/vk.log" ready "vkeyboard never bound"
"$work/lockclient" window ff336699 org.abyssbsd.ib-a < "$work/a" > /dev/null 2>&1 & wa=$!; exec 5>"$work/a"
await "$work/ut.out" '^window-island org.abyssbsd.ib-a 1$' "A did not open on island 1"

# ----------------------------------------------- 1. the item follows
await "$work/bar.log" "MenuBar: island HEADLESS-1 1 of 4 (1)" "the bar was not told the island on binding"
await "$work/bar.log" "MenuBar: island item '1' at " "the bar shows no island item"
printf 'c 4 3\n' >&4
await "$work/bar.log" "MenuBar: island HEADLESS-1 2 of 4 (2)" "the bar did not hear Ctrl-2"
await "$work/bar.log" "MenuBar: island item '2' at " "the bar's item did not change to 2"
"$work/lockclient" window ffcc2222 org.abyssbsd.ib-b < "$work/b" > /dev/null 2>&1 & wb=$!; exec 6>"$work/b"
await "$work/ut.out" '^window-island org.abyssbsd.ib-b 2$' "B did not open on island 2"
printf 'c 4 4\n' >&4
await "$work/ut.out" '^islands HEADLESS-1=3$' "Ctrl-3 did not show island 3"
"$work/lockclient" window ff22aa22 org.abyssbsd.ib-c < "$work/c" > /dev/null 2>&1 & wc=$!; exec 7>"$work/c"
await "$work/ut.out" '^window-island org.abyssbsd.ib-c 3$' "C did not open on island 3"
printf 'c 4 3\n' >&4
await "$work/bar.log" "MenuBar: island item '2' at " "the bar did not follow back to 2" 2
echo "ok: 1. the bar shows the island from the start, and follows the keyboard"

# ---------------------------------------------------- 2. the menu
click "$(at "MenuBar: island item '2'")"
await "$work/bar.log" 'MenuBar: opened Islands' "the island item did not open its menu"
# The island rows of the menu just opened (P13.6 added a Shoals section under them).
rows=$(awk '/MenuBar: opened Islands/{ buf = "" } /MenuBar: item /{ buf = buf $0 "\n" } END { printf "%s", buf }' "$work/bar.log" \
  | sed "s/.*item '\([^']*\)'.*/\1/" | sed 's/^ *//' | grep -v -E 'Shoal|Strip|Front Window' | tr '\n' '|')
[ "$rows" = "Island 1|org.abyssbsd.ib-a|✓ Island 2|org.abyssbsd.ib-b|Island 3|org.abyssbsd.ib-c|Island 4|" ] \
  || fail "the menu's rows are not each island and its windows, 2 ticked: $rows"
echo "ok: 2. the menu: every island, island 2 ticked, each with its own windows"

# ---------------------------------------------- 3. choose island 3
click "$(at "MenuBar: item '    Island 3'")"
await "$work/ut.out" '^islands HEADLESS-1=3$' "choosing Island 3 did not show it" 2
await "$work/bar.log" "MenuBar: island item '3' at " "the bar did not follow its own choice"
echo "ok: 3. choosing Island 3 showed it"

# ---------------------------------------------- 4. choose window A
click "$(at "MenuBar: island item '3'")"
await "$work/bar.log" 'MenuBar: opened Islands' "the menu did not open a second time" 2
click "$(at "MenuBar: item '        org.abyssbsd.ib-a'")"
await "$work/ut.out" '^islands HEADLESS-1=1$' "choosing window A did not go to its island" 2
[ "$(top)" = org.abyssbsd.ib-a ] || fail "choosing window A did not bring it to the front ($(top))"
echo "ok: 4. choosing window A went to island 1 and brought A forward"

# ------------------------------------------------------- 5. the Dock
"$work/ftctl" org.abyssbsd.ib-b restore > "$work/ft.log" 2>&1 || fail "ftctl: $(cat "$work/ft.log")"
await "$work/ut.out" '^islands HEADLESS-1=2$' "the Dock's activate did not go to B's island" 3
sleep 0.2; [ "$(top)" = org.abyssbsd.ib-b ] || fail "the Dock's activate did not bring B forward ($(top))"
echo "ok: 5. the Dock's activate went to island 2 and brought B forward"

# --------------------------------------------------- 6. one island
for p in ${bar:-} ${wc:-} ${wb:-} ${wa:-} ${vk:-} ${vp:-} ${ut_pid:-}; do kill "$p" 2>/dev/null || true; done
exec 3>&- 4>&- 5>&- 6>&- 7>&- 2>/dev/null || true
wc=""; wb=""; wa=""; vk=""; vp=""; sleep 0.3
start 'count = 1'
await "$work/bar.log" "MenuBar: island HEADLESS-1 1 of 1" "the bar was not told about the one island"
grep -q "MenuBar: island item none" "$work/bar.log" && ! grep -q "MenuBar: island item '" "$work/bar.log" \
  || fail "with one island, the bar drew an item"
echo "ok: 6. one island: no item"
echo "all green (islands in the bar and the Dock: where you are, where every window is, and nothing lost)."
