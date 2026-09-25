#!/bin/sh
# AbyssBSD Swift DE — the menu bar is the frontmost application's (P10.4).
#
# Everything before this pass drew File/Edit/View for nobody. Now the bar asks
# the compositor who is frontmost (P10.3), asks that application what it can do
# (P10.2), asks it again what can run *as each menu opens*, and runs the verb a
# person chooses. This drives it with a real pointer on our own compositor,
# and every claim is checked on the thing (§2.44, §2.46):
#
#   1. The bar shows the **Finder's** menus, read from `menus.finder.<pid>`.
#   2. **Paste is drawn disabled** while the clipboard is empty — the bar asked,
#      and the Finder said no — and **enabled** after Edit ▸ Copy, chosen from
#      the bar, put something there. The same row, two answers, one question.
#   3. File ▸ New Folder, chosen with the pointer, makes a folder **on disk**,
#      and the bar logs the result the Finder returned, not the title it drew.
#   4. With no window left, the desktop is frontmost — and the desktop is the
#      Finder, so its menus stay (Jaguar's rule, through the compositor).
#
# No coordinates are written here. The bar publishes where its titles and rows
# are, and the script reads them (§2.46).
#
# Usage: abyss/tests/live-menus.sh
set -eu

root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"
. "$root/abyss/common.sh"
abyss_ensure_runtime_dir

undertow="$root/.build/debug/undertow"
aqua="$root/.build/debug/AquaDemo"
[ -x "$undertow" ] && [ -x "$aqua" ] || swift build
command -v wayland-scanner >/dev/null 2>&1 || { echo "note: no wayland-scanner, skipping"; exit 0; }

work=$(mktemp -d /tmp/abyss-menus.XXXXXX)
rundir=$(mktemp -d /tmp/abyss-menur.XXXXXX)
priv="abyss-bar-$$"
cleanup() {
  exec 3>&- 2>/dev/null || true
  exec 4>&- 2>/dev/null || true
  for p in ${vk_pid:-} ${vp_pid:-} ${finder_pid:-} ${desk_pid:-} ${bar_pid:-} ${ut_pid:-}; do
    kill "$p" 2>/dev/null || true
  done
  rm -rf "$work" "$rundir"
}
trap cleanup EXIT INT TERM HUP
fail() { echo "FAIL: $1"; exit 1; }
export ABYSS_RUNTIME_DIR="$rundir"

# count FILE STRING — how many lines contain it (fixed string).
count() { grep -cF "$2" "$1" 2>/dev/null || true; }
# after FILE STRING N WHAT — wait until STRING appears more than N times.
after() {
  i=0
  while [ $i -lt 60 ]; do
    [ "$(count "$1" "$2")" -gt "$3" ] && return 0
    sleep 0.2; i=$((i + 1))
  done
  fail "$4 — $(tail -4 "$1")"
}

dir="$work/files"
mkdir -p "$dir" "$work/cfg" "$work/home/.Trash" "$work/home/Desktop"
printf 'hello\n' > "$dir/Read Me.txt"

env -u WAYLAND_DISPLAY "$undertow" run --frames 0 --width 800 --height 600 \
    --config-dir "$work/cfg" --privileged-socket "$priv" \
    > "$work/ut.out" 2> "$work/ut.err" &
ut_pid=$!
after "$work/ut.out" "WAYLAND_PRIVILEGED=$priv" 0 "undertow never announced its privileged socket"
wd=$(grep -m1 '^WAYLAND_DISPLAY=' "$work/ut.out" | cut -d= -f2-)
echo "ok: undertow is up on $wd (bar on $priv)"

env WAYLAND_DISPLAY="$priv" ABYSS_CONFIG_DIR="$work/cfg" AQUA_SCENE=menubar \
    "$aqua" > "$work/bar.log" 2>&1 &
bar_pid=$!
after "$work/bar.log" "MenuBar: frontmost: nothing" 0 "the bar never heard from the compositor"

env WAYLAND_DISPLAY="$wd" ABYSS_CONFIG_DIR="$work/cfg" HOME="$work/home" \
    ABYSS_FINDER_DIR="$dir" AQUA_SCENE=finder "$aqua" > "$work/finder.log" 2>&1 &
finder_pid=$!
addr="menus.finder.$finder_pid"
after "$work/bar.log" "showing Finder's menus from $addr" 0 "the bar never showed the Finder's menus"
echo "ok: $(grep -F "showing Finder's menus" "$work/bar.log" | tail -1 | sed 's/^MenuBar: //')"
# The key column's glyphs are in some face, or the bar says so (§2.45).
grep -q 'NO GLYPHS' "$work/bar.log" \
  && fail "the bar cannot draw its key equivalents: $(grep 'NO GLYPHS' "$work/bar.log")"

# ---------------------------------------------------------------- the pointer
xml="$root/abyss/tests/wlr-virtual-pointer-unstable-v1.xml"
wayland-scanner client-header "$xml" "$work/vpointer-proto.h"
wayland-scanner private-code  "$xml" "$work/vpointer-proto.c"
cc -I"$work" "$root/abyss/tests/vpointer.c" "$work/vpointer-proto.c" \
   $(pkg-config --cflags --libs wayland-client) -o "$work/vpointer" \
   || fail "could not build the virtual pointer"
mkfifo "$work/pointer"
env WAYLAND_DISPLAY="$wd" "$work/vpointer" 800 600 < "$work/pointer" > "$work/vp.log" 2>&1 &
vp_pid=$!
exec 3> "$work/pointer"
sleep 1

# Where a title is, from the bar's own last "titles" line.
title_at() {
  grep -F 'MenuBar: titles ' "$work/bar.log" | tail -1 | tr ' ' '\n' \
    | grep "^$1@" | head -1 | cut -d@ -f2 | tr ',' ' '
}
# Where a row is, from the rows the bar logged when that menu last opened.
item_line() {
  awk -v m="MenuBar: opened $1" 'index($0, m) { buf = ""; on = 1; next }
       on && /MenuBar: item / { buf = buf $0 "\n"; next }
       on { on = 0 } END { printf "%s", buf }' "$work/bar.log" | grep -F "'$2'" | tail -1
}
click() { printf 'm %s %s\np\nr\n' "$1" "$2" >&3; sleep 0.5; }

open_menu() {  # open_menu TITLE
  n=$(count "$work/bar.log" "MenuBar: opened $1")
  xy=$(title_at "$1"); [ -n "$xy" ] || fail "the bar published no position for $1"
  click $xy
  after "$work/bar.log" "MenuBar: opened $1" "$n" "clicking $1 opened nothing"
}

# A picture, when asked for: File open, through our own screencopy.
if [ -n "${ABYSS_MENUS_SHOT:-}" ]; then
  open_menu File
  sleep 0.5
  WAYLAND_DISPLAY="$wd" "$root/.build/debug/abyssgrab" "$ABYSS_MENUS_SHOT" \
    || fail "could not grab the screen"
  click $(title_at File)
  echo "ok: grabbed $ABYSS_MENUS_SHOT with File open"
fi

# ----------------------------------------------- 1b. the menu is on the screen
# Asserted in pixels, because every other check here would pass with a menu
# that is hit-tested and invisible. A point in the menu's left margin — inside
# the popup, left of any text, and left of the Finder window — is the menu's
# white if the popup is drawn and the desktop's blue if it is not.
open_menu File
sleep 0.4
grab="$work/open.ppm"
WAYLAND_DISPLAY="$wd" "$root/.build/debug/abyssgrab" "$grab" 2>/dev/null \
  || fail "could not grab the screen"
fx=$(title_at File | cut -d' ' -f1)
fy=$(item_line File "New Finder Window" | sed -n "s/.* at [0-9]*,\([0-9]*\) .*/\1/p")
px=$((fx - 15)); py=$((fy + 40))
hdr=$(printf 'P6\n800 600\n255\n' | wc -c | tr -d ' ')
rgb=$(dd if="$grab" bs=1 skip=$((hdr + (py * 800 + px) * 3)) count=3 2>/dev/null \
      | od -An -v -tu1 | awk '{print $1, $2, $3}')
[ "$rgb" = "255 255 255" ] \
  || fail "the File menu is open and ($px,$py) is $rgb, not the menu's white — the popup is not drawn"
echo "ok: the open menu is on screen — ($px,$py) is the menu's white, not the desktop"
click $(title_at File)

# ----------------------------------------------------- 2. Paste says no, then yes
open_menu Edit
paste=$(item_line Edit Paste)
case "$paste" in
  *" disabled edit.paste") echo "ok: Paste is drawn disabled — the clipboard is empty, and the Finder said so" ;;
  *) fail "Paste with an empty clipboard: '$paste'" ;;
esac
grep -q 'MenuBar: validated [0-9]* commands in [0-9]* us' "$work/bar.log" \
  || fail "the menu opened without asking the application what can run"
click $(title_at Edit)   # close it

# Something to copy: File ▸ New Folder, with the pointer (3).
open_menu File
nf=$(item_line File "New Folder")
case "$nf" in *" enabled file.new-folder") ;; *) fail "New Folder is not enabled: '$nf'" ;; esac
xy=$(echo "$nf" | sed -n "s/.* at \([0-9]*\),\([0-9]*\) .*/\1 \2/p")
n=$(count "$work/bar.log" "chose File > New Folder")
click $xy
after "$work/bar.log" "chose File > New Folder (file.new-folder) → ok $dir/untitled folder" "$n" \
  "choosing New Folder returned no result"
[ -d "$dir/untitled folder" ] || fail "the bar said ok and there is no folder on disk"
echo "ok: File ▸ New Folder, by pointer — the Finder answered with the path, and it is on disk"

# Edit ▸ Copy (the new folder is selected), then Paste must be enabled.
open_menu Edit
cp=$(item_line Edit Copy)
xy=$(echo "$cp" | sed -n "s/.* at \([0-9]*\),\([0-9]*\) .*/\1 \2/p")
case "$cp" in *" enabled edit.copy") ;; *) fail "Copy is not enabled with a selection: '$cp'" ;; esac
n=$(count "$work/bar.log" "chose Edit > Copy")
click $xy
after "$work/bar.log" "chose Edit > Copy (edit.copy) → ok" "$n" "choosing Copy returned no result"
open_menu Edit
paste=$(item_line Edit Paste)
case "$paste" in
  *" enabled edit.paste") echo "ok: after Edit ▸ Copy the same row is enabled — asked again as the menu opened" ;;
  *) fail "Paste after a copy: '$paste'" ;;
esac
click $(title_at Edit)
t=$(grep -o 'validated [0-9]* commands in [0-9]* us' "$work/bar.log" | tail -1)
echo "ok: $t (the round trip before a menu draws — PHASE10 §6.4)"

# ------------------------------------------------ 3b. the same, by keyboard
# The bar takes the keyboard when a title is clicked (on_demand, HANDOFF
# §2.27), and Down/Return drive the open menu. Down from nothing highlights the
# first row that can be chosen; in File that is New Finder Window.
kxml="$root/abyss/tests/virtual-keyboard-unstable-v1.xml"
wayland-scanner client-header "$kxml" "$work/vkeyboard-proto.h"
wayland-scanner private-code  "$kxml" "$work/vkeyboard-proto.c"
cc -I"$work" "$root/abyss/tests/vkeyboard.c" "$work/vkeyboard-proto.c" \
   $(pkg-config --cflags --libs wayland-client xkbcommon) -o "$work/vkeyboard" \
   || fail "could not build the virtual keyboard"
mkfifo "$work/keys"
env WAYLAND_DISPLAY="$wd" "$work/vkeyboard" < "$work/keys" > "$work/vk.log" 2>&1 &
vk_pid=$!
exec 4> "$work/keys"
sleep 1
open_menu File
n=$(count "$work/bar.log" "chose File > New Finder Window")
printf 'k 108\n' >&4; sleep 0.3     # Down (evdev 108)
printf 'k 28\n'  >&4                # Return (evdev 28)
after "$work/bar.log" "chose File > New Finder Window (file.new-window) → ok" "$n" \
  "Down and Return in the open File menu chose nothing"
echo "ok: the same menus by keyboard — Down, Return, and the Finder answered"
# And the walk: → closes File and opens Edit, and the keyboard must still be
# the bar's afterwards — the gap between the two menus has no popup in it.
open_menu File
n=$(count "$work/bar.log" "MenuBar: opened Edit")
printf 'k 106\n' >&4                # Right (evdev 106)
after "$work/bar.log" "MenuBar: opened Edit" "$n" "→ did not walk from File to Edit"
n=$(count "$work/bar.log" "MenuBar: closed")
printf 'k 1\n' >&4                  # Escape (evdev 1)
after "$work/bar.log" "MenuBar: closed" "$n" \
  "after walking to Edit the keyboard was no longer the bar's — Escape went elsewhere"
echo "ok: → walked File to Edit and Escape still reached the bar"
# And once the menu is gone the keys are the application's again — the window
# never stopped being frontmost. The witness is the rename New Folder left
# open (Jaguar drops you into naming it): R then Return names the folder "r",
# and the folder on disk is the proof the keys arrived.
sleep 0.4
printf 'k 19\n' >&4; sleep 0.2      # R (evdev 19)
printf 'k 28\n' >&4                 # Return
after "$work/finder.log" "renamed untitled folder -> r in $dir" 0 \
  "after the menu closed the keyboard never went back to the Finder"
[ -d "$dir/r" ] || fail "the Finder said it renamed the folder and there is no $dir/r"
echo "ok: with the menu closed, keys reach the Finder again — the folder is now $dir/r"

# ------------------------------------------- 4. no window: the desktop's Finder
env WAYLAND_DISPLAY="$wd" ABYSS_CONFIG_DIR="$work/cfg" HOME="$work/home" \
    AQUA_SCENE=wallpaper "$aqua" > "$work/desk.log" 2>&1 &
desk_pid=$!
after "$work/desk.log" "the desktop publishes the Finder's menus at menus.finder.$desk_pid" 0 \
  "the desktop never published its Finder's menus"
kill "$finder_pid"; wait "$finder_pid" 2>/dev/null || true; finder_pid=""
after "$work/bar.log" "showing Finder's menus from menus.finder.$desk_pid" 0 \
  "with no window focused the bar did not fall back to the desktop's Finder"
echo "ok: with no window left the desktop is frontmost — and the desktop is the Finder"

echo "all green (the bar is the frontmost application's)."
