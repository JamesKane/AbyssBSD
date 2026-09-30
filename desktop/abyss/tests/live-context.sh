#!/bin/sh
# AbyssBSD Swift DE — the menus the desktop owns (P10.8).
#
# Contextual menus are the same commands the menu bar shows, at the pointer;
# the system menu's items do what they say. On our own compositor, with a real
# pointer, each checked on the thing:
#
#   1. Right-click an item in a Finder window: it is selected, and its menu
#      offers the Finder's own commands. Duplicate makes a copy **on disk**.
#   2. Right-click the folder's background: New Folder makes one **on disk**.
#   3. System ▸ About This Computer posts a notification — the notification
#      centre's own log says it arrived, with the machine in it.
#   4. System ▸ Force Quit <frontmost> kills the frontmost application's
#      process: **the process is gone**, and the compositor says which pid.
#   5. System ▸ System Preferences opens a System Preferences window, which the
#      compositor saw map.
#
# No coordinates for menu rows here: the app logs where each row is inside its
# popup, and the compositor logs where the popup landed (§2.46).
#
# Usage: abyss/tests/live-context.sh
set -eu

root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"
. "$root/abyss/common.sh"
abyss_ensure_runtime_dir

undertow="$root/.build/debug/undertow"
aqua="$root/.build/debug/AquaDemo"
[ -x "$undertow" ] && [ -x "$aqua" ] || swift build
command -v wayland-scanner >/dev/null || { echo "SKIP: no wayland-scanner"; exit 0; }

work=$(mktemp -d /tmp/abyss-ctx.XXXXXX)
rundir=$(mktemp -d /tmp/abyss-ctxr.XXXXXX)
priv="abyss-cbar-$$"
cleanup() {
  exec 3>&- 2>/dev/null || true
  for p in ${vp_pid:-} ${victim_pid:-} ${finder_pid:-} ${notify_pid:-} ${bar_pid:-} ${ut_pid:-}; do
    kill "$p" 2>/dev/null || true
  done
  [ -s "$work/prefs.pid" ] && kill "$(cat "$work/prefs.pid")" 2>/dev/null || true
  rm -rf "$work" "$rundir" 2>/dev/null || true
}
trap cleanup EXIT INT TERM HUP
fail() { echo "FAIL: $1"; exit 1; }
export ABYSS_RUNTIME_DIR="$rundir"

count() { grep -cF "$2" "$1" 2>/dev/null || true; }
after() {  # after FILE STRING N WHAT
  i=0
  while [ $i -lt 50 ]; do
    [ "$(count "$1" "$2")" -gt "$3" ] && return 0
    sleep 0.2; i=$((i + 1))
  done
  fail "$4 — $(tail -3 "$1")"
}

dir="$work/files"
mkdir -p "$dir" "$work/cfg" "$work/home/.Trash"
printf 'hello\n' > "$dir/Read Me.txt"

env -u WAYLAND_DISPLAY "$undertow" run --frames 0 --width 800 --height 600 \
    --config-dir "$work/cfg" --privileged-socket "$priv" \
    > "$work/ut.out" 2> "$work/ut.err" &
ut_pid=$!
after "$work/ut.out" "WAYLAND_PRIVILEGED=$priv" 0 "undertow never came up"
wd=$(grep -m1 '^WAYLAND_DISPLAY=' "$work/ut.out" | cut -d= -f2-)

# The bar (whose exclusive zone moves windows down 22px), the notification
# centre About posts to, and a Finder.
# What the bar launches for System Preferences: AquaDemo, through a wrapper that
# records its pid — the launch is detached, and this test must clean it up.
printf '#!/bin/sh\necho $$ > "%s/prefs.pid"\necho "$WAYLAND_DISPLAY" > "%s/prefs.display"\nexec "%s" "$@"\n' "$work" "$work" "$aqua" > "$work/prefs.sh"
chmod +x "$work/prefs.sh"
env WAYLAND_DISPLAY="$priv" ABYSS_CONFIG_DIR="$work/cfg" AQUA_SCENE=menubar \
    ABYSS_APP_BINARY="$work/prefs.sh" ABYSS_APP_WAYLAND_DISPLAY="$wd" \
    "$aqua" > "$work/bar.log" 2>&1 &
bar_pid=$!
after "$work/bar.log" "MenuBar: frontmost: nothing" 0 "the bar never came up"
env WAYLAND_DISPLAY="$wd" ABYSS_CONFIG_DIR="$work/cfg" AQUA_SCENE=notify \
    "$aqua" > "$work/notify.log" 2>&1 &
notify_pid=$!
env WAYLAND_DISPLAY="$wd" ABYSS_CONFIG_DIR="$work/cfg" HOME="$work/home" \
    ABYSS_FINDER_DIR="$dir" AQUA_SCENE=finder "$aqua" > "$work/finder.log" 2>&1 &
finder_pid=$!
after "$work/bar.log" "showing Finder's menus" 0 "the Finder never became frontmost"

xml="$root/abyss/tests/wlr-virtual-pointer-unstable-v1.xml"
wayland-scanner client-header "$xml" "$work/vpointer-proto.h"
wayland-scanner private-code  "$xml" "$work/vpointer-proto.c"
cc -I"$work" "$root/abyss/tests/vpointer.c" "$work/vpointer-proto.c" \
   $(pkg-config --cflags --libs wayland-client) -o "$work/vpointer" || fail "no vpointer"
mkfifo "$work/pointer"
env WAYLAND_DISPLAY="$wd" "$work/vpointer" 800 600 < "$work/pointer" > "$work/vp.log" 2>&1 &
vp_pid=$!
exec 3> "$work/pointer"
sleep 1

# The popup's on-screen origin, as the compositor placed it (the latest).
popup_origin() { grep 'undertow: popup mapped at' "$work/ut.err" | tail -1 | sed 's/.* at \([0-9]*\),\([0-9]*\) .*/\1 \2/'; }
# A row's offset inside the popup, from the app's log.
row_offset() { grep -F "context item '$2' at" "$1" | tail -1 | sed 's/.* at +\([0-9]*\),+\([0-9]*\) .*/\1 \2/'; }
click_row() {  # click_row LOG TITLE — left-click a row of the open context menu
  set -- $(popup_origin) $(row_offset "$1" "$2")
  [ $# = 4 ] || fail "no geometry for that row"
  printf 'm %s %s\np\nr\n' $(($1 + $3)) $(($2 + $4)) >&3
  sleep 0.5
}
right_click() { printf 'm %s %s\nP\nR\n' "$1" "$2" >&3; sleep 0.6; }

# ------------------------------------------------ 1. an item's menu: Duplicate
# The Finder's 520x400 is centred in the usable area — 800x578 under the bar —
# at (140, 111); its first icon cell's centre is local (54, 96).
n=$(count "$work/ut.err" "popup mapped at")
right_click 194 207
grep -q 'Finder: selected Read Me.txt' "$work/finder.log" \
  || fail "the right-click did not select Read Me.txt: $(tail -3 "$work/finder.log")"
after "$work/ut.err" "popup mapped at" "$n" "right-clicking an item opened no menu"
case "$(grep -F "context item 'Duplicate'" "$work/finder.log" | tail -1)" in
  *" enabled file.duplicate") ;;
  *) fail "the item menu has no enabled Duplicate: $(grep 'context item' "$work/finder.log" | tail -8)" ;;
esac
grep -q "context item 'Get Info' at .* disabled file.get-info" "$work/finder.log" \
  || fail "Get Info should be drawn, disabled — it is in the menu bar, so it is here"
click_row "$work/finder.log" Duplicate
after "$work/finder.log" "context chose Duplicate (file.duplicate) → ok $dir/Read Me copy.txt" 0 \
  "choosing Duplicate from the item's menu did nothing"
[ -f "$dir/Read Me copy.txt" ] || fail "Duplicate said ok and there is no copy on disk"
echo "ok: an item's menu is the Finder's commands — Duplicate made 'Read Me copy.txt' on disk"

# ------------------------------------------- 2. the background's: New Folder
n=$(count "$work/ut.err" "popup mapped at")
right_click 500 450
after "$work/ut.err" "popup mapped at" "$n" "right-clicking the background opened no menu"
grep -q 'context menu folder' "$work/finder.log" || fail "that was not the folder's menu"
click_row "$work/finder.log" "New Folder"
after "$work/finder.log" "context chose New Folder (file.new-folder) → ok $dir/untitled folder" 0 \
  "New Folder from the background's menu did nothing"
[ -d "$dir/untitled folder" ] || fail "New Folder said ok and there is no folder"
echo "ok: the background's menu — New Folder made one on disk"

# ------------------------------------------------ the bar's rows, by position
title_at() {
  grep -F 'MenuBar: titles ' "$work/bar.log" | tail -1 | tr ' ' '\n' \
    | grep "^$1@" | head -1 | cut -d@ -f2 | tr ',' ' '
}
item_line() {
  awk -v m="MenuBar: opened $1" 'index($0, m) { buf = ""; on = 1; next }
       on && /MenuBar: item / { buf = buf $0 "\n"; next }
       on { on = 0 } END { printf "%s", buf }' "$work/bar.log" | grep -F "'$2" | tail -1
}
system_item() {  # system_item TITLE-PREFIX — open System and click that row
  n=$(count "$work/bar.log" "MenuBar: opened System")
  printf 'm %s %s\np\nr\n' $(title_at System) >&3; sleep 0.5
  after "$work/bar.log" "MenuBar: opened System" "$n" "the System menu did not open"
  line=$(item_line System "$1")
  xy=$(echo "$line" | sed -n "s/.* at \([0-9]*\),\([0-9]*\) .*/\1 \2/p")
  [ -n "$xy" ] || fail "the System menu has no '$1' row"
  case "$line" in *" enabled "*) ;; *) fail "'$1' is not enabled: $line" ;; esac
  printf 'm %s %s\np\nr\n' $xy >&3; sleep 0.5
}

# ------------------------------------------------------------- 3. About
system_item "About This Computer"
after "$work/notify.log" "posted #1: About This Computer" 0 \
  "About This Computer never reached the notification centre"
grep -q "chose System > About This Computer (system.about) → ok .* CPUs, .* GB memory" "$work/bar.log" \
  || fail "About did not say what machine this is: $(grep 'system.about' "$work/bar.log" | tail -1)"
echo "ok: About This Computer — $(grep 'system.about' "$work/bar.log" | tail -1 | sed 's/.*→ ok //')"

# ------------------------------------------------------- 4. Force Quit
env WAYLAND_DISPLAY="$wd" ABYSS_CONFIG_DIR="$work/cfg" AQUA_SCENE=widgets \
    "$aqua" > "$work/victim.log" 2>&1 &
victim_pid=$!
after "$work/bar.log" "frontmost: org.abyssbsd.aquademo" 0 "the victim never became frontmost"
system_item "Force Quit aquademo"
after "$work/ut.err" "force quit org.abyssbsd.aquademo: killed $victim_pid" 0 \
  "the compositor did not kill the frontmost application"
i=0
while [ $i -lt 25 ] && kill -0 "$victim_pid" 2>/dev/null; do sleep 0.2; i=$((i + 1)); done
kill -0 "$victim_pid" 2>/dev/null && fail "Force Quit said it killed $victim_pid and it is alive"
victim_pid=""
kill -0 "$finder_pid" 2>/dev/null || fail "Force Quit killed the Finder too"
echo "ok: Force Quit aquademo — the process is gone, and only that one"

# ------------------------------------------------- 5. System Preferences
focused_before=$(count "$work/ut.err" "focused org.abyssbsd.preferences")
system_item "System Preferences"
after "$work/bar.log" "chose System > System Preferences… (system.preferences) → ok" 0 \
  "System Preferences was not started"
i=0
while [ $i -lt 25 ] && [ ! -s "$work/prefs.pid" ]; do sleep 0.2; i=$((i + 1)); done
[ -s "$work/prefs.pid" ] || fail "nothing was launched"
kill -0 "$(cat "$work/prefs.pid")" 2>/dev/null || fail "System Preferences started and died"
# Its window maps and takes focus — the compositor says System Preferences is
# frontmost. It has been an application of its own, `org.abyssbsd.preferences`,
# since P14.1; this waited for `org.abyssbsd.aquademo` until 2026-09-28, and
# failed from P14.1 on without anyone running it.
after "$work/ut.err" "focused org.abyssbsd.preferences" "$focused_before" \
  "no System Preferences window ever became frontmost"
[ "$(cat "$work/prefs.display")" = "$wd" ] \
  || fail "System Preferences was launched on '$(cat "$work/prefs.display")', not the ordinary display — a child of the bar must never inherit its privilege"
echo "ok: System Preferences opened a window the compositor made frontmost — on the ordinary display, not the bar's"

echo "all green (contextual menus are the menu bar's commands; the system menu does what it says)."
