#!/bin/sh
# AbyssBSD Swift DE — submenus open (PHASE10 P10.8, BACKLOG).
#
# The bar drew a submenu's ▸ from P10.1 and nothing ever opened one; every
# application's menus were one level deep. `gtkmenu`, a stock GtkApplication
# (the other end never ours, §2.39), is given File ▸ Export ▸ (As PNG, As PDF
# — disabled — and More ▸ As SVG) with GTKMENU_SUBMENUS=1. With a real
# pointer and keyboard, through undertow:
#
#   1. File's Export row is drawn as a submenu, and hovering it opens its
#      menu beside it — As PNG, As PDF disabled because GTK disabled it, More;
#   2. As PNG, chosen in the submenu, runs in GTK's process;
#   3. two deep: More opens beside Export, and As SVG runs;
#   4. a disabled row in a submenu cannot be chosen, and the menu stays open;
#   5. the keyboard: ↓ to Export, → opens it with its first row highlighted,
#      ← closes it again, → and Return choose As PNG;
#   6. Escape from inside a submenu closes the whole menu, and a click outside
#      a two-deep chain takes all of it down — the bar alive and able to open
#      File again, so no popup was destroyed out of order (a protocol error).
#
# Usage: abyss/tests/live-submenus.sh      (skips, loudly, with no GTK runtime)
set -eu

root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"
. "$root/abyss/common.sh"
abyss_ensure_runtime_dir

undertow="$root/.build/debug/undertow"
aqua="$root/.build/debug/AquaDemo"
bridge="$root/.build/debug/abyss-dbus"
[ -x "$undertow" ] && [ -x "$aqua" ] && [ -x "$bridge" ] || swift build
command -v dbus-daemon >/dev/null || { echo "SKIP: no dbus-daemon"; exit 0; }
command -v wayland-scanner >/dev/null || { echo "SKIP: no wayland-scanner"; exit 0; }

work=$(mktemp -d /tmp/abyss-msub.XXXXXX)
rundir=$(mktemp -d /tmp/abyss-msur.XXXXXX)
priv="abyss-sbar-$$"
cleanup() {
  exec 3>&- 4>&- 2>/dev/null || true
  for p in ${vk_pid:-} ${vp_pid:-} ${app_pid:-} ${br_pid:-} ${bar_pid:-} ${ut_pid:-} ${bus_pid:-}; do
    kill "$p" 2>/dev/null || true
  done
  rm -rf "$work" "$rundir" 2>/dev/null || true
}
trap cleanup EXIT INT TERM HUP
fail() { echo "FAIL: $1"; exit 1; }
export ABYSS_RUNTIME_DIR="$rundir"

count() { grep -cF "$2" "$1" 2>/dev/null || true; }
after() {  # after FILE STRING N WHAT
  i=0
  while [ $i -lt 60 ]; do
    [ "$(count "$1" "$2")" -gt "$3" ] && return 0
    sleep 0.2; i=$((i + 1))
  done
  fail "$4 — $(tail -3 "$1")"
}

# ---------------------------------------------------------------- the app
cc -O0 "$root/abyss/tests/gtkmenu.c" -ldl -o "$work/gtkmenu" || fail "could not build gtkmenu"
xml="$root/abyss/tests/wlr-virtual-pointer-unstable-v1.xml"
wayland-scanner client-header "$xml" "$work/vpointer-proto.h"
wayland-scanner private-code  "$xml" "$work/vpointer-proto.c"
cc -I"$work" "$root/abyss/tests/vpointer.c" "$work/vpointer-proto.c" \
   $(pkg-config --cflags --libs wayland-client) -o "$work/vpointer" || fail "no vpointer"
xml="$root/abyss/tests/virtual-keyboard-unstable-v1.xml"
wayland-scanner client-header "$xml" "$work/vkeyboard-proto.h"
wayland-scanner private-code  "$xml" "$work/vkeyboard-proto.c"
cc -I"$work" "$root/abyss/tests/vkeyboard.c" "$work/vkeyboard-proto.c" \
   $(pkg-config --cflags --libs wayland-client xkbcommon) -o "$work/vkeyboard" || fail "no vkeyboard"

# ---------------------------------------------------------------- the bus
# Nothing activatable: every process on it is one we started (live-gtk.sh).
cat > "$work/bus.conf" <<'EOF'
<!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-BUS Bus Configuration 1.0//EN"
 "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
<busconfig>
  <type>session</type>
  <listen>unix:tmpdir=/tmp</listen>
  <policy context="default">
    <allow send_destination="*" eavesdrop="true"/>
    <allow eavesdrop="true"/>
    <allow own="*"/>
  </policy>
</busconfig>
EOF
busaddr=$(dbus-daemon --config-file="$work/bus.conf" --fork \
          --print-address=1 --print-pid=3 3>"$work/buspid")
bus_pid=$(cat "$work/buspid")
export DBUS_SESSION_BUS_ADDRESS="$busaddr"

# ---------------------------------------------- compositor, bridge, bar
mkdir -p "$work/cfg"
env -u WAYLAND_DISPLAY "$undertow" run --frames 0 --width 800 --height 600 \
    --config-dir "$work/cfg" --privileged-socket "$priv" \
    > "$work/ut.out" 2> "$work/ut.err" &
ut_pid=$!
after "$work/ut.out" "WAYLAND_PRIVILEGED=$priv" 0 "undertow never came up"
wd=$(grep -m1 '^WAYLAND_DISPLAY=' "$work/ut.out" | cut -d= -f2-)

"$bridge" --menus > "$work/bridge.log" 2>&1 &
br_pid=$!
after "$work/bridge.log" "ready (menus: menus-dbus)" 0 "the menu bridge never came up"

env WAYLAND_DISPLAY="$priv" ABYSS_CONFIG_DIR="$work/cfg" AQUA_SCENE=menubar \
    "$aqua" > "$work/bar.log" 2>&1 &
bar_pid=$!
after "$work/bar.log" "MenuBar: frontmost: nothing" 0 "the bar never came up"

# ---------------------------------------------------------- the stock app
env WAYLAND_DISPLAY="$wd" GDK_BACKEND=wayland GTKMENU_SUBMENUS=1 "$work/gtkmenu" \
    > "$work/app.out" 2> "$work/app.err" &
app_pid=$!
i=0
while [ $i -lt 50 ]; do
  grep -q '^ready' "$work/app.out" 2>/dev/null && break
  kill -0 "$app_pid" 2>/dev/null || {
    grep -q 'libgtk-3' "$work/app.err" && { echo "SKIP: no GTK 3 runtime"; exit 0; }
    fail "gtkmenu exited: $(cat "$work/app.err")"; }
  sleep 0.2; i=$((i + 1))
done


after "$work/bar.log" "showing MenuSpike's menus from menus-dbus (GTK)" 0 \
  "the bar never showed the GTK application's menus"

# ---------------------------------------------------------- the pointer, the keys
mkfifo "$work/pointer" "$work/keys"
env WAYLAND_DISPLAY="$wd" "$work/vpointer" 800 600 < "$work/pointer" > "$work/vp.log" 2>&1 &
vp_pid=$!
exec 3> "$work/pointer"
env WAYLAND_DISPLAY="$wd" "$work/vkeyboard" < "$work/keys" > "$work/vk.log" 2>&1 &
vk_pid=$!
exec 4> "$work/keys"
sleep 1
title_at() {
  grep -F 'MenuBar: titles ' "$work/bar.log" | tail -1 | tr ' ' '\n' \
    | grep "^$1@" | head -1 | cut -d@ -f2 | tr ',' ' '
}
# The last-logged row called TITLE after the last "opened MENU" line.
item_line() {
  awk -v m="MenuBar: opened $1" 'index($0, m) == 1 || index($0, "MenuBar: opened " substr(m, 17)) { buf = ""; on = 1; next }
       on && /MenuBar: item / { buf = buf $0 "\n"; next }
       on { on = 0 } END { printf "%s", buf }' "$work/bar.log" | grep -F "'$2'" | tail -1
}
xy_of() { printf '%s' "$1" | sed -n "s/.* at \([0-9]*\),\([0-9]*\) .*/\1 \2/p"; }
move() { printf 'm %s %s\n' "$1" "$2" >&3; sleep 0.3; }
click() { printf 'm %s %s\np\nr\n' "$1" "$2" >&3; sleep 0.5; }
key() { printf 'k %s\n' "$1" >&4; sleep 0.25; }
open_menu() {
  local_n=$(count "$work/bar.log" "MenuBar: opened $1")
  click $(title_at "$1")
  after "$work/bar.log" "MenuBar: opened $1" "$local_n" "clicking $1 opened nothing"
}
alive() {
  kill -0 "$bar_pid" 2>/dev/null || fail "the bar died ($1): $(grep -i -m2 'error\|protocol' "$work/bar.log")"
  kill -0 "$app_pid" 2>/dev/null || fail "gtkmenu died ($1)"
}

# ------------------------------------------------------ 1. hover opens it
open_menu File
exp=$(item_line File Export)
case "$exp" in *" enabled submenu") ;; *) fail "File's Export row is not an enabled submenu: '$exp'" ;; esac
n=$(count "$work/bar.log" "MenuBar: opened submenu File > Export")
move $(xy_of "$exp")
after "$work/bar.log" "MenuBar: opened submenu File > Export" "$n" "hovering Export opened no submenu"
png=$(item_line "submenu File > Export" "As PNG"); pdf=$(item_line "submenu File > Export" "As PDF")
more=$(item_line "submenu File > Export" "More")
case "$png" in *" enabled app.export-png") ;; *) fail "As PNG: '$png'" ;; esac
case "$pdf" in *" disabled app.export-pdf") ;; *) fail "As PDF should be disabled, as GTK has it: '$pdf'" ;; esac
case "$more" in *" enabled submenu") ;; *) fail "More: '$more'" ;; esac
# With Export open, the pointer still reaches File itself: another row
# closes the submenu, and Export again opens it.
c=$(count "$work/bar.log" "MenuBar: closed submenu File > Export")
move $(xy_of "$(item_line File Quit)")
after "$work/bar.log" "MenuBar: closed submenu File > Export" "$c" "hovering Quit, below Export, did not close the submenu"
o=$(count "$work/bar.log" "MenuBar: opened submenu File > Export")
move $(xy_of "$exp")
after "$work/bar.log" "MenuBar: opened submenu File > Export" "$o" "hovering Export again did not reopen it"
echo "ok: 1. hovering File ▸ Export opened it beside the row: As PNG, As PDF (disabled, as GTK has it), More ▸; hovering Quit closed it, Export reopened it"

# ------------------------------------------------------ 2. chosen, in GTK
ex=$(xy_of "$exp"); px=$(xy_of "$png")
move ${px% *} ${ex#* }                                  # across, level with Export, into the submenu
click $px
after "$work/app.out" "activated=export-png" 0 "choosing As PNG in the submenu never reached GTK"
grep -q "chose File > Export > As PNG (app.export-png) → ok" "$work/bar.log" \
  || fail "the bar did not log the choice: $(grep 'chose' "$work/bar.log" | tail -1)"
alive "after a choice in a submenu"
echo "ok: 2. As PNG, chosen in the submenu, ran in GTK's process"

# ------------------------------------------------------ 3. two deep
open_menu File
exp=$(item_line File Export); move $(xy_of "$exp")
after "$work/bar.log" "MenuBar: opened submenu File > Export" 1 "Export did not open a second time"
more=$(item_line "submenu File > Export" "More"); ex=$(xy_of "$exp"); mx=$(xy_of "$more")
move ${mx% *} ${ex#* }; move $mx
after "$work/bar.log" "MenuBar: opened submenu File > Export > More" 0 "hovering More opened nothing"
svg=$(item_line "submenu File > Export > More" "As SVG")
case "$svg" in *" enabled app.export-svg") ;; *) fail "As SVG: '$svg'" ;; esac
sx=$(xy_of "$svg")
move ${sx% *} ${mx#* }; click $sx
after "$work/app.out" "activated=export-svg" 0 "choosing As SVG, two deep, never reached GTK"
alive "after a choice two deep"
echo "ok: 3. two deep: More opened beside Export, and As SVG ran in GTK"

# ------------------------------------------------------ 4. disabled
open_menu File
exp=$(item_line File Export); move $(xy_of "$exp")
after "$work/bar.log" "MenuBar: opened submenu File > Export" 2 "Export did not open a third time"
pdf=$(item_line "submenu File > Export" "As PDF"); ex=$(xy_of "$exp"); dx=$(xy_of "$pdf")
move ${dx% *} ${ex#* }; click $dx
sleep 0.5
grep -q 'activated=export-pdf' "$work/app.out" && fail "a disabled row in a submenu was chosen"
c=$(count "$work/bar.log" "MenuBar: closed")
click 700 400                                           # outside: the whole chain goes
after "$work/bar.log" "MenuBar: closed" "$c" "a click outside the open submenu did not close the menu"
alive "after an outside click with a submenu open"
echo "ok: 4. As PDF, disabled, could not be chosen and the menu stayed open; a click outside closed the whole chain"

# ------------------------------------------------------ 5. the keyboard
pngs=$(count "$work/app.out" "activated=export-png")   # not $n: open_menu sets that
open_menu File
key 108; key 108; key 108                               # ↓ ↓ ↓: New, Open…, Export
s=$(count "$work/bar.log" "MenuBar: opened submenu File > Export")
key 106                                                 # →
after "$work/bar.log" "MenuBar: opened submenu File > Export" "$s" "→ on Export opened no submenu"
key 105                                                 # ←: closed again
key 106                                                 # →: open, first row highlighted
after "$work/bar.log" "MenuBar: opened submenu File > Export" "$((s + 1))" "← then → did not reopen Export"
key 28                                                  # Return: As PNG
after "$work/app.out" "activated=export-png" "$pngs" "Return in the submenu (As PNG highlighted by →) never reached GTK"
alive "after the keyboard"
echo "ok: 5. the keyboard: ↓ to Export, → opened it, ← closed it, → and Return chose As PNG"

# ------------------------------------------------------ 6. Escape, two deep
open_menu File
exp=$(item_line File Export); move $(xy_of "$exp")
more=$(item_line "submenu File > Export" "More"); ex=$(xy_of "$exp"); mx=$(xy_of "$more")
m2=$(count "$work/bar.log" "MenuBar: opened submenu File > Export > More")
move ${mx% *} ${ex#* }; move $mx
after "$work/bar.log" "MenuBar: opened submenu File > Export > More" "$m2" "More did not open"
c=$(count "$work/bar.log" "MenuBar: closed")
key 1                                                   # Escape, from two deep
after "$work/bar.log" "MenuBar: closed" "$c" "Escape inside a submenu did not close the menu"
alive "after Escape two deep"
open_menu File
alive "opening File again"
echo "ok: 6. Escape two deep closed the whole menu, and the bar opened File again — no popup was left or destroyed out of order"

echo "all green (submenus open: by pointer and keyboard, two deep, through undertow)."
