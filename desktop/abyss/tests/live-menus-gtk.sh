#!/bin/sh
# AbyssBSD Swift DE — a GTK application's menus, in our menu bar (P10.6).
#
# The other end is never ours (§2.39): `gtkmenu` is a stock GtkApplication,
# dlopen'd, whose menus are exported by GTK's own code. Between it and the bar:
# our compositor answering GTK's `gtk_shell1` (so GTK says where its menus are,
# and stops drawing its own), and `abyss-dbus --menus` reading them over the bus
# and serving them as MenuWire. What this proves, on the thing each time:
#
#   1. GTK was told the desktop shows a global menu bar, and **hid its own** —
#      its own setting, `gtk-shell-shows-menubar`, printed by the app.
#   2. undertow recorded where GTK's menus are, against its surface.
#   3. The bar shows **the GTK application's** menus: its name bold, File, Edit.
#   4. Paste is drawn disabled because **GTK** disabled it.
#   5. Choosing File ▸ Open… with a real pointer runs the action **in GTK's
#      process**, which says so in its own words.
#
# Usage: abyss/tests/live-menus-gtk.sh      (skips, loudly, with no GTK runtime)
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

work=$(mktemp -d /tmp/abyss-mgtk.XXXXXX)
rundir=$(mktemp -d /tmp/abyss-mgtr.XXXXXX)
priv="abyss-gbar-$$"
cleanup() {
  exec 3>&- 2>/dev/null || true
  for p in ${vp_pid:-} ${app_pid:-} ${br_pid:-} ${bar_pid:-} ${ut_pid:-} ${bus_pid:-}; do
    kill "$p" 2>/dev/null || true
  done
  rm -rf "$work" "$rundir"
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
env WAYLAND_DISPLAY="$wd" GDK_BACKEND=wayland "$work/gtkmenu" \
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

# 1. GTK hid its own menubar, by its own setting.
grep -q '^ready shows-menubar=1$' "$work/app.out" \
  || fail "GTK still draws its own menubar: $(cat "$work/app.out")"
echo "ok: GTK was told the desktop has a global menu bar, and hid its own"

# 2. undertow knows where GTK's menus are.
after "$work/ut.err" "/org/abyss/MenuSpike/menus/menubar" 0 \
  "undertow never heard where GTK's menus are"
echo "ok: undertow recorded GTK's menu address against its surface"

# 3. The bar shows the GTK application's menus.
after "$work/bar.log" "showing MenuSpike's menus from menus-dbus (GTK)" 0 \
  "the bar never showed the GTK application's menus"
titles=$(grep -F 'MenuBar: titles ' "$work/bar.log" | tail -1)
case "$titles" in
  *" MenuSpike@"*" File@"*" Edit@"*) echo "ok: the bar shows MenuSpike, File, Edit — GTK's menus" ;;
  *) fail "the bar's titles are not GTK's: $titles" ;;
esac

# ---------------------------------------------------------- the pointer
mkfifo "$work/pointer"
env WAYLAND_DISPLAY="$wd" "$work/vpointer" 800 600 < "$work/pointer" > "$work/vp.log" 2>&1 &
vp_pid=$!
exec 3> "$work/pointer"
sleep 1
title_at() {
  grep -F 'MenuBar: titles ' "$work/bar.log" | tail -1 | tr ' ' '\n' \
    | grep "^$1@" | head -1 | cut -d@ -f2 | tr ',' ' '
}
item_line() {
  awk -v m="MenuBar: opened $1" 'index($0, m) { buf = ""; on = 1; next }
       on && /MenuBar: item / { buf = buf $0 "\n"; next }
       on { on = 0 } END { printf "%s", buf }' "$work/bar.log" | grep -F "'$2'" | tail -1
}
click() { printf 'm %s %s\np\nr\n' "$1" "$2" >&3; sleep 0.5; }
open_menu() {
  n=$(count "$work/bar.log" "MenuBar: opened $1")
  click $(title_at "$1")
  after "$work/bar.log" "MenuBar: opened $1" "$n" "clicking $1 opened nothing"
}

# 4. Paste is disabled because GTK disabled it.
open_menu Edit
case "$(item_line Edit Paste)" in
  *" disabled app.paste") echo "ok: Paste is drawn disabled — GTK disabled the action" ;;
  *) fail "Paste: '$(item_line Edit Paste)'" ;;
esac
case "$(item_line Edit Copy)" in
  *" enabled app.copy") ;;
  *) fail "Copy should be enabled: '$(item_line Edit Copy)'" ;;
esac
click $(title_at Edit)

# 5. File ▸ Open…, by pointer, runs in GTK's process.
open_menu File
xy=$(item_line File "Open…" | sed -n "s/.* at \([0-9]*\),\([0-9]*\) .*/\1 \2/p")
[ -n "$xy" ] || fail "File has no Open… row"
click $xy
after "$work/app.out" "activated=open" 0 "choosing Open… never reached GTK"
grep -q "chose File > Open… (app.open) → ok" "$work/bar.log" \
  || fail "the bar did not log the result: $(grep 'chose' "$work/bar.log" | tail -1)"
echo "ok: File ▸ Open…, chosen in our bar, ran in GTK's process: $(grep activated "$work/app.out")"

echo "all green (a GTK application's menus, in our bar, the other end never ours)."
