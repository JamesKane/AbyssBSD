#!/bin/sh
# AbyssBSD Swift DE — a Qt/KDE application's menus, in our menu bar (P10.7).
#
# The other end is **stock kcalc** — KDE's calculator, from the distribution,
# nothing of ours. Between it and the bar: `abyss-dbus --menus` owning
# `com.canonical.AppMenu.Registrar` (without it Qt exports nothing), undertow
# answering `org_kde_kwin_appmenu` (so Qt says where its menu is), and the same
# bridge reading `com.canonical.dbusmenu` and serving it as MenuWire. On the
# thing each time:
#
#   1. undertow recorded kcalc's dbusmenu address against its surface.
#   2. The bar shows **kcalc's** menus — File, Edit, Settings.
#   3. **Its shortcuts arrive**, as the keys that work: Undo is ⌃Z (Qt listens
#      for Ctrl; ⌘Z would draw a key that does nothing).
#   4. Choosing Settings ▸ Science Mode with a real pointer **switches kcalc's
#      mode**, which kcalc itself reports afterwards: its own layout says the
#      radio item is now on.
#   5. The bar follows kcalc's menus changing (P10.9): Science Mode adds
#      Constants, and it appears with no focus change. A Qt submenu opens
#      (P10.8): its first opens beside its row, and a constant chosen runs.
#
# Usage: abyss/tests/live-menus-qt.sh      (skips, loudly, without kcalc)
set -eu

root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"
. "$root/abyss/common.sh"
abyss_ensure_runtime_dir

undertow="$root/.build/debug/undertow"
aqua="$root/.build/debug/AquaDemo"
bridge="$root/.build/debug/abyss-dbus"
[ -x "$undertow" ] && [ -x "$aqua" ] && [ -x "$bridge" ] || swift build
command -v kcalc >/dev/null || { echo "SKIP: no kcalc (the stock Qt application this test drives)"; exit 0; }
command -v dbus-daemon >/dev/null || { echo "SKIP: no dbus-daemon"; exit 0; }
command -v gdbus >/dev/null || { echo "SKIP: no gdbus (the independent witness)"; exit 0; }
command -v wayland-scanner >/dev/null || { echo "SKIP: no wayland-scanner"; exit 0; }

work=$(mktemp -d /tmp/abyss-mqt.XXXXXX)
rundir=$(mktemp -d /tmp/abyss-mqr.XXXXXX)
priv="abyss-qbar-$$"
cleanup() {
  exec 3>&- 2>/dev/null || true
  for p in ${vp_pid:-} ${app_pid:-} ${br_pid:-} ${bar_pid:-} ${ut_pid:-} ${bus_pid:-}; do
    kill "$p" 2>/dev/null || true
  done
  rm -rf "$work" "$rundir" 2>/dev/null || true
}
trap cleanup EXIT INT TERM HUP
fail() { echo "FAIL: $1"; exit 1; }
export ABYSS_RUNTIME_DIR="$rundir"
export XDG_CONFIG_HOME="$work/xdg"   # kcalc's settings, not the user's

count() { grep -cF "$2" "$1" 2>/dev/null || true; }
after() {  # after FILE STRING N WHAT
  i=0
  while [ $i -lt 75 ]; do
    [ "$(count "$1" "$2")" -gt "$3" ] && return 0
    sleep 0.2; i=$((i + 1))
  done
  fail "$4 — $(tail -3 "$1")"
}

xml="$root/abyss/tests/wlr-virtual-pointer-unstable-v1.xml"
wayland-scanner client-header "$xml" "$work/vpointer-proto.h"
wayland-scanner private-code  "$xml" "$work/vpointer-proto.c"
cc -I"$work" "$root/abyss/tests/vpointer.c" "$work/vpointer-proto.c" \
   $(pkg-config --cflags --libs wayland-client) -o "$work/vpointer" || fail "no vpointer"

# A bus with nothing activatable (live-gtk.sh's reason).
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

mkdir -p "$work/cfg" "$work/xdg"
env -u WAYLAND_DISPLAY "$undertow" run --frames 0 --width 800 --height 600 \
    --config-dir "$work/cfg" --privileged-socket "$priv" \
    > "$work/ut.out" 2> "$work/ut.err" &
ut_pid=$!
after "$work/ut.out" "WAYLAND_PRIVILEGED=$priv" 0 "undertow never came up"
wd=$(grep -m1 '^WAYLAND_DISPLAY=' "$work/ut.out" | cut -d= -f2-)

# The registrar must be owned BEFORE kcalc starts: Qt decides at startup.
"$bridge" --menus > "$work/bridge.log" 2>&1 &
br_pid=$!
after "$work/bridge.log" "ready (menus: menus-dbus)" 0 "the menu bridge never came up"

env WAYLAND_DISPLAY="$priv" ABYSS_CONFIG_DIR="$work/cfg" AQUA_SCENE=menubar \
    "$aqua" > "$work/bar.log" 2>&1 &
bar_pid=$!
after "$work/bar.log" "MenuBar: frontmost: nothing" 0 "the bar never came up"

env WAYLAND_DISPLAY="$wd" QT_QPA_PLATFORM=wayland kcalc > "$work/app.out" 2>&1 &
app_pid=$!

# 1. undertow knows where kcalc's menu is.
after "$work/ut.err" "[dbusmenu]" 0 "kcalc never told undertow where its menu is"
addr=$(grep 'a surface published its menus at .* \[dbusmenu\]' "$work/ut.err" | tail -1 \
       | sed 's/.* published its menus at \(.*\) \[dbusmenu\]/\1/')
svc=${addr% *}; path=${addr#* }
echo "ok: undertow recorded kcalc's dbusmenu at $svc $path"

# 2. The bar shows kcalc's menus.
after "$work/bar.log" "showing kcalc's menus from menus-dbus (Qt)" 0 \
  "the bar never showed kcalc's menus"
titles=$(grep -F 'MenuBar: titles ' "$work/bar.log" | tail -1)
case "$titles" in
  *" kcalc@"*" File@"*" Edit@"*" Settings@"*) echo "ok: the bar shows kcalc, File, Edit, Settings — kcalc's menus" ;;
  *) fail "the bar's titles are not kcalc's: $titles" ;;
esac

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

# 3. Qt's shortcuts arrive, as the keys that work.
open_menu Edit
case "$(item_line Edit Undo)" in
  *"'Undo' ⌃Z at "*) echo "ok: Undo shows ⌃Z — Qt's own shortcut, and the key kcalc listens for" ;;
  *) fail "Undo's row: '$(item_line Edit Undo)'" ;;
esac
click $(title_at Edit)

# 4. Settings ▸ Science Mode, by pointer, switches kcalc's mode.
state() {  # the toggle-state of Science Mode, in kcalc's own layout
  gdbus call --session -d "$svc" -o "$path" -m com.canonical.dbusmenu.GetLayout -- 0 -1 \
      "['label','toggle-state']" 2>/dev/null \
    | grep -o "'label': <'Science Mode'>, 'toggle-state': <[0-9]>\|'toggle-state': <[0-9]>, 'label': <'Science Mode'>" \
    | grep -o "toggle-state': <[0-9]" | grep -o '[0-9]$'
}
[ "$(state)" = 0 ] || fail "Science Mode was already on before we chose it ($(state))"
open_menu Settings
xy=$(item_line Settings "Science Mode" | sed -n "s/.* at \([0-9]*\),\([0-9]*\) .*/\1 \2/p")
[ -n "$xy" ] || fail "Settings has no Science Mode row"
click $xy
after "$work/bar.log" "chose Settings > Science Mode (settings.science-mode) → ok" 0 \
  "choosing Science Mode returned no result"
i=0
while [ $i -lt 25 ] && [ "$(state)" != 1 ]; do sleep 0.2; i=$((i + 1)); done
[ "$(state)" = 1 ] || fail "the bar said ok and kcalc's Science Mode is still off"
echo "ok: Settings ▸ Science Mode, chosen in our bar, switched kcalc — by kcalc's own account"

# 5. The bar follows kcalc's menus changing (P10.9), and a Qt submenu opens
#    (P10.8). Science Mode gives kcalc a Constants menu while it is frontmost;
#    the bridge hears dbusmenu's LayoutUpdated and the bar shows it, with no
#    focus change. Its rows are submenus Qt fills lazily (AboutToShow, §4.5):
#    the first opens beside its row, and a constant chosen from it runs.
grep -q 'menus-dbus: watching ' "$work/bridge.log" || fail "the bar never asked the bridge to watch kcalc: $(tail -3 "$work/bridge.log")"
i=0
while [ $i -lt 25 ] && ! grep -F 'MenuBar: titles ' "$work/bar.log" | tail -1 | grep -q ' Constants@'; do
  sleep 0.2; i=$((i + 1)); done
grep -F 'MenuBar: titles ' "$work/bar.log" | tail -1 | grep -q ' Constants@' \
  || fail "Science Mode added Constants to kcalc, and the bar never showed it: $(grep -F 'MenuBar: titles ' "$work/bar.log" | tail -1) — bridge: $(grep 'menus-dbus:' "$work/bridge.log" | tail -2 | tr '\n' ' ')"
grep -q "menus-dbus: .*'s menus changed; told 1 bar" "$work/bridge.log" \
  || fail "the bridge never said it pushed the change: $(grep 'menus-dbus:' "$work/bridge.log" | tail -2)"
grep -q "MenuBar: .*vocabulary changed; redescribed" "$work/bar.log" \
  || fail "the bar did not say it re-read kcalc's menus"
echo "ok: Science Mode added Constants, and the bar showed it without a focus change — the bridge heard kcalc's LayoutUpdated and told it"
open_menu Constants
sub=$(awk 'index($0, "MenuBar: opened Constants") { buf = ""; on = 1; next }
           on && /MenuBar: item / { buf = buf $0 "\n"; next } on { on = 0 }
           END { printf "%s", buf }' "$work/bar.log" | grep ' enabled submenu$' | head -1)
[ -n "$sub" ] || fail "Constants has no submenu row: $(grep -A4 'opened Constants' "$work/bar.log" | tail -4)"
title=$(printf '%s' "$sub" | sed -n "s/.*item '\([^']*\)'.*/\1/p")
sxy=$(printf '%s' "$sub" | sed -n "s/.* at \([0-9]*\),\([0-9]*\) .*/\1 \2/p")
printf 'm %s\n' "$sxy" >&3
after "$work/bar.log" "MenuBar: opened submenu Constants > $title" 0 "hovering Constants ▸ $title opened nothing"
first=$(awk -v m="MenuBar: opened submenu Constants > $title" 'index($0, m) { buf = ""; on = 1; next }
           on && /MenuBar: item / { buf = buf $0 "\n"; next } on { on = 0 }
           END { printf "%s", buf }' "$work/bar.log" | grep ' enabled ' | head -1)
[ -n "$first" ] || fail "$title's submenu has no enabled row"
fname=$(printf '%s' "$first" | sed -n "s/.*item '\([^']*\)'.*/\1/p")
fxy=$(printf '%s' "$first" | sed -n "s/.* at \([0-9]*\),\([0-9]*\) .*/\1 \2/p")
printf 'm %s %s\n' "${fxy% *}" "${sxy#* }" >&3; sleep 0.3     # across, level with the row
click $fxy
after "$work/bar.log" "chose Constants > $title > $fname" 0 "choosing $fname in Qt's submenu returned no result"
grep "chose Constants > $title > $fname" "$work/bar.log" | tail -1 | grep -q '→ ok' \
  || fail "kcalc did not take $fname: $(grep 'chose Constants' "$work/bar.log" | tail -1)"
kill -0 "$app_pid" 2>/dev/null || fail "kcalc died"
echo "ok: Constants ▸ $title, a Qt submenu, opened beside its row, and $fname ran in kcalc"
# Reading a Qt menu asks its lazy submenus to fill, which can make Qt announce
# a new layout: the bridge must not chase its own echo (P10.9).
sleep 2
quiet=$(grep -c 'signalled, and its menus are the same' "$work/bridge.log" || true)
[ "$quiet" -le 3 ] || fail "the bridge re-read kcalc $quiet times for nothing — an echo loop: $(grep 'menus-dbus:' "$work/bridge.log" | tail -3)"
echo "ok: settled — $(grep -c "menus changed; told" "$work/bridge.log") change pushed, $quiet quiet re-reads, no echo"

echo "all green (a Qt application's menus, in our bar, the other end never ours)."
