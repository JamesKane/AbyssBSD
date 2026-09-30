#!/bin/sh
# AbyssBSD Swift DE — the Dock carries installed applications (PHASE15 P15.2).
#
# A bundle `abyss-appgen` wrote (P15.1) is pinned by `dock.ini`, on our own
# compositor, driven by the virtual pointer. Claims:
#
#   1. the Dock pins what dock.ini names — the desktop's own tiles and an
#      installed bundle, by name — and says where each tile is;
#   2. clicking the bundle's tile launches it: its window maps on undertow;
#   3. the running window is the tile's: the Dock sees it running and adds no
#      second tile under the window's title (matched through the bundle's
#      app-ids, not the tile's label);
#   4. clicking again activates the running window rather than launching a
#      second copy;
#   5. a running application that is not pinned wears its bundle's name.
#
# Usage: abyss/tests/live-dock-apps.sh
set -eu
root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"
. "$root/abyss/common.sh"
abyss_ensure_runtime_dir

appgen="$root/.build/debug/abyss-appgen"
undertow="$root/.build/debug/undertow"
aqua="$root/.build/debug/AquaDemo"
for b in "$appgen" "$undertow" "$aqua"; do [ -x "$b" ] || { swift build; break; }; done
command -v wayland-scanner >/dev/null 2>&1 || { echo "note: no wayland-scanner, skipping"; exit 0; }

work=$(mktemp -d /tmp/abyss-dockapps.XXXXXX)
cleanup() {
  exec 3>&- 2>/dev/null || true
  for p in ${vp_pid:-} ${dock_pid:-} ${ut_pid:-}; do kill "$p" 2>/dev/null || true; done
  pkill -f "$work" 2>/dev/null || true
  rm -rf "$work"
}
trap cleanup EXIT INT TERM HUP
fail() {  # to stderr: it may run where stdout is captured or thrown away
  exec 1>&2
  echo "FAIL: $1"
  [ -s "$work/dock.log" ] && grep 'Dock:' "$work/dock.log" | tail -10 | sed 's/^/  dock| /'
  exit 1
}

# ------------------------------------------------------------ the bundle
home="$work/home"; mkdir -p "$home" "$work/entries" "$work/cfg"
cat > "$work/entries/org.abyssbsd.window.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Aqua Window
StartupWMClass=org.abyssbsd.aquademo
Exec=env AQUA_SCENE=window "$aqua"
EOF
"$appgen" --from "$work/entries" --to "$home/Applications" > "$work/gen.out" 2>&1 || fail "abyss-appgen: $(cat "$work/gen.out")"
printf '[dock]\napps = finder; Aqua Window; sysprefs\n' > "$work/cfg/dock.ini"

# ------------------------------------------------------------ the compositor
env -u WAYLAND_DISPLAY "$undertow" run --frames 0 --width 800 --height 600 \
    > "$work/ut.out" 2> "$work/ut.err" &
ut_pid=$!
wd=""; i=0
while [ $i -lt 80 ] && [ -z "$wd" ]; do
  wd=$(grep -m1 '^WAYLAND_DISPLAY=' "$work/ut.out" 2>/dev/null | cut -d= -f2-) || wd=""; sleep 0.25; i=$((i + 1))
done
[ -n "$wd" ] || fail "undertow never announced a socket"

start_dock() {  # start_dock LOG — the Dock with our HOME and dock.ini
  env WAYLAND_DISPLAY="$wd" HOME="$home" ABYSS_CONFIG_DIR="$work/cfg" \
      AQUA_SCENE=dock "$aqua" > "$1" 2>&1 &
  dock_pid=$!
  i=0
  while [ $i -lt 80 ]; do
    grep -q 'Dock: tiles ' "$1" 2>/dev/null && return 0
    kill -0 "$dock_pid" 2>/dev/null || fail "the Dock exited: $(cat "$1")"
    sleep 0.25; i=$((i + 1))
  done
  fail "the Dock never said where its tiles are"
}
start_dock "$work/dock.log"

# ------------------------------------------------------------ the pointer
xml="$root/abyss/tests/wlr-virtual-pointer-unstable-v1.xml"
wayland-scanner client-header "$xml" "$work/vpointer-proto.h"
wayland-scanner private-code  "$xml" "$work/vpointer-proto.c"
cc -I"$work" "$root/abyss/tests/vpointer.c" "$work/vpointer-proto.c" \
   $(pkg-config --cflags --libs wayland-client) -o "$work/vpointer" || fail "could not build the virtual pointer"
mkfifo "$work/pointer"
env WAYLAND_DISPLAY="$wd" "$work/vpointer" 800 600 < "$work/pointer" > "$work/vp.log" 2>&1 &
vp_pid=$!
exec 3> "$work/pointer"
sleep 1.5

tile() {  # tile NAME -> "X Y" on the output, from the Dock's latest tiles line
  line=$(grep 'Dock: tiles ' "$work/dock.log" | tail -1 | sed 's/.*Dock: tiles //')
  # Labels have spaces, so find "NAME=" at the start or after a space — in awk:
  # BSD sed has no alternation.
  p=$(printf '%s\n' "$line" | awk -v n="$1=" '{
        s = " " $0; i = index(s, " " n); if (!i) exit
        split(substr(s, i + 1 + length(n)), a, /[, ]/); print a[1], a[2] }')
  [ -n "$p" ] || fail "the Dock does not say where '$1' is: $line"
  set -- $p
  echo "$1 $((600 - $2))"
}
click() { printf 'm %s\n' "$(tile "$1")" >&3; sleep 0.4; printf 'p\nr\n' >&3; }
count() { grep -c -- "$1" "$work/dock.log" 2>/dev/null || true; }
await() {  # await PATTERN BEFORE WHY
  i=0
  while [ $i -lt 100 ]; do [ "$(count "$1")" -gt "$2" ] && return 0; sleep 0.1; i=$((i + 1)); done
  fail "$3"
}

# ------------------------------------------------------------ 1. pinned
grep -q 'Dock: pinned Finder, Aqua Window, System Preferences$' "$work/dock.log" \
  || fail "the Dock did not pin what dock.ini names"
tile "Aqua Window" > /dev/null
echo "ok: 1. dock.ini's tiles pinned, an installed bundle among them, and each tile's place said"

# ------------------------------------------------------------ 2. launch
b=$(count 'Dock: launched ')
click "Aqua Window"
await 'Dock: launched org.abyssbsd.aquademo' "$b" "clicking the bundle's tile launched nothing"
i=0; while [ $i -lt 150 ] && ! grep -q '^window org.abyssbsd.aquademo/' "$work/ut.out"; do sleep 0.1; i=$((i + 1)); done
grep -q '^window org.abyssbsd.aquademo/' "$work/ut.out" || fail "the launched application's window never mapped"
echo "ok: 2. the bundle's tile launched it, and its window mapped on undertow"

# ------------------------------------------------------------ 3. running
await 'Dock: running org.abyssbsd.aquademo' 0 "the Dock never saw it running"
sleep 0.5
last=$(grep 'Dock: tiles ' "$work/dock.log" | tail -1)
case "$last" in *"AbyssBSD="*) fail "a second tile under the window's title: $last" ;; esac
echo "ok: 3. the running window is the tile's (matched by the bundle's app-ids): no second tile"

# ------------------------------------------------------------ 4. activate
b=$(count 'Dock: activated '); l=$(count 'Dock: launched ')
click "Aqua Window"
await 'Dock: activated org.abyssbsd.aquademo' "$b" "a second click did not activate the running window"
[ "$(count 'Dock: launched ')" = "$l" ] || fail "a second click launched a second copy"
echo "ok: 4. a second click activated the running window instead of launching another"

# ------------------------------------------------------------ 5. unpinned
kill "$dock_pid" 2>/dev/null || true; wait "$dock_pid" 2>/dev/null || true
printf '[dock]\napps = finder; sysprefs\n' > "$work/cfg/dock.ini"
start_dock "$work/dock.log"
i=0; until grep -q 'Dock: tiles .*Aqua Window=' "$work/dock.log" || [ $i -ge 40 ]; do sleep 0.25; i=$((i + 1)); done
grep 'Dock: tiles ' "$work/dock.log" | tail -1 | grep -q 'Aqua Window=' \
  || fail "the unpinned running application did not wear its bundle's name: $(grep 'Dock: tiles ' "$work/dock.log" | tail -1)"
echo "ok: 5. an unpinned running application wears its bundle's name, not its window's title"

echo "all green (the Dock carries installed applications)."
