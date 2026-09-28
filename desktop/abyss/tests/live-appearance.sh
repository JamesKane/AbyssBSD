#!/bin/sh
# AbyssBSD Swift DE — the theme changes while the desktop runs (PHASE14 P14.2).
#
# The choice lives in appearance.ini (`abyss-theme set`, and the General pane,
# write it by atomic rename); every process that draws watches the config
# directory and follows. PHASE14 §6.7 names the traps: a process that misses
# the change, and a cached picture from the old theme that survives it. So each
# section switches Aqua -> Trench -> Aqua and checks the same pixels three
# times: they CHANGE, and then they come back **byte for byte** — a stale cache
# anywhere shows up as a difference on the way back.
#
#   1. undertow's server-side frames
#   2. every toolkit process: the desktop, the menu bar, the Dock, and an
#      ordinary Aqua window — each process says it reloaded (its `Theme:` line),
#      and each one's pixels change and come back
#
# Usage: abyss/tests/live-appearance.sh
set -eu

root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"
. "$root/abyss/common.sh"
abyss_ensure_runtime_dir

undertow="$root/.build/debug/undertow"
theme="$root/.build/debug/abyss-theme"
grab="$root/.build/debug/abyssgrab"
[ -x "$undertow" ] && [ -x "$theme" ] && [ -x "$grab" ] || swift build
command -v wayland-scanner >/dev/null 2>&1 || { echo "note: no wayland-scanner, skipping"; exit 0; }

W=800
H=600
work=$(mktemp -d /tmp/abyss-appearance.XXXXXX)
cleanup() {
  for p in ${app_pid:-} ${win_pid:-} ${shell_pids:-} ${ut_pid:-}; do kill "$p" 2>/dev/null || true; done
  rm -rf "$work"
}
trap cleanup EXIT INT TERM HUP
fail() { echo "FAIL: $1"; exit 1; }
mkdir -p "$work/cfg"
export ABYSS_CONFIG_DIR="$work/cfg"
unset ABYSS_THEME ABYSS_THEME_SCHEME

# Wait until `file` has more than `since` lines matching `pattern`.
after() {  # after FILE PATTERN SINCE WHY
  i=0
  while [ $i -lt 60 ]; do
    [ "$(grep -c -- "$2" "$1" 2>/dev/null || true)" -gt "$3" ] && return 0
    sleep 0.1; i=$((i + 1))
  done
  fail "$4"
}

# A window that asks undertow to draw its frame.
deco_xml=""
for d in /usr/share/wayland-protocols /usr/local/share/wayland-protocols; do
  [ -f "$d/unstable/xdg-decoration/xdg-decoration-unstable-v1.xml" ] \
    && deco_xml="$d/unstable/xdg-decoration/xdg-decoration-unstable-v1.xml"
done
[ -n "$deco_xml" ] || { echo "SKIP: no xdg-decoration XML in wayland-protocols"; exit 0; }
wayland-scanner client-header "$deco_xml" "$work/xdg-decoration-unstable-v1-client-protocol.h"
wayland-scanner private-code  "$deco_xml" "$work/xdg-decoration-unstable-v1-protocol.c"
cc -I"$work" -I "$root/de/cwayland/include" "$root/abyss/tests/adversary.c" \
   "$root/de/cabyssprotocols/xdg-shell-protocol.c" "$work/xdg-decoration-unstable-v1-protocol.c" \
   $(pkg-config --cflags --libs wayland-client) -o "$work/adversary" \
   || fail "could not build the decorated client"

"$theme" set aqua || fail "abyss-theme could not choose aqua"
env -u WAYLAND_DISPLAY "$undertow" run --frames 0 --width "$W" --height "$H" \
    --config-dir "$work/cfg" > "$work/ut.out" 2> "$work/ut.err" &
ut_pid=$!
after "$work/ut.out" '^WAYLAND_DISPLAY=' 0 "undertow never announced a socket"
wd=$(grep -m1 '^WAYLAND_DISPLAY=' "$work/ut.out" | cut -d= -f2-)
grep -q '^Theme: Aqua from ' "$work/ut.err" || fail "undertow did not start in Aqua: $(grep '^Theme:' "$work/ut.err")"

# The shell, and an ordinary Aqua window — every one a process of its own,
# each told of the change by nobody but its own watch. The status items are
# pinned as the golden gate pins them; the clock is not, so the bar is compared
# on its left half, where the menus are.
demo="$root/.build/debug/AquaDemo"
mkdir -p "$work/desk"
shell_pids=""
for scene in wallpaper menubar dock window; do
  env WAYLAND_DISPLAY="$wd" ABYSS_DESKTOP_DIR="$work/desk" ABYSS_FINDER_DIR="$work/desk" \
      ABYSS_FAKE_VOLUME=60 ABYSS_FAKE_BATTERY=80 AQUA_SCENE="$scene" "$demo" \
      > "$work/$scene.log" 2>&1 &
  shell_pids="$shell_pids $!"
done
for scene in wallpaper menubar dock window; do
  after "$work/$scene.log" '^Theme: Aqua from ' 0 "the $scene process did not start in Aqua"
done
after "$work/ut.out" '^window org.abyssbsd.aquademo/AbyssBSD ' 0 "the Aqua window never mapped"
wg=$(grep '^window org.abyssbsd.aquademo/AbyssBSD ' "$work/ut.out" | tail -1 | cut -d' ' -f3,4)
wx=${wg%%,*}; wrest=${wg#*,}; wy=${wrest%% *}; wsize=${wg#* }; ww=${wsize%x*}

env WAYLAND_DISPLAY="$wd" "$work/adversary" decorated 300 160 > "$work/app.log" 2>&1 &
app_pid=$!
key="org.abyssbsd.undecorated/Foreign"
after "$work/ut.out" "^window $key " 0 "the decorated window never mapped"
after "$work/ut.out" '^frame-rasterisations=[1-9]' 0 "undertow never drew the window's frame"
g=$(grep "^window $key " "$work/ut.out" | tail -1 | cut -d' ' -f3,4)
sx=${g%%,*}; rest=${g#*,}; sy=${rest%% *}; size=${g#* }; sw=${size%x*}
echo "ok: a window wearing undertow's frame, at $sx,$sy, in Aqua"

hdr_len=$(printf 'P6\n%s %s\n255\n' "$W" "$H" | wc -c | tr -d ' ')
row() {  # row PPM X Y N -> the raw bytes of N pixels of one row
  dd if="$1" bs=1 skip=$((hdr_len + ((($3 * W) + $2) * 3))) count=$(($4 * 3)) 2>/dev/null | od -An -v -tu1
}
# One strip per thing that draws, each a row it and only it owns:
#   frame    undertow's title bar, 5 px above the decorated window's pixels
#   window   an Aqua window's own title bar, 8 px into its surface
#   bar      the menu bar's left half (the clock, on the right, is live)
#   dock     the Dock's shelf, 12 px above the bottom, across the middle
#   desktop  the wallpaper, down the left side, under the bar
STRIPS="frame window bar dock desktop"
shot() {  # shot NAME
  env WAYLAND_DISPLAY="$wd" "$grab" "$work/$1.ppm" > /dev/null 2>&1 || fail "screencopy failed ($1)"
  row "$work/$1.ppm" "$sx" $((sy - 5)) "$sw" > "$work/$1.frame"
  row "$work/$1.ppm" "$wx" $((wy + 8)) "$ww" > "$work/$1.window"
  row "$work/$1.ppm" 0 11 $((W / 2)) > "$work/$1.bar"
  row "$work/$1.ppm" $((W / 4)) $((H - 12)) $((W / 2)) > "$work/$1.dock"
  row "$work/$1.ppm" 0 120 60 > "$work/$1.desktop"
}
# Every one of these must have changed between two shots...
changed() {  # changed A B WHY
  for s in $STRIPS; do
    cmp -s "$work/$1.$s" "$work/$2.$s" && fail "$3: the $s did not change"
  done
  return 0
}
# ...or be byte-for-byte what it was.
same() {  # same A B WHY
  for s in $STRIPS; do
    cmp -s "$work/$1.$s" "$work/$2.$s" || fail "$3: the $s is not what it was"
  done
  return 0
}
switch() {  # switch THEME [SCHEME]
  n=$(grep -c '^theme-reloads=' "$work/ut.out" || true)
  counts=""
  for scene in wallpaper menubar dock window; do
    counts="$counts $(grep -c '^Theme: ' "$work/$scene.log" || true)"
  done
  "$theme" set "$@" || fail "abyss-theme could not choose $*"
  after "$work/ut.out" '^theme-reloads=' "$n" "undertow never noticed the theme change to $*"
  set -- $counts
  for scene in wallpaper menubar dock window; do
    after "$work/$scene.log" '^Theme: ' "$1" "the $scene process never followed the change"
    shift
  done
  sleep 0.4                          # a frame or two, drawn in the new theme
}

sleep 0.3
shot aqua
switch trench
grep -q '^Theme: Trench' "$work/ut.err" || fail "undertow reloaded, but not Trench: $(grep '^Theme:' "$work/ut.err" | tail -1)"
shot trench
changed aqua trench "Aqua -> Trench"
for scene in wallpaper menubar dock window; do
  grep '^Theme: ' "$work/$scene.log" | tail -1 | grep -q '^Theme: Trench' \
    || fail "the $scene process reloaded, but not Trench"
done
echo "ok: 1. undertow followed Aqua -> Trench with no restart, and redrew the frame"
echo "ok: 2. so did the desktop, the menu bar, the Dock and an Aqua window — each its own process"

# **A switch that changes only colours.** Aqua -> Trench changes the title
# bar's height too, so the frame's size changes and any cache misses by
# accident; two schemes of one theme keep every metric and change only the
# paint — the case where only the theme's identity in the cache key can tell
# the old frame from the new (§6.7). With it removed, this is where it fails.
switch trench daylight
shot daylight
cmp -s "$work/trench.frame" "$work/daylight.frame" \
  && fail "Trench's daylight scheme drew the same frame as neon — the frame cache does not know the theme changed"
changed trench daylight "neon -> daylight"
echo "ok:    ...and neon -> daylight, same metrics, new colours: every one redrawn"

switch aqua
shot aqua-again
same aqua aqua-again "back in Aqua, something from Trench survived"
kill -0 "$ut_pid" 2>/dev/null || fail "undertow exited during the switches"
for p in $shell_pids; do kill -0 "$p" 2>/dev/null || fail "a shell process exited during the switches"; done
echo "ok:    ...and back to Aqua, byte for byte, everywhere: nothing from Trench survived"

echo "all green (the theme changes while the desktop runs)."
