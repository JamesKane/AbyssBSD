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
#   5. a running application that is not pinned wears its bundle's name;
#   6. its tile's "Keep in Dock" pins it, and dock.ini says so;
#   7. a pinned tile's "Remove from Dock" unpins it, and "Quit" quits it —
#      the window found through the bundle's app-ids;
#   8. a bundle dragged out of the Finder onto a tile is pinned before that
#      tile, and saved;
#   9. a document dropped on an application's tile opens with it (the bundle's
#      launcher is given the file);
#  10. the Apple menu's Recent Items lists what the Dock opened, choosing it
#      opens it again (on the ordinary display, from the privileged bar), and
#      Clear Menu empties it.
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
  for p in ${vp_pid:-} ${bar_pid:-} ${finder_pid:-} ${dock_pid:-} ${ut_pid:-}; do kill "$p" 2>/dev/null || true; done
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
# The program notes the display each copy was started on: the bar launches on
# the privileged socket's behalf, and must never hand a child that socket.
printf '#!/bin/sh\necho "$WAYLAND_DISPLAY" >> "%s/displays"\nAQUA_SCENE=window exec "%s" "$@"\n' "$work" "$aqua" > "$work/aquawin"
chmod +x "$work/aquawin"
cat > "$work/entries/org.abyssbsd.window.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Aqua Window
StartupWMClass=org.abyssbsd.aquademo
Exec="$work/aquawin" %F
EOF
"$appgen" --from "$work/entries" --to "$home/Applications" > "$work/gen.out" 2>&1 || fail "abyss-appgen: $(cat "$work/gen.out")"
printf '[dock]\napps = finder; Aqua Window; sysprefs\n' > "$work/cfg/dock.ini"

# ------------------------------------------------------------ the compositor
# `--config-dir`: no window position remembered from another run moves the
# Finder out from under claim 8's aim.
mkdir -p "$work/ut-cfg"
priv="abyss-dockapps-priv-$$"
env -u WAYLAND_DISPLAY "$undertow" run --frames 0 --width 800 --height 600 --config-dir "$work/ut-cfg" \
    --privileged-socket "$priv" \
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

# ------------------------------------------------------------ the tile menu
# menu TILE ROW: right-click TILE, then click ROW where the menu really is — the
# popup's placement (relative to the Dock's surface, which sits at the bottom of
# the output) plus the row's offset in it, both as logged.
menu() {
  printf 'm %s\n' "$(tile "$1")" >&3; sleep 0.5
  n=$(grep -c 'Surface.Popup: placed at' "$work/dock.log" || true)
  printf 'P\nR\n' >&3
  i=0; while [ $i -lt 30 ] && [ "$(grep -c 'Surface.Popup: placed at' "$work/dock.log" || true)" -le "$n" ]; do sleep 0.1; i=$((i + 1)); done
  pl=$(grep 'Surface.Popup: placed at' "$work/dock.log" | tail -1 | sed 's/.*placed at \(-*[0-9]*\),\(-*[0-9]*\) .*/\1 \2/')
  row=$(grep -F "context item '$2' at" "$work/dock.log" | tail -1 | sed 's/.* at +\([0-9]*\),+\([0-9]*\) .*/\1 \2/')
  sh_=$(grep 'Surface.LayerSurface: mapped' "$work/dock.log" | tail -1 | sed 's/.*mapped [0-9]*x\([0-9]*\) .*/\1/')
  [ -n "$pl" ] && [ -n "$row" ] && [ -n "$sh_" ] || fail "no '$2' in $1's menu: $(grep 'context item' "$work/dock.log" | tail -4)"
  set -- $pl $row
  printf 'm %s %s\np\nr\n' "$(($1 + $3))" "$((600 - sh_ + $2 + $4))" >&3
  sleep 0.8
}
apps_saved() { sed -n 's/^apps *= *//p' "$work/cfg/dock.ini"; }

# ------------------------------------------------------------ 6. keep
menu "Aqua Window" "Keep in Dock"
[ "$(apps_saved)" = "finder; sysprefs; Aqua Window" ] || fail "Keep in Dock saved '$(apps_saved)'"
grep -q 'Dock: kept Aqua Window in the Dock' "$work/dock.log" || fail "Keep in Dock kept nothing"
echo "ok: 6. Keep in Dock pinned the running application (dock.ini: $(apps_saved))"

# ------------------------------------------------------------ 7. remove, quit
menu "Aqua Window" "Remove from Dock"
[ "$(apps_saved)" = "finder; sysprefs" ] || fail "Remove from Dock saved '$(apps_saved)'"
menu "Aqua Window" "Quit"
grep -q 'Dock: asked Aqua Window to quit (1 window)' "$work/dock.log" || fail "Quit found no window to close"
i=0; until ! grep 'Dock: tiles ' "$work/dock.log" | tail -1 | grep -q 'Aqua Window='; do
  [ $i -ge 50 ] && fail "the application did not quit"; sleep 0.1; i=$((i + 1)); done
echo "ok: 7. Remove from Dock unpinned it (dock.ini: $(apps_saved)); Quit closed its window, and its tile went"

# ------------------------------------------------------------ 8. drag a bundle on
# The Finder on ~/Applications: 520x400, centred at (140, 100); entries sort by
# name in 88px cells, so "Aqua Window.app" is cell 0 at screen (194, 196) and
# "Note.txt" (for claim 9) cell 1 at (282, 196) — live-dnd's numbers.
printf 'a note\n' > "$home/Applications/Note.txt"
env WAYLAND_DISPLAY="$wd" HOME="$home" ABYSS_CONFIG_DIR="$work/cfg" ABYSS_FINDER_DIR="$home/Applications" \
    AQUA_SCENE=finder "$aqua" > "$work/finder.log" 2>&1 &
finder_pid=$!
i=0; until grep -q 'Finder: listed' "$work/finder.log" 2>/dev/null; do
  [ $i -ge 80 ] && fail "the Finder never listed ~/Applications"; sleep 0.25; i=$((i + 1)); done
sleep 1
drag() {  # drag X Y NAME TILE — press on the Finder's NAME at X,Y and drop it on TILE
  printf 'm %s %s\np\n' "$1" "$2" >&3; sleep 0.6
  grep -q "Finder: selected $3" "$work/finder.log" || fail "the press did not land on $3: $(tail -3 "$work/finder.log")"
  printf 'm %s %s\n' "$1" "$(($2 + 16))" >&3; sleep 0.6
  grep -q "Finder: dragging $home/Applications/$3" "$work/finder.log" || fail "no drag of $3 started"
  printf 'm %s\n' "$(tile "$4")" >&3; sleep 0.8
  printf 'r\n' >&3; sleep 1.2
}
drag 194 196 "Aqua Window.app" "System Preferences"
[ "$(apps_saved)" = "finder; Aqua Window; sysprefs" ] \
  || fail "the bundle dropped on System Preferences saved '$(apps_saved)'"
grep 'Dock: tiles ' "$work/dock.log" | tail -1 | grep -q 'Finder=[0-9,]* Aqua Window=[0-9,]* System Preferences=' \
  || fail "the tiles are not in that order: $(grep 'Dock: tiles ' "$work/dock.log" | tail -1)"
echo "ok: 8. a bundle dragged out of the Finder was pinned before the tile it was dropped on (dock.ini: $(apps_saved))"

# ------------------------------------------------------------ 9. open with
w=$(grep -c '^window org.abyssbsd.aquademo/' "$work/ut.out" || true)
drag 282 196 "Note.txt" "Aqua Window"
grep -q "Dock: opened $home/Applications/Note.txt with Aqua Window" "$work/dock.log" \
  || fail "the document was not opened with the tile's application"
i=0; until [ "$(grep -c '^window org.abyssbsd.aquademo/' "$work/ut.out" || true)" -gt "$w" ]; do
  [ $i -ge 150 ] && fail "no window mapped for the opened document"; sleep 0.1; i=$((i + 1)); done
echo "ok: 9. a document dropped on the application's tile opened with it"

# ------------------------------------------------------------ 10. Recent Items
# The bar, on the privileged socket, launching onto the ordinary one.
env WAYLAND_DISPLAY="$priv" HOME="$home" ABYSS_CONFIG_DIR="$work/cfg" AQUA_SCENE=menubar \
    ABYSS_APP_WAYLAND_DISPLAY="$wd" "$aqua" > "$work/bar.log" 2>&1 &
bar_pid=$!
i=0; until grep -q 'MenuBar: titles ' "$work/bar.log" 2>/dev/null; do
  [ $i -ge 80 ] && fail "the bar never said where its titles are: $(tail -3 "$work/bar.log")"; sleep 0.25; i=$((i + 1)); done
grep -q "^0 *= *$home/Applications/Aqua Window.app$" "$work/cfg/recent.ini" 2>/dev/null \
  || fail "the Dock's launches were not recorded: $(cat "$work/cfg/recent.ini" 2>&1)"
title_at() { grep -F 'MenuBar: titles ' "$work/bar.log" | tail -1 | tr ' ' '\n' | grep "^$1@" | head -1 | cut -d@ -f2 | tr ',' ' '; }
item_line() {  # item_line MENU TITLE — the row TITLE after the last "opened MENU"
  awk -v m="MenuBar: opened $1" 'index($0, m) { buf = ""; on = 1; next }
       on && /MenuBar: item / { buf = buf $0 "\n"; next }
       on { on = 0 } END { printf "%s", buf }' "$work/bar.log" | grep -F "'$2'" | tail -1
}
xy_of() { printf '%s' "$1" | sed -n "s/.* at \([0-9]*\),\([0-9]*\) .*/\1 \2/p"; }
bar_count() { grep -c -- "$1" "$work/bar.log" 2>/dev/null || true; }
recent_open() {  # open System ▸ Recent Items
  n=$(bar_count 'MenuBar: opened System$'); s=$(bar_count 'MenuBar: opened submenu System > Recent Items')
  printf 'm %s\np\nr\n' "$(title_at System)" >&3; sleep 0.6
  [ "$(bar_count 'MenuBar: opened System$')" -gt "$n" ] || fail "the System menu did not open"
  r=$(item_line System "Recent Items")
  case "$r" in *" enabled submenu") ;; *) fail "Recent Items is not an enabled submenu: '$r'" ;; esac
  printf 'm %s\n' "$(xy_of "$r")" >&3; sleep 0.6
  [ "$(bar_count 'MenuBar: opened submenu System > Recent Items')" -gt "$s" ] || fail "hovering Recent Items opened nothing"
  ry=$(xy_of "$r"); ry=${ry#* }
}
choose_recent() {  # choose_recent TITLE — across level with the row, then down to TITLE
  row=$(item_line "submenu System > Recent Items" "$1")
  [ -n "$row" ] || fail "Recent Items has no '$1': $(grep 'MenuBar: item' "$work/bar.log" | tail -4)"
  set -- $(xy_of "$row")
  printf 'm %s %s\n' "$1" "$ry" >&3; sleep 0.3
  printf 'm %s %s\np\nr\n' "$1" "$2" >&3; sleep 0.8
}
recent_open
w=$(grep -c '^window org.abyssbsd.aquademo/' "$work/ut.out" || true)
choose_recent "Aqua Window"
grep -q "chose System > Recent Items > Aqua Window (system.recent.0) → ok $home/Applications/Aqua Window.app" "$work/bar.log" \
  || fail "choosing Aqua Window: $(grep 'chose' "$work/bar.log" | tail -1)"
i=0; until [ "$(grep -c '^window org.abyssbsd.aquademo/' "$work/ut.out" || true)" -gt "$w" ]; do
  [ $i -ge 150 ] && fail "Recent Items launched nothing that mapped"; sleep 0.1; i=$((i + 1)); done
recent_open
choose_recent "Clear Menu"
[ "$(tail -1 "$work/displays")" = "$wd" ] || fail "Recent Items launched on '$(tail -1 "$work/displays")', not the ordinary display $wd"
grep -q 'chose System > Recent Items > Clear Menu (system.recent.clear) → ok' "$work/bar.log" || fail "Clear Menu did not run"
grep -q '=' "$work/cfg/recent.ini" 2>/dev/null && fail "Clear Menu left: $(cat "$work/cfg/recent.ini")"
echo "ok: 10. Recent Items listed what the Dock opened, opened it again on the ordinary display, and Clear Menu emptied it"

echo "all green (the Dock carries installed applications)."
